package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strconv"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

MONITOR_STATUS_NAMES :: [9]string{"firing", "failing", "error", "no_data", "unknown", "between", "healthy", "paused", "retired"}
Monitor_Status_Row :: struct {
	id, monitor_id, name, identity, status:                     string,
	revision, sequence, evaluated_at, seen_at:                  string,
	value:                                                      Maybe(f64),
	paused, retired, incident_open:                             bool,
	observation, freshness:                                     int,
	failures, recoveries, missing:                              u32,
	incident_id, acknowledged_by, acknowledged_at, assigned_to: string,
	counts:                                                     [9]u64, // Monitor rows only, in MONITOR_STATUS_NAMES order.
}
Monitor_Status_Page :: struct {
	version:                   int,
	config_revision:           string,
	monitor_id, at, cursor_id: string,
	cursor_rank:               u8,
	has_more:                  bool,
	rows:                      [dynamic]Monitor_Status_Row,
}

// Canonical assets validate these JSON fields on write. Parameters scope every
// join to the request workspace. IDs remain fixed-width blobs through sorting.
MONITOR_STATUS_CFG :: `WITH cfg AS (
 SELECT a.id,a.updated_at revision,json_extract(CAST(a.preview AS TEXT),'$.name') name,
 json_extract(CAST(a.preview AS TEXT),'$.enabled') enabled,
 3*json_extract(CAST(a.preview AS TEXT),'$.interval_ns')+json_extract(CAST(a.preview AS TEXT),'$.timeout_ns') stale,
 coalesce(r.sequence,zeroblob(8)) run_sequence,coalesce(r.evaluated_at,0) run_at,
 coalesce(r.revision,0) run_revision,substr(r.receipt,25,1)=x'01' run_failed
 FROM assets a LEFT JOIN monitor_runs r ON r.workspace=a.workspace AND r.monitor_id=a.id
 WHERE a.workspace=?1 AND a.asset_type=?8`
MONITOR_STATUS_INSTANCES :: `
), instances AS (
 SELECT i.*,c.enabled,c.revision,c.name,
 CASE WHEN i.retired THEN 8 WHEN i.paused OR NOT c.enabled THEN 7
 WHEN i.incident_open THEN 0
 WHEN c.run_revision!=c.revision THEN 4
 WHEN i.freshness=0 THEN 4
 WHEN i.observation=4 THEN 2
 WHEN (i.has_value AND ?3-i.seen_at>=c.stale) OR i.observation=3 THEN 3
 WHEN NOT i.has_value THEN 4 WHEN i.observation=1 THEN 1
 WHEN i.observation=2 THEN 5 ELSE 6 END rank
 FROM monitor_instances i JOIN cfg c ON c.id=i.monitor_id
 WHERE i.workspace=?1`
MONITOR_STATUS_SUMMARY :: `
), summary AS (
 SELECT c.*,
 CASE WHEN NOT c.enabled THEN 7
 WHEN coalesce(min(CASE WHEN i.rank<7 THEN i.rank END),9)=0 THEN 0
 WHEN c.run_revision!=c.revision THEN 4
 WHEN c.run_failed THEN 2
 WHEN c.run_at>0 AND ?3-c.run_at>=c.stale THEN 3
 ELSE coalesce(min(CASE WHEN i.rank<7 THEN i.rank END),CASE WHEN count(i.id)>0 AND min(i.rank)=7 THEN 7 ELSE 4 END) END rank,
 sum(CASE WHEN i.rank=0 THEN 1 ELSE 0 END) n0,sum(CASE WHEN i.rank=1 THEN 1 ELSE 0 END) n1,
 sum(CASE WHEN i.rank=2 THEN 1 ELSE 0 END) n2,sum(CASE WHEN i.rank=3 THEN 1 ELSE 0 END) n3,
 sum(CASE WHEN i.rank=4 THEN 1 ELSE 0 END) n4,sum(CASE WHEN i.rank=5 THEN 1 ELSE 0 END) n5,
 sum(CASE WHEN i.rank=6 THEN 1 ELSE 0 END) n6,sum(CASE WHEN i.rank=7 THEN 1 ELSE 0 END) n7,
 sum(CASE WHEN i.rank=8 THEN 1 ELSE 0 END) n8
 FROM cfg c LEFT JOIN instances i ON i.monitor_id=c.id GROUP BY c.id
) `

