//
// worker.odin - Worker Thread Management
//
// This file handles worker thread functionality including:
// - Processing pending connections from channels
// - Worker thread lifecycle and initialization
// - Idle connection detection and cleanup
// - Thread-local resource cleanup on shutdown
// - Message sequence number generation for threads
//
package main

import "core:container/queue"
import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:time"

import "byte_pool"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import ulid "ulid"

WORKER_TICK_ACTIVE_TIMEOUT :: 250 * time.Microsecond
WORKER_TICK_IDLE_TIMEOUT :: 10 * time.Millisecond
WORKER_TICK_ACTIVITY_BURST_LOOPS :: 8

// Thread-local message sequence counter
@(thread_local)
message_seq_counter: pr.MessageSeq

// A short burst of real work keeps the loop on the fast cadence for a few
// iterations. Quiet loops decay back to the longer idle timeout.
@(thread_local)
worker_fast_tick_budget: int

// Generate a unique message sequence number for this thread
generate_message_seq :: proc() -> pr.MessageSeq {
	message_seq_counter += 1
	return message_seq_counter
}

// Intern a workspace ID string to avoid duplicate allocations.
// Returns an interned string owned by the thread-local intern pool.
intern_workspace_id :: proc(workspace_id: string) -> string {
	interned, err := strings.intern_get(&td.workspace_intern, workspace_id)
	if err != nil do panic("failed to intern workspace ID")
	return interned
}

// Intern a username string to avoid duplicate allocations and use-after-free bugs.
// All username map keys (user_dms, user_connection_count,
// user_authenticated_connection_count, user_last_seen)
// should use interned strings so they survive connection cleanup.
// Returns an interned string owned by the thread-local intern pool.
intern_username :: proc(username: string) -> string {
	interned, err := strings.intern_get(&td.workspace_intern, username)
	if err != nil do panic("failed to intern username")
	return interned
}

intern_room_mapping_name :: proc(room_name: string) -> string {
	interned, err := strings.intern_get(&td.workspace_intern, room_name)
	if err != nil do panic("failed to intern room mapping name")
	return interned
}

// Get or create a Workspace_State for the given workspace ID.
// Uses interned workspace_id as key for deduplication.
get_or_create_workspace :: proc(workspace_id: string) -> ^Workspace_State {
	interned := intern_workspace_id(workspace_id)
	if ws, ok := td.workspaces[interned]; ok {
		return ws
	}
	ws := new(Workspace_State)
	ws.conversations = make(map[pr.ConversationID]^Conversation_State, 64)
	ws.room_mappings = make(map[string]Room_Mapping_State, 64)
	ws.user_dms = make(map[string][dynamic]pr.ConversationID, 64)
	ws.user_connection_head = make(map[string]Connection_Handle, 256)
	ws.user_connection_next = make(map[Connection_Handle]Connection_Handle)
	ws.user_connection_count = make(map[string]int, 256)
	ws.user_authenticated_connection_count = make(map[string]int, 256)
	ws.user_last_seen = make(map[string]u64, 256)
	state_map_set(&td.workspaces, interned, ws)
	return ws
}

// Get Workspace_State if it exists, nil otherwise.
get_workspace :: proc(workspace_id: string) -> ^Workspace_State {
	return td.workspaces[workspace_id]
}

// Get cached Workspace_State for a connection if possible, falling back to the
// workspace map for tests and transitional paths that build connections manually.
get_connection_workspace :: #force_inline proc(c: ^NRC_Connection) -> ^Workspace_State {
	if c == nil {
		return nil
	}
	if c.workspace != nil {
		return c.workspace
	}
	ws := get_workspace(c.workspace_id)
	c.workspace = ws
	return ws
}

// Get or create the Workspace_State for a connection and cache the pointer on
// the connection. Workspace_State allocations are stable for the worker lifetime.
get_or_create_connection_workspace :: #force_inline proc(c: ^NRC_Connection) -> ^Workspace_State {
	if c == nil {
		return nil
	}
	if c.workspace != nil {
		return c.workspace
	}
	ws := get_or_create_workspace(c.workspace_id)
	c.workspace = ws
	return ws
}

