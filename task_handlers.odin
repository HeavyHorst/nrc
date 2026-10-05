//
// task_handlers.odin - Task/Kanban Message Processing
//
// This file contains handlers for task/kanban protocol messages including:
// - CreateTask: Creates a new task in a conversation
// - UpdateTask: Updates task title, description, status, assignee, priority
// - DeleteTask: Removes a task from a conversation
// - MoveTask: Optimized drag-drop reordering (status + order_index)
// - GetTasks: Retrieves all tasks for a conversation
//
package main

import "core:log"
import "core:mem"
import "core:net"
import "core:slice"

import "btree"
import "byte_pool"
import pr "protocol"

// ============================================================================
// String Field Update Helper
// ============================================================================

// Resolves string field updates using sentinel convention:
// - empty slice: no change (keep old value)
// - single null byte "\x00": explicit clear (return nil)
// - otherwise: use new value
resolve_string_field :: proc(new_value: []byte, old_value: []byte) -> []byte {
	if len(new_value) == 0 {
		return old_value
	}
	if len(new_value) == 1 && new_value[0] == 0 {
		return nil
	}
	return new_value
}

// ============================================================================
// Task ID Generation
// ============================================================================

generate_task_id :: proc() -> pr.TaskID {
	return pr.TaskID(td.task_seq + 1)
}

// ============================================================================
// CreateTask Handler
// ============================================================================

process_create_task :: proc(c: ^NRC_Connection, req: pr.CreateTaskRequest) {
	workspace_id := c.workspace_id

	// Validate title is non-empty
	if len(req.title) == 0 {
		send_task_list_error(c, req.conv_id, "Task title cannot be empty", req.correlation_id)
		return
	}

	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, req.conv_id)

	// Generate task ID and timestamps
	task_id := generate_task_id()
	now := nrc_time_unix_nanos()
	created_by := get_connection_nickname(c)

	// Use status from request (default Backlog, or Note for notes)
	initial_status := req.status

	// Calculate initial order_index (append to end of the target status column)
	order_index, column_ok := calculate_next_order_index(conv.tasks, initial_status)
	if !column_ok {
		send_task_list_error(c, req.conv_id, "Status column is full", req.correlation_id)
		return
	}

	// Create task with single allocation pattern
	task := alloc_task(req.title, req.description, nil, transmute([]byte)created_by, req.external_ref, nil, req.project, req.attachments)
	if task == nil {
		send_task_list_error(c, req.conv_id, "Failed to allocate task", req.correlation_id)
		return
	}
	task.id = task_id
	task.conv_id = req.conv_id
	task.status = initial_status
	task.order_index = order_index
	task.priority = req.priority
	task.color = req.color
	task.created_at = now
	task.updated_at = now
	task.due_at = req.due_at // 0 = no due date
	task.blocked_by = 0 // New tasks are not blocked
	task.completed_at = 0 // Not completed yet

	// Stage the WAL transaction before changing speculative in-memory state.
	// The outbox holds responses and broadcasts until the batch is fsynced.
	if !persist_task_created(workspace_id, task) {
		persistent_mutation_failed("task", "create", workspace_id)
		free_task(task)
		return
	}
	td.task_seq = u64(task_id)

	// Store task
	task_store_put(conv, task)

	when ODIN_DEBUG do debug_log("[T%d] Created task %v in conv %v workspace %s", td.thread_index, task_id, req.conv_id, workspace_id)

	// Send TaskCreated to requester (with correlation_id for request/response matching)
	send_task_created(c, task^, req.correlation_id)

	// Broadcast to other subscribers (correlation_id=0)
	broadcast_task_created(task^, c.sock, ws)
}

// ============================================================================
// UpdateTask Handler
// ============================================================================

