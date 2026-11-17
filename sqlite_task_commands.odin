package main

import "byte_pool"
import "core:c"
import "core:fmt"
import "core:net"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

sqlite_command_error :: proc(output: ^db.Command_Output, opcode: pr.Opcode, correlation: u32, text: string) -> c.int {
	if opcode == .C_DeleteTask do return sqlite_task_command_error(output, correlation, text)
	msg := pr.ErrorResponse {
		origin_opcode  = opcode,
		error_msg      = transmute([]byte)text,
		correlation_id = correlation,
	}
	buf, rc := db.command_frame(output, pr.getSizeErrorResponse(msg))
	if rc != sql.OK do return rc
	return pr.serializeErrorResponse(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_task_command_error :: proc(output: ^db.Command_Output, correlation: u32, text: string) -> c.int {
	msg := pr.TaskListResponse {
		conv_id        = 0,
		success        = false,
		error          = transmute([]byte)text,
		correlation_id = correlation,
	}
	buf, rc := db.command_frame(output, pr.getSizeTaskListResponse(msg))
	if rc != sql.OK do return rc
	return pr.serializeTaskListResponse(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_emit_task_updated :: proc(output: ^db.Command_Output, task: pr.Task, correlation: u32, audience: db.Command_Audience) -> c.int {
	msg := pr.TaskUpdated {
		task           = task,
		correlation_id = correlation,
	}
	buf, rc := db.command_frame(output, pr.getSizeTaskUpdated(msg), audience, task.conv_id)
	if rc != sql.OK do return rc
	return pr.serializeTaskUpdated(msg, buf) == len(buf) ? sql.OK : sql.CONSTRAINT
}

sqlite_task_update_history :: proc(store: ^db.Store, request: ^db.Request, before, after: ^pr.Task, system := false, system_unblock := false) -> c.int {
	fields: [14]string
	n := 0
	for field in ([?]struct {
			name:    string,
			changed: bool,
		}{{"title", string(before.title) != string(after.title)}, {"description", string(before.description) != string(after.description)}, {"status", before.status != after.status}, {"order_index", before.order_index != after.order_index}, {"assignee", string(before.assignee) != string(after.assignee)}, {"priority", before.priority != after.priority}, {"color", before.color != after.color}, {"external_ref", string(before.external_ref) != string(after.external_ref)}, {"due_at", before.due_at != after.due_at}, {"blocked_by", before.blocked_by != after.blocked_by}, {"completed_at", before.completed_at != after.completed_at}, {"completed_by", string(before.completed_by) != string(after.completed_by)}, {"project", string(before.project) != string(after.project)}, {"attachments", !history_attachment_equal(before.attachments, after.attachments)}}) {if field.changed {fields[n] = field.name; n += 1}}
	split_unblock := false
	if system_unblock {
		for field, i in fields[:n] {if field == "blocked_by" {copy(fields[i:], fields[i + 1:n]); n -= 1; split_unblock = true; break}}
	}
	if n == 0 && !split_unblock do return sql.OK // Timestamp-only changes are not history events.
	id := fmt.aprintf("%d", after.id); defer delete(id)
	timestamp := fmt.aprintf("%d", request.timestamp); defer delete(timestamp)
	label := pr.history_short_label(string(after.title), context.allocator); defer delete(label)
	actor_id := request.subject
	service_actor := ""; defer delete(service_actor)
	if actor_id == "" {service_actor = fmt.aprintf("service:%s", request.actor); actor_id = service_actor}
	event := pr.History_Event {
		timestamp    = timestamp,
		actor_id     = system ? "system" : actor_id,
		actor_name   = system ? "System" : request.actor,
		entity_type  = "task",
		entity_id    = id,
		entity_label = label,
		action       = "updated",
		fields       = fields[:n],
	}
	if n != 0 {
		if rc := db.append_history_event(store, request.workspace, event, {1, after.id}); rc != sql.OK do return rc
	}
	if split_unblock {
		event.actor_id = "system"; event.actor_name = "System"; event.fields = {"blocked_by"}
		return db.append_history_event(store, request.workspace, event, {1, after.id})
	}
	return sql.OK
}

// Existing records need only the changed columns. A full UPSERT also rewrites
// unrelated sorting indexes and attachments, increasing WAL and pager churn.
sqlite_update_task :: proc(store: ^db.Store, workspace: string, old, next: ^pr.Task) -> c.int {
	if !history_attachment_equal(old.attachments, next.attachments) do return db.put_task(store, workspace, next)
	if sql.get_autocommit(store.db) != 0 do return sql.MISUSE
	assert(old.id == next.id && old.conv_id == 0 && next.conv_id == 0)
	fields := [?]struct {
		name:    string,
		value:   SQLite_Projection_Value,
		changed: bool,
	} {
		{"title", string(next.title), string(old.title) != string(next.title)},
		{"description", string(next.description), string(old.description) != string(next.description)},
		{"status", i64(next.status), old.status != next.status},
		{"order_index", i64(next.order_index), old.order_index != next.order_index},
		{"assignee", string(next.assignee), string(old.assignee) != string(next.assignee)},
		{"priority", i64(next.priority), old.priority != next.priority},
		{"color", i64(next.color), old.color != next.color},
		{"created_by", string(next.created_by), string(old.created_by) != string(next.created_by)},
		{"created_at", next.created_at, old.created_at != next.created_at},
		{"updated_at", next.updated_at, old.updated_at != next.updated_at},
		{"external_ref", string(next.external_ref), string(old.external_ref) != string(next.external_ref)},
		{"due_at", next.due_at, old.due_at != next.due_at},
		{"blocked_by", u64(next.blocked_by), old.blocked_by != next.blocked_by},
		{"completed_at", next.completed_at, old.completed_at != next.completed_at},
		{"completed_by", string(next.completed_by), string(old.completed_by) != string(next.completed_by)},
		{"project", string(next.project), string(old.project) != string(next.project)},
	}
	query: [1024]byte
	pos := copy(query[:], "UPDATE tasks SET ")
	values: [len(fields)]SQLite_Projection_Value
	n := 0
	for field in fields {
		if !field.changed do continue
		pos += len(fmt.bprintf(query[pos:], "%s%s=?%d", n == 0 ? "" : ",", field.name, n + 3))
		values[n] = field.value; n += 1
	}
	if n == 0 do return sql.OK
	pos += copy(query[pos:], " WHERE workspace=?1 AND id=?2")
	query[pos] = 0
	key := pr.Asset {
		asset_id = next.id,
	}
	if rc := sqlite_projection_write(store, cstring(raw_data(query[:])), workspace, &key, values[:n]); rc != sql.OK do return rc
	return db.advance_floor(store, max(next.id, next.blocked_by))
}

sqlite_unblock_tasks :: proc(store: ^db.Store, request: ^db.Request, completed: ^pr.Task, output: ^db.Command_Output) -> c.int {
	last: u64
	for {
		// Finish the indexed seek before changing blocked_by, rather than mutate
		// the index under a live SELECT cursor with undefined visitation behavior.
		id: u64
		{
			s: ^sql.Statement
			rc := sql.prepare_v2(store.db, "SELECT id FROM tasks WHERE workspace=?1 AND blocked_by=?2 AND id>?3 AND id!=?2 ORDER BY id LIMIT 1", -1, &s, nil)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 2, completed.id); rc != sql.OK do return rc
			if rc = sql.bind_id(s, 3, last); rc != sql.OK do return rc
			rc = sql.step(s)
			if rc == sql.DONE do return sql.OK
			if rc != sql.ROW do return rc
			id, rc = sql.column_id(s, 0); if rc != sql.OK do return rc
		}
		old, found, rc := db.get_task(store, request.workspace, completed.conv_id, id, max_bytes = pr.MAX_PROTOCOL_PAYLOAD_SIZE)
		defer db.destroy_task(&old)
		if rc != sql.OK do return rc
		if !found do return sql.CORRUPT
		next := old
		if old.updated_at == max(i64) do return sql.FULL
		next.blocked_by = 0; next.updated_at = max(completed.updated_at, old.updated_at + 1)
		if rc = sqlite_update_task(store, request.workspace, &old, &next); rc != sql.OK do return rc
		if rc = sqlite_task_update_history(store, request, &old, &next, true); rc != sql.OK do return rc
		if rc = sqlite_emit_task_updated(output, next, 0, .Subscribers); rc != sql.OK do return rc
		last = id
	}
}

sqlite_execute_task_command :: proc(store: ^db.Store, request: ^db.Request, output: ^db.Command_Output) -> c.int {
	if request.chronicle_access & pr.CHRONICLE_ACCESS_SERVICE != 0 && request.opcode != .C_Chronicle do return sql.CONSTRAINT
	if request.operation == .Monitor_Maintenance do return sqlite_monitor_maintenance(store, request, output)
	if request.opcode == .C_Chronicle do return sqlite_execute_chronicle(store, request, output)
	#partial switch request.opcode {
	case .C_SendMessage, .C_SendMessageV2, .C_SubscribeConvs, .C_SubscribeConvsV2, .C_UnsubscribeConvs, .C_ListMessagesBefore, .C_ReplayMessagesAfter:
		return sqlite_authorize_dm_request(store, request, output)
	}
	if request.opcode == .C_StartDM || request.opcode == .C_ListDMs || request.opcode == .C_LeaveDM do return sqlite_execute_dm(store, request, output)
	if request.opcode == .C_ApplyTransaction do return sqlite_apply_transaction(store, request, output)
	if request.opcode == .C_ApplyMonitorRun do return sqlite_apply_monitor_run(store, request, output)
	if request.opcode == .C_GetMonitorState do return sqlite_get_monitor_state(store, request, output)
	if request.opcode == .C_QueryMonitorStatus do return sqlite_query_monitor_status(store, request, output)
	if request.opcode == .C_ControlMonitorInstance do return sqlite_control_monitor_instance(store, request, output)
	if request.opcode == .C_ActOnIncident do return sqlite_act_on_incident(store, request, output)
	if request.opcode == .C_MonitorDelivery do return sqlite_monitor_delivery(store, request, output)
	if request.opcode == .C_QueryTickets do return sqlite_query_tickets(store, request, output)
	if request.opcode == .C_QueryCalendar do return sqlite_query_calendar(store, request, output)
	if request.opcode == .C_GraphQuery || request.opcode == .C_GraphShortestPath || request.opcode == .C_GraphRank do return sqlite_graph_traverse(store, request, output)
	if request.opcode == .C_GraphDegree do return sqlite_graph_degree(store, request, output)
	if request.opcode == .C_GraphCommonNeighbors do return sqlite_graph_common(store, request, output)
	if request.opcode == .C_DeleteAsset || request.opcode == .C_DeleteTask do return sqlite_delete_record(store, request, output)
	#partial switch request.opcode {
	case .C_CreateEdge, .C_DeleteEdge, .C_ListEdges, .C_ListAllEdges, .C_ListAllEdgesPaged, .C_ListEdgesPaged:
		return sqlite_execute_edges(store, request, output)
	}
	if request.opcode == .C_CreateAsset || request.opcode == .C_UpdateAsset do return sqlite_execute_asset_write(store, request, output)
	if request.opcode == .C_ListAssets || request.opcode == .C_ListAssetsPaged || request.opcode == .C_ListAssetsPagedByProject || request.opcode == .C_ListAssetsPagedByTag do return sqlite_list_assets(store, request, output)
	if request.opcode == .C_GetAsset || request.opcode == .C_GetAssetsByIDs || request.opcode == .C_GetTasksByIDs do return sqlite_execute_record_reads(store, request, output)
	if request.opcode == .C_ListHistory do return sqlite_execute_history(store, request, output)
	if request.opcode == .C_QueryTasks do return sqlite_query_tasks(store, request, output)
	if request.opcode == .C_ListTaskSlices do return sqlite_list_slices(store, request, output)
	if request.opcode == .C_SearchCustomers do return sqlite_search_customers(store, request, output)
	if request.opcode == .C_GetWorkspaceOverview do return sqlite_workspace_overview(store, request, output)
	if request.opcode == .C_ListTaskDependents do return sqlite_list_task_dependents(store, request, output)
	if request.opcode == .C_ListTasksPaged do return sqlite_list_tasks_paged(store, request, output)
	if request.opcode == .C_GetTasks do return sqlite_get_tasks(store, request, output)
	#partial switch request.opcode {
	case .C_ListTaskProjects, .C_ListTaskAssignees, .C_ListSliceOwners, .C_ListTicketAssignees, .C_ListCalendarPeople:
		return sqlite_list_task_facets(store, request, output)
	case .C_ListNoteProjects, .C_ListNoteTags:
		return sqlite_list_note_facets(store, request, output)
	}
	update: pr.UpdateTaskRequest
	move: pr.MoveTaskRequest
	attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
	id: u64
	correlation: u32
	#partial switch request.opcode {
	case .C_UpdateTask:
		parse_err: pr.ProtocolParseError
		update, parse_err = pr.parseUpdateTaskRequest(request.body, attachments[:])
		if parse_err != nil || update.conv_id != 0 do return sql.CONSTRAINT
		id = update.task_id; correlation = update.correlation_id
	case .C_MoveTask:
		parse_err: pr.ProtocolParseError
		move, parse_err = pr.parseMoveTaskRequest(request.body)
		if parse_err != nil || move.conv_id != 0 do return sql.CONSTRAINT
		id = move.task_id; correlation = move.correlation_id
	case:
		return sql.MISUSE
	}
	old, found, rc := db.get_task(store, request.workspace, 0, id, max_bytes = pr.MAX_PROTOCOL_PAYLOAD_SIZE)
	defer db.destroy_task(&old)
	if rc != sql.OK do return rc
	if !found do return sqlite_task_command_error(output, correlation, "Task not found")
	if old.updated_at == max(i64) do return sql.FULL
	next := old // Borrow old/input bytes only until serialization inside this call.
	if request.opcode == .C_UpdateTask {
		next.title = resolve_string_field(update.title, old.title)
		next.description = resolve_string_field(update.description, old.description)
		next.assignee = resolve_string_field(update.assignee, old.assignee)
		next.external_ref = resolve_string_field(update.external_ref, old.external_ref)
		next.project = resolve_string_field(update.project, old.project)
		if u8(update.status) != 255 do next.status = update.status
		if update.priority != 255 do next.priority = update.priority
		if u8(update.color) != 255 do next.color = update.color
		if update.due_at != 0 do next.due_at = update.due_at == -1 ? 0 : update.due_at
		if update.blocked_by != 0 do next.blocked_by = update.blocked_by == max(u64) ? 0 : update.blocked_by
		if !update.preserve_attachments do next.attachments = update.attachments
	} else {
		next.status = move.status; next.order_index = move.order_index
		if .Append in move.flags {
			s: ^sql.Statement
			rc = sql.prepare_v2(store.db, "SELECT coalesce(max(order_index)+1,0) FROM tasks WHERE workspace=?1 AND status=?2", -1, &s, nil)
			if rc != sql.OK do return rc
			defer sql.finalize(s)
			if rc = sql.bind_bytes(s, 1, transmute([]byte)request.workspace); rc != sql.OK do return rc
			if rc = sql.bind_int64(s, 2, i64(move.status)); rc != sql.OK do return rc
			if rc = sql.step(s); rc != sql.ROW do return rc
			order := sql.column_int64(s, 0)
			if order > i64(max(u16)) do return sqlite_task_command_error(output, correlation, "Status column is full")
			next.order_index = u16(order)
		}
	}
	next.updated_at = max(request.timestamp, old.updated_at + 1)
	if next.status == .Done && old.status != .Done {next.completed_at = next.updated_at; next.completed_by = transmute([]byte)request.actor}
	if next.status != .Done && old.status == .Done {next.completed_at = 0; next.completed_by = nil}
	if rc = sqlite_update_task(store, request.workspace, &old, &next); rc != sql.OK do return rc
	if rc = sqlite_task_update_history(store, request, &old, &next); rc != sql.OK do return rc
	if next.status == .Done && old.status != .Done {
		if rc = sqlite_unblock_tasks(store, request, &next, output); rc != sql.OK do return rc
	}
	for audience in ([?]db.Command_Audience{.Requester, .Other_Subscribers}) {
		corr := audience == .Requester ? correlation : 0
		if request.opcode == .C_UpdateTask {
			if rc = sqlite_emit_task_updated(output, next, corr, audience); rc != sql.OK do return rc
		} else {
			msg := pr.TaskMoved {
				task_id        = next.id,
				conv_id        = 0,
				status         = next.status,
				order_index    = next.order_index,
				completed_at   = next.completed_at,
				completed_by   = next.completed_by,
				correlation_id = corr,
			}
			buf, frame_rc := db.command_frame(output, pr.getSizeTaskMoved(msg), audience)
			if frame_rc != sql.OK do return frame_rc
			if pr.serializeTaskMoved(msg, buf) != len(buf) do return sql.CONSTRAINT
		}
	}
	return sql.OK
}