// Get or create a Conversation_State for the given conversation in a workspace.
get_or_create_conversation :: proc(ws: ^Workspace_State, conv_id: pr.ConversationID) -> ^Conversation_State {
	if conv, ok := ws.conversations[conv_id]; ok {
		return conv
	}
	conv := new(Conversation_State)
	init_subscriber_index(conv)
	conv.tasks = make(map[pr.TaskID]^pr.Task, 128)
	init_task_index(conv)
	conv.assets = make(map[pr.AssetID]^pr.Asset, 128)
	init_note_index(conv)
	conv.edges = make(map[pr.EdgeID]^pr.Edge, 64)
	conv.edges_by_entity = make(map[Edge_Entity_Key][dynamic]pr.EdgeID, 64)
	state_map_set(&ws.conversations, conv_id, conv)
	return conv
}

// Get Conversation_State if it exists, nil otherwise.
get_conversation :: proc(ws: ^Workspace_State, conv_id: pr.ConversationID) -> ^Conversation_State {
	if ws == nil {
		return nil
	}
	return ws.conversations[conv_id]
}

process_pending_connections :: proc() -> bool {
	// Process items from this worker's SPSC queue without blocking.
	// Limit processing time to 5ms to maintain low tail latency for WebSocket messages
	start_time := nrc_time_now_monotonic()
	max_duration := 5 * time.Millisecond
	did_work := false

	for {
		// Check if we've exceeded the time budget
		if time.diff(start_time, nrc_time_now_monotonic()) > max_duration {
			pending_queue_rearm_wake(td.my_pending_queue)
			return did_work
		}

		pending_conn, ok := pending_queue_try_recv(td.my_pending_queue)
		if !ok {
			pending_queue_rearm_wake(td.my_pending_queue)
			return did_work
		}

		did_work = true

		worker_process_http_upgrade(pending_conn.upgrade)
	}
}

worker_adopt_upgraded_connection :: proc(upgrade: ^HTTP_Upgrade_Connection, bootstrap_http_response: []byte = nil) {
	upgrade_owned := true
	defer if upgrade_owned do http_temp_connection_free(upgrade)
	upgrade_allocator := http_upgrade_allocator(upgrade)
	sock := upgrade.sock
	workspace_id := upgrade.workspace_id
	verified_username := upgrade.verified_username

	if connection_get(sock) != nil {
		log.warnf("[T%d] Upgraded socket %v is already tracked", td.thread_index, sock)
		net.close(sock)
		return
	}

	c, conn_ok := connection_alloc()
	if !conn_ok {
		log.errorf("[T%d] Failed to allocate connection handle for upgraded socket %v", td.thread_index, sock)
		net.close(sock)
		return
	}
	send_queue_init(c)
	c.server = td.server
	c.sock = sock
	c.workspace_id = intern_workspace_id(workspace_id)
	c.verified_username = verified_username
	c.thread_index = td.thread_index
	c.state = .New
	c.last_activity = nrc_time_now_monotonic()
	c.user_type = upgrade.user_type

	if verified_username == "" {
		log.errorf("[T%d] Rejecting upgraded connection %v without verified identity", td.thread_index, sock)
		net.close(sock)
		send_queue_destroy(c)
		connection_remove(c)
		return
	}
	c.verified_username = intern_username(verified_username)
	upgrade.workspace_id = ""
	delete(workspace_id, upgrade_allocator)
	upgrade.verified_username = ""
	delete(verified_username, upgrade_allocator)

	connection_set_socket_handle(sock, c.handle)
	td.active_sockets[sock] = {}
	td.connection_count += 1

	if td.connection_count > MAX_CONNECTIONS_PER_THREAD {
		log.warnf("[T%d] Connection limit exceeded (%d), rejecting connection %v", td.thread_index, td.connection_count, sock)
		if len(bootstrap_http_response) > 0 {
			connection_close(c, false)
		} else {
			send_websocket_close_frame_and_close(c, 1013, "Server busy")
		}
		return
	}

	c.authenticated = upgrade.authenticated
	when ODIN_DEBUG do debug_log("[T%d] authenticated: %s", td.thread_index, c.verified_username)
	ws := get_or_create_connection_workspace(c)
	track_user_connection(c)
	on_user_connect(ws, c.verified_username, c.authenticated)

	if len(bootstrap_http_response) > 0 {
		// Completion may run synchronously in simulation, so transfer ownership
		// before enqueue and do not touch upgrade after this call.
		upgrade_owned = false
		if !send_server_bootstrap(c, bootstrap_http_response, upgrade) {
			connection_close(c, false)
		}
		return
	}

	if !send_server_ready(c) {
		connection_close(c, false)
		return
	}

	initial_ws_bytes := upgrade.http_remainder_buf[upgrade.http_header_end:upgrade.http_received]
	if len(initial_ws_bytes) > 0 {
		initial_ctx := connection_io_context_make(c)
		initial_ctx.pinned = connection_io_pin(c)
		on_recv_websocket_fixed(initial_ctx, len(initial_ws_bytes), initial_ws_bytes, {}, nil)
	} else {
		schedule_next_recv(c)
	}
}

