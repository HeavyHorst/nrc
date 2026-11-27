package main

import "core:c"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

SQLite_Projection_Value :: union {
	string,
	i64,
	u64,
}

// Every projection is written in the canonical asset's transaction. Keys are
// always workspace/asset ID; byte strings never undergo TEXT conversion.
sqlite_projection_write :: proc(store: ^db.Store, query: cstring, workspace: string, asset: ^pr.Asset, values: []SQLite_Projection_Value) -> c.int {
	if asset.conv_id != 0 do return sql.CONSTRAINT
	statement: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &statement, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = sql.bind_bytes(statement, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(statement, 2, asset.asset_id); rc != sql.OK do return rc
	for value, i in values {
		switch v in value {
		case string:
			rc = sql.bind_bytes(statement, c.int(i + 3), transmute([]byte)v)
		case i64:
			rc = sql.bind_int64(statement, c.int(i + 3), v)
		case u64:
			rc = sql.bind_id(statement, c.int(i + 3), v)
		}
		if rc != sql.OK do return rc
	}
	rc = sql.step(statement)
	return rc == sql.DONE ? sql.OK : rc
}

sqlite_project_asset :: proc(store: ^db.Store, workspace: string, asset: ^pr.Asset, inserted := false) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	// This also removes projections left by changing an asset's type.
	for query in ([?]cstring{"DELETE FROM note_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM note_tags WHERE workspace=?1 AND asset_id=?2", "DELETE FROM reminder_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM appointment_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM appointment_people WHERE workspace=?1 AND asset_id=?2", "DELETE FROM slice_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM customer_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM ticket_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM ticket_entry_metadata WHERE workspace=?1 AND asset_id=?2", "DELETE FROM room_mappings WHERE workspace=?1 AND asset_id=?2"}) {
		if inserted do break // A successful insert cannot have existing child rows.
		// A metadata edit must not invalidate all memberships of a valid slice.
		if asset.asset_type == .Slice && string(query) == "DELETE FROM slice_metadata WHERE workspace=?1 AND asset_id=?2" do continue
		if rc := sqlite_projection_write(store, query, workspace, asset, nil); rc != sql.OK do return rc
	}
	// Parsed metadata never escapes this one-record arena, even on SQL failure.
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	context.allocator = virtual.arena_allocator(&arena)
	switch asset.asset_type {
	case .ReviewForm, .ReviewAnswer:
		// The form is self-contained; the standard type/updated index owns its register.
		return sql.OK
	case .Note:
		tags := make([dynamic]string)
		project := json_note_metadata_fields(asset.preview, &tags, context.allocator)
		rc := sqlite_projection_write(store, "INSERT INTO note_metadata VALUES(?1,?2,?3,?4)", workspace, asset, {project, asset.updated_at})
		if rc != sql.OK do return rc
		for tag in tags {
			if rc = sqlite_projection_write(store, "INSERT INTO note_tags VALUES(?1,?2,?3,?4)", workspace, asset, {tag, asset.updated_at}); rc != sql.OK do return rc
		}
	case .Reminder:
		at, title := calendar_reminder(asset, context.allocator)
		return sqlite_projection_write(
			store,
			"INSERT INTO reminder_metadata VALUES(?1,?2,?3,?4,?5)",
			workspace,
			asset,
			{i64(reminder_is_personal(asset) ? 1 : 0), at, string(title)},
		)
	case .Appointment:
		r, valid := parse_appointment_preview(asset.preview, context.allocator)
		if !valid do return sql.OK
		start, end := appointment_envelope(r)
		key := appointment_index_key(start, end, asset.asset_id)
		rc := sqlite_projection_write(
			store,
			"INSERT INTO appointment_metadata VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
			workspace,
			asset,
			{i64(key.bucket), key.slot, start, end, string(r.assignee), string(r.project)},
		)
		if rc != sql.OK do return rc
		people := make([dynamic]string)
		append(&people, string(r.assignee))
		if r.version == 2 {
			append(&people, string(asset.owner)); append(&people, ..r.participants)
			for ex in r.exceptions do if !ex.cancelled && ex.has_participants do append(&people, ..ex.participants)
		}
		for person in people {
			if person == "" do continue
			if rc = sqlite_projection_write(store, "INSERT INTO appointment_people VALUES(?1,?2,?3) ON CONFLICT DO NOTHING", workspace, asset, {person}); rc != sql.OK do return rc
		}
	case .Slice:
		m, group, valid := slice_preview(asset, context.allocator)
		if !valid && inserted do return sql.OK
		if !valid do return sqlite_projection_write(store, "DELETE FROM slice_metadata WHERE workspace=?1 AND asset_id=?2", workspace, asset, nil)
		group_id, _ := strconv.parse_u64(group, 10)
		return sqlite_projection_write(
			store,
			`INSERT INTO slice_metadata(workspace,asset_id,name,owner,outcome,closed,closed_at,closed_by,group_id)
 VALUES(?1,?2,?3,?4,?5,?6,?7,?8,coalesce((SELECT id FROM assets WHERE workspace=?1 AND id=?9 AND asset_type=20),zeroblob(8)))
 ON CONFLICT(workspace,asset_id) DO UPDATE SET name=excluded.name,owner=excluded.owner,
 outcome=excluded.outcome,closed=excluded.closed,closed_at=excluded.closed_at,closed_by=excluded.closed_by,
 group_id=CASE WHEN ?10=0 THEN slice_metadata.group_id ELSE excluded.group_id END`,
			workspace,
			asset,
			{m.name, m.owner, m.outcome, i64(m.closed ? 1 : 0), m.closed_at, m.closed_by, group_id, i64(group != "" ? 1 : 0)},
		)
	case .CustomerCompany, .CustomerContact, .CustomerActivity:
		m, valid := customer_preview(asset, context.allocator)
		if !valid do return sql.OK
		search := fmt.aprint(
			m.title,
			" ",
			m.number,
			" ",
			m.sector,
			" ",
			m.account_type,
			" ",
			m.city,
			" ",
			m.address,
			" ",
			m.website,
			" ",
			m.assignee,
			" ",
			m.role,
			" ",
			m.email,
			" ",
			m.phone,
		)
		return sqlite_projection_write(
			store,
			"INSERT INTO customer_metadata VALUES(?1,?2,?3,?4,?5,?6,?7)",
			workspace,
			asset,
			{
				m.title,
				strings.to_lower(search),
				i64(m.archived ? 1 : 0),
				i64(customer_preview_is_active_contact(asset.preview, context.allocator) ? 1 : 0),
				m.email,
			},
		)
	case .Ticket:
		m, valid := parse_ticket_preview(asset.preview, context.allocator)
		if !valid do return sql.OK
		fields := strings.to_lower(fmt.aprint(m.title, "\n", m.requester, "\n", m.requester_name, "\n#", asset.asset_id))
		if rc := sqlite_project_ticket_document(store, workspace, asset, asset.asset_id, fields); rc != sql.OK do return rc
		follow_up, _ := ticket_follow_up_time(m.follow_up_at)
		return sqlite_projection_write(
			store,
			"INSERT INTO ticket_metadata VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
			workspace,
			asset,
			{m.title, m.status, m.assignee, m.company_id, m.contact_id, m.requester, m.requester_name, m.priority, follow_up},
		)
	case .TicketEntry:
		if asset.parent_type != .Asset do return sql.OK
		if rc := sqlite_project_ticket_document(store, workspace, asset, asset.parent_id, ""); rc != sql.OK do return rc
		m: struct {
			kind: string `json:"kind"`,
		}
		// Every entry contributes to activity time, even malformed preview JSON;
		// only parsed kinds contribute to public/customer reply watermarks.
		if json.unmarshal(asset.preview, &m, allocator = context.allocator) != nil do m.kind = ""
		return sqlite_projection_write(
			store,
			"INSERT INTO ticket_entry_metadata VALUES(?1,?2,?3,?4,?5)",
			workspace,
			asset,
			{u64(asset.parent_id), m.kind, asset.created_at},
		)
	case .RoomMapping:
		if asset.conv_id != pr.WORKSPACE_DATA_ID do return sql.OK
		name_buf: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
		name, valid := normalize_room_mapping_name(asset.preview, name_buf[:])
		if !valid do return sql.OK
		if _, builtin := builtin_room_id_for_name(name); builtin do return sql.OK
		return sqlite_projection_write(
			store,
			"INSERT INTO room_mappings(workspace,asset_id,name,conversation_id) VALUES(?1,?2,?3,?4)",
			workspace,
			asset,
			{name, u64(make_room_mapping_conv_id(workspace, name))},
		)
	case .Comment, .Document, .File, .Agenda, .Monitor, .Incident, .MonitorSource, .SliceGroup:
	}
	return sql.OK
}

