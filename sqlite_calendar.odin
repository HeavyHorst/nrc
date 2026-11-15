package main

import "core:c"
import "core:mem/virtual"
import "core:strings"
import tz "core:time/timezone"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

SQLite_Calendar_Page :: struct {
	items: [101]pr.CalendarRow,
	count: int,
}

sqlite_calendar_row_destroy :: proc(row: pr.CalendarRow) {
	delete(row.title); delete(row.assignee); delete(row.project)
}

// Keep only the earliest page plus one lookahead. Text is copied out of the
// current SQLite row / one-appointment arena, never retained for all candidates.
sqlite_calendar_offer :: proc(rows: ^SQLite_Calendar_Page, req: pr.CalendarRequest, row: pr.CalendarRow) {
	if req.has_cursor && calendar_key_compare(row.key, req.cursor) <= 0 do return
	position := 0
	for position < rows.count && calendar_key_compare(rows.items[position].key, row.key) <= 0 do position += 1
	if position > int(req.limit) do return
	if rows.count == int(req.limit) + 1 {
		rows.count -= 1; sqlite_calendar_row_destroy(rows.items[rows.count])
	}
	rows.count += 1
	for i := rows.count - 1; i > position; i -= 1 do rows.items[i] = rows.items[i - 1]
	copy := row
	copy.title = transmute([]byte)strings.clone(string(row.title))
	copy.assignee = transmute([]byte)strings.clone(string(row.assignee))
	copy.project = transmute([]byte)strings.clone(string(row.project))
	rows.items[position] = copy
}

sqlite_calendar_appointment :: proc(rows: ^SQLite_Calendar_Page, req: pr.CalendarRequest, id: u64, owner, preview: []byte) -> c.int {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return sql.NOMEM
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	r, valid := parse_appointment_preview(preview, allocator)
	if !valid do return sql.OK
	if r.repeat == "" {
		if !appointment_person_matches(r, owner, r.participants, req.assignee) do return sql.OK
		sqlite_calendar_offer(
			rows,
			req,
			{
				key = {max(r.start_at, req.start), 2, id},
				title = r.title,
				assignee = r.assignee,
				project = r.project,
				actual_start_at = r.start_at,
				end_at = r.end_at,
			},
		)
	} else {
		zone, loaded := appointment_zone(r.timezone, allocator)
		if !loaded do return sql.OK
		defer if zone != nil do tz.region_destroy(zone, allocator)
		for occurrence in appointment_expand(r, req.start, req.end, zone, allocator) {
			if !appointment_person_matches(r, owner, occurrence.participants, req.assignee) do continue
			sqlite_calendar_offer(
				rows,
				req,
				{
					key = {max(occurrence.start_at, req.start), 3, id},
					title = r.title,
					assignee = r.assignee,
					project = r.project,
					actual_start_at = occurrence.start_at,
					end_at = occurrence.end_at,
					occurrence_at = occurrence.at,
				},
			)
		}
	}
	return sql.OK
}

sqlite_query_calendar :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseCalendarRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	rows: SQLite_Calendar_Page
	defer for row in rows.items[:rows.count] do sqlite_calendar_row_destroy(row)
	// Each point stream is already sorted. At most limit+1 visible rows from
	// either stream can contribute to the final merged page.
	for query, kind in ([2]cstring{`SELECT id,due_at,title,assignee,project,blocked_by!=x'0000000000000000'
 FROM tasks INDEXED BY tasks_due WHERE workspace=?1 AND due_at>0 AND due_at>=?2 AND due_at<?3 AND status BETWEEN 0 AND 2
 AND (NOT ?4 OR (due_at,0,id)>(?5,?6,?7)) AND (?8=x'' OR assignee=?8) AND (?9=x'' OR project=?9)
 ORDER BY due_at,id LIMIT ?10`, `SELECT m.asset_id,m.deadline,m.title,x'',x'',0
 FROM reminder_metadata m INDEXED BY reminder_deadline CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND m.deadline>0 AND m.deadline>=?2 AND m.deadline<?3
 AND (NOT ?4 OR (m.deadline,1,m.asset_id)>(?5,?6,?7)) AND ?8=x'' AND ?9=x''
 AND (m.personal=0 OR (?11!=x'' AND a.owner=?11)) ORDER BY m.deadline,m.asset_id LIMIT ?10`}) {
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		for value, i in ([5]i64{req.has_cursor ? max(req.start, req.cursor.at) : req.start, req.end, req.has_cursor ? 1 : 0, req.cursor.at, i64(req.cursor.kind)}) {
			if rc = sql.bind_int64(s, c.int(i + 2), value); rc != sql.OK do return rc
		}
		if rc = sql.bind_id(s, 7, req.cursor.id); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 8, req.assignee); rc != sql.OK do return rc
		if rc = sql.bind_bytes(s, 9, req.project); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 10, i64(req.limit) + 1); rc != sql.OK do return rc
		if kind == 1 {if rc = sql.bind_bytes(s, 11, transmute([]byte)request.actor); rc != sql.OK do return rc}
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			sqlite_calendar_offer(
				&rows,
				req,
				{
					key = {sql.column_int64(s, 1), u8(kind), id},
					title = sql.column_bytes_view(s, 2),
					assignee = sql.column_bytes_view(s, 3),
					project = sql.column_bytes_view(s, 4),
					blocked = sql.column_int64(s, 5) != 0,
				},
			)
		}
	}
	// The existing interval buckets include long events and recurrence exceptions.
	// Reuse their exact overlap test and canonical recurrence expansion.
	s: ^sql.Statement
	rc := sql.prepare_v2(
		store.db,
		`SELECT m.asset_id,a.owner,a.preview
 FROM appointment_metadata m INDEXED BY appointment_interval CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.asset_id
 WHERE m.workspace=?1 AND m.bucket=?2 AND m.slot>=?3 AND m.slot<=?4 AND m.start_at<?5
 AND ((m.end_at!=0 AND m.end_at>?6) OR (m.end_at=0 AND m.start_at>=?6))
 AND (?7=x'' OR m.project=?7)
 AND (?8=x'' OR EXISTS(SELECT 1 FROM appointment_people p WHERE p.workspace=m.workspace AND p.asset_id=m.asset_id AND p.person=?8))
 ORDER BY m.slot,m.start_at,m.asset_id`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, req.end); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 6, req.start); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 7, req.project); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 8, req.assignee); rc != sql.OK do return rc
	for bucket: u8 = 0; bucket < 64; bucket += 1 {
		if rc = sql.bind_int64(s, 2, i64(bucket)); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 3, req.start >> bucket); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 4, (req.end - 1) >> bucket); rc != sql.OK do return rc
		for {
			rc = sql.step(s); if rc == sql.DONE do break
			if rc != sql.ROW do return rc
			id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
			if rc = sqlite_calendar_appointment(&rows, req, id, sql.column_bytes_view(s, 1), sql.column_bytes_view(s, 2)); rc != sql.OK do return rc
		}
		if rc = sql.reset(s); rc != sql.OK do return rc
	}
	size := 34; count := 0; more := false
	budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for row in rows.items[:rows.count] {
		if count == int(req.limit) {more = true; break}
		row_size := pr.calendar_row_size(row)
		if row_size > budget - size {
			if count == 0 do return sql.TOOBIG
			more = true; break
		}
		count += 1; size += row_size
	}
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeCalendarPage(rows.items[:count], more, req.correlation_id, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}