worker_note_activity :: #force_inline proc() {
	worker_fast_tick_budget = WORKER_TICK_ACTIVITY_BURST_LOOPS
}

worker_decay_activity :: #force_inline proc() {
	if worker_fast_tick_budget > 0 {
		worker_fast_tick_budget -= 1
	}
}

worker_tick_timeout :: #force_inline proc() -> time.Duration {
	if queue.len(td.deferred_input_handles) > 0 do return 0
	timeout := WORKER_TICK_IDLE_TIMEOUT
	if worker_fast_tick_budget > 0 {
		timeout = WORKER_TICK_ACTIVE_TIMEOUT
	}
	for &writer in td.shard_writers.writers {
		if writer.commit_pending && !writer.fsync_in_flight {
			remaining := SHARD_COMMIT_WINDOW - time.diff(writer.commit_started, writer.wal.get_time())
			timeout = min(timeout, max(time.Duration(0), remaining))
		}
	}
	for &store in td.message_stores.stores {
		if store.commit_pending && !store.fsync_in_flight && store.wal.pending_bytes > 0 {
			remaining := RETAINED_COMMIT_WINDOW - time.diff(store.commit_started, store.wal.get_time())
			timeout = min(timeout, max(time.Duration(0), remaining))
		}
	}
	return timeout
}

worker_state_init_core :: proc(server: ^NRC_Server, thread_index: int, connection_capacity := MAX_CONNECTIONS_PER_THREAD) {
	assert(connection_capacity > 0 && connection_capacity <= MAX_CONNECTIONS_PER_THREAD)
	td.server = server
	td.thread_index = thread_index
	if server != nil && thread_index >= 0 {
		td.my_pending_queue = server.pending_connections[thread_index]
	}

	connection_storage_init()
	td.spool = byte_pool.init_buffer_pool()
	init_batch_state_pool()
	td.state = .Running
	td.active_sockets = make(map[net.TCP_Socket]struct{}, connection_capacity)
	// One handle per active connection is the hard upper bound. Reserve it once
	// so deferred fanout never allocates while processing callback waves.
	if qerr := queue.init(&td.deferred_outbox_handles, connection_capacity); qerr != nil {
		panic("failed to initialize deferred outbox queue")
	}
	if qerr := queue.init(&td.deferred_input_handles, connection_capacity); qerr != nil {
		panic("failed to initialize deferred input queue")
	}
	td.inflight_send_handles = make([dynamic]Connection_Handle, 0, connection_capacity)
	if err := strings.intern_init(&td.workspace_intern); err != nil do panic("failed to initialize worker intern pool")
	td.workspaces = make(map[string]^Workspace_State, 256)

	// Deterministic simulation uses the virtual runtime clock and must not trigger
	// the stdlib's potentially sleep-based per-thread TSC calibration.
	when !NRC_SIMULATION {
		ulid.init()
	}
}

