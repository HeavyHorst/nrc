package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"

// Storage primitives, not protocol handlers: authorization, domain validation,
// cascades and history will be composed by the executor's transaction handlers.
// Mutators require an explicit transaction; on any error the caller must roll
// back the entire operation rather than commit partially updated projections.
put_task :: proc(store: ^Store, workspace: string, task: ^pr.Task) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	if task.conv_id != 0 do return sql.CONSTRAINT
	if len(task.attachments) > pr.MAX_ATTACHMENTS_PER_TASK do return sql.CONSTRAINT
	statement, rc := prepare(
		store,
		`INSERT INTO tasks VALUES
		(?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18)
		ON CONFLICT(workspace, id) DO UPDATE SET
		title=excluded.title, description=excluded.description, status=excluded.status,
		order_index=excluded.order_index, assignee=excluded.assignee, priority=excluded.priority,
		color=excluded.color, created_by=excluded.created_by, created_at=excluded.created_at,
		updated_at=excluded.updated_at, external_ref=excluded.external_ref, due_at=excluded.due_at,
		blocked_by=excluded.blocked_by, completed_at=excluded.completed_at,
		completed_by=excluded.completed_by, project=excluded.project`,
	)
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = bind_task_key(statement, workspace, task.id); rc != sql.OK do return rc
	for field in ([7]struct {
			index: c.int,
			bytes: []byte,
		}{{3, task.title}, {4, task.description}, {7, task.assignee}, {10, task.created_by}, {13, task.external_ref}, {17, task.completed_by}, {18, task.project}}) {
		if rc = sql.bind_bytes(statement, field.index, field.bytes); rc != sql.OK do return rc
	}
	for field in ([8]struct {
			index: c.int,
			value: i64,
		}{{5, i64(task.status)}, {6, i64(task.order_index)}, {8, i64(task.priority)}, {9, i64(task.color)}, {11, task.created_at}, {12, task.updated_at}, {14, task.due_at}, {16, task.completed_at}}) {
		if rc = sql.bind_int64(statement, field.index, field.value); rc != sql.OK do return rc
	}
	if rc = sql.bind_id(statement, 15, task.blocked_by); rc != sql.OK do return rc
	if rc = sql.step(statement); rc != sql.DONE do return rc
	if rc = delete_task_attachments(store, workspace, task.id); rc != sql.OK do return rc
	attachment_statement, attachment_rc := prepare(store, "INSERT INTO task_attachments VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)")
	if attachment_rc != sql.OK do return attachment_rc
	defer sql.finalize(attachment_statement)
	for attachment, ordinal in task.attachments {
		if rc = bind_task_key(attachment_statement, workspace, task.id); rc != sql.OK do return rc
		if rc = sql.bind_int64(attachment_statement, 3, i64(ordinal)); rc != sql.OK do return rc
		if rc = sql.bind_bytes(attachment_statement, 4, attachment.file_id); rc != sql.OK do return rc
		if rc = sql.bind_bytes(attachment_statement, 5, attachment.filename); rc != sql.OK do return rc
		if rc = sql.bind_id(attachment_statement, 6, attachment.size); rc != sql.OK do return rc
		if rc = sql.bind_bytes(attachment_statement, 7, attachment.mime_type); rc != sql.OK do return rc
		if rc = sql.bind_int64(attachment_statement, 8, attachment.uploaded_at); rc != sql.OK do return rc
		if rc = sql.step(attachment_statement); rc != sql.DONE do return rc
		if rc = sql.reset(attachment_statement); rc != sql.OK do return rc
	}
	return advance_floor(store, max(task.id, task.blocked_by))
}

remove_task :: proc(store: ^Store, workspace: string, scope, id: u64) -> c.int {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	if scope != 0 do return sql.CONSTRAINT
	statement, rc := prepare(store, "DELETE FROM tasks WHERE workspace=?1 AND id=?2")
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = bind_task_key(statement, workspace, id); rc != sql.OK do return rc
	rc = sql.step(statement)
	return rc == sql.DONE ? sql.OK : rc
}

// Returns an owned task, including all byte fields and attachments. No row
// pointers escape SQLite. The caller frees it with destroy_task using the same
// allocator; it can outlive this connection. Missing records are (zero,false,OK).
// validate_only runs the same checks without copying fields or attachments;
// it returns an empty task even when found is true.
get_task :: proc(
	store: ^Store,
	workspace: string,
	scope, id: u64,
	allocator := context.allocator,
	max_bytes := max(int),
	validate_only := false,
) -> (
	task: pr.Task,
	found: bool,
	status: c.int,
) {
	context.allocator = allocator
	if scope != 0 do return {}, false, sql.CONSTRAINT
	// Keep task and attachment reads in one snapshot, also when called outside
	// an existing write transaction. Never hold this snapshot across a queue wait.
	read_transaction := sql.get_autocommit(store.db) != 0
	if read_transaction {
		if status = execute(store, "BEGIN"); status != sql.OK do return
	}
	task, found, status = read_task(store, workspace, id, max_bytes, validate_only)
	if read_transaction {
		end_status := rollback(store)
		if status == sql.OK do status = end_status
	}
	if status != sql.OK {
		destroy_task(&task, allocator)
		found = false
	}
	return
}

