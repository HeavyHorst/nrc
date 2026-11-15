//
// task_handlers.odin - Task/Kanban Message Processing
//
// SQLite create/get submission, shared responses and task broadcasts.
//
package main

import "core:log"
import "core:net"

import "byte_pool"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

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
// CreateTask Handler
// ============================================================================

process_create_task :: proc(c: ^NRC_Connection, req: pr.CreateTaskRequest) {
	// Validate title is non-empty
	if len(req.title) == 0 {
		send_task_list_error(c, req.conv_id, "Task title cannot be empty", req.correlation_id)
		return
	}
	if !c.authenticated || req.conv_id != pr.WORKSPACE_DATA_ID {
		send_task_list_error(c, req.conv_id, "Access denied", req.correlation_id)
		return
	}
	now := nrc_time_unix_nanos()
	request := db.Request {
		operation = .Create_Task,
		shard = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		task = pr.Task {
			conv_id = req.conv_id,
			title = req.title,
			description = req.description,
			status = req.status,
			priority = req.priority,
			color = req.color,
			external_ref = req.external_ref,
			project = req.project,
			due_at = req.due_at,
			attachments = req.attachments,
			created_at = now,
			updated_at = now,
		},
	}
	admission_error: string
	if !worker_db_submit(c, request, req.correlation_id, complete_create_task, &admission_error) {
		send_task_list_error(c, req.conv_id, admission_error, req.correlation_id)
	}
}

complete_create_task :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	if job.result.status != sql.OK {
		if c == nil do return
		error := "Failed to create task"
		switch job.result.create_error {
		case .None:
		case .Invalid_Task:
			error = "Invalid task data"
		case .Column_Full:
			error = "Status column is full"
		}
		send_task_list_error(c, pr.WORKSPACE_DATA_ID, error, correlation)
		return
	}
	// A disconnected/stale initiator must not suppress a committed event or
	// exclude a replacement connection that happens to reuse its socket.
	excluded := net.TCP_Socket(-1)
	if c != nil {excluded = c.sock; send_task_created(c, job.result.task, correlation)}
	broadcast_task_created(job.result.task, excluded, job.request.workspace)
}

// ============================================================================
// GetTask Handler
// ============================================================================

process_get_task :: proc(c: ^NRC_Connection, req: pr.GetTaskRequest) {
	if !c.authenticated || req.conv_id != pr.WORKSPACE_DATA_ID {
		send_task_full(c, req.conv_id, nil, "Access denied", req.correlation_id)
		return
	}
	request := db.Request {
		operation = .Get_Task,
		shard     = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		scope     = pr.WORKSPACE_DATA_ID,
		task_id   = req.task_id,
	}
	admission_error: string
	if !worker_db_submit(c, request, req.correlation_id, complete_get_task, &admission_error) {
		send_task_full(c, req.conv_id, nil, admission_error, req.correlation_id)
	}
}

// Public workspace tasks have no record-level ACL. The worker bridge rechecks
// authenticated workspace/identity and connection generation before this call.
// Private legacy scopes never enter this read path. The result is borrowed.
complete_get_task :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	if c == nil do return
	if job.result.status != sql.OK {
		send_task_full(c, pr.WORKSPACE_DATA_ID, nil, "Failed to load task", correlation)
	} else if !job.result.found {
		send_task_full(c, pr.WORKSPACE_DATA_ID, nil, "Task not found", correlation)
	} else {
		send_task_full(c, pr.WORKSPACE_DATA_ID, &job.result.task, "", correlation)
	}
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

// Shared response metadata, including SQLite command-error responses.
Task_Query_Collection :: struct {
	has_more:            bool,
	next_cursor_number:  i64,
	next_cursor_text:    []byte,
	next_cursor_task_id: pr.TaskID,
	total_count:         u32,
}

send_task_query_page :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	tasks: []pr.Task,
	result: Task_Query_Collection,
	correlation_id: u32,
	error_text := "",
) {
	msg := pr.TaskQueryPage {
		conv_id             = conv_id,
		success             = error_text == "",
		error               = transmute([]byte)error_text,
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
	if task != nil && protocol_size > MAX_PROTOCOL_PAYLOAD_SIZE {
		send_task_full(c, conv_id, nil, "Task exceeds response limit", correlation_id)
		return
	}
	buf, header_len := allocate_websocket_frame_buffer(protocol_size, "task full")
	if buf == nil do return
	protocol_len := pr.serializeTaskFull(msg, buf[header_len:])
	if protocol_len > 0 {
		_ = send_pooled_buffer(c, buf[:header_len + protocol_len])
	} else {
		byte_pool.release(td.spool, buf)
		if task != nil do send_task_full(c, conv_id, nil, "Invalid task data", correlation_id)
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