worker_state_init_real_io :: proc() -> bool {
	errno := nbio.init(&td.io)
	if errno != linux.Errno.NONE {
		log.errorf("[T%d] Failed to initialize nbio: %v", td.thread_index, errno)
		return false
	}

	if err := nbio.pbuf_ring_init(&td.io); err != linux.Errno.NONE {
		log.errorf("[T%d] Failed to initialize buffer ring: %v", td.thread_index, err)
		return false
	}

	return true
}

worker_state_init_real_persistence :: proc() -> bool {
	if !init_active_sharded_worker_persistence(persistence.DATA_DIR, runtime_storage_layout.generation, td.thread_index, thread_count) do return false
	generation_dir := sharded_generation_path(persistence.DATA_DIR, runtime_storage_layout.generation)
	defer delete(generation_dir)
	return init_message_store_registry(&td.message_stores, generation_dir, td.thread_index, thread_count)
}

worker_state_start_real_timers :: proc() {
	td.next_send_watchdog_at = {}
	start_worker_maintenance_timer()
}

// Publish work produced by one completed I/O callback wave. io_uring runs every
// completion already collected by a tick before the worker reaches this boundary;
// retained writes and normal fanout therefore become visible only after that wave.
worker_finish_callback_wave :: proc() -> (did_work, ok: bool) {
	ok = true
	if !td.collect_presence_updates do begin_presence_batch_wave()
	if drain_deferred_input() do did_work = true
	defer {td.input_budget_active = false}
	message_writes, message_writes_ok := flush_pending_retained_message_writes(&td.message_stores)
	if message_writes do did_work = true
	if !message_writes_ok {
		log.errorf("[T%d] Retained message WAL batch failed; shutting down", td.thread_index)
		if td.server != nil do server_shutdown_after_storage_error(td.server)
		ok = false
	}
	if drain_deferred_outbox_pumps() {
		did_work = true
	}
	// Publication can itself reject slow peers. Keep their departures batched
	// until both retained-message fanout and deferred outbox pumping are done.
	if finish_presence_batch_wave() do did_work = true
	when !NRC_SIMULATION {
		if did_work {
			if submit_err := nbio.submit_all_pending(&td.io); submit_err != .NONE {
				log.errorf("[T%d] Failed to publish deferred message fanout: %v", td.thread_index, submit_err)
				ok = false
			}
		}
	}
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && queue.len(td.deferred_input_handles) > 0 {
			nrc_sim_schedule_input_turn(&nrc_sim_runtime.world)
		}
	}
	return
}

// Run the ordered userspace phases that precede one non-blocking I/O tick.
// Later phases may consume state published by earlier phases in the same turn;
// in particular, preemptive WAL rotation can make compaction work immediately
// eligible for issuance.
worker_run_pre_tick :: proc() -> (did_work: bool) {
	did_work = process_pending_connections()
	did_sync, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
	if !sync_ok {
		log.errorf("[T%d] Shard WAL durability sync failed; shutting down", td.thread_index)
		server_shutdown_after_storage_error(td.server)
	}
	if did_sync do did_work = true
	message_work, message_ok := maintain_message_store_registry(&td.message_stores)
	if !message_ok {
		log.errorf("[T%d] Message store maintenance failed; shutting down", td.thread_index)
		server_shutdown_after_storage_error(td.server)
	}
	if message_work do did_work = true
	if process_shard_compaction_results() do did_work = true
	if schedule_shard_compaction_work() do did_work = true
	return
}