process_update_task :: proc(c: ^NRC_Connection, req: pr.UpdateTaskRequest) {
	workspace_id := c.workspace_id

	// Direct O(1) lookup using conv_id from request
	old_task := get_task(workspace_id, req.conv_id, req.task_id)
	if old_task == nil {
		send_task_list_error(c, req.conv_id, "Task not found", req.correlation_id)
		return
	}

	// Determine new values for string fields
	// Convention: empty = no change, "\x00" = explicit clear, otherwise = new value
	new_title := resolve_string_field(req.title, old_task.title)
	new_description := resolve_string_field(req.description, old_task.description)
	new_assignee := resolve_string_field(req.assignee, old_task.assignee)
	new_external_ref := resolve_string_field(req.external_ref, old_task.external_ref)
	new_project := resolve_string_field(req.project, old_task.project)

	// Track previous status for completed_at/completed_by logic
	prev_status := old_task.status
	new_status := u8(req.status) != 255 ? req.status : old_task.status
	ws := get_connection_workspace(c)
	conv := get_conversation(ws, req.conv_id)

	// Determine completed_by based on status transition (must be done before alloc)
	new_completed_by: []byte
	if new_status == .Done && prev_status != .Done {
		new_completed_by = transmute([]byte)get_connection_nickname(c)
	} else if new_status != .Done && prev_status == .Done {
		new_completed_by = nil
	} else {
		new_completed_by = old_task.completed_by
	}

	// Allocate new task with updated strings (single allocation pattern).
	// Partial updates can preserve attachments with the wire sentinel.
	new_attachments := req.preserve_attachments ? old_task.attachments : req.attachments
	new_task := alloc_task(new_title, new_description, new_assignee, old_task.created_by, new_external_ref, new_completed_by, new_project, new_attachments)
	if new_task == nil {
		send_task_list_error(c, req.conv_id, "Failed to allocate task", req.correlation_id)
		return
	}

	// Copy non-string fields from old task
	new_task.id = old_task.id
	new_task.conv_id = old_task.conv_id
	new_task.status = old_task.status
	new_task.order_index = old_task.order_index
	new_task.priority = old_task.priority
	new_task.color = old_task.color
	new_task.created_at = old_task.created_at
	new_task.updated_at = old_task.updated_at
	new_task.due_at = old_task.due_at
	new_task.blocked_by = old_task.blocked_by
	new_task.completed_at = old_task.completed_at

	// Apply non-string field updates
	if u8(req.status) != 255 {
		new_task.status = req.status
	}
	if req.priority != 255 {
		new_task.priority = req.priority
	}
	if u8(req.color) != 255 {
		new_task.color = req.color
	}
	if req.due_at != 0 {
		new_task.due_at = req.due_at == -1 ? 0 : req.due_at
	}
	if req.blocked_by != 0 {
		new_task.blocked_by = req.blocked_by == max(pr.TaskID) ? 0 : req.blocked_by
	}

	// Auto-manage completed_at based on status transitions
	now := nrc_time_unix_nanos()
	if new_task.status == .Done && prev_status != .Done {
		new_task.completed_at = now
	} else if new_task.status != .Done && prev_status == .Done {
		new_task.completed_at = 0
	}

	// Update timestamp
	new_task.updated_at = now

	unblocks: [dynamic]pr.Task
	defer delete(unblocks)
	if new_task.status == .Done && prev_status != .Done {
		collect_task_unblocks(conv, new_task, &unblocks)
	}
	// Persist before swapping the in-memory owner or acknowledging the mutation.
	if persisted, too_large := persist_task_with_unblocks(workspace_id, new_task, .Update, unblocks[:]); !persisted {
		if too_large {
			send_task_list_error(c, req.conv_id, "Task completion exceeds atomic transaction size limit", req.correlation_id)
		} else {
			persistent_mutation_failed("task", "update", workspace_id)
		}
		free_task(new_task)
		return
	}

	// Swap into map and free old task
	task_store_put(conv, new_task)
	apply_task_unblocks(ws, unblocks[:])

	when ODIN_DEBUG do debug_log("[T%d] Updated task %v", td.thread_index, req.task_id)

	// Send TaskUpdated to requester
	send_task_updated(c, new_task^, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_task_updated(new_task^, c.sock, ws)
}

// ============================================================================
// DeleteTask Handler
// ============================================================================

process_delete_task :: proc(c: ^NRC_Connection, req: pr.DeleteTaskRequest) {
	workspace_id := c.workspace_id
	ws := get_connection_workspace(c)

	// Direct O(1) lookup using conv_id from request
	task := get_task(workspace_id, req.conv_id, req.task_id)
	if task == nil {
		send_task_list_error(c, req.conv_id, "Task not found", req.correlation_id)
		return
	}

	assets_to_delete := make([dynamic]pr.AssetID, 0, 16)
	defer delete(assets_to_delete)
	conv := get_conversation(ws, req.conv_id)
	collect_task_asset_delete_ids(conv, req.task_id, &assets_to_delete)

	asset_edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&asset_edges_to_delete)
	defer edge_delete_plan_destroy(&asset_edges_to_delete)
	for asset_id in assets_to_delete {
		collect_edges_for_entity_delete(conv, &asset_edges_to_delete, pr.TargetType.Asset, u64(asset_id))
	}
	task_edges_to_delete: Edge_Delete_Plan
	edge_delete_plan_init(&task_edges_to_delete)
	defer edge_delete_plan_destroy(&task_edges_to_delete)
	collect_edges_for_entity_delete_excluding(conv, &task_edges_to_delete, pr.TargetType.Task, u64(req.task_id), &asset_edges_to_delete)

	if td.shard_writers.mode == .Active {
		if 1 + len(assets_to_delete) + len(asset_edges_to_delete.edge_ids) + len(task_edges_to_delete.edge_ids) > SHARD_TRANSACTION_MAX_MUTATIONS {
			send_task_list_error(c, req.conv_id, "Task deletion exceeds atomic transaction size limit", req.correlation_id)
			return
		}
		workspace := transmute([]byte)workspace_id
		writer := shard_writer_for_workspace(&td.shard_writers, workspace)
		if writer == nil {
			persistent_mutation_failed("shard", "task delete owner", workspace_id)
			return
		}
		cascade, built := build_shard_task_delete_transaction(
			workspace,
			req.conv_id,
			req.task_id,
			assets_to_delete[:],
			asset_edges_to_delete.edge_ids[:],
			task_edges_to_delete.edge_ids[:],
			writer.floors,
		)
		if !built {
			persistent_mutation_failed("shard", "build task delete", workspace_id)
			return
		}
		defer destroy_shard_task_delete_transaction(&cascade)
		if !append_shard_transaction(writer, &cascade.tx) {
			persistent_mutation_failed("shard", "task delete", workspace_id)
			return
		}
		for edge_id in asset_edges_to_delete.edge_ids do apply_edge_delete_id(conv, ws, req.conv_id, edge_id, net.TCP_Socket(-1))
		for edge_id in task_edges_to_delete.edge_ids do apply_edge_delete_id(conv, ws, req.conv_id, edge_id, c.sock)
		for asset_id in assets_to_delete do apply_asset_delete_id(conv, ws, req.conv_id, asset_id)
	} else {
		// Apply the durable prefix as each tombstone is accepted. If a later tombstone
		// fails, RAM/client state reflects the already-persisted prefix and the server
		// fails closed.
		if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, req.conv_id, &asset_edges_to_delete, net.TCP_Socket(-1)) {
			return
		}
		if !persist_and_apply_edge_delete_plan(workspace_id, conv, ws, req.conv_id, &task_edges_to_delete, c.sock) {
			return
		}
		if !persist_and_apply_asset_delete_ids(workspace_id, conv, ws, req.conv_id, assets_to_delete[:]) {
			return
		}
		if !persist_task_deleted_kernel_accepted(workspace_id, req.conv_id, req.task_id) {
			persistent_mutation_failed("task", "delete", workspace_id)
			return
		}
	}

	// Remove from storage
	if conv != nil {
		// Free task memory (SINGLE OWNER PATTERN)
		task_store_remove(conv, req.task_id)
	}

	when ODIN_DEBUG do debug_log("[T%d] Deleted task %v", td.thread_index, req.task_id)

	// Send TaskDeleted to requester
	send_task_deleted(c, req.task_id, req.conv_id, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_task_deleted(req.task_id, req.conv_id, c.sock, ws)
}

