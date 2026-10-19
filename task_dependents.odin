package main

import "btree"
import "byte_pool"
import pr "protocol"

// Seek only the requested parent's range. No total count or unrelated scan.
collect_task_dependents_page :: proc(conv: ^Conversation_State, req: pr.ListTaskDependentsRequest, tasks: ^[dynamic]pr.Task) -> pr.TaskDependentsPage {
	page := pr.TaskDependentsPage {
		conv_id        = req.conv_id,
		task_id        = req.task_id,
		correlation_id = req.correlation_id,
	}
	if conv == nil || conv.tasks[req.task_id] == nil {
		page.error = transmute([]byte)string("task_not_found")
		return page
	}
	page.success = true
	size := pr.getSizeTaskDependentsPage(page)
	it := btree.iter(&conv.task_blockers)
	defer btree.iter_destroy(&it)
	for found := btree.iter_seek(&it, Entity_Reference_Key{parent_id = u64(req.task_id), entity_id = u64(req.after_task_id)});
	    found;
	    found = btree.iter_next(&it) {
		key := btree.item(&it)
		if key.parent_id != u64(req.task_id) do break
		if key.entity_id <= u64(req.after_task_id) do continue
		task := conv.tasks[pr.TaskID(key.entity_id)]
		if task == nil do continue
		item_size := pr.getSizeTask(task^)
		if len(tasks) >= int(req.limit) || size + item_size > MAX_PROTOCOL_PAYLOAD_SIZE {
			if len(tasks) == 0 {
				page.success = false
				page.error = transmute([]byte)string("task_exceeds_page_byte_limit")
			} else {page.has_more = true}
			break
		}
		append(tasks, task^)
		size += item_size
		page.next_task_id = task.id
	}
	page.tasks = tasks[:]
	return page
}

process_list_task_dependents :: proc(c: ^NRC_Connection, req: pr.ListTaskDependentsRequest) {
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	tasks := make([dynamic]pr.Task, 0, int(req.limit))
	defer delete(tasks)
	page := collect_task_dependents_page(conv, req, &tasks)
	buf, header_len := allocate_websocket_frame_buffer(pr.getSizeTaskDependentsPage(page), "task dependents page")
	if buf == nil do return
	written := pr.serializeTaskDependentsPage(page, buf[header_len:])
	if written > 0 {_ = send_pooled_buffer(c, buf[:header_len + written])} else {byte_pool.release(td.spool, buf)}
}