sqlite_query_monitor_status :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	r, err := pr.parseQueryMonitorStatusRequest(request.body)
	if err != nil do return sql.CONSTRAINT
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	now := nrc_time_unix_nanos()
	at := r.at == 0 ? now : r.at
	if at <= 0 || at > now || now - at > 300_000_000_000 do return sql.CONSTRAINT
	config_revision: string
	if r.monitor_id != 0 {
		// Monitors are workspace-visible. Read the revision even for an empty
		// instance page, without loading an asset preview, payload or attachments.
		rev: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT updated_at FROM assets WHERE workspace=?1 AND id=?2 AND asset_type=?3", -1, &rev, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(rev)
		if rc = sql.bind_bytes(rev, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(rev, 2, r.monitor_id); rc != sql.OK do return rc
		if rc = sql.bind_int64(rev, 3, i64(pr.AssetType.Monitor)); rc != sql.OK do return rc
		if rc = sql.step(rev); rc != sql.ROW do return rc == sql.DONE ? sql.CONSTRAINT : rc
		config_revision = fmt.aprintf("%d", sql.column_int64(rev, 0))
	}
	query :=
		MONITOR_STATUS_CFG + MONITOR_STATUS_INSTANCES + MONITOR_STATUS_SUMMARY +
		`SELECT id,rank,name,revision,run_sequence,run_at,n0,n1,n2,n3,n4,n5,n6,n7,n8
 FROM summary WHERE (?4=zeroblob(8) OR rank>?5 OR (rank=?5 AND id>?4))
 AND (?9=0 OR (?9=1 AND rank<6) OR (?9=2 AND rank=6) OR (?9=3 AND rank=7))
 AND (length(?10)=0 OR instr(lower(name),lower(CAST(?10 AS TEXT)))>0 OR id=?11)
 ORDER BY rank,id LIMIT ?6`
	if r.monitor_id != 0 {
		// Without ANALYZE statistics SQLite otherwise prefers a workspace-wide
		// primary-key scan over the selective (workspace,monitor_id,identity) index.
		query =
			MONITOR_STATUS_CFG + " AND a.id=?2" + MONITOR_STATUS_INSTANCES + " AND unlikely(i.monitor_id=?2)) " +
			`SELECT i.id,i.rank,i.identity,i.revision,i.sequence,i.evaluated_at,i.seen_at,
 i.value_bits,i.has_value,i.paused,i.retired,i.incident_open,i.observation,i.freshness,i.failures,i.recoveries,i.missing,
 coalesce(e.incident_id,zeroblob(8)),coalesce(json_extract(CAST(a.preview AS TEXT),'$.acknowledged_by'),''),
 coalesce(json_extract(CAST(a.preview AS TEXT),'$.acknowledged_at'),''),coalesce(json_extract(CAST(a.preview AS TEXT),'$.assigned_to'),'')
 FROM instances i LEFT JOIN monitor_episodes e ON e.workspace=i.workspace AND e.instance_id=i.id AND e.episode=i.episode
 LEFT JOIN assets a ON a.workspace=e.workspace AND a.id=e.incident_id
 WHERE (?7 OR NOT i.retired) AND (?4=zeroblob(8) OR i.rank>?5 OR (i.rank=?5 AND i.id>?4)) ORDER BY i.rank,i.id LIMIT ?6`
	}
	statement: ^sql.Statement
	cquery := strings.clone_to_cstring(query)
	rc := sql.prepare_v2(store.db, cquery, -1, &statement, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = sql.bind_bytes(statement, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(statement, 2, r.monitor_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(statement, 3, at); rc != sql.OK do return rc
	if rc = sql.bind_id(statement, 4, r.cursor_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(statement, 5, i64(r.cursor_rank)); rc != sql.OK do return rc
	if rc = sql.bind_int64(statement, 6, i64(r.limit) + 1); rc != sql.OK do return rc
	if rc = sql.bind_int64(statement, 7, r.include_retired ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(statement, 8, i64(pr.AssetType.Monitor)); rc != sql.OK do return rc
	if r.monitor_id == 0 {
		search := strings.trim_space(r.search)
		id_text := search
		if strings.has_prefix(id_text, "#") do id_text = id_text[1:]
		search_id, valid_id := strconv.parse_u64(id_text)
		if !valid_id do search_id = 0
		if rc = sql.bind_int64(statement, 9, i64(r.state_filter)); rc != sql.OK do return rc
		if rc = sql.bind_bytes(statement, 10, transmute([]byte)search); rc != sql.OK do return rc
		if rc = sql.bind_id(statement, 11, search_id); rc != sql.OK do return rc
	}
	page := Monitor_Status_Page {
		config_revision = config_revision,
		version    = 1,
		monitor_id = fmt.aprintf("%d", r.monitor_id),
		at         = fmt.aprintf("%d", at),
		cursor_id  = "0",
	}
	page.rows = make([dynamic]Monitor_Status_Row, 0, int(r.limit))
	status_names := MONITOR_STATUS_NAMES
	size := 1024
	for {
		rc = sql.step(statement)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(page.rows) == int(r.limit) {page.has_more = true; break}
		id, id_rc := sql.column_id(statement, 0)
		if id_rc != sql.OK do return id_rc
		rank := sql.column_int64(statement, 1)
		if rank < 0 || rank >= len(MONITOR_STATUS_NAMES) do return sql.CORRUPT
		row := Monitor_Status_Row {
			id         = fmt.aprintf("%d", id),
			monitor_id = page.monitor_id,
			status     = status_names[rank],
		}
		text := strings.clone(string(sql.column_bytes_view(statement, 2)))
		row.revision = fmt.aprintf("%d", sql.column_int64(statement, 3))
		seq, seq_rc := sql.column_id(statement, 4)
		if seq_rc != sql.OK do return seq_rc
		row.sequence = fmt.aprintf("%d", seq)
		row.evaluated_at = fmt.aprintf("%d", sql.column_int64(statement, 5))
		if r.monitor_id == 0 {
			row.monitor_id, row.name = row.id, text
			row.paused = rank == 7
			for j in 0 ..< 9 do row.counts[j] = u64(sql.column_int64(statement, i32(6 + j)))
			row.incident_open = row.counts[0] > 0
		} else {
			row.identity = text
			row.seen_at = fmt.aprintf("%d", sql.column_int64(statement, 6))
			if sql.column_int64(statement, 8) != 0 {
				bits, bits_rc := sql.column_id(statement, 7)
				if bits_rc != sql.OK do return bits_rc
				row.value = transmute(f64)bits
			}
			row.paused = sql.column_int64(statement, 9) != 0
			row.retired = sql.column_int64(statement, 10) != 0
			row.incident_open = sql.column_int64(statement, 11) != 0
			row.observation = int(sql.column_int64(statement, 12))
			row.freshness = int(sql.column_int64(statement, 13))
			row.failures = u32(sql.column_int64(statement, 14))
			row.recoveries = u32(sql.column_int64(statement, 15))
			row.missing = u32(sql.column_int64(statement, 16))
			incident, incident_rc := sql.column_id(statement, 17)
			if incident_rc != sql.OK do return incident_rc
			row.incident_id = fmt.aprintf("%d", incident)
			row.acknowledged_by = strings.clone(string(sql.column_bytes_view(statement, 18)))
			row.acknowledged_at = strings.clone(string(sql.column_bytes_view(statement, 19)))
			row.assigned_to = strings.clone(string(sql.column_bytes_view(statement, 20)))
		}
		encoded, encode_err := json.marshal(row)
		if encode_err != nil do return sql.CONSTRAINT
		if size + len(encoded) + 1 > 120000 {page.has_more = true; break}
		size += len(encoded) + 1
		append(&page.rows, row)
		page.cursor_id, page.cursor_rank = row.id, u8(rank)
	}
	encoded, encode_err := json.marshal(page)
	if encode_err != nil do return sql.CONSTRAINT
	context.allocator = backing
	buf, frame_rc := db.command_frame(output, 6 + len(encoded))
	if frame_rc != sql.OK do return frame_rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_MonitorStatusPage))
	endian.put_u32(buf[2:], .Big, r.correlation_id)
	copy(buf[6:], encoded)
	return sql.OK
}
