package main

import "core:c"
import "core:fmt"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// The caller owns the SQL. Only active filters may reference record columns:
// otherwise even count(*) needs full task rows instead of a covering index.
sqlite_task_query_filter :: proc(req: pr.TaskQueryRequest, ordered := false) -> string {
	from := " FROM tasks t"
	// Start at the slice, never at all workspace tasks. CROSS JOIN keeps the
	// member set outermost even without planner statistics. UNION preserves set
	// semantics; canonical membership uniqueness also rules out reversed pairs.
	if req.slice_id != 0 do from = ` FROM (
 SELECT target_id AS id FROM edges INDEXED BY edges_source
 WHERE workspace=?1 AND source_type=?13 AND source_id=?10 AND relation=?14 AND target_type=?12
 UNION
 SELECT source_id AS id FROM edges INDEXED BY edges_target
 WHERE workspace=?1 AND target_type=?13 AND target_id=?10 AND relation=?14 AND source_type=?12
	) members CROSS JOIN tasks t ON t.id=members.id`
	// The validated four-bit mask already excludes other statuses. Add the
	// redundant range only for counts/status ordering, where the status index
	// covers the read, not for sorts that would fetch every full task through it.
	status := ordered && req.sort != .Status ? "" : " AND t.status BETWEEN 0 AND 3"
	blocked := ""
	if req.blocked == 1 do blocked = " AND t.blocked_by!=x'0000000000000000'"
	if req.blocked == 2 do blocked = " AND t.blocked_by=x'0000000000000000'"
	return fmt.aprintf(
		"%s WHERE t.workspace=?1%s AND (?2 & (1 << t.status))!=0%s%s%s%s%s%s",
		from,
		status,
		req.color != 255 ? " AND t.color=?3" : "",
		blocked,
		req.overdue_before != 0 ? " AND t.due_at>0 AND t.due_at<?5 AND t.status!=3" : "",
		req.has_assignee ? " AND t.assignee=?7" : "",
		req.has_project ? " AND t.project=?9" : "",
		req.slice_id != 0 ? " AND EXISTS(SELECT 1 FROM assets WHERE workspace=?1 AND id=?10 AND asset_type=?11)" : "",
	)
}

sqlite_prepare_task_query :: proc(store: ^db.Store, workspace: string, req: pr.TaskQueryRequest, query: string) -> (s: ^sql.Statement, rc: c.int) {
	text := strings.clone_to_cstring(query); defer delete(text)
	rc = sql.prepare_v2(store.db, text, -1, &s, nil); if rc != sql.OK do return
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_int64(s, 2, i64(req.status_mask)); rc != sql.OK do return
	if req.color != 255 {if rc = sql.bind_int64(s, 3, i64(req.color)); rc != sql.OK do return}
	if req.overdue_before != 0 {if rc = sql.bind_int64(s, 5, req.overdue_before); rc != sql.OK do return}
	if req.has_assignee {if rc = sql.bind_bytes(s, 7, req.assignee); rc != sql.OK do return}
	if req.has_project {if rc = sql.bind_bytes(s, 9, req.project); rc != sql.OK do return}
	if req.slice_id == 0 do return
	if rc = sql.bind_id(s, 10, req.slice_id); rc != sql.OK do return
	for value, i in ([4]i64{i64(pr.AssetType.Slice), i64(pr.TargetType.Task), i64(pr.TargetType.Asset), i64(pr.RelationType.MemberOf)}) {
		if rc = sql.bind_int64(s, c.int(i + 11), value); rc != sql.OK do return
	}
	return
}

