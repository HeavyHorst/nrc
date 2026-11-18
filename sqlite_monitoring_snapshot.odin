package main

import "core:c"
import "core:encoding/endian"
import "core:mem"
import "core:mem/virtual"
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
	return sqlite_monitor_state_page(store, request, output, r, enabled, policy, backing, at)
}

// The capture transaction supplies its accepted evaluation time. Reading an
// immutable outbox page never revalidates that time against a later wall clock.
sqlite_monitor_state_page :: proc(
	store: ^db.Store,
	request: ^db.Request,
	output: ^db.Command_Output,
	r: pr.GetMonitorStateRequest,
	enabled: bool,
	policy: mon.Policy,
	backing: mem.Allocator,
	at: i64,
) -> c.int {
	if at <= 0 || at > max(i64) - policy.stale_after do return sql.CONSTRAINT
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

sqlite_capture_monitor_snapshot :: proc(
	store: ^db.Store,
	request: ^db.Request,
	monitor_id, sequence: u64,
	revision, at: i64,
	policy: mon.Policy,
	enabled := true,
) -> c.int {
	page := db.Command_Output {
		limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE,
	}
	defer db.destroy_command_output(&page)
	r := pr.GetMonitorStateRequest {
		monitor_id = monitor_id,
		revision   = revision,
		sequence   = sequence,
	}
	snapshot_id, allocation_rc := db.next_id(store, .Monitor_Snapshot)
	if allocation_rc != sql.OK do return allocation_rc
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "INSERT INTO monitor_snapshots VALUES(?1,?2,?3,?4,?5,?6)", -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	for {
		if rc = sqlite_monitor_state_page(store, request, &page, r, enabled, policy, context.allocator, at); rc != sql.OK do return rc
		// C_MonitorHistory extends the live page with a capture ID and kind. All
		// paused rows in an accepted run still belong to the ordinary run backlog.
		body := make([]byte, len(page.frames[0].payload) + 9)
		copy(body, page.frames[0].payload)
		endian.put_u64(body[len(body) - 9:], .Big, snapshot_id)
		body[len(body) - 1] = enabled ? 0 : 1
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, monitor_id); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 3, snapshot_id); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 4, at); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 5, r.cursor); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 6, body); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.DONE do return rc
		r.cursor, _ = endian.get_u64(body[46:], .Big)
		if r.cursor == 0 do break
		if rc = sql.reset(s); rc != sql.OK do return rc
		db.destroy_command_output(&page)
		page = {
			limit = pr.MAX_PROTOCOL_PAYLOAD_SIZE,
		}
	}
	return sql.OK
}

sqlite_monitor_history :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	r, err := pr.parseMonitorHistoryRequest(request.body)
	if err != nil do return sql.CONSTRAINT
	monitor, found, rc := sqlite_read_asset(store, request.workspace, request.actor, r.monitor_id, true)
	if rc != sql.OK do return rc
	if !found do return sql.CONSTRAINT
	config, policy, valid := parse_monitor_config(&monitor, context.allocator)
	if !valid || config.evaluator != request.actor do return sql.CONSTRAINT
	s: ^sql.Statement
	query: cstring = "SELECT body FROM monitor_snapshots WHERE workspace=?1 AND monitor_id=?2 AND snapshot_id=?3 AND observed_at=?4 AND cursor=?5"
	if r.cursor == 0 do query = "SELECT body FROM monitor_snapshots WHERE workspace=?1 AND monitor_id=?2 AND cursor=?5 ORDER BY snapshot_id LIMIT 1"
	if r.acknowledge do query = "DELETE FROM monitor_snapshots WHERE workspace=?1 AND monitor_id=?2 AND snapshot_id=?3 AND observed_at=?4"
	rc = sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, r.monitor_id); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 3, r.snapshot_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 4, r.at); rc != sql.OK do return rc
	if !r.acknowledge {if rc = sql.bind_id(s, 5, r.cursor); rc != sql.OK do return rc}
	rc = sql.step(s)
	if rc == sql.DONE && !r.acknowledge && r.cursor == 0 && !config.enabled {
		// Disabled monitors still emit bounded pause evidence. Capture once before
		// paging, exactly as for runs; continuation never consults the wall clock.
		sequence: u64
		read: ^sql.Statement
		if rc = sql.prepare_v2(store.db, "SELECT sequence FROM monitor_runs WHERE workspace=?1 AND monitor_id=?2", -1, &read, nil); rc != sql.OK do return rc
		defer sql.finalize(read)
		if rc = sql.bind_bytes(read, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(read, 2, r.monitor_id); rc != sql.OK do return rc
		rc = sql.step(read)
		if rc == sql.ROW {if sequence, rc = sql.column_id(read, 0); rc != sql.OK do return rc} else if rc != sql.DONE do return rc
		if rc = sqlite_capture_monitor_snapshot(store, request, r.monitor_id, sequence, monitor.updated_at, nrc_time_unix_nanos(), policy, false); rc != sql.OK do return rc
		if rc = sql.reset(s); rc != sql.OK do return rc
		rc = sql.step(s)
	}
	if rc == sql.DONE {
		if r.cursor != 0 do return sql.CONSTRAINT
		context.allocator = backing
		buf, status := db.command_frame(output, 30)
		if status != sql.OK do return status
		endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorState))
		endian.put_u32(buf[2:], .Big, r.correlation_id)
		endian.put_u64(buf[6:], .Big, r.monitor_id)
		endian.put_u64(buf[14:], .Big, u64(monitor.updated_at))
		endian.put_u64(buf[22:], .Big, r.snapshot_id)
		return sql.OK
	}
	if rc != sql.ROW do return rc
	body := sql.column_bytes_view(s, 0)
	context.allocator = backing
	buf, status := db.command_frame(output, len(body))
	if status != sql.OK do return status
	copy(buf, body)
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	return sql.OK
}