// ============================================================================
// MoveTask Handler (Optimized drag-drop)
// ============================================================================

process_move_task :: proc(c: ^NRC_Connection, req: pr.MoveTaskRequest) {
	workspace_id := c.workspace_id
	ws := get_connection_workspace(c)

	// Direct O(1) lookup using conv_id from request
	old_task := get_task(workspace_id, req.conv_id, req.task_id)
	if old_task == nil {
		send_task_list_error(c, req.conv_id, "Task not found", req.correlation_id)
		return
	}

	// Track previous status for completed_at/completed_by logic
	prev_status := old_task.status
	now := nrc_time_unix_nanos()
	conv := get_conversation(ws, req.conv_id)

	// Determine completed_by based on status transition
	new_completed_by: []byte
	if req.status == .Done && prev_status != .Done {
		new_completed_by = transmute([]byte)get_connection_nickname(c)
	} else if req.status != .Done && prev_status == .Done {
		new_completed_by = nil
	} else {
		new_completed_by = old_task.completed_by
	}

	// Reallocate task if completed_by changes (string field in single-alloc block)
	completed_by_changed := len(new_completed_by) != len(old_task.completed_by)
	task: ^pr.Task

	if completed_by_changed {
		task = alloc_task(
			old_task.title,
			old_task.description,
			old_task.assignee,
			old_task.created_by,
			old_task.external_ref,
			new_completed_by,
			old_task.project,
			old_task.attachments,
		)
		if task == nil {
			send_task_list_error(c, req.conv_id, "Failed to allocate task", req.correlation_id)
			return
		}
		task.id = old_task.id
		task.conv_id = old_task.conv_id
		task.priority = old_task.priority
		task.color = old_task.color
		task.created_at = old_task.created_at
		task.due_at = old_task.due_at
		task.blocked_by = old_task.blocked_by
	} else {
		// Persist from a stack snapshot so the existing task is not mutated before WAL acceptance.
		task_snapshot := old_task^
		task = &task_snapshot
	}

	// Update status and order_index
	task.status = req.status
	task.order_index = req.order_index
	if .Append in req.flags {
		// The client asks for the end of the column instead of naming a position.
		// The server folds the column, so the position is not derived from a
		// client cache that may hold one page of it. The folded position is what
		// the acknowledgement and the broadcast carry.
		next_order, column_ok := calculate_next_order_index(conv.tasks, req.status)
		if !column_ok {
			send_task_list_error(c, req.conv_id, "Status column is full", req.correlation_id)
			if completed_by_changed {
				free_task(task)
			}
			return
		}
		task.order_index = next_order
	}

	// Auto-manage completed_at based on status transitions
	if task.status == .Done && prev_status != .Done {
		task.completed_at = now
	} else if task.status != .Done && prev_status == .Done {
		task.completed_at = 0
	}
	task.updated_at = now

	unblocks: [dynamic]pr.Task
	defer delete(unblocks)
	if task.status == .Done && prev_status != .Done {
		collect_task_unblocks(conv, task, &unblocks)
	}
	// Persist before mutating/replacing the in-memory task or acknowledging.
	if persisted, too_large := persist_task_with_unblocks(workspace_id, task, .Move, unblocks[:]); !persisted {
		if too_large {
			send_task_list_error(c, req.conv_id, "Task completion exceeds atomic transaction size limit", req.correlation_id)
		} else {
			persistent_mutation_failed("task", "move", workspace_id)
		}
		if completed_by_changed {
			free_task(task)
		}
		return
	}

	if completed_by_changed {
		task_store_put(conv, task)
	} else {
		task_store_move(conv, task)
	}
	apply_task_unblocks(ws, unblocks[:])

	when ODIN_DEBUG do debug_log("[T%d] Moved task %v to status %v order %v", td.thread_index, req.task_id, req.status, task.order_index)

	// Send TaskMoved to requester
	send_task_moved(c, req.task_id, req.conv_id, req.status, task.order_index, task.completed_at, task.completed_by, req.correlation_id)

	// Broadcast to other subscribers
	broadcast_task_moved(req.task_id, req.conv_id, req.status, task.order_index, task.completed_at, task.completed_by, c.sock, ws)
}