@(private)
read_task :: proc(store: ^Store, workspace: string, id: u64, max_bytes: int, validate_only: bool) -> (task: pr.Task, found: bool, status: c.int) {
	statement, rc := prepare(
		store,
		`SELECT title, description, status, order_index, assignee,
		priority, color, created_by, created_at, updated_at, external_ref, due_at,
		blocked_by, completed_at, completed_by, project
		FROM tasks WHERE workspace=?1 AND id=?2`,
	)
	if rc != sql.OK do return task, false, rc
	defer sql.finalize(statement)
	if rc = bind_task_key(statement, workspace, id); rc != sql.OK do return task, false, rc
	rc = sql.step(statement)
	if rc == sql.DONE do return task, false, sql.OK
	if rc != sql.ROW do return task, false, rc
	// Bound owned output before copying it out of SQLite. SQLite's own page
	// and statement memory is separate from these transport credits.
	if max_bytes < size_of(pr.Task) do return task, false, sql.TOOBIG
	remaining := max_bytes - size_of(pr.Task)
	for column in ([7]c.int{0, 1, 4, 7, 10, 14, 15}) {
		length := int(sql.column_bytes(statement, column))
		if length > remaining do return task, false, sql.TOOBIG
		remaining -= length
	}
	task.blocked_by, rc = sql.column_id(statement, 12)
	if rc != sql.OK do return task, false, rc
	if !validate_only {
		task.id = id
		task.title = copy_column(statement, 0)
		task.description = copy_column(statement, 1)
		task.status = pr.TaskStatus(sql.column_int64(statement, 2))
		task.order_index = u16(sql.column_int64(statement, 3))
		task.assignee = copy_column(statement, 4)
		task.priority = u8(sql.column_int64(statement, 5))
		task.color = pr.TaskColor(sql.column_int64(statement, 6))
		task.created_by = copy_column(statement, 7)
		task.created_at = sql.column_int64(statement, 8)
		task.updated_at = sql.column_int64(statement, 9)
		task.external_ref = copy_column(statement, 10)
		task.due_at = sql.column_int64(statement, 11)
		task.completed_at = sql.column_int64(statement, 13)
		task.completed_by = copy_column(statement, 14)
		task.project = copy_column(statement, 15)
	}
	attachments, attachments_rc := prepare(
		store,
		`SELECT file_id, filename, size, mime_type, uploaded_at
		FROM task_attachments WHERE workspace=?1 AND task_id=?2 ORDER BY ordinal`,
	)
	if attachments_rc != sql.OK do return task, false, attachments_rc
	defer sql.finalize(attachments)
	if rc = bind_task_key(attachments, workspace, id); rc != sql.OK do return task, false, rc
	items: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	count := 0
	transferred := false
	defer if !transferred {
		for item in items[:count] {delete(item.file_id); delete(item.filename); delete(item.mime_type)}
	}
	for {
		rc = sql.step(attachments)
		if rc == sql.DONE do break
		if rc != sql.ROW do return task, false, rc
		if count == len(items) do return task, false, sql.CORRUPT
		if remaining < size_of(pr.Attachment) do return task, false, sql.TOOBIG
		remaining -= size_of(pr.Attachment)
		for column in ([3]c.int{0, 1, 3}) {
			length := int(sql.column_bytes(attachments, column))
			if length > remaining do return task, false, sql.TOOBIG
			remaining -= length
		}
		size, size_rc := sql.column_id(attachments, 2)
		if size_rc != sql.OK do return task, false, size_rc
		if !validate_only {
			items[count] = pr.Attachment {
				file_id     = copy_column(attachments, 0),
				filename    = copy_column(attachments, 1),
				size        = size,
				mime_type   = copy_column(attachments, 3),
				uploaded_at = sql.column_int64(attachments, 4),
			}
		}
		count += 1
	}
	if validate_only do return {}, true, sql.OK
	task.attachments = make([]pr.Attachment, count)
	copy(task.attachments, items[:count])
	transferred = true
	return task, true, sql.OK
}

destroy_task :: proc(task: ^pr.Task, allocator := context.allocator) {
	delete(task.title, allocator); delete(task.description, allocator); delete(task.assignee, allocator)
	delete(task.created_by, allocator); delete(task.external_ref, allocator); delete(task.completed_by, allocator); delete(task.project, allocator)
	for attachment in task.attachments {
		delete(attachment.file_id, allocator); delete(attachment.filename, allocator); delete(attachment.mime_type, allocator)
	}
	delete(task.attachments, allocator)
	task^ = {}
}

@(private)
copy_column :: proc(statement: ^sql.Statement, column: c.int) -> []byte {
	view := sql.column_bytes_view(statement, column)
	owned := make([]byte, len(view))
	copy(owned, view)
	return owned
}

@(private)
bind_task_key :: proc(statement: ^sql.Statement, workspace: string, id: u64) -> c.int {
	if rc := sql.bind_bytes(statement, 1, transmute([]byte)workspace); rc != sql.OK do return rc
	return sql.bind_id(statement, 2, id)
}

@(private)
delete_task_attachments :: proc(store: ^Store, workspace: string, id: u64) -> c.int {
	statement, rc := prepare(store, "DELETE FROM task_attachments WHERE workspace=?1 AND task_id=?2")
	if rc != sql.OK do return rc
	defer sql.finalize(statement)
	if rc = bind_task_key(statement, workspace, id); rc != sql.OK do return rc
	rc = sql.step(statement)
	return rc == sql.DONE ? sql.OK : rc
}