worker_thread :: proc(worker_data: Worker_Thread_Data) {
	defer jwt_validation_scratch_destroy()
	worker_state_init_core(worker_data.server, worker_data.thread_index)

	// Pin only to CPUs permitted by the process affinity/cgroup. If a CPU is
	// available beyond the configured worker count, keep it for the main and
	// compactor service roles. Single-CPU systems intentionally share one CPU.
	if !cpu_affinity_disabled() {
		worker_cpu := cpu_role_worker_cpu(&cpu_role_plan, td.thread_index)
		if worker_cpu >= 0 do set_thread_cpu_affinity(worker_cpu)
	}

	if !worker_state_init_real_io() {
		_ = chan.send(td.server.worker_startup, false)
		sync.wait_group_done(&td.server.wg)
		return
	}

	if !worker_state_init_real_persistence() {
		_ = chan.send(td.server.worker_startup, false)
		sync.wait_group_done(&td.server.wg)
		return
	}
	worker_state_start_real_timers()
	_ = chan.send(td.server.worker_startup, true)

	log.infof("[T%d] Worker thread started.", td.thread_index)

	for {
		if sync.atomic_load(&td.server.closing) do _server_thread_shutdown(td.server)
		if td.state == .Closed do break

		begin_input_turn()
		begin_presence_batch_wave()
		did_work := worker_run_pre_tick()

		tick_stats_before := nbio.get_stats(&td.io)
		errno2 := nbio.tick(&td.io, worker_tick_timeout(), td.my_pending_queue.wake_fd, yield_after_callbacks = true)
		if errno2 != linux.Errno.NONE {
			log.errorf("[T%d] nbio tick error: %v", td.thread_index, errno2)
			time.sleep(100 * time.Millisecond)
		} else {
			tick_stats_after := nbio.get_stats(&td.io)
			if tick_stats_after.total_completions > tick_stats_before.total_completions {
				did_work = true
			}
		}
		callback_work, _ := worker_finish_callback_wave()
		if callback_work do did_work = true

		if did_work {
			worker_note_activity()
		} else {
			worker_decay_activity()
		}
	}

	when ODIN_DEBUG do debug_log("[T%d] Worker thread exiting - notifying wait group", td.thread_index)
	sync.wait_group_done(&td.server.wg)
}

run_worker_maintenance :: proc() {
	now := nrc_time_now_monotonic()
	check_idle_connections(now)
	if td.next_send_watchdog_at != {} && time.diff(td.next_send_watchdog_at, now) >= 0 {
		check_stalled_sends(now)
	}
}

// Run bounded idle maintenance every 100ms and scan the indexed stalled sends
// when their earliest deadline is due, without a full active-connection scan.
start_worker_maintenance_timer :: proc() {
	// Don't schedule new timers during shutdown
	if sync.atomic_load(&td.server.closing) {
		return
	}

	td.maintenance_completion = nrc_schedule_timer(
	Worker_Maintenance_Interval,
	&td.thread_index, // Pass thread index as context
	proc(thread_index: ^int) {
		// Don't do work or reschedule during shutdown
		if sync.atomic_load(&td.server.closing) {
			td.maintenance_completion = nil
			return
		}
		run_worker_maintenance()
		start_worker_maintenance_timer()
	},
	)
}

// Consolidated cleanup for all workspace state (replaces 6 separate cleanup procs)
// NOTE: Only use in tests. The OS cleans up when the program ends anyway.
cleanup_workspaces :: proc() {
	for _, ws in td.workspaces {
		// Clean up user_dms map (dynamic arrays inside)
		for _, dms in ws.user_dms {
			delete(dms)
		}
		delete(ws.user_dms)

		// Clean up the per-user connection index, counts, and last-seen maps.
		delete(ws.user_connection_head)
		delete(ws.user_connection_next)
		delete(ws.user_connection_count)
		delete(ws.user_authenticated_connection_count)
		delete(ws.user_last_seen)
		delete(ws.room_mappings)

		for _, conv in ws.conversations do destroy_conversation(conv)
		delete(ws.conversations)
		free(ws)
	}
	delete(td.workspaces)
}

destroy_conversation :: proc(conv: ^Conversation_State) {
	// No worker batch may retain this conversation after its allocation is freed.
	for flush_presence_batch(conv) {}
	destroy_subscriber_index(conv)
	if conv.agenda != "" do delete(conv.agenda)
	for _, task in conv.tasks do free_task(task)
	delete(conv.tasks)
	destroy_task_index(conv)
	for _, asset in conv.assets do free_asset(asset)
	delete(conv.assets)
	destroy_note_index(conv)
	for _, edge in conv.edges do free_edge(edge)
	delete(conv.edges)
	for _, edge_list in conv.edges_by_entity do delete(edge_list)
	delete(conv.edges_by_entity)
	// Participant strings are interned, not owned by the conversation.
	if conv.dm_participants != nil do free(conv.dm_participants)
	free(conv)
}