// ============================================================================
// GetTasks Handler
// ============================================================================

process_get_tasks :: proc(c: ^NRC_Connection, req: pr.GetTasksRequest) {
	// Collect tasks for the conversation
	tasks: [dynamic]pr.Task
	defer delete(tasks)

	ws := get_connection_workspace(c)
	if ws != nil {
		conv := get_conversation(ws, req.conv_id)
		if conv != nil {
			for _, task in conv.tasks {
				append(&tasks, task^)
			}
		}
	}

	// Sort by priority (descending) then order_index (ascending)
	// Note: Simple bubble sort is fine for <1000 tasks
	sort_tasks_by_priority_and_order(tasks[:])

	when ODIN_DEBUG do debug_log("[T%d] GetTasks for conv %v: %d tasks", td.thread_index, req.conv_id, len(tasks))

	// Send response
	send_task_list_response(c, req.conv_id, true, tasks[:], "", req.correlation_id)
}

Task_Page_Collection :: struct {
	has_more:            bool,
	next_cursor_sort_at: i64,
	next_cursor_task_id: pr.TaskID,
	total_count:         u32,
}

collect_task_page :: proc(conv: ^Conversation_State, req: pr.ListTasksPagedRequest, tasks: ^[dynamic]pr.Task) -> Task_Page_Collection {
	result: Task_Page_Collection
	if conv == nil || tasks == nil do return result

	indexed_count := 0
	for status in 0 ..< 4 {
		count := btree.count(&conv.task_status_indexes[status].trees[0][0])
		indexed_count += count
		if req.status_mask & (u8(1) << u8(status)) != 0 do result.total_count += u32(count)
	}
	if req.status_mask & (u8(1) << 4) != 0 {
		result.total_count += u32(btree.count(&conv.task_index) - indexed_count)
	}

	page_protocol_size := pr.getSizeTaskListPage(pr.TaskListPage{})
	it := btree.iter(&conv.task_index)
	defer btree.iter_destroy(&it)
	has_item := false
	if req.has_cursor {
		cursor := Task_Sort_Key {
			sort_at = req.cursor_sort_at,
			task_id = req.cursor_task_id,
		}
		has_item = btree.iter_seek(&it, cursor)
		if has_item {
			if task_sort_key_compare(cursor, btree.item(&it)) <= 0 do has_item = btree.iter_prev(&it)
		} else {
			has_item = btree.iter_last(&it)
		}
	} else {
		has_item = btree.iter_last(&it)
	}

	for has_item {
		key := btree.item(&it)
		task := conv.tasks[key.task_id]
		if task != nil && task_matches_status_mask(task, req.status_mask) {
			task_size := pr.getSizeTask(task^)
			if len(tasks) >= int(req.limit) || (len(tasks) > 0 && page_protocol_size + task_size > MAX_PROTOCOL_PAYLOAD_SIZE) {
				result.has_more = true
				break
			}
			append(tasks, task^)
			page_protocol_size += task_size
			result.next_cursor_sort_at = key.sort_at
			result.next_cursor_task_id = key.task_id
		}
		has_item = btree.iter_prev(&it)
	}
	return result
}

Task_Query_Collection :: struct {
	has_more:            bool,
	next_cursor_number:  i64,
	next_cursor_text:    []byte,
	next_cursor_task_id: pr.TaskID,
	total_count:         u32,
}

task_matches_query :: proc(task: ^pr.Task, req: pr.TaskQueryRequest) -> bool {
	if task == nil || !task_matches_status_mask(task, req.status_mask) do return false
	if req.color != 255 && u8(task.color) != req.color do return false
	if req.blocked == 1 && task.blocked_by == 0 do return false
	if req.blocked == 2 && task.blocked_by != 0 do return false
	if req.overdue_before != 0 && !(task.due_at > 0 && task.due_at < req.overdue_before && task.status != .Done) do return false
	if req.has_assignee && task_query_bytes_compare(task.assignee, req.assignee) != 0 do return false
	if req.has_project && task_query_bytes_compare(task.project, req.project) != 0 do return false
	return true
}