worker_db_submit_command :: proc(c: ^NRC_Connection, opcode: pr.Opcode, body: []byte, correlation: u32) {
	if !c.authenticated {worker_db_command_error(c, opcode, correlation, "Access denied"); return}
	request := db.Request {
		operation = .Command,
		shard     = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
		opcode    = opcode,
		body      = body,
		timestamp = nrc_time_unix_nanos(),
	}
	admission_error: string
	if !worker_db_submit(c, request, correlation, worker_db_complete_command, &admission_error) do worker_db_command_error(c, opcode, correlation, admission_error)
}

worker_db_command_error :: proc(c: ^NRC_Connection, opcode: pr.Opcode, correlation: u32, text: string) {
	#partial switch opcode {
	case .C_ApplyTransaction:
		if text == "db_connection_overloaded" || text == "db_worker_overloaded" {
			send_error_response(c, opcode, text, correlation)
			return
		}
		send_transaction_result(c, correlation, .Rejected, max(u16), nil)
	case .C_GraphQuery, .C_GraphShortestPath, .C_GraphRank, .C_GraphDegree, .C_GraphCommonNeighbors:
		send_error_response(c, opcode, text, correlation)
	case .C_QueryTasks:
		send_task_query_page(c, 0, nil, {}, correlation, text)
	case .C_ListTaskSlices:
		send_task_slice_list(c, 0, nil, {}, text, correlation)
	case .C_SearchCustomers, .C_QueryCalendar, .C_QueryTickets:
		send_error_response(c, opcode, text, correlation)
	case .C_GetWorkspaceOverview:
		send_workspace_overview(c, {error = transmute([]byte)text, correlation_id = correlation})
	case .C_ListHistory:
		send_history_error(c, correlation, text)
	case .C_Chronicle:
		send_error_response(c, opcode, text, correlation)
	case .C_ListTasksPaged:
		send_task_list_page(c, 0, nil, false, 0, 0, 0, text, correlation)
	case .C_CreateEdge, .C_DeleteEdge, .C_ListEdges, .C_ListAllEdges, .C_ListAllEdgesPaged, .C_ListEdgesPaged:
		send_error_response(c, opcode, text, correlation)
	case .C_ControlMonitorInstance,
	     .C_GetMonitorState,
	     .C_QueryMonitorStatus,
	     .C_MonitorDelivery,
	     .C_ActOnIncident,
	     .C_ApplyMonitorRun,
	     .C_CreateAsset,
	     .C_UpdateAsset,
	     .C_DeleteAsset,
	     .C_ListAssets,
	     .C_ListAssetsPaged,
	     .C_ListAssetsPagedByProject,
	     .C_ListAssetsPagedByTag:
		send_error_response(c, opcode, text, correlation)
	case .C_ListSliceOwners, .C_ListTicketAssignees, .C_ListCalendarPeople, .C_ListNoteProjects, .C_ListNoteTags:
		send_error_response(c, opcode, text, correlation)
	case .C_ListTaskDependents, .C_ListTaskProjects, .C_ListTaskAssignees, .C_GetAsset, .C_GetAssetsByIDs, .C_GetTasksByIDs:
		send_error_response(c, opcode, text, correlation)
	case:
		send_task_list_error(c, 0, text, correlation)
	}
}