// worker_state_destroy_core_for_test releases state created by worker_state_init_core
// without touching real IO or persistence. Tests and the deterministic simulator can
// use this to boot handler/runtime state without starting nbio.
worker_state_destroy_core_for_test :: proc() {
	discard_deferred_input()
	assert(td.shared_fanout_depth == 0, "test teardown with active shared fanout")
	assert(!td.draining_presence_updates, "test teardown while draining deferred presence")
	assert(len(td.deferred_presence_updates) == 0, "test teardown with deferred presence updates")
	assert(!td.collect_presence_updates && td.presence_batch_count == 0, "test teardown with pending presence batches")
	assert(td.defer_normal_outbox_pumps == 0, "test teardown while collecting deferred outboxes")
	assert(deferred_outbox_pump_count() == 0, "test teardown with deferred outboxes")
	assert(len(td.inflight_send_handles) == 0, "test teardown with indexed in-flight sends")
	cleanup_workspaces()
	td.workspaces = nil

	if td.active_sockets != nil {
		delete(td.active_sockets)
		td.active_sockets = nil
	}
	delete(td.deferred_presence_updates)
	td.deferred_presence_updates = nil
	queue.destroy(&td.deferred_outbox_handles)
	td.deferred_outbox_handles = {}
	queue.destroy(&td.deferred_input_handles)
	td.deferred_input_handles = {}
	delete(td.inflight_send_handles)
	td.inflight_send_handles = nil
	td.shared_fanout_depth = 0
	td.draining_presence_updates = false
	td.defer_normal_outbox_pumps = 0
	td.idle_scan_cursor = 0
	td.next_send_watchdog_at = {}
	td.connection_count = 0

	strings.intern_destroy(&td.workspace_intern)
	destroy_batch_state_pool()
	connection_storage_destroy()

	if td.spool != nil {
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = nil
	}

	td.state = .Closed
}

