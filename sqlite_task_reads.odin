package main

import "core:c"
import "core:strings"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_list_task_dependents :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListTaskDependentsRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	page := pr.TaskDependentsPage {
		task_id        = req.task_id,
		correlation_id = req.correlation_id,
	}
	// Check existence without loading the parent's body or attachments. A missing
	// parent differs from an existing parent with no dependents, even after EOF.
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT 1 FROM tasks WHERE workspace=?1 AND id=?2", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 2, req.task_id); rc != sql.OK do return rc
		rc = sql.step(s)
		if rc != sql.ROW && rc != sql.DONE do return rc
		page.success = rc == sql.ROW
	}
	if !page.success {
		page.error = transmute([]byte)string("task_not_found")
		buf, rc := db.command_frame(output, pr.getSizeTaskDependentsPage(page))
		if rc != sql.OK do return rc
		return pr.serializeTaskDependentsPage(page, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
	}
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "SELECT id FROM tasks WHERE workspace=?1 AND blocked_by=?2 AND id>?3 ORDER BY id LIMIT ?4", -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 2, req.task_id); rc != sql.OK do return rc
	if rc = sql.bind_id(s, 3, req.after_task_id); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 4, i64(req.limit) + 1); rc != sql.OK do return rc
	tasks, alloc_err := make([]pr.Task, int(req.limit))
	if alloc_err != nil do return sql.NOMEM
	count := 0
	defer {for &task in tasks[:count] do db.destroy_task(&task); delete(tasks)}
	size := pr.getSizeTaskDependentsPage(page)
	limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for {
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if count == len(tasks) {page.has_more = true; break}
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		task, found, task_rc := db.get_task(store, request.workspace, 0, id, max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
		adopted := false
		defer if !adopted do db.destroy_task(&task)
		if task_rc != sql.OK do return task_rc
		if !found do return sql.CORRUPT
		task_size := pr.getSizeTask(task)
		if task_size > limit - size {
			if count == 0 {
				page.success = false
				page.error = transmute([]byte)string("task_exceeds_page_byte_limit")
			} else {page.has_more = true}
			break
		}
		tasks[count] = task; adopted = true; count += 1; size += task_size
		page.next_task_id = id
	}
	page.tasks = tasks[:count]
	buf, frame_rc := db.command_frame(output, pr.getSizeTaskDependentsPage(page))
	if frame_rc != sql.OK do return frame_rc
	return pr.serializeTaskDependentsPage(page, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_list_tasks_paged :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListTasksPagedRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	page := pr.TaskListPage {
		success        = true,
		correlation_id = req.correlation_id,
	}
	// Count and page share the executor transaction. Force the ordered index:
	// the status index otherwise encourages a full sort before applying LIMIT.
	{
		s: ^sql.Statement
		rc := sql.prepare_v2(store.db, "SELECT count(*) FROM tasks WHERE workspace=?1 AND status BETWEEN 0 AND 4 AND (?2 & (1 << status)) != 0", -1, &s, nil)
		if rc != sql.OK do return rc
		defer sql.finalize(s)
		if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
		if rc = sql.bind_int64(s, 2, i64(req.status_mask)); rc != sql.OK do return rc
		if rc = sql.step(s); rc != sql.ROW do return rc
		count := sql.column_int64(s, 0)
		if count > i64(max(u32)) do return sql.TOOBIG
		page.total_count = u32(count)
	}
	query: cstring = `SELECT id,CASE WHEN status=3 THEN completed_at ELSE updated_at END AS sort_at
	 FROM tasks INDEXED BY tasks_page WHERE workspace=?1
	 AND status BETWEEN 0 AND 4 AND (?2 & (1 << status)) != 0
	 ORDER BY sort_at DESC,id DESC LIMIT ?3`
	// SQLite does not use expression-index tuple inequalities as range seeks.
	// Split equal-time IDs and older timestamps into disjoint, bounded seeks.
	if req.has_cursor do query = `SELECT id,sort_at FROM (
	 SELECT id,CASE WHEN status=3 THEN completed_at ELSE updated_at END AS sort_at
	 FROM tasks INDEXED BY tasks_page WHERE workspace=?1
	 AND status BETWEEN 0 AND 4 AND (?2 & (1 << status)) != 0
	 AND CASE WHEN status=3 THEN completed_at ELSE updated_at END=?4 AND id<?5
	 ORDER BY id DESC LIMIT ?3)
	 UNION ALL SELECT id,sort_at FROM (
	 SELECT id,CASE WHEN status=3 THEN completed_at ELSE updated_at END AS sort_at
	 FROM tasks INDEXED BY tasks_page WHERE workspace=?1
	 AND status BETWEEN 0 AND 4 AND (?2 & (1 << status)) != 0
	 AND CASE WHEN status=3 THEN completed_at ELSE updated_at END<?4
	 ORDER BY sort_at DESC,id DESC LIMIT ?3)
	 ORDER BY sort_at DESC,id DESC LIMIT ?3`
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 2, i64(req.status_mask)); rc != sql.OK do return rc
	if rc = sql.bind_int64(s, 3, i64(req.limit) + 1); rc != sql.OK do return rc
	if req.has_cursor {
		if rc = sql.bind_int64(s, 4, req.cursor_sort_at); rc != sql.OK do return rc
		if rc = sql.bind_id(s, 5, req.cursor_task_id); rc != sql.OK do return rc
	}
	// Bounded by protocol page count and serialized bytes, not workspace size.
	tasks, alloc_err := make([]pr.Task, int(req.limit))
	if alloc_err != nil do return sql.NOMEM
	count := 0
	defer {for &task in tasks[:count] do db.destroy_task(&task); delete(tasks)}
	size := pr.getSizeTaskListPage(page)
	limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	for {
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		if count == len(tasks) {page.has_more = true; break}
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		task, found, task_rc := db.get_task(store, request.workspace, 0, id, max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
		adopted := false
		defer if !adopted do db.destroy_task(&task)
		if task_rc != sql.OK do return task_rc
		if !found do return sql.CORRUPT
		task_size := pr.getSizeTask(task)
		if task_size > limit - size {
			if count == 0 do return sql.TOOBIG
			page.has_more = true; break
		}
		tasks[count] = task; adopted = true; count += 1; size += task_size
		page.next_cursor_sort_at = sql.column_int64(s, 1); page.next_cursor_task_id = id
	}
	page.tasks = tasks[:count]
	buf, frame_rc := db.command_frame(output, size)
	if frame_rc != sql.OK do return frame_rc
	return pr.serializeTaskListPage(page, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_get_tasks :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseGetTasksRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, "SELECT id FROM tasks WHERE workspace=?1 ORDER BY priority DESC,order_index,id LIMIT ?2", -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	limit := min(pr.MAX_PROTOCOL_PAYLOAD_SIZE, output.limit - size_of(db.Command_Frame))
	if limit < pr.getSizeTaskListResponse({}) do return sql.TOOBIG
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	// Even the SQL sorter only needs enough keys to fill one legal response.
	if rc = sql.bind_int64(s, 2, i64(limit / pr.getSizeTask({}) + 1)); rc != sql.OK do return rc
	tasks: [dynamic]pr.Task
	defer {for &task in tasks do db.destroy_task(&task); delete(tasks)}
	size := pr.getSizeTaskListResponse({})
	for {
		rc = sql.step(s)
		if rc == sql.DONE do break
		if rc != sql.ROW do return rc
		id, id_rc := sql.column_id(s, 0); if id_rc != sql.OK do return id_rc
		task, found, task_rc := db.get_task(store, request.workspace, 0, id, max_bytes = 2 * pr.MAX_PROTOCOL_PAYLOAD_SIZE)
		adopted := false
		defer if !adopted do db.destroy_task(&task)
		if task_rc != sql.OK do return task_rc
		if !found do return sql.CORRUPT
		task_size := pr.getSizeTask(task)
		if task_size > limit - size do return sqlite_task_command_error(output, req.correlation_id, "Task list exceeds transport limit; use paged task queries")
		if _, alloc_err := append(&tasks, task); alloc_err != nil do return sql.NOMEM
		adopted = true; size += task_size
	}
	buf, frame_rc := db.command_frame(output, size)
	if frame_rc != sql.OK do return frame_rc
	msg := pr.TaskListResponse {
		success        = true,
		tasks          = tasks[:],
		correlation_id = req.correlation_id,
	}
	return pr.serializeTaskListResponse(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_list_task_facets :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	req, err := pr.parseListTaskProjectsRequest(request.body)
	if err != nil || req.conv_id != 0 do return sql.CONSTRAINT
	query: cstring = "SELECT DISTINCT project FROM tasks INDEXED BY tasks_project WHERE workspace=?1 AND project>x'' ORDER BY project"
	opcode := pr.Opcode.S_TaskProjects
	#partial switch request.opcode {
	case .C_ListTaskAssignees:
		query = "SELECT DISTINCT assignee FROM tasks INDEXED BY tasks_assignee WHERE workspace=?1 AND assignee>x'' ORDER BY assignee"
		opcode = .S_TaskAssignees
	case .C_ListSliceOwners:
		query = "SELECT DISTINCT owner FROM slice_metadata INDEXED BY slice_owner WHERE workspace=?1 AND owner>x'' ORDER BY owner"
		opcode = .S_SliceOwners
	case .C_ListTicketAssignees:
		query = "SELECT DISTINCT assignee FROM ticket_metadata INDEXED BY ticket_assignee WHERE workspace=?1 AND assignee>x'' ORDER BY assignee"
		opcode = .S_TicketAssignees
	case .C_ListCalendarPeople:
		query = `SELECT person FROM appointment_people INDEXED BY appointment_person WHERE workspace=?1 AND person>x''
 UNION SELECT assignee FROM tasks INDEXED BY tasks_assignee WHERE workspace=?1 AND assignee>x'' ORDER BY 1`
		opcode = .S_CalendarPeople
	}
	s: ^sql.Statement
	rc := sql.prepare_v2(store.db, query, -1, &s, nil)
	if rc != sql.OK do return rc
	defer sql.finalize(s)
	if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
	// SQL supplies distinct byte-ordered names. Only one bounded chunk is copied
	// at a time; prepared frames remain covered by the admission result credit.
	names: [128]string
	count := 0
	defer for name in names[:count] do delete(name)
	size := pr.getSizeTaskProjects({})
	for {
		rc = sql.step(s)
		if rc != sql.ROW && rc != sql.DONE do return rc
		name := rc == sql.ROW ? string(sql.column_bytes_view(s, 0)) : ""
		if len(name) > pr.MAX_PROJECT_LENGTH do return sql.CONSTRAINT
		if rc == sql.DONE || count == len(names) || size + 2 + len(name) > pr.MAX_PROTOCOL_PAYLOAD_SIZE {
			msg := pr.TaskProjects {
				projects       = names[:count],
				has_more       = rc != sql.DONE,
				correlation_id = req.correlation_id,
			}
			buf, frame_rc := db.command_frame(output, size)
			if frame_rc != sql.OK do return frame_rc
			if pr.serializeTaskProjects(msg, buf, opcode) != len(buf) do return sql.CONSTRAINT
			for value in names[:count] do delete(value)
			count = 0; size = pr.getSizeTaskProjects({})
			if rc == sql.DONE do return sql.OK
		}
		names[count] = strings.clone(name); count += 1; size += 2 + len(name)
	}
}
