package main

import "core:c"
import "core:encoding/endian"
import "core:mem"
import "core:strings"
import mon "monitoring"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// A revision/sequence fence spans pages. Maintenance may change freshness while
// paging, so derive staleness from seen_at at the fixed snapshot time instead.
sqlite_monitor_snapshot_page :: proc(
	store: ^db.Store,
	request: ^db.Request,
	output: ^db.Command_Output,
	r: pr.GetMonitorStateRequest,
	enabled: bool,
	policy: mon.Policy,
	backing: mem.Allocator,
) -> c.int {
	now := nrc_time_unix_nanos()
	at := r.at == 0 ? now : r.at
	if at <= 0 || at > now || now - at > 300_000_000_000 || at > max(i64) - policy.stale_after do return sql.CONSTRAINT
	s: ^sql.Statement
	rc := sql.prepare_v2(
		store.db,
		`SELECT id,identity,seen_at,has_value,observation,freshness,paused
 FROM monitor_instances WHERE workspace=?1 AND monitor_id=?2 AND id>?3 AND retired=0 ORDER BY id LIMIT 17`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 3, r.cursor); rc != sql.OK do return rc
	rows: [16]struct {
		id:       u64,
		identity: string,
		state:    u8,
		until:    i64,
	}
	count, size := 0, 56
	next: u64
	for {
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if count == len(rows) {next = rows[count - 1].id; break}
		row := &rows[count]
		if row.id, rc = sql.column_id(s, 0); rc != sql.OK do return rc
		row.identity = strings.clone(string(sql.column_bytes_view(s, 1)))
		row.state, row.until = 2, at // Unknown, not healthy by default.
		seen := sql.column_int64(s, 2)
		observation := sql.column_int64(s, 4)
		if !enabled || sql.column_int64(s, 6) != 0 {
			row.state, row.until = 3, at + policy.stale_after // Observed pause, bounded evidence.
		} else if sql.column_int64(s, 3) != 0 && observation < 2 && sql.column_int64(s, 5) != 0 && seen <= at && seen <= max(i64) - policy.stale_after {
			row.until = max(at, seen + policy.stale_after)
			if row.until > at do row.state = u8(observation)
		}
		size += 19 + len(row.identity)
		count += 1
	}
	context.allocator = backing
	buf, status := db.command_frame(output, size)
	if status != sql.OK do return status
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorState))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	endian.put_u64(buf[6:], .Big, r.monitor_id)
	endian.put_u64(buf[14:], .Big, u64(r.revision))
	endian.put_u64(buf[22:], .Big, r.sequence)
	endian.put_u64(buf[30:], .Big, u64(at))
	endian.put_u64(buf[38:], .Big, u64(policy.stale_after))
	endian.put_u64(buf[46:], .Big, next)
	endian.put_u16(buf[54:], .Big, u16(count))
	offset := 56
	for row in rows[:count] {
		endian.put_u64(buf[offset:], .Big, row.id)
		endian.put_u16(buf[offset + 8:], .Big, u16(len(row.identity)))
		copy(buf[offset + 10:], row.identity)
		offset += 10 + len(row.identity)
		buf[offset] = row.state
		endian.put_u64(buf[offset + 1:], .Big, u64(row.until))
		offset += 9
	}
	return sql.OK
}