collect_task_query_page :: proc(conv: ^Conversation_State, req: pr.TaskQueryRequest, tasks: ^[dynamic]pr.Task) -> Task_Query_Collection {
	result: Task_Query_Collection
	if conv == nil || tasks == nil do return result
	set := &conv.task_query_indexes
	candidate_count := btree.count(&set.trees[0][0])
	if req.has_project {
		index := conv.task_project_indexes[string(req.project)]; if index == nil do return result
		count := btree.count(&index.indexes.trees[0][0])
		if count < candidate_count {set = &index.indexes; candidate_count = count}
	}
	if req.has_assignee {
		index := conv.task_assignee_indexes[string(req.assignee)]; if index == nil do return result
		count := btree.count(&index.indexes.trees[0][0])
		if count < candidate_count {set = &index.indexes; candidate_count = count}
	}
	// A single-status tree is often the narrowest available ordered scope.
	status_index := -1
	for status in 0 ..< 4 {if req.status_mask == (u8(1) << u8(status)) do status_index = status}
	if status_index >= 0 {
		count := btree.count(&conv.task_status_indexes[status_index].trees[0][0])
		if count < candidate_count {set = &conv.task_status_indexes[status_index]; candidate_count = count}
	}
	tree := task_query_index_set_ensure_order(set, &conv.tasks, req.sort, req.descending)
	fully_covered :=
		req.color == 255 &&
		req.blocked == 0 &&
		req.overdue_before == 0 &&
		(!req.has_project || set == &conv.task_project_indexes[string(req.project)].indexes) &&
		(!req.has_assignee || set == &conv.task_assignee_indexes[string(req.assignee)].indexes) &&
		(req.status_mask == 0x0f || (status_index >= 0 && set == &conv.task_status_indexes[status_index]))
	if fully_covered do result.total_count = u32(candidate_count)
	it := btree.iter(tree); defer btree.iter_destroy(&it)
	has_item := false
	if req.has_cursor {
		cursor := Task_Query_Key {
			number      = req.cursor_number,
			text        = req.cursor_text,
			due_missing = req.sort == .DueAt && req.cursor_number == 0,
			task_id     = req.cursor_task_id,
		}
		has_item = btree.iter_seek(&it, cursor)
		if has_item && (req.descending ? task_query_key_compare_desc(btree.item(&it), cursor) : task_query_key_compare_asc(btree.item(&it), cursor)) <= 0 do has_item = btree.iter_next(&it)
	} else {has_item = btree.iter_first(&it)}
	// Count all candidates when residual predicates remain, while only paging rows after the cursor.
	if !fully_covered {
		count_it := btree.iter(tree); defer btree.iter_destroy(&count_it)
		for found := btree.iter_first(&count_it);
		    found;
		    found = btree.iter_next(&count_it) {task := conv.tasks[btree.item(&count_it).task_id]; if task_matches_query(task, req) do result.total_count += 1}
	}
	page_size := pr.getSizeTaskQueryPage(pr.TaskQueryPage{})
	for has_item {
		key := btree.item(&it); has_item = btree.iter_next(&it); task := conv.tasks[key.task_id]
		if !task_matches_query(task, req) do continue
		task_size := pr.getSizeTask(task^)
		projected_size := page_size + task_size + len(key.text) - len(result.next_cursor_text)
		if len(tasks) >= int(req.limit) || (len(tasks) > 0 && projected_size > MAX_PROTOCOL_PAYLOAD_SIZE) {result.has_more = true; break}
		append(tasks, task^)
		page_size = projected_size
		result.next_cursor_number = key.number
		result.next_cursor_text = key.text
		result.next_cursor_task_id = key.task_id
	}
	return result
}

process_query_tasks :: proc(c: ^NRC_Connection, req: pr.TaskQueryRequest) {
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	tasks := make([dynamic]pr.Task, 0, int(req.limit)); defer delete(tasks)
	result := collect_task_query_page(conv, req, &tasks)
	send_task_query_page(c, req.conv_id, tasks[:], result, req.correlation_id)
}

process_list_task_projects :: proc(c: ^NRC_Connection, req: pr.ListTaskProjectsRequest) {
	projects := make([dynamic]string); defer delete(projects)
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	if conv != nil {
		for project in conv.task_project_indexes {
			if project != "" do append(&projects, project)
		}
		slice.sort_by(projects[:], proc(a, b: string) -> bool {
			return a < b
		})
	}
	send_task_projects(c, req.conv_id, projects[:], req.correlation_id)
}

process_list_task_assignees :: proc(c: ^NRC_Connection, req: pr.ListTaskProjectsRequest) {
	assignees := make([dynamic]string); defer delete(assignees)
	conv := get_conversation(get_connection_workspace(c), req.conv_id)
	if conv != nil {
		for assignee in conv.task_assignee_indexes {
			if assignee != "" do append(&assignees, assignee)
		}
		slice.sort_by(assignees[:], proc(a, b: string) -> bool {return a < b})
	}
	send_task_projects(c, req.conv_id, assignees[:], req.correlation_id, .S_TaskAssignees)
}

process_list_tasks_paged :: proc(c: ^NRC_Connection, req: pr.ListTasksPagedRequest) {
	ws := get_connection_workspace(c)
	conv := get_conversation(ws, req.conv_id)
	if conv == nil {
		send_task_list_page(c, req.conv_id, nil, false, 0, 0, 0, "", req.correlation_id)
		return
	}
	tasks := make([dynamic]pr.Task, 0, int(req.limit))
	defer delete(tasks)
	result := collect_task_page(conv, req, &tasks)

	send_task_list_page(
		c,
		req.conv_id,
		tasks[:],
		result.has_more,
		result.next_cursor_sort_at,
		result.next_cursor_task_id,
		result.total_count,
		"",
		req.correlation_id,
	)
}

process_get_task :: proc(c: ^NRC_Connection, req: pr.GetTaskRequest) {
	task := get_task(c.workspace_id, req.conv_id, req.task_id)
	if task == nil {
		send_task_full(c, req.conv_id, nil, "Task not found", req.correlation_id)
		return
	}
	send_task_full(c, req.conv_id, task, "", req.correlation_id)
}

// ============================================================================
// Response Senders
// ============================================================================

