package main

import "core:log"
import "core:strings"
import "core:sys/linux"
import "core:time"
import nbio "nbio/poly"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

// Startup and isolated tests attach one SPSC port owned by this worker.
WORKER_DB_COMPLETION_BUDGET :: 64
Worker_DB_Callback :: #type proc(connection: ^NRC_Connection, correlation: u32, completion: ^db.Completion)
Worker_DB_Pending :: struct {
	handle:            Connection_Handle,
	username, subject: string,
	user_type:         pr.User_Type,
	chronicle_access:  u8,
	correlation:       u32,
	callback:          Worker_DB_Callback,
}
Worker_DB_DM_Key :: struct {
	workspace: ^Workspace_State,
	id:        pr.ConversationID,
}
Worker_DB :: struct {
	idle_dms:        map[Worker_DB_DM_Key]bool,
	port:            ^db.Worker_Port,
	pending:         map[u64]Worker_DB_Pending,
	next_request:    u64,
	stopping:        bool,
	monitor_pending: bool,
	monitor_shard:   int,
	monitor_cursors: [LOGICAL_SHARD_COUNT]u64,
	monitor_through: [LOGICAL_SHARD_COUNT]u64,
	monitor_due:     [LOGICAL_SHARD_COUNT]time.Time,
	monitor_budget:  int,
}

worker_db_attach :: proc(port: ^db.Worker_Port) {
	assert(td.database.port == nil && port != nil && port.in_flight == 0 && !port.closed)
	td.database.port = port
	td.database.idle_dms = make(map[Worker_DB_DM_Key]bool)
	td.database.pending = make(map[u64]Worker_DB_Pending, port.executor.capacity, worker_backing_allocator())
}

// Internal storage operations, NOT authorized protocol commands. Domain handlers
// must enforce their scope/ACL rules; private records need DB authorization and
// visibility rechecks before sending. Callbacks always run, even with a nil recipient,
// so a disconnected initiator cannot suppress committed mutation broadcasts.
// Completion data is borrowed until the callback returns. Callbacks must not
// detach/destroy the transport or keep its payload pointers.
worker_db_submit :: proc(c: ^NRC_Connection, request: db.Request, correlation: u32, callback: Worker_DB_Callback, admission_error: ^string = nil) -> bool {
	if admission_error != nil do admission_error^ = "Server too busy"
	state := &td.database
	if state.port == nil || state.stopping || callback == nil || c == nil do return false
	if !c.authenticated || c.state < .New || c.state >= .Will_Close || connection_get_by_handle(c.handle) != c do return false
	if state.next_request == max(u64) do return false
	id := state.next_request + 1
	owned_request := request
	owned_request.request_id = id
	owned_request.ordering_key = transmute(u64)c.handle
	owned_request.workspace = c.workspace_id
	owned_request.actor = c.verified_username
	owned_request.subject = c.verified_subject
	owned_request.chronicle_access = c.chronicle_access
	owned_request.review_portal = c.user_type == .Bot && c.verified_username == "nrc-tickets"
	owned_request.portal_account_admin = c.portal_account_admin
	owned_request.portal_account_bot = c.portal_account_bot
	if request.operation == .Create_Task {
		owned_request.task.created_by = transmute([]byte)c.verified_username
	}
	allocator := worker_backing_allocator()
	username, err := strings.clone(c.verified_username, allocator)
	if err != .None do return false
	subject, subject_err := strings.clone(c.verified_subject, allocator)
	if subject_err != .None {delete(username, allocator); return false}
	rejection: db.Admission_Rejection
	if !db.submit(state.port, owned_request, &rejection) {
		if admission_error != nil {
			if rejection == .Connection_Limit do admission_error^ = "db_connection_overloaded"
			if rejection == .Worker_Limit do admission_error^ = "db_worker_overloaded"
		}
		delete(username, allocator)
		delete(subject, allocator)
		return false
	}
	state.next_request = id
	state.pending[id] = {
		handle           = c.handle,
		username         = username,
		subject          = subject,
		user_type        = c.user_type,
		chronicle_access = c.chronicle_access,
		correlation      = correlation,
		callback         = callback,
	}
	return true
}

worker_db_drain :: proc() -> (did_work: bool) {
	state := &td.database
	port := state.port
	if port == nil do return false
	for _ in 0 ..< WORKER_DB_COMPLETION_BUDGET {
		job, ok := db.receive(port)
		if !ok do break
		did_work = true
		pending, exists := state.pending[job.request.request_id]
		assert(exists, "completion without worker routing state")
		c := connection_get_by_handle(pending.handle)
		if c != nil {
			if state.stopping ||
			   !c.authenticated ||
			   c.state < .New ||
			   c.state >= .Will_Close ||
			   c.workspace_id != job.request.workspace ||
			   c.verified_username != pending.username ||
			   c.verified_subject != pending.subject ||
			   c.chronicle_access != pending.chronicle_access ||
			   job.request.chronicle_access != pending.chronicle_access ||
			   c.user_type != pending.user_type {
				c = nil
			}
		}
		if job.result.delivery_failed {
			// The transaction already committed. Force a fresh snapshot rather
			// than reporting rollback or leaving subscribers with partial events.
			handles := make([dynamic]Connection_Handle)
			defer delete(handles)
			for sock in td.active_sockets {
				client := connection_get(sock)
				if client != nil && client.workspace_id == job.request.workspace do append(&handles, client.handle)
			}
			for handle in handles {
				client := connection_get_by_handle(handle)
				if client != nil do send_websocket_close_frame_and_close(client, 1011, "Storage result unavailable; reconnect")
			}
		} else {
			pending.callback(c, pending.correlation, job)
		}
		if !job.result.command.more {
			delete_key(&state.pending, job.request.request_id)
			delete(pending.username, worker_backing_allocator())
			delete(pending.subject, worker_backing_allocator())
		}
		db.release_completion(port, job)
	}
	// Also re-signal a remaining batch so a budget yield never sleeps on work.
	db.rearm_completions(port)
	return
}