// One selection per connection, kept in SQLite temporary storage. Both the
// key and validity stamp participate in the executor transaction. Local writes
// (including rolled-back writes) and commits from other connections invalidate
// conservatively; cache bookkeeping accounts for its own final inserted row.
sqlite_work_order_cache :: proc(store: ^db.Store, workspace: string, req: pr.TaskQueryRequest, total: ^u32, save := false) -> (hit: bool, rc: c.int) {
	key := req
	key.limit = 1; key.correlation_id = 0; key.has_cursor = false
	key.cursor_number = 0; key.cursor_task_id = 0; key.cursor_text = nil
	buf := make([]byte, pr.getSizeTaskQueryRequest(key)); defer delete(buf)
	if pr.serializeTaskQueryRequest(key, buf) != len(buf) do return false, sql.CONSTRAINT
	rc = sql.exec(
		store.db,
		"CREATE TEMP TABLE IF NOT EXISTS nrc_work_cache(workspace BLOB,query BLOB,version INTEGER,changes INTEGER,total INTEGER)",
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return
	query: cstring = `SELECT total FROM temp.nrc_work_cache WHERE workspace=?1 AND query=?2
 AND version=(SELECT data_version FROM pragma_data_version) AND changes=total_changes()`
	if save {
		if rc = sql.exec(store.db, "DELETE FROM temp.nrc_work_cache", nil, nil, nil); rc != sql.OK do return
		query = "INSERT INTO temp.nrc_work_cache SELECT ?1,?2,data_version,total_changes()+1,?3 FROM pragma_data_version"
	}
	s: ^sql.Statement
	rc = sql.prepare_v2(store.db, query, -1, &s, nil); if rc != sql.OK do return
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)workspace); rc != sql.OK do return
	if rc = sql.bind_bytes(s, 2, buf); rc != sql.OK do return
	if save {if rc = sql.bind_int64(s, 3, i64(total^)); rc != sql.OK do return}
	rc = sql.step(s)
	if rc != sql.ROW && rc != sql.DONE do return
	if rc == sql.ROW do total^ = u32(sql.column_int64(s, 0))
	return rc == sql.ROW, sql.OK
}

sqlite_task_work_order_build :: proc(store: ^db.Store, workspace: string, req: pr.TaskQueryRequest) -> c.int {
	rc := sql.exec(
		store.db,
		"DROP TABLE IF EXISTS temp.nrc_work; CREATE TEMP TABLE nrc_work(id BLOB PRIMARY KEY,dependency BLOB,bucket INTEGER,priority INTEGER,missing INTEGER,due INTEGER,position INTEGER) WITHOUT ROWID;",
		nil,
		nil,
		nil,
	)
	if rc != sql.OK do return rc
	filter := sqlite_task_query_filter(req, ordered = true); defer delete(filter)
	query := fmt.aprintf(
		`INSERT INTO temp.nrc_work SELECT t.id,t.blocked_by,
 CASE WHEN t.status=3 THEN 2 WHEN t.blocked_by=x'0000000000000000' OR EXISTS(SELECT 1 FROM tasks p WHERE p.workspace=t.workspace AND p.id=t.blocked_by AND p.status=3) THEN 0 ELSE 1 END,
 t.priority,t.due_at<=0,CASE WHEN t.due_at>0 THEN t.due_at ELSE 0 END,NULL%s`,
		filter,
	)
	defer delete(query)
	s, prepare_rc := sqlite_prepare_task_query(store, workspace, req, query); defer if s != nil do sql.finalize(s)
	if prepare_rc != sql.OK do return prepare_rc
	if rc = sql.step(s); rc != sql.DONE do return rc
	// Bulk-build the queue indexes instead of maintaining them per insert.
	// Each index retains only its active set: pending queue, blocked children,
	// or emitted positions. Ranking need not reinsert finished queue entries.
	rc = sql.exec(
		store.db,
		`CREATE INDEX temp.nrc_work_queue ON nrc_work(bucket,priority DESC,missing,due,id) WHERE bucket<3;
 CREATE INDEX temp.nrc_work_children ON nrc_work(dependency) WHERE bucket=1;
 CREATE UNIQUE INDEX temp.nrc_work_position ON nrc_work(position) WHERE position IS NOT NULL;`,
		nil,
		nil,
		nil,
	)
	return rc
}

