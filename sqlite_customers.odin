package main

import "core:c"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_search_customers :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseSearchCustomersRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	query := strings.to_lower(string(req.query)); defer delete(query)
	s: ^sql.Statement
	// Resolve matching contacts once, walking both directions of membership.
	// IN deduplicates companies even when several contacts match. CASE skips
	// this lookup entirely for an empty query or a direct company match.
	rc := sql.prepare_v2(
		store.db,
		`WITH contacts AS MATERIALIZED (
 SELECT m.asset_id FROM customer_metadata m CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND instr(m.search_text,?4)>0 AND a.asset_type=?5)
 SELECT m.asset_id,CASE WHEN length(?4)=0 OR instr(m.search_text,?4)>0 THEN 1 ELSE m.asset_id IN (
 SELECT e.target_id FROM contacts c CROSS JOIN edges e INDEXED BY edges_source WHERE e.workspace=?1 AND e.source_type=?6 AND e.source_id=c.asset_id AND e.target_type=?6 AND e.relation=?7
 UNION ALL SELECT e.source_id FROM contacts c CROSS JOIN edges e INDEXED BY edges_target WHERE e.workspace=?1 AND e.target_type=?6 AND e.target_id=c.asset_id AND e.source_type=?6 AND e.relation=?7) END
 FROM customer_metadata m
 CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND a.asset_type=?2 AND (?3 OR m.archived=0) ORDER BY m.asset_id`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 2, i64(pr.AssetType.CustomerCompany)); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 3, req.include_archived ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 4, transmute([]byte)query); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, i64(pr.AssetType.CustomerContact)); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 6, i64(pr.TargetType.Asset)); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 7, i64(pr.RelationType.MemberOf)); rc != sql.OK do return rc
	numeric := query != "" && len(query) <= 20
	for c in query {if c < '0' || c > '9' {numeric = false; break}}
	backing := context.allocator
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	assets: [CUSTOMER_READ_MAX_LIMIT]pr.Asset
	count := 0
	limit := req.limit == 0 ? CUSTOMER_READ_DEFAULT_LIMIT : min(int(req.limit), CUSTOMER_READ_MAX_LIMIT)
	msg := pr.CustomerSearchPageMessage {
		correlation_id = req.correlation_id,
	}
	size := pr.getSizeCustomerSearchPageMessage(msg)
	byte_limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		matched := sql.column_int64(s, 1) != 0
		if !matched && numeric {
			// Decimal IDs must retain their unsigned meaning above INT64_MAX.
			text := fmt.aprint(id)
			matched = strings.contains(text, query); delete(text)
		}
		if !matched do continue
		if msg.total_count == max(u32) do return sql.TOOBIG
		msg.total_count += 1
		if id <= req.after_company_id do continue
		if msg.has_more do continue // Continue metadata counting, not body loading.
		if count == limit {msg.has_more = true; continue}
		a: pr.Asset
		found: bool
		{
			context.allocator = virtual.arena_allocator(&arena)
			a, found, rc = sqlite_read_asset(store, request.workspace, request.actor, id, false)
		}
		if rc != sql.OK do return rc
		if !found do return sql.CORRUPT
		if pr.getSizeAssetHeader(a) > byte_limit - size {
			if count == 0 do return sqlite_command_error(output, request.opcode, req.correlation_id, "Company exceeds page byte limit")
			msg.has_more = true; continue
		}
		assets[count] = a; count += 1; size += pr.getSizeAssetHeader(a); msg.next_company_id = id
	}
	context.allocator = backing
	msg.assets = assets[:count]
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeCustomerSearchPageMessage(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