worker_db_wake_fd :: proc() -> linux.Fd {
	if td.database.port == nil do return -1
	return td.database.port.wake.fd
}

worker_wait_io :: proc(timeout: time.Duration) -> linux.Errno {
	return nbio.tick(
		&td.io,
		timeout,
		td.my_pending_queue.wake_ready ? td.my_pending_queue.wake_fd : -1,
		yield_after_callbacks = true,
		callback_limit = WORKER_CALLBACK_BUDGET,
		extra_wake_fd = worker_db_wake_fd(),
	)
}

worker_db_begin_shutdown :: proc() {
	if td.database.port == nil || td.database.stopping do return
	td.database.stopping = true
	db.finish_submissions(td.database.port)
}

// The coordinator still owns joining/destroying the executor after ALL workers
// have finished. Detach only once this worker has consumed its completions.
worker_db_detach :: proc() {
	if td.database.port == nil do return
	assert(td.database.stopping && len(td.database.pending) == 0 && td.database.port.in_flight == 0)
	delete(td.database.pending)
	delete(td.database.idle_dms)
	td.database = {}
}

worker_db_mark_dm :: proc(ws: ^Workspace_State, id: pr.ConversationID) {
	if td.database.port == nil || !pr.is_dm_conversation(id) do return
	td.database.idle_dms[{ws, id}] = true
}

MONITOR_MAINTENANCE_JOBS_PER_TICK :: 8
MONITOR_MAINTENANCE_RECHECK :: 5 * time.Second

// A bounded burst per timer tick, still only one job in flight. Completions
// continue the burst; rotating ready shards prevents a large shard monopolizing it.
worker_db_monitor_maintenance :: proc() {
	state := &td.database
	if state.port == nil || td.server == nil || state.stopping || state.monitor_pending || state.next_request == max(u64) do return
	state.monitor_budget = MONITOR_MAINTENANCE_JOBS_PER_TICK
	worker_db_submit_monitor_maintenance()
}

worker_db_submit_monitor_maintenance :: proc() {
	state := &td.database
	if state.stopping || state.monitor_pending || state.monitor_budget == 0 || state.next_request == max(u64) do return
	workers := len(td.server.threads)
	if workers == 0 do return
	now := nrc_time_now_monotonic()
	shard := state.monitor_shard
	found := false
	for _ in 0 ..< LOGICAL_SHARD_COUNT {
		if shard % workers == td.thread_index &&
		   shard < len(state.port.executor.paths) &&
		   len(string(state.port.executor.paths[shard])) != 0 &&
		   (state.monitor_due[shard] == {} || time.diff(state.monitor_due[shard], now) >= 0) {
			found = true
			break
		}
		shard = (shard + 1) % LOGICAL_SHARD_COUNT
	}
	if !found do return
	id := state.next_request + 1
	request := db.Request {
		request_id      = id,
		shard           = shard,
		operation       = .Monitor_Maintenance,
		timestamp       = nrc_time_unix_nanos(),
		monitor_cursor  = state.monitor_cursors[shard],
		monitor_through = state.monitor_through[shard],
	}
	if !db.submit(state.port, request) do return
	state.monitor_budget -= 1
	state.next_request = id
	state.monitor_pending = true
	state.monitor_shard = (shard + 1) % LOGICAL_SHARD_COUNT
	state.pending[id] = {
		callback = worker_db_monitor_maintenance_complete,
	}
}

worker_db_monitor_maintenance_complete :: proc(_: ^NRC_Connection, _: u32, job: ^db.Completion) {
	state := &td.database
	state.monitor_pending = false
	if job.result.status == sql.OK {
		state.monitor_cursors[job.request.shard] = job.result.command.monitor_cursor
		state.monitor_through[job.request.shard] = job.result.command.monitor_through
	} else {
		// Keep this shard's cursor for retry on the next round; other shards proceed.
		log.errorf("[T%d] Monitor maintenance failed for shard %d: %d", td.thread_index, job.request.shard, job.result.status)
	}
	if job.result.status != sql.OK || job.result.command.monitor_through == 0 {
		state.monitor_due[job.request.shard] = time.time_add(nrc_time_now_monotonic(), MONITOR_MAINTENANCE_RECHECK)
	}
	worker_db_submit_monitor_maintenance()
}

// Presence batches may borrow conversation pointers until the wave finishes.
worker_db_evict_idle_dms :: proc() -> bool {
	if len(td.database.idle_dms) == 0 do return false
	for key in td.database.idle_dms {
		conv := get_conversation(key.workspace, key.id)
		if conv == nil || conv.dm_participants == nil || !conv.dm_participants.owned_names || subscriber_count(conv) != 0 do continue
		remove_user_dm(key.workspace, conv.dm_participants.user_a, key.id)
		remove_user_dm(key.workspace, conv.dm_participants.user_b, key.id)
		delete_key(&key.workspace.conversations, key.id)
		destroy_conversation(conv)
	}
	clear(&td.database.idle_dms)
	return true
}
