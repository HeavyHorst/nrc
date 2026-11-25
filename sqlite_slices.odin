package main

import "core:c"
import "core:fmt"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_list_slices :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListTaskSlicesRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	if rc := db.finalize_slices(store); rc != sql.OK do return rc
	if !req.has_name do return sqlite_list_slices_indexed(store, request, output, req)
	msg := pr.TaskSliceList {
		success        = true,
		correlation_id = req.correlation_id,
	}
	with_counts := !req.has_cursor && !req.has_owner && !req.has_name && len(req.project) == 0
	name := strings.to_lower(string(req.name)); defer delete(name)
	// Sort derived rows on disk, not a workspace-sized array of member records.
	defer sql.exec(store.db, "DELETE FROM temp.nrc_slices", nil, nil, nil)
	rc := sql.exec(
		store.db,
		`CREATE TEMP TABLE IF NOT EXISTS nrc_slices(id BLOB PRIMARY KEY,name BLOB,owner BLOB,closed INTEGER,sort_at INTEGER,
 backlog INTEGER,todo INTEGER,in_progress INTEGER,done INTEGER,blocked INTEGER,notes INTEGER,files INTEGER,tickets INTEGER,oldest INTEGER,last_moved INTEGER) WITHOUT ROWID;
 CREATE INDEX IF NOT EXISTS temp.nrc_slices_order ON nrc_slices(closed,sort_at DESC,id);
 DELETE FROM temp.nrc_slices;`,
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	s: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT m.asset_id,m.name,m.owner,m.closed,
 CASE WHEN ?5 THEN 0 ELSE (SELECT a.created_at FROM assets a WHERE a.workspace=m.workspace AND a.id=m.asset_id) END
 FROM slice_metadata m
 WHERE m.workspace=?1 AND (NOT ?2 OR m.owner=?3) AND (?4 OR m.closed=0)`,
		-1,
		&s,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 2, req.has_owner ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_bytes(s, 3, req.owner); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 4, req.include_closed || with_counts ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 5, req.has_name ? 1 : 0); rc != sql.OK do return rc
	summary: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT backlog,todo,in_progress,done,blocked,notes,files,tickets,oldest,last_moved,
 max(backlog,todo,in_progress,done,blocked,notes,files,tickets)>65535,
 EXISTS(SELECT 1 FROM slice_projects WHERE workspace=?1 AND slice_id=?2 AND project=?3),
 CASE WHEN ?4 THEN (SELECT created_at FROM assets WHERE workspace=?1 AND id=?2) ELSE 0 END
 FROM slice_summaries WHERE workspace=?1 AND slice_id=?2`,
		-1,
		&summary,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(summary)
	if rc = sql.bind_bytes(summary, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_bytes(summary, 3, req.project); rc != sql.OK do return rc
	if rc = sql.bind_int64(summary, 4, req.has_name ? 1 : 0); rc != sql.OK do return rc
	insert: ^sql.Statement
	rc = sql.prepare_v2(store.db, "INSERT INTO temp.nrc_slices VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15)", -1, &insert, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(insert)
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		if req.has_name {
			lower := strings.to_lower(string(sql.column_bytes_view(s, 1)))
			matches := strings.contains(lower, name); delete(lower)
			if !matches do continue
		}
		entry := pr.TaskSlice {
			slice_id = id,
			name     = sql.column_bytes_view(s, 1),
			owner    = sql.column_bytes_view(s, 2),
		}
		closed := sql.column_int64(s, 3) != 0
		if closed do entry.flags += pr.TaskSliceFlag_CLOSED
		project_matches := len(req.project) == 0
		if rc = sql.bind_id(summary, 2, id); rc != sql.OK do return rc
		rc = sql.step(summary)
		if rc != sql.ROW do return rc == sql.DONE ? sql.CORRUPT : rc
		for dest, i in ([8]^u16{&entry.backlog, &entry.todo, &entry.in_progress, &entry.done, &entry.blocked, &entry.notes, &entry.files, &entry.tickets}) do dest^ = u16(sql.column_int64(summary, c.int(i)))
		entry.oldest_active_at = sql.column_int64(summary, 8); entry.last_moved_at = sql.column_int64(summary, 9)
		overflow := sql.column_int64(summary, 10) != 0
		project_matches = project_matches || sql.column_int64(summary, 11) != 0
		created := req.has_name ? sql.column_int64(summary, 12) : sql.column_int64(s, 4)
		if rc = sql.reset(summary); rc != sql.OK do return rc
		if !project_matches do continue
		if overflow {
			msg = pr.TaskSliceList {
				correlation_id = req.correlation_id,
				error          = transmute([]byte)string("Slice listing representation limit exceeded: member category exceeds 65535"),
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeTaskSliceList(msg)); if frame_rc != sql.OK do return frame_rc
			return pr.serializeTaskSliceList(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
		}
		if closed && !req.include_closed do continue
		if msg.total_count == max(u32) do return sql.TOOBIG
		msg.total_count += 1
		if rc = sql.bind_id(insert, 1, id); rc != sql.OK do return rc
		if rc = sql.bind_bytes(insert, 2, entry.name); rc != sql.OK do return rc
		if rc = sql.bind_bytes(insert, 3, entry.owner); rc != sql.OK do return rc
		for value, i in ([12]i64{closed ? 1 : 0, max(created, entry.last_moved_at), i64(entry.backlog), i64(entry.todo), i64(entry.in_progress), i64(entry.done), i64(entry.blocked), i64(entry.notes), i64(entry.files), i64(entry.tickets), entry.oldest_active_at, entry.last_moved_at}) {
			if rc = sql.bind_int64(insert, c.int(i + 4), value); rc != sql.OK do return rc
		}
		if rc = sql.step(insert); rc != sql.DONE do return rc
		if rc = sql.reset(insert); rc != sql.OK do return rc
	}
	if with_counts {
		counts: ^sql.Statement
		rc = sql.prepare_v2(
			store.db,
			"SELECT coalesce(sum(total),0),coalesce(sum(covered),0) FROM workspace_task_counts WHERE workspace=?1 AND status!=?2",
			-1,
			&counts,
			nil,
		)
		if rc != sql.OK do return rc
		defer sql.finalize(counts)
		if rc = sql.bind_bytes(counts, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_int64(counts, 2, i64(pr.TaskStatus.Note)); rc != sql.OK do return rc
		if rc = sql.step(counts); rc != sql.ROW do return rc
		total := sql.column_int64(counts, 0); covered := sql.column_int64(counts, 1)
		if total > i64(max(u32)) do return sql.TOOBIG
		msg.assigned_tasks = u32(covered); msg.unassigned_tasks = u32(total - covered)
	}
	rows: ^sql.Statement
	rc = sql.prepare_v2(
		store.db,
		`SELECT * FROM temp.nrc_slices WHERE NOT ?1 OR closed>?2 OR
 (closed=?2 AND (sort_at<?3 OR (sort_at=?3 AND id>?4))) ORDER BY closed,sort_at DESC,id LIMIT ?5`,
		-1,
		&rows,
		nil,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(rows)
	if rc = sql.bind_int64(rows, 1, req.has_cursor ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 2, req.cursor_closed ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 3, req.cursor_sort_at); rc != sql.OK do return rc
	if rc = sql.bind_id(rows, 4, req.cursor_slice_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 5, i64(req.limit) + 1); rc != sql.OK do return rc
	return sqlite_slice_page(store, request, rows, req, msg, output)
}

sqlite_slice_page :: proc(store: ^db.Store, request: ^db.Request, rows: ^sql.Statement, req: pr.ListTaskSlicesRequest, message: pr.TaskSliceList, output: ^db.Command_Output) -> c.int {
	msg := message
	msg.include_reviews = req.include_reviews
	rc: c.int
	reviews: ^sql.Statement
	defer if reviews != nil do sql.finalize(reviews)
	if req.include_reviews {
		rc = sql.prepare_v2(store.db, `SELECT count(*) FROM slice_members m
 CROSS JOIN assets a ON a.workspace=m.workspace AND a.id=m.member_id
 WHERE m.workspace=?1 AND m.slice_id=?2 AND m.member_type=1 AND a.asset_type=?3`, -1, &reviews, nil)
		if rc != sql.OK do return rc
		if rc = sql.bind_bytes(reviews, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_int64(reviews, 3, i64(pr.AssetType.ReviewForm)); rc != sql.OK do return rc
	}
	entries := make([dynamic]pr.TaskSlice, 0, int(req.limit))
	defer {for entry in entries {delete(entry.name); delete(entry.owner)}; delete(entries)}
	size := pr.getSizeTaskSliceList(msg)
	budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for {
		rc = sql.step(rows); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(entries) == int(req.limit) {msg.has_more = true; break}
		entry := pr.TaskSlice {
			name  = sql.column_bytes_view(rows, 1),
			owner = sql.column_bytes_view(rows, 2),
		}
		entry.slice_id, rc = sql.column_id(rows, 0); if rc != sql.OK do return rc
		closed := sql.column_int64(rows, 3) != 0
		if closed do entry.flags += pr.TaskSliceFlag_CLOSED
		for dest, i in ([8]^u16{&entry.backlog, &entry.todo, &entry.in_progress, &entry.done, &entry.blocked, &entry.notes, &entry.files, &entry.tickets}) do dest^ = u16(sql.column_int64(rows, c.int(i + 5)))
		entry.oldest_active_at = sql.column_int64(rows, 13); entry.last_moved_at = sql.column_int64(rows, 14)
		entry_size := pr.getSizeTaskSlice(entry) + (req.include_reviews ? 4 : 0)
		if size + entry_size > budget {if len(entries) == 0 do return sql.TOOBIG; msg.has_more = true; break}
		if reviews != nil {
			if rc = sql.bind_id(reviews, 2, entry.slice_id); rc != sql.OK do return rc
			if rc = sql.step(reviews); rc != sql.ROW do return rc
			count := sql.column_int64(reviews, 0)
			if count > i64(max(u32)) do return sql.TOOBIG
			entry.reviews = u32(count)
			if rc = sql.reset(reviews); rc != sql.OK do return rc
		}
		entry.name = transmute([]byte)strings.clone(string(entry.name)); entry.owner = transmute([]byte)strings.clone(string(entry.owner))
		append(&entries, entry); size += entry_size
		msg.next_cursor_closed = closed; msg.next_cursor_sort_at = sql.column_int64(rows, 4); msg.next_cursor_slice_id = entry.slice_id
	}
	msg.slices = entries[:]
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	return pr.serializeTaskSliceList(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

// Named substring searches retain the Unicode-aware path above. Ordinary
// pages seek the durable ordering index before fetching record fields.
sqlite_list_slices_indexed :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output, req: pr.ListTaskSlicesRequest) -> c.int {
	msg := pr.TaskSliceList{success = true, correlation_id = req.correlation_id}
	with_counts := !req.has_cursor && !req.has_owner && len(req.project) == 0
	owner := req.has_owner ? " AND m.owner=?2" : ""
	project :: "(?3=x'' OR EXISTS(SELECT 1 FROM slice_projects p WHERE p.workspace=m.workspace AND p.slice_id=m.asset_id AND p.project=?3))"
	project_from :: `FROM slice_projects p INDEXED BY slice_projects_filter
 CROSS JOIN slice_metadata m ON m.workspace=p.workspace AND m.asset_id=p.slice_id`
	count_query: string
	if len(req.project) > 0 {
		// Missing summaries remain an error even outside the selected project.
		// Count and overflow checks, however, only need that project's records.
		count_query = fmt.aprintf(`SELECT
 coalesce(sum(?4 OR m.closed=0),0),
 coalesce(max(max(s.backlog,s.todo,s.in_progress,s.done,s.blocked,s.notes,s.files,s.tickets)>65535),0),
 EXISTS(SELECT 1 FROM slice_metadata m WHERE m.workspace=?1%s AND (?5 OR m.closed=0)
 AND NOT EXISTS(SELECT 1 FROM slice_summaries s WHERE s.workspace=m.workspace AND s.slice_id=m.asset_id))
 %s LEFT JOIN slice_summaries s ON s.workspace=m.workspace AND s.slice_id=m.asset_id
 WHERE p.workspace=?1 AND p.project=?3%s AND (?5 OR m.closed=0)`, owner, project_from, owner)
	} else {
		count_query = fmt.aprintf(`SELECT
 coalesce(sum(%s AND (?4 OR m.closed=0)),0),
 coalesce(max(%s AND max(s.backlog,s.todo,s.in_progress,s.done,s.blocked,s.notes,s.files,s.tickets)>65535),0),
 coalesce(max(s.slice_id IS NULL),0)
 FROM slice_metadata m LEFT JOIN slice_summaries s ON s.workspace=m.workspace AND s.slice_id=m.asset_id
 WHERE m.workspace=?1%s AND (?5 OR m.closed=0)`, project, project, owner)
	}
	defer delete(count_query)
	c_count := strings.clone_to_cstring(count_query); defer delete(c_count)
	count: ^sql.Statement
	rc := sql.prepare_v2(store.db, c_count, -1, &count, nil); if rc != sql.OK do return rc
	defer sql.finalize(count)
	if rc = sql.bind_bytes(count, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_bytes(count, 2, req.owner); rc != sql.OK do return rc
	if rc = sql.bind_bytes(count, 3, req.project); rc != sql.OK do return rc
	if rc = sql.bind_int64(count, 4, req.include_closed ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(count, 5, req.include_closed || with_counts ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.step(count); rc != sql.ROW do return rc
	if sql.column_int64(count, 2) != 0 do return sql.CORRUPT
	if sql.column_int64(count, 1) != 0 {
		msg = {correlation_id = req.correlation_id, error = transmute([]byte)string("Slice listing representation limit exceeded: member category exceeds 65535")}
		buf, status := db.command_frame(output, pr.getSizeTaskSliceList(msg)); if status != sql.OK do return status
		return pr.serializeTaskSliceList(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	total := sql.column_int64(count, 0)
	if total > i64(max(u32)) do return sql.TOOBIG
	msg.total_count = u32(total)
	if with_counts {
		counts: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT coalesce(sum(total),0),coalesce(sum(covered),0) FROM workspace_task_counts WHERE workspace=?1 AND status!=?2", -1, &counts, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(counts)
		if rc = sql.bind_bytes(counts, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_int64(counts, 2, i64(pr.TaskStatus.Note)); rc != sql.OK do return rc
		if rc = sql.step(counts); rc != sql.ROW do return rc
		all := sql.column_int64(counts, 0); covered := sql.column_int64(counts, 1)
		if all > i64(max(u32)) do return sql.TOOBIG
		msg.assigned_tasks = u32(covered); msg.unassigned_tasks = u32(all - covered)
	}
	index := req.has_owner ? "slice_owner_page" : "slice_page"
	closed := req.include_closed ? "" : " AND m.closed=0"
	// A whole project fitting in one page has bounded sorting work. For larger
	// projects, keep the ordering-index seek rather than sorting every match.
	project_page := len(req.project) > 0 && total <= i64(req.limit) + 1
	base: string
	if project_page {
		base = fmt.aprintf("SELECT m.asset_id AS id,m.closed,m.sort_at %s WHERE p.workspace=?1 AND p.project=?3%s%s", project_from, owner, closed)
	} else {
		base = fmt.aprintf("SELECT m.asset_id AS id,m.closed,m.sort_at FROM slice_metadata m INDEXED BY %s WHERE m.workspace=?1%s%s AND %s", index, owner, closed, project)
	}
	defer delete(base)
	keys: string
	if !req.has_cursor {
		keys = fmt.aprintf("%s ORDER BY closed,sort_at DESC,id LIMIT ?9", base)
	} else if !req.include_closed && req.cursor_closed {
		keys = fmt.aprintf("%s AND 0 LIMIT ?9", base)
	} else if project_page {
		// Visit project matches once, then sort narrow keys before loading fields.
		keys = fmt.aprintf(`%s AND (m.closed>?6 OR (m.closed=?6 AND
 (m.sort_at<?7 OR (m.sort_at=?7 AND m.asset_id>?8)))) ORDER BY closed,sort_at DESC,id LIMIT ?9`, base)
	} else {
		// Disjoint ranges preserve mixed ASC/DESC ordering without OFFSET.
		// Each emits at most limit+1 keys; a project filter can examine more.
		later: string
		if req.include_closed && !req.cursor_closed {
			later = fmt.aprintf(" UNION ALL SELECT * FROM (%s AND m.closed>?6 ORDER BY closed,sort_at DESC,id LIMIT ?9)", base)
		}
		defer delete(later)
		keys = fmt.aprintf(`SELECT * FROM (%s AND m.closed=?6 AND m.sort_at=?7 AND m.asset_id>?8 ORDER BY closed,sort_at DESC,id LIMIT ?9)
 UNION ALL SELECT * FROM (%s AND m.closed=?6 AND m.sort_at<?7 ORDER BY closed,sort_at DESC,id LIMIT ?9)
 %s ORDER BY closed,sort_at DESC,id LIMIT ?9`, base, base, later)
	}
	defer delete(keys)
	query := fmt.aprintf(`WITH page AS MATERIALIZED (%s)
 SELECT p.id,m.name,m.owner,p.closed,p.sort_at,s.backlog,s.todo,s.in_progress,s.done,s.blocked,s.notes,s.files,s.tickets,s.oldest,s.last_moved
 FROM page p CROSS JOIN slice_metadata m ON m.workspace=?1 AND m.asset_id=p.id
 CROSS JOIN slice_summaries s ON s.workspace=?1 AND s.slice_id=p.id
 ORDER BY p.closed,p.sort_at DESC,p.id`, keys)
	defer delete(query)
	c_query := strings.clone_to_cstring(query); defer delete(c_query)
	rows: ^sql.Statement
	rc = sql.prepare_v2(store.db, c_query, -1, &rows, nil); if rc != sql.OK do return rc
	defer sql.finalize(rows)
	if rc = sql.bind_bytes(rows, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_bytes(rows, 2, req.owner); rc != sql.OK do return rc
	if rc = sql.bind_bytes(rows, 3, req.project); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 6, req.cursor_closed ? 1 : 0); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 7, req.cursor_sort_at); rc != sql.OK do return rc
	if rc = sql.bind_id(rows, 8, req.cursor_slice_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(rows, 9, i64(req.limit) + 1); rc != sql.OK do return rc
	return sqlite_slice_page(store, request, rows, req, msg, output)
}