worker_db_complete_command :: proc(c: ^NRC_Connection, correlation: u32, job: ^db.Completion) {
	if job.result.status != sql.OK {
		if c != nil {
			text := "Failed to change task"
			if job.request.opcode == .C_QueryMonitorStatus do text = "Failed to query monitor status: check monitor, cursor and page timestamp"
			if job.request.opcode == .C_ApplyMonitorRun do text = "Monitor run rejected: check evaluator, revision, sequence and instance limits"
			if job.request.opcode == .C_ControlMonitorInstance do text = "Monitor instance action rejected: check revision, instance state and active capacity"
			if job.request.opcode == .C_ActOnIncident do text = "Incident action rejected: check incident ID and revision"
			if job.request.opcode == .C_MonitorDelivery do text = "Monitor delivery rejected: check evaluator, stream, event and lease"
			if job.request.opcode == .C_ApplyMonitorRun && job.result.status == sql.CONSTRAINT do text = "Monitor run rejected: check evaluator, revision, sequence, instance limits and queue capacity"
			#partial switch job.request.opcode {
			case .C_GraphQuery, .C_GraphShortestPath, .C_GraphRank, .C_GraphDegree, .C_GraphCommonNeighbors:
				text = "Failed to query graph"
				if job.result.status == sql.TOOBIG do text = "Graph result exceeds response limit; narrow the query"
			case .C_QueryTasks:
				text = "Failed to query tasks"
			case .C_QueryCalendar:
				text = "Failed to query calendar"
				if job.result.status == sql.TOOBIG do text = "Calendar row exceeds response limit"
			case .C_QueryTickets:
				text = "Failed to query tickets"
				if job.result.status == sql.TOOBIG do text = "Ticket query exceeds response limit"
			case .C_ListTaskSlices:
				text = "Failed to read slices"
			case .C_SearchCustomers:
				text = "Failed to search customers"
			case .C_GetWorkspaceOverview:
				text = "Failed to read workspace overview"
			case .C_CreateEdge, .C_DeleteEdge:
				text = "Failed to change edge"
			case .C_ListEdges, .C_ListAllEdges, .C_ListAllEdgesPaged, .C_ListEdgesPaged:
				text = "Failed to read edges"
			}
			if job.request.opcode == .C_CreateAsset || job.request.opcode == .C_UpdateAsset || job.request.opcode == .C_DeleteAsset do text = "Failed to change asset"
			if job.request.opcode == .C_ListAssets || job.request.opcode == .C_ListAssetsPaged || job.request.opcode == .C_ListAssetsPagedByProject || job.request.opcode == .C_ListAssetsPagedByTag do text = "Failed to read assets"
			if job.request.opcode == .C_ListAssets && job.result.status == sql.TOOBIG do text = "Asset list too large; use ListAssetsPaged"
			if job.request.opcode == .C_GetAsset || job.request.opcode == .C_GetAssetsByIDs || job.request.opcode == .C_GetTasksByIDs do text = "Failed to read records"
			if job.request.opcode == .C_ListHistory do text = "Failed to read history"
			if job.request.opcode == .C_ListTaskDependents || job.request.opcode == .C_ListTasksPaged || job.request.opcode == .C_GetTasks do text = "Failed to read tasks"
			if job.request.opcode == .C_ListTaskProjects || job.request.opcode == .C_ListTaskAssignees do text = "Failed to read task metadata"
			if job.request.opcode == .C_ListSliceOwners || job.request.opcode == .C_ListTicketAssignees || job.request.opcode == .C_ListCalendarPeople do text = "Failed to read people metadata"
			if job.request.opcode == .C_ListNoteProjects || job.request.opcode == .C_ListNoteTags do text = "Failed to read note metadata"
			worker_db_command_error(c, job.request.opcode, correlation, text)
		}
		return
	}
	for frame in job.result.command.frames[:job.result.command.count] {
		if frame.audience == .Requester {
			if c == nil do continue
			buf, header := allocate_websocket_frame_buffer(len(frame.payload), "DB response")
			if buf == nil do continue
			copy(buf[header:], frame.payload)
			_ = send_pooled_buffer(c, buf)
		} else {
			conv := get_conversation(get_workspace(job.request.workspace), frame.scope)
			if conv == nil || subscriber_count(conv) == 0 do continue
			buf, header := allocate_websocket_frame_buffer(len(frame.payload), "DB event")
			if buf == nil do continue
			copy(buf[header:], frame.payload)
			shared := new(Broadcast_Buffer, byte_pool.allocator(td.spool))
			shared^ = {
				data      = buf,
				ref_count = 1,
				pool      = td.spool,
			}
			excluded := net.TCP_Socket(-1)
			if frame.audience == .Other_Subscribers && c != nil do excluded = c.sock
			_ = send_shared_to_subscriber_entries(conv, excluded, shared, personal_owner = frame.private_owner)
		}
	}
}