_server_thread_shutdown :: proc(s: ^NRC_Server, loc := #caller_location) {
	log.infof("[T%d] Shutting down worker thread...", td.thread_index)
	td.state = .Closing
	discard_deferred_input()
	discard_deferred_outbox_pumps()
	// Cap-deferred requests can pin connections without an fsync in flight.
	// Release them before waiting for retained connections to retire.
	for &writer in td.shard_writers.writers do discard_shard_deferred_requests(&writer)
	cancel_message_seals(&td.message_stores)

	// We shutdown the process/server
	// No value in cleaning up all allocations

	// Cancel worker-owned periodic timers before waiting for all callbacks.
	log.infof("[T%d] Cancelling pending timers...", td.thread_index)
	nrc_cancel_timer(td.maintenance_completion)

	log.infof("[T%d] Starting connection cleanup loop, connection_count=%d", td.thread_index, td.connection_count)

	for i := 0;; i += 1 {
		// Collect sockets to close (avoid modifying list during iteration)
		sockets_to_close := make([dynamic]net.TCP_Socket, 0, 64)
		defer delete(sockets_to_close)

		for sock in td.active_sockets {
			conn := connection_get(sock)
			if conn == nil do continue
			#partial switch conn.state {
			case .Active, .New, .Idle, .Pending, .Will_Close:
				append(&sockets_to_close, sock)
			case .Closing:
				when ODIN_DEBUG do if i % 10_000 == 0 do debug_log("shutdown: connection is closing")
			case .Closed:
				log.warn("closed connection in connections array, maybe a race or logic error")
			}
		}

		// Close collected connections
		for sock in sockets_to_close {
			if conn := connection_get(sock); conn != nil {
				when ODIN_DEBUG do debug_log("shutdown: closing connection %v", sock)
				connection_close(conn, true)
			}
		}

		when ODIN_DEBUG do debug_log("[T%d] Shutdown iteration %d: %d connections remaining", td.thread_index, i, td.connection_count)
		if td.connection_count == 0 && td.retained_connection_count == 0 && nbio.num_waiting(&td.io) == 0 {
			break
		}

		when ODIN_DEBUG do debug_log("[T%d] Calling nbio.tick for shutdown", td.thread_index)
		err := nbio.tick(&td.io, 1 * time.Millisecond)
		when ODIN_DEBUG do debug_log("[T%d] nbio.tick returned", td.thread_index)
		fmt.assertf(err == linux.Errno.NONE, "IO tick error during shutdown: %v")
		_, message_writes_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !message_writes_ok do server_shutdown_after_storage_error(td.server)
	}

	log.infof("[T%d] All connections closed.", td.thread_index)
	log.infof("[T%d] Timers cancelled, starting drain...", td.thread_index)

	// Drain remaining I/O (closes, cancelled timers, etc.) before destroying io_uring
	drain_start := nrc_time_now()
	drain_timeout := 100 * time.Millisecond
	drain_iteration := 0
	for {
		waiting := nbio.num_waiting(&td.io)
		if waiting == 0 {
			log.infof("[T%d] Drain complete after %d iterations", td.thread_index, drain_iteration)
			break
		}
		elapsed := time.diff(drain_start, nrc_time_now())
		if elapsed > drain_timeout {
			log.warnf("[T%d] Drain timeout after %d iterations with %d operations pending (elapsed: %v)", td.thread_index, drain_iteration, waiting, elapsed)
			break
		}
		when ODIN_DEBUG do if drain_iteration % 100 == 0 do debug_log("[T%d] Draining IO: %d operations still pending (iteration %d)", td.thread_index, waiting, drain_iteration)
		err := nbio.tick(&td.io, 1 * time.Millisecond)
		if err != linux.Errno.NONE {
			log.errorf("[T%d] IO tick error during drain: %v", td.thread_index, err)
			break
		}
		_, message_writes_ok := flush_pending_retained_message_writes(&td.message_stores)
		if !message_writes_ok do server_shutdown_after_storage_error(td.server)
		drain_iteration += 1
	}

	log.infof("[T%d] IO drained. Flushing persistence WALs...", td.thread_index)
	if !shutdown_message_store_registry(&td.message_stores) {
		log.errorf("[T%d] Final message store durability sync failed during shutdown", td.thread_index)
		server_shutdown_after_storage_error(td.server)
	}

	if !shutdown_shard_writer_registry(&td.shard_writers) {
		log.errorf("[T%d] Final shard WAL durability sync failed during shutdown", td.thread_index)
		server_shutdown_after_storage_error(td.server)
	}
	assert(td.shared_fanout_depth == 0, "worker shutdown with active shared fanout")
	assert(!td.draining_presence_updates, "worker shutdown while draining deferred presence")
	assert(len(td.deferred_presence_updates) == 0, "worker shutdown with deferred presence updates")
	assert(td.defer_normal_outbox_pumps == 0, "worker shutdown while collecting deferred outboxes")
	assert(deferred_outbox_pump_count() == 0, "worker shutdown with deferred outboxes")
	assert(len(td.inflight_send_handles) == 0, "worker shutdown with indexed in-flight sends")
	delete(td.deferred_presence_updates)
	td.deferred_presence_updates = nil
	queue.destroy(&td.deferred_outbox_handles)
	td.deferred_outbox_handles = {}
	queue.destroy(&td.deferred_input_handles)
	td.deferred_input_handles = {}
	delete(td.inflight_send_handles)
	td.inflight_send_handles = nil

	// Connection handles and batch metadata are callback-owned. The loop above
	// must retain this infrastructure until every close and transport pin retires.
	destroy_batch_state_pool()
	connection_storage_destroy()
	log.infof(
		"[T%d] Batch pool stats: alloc=%d reuse=%d release=%d drop=%d heap_alloc=%d heap_free=%d",
		td.thread_index,
		td.batch_state_pool.pooled_allocations,
		td.batch_state_pool.pooled_reuses,
		td.batch_state_pool.pooled_releases,
		td.batch_state_pool.pooled_drops,
		td.batch_state_pool.heap_fallback_allocs,
		td.batch_state_pool.heap_fallback_frees,
	)
	td.state = .Closed
	log.infof("[T%d] Worker thread shutdown complete.", td.thread_index)
}