send_task_created :: proc(c: ^NRC_Connection, task: pr.Task, correlation_id: u32 = 0) {
	msg := pr.TaskCreated {
		task           = task,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeTaskCreated(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task created")
	if buf == nil do return

	protocol_len := pr.serializeTaskCreated(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize TaskCreated for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_task_updated :: proc(c: ^NRC_Connection, task: pr.Task, correlation_id: u32 = 0) {
	msg := pr.TaskUpdated {
		task           = task,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeTaskUpdated(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task updated")
	if buf == nil do return

	protocol_len := pr.serializeTaskUpdated(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize TaskUpdated for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_task_deleted :: proc(c: ^NRC_Connection, task_id: pr.TaskID, conv_id: pr.ConversationID, correlation_id: u32 = 0) {
	msg := pr.TaskDeleted {
		task_id        = task_id,
		conv_id        = conv_id,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeTaskDeleted(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task deleted")
	if buf == nil do return

	protocol_len := pr.serializeTaskDeleted(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize TaskDeleted for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_task_moved :: proc(
	c: ^NRC_Connection,
	task_id: pr.TaskID,
	conv_id: pr.ConversationID,
	status: pr.TaskStatus,
	order_index: u16,
	completed_at: i64,
	completed_by: []byte,
	correlation_id: u32 = 0,
) {
	msg := pr.TaskMoved {
		task_id        = task_id,
		conv_id        = conv_id,
		status         = status,
		order_index    = order_index,
		completed_at   = completed_at,
		completed_by   = completed_by,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeTaskMoved(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task moved")
	if buf == nil do return

	protocol_len := pr.serializeTaskMoved(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize TaskMoved for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_task_list_response :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, success: bool, tasks: []pr.Task, error_msg: string, correlation_id: u32 = 0) {
	msg := pr.TaskListResponse {
		conv_id        = conv_id,
		success        = success,
		tasks          = tasks,
		error          = transmute([]byte)error_msg,
		correlation_id = correlation_id,
	}

	protocol_size := pr.getSizeTaskListResponse(msg)
	if protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE && success {
		send_task_list_response(c, conv_id, false, nil, "Task list exceeds transport limit; use paged task queries", correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task list response")
	if buf == nil do return

	protocol_len := pr.serializeTaskListResponse(msg, buf[header_len:])
	if protocol_len > 0 {
		total_len := header_len + protocol_len
		_ = send_pooled_buffer(c, buf[:total_len])
	} else {
		log.errorf("[T%d] Failed to serialize TaskListResponse for sock %v", td.thread_index, c.sock)
		byte_pool.release(td.spool, buf)
	}
}

send_task_list_error :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, error_msg: string, correlation_id: u32 = 0) {
	send_task_list_response(c, conv_id, false, nil, error_msg, correlation_id)
}

send_task_list_page :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	tasks: []pr.Task,
	has_more: bool,
	next_sort_at: i64,
	next_task_id: pr.TaskID,
	total_count: u32,
	error_msg: string,
	correlation_id: u32,
) {
	msg := pr.TaskListPage {
		conv_id             = conv_id,
		success             = len(error_msg) == 0,
		tasks               = tasks,
		has_more            = has_more,
		next_cursor_sort_at = next_sort_at,
		next_cursor_task_id = next_task_id,
		total_count         = total_count,
		error               = transmute([]byte)error_msg,
		correlation_id      = correlation_id,
	}
	protocol_size := pr.getSizeTaskListPage(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task list page")
	if buf == nil do return
	protocol_len := pr.serializeTaskListPage(msg, buf[header_len:])
	if protocol_len > 0 {
		_ = send_pooled_buffer(c, buf[:header_len + protocol_len])
	} else {
		byte_pool.release(td.spool, buf)
	}
}

send_task_query_page :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, tasks: []pr.Task, result: Task_Query_Collection, correlation_id: u32) {
	msg := pr.TaskQueryPage {
		conv_id             = conv_id,
		success             = true,
		tasks               = tasks,
		has_more            = result.has_more,
		next_cursor_number  = result.next_cursor_number,
		next_cursor_task_id = result.next_cursor_task_id,
		next_cursor_text    = result.next_cursor_text,
		total_count         = result.total_count,
		correlation_id      = correlation_id,
	}
	size := pr.getSizeTaskQueryPage(msg); buf, header_len := allocate_websocket_frame_buffer(size, "task query page"); if buf == nil do return
	written := pr.serializeTaskQueryPage(
		msg,
		buf[header_len:],
	); if written > 0 {_ = send_pooled_buffer(c, buf[:header_len + written])} else {byte_pool.release(td.spool, buf)}
}

task_project_chunk_count :: proc(projects: []string) -> int {
	size := pr.getSizeTaskProjects(pr.TaskProjects{})
	for project, i in projects {
		size += 2 + len(project)
		if size > MAX_PROTOCOL_PAYLOAD_SIZE do return i
	}
	return len(projects)
}

send_task_projects :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, projects: []string, correlation_id: u32, opcode: pr.Opcode = .S_TaskProjects) {
	remaining := projects
	for {
		count := task_project_chunk_count(remaining)
		msg := pr.TaskProjects {
			conv_id        = conv_id,
			projects       = remaining[:count],
			has_more       = count < len(remaining),
			correlation_id = correlation_id,
		}
		size := pr.getSizeTaskProjects(msg)
		buf, header_len := allocate_websocket_frame_buffer(size, "task projects")
		if buf == nil do return
		written := pr.serializeTaskProjects(msg, buf[header_len:], opcode)
		if written <= 0 {
			byte_pool.release(td.spool, buf)
			return
		}
		if !send_pooled_buffer(c, buf[:header_len + written]) do return
		if !msg.has_more do return
		remaining = remaining[count:]
	}
}

send_task_full :: proc(c: ^NRC_Connection, conv_id: pr.ConversationID, task: ^pr.Task, error_msg: string, correlation_id: u32) {
	msg := pr.TaskFull {
		conv_id        = conv_id,
		success        = task != nil,
		has_task       = task != nil,
		error          = transmute([]byte)error_msg,
		correlation_id = correlation_id,
	}
	if task != nil do msg.task = task^
	protocol_size := pr.getSizeTaskFull(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task full")
	if buf == nil do return
	protocol_len := pr.serializeTaskFull(msg, buf[header_len:])
	if protocol_len > 0 {
		_ = send_pooled_buffer(c, buf[:header_len + protocol_len])
	} else {
		byte_pool.release(td.spool, buf)
	}
}

// ============================================================================
// Broadcast Helpers
// ============================================================================

broadcast_task_created_by_id :: proc(task: pr.Task, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_task_created_with_workspace(task, excluded_sock, get_workspace(workspace_id))
}

broadcast_task_created_with_workspace :: proc(task: pr.Task, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, task.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	// Create shared buffer
	msg := pr.TaskCreated {
		task = task,
	}
	shared_buf := create_shared_task_broadcast_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_task_created :: proc {
	broadcast_task_created_by_id,
	broadcast_task_created_with_workspace,
}

broadcast_task_updated_by_id :: proc(task: pr.Task, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_task_updated_with_workspace(task, excluded_sock, get_workspace(workspace_id))
}

broadcast_task_updated_with_workspace :: proc(task: pr.Task, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, task.conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.TaskUpdated {
		task = task,
	}
	shared_buf := create_shared_task_updated_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_task_updated :: proc {
	broadcast_task_updated_by_id,
	broadcast_task_updated_with_workspace,
}

broadcast_task_deleted_by_id :: proc(task_id: pr.TaskID, conv_id: pr.ConversationID, excluded_sock: net.TCP_Socket, workspace_id: string) {
	broadcast_task_deleted_with_workspace(task_id, conv_id, excluded_sock, get_workspace(workspace_id))
}

broadcast_task_deleted_with_workspace :: proc(task_id: pr.TaskID, conv_id: pr.ConversationID, excluded_sock: net.TCP_Socket, ws: ^Workspace_State) {
	if ws == nil do return

	conv := get_conversation(ws, conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.TaskDeleted {
		task_id = task_id,
		conv_id = conv_id,
	}
	shared_buf := create_shared_task_deleted_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_task_deleted :: proc {
	broadcast_task_deleted_by_id,
	broadcast_task_deleted_with_workspace,
}

broadcast_task_moved_by_id :: proc(
	task_id: pr.TaskID,
	conv_id: pr.ConversationID,
	status: pr.TaskStatus,
	order_index: u16,
	completed_at: i64,
	completed_by: []byte,
	excluded_sock: net.TCP_Socket,
	workspace_id: string,
) {
	broadcast_task_moved_with_workspace(task_id, conv_id, status, order_index, completed_at, completed_by, excluded_sock, get_workspace(workspace_id))
}

broadcast_task_moved_with_workspace :: proc(
	task_id: pr.TaskID,
	conv_id: pr.ConversationID,
	status: pr.TaskStatus,
	order_index: u16,
	completed_at: i64,
	completed_by: []byte,
	excluded_sock: net.TCP_Socket,
	ws: ^Workspace_State,
) {
	if ws == nil do return

	conv := get_conversation(ws, conv_id)
	if conv == nil do return
	if subscriber_count(conv) == 0 do return

	msg := pr.TaskMoved {
		task_id      = task_id,
		conv_id      = conv_id,
		status       = status,
		order_index  = order_index,
		completed_at = completed_at,
		completed_by = completed_by,
	}
	shared_buf := create_shared_task_moved_buffer(msg)
	if shared_buf == nil do return

	send_shared_to_subscribers_except(conv, excluded_sock, shared_buf)
}

broadcast_task_moved :: proc {
	broadcast_task_moved_by_id,
	broadcast_task_moved_with_workspace,
}

// ============================================================================
// Shared Buffer Creators
// ============================================================================

create_shared_task_broadcast_buffer :: proc(msg: pr.TaskCreated) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeTaskCreated(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task created broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeTaskCreated(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

create_shared_task_updated_buffer :: proc(msg: pr.TaskUpdated) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeTaskUpdated(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task updated broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeTaskUpdated(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

create_shared_task_deleted_buffer :: proc(msg: pr.TaskDeleted) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeTaskDeleted(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task deleted broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeTaskDeleted(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

create_shared_task_moved_buffer :: proc(msg: pr.TaskMoved) -> ^Broadcast_Buffer {
	protocol_size := pr.getSizeTaskMoved(msg)
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task moved broadcast")
	if buf == nil do return nil

	protocol_len := pr.serializeTaskMoved(msg, buf[header_len:])
	if protocol_len <= 0 {
		byte_pool.release(td.spool, buf)
		return nil
	}

	shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
	shared.data = buf[:header_len + protocol_len]
	shared.ref_count = 1
	shared.pool = td.spool

	return shared
}

// ============================================================================
// Helper Procedures
// ============================================================================

// Get task by ID with O(1) lookup using conv_id
get_task :: proc(workspace_id: string, conv_id: pr.ConversationID, task_id: pr.TaskID) -> ^pr.Task {
	ws := get_workspace(workspace_id)
	if ws == nil do return nil
	conv := get_conversation(ws, conv_id)
	if conv == nil do return nil
	return conv.tasks[task_id] or_else nil
}

// ============================================================================
// Single-Allocation Task Memory Management
// ============================================================================
//
// Tasks are allocated as a single contiguous block:
//   [Task struct | title bytes | description bytes | assignee | created_by | external_ref | completed_by]
//
// The slice fields in Task point into the trailing buffer. This reduces
// allocation count from 6 (struct + 5 strings) to 1, improving replay perf.
//
// On update, the entire block is reallocated if any string field changes.

// alloc_task allocates a task with all string data in a single contiguous block
// Attachments are allocated separately
alloc_task :: proc(title, description, assignee, created_by, external_ref, completed_by, project: []byte, attachments: []pr.Attachment) -> ^pr.Task {
	// Calculate total size including attachment structs and their string fields
	attachments_size := size_of(pr.Attachment) * len(attachments)
	attachment_strings_size := 0
	for &att in attachments {
		attachment_strings_size += len(att.file_id) + len(att.filename) + len(att.mime_type)
	}

	// Include worst-case alignment padding for attachments array
	attachment_alignment_padding := align_of(pr.Attachment) - 1 if len(attachments) > 0 else 0

	total_size :=
		size_of(pr.Task) +
		len(title) +
		len(description) +
		len(assignee) +
		len(created_by) +
		len(external_ref) +
		len(completed_by) +
		len(project) +
		attachment_alignment_padding +
		attachments_size +
		attachment_strings_size

	block, _ := mem.alloc_bytes(total_size)
	if len(block) == 0 {
		return nil
	}

	task := (^pr.Task)(raw_data(block))

	// Copy strings into trailing buffer and set slices
	offset := size_of(pr.Task)

	if len(title) > 0 {
		copy(block[offset:], title)
		task.title = block[offset:][:len(title)]
		offset += len(title)
	}

	if len(description) > 0 {
		copy(block[offset:], description)
		task.description = block[offset:][:len(description)]
		offset += len(description)
	}

	if len(assignee) > 0 {
		copy(block[offset:], assignee)
		task.assignee = block[offset:][:len(assignee)]
		offset += len(assignee)
	}

	if len(created_by) > 0 {
		copy(block[offset:], created_by)
		task.created_by = block[offset:][:len(created_by)]
		offset += len(created_by)
	}

	if len(external_ref) > 0 {
		copy(block[offset:], external_ref)
		task.external_ref = block[offset:][:len(external_ref)]
		offset += len(external_ref)
	}

	if len(completed_by) > 0 {
		copy(block[offset:], completed_by)
		task.completed_by = block[offset:][:len(completed_by)]
		offset += len(completed_by)
	}

	if len(project) > 0 {
		copy(block[offset:], project)
		task.project = block[offset:][:len(project)]
		offset += len(project)
	}

	// Copy attachments array and their string fields into the block
	if len(attachments) > 0 {
		// Align offset for proper alignment of Attachment struct (contains u64/i64 fields)
		offset = mem.align_forward_int(offset, align_of(pr.Attachment))
		task.attachments = transmute([]pr.Attachment)mem.Raw_Slice{raw_data(block[offset:]), len(attachments)}
		offset += attachments_size

		// Deep copy each attachment's string fields
		for i := 0; i < len(attachments); i += 1 {
			src := &attachments[i]
			dst := &task.attachments[i]

			// Copy scalar fields
			dst.size = src.size
			dst.uploaded_at = src.uploaded_at

			// Deep copy file_id
			if len(src.file_id) > 0 {
				copy(block[offset:], src.file_id)
				dst.file_id = block[offset:][:len(src.file_id)]
				offset += len(src.file_id)
			}

			// Deep copy filename
			if len(src.filename) > 0 {
				copy(block[offset:], src.filename)
				dst.filename = block[offset:][:len(src.filename)]
				offset += len(src.filename)
			}

			// Deep copy mime_type
			if len(src.mime_type) > 0 {
				copy(block[offset:], src.mime_type)
				dst.mime_type = block[offset:][:len(src.mime_type)]
				offset += len(src.mime_type)
			}
		}
	}

	return task
}

// Free task memory (single allocation for task struct, strings, and attachments)
free_task :: proc(task: ^pr.Task) {
	if task == nil do return

	// Everything is in a single allocation block, just free the task pointer
	free(task)
}

// Calculate the next order_index for a status column, and whether the column can
// name one at all: a column whose positions are exhausted cannot take another
// task, and the caller rejects the write instead of folding an index that would
// wrap past the u16 space.
calculate_next_order_index :: proc(conv_tasks: map[pr.TaskID]^pr.Task, status: pr.TaskStatus) -> (order_index: u16, ok: bool) {
	max_order: u16 = 0
	for _, task in conv_tasks {
		if task.status != status do continue
		if task.order_index >= max_order {
			if task.order_index == max(u16) do return 0, false
			max_order = task.order_index + 1
		}
	}
	return max_order, true
}

// Sort tasks by priority (descending) then order_index (ascending)
sort_tasks_by_priority_and_order :: proc(tasks: []pr.Task) {
	slice.sort_by(
		tasks,
		proc(a, b: pr.Task) -> bool {
			if a.priority != b.priority {
				return a.priority > b.priority // Higher priority first
			}
			return a.order_index < b.order_index // Lower order_index first
		},
	)
}