// Resume the disk-backed priority queue only through this page's lookahead.
// A surviving cursor ID overrides its old rank; a missing ID uses that rank.
sqlite_task_work_order :: proc(store: ^db.Store, req: pr.TaskQueryRequest) -> c.int {
	position: i64
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT coalesce(max(position),0) FROM temp.nrc_work WHERE position IS NOT NULL", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.step(s); rc != sql.ROW do return rc
		position = sql.column_int64(s, 0)
	}
	rc := sql.OK
	start := req.has_cursor ? max(i64(0), req.cursor_number) : 0
	seek_cursor := false
	if req.has_cursor {
		cursor: ^sql.Statement
		rc = sql.prepare_v2(store.db, "SELECT position FROM temp.nrc_work WHERE id=?1", -1, &cursor, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(cursor)
		if rc = sql.bind_id(cursor, 1, req.cursor_task_id); rc != sql.OK do return rc
		rc = sql.step(cursor)
		if rc != sql.ROW && rc != sql.DONE do return rc
		if rc == sql.ROW {start = sql.column_int64(cursor, 0); seek_cursor = start == 0}
	}
	remaining := i64(req.limit) + 1
	if !seek_cursor && position > start do remaining -= min(remaining, position - start)
	if remaining == 0 do return sql.OK
	pop: ^sql.Statement
	rc = sql.prepare_v2(store.db, "SELECT id,bucket FROM temp.nrc_work WHERE bucket<3 ORDER BY bucket,priority DESC,missing,due,id LIMIT 1", -1, &pop, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(pop)
	emit: ^sql.Statement
	rc = sql.prepare_v2(store.db, "UPDATE temp.nrc_work SET bucket=3,position=?2 WHERE id=?1", -1, &emit, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(emit)
	release: ^sql.Statement
	rc = sql.prepare_v2(store.db, "UPDATE temp.nrc_work SET bucket=0 WHERE dependency=?1 AND bucket=1", -1, &release, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(release)
	for {
		rc = sql.step(pop); if rc == sql.DONE do return sql.OK
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(pop, 0); if id_rc != sql.OK do return id_rc
		ready := sql.column_int64(pop, 1) == 0
		if rc = sql.reset(pop); rc != sql.OK do return rc
		position += 1
		if position > i64(max(u32)) do return sql.TOOBIG
		if rc = sql.bind_id(emit, 1, id); rc != sql.OK do return rc
		if rc = sql.bind_int64(emit, 2, position); rc != sql.OK do return rc
		if rc = sql.step(emit); rc != sql.DONE do return rc
		if rc = sql.reset(emit); rc != sql.OK do return rc
		if ready {
			if rc = sql.bind_id(release, 1, id); rc != sql.OK do return rc
			if rc = sql.step(release); rc != sql.DONE do return rc
			if rc = sql.reset(release); rc != sql.OK do return rc
		}
		if seek_cursor && id == req.cursor_task_id {seek_cursor = false; start = position}
		if !seek_cursor && position > start {
			remaining -= 1
			if remaining == 0 do return sql.OK
		}
	}
}

sqlite_query_tasks :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseTaskQueryRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	page := pr.TaskQueryPage {
		success        = true,
		correlation_id = req.correlation_id,
	}
	work := req.sort == .WorkOrder
	cache_saved := false
	cached_count := false
	defer if work && !cache_saved do sql.exec(store.db, "DROP TABLE IF EXISTS temp.nrc_work; DROP TABLE IF EXISTS temp.nrc_work_cache", nil, nil, nil)
	if work {
		hit, rc := sqlite_work_order_cache(store, request.workspace, req, &page.total_count); if rc != sql.OK do return rc
		cached_count = hit
		if !hit {if rc = sqlite_task_work_order_build(store, request.workspace, req); rc != sql.OK do return rc}
		if rc = sqlite_task_work_order(store, req); rc != sql.OK do return rc
	}
	// The candidate set does not change while ranking. Its validated cached
	// total applies to every page; count only a rebuilt selection, before cursors.
	if !cached_count {
		s: ^sql.Statement
		rc := sql.OK
		if work {rc = sql.prepare_v2(store.db, "SELECT count(*) FROM temp.nrc_work", -1, &s, nil)} else {
			filter := sqlite_task_query_filter(req); defer delete(filter)
			query := fmt.aprintf("SELECT count(*)%s", filter)
			defer delete(query)
			s, rc = sqlite_prepare_task_query(store, request.workspace, req, query)
		}
		defer if s != nil do sql.finalize(s)
		if rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.ROW do return rc
		n := sql.column_int64(s, 0); if n > i64(max(u32)) do return sql.TOOBIG
		page.total_count = u32(n)
	}
	number, text, missing := "0", "x''", "0"
	#partial switch req.sort {
	case .Priority:
		number = "t.priority"
	case .Status:
		number = "t.status"
	case .Assignee:
		text = "t.assignee"
	case .DueAt:
		number = "t.due_at"; missing = "t.due_at=0"
	case .CreatedAt:
		number = "t.created_at"
	case .Title:
		text = "t.title"
	case .Color:
		number = "t.color"
	case .Project:
		text = "t.project"
	}
	direction := req.descending ? "DESC" : "ASC"
	comparison := req.descending ? "<" : ">"
	filter := sqlite_task_query_filter(req, ordered = true); defer delete(filter)
	query := fmt.aprintf(
		`SELECT id,n,v,m FROM (SELECT t.id,%s AS n,%s AS v,(%s) AS m%s)
 WHERE NOT ?15 OR m>?16 OR (m=?16 AND (n%s?17 OR (n=?17 AND (v%s?18 OR (v=?18 AND id>?19)))))
 ORDER BY m,n %s,v %s,id LIMIT ?20`,
		number,
		text,
		missing,
		filter,
		comparison,
		comparison,
		direction,
		direction,
	)
	defer delete(query)
	s: ^sql.Statement
	rc := sql.OK
	if work {
		rc = sql.prepare_v2(
			store.db,
			`SELECT id,position,x'',0 FROM temp.nrc_work WHERE position>
 CASE WHEN ?1 THEN coalesce((SELECT position FROM temp.nrc_work WHERE id=?2),max(0,?3)) ELSE 0 END ORDER BY position LIMIT ?4`,
			-1,
			&s,
			nil,
		)
		if rc == sql.OK {rc = sql.bind_int64(s, 1, req.has_cursor ? 1 : 0)}
		if rc == sql.OK {rc = sql.bind_id(s, 2, req.cursor_task_id)}
		if rc == sql.OK {rc = sql.bind_int64(s, 3, req.cursor_number)}
		if rc == sql.OK {rc = sql.bind_int64(s, 4, i64(req.limit) + 1)}
	} else {
		s, rc = sqlite_prepare_task_query(store, request.workspace, req, query)
		if rc == sql.OK {rc = sql.bind_int64(s, 15, req.has_cursor ? 1 : 0)}
		if rc == sql.OK {rc = sql.bind_int64(s, 16, req.sort == .DueAt && req.cursor_number == 0 ? 1 : 0)}
		if rc == sql.OK {rc = sql.bind_int64(s, 17, req.cursor_number)}
		if rc == sql.OK {rc = sql.bind_bytes(s, 18, req.cursor_text)}
		if rc == sql.OK {rc = sql.bind_id(s, 19, req.cursor_task_id)}
		if rc == sql.OK {rc = sql.bind_int64(s, 20, i64(req.limit) + 1)}
	}
	defer if s != nil do sql.finalize(s)
	if rc != sql.OK do return rc
	tasks := make([dynamic]pr.Task, 0, int(req.limit))
	defer {for &task in tasks do db.destroy_task(&task); delete(tasks); delete(page.next_cursor_text)}
	size := pr.getSizeTaskQueryPage(page)
	budget := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for {
		rc = sql.step(s); if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if len(tasks) == int(req.limit) {page.has_more = true; break}
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		task, found, read_rc := db.get_task(store, request.workspace, 0, id, max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
		adopted := false; defer if !adopted do db.destroy_task(&task)
		if read_rc != sql.OK do return read_rc
		if !found do return sql.CORRUPT
		cursor := sql.column_bytes_view(s, 2)
		next_size := size + pr.getSizeTask(task) + len(cursor) - len(page.next_cursor_text)
		if next_size > budget {if len(tasks) == 0 do return sql.TOOBIG; page.has_more = true; break}
		append(&tasks, task); adopted = true; size = next_size
		delete(page.next_cursor_text); page.next_cursor_text = transmute([]byte)strings.clone(string(cursor))
		page.next_cursor_number = sql.column_int64(s, 1); page.next_cursor_task_id = id
	}
	page.tasks = tasks[:]
	buf, frame_rc := db.command_frame(output, size); if frame_rc != sql.OK do return frame_rc
	if pr.serializeTaskQueryPage(page, buf) != len(buf) do return sql.CONSTRAINT
	if work {
		_, save_rc := sqlite_work_order_cache(store, request.workspace, req, &page.total_count, save = true)
		if save_rc != sql.OK do return save_rc
		cache_saved = true
	}
	return sql.OK
}