sqlite_project_ticket_document :: proc(store: ^db.Store, workspace: string, asset: ^pr.Asset, ticket: u64, fields: string) -> c.int {
	rc := sqlite_projection_write(store, "INSERT INTO ticket_search_docs(workspace,asset_id,ticket_id) VALUES(?1,?2,?3)", workspace, asset, {ticket})
	if rc != sql.OK do return rc
	// FTS5 may skip or stop at NUL. Keep a searchable boundary instead;
	// queries containing this private-use character take the literal scan.
	index_fields, _ := strings.replace_all(fields, "\x00", TICKET_FTS_NUL)
	index_body, _ := strings.replace_all(ticket_search_body(asset), "\x00", TICKET_FTS_NUL)
	return sqlite_projection_write(
		store,
		`INSERT INTO ticket_trigrams(rowid,fields,body)
 SELECT docid,CAST(?3 AS TEXT),CAST(?4 AS TEXT) FROM ticket_search_docs WHERE workspace=?1 AND asset_id=?2`,
		workspace,
		asset,
		{index_fields, index_body},
	)
}

// Explicit offline operation. One SQLite row plus one scoped parser arena is
// live at a time. Failure rolls back the entire rebuild, including old indexes.
sqlite_rebuild_projections :: proc(store: ^db.Store) -> c.int {
	if sql.get_autocommit(store.db) == 0 do return sql.MISUSE
	rc := db.begin(store)
	if rc != sql.OK do return rc
	committed := false
	defer if !committed do db.rollback(store)
	// Reject ambiguous legacy aliases rather than silently pick an asset based
	// on SQL iteration order. Other projections have one independent asset key.
	if rc = sql.exec(store.db, "DELETE FROM room_mappings", nil, nil, nil); rc != sql.OK do return rc
	statement: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		"SELECT workspace,id,asset_type,parent_type,parent_id,owner,created_at,updated_at,payload_encoding,payload_raw_len,preview,payload FROM assets ORDER BY workspace,id",
		-1,
		&statement,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	for {
		rc = sql.step(statement)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		a: pr.Asset
		a.asset_id, rc = sql.column_id(statement, 1); if rc != sql.OK do return rc
		a.asset_type = pr.AssetType(sql.column_int64(statement, 2))
		a.parent_type = pr.ParentType(sql.column_int64(statement, 3))
		a.parent_id, rc = sql.column_id(statement, 4); if rc != sql.OK do return rc
		a.owner = sql.column_bytes_view(statement, 5)
		a.created_at = sql.column_int64(statement, 6); a.updated_at = sql.column_int64(statement, 7)
		a.payload_encoding = pr.PayloadEncoding(sql.column_int64(statement, 8))
		raw_len := sql.column_int64(statement, 9)
		if raw_len < 0 || raw_len > i64(max(u32)) do return sql.CORRUPT
		a.payload_raw_len = u32(raw_len)
		a.preview = sql.column_bytes_view(statement, 10); a.payload = sql.column_bytes_view(statement, 11)
		if len(a.preview) > pr.MAX_PREVIEW_LENGTH || len(a.payload) > pr.MAX_PAYLOAD_LENGTH do return sql.TOOBIG
		if !validate_appointment_asset(a.asset_type, a.payload_encoding, a.payload_raw_len, a.preview, a.payload) ||
		   !validate_ticket_asset(a.asset_type, a.parent_type, a.parent_id, a.payload_encoding, a.payload_raw_len, a.preview, a.payload) {
			return sql.CORRUPT
		}
		if rc = sqlite_project_asset(store, string(sql.column_bytes_view(statement, 0)), &a); rc != sql.OK do return rc
	}
	if rc = db.rebuild_slices(store); rc != sql.OK do return rc
	if rc = sql.exec(store.db, "DELETE FROM ticket_search_backfill", nil, nil, nil); rc != sql.OK do return rc
	rc = db.commit(store)
	committed = rc == sql.OK
	return rc
}

sqlite_projection_builder_main :: proc() {
	if len(os.args) != 2 {fmt.eprintln("Usage: projection-builder <existing-shard.sqlite3>"); os.exit(2)}
	path := strings.clone_to_cstring(os.args[1]); defer delete(path)
	store, rc := db.open(path)
	if rc != sql.OK {fmt.eprintf("Cannot open NRC SQLite shard (status %d)\n", rc); os.exit(1)}
	rc = sqlite_rebuild_projections(&store)
	close_rc := db.close(&store)
	if rc != sql.OK || close_rc != sql.OK {fmt.eprintf("Projection rebuild failed (status %d, close %d)\n", rc, close_rc); os.exit(1)}
}
