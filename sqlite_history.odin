package main

import "core:c"
import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Availability is read from the same transaction as the page. Only the tiny
// canonical visibility fields are needed, never the asset payload or a RAM map.
sqlite_history_available :: proc(store: ^db.Store, workspace, actor: string, kind: u8, id: u64, asset_type: ^u16) -> (bool, c.int) {
	if kind != 1 && kind != 2 do return false, sql.OK
	query: cstring = "SELECT 1 FROM tasks WHERE workspace=?1 AND id=?2"
	if kind == 2 do query = "SELECT asset_type,owner,preview FROM assets WHERE workspace=?1 AND id=?2"
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return false, rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return false, rc
	if rc = sql.bind_id(s, 2, id); rc != sql.OK do return false, rc
	rc = sql.step(s)
	if rc == sql.DONE do return false, sql.OK
	if rc != sql.ROW do return false, rc
	if kind == 1 do return true, sql.OK
	a := pr.Asset {
		asset_type = pr.AssetType(sql.column_int64(s, 0)),
		owner      = sql.column_bytes_view(s, 1),
		preview    = sql.column_bytes_view(s, 2),
	}
	if !asset_visible_to(&a, actor) do return false, sql.OK
	if asset_type^ == 0 do asset_type^ = u16(a.asset_type)
	return true, sql.OK
}

sqlite_history_frame :: proc(output: ^db.Command_Output, correlation: u32, payload: []byte) -> c.int {
	buf, rc := db.command_frame(output, 6 + len(payload))
	if rc != sql.OK do return rc
	endian.put_u16(buf, .Big, u16(pr.Opcode.S_HistoryPage))
	endian.put_u32(buf[2:], .Big, correlation)
	copy(buf[6:], payload)
	return sql.OK
}

sqlite_execute_history :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListHistoryRequest(request.body)
	if err != nil do return sql.CONSTRAINT
	// Each indexed arm contributes at most one page plus lookahead. UNION
	// deduplicates matching endpoints without materializing all historical IDs.
	query: cstring = `SELECT id,entity_kind,entity_id,body,source_kind,source_id,target_kind,target_id
		FROM history WHERE workspace=?1 AND id<?2 AND (private_owner=x'' OR private_owner=?3) ORDER BY id DESC LIMIT ?6`
	if req.kind != 0 do query = `SELECT id,entity_kind,entity_id,body,source_kind,source_id,target_kind,target_id
		FROM history WHERE workspace=?1 AND id IN (
		 SELECT id FROM (SELECT id FROM history INDEXED BY history_entity WHERE workspace=?1 AND entity_kind=?4 AND entity_id=?5 AND id<?2
		   AND (private_owner=x'' OR private_owner=?3) ORDER BY id DESC LIMIT ?6)
		 UNION SELECT id FROM (SELECT id FROM history INDEXED BY history_source WHERE workspace=?1 AND entity_kind=3 AND source_kind=?4 AND source_id=?5 AND id<?2
		   AND (private_owner=x'' OR private_owner=?3) ORDER BY id DESC LIMIT ?6)
		 UNION SELECT id FROM (SELECT id FROM history INDEXED BY history_target WHERE workspace=?1 AND entity_kind=3 AND target_kind=?4 AND target_id=?5 AND id<?2
		   AND (private_owner=x'' OR private_owner=?3) ORDER BY id DESC LIMIT ?6)
		) ORDER BY id DESC LIMIT ?6`
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	// No cursor includes the entire u64 domain, including max(u64). A nine-byte
	// sentinel sorts after every eight-byte ID without losing integer precision.
	if req.before == 0 {
		sentinel := [9]byte{255, 255, 255, 255, 255, 255, 255, 255, 255}
		rc = sql.bind_bytes(s, 2, sentinel[:])
	} else {rc = sql.bind_id(s, 2, req.before)}
	if rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 3, transmute([]byte)request.actor); rc != sql.OK do return rc
	if req.kind != 0 {
		if rc = sql.bind_int64(s, 4, i64(req.kind)); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 5, req.entity); rc != sql.OK do return rc
	}
	if rc = sql.bind_int64(s, 6, i64(req.limit) + 1); rc != sql.OK do return rc
	b: strings.Builder
	strings.builder_init(&b); defer strings.builder_destroy(&b)
	strings.write_string(&b, `{"events":[`)
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame)) - 6
	count := 0
	last: u64
	more := false
	for {
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if count == int(req.limit) {more = true; break}
		virtual.arena_free_all(&arena)
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		entity, entity_rc := sql.column_id(s, 2); if entity_rc != sql.OK do return entity_rc
		source, source_rc := sql.column_id(s, 5); if source_rc != sql.OK do return source_rc
		target, target_rc := sql.column_id(s, 7); if target_rc != sql.OK do return target_rc
		body := sql.column_bytes_view(s, 3)
		if len(body) > 65536 do return sql.CORRUPT
		event: pr.History_Event
		if json.unmarshal(body, &event, allocator = allocator) != nil do return sql.CORRUPT
		event.entity_available, rc = sqlite_history_available(store, request.workspace, request.actor, u8(sql.column_int64(s, 1)), entity, &event.asset_type)
		if rc != sql.OK do return rc
		event.source_available, rc = sqlite_history_available(
			store,
			request.workspace,
			request.actor,
			u8(sql.column_int64(s, 4)),
			source,
			&event.source_asset_type,
		)
		if rc != sql.OK do return rc
		event.target_available, rc = sqlite_history_available(
			store,
			request.workspace,
			request.actor,
			u8(sql.column_int64(s, 6)),
			target,
			&event.target_asset_type,
		)
		if rc != sql.OK do return rc
		encoded, encode_err := json.marshal(event, allocator = allocator)
		if encode_err != nil do return sql.CORRUPT
		if strings.builder_len(b) + len(encoded) + 64 > limit {
			// Never return an empty page whose cursor cannot advance.
			if count == 0 do return sql.TOOBIG
			more = true; break
		}
		if count > 0 do strings.write_string(&b, ",")
		strings.write_string(&b, string(encoded)); count += 1; last = id
	}
	if !more do last = 0
	fmt.sbprintf(&b, `],"nextBefore":"%d"}`, last)
	return sqlite_history_frame(output, req.correlation_id, transmute([]byte)strings.to_string(b))
}
