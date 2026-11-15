package workspace_db

import pr "../protocol"
import sql "../sqlite"
import "core:c"
import "core:fmt"

Create_Task_Error :: enum {
	None,
	Invalid_Task,
	Column_Full,
}

// Called inside the executor's write transaction. All reads and writes,
// including both sequence floors and history, commit or roll back together.
// The task is owned by the job, not a worker receive buffer.
create_task :: proc(store: ^Store, workspace: string, task: ^pr.Task, subject: string) -> (c.int, Create_Task_Error) {
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE, .None
	if task.conv_id != pr.WORKSPACE_DATA_ID || len(task.title) == 0 do return sql.CONSTRAINT, .Invalid_Task
	// Verify that the post-commit ACK is representable before changing anything.
	size := pr.getSizeTaskCreated({task = task^})
	if size > pr.MAX_PROTOCOL_PAYLOAD_SIZE do return sql.TOOBIG, .Invalid_Task
	buffer := make([]byte, size)
	defer delete(buffer)
	if pr.serializeTaskCreated({task = task^}, buffer) != size do return sql.CONSTRAINT, .Invalid_Task
	statement, rc := prepare(store, "SELECT coalesce(max(order_index)+1,0) FROM tasks WHERE workspace=?1 AND status=?2")
	if rc != sql.OK do return rc, .None
	defer sql.finalize(statement)
	if rc = sql.bind_bytes(statement, 1, transmute([]byte)workspace); rc != sql.OK do return rc, .None
	if rc = sql.bind_int64(statement, 2, i64(task.status)); rc != sql.OK do return rc, .None
	if rc = sql.step(statement); rc != sql.ROW do return rc, .None
	order := sql.column_int64(statement, 0)
	if order > i64(max(u16)) do return sql.FULL, .Column_Full
	task.order_index = u16(order)
	task.id, rc = next_id(store)
	if rc != sql.OK do return rc, .None
	if rc = put_task(store, workspace, task); rc != sql.OK do return rc, .None
	return append_task_created_history(store, workspace, task, subject), .None
}

append_task_created_history :: proc(store: ^Store, workspace: string, task: ^pr.Task, subject: string, system_unblock := false) -> c.int {
	entity_text := fmt.aprintf("%d", task.id); defer delete(entity_text)
	timestamp := fmt.aprintf("%d", task.created_at); defer delete(timestamp)
	label := pr.history_short_label(string(task.title), context.allocator); defer delete(label)
	actor_id := subject
	service_actor := ""
	defer delete(service_actor)
	if actor_id == "" {service_actor = fmt.aprintf("service:%s", string(task.created_by)); actor_id = service_actor}
	fields := pr.TASK_CREATED_HISTORY_FIELDS
	count := len(fields)
	if system_unblock {
		for field, i in fields {if field == "blocked_by" {copy(fields[i:], fields[i + 1:]); count -= 1; break}}
	}
	event := pr.History_Event {
		timestamp    = timestamp,
		actor_id     = actor_id,
		actor_name   = string(task.created_by),
		entity_type  = "task",
		entity_id    = entity_text,
		entity_label = label,
		action       = "created",
		fields       = fields[:count],
	}
	if rc := append_history_event(store, workspace, event, {1, task.id}); rc != sql.OK do return rc
	if system_unblock {
		event.actor_id = "system"; event.actor_name = "System"; event.action = "updated"; event.fields = {"blocked_by"}
		return append_history_event(store, workspace, event, {1, task.id})
	}
	return sql.OK
}
