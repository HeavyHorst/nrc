package main

// Simulation-only helper tests for the deterministic runtime used by integrated
// handler properties. The file validates the fake socket/event plumbing and basic
// simulation contracts that larger DST fixtures depend on, while compiling away
// to small suppressions in normal non-simulation test builds.

import "base:runtime"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:net"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "byte_pool"
import hgl "hegel"
import nbio "nbio/poly"
import pr "protocol"
import "storage_io"
import tlsf "vendor/tlsf"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: fmt.eprintf
	_ :: log.nil_logger
	_ :: net.TCP_Socket
	_ :: runtime.Allocator{}
	_ :: linux.Errno
	_ :: time.Millisecond
	_ :: byte_pool.alloc
	_ :: hgl.run
	_ :: nbio.iovec
	_ :: pr.get_opcode
	_ :: storage_io.Context
	_ :: tlsf.Allocator
}

when NRC_SIMULATION {
	SIM_TEST_MAX_CLIENTS :: 16

	Receive_Growth_OOM_Allocator :: struct {
		backing:       runtime.Allocator,
		failed_once:   bool,
		failure_count: int,
	}

	receive_growth_oom_allocator_proc :: proc(
		allocator_data: rawptr,
		mode: runtime.Allocator_Mode,
		size, alignment: int,
		old_memory: rawptr,
		old_size: int,
		location := #caller_location,
	) -> (
		[]byte,
		runtime.Allocator_Error,
	) {
		state := (^Receive_Growth_OOM_Allocator)(allocator_data)
		if !state.failed_once && (mode == .Alloc || mode == .Alloc_Non_Zeroed) {
			state.failed_once = true
			state.failure_count += 1
			return nil, .Out_Of_Memory
		}
		return state.backing.procedure(state.backing.data, mode, size, alignment, old_memory, old_size, location)
	}

	Sim_Test_Context :: struct {
		sim:     Sim_Runtime,
		conns:   [SIM_TEST_MAX_CLIENTS]^NRC_Connection,
		heap:    tlsf.Allocator,
		backing: runtime.Allocator,
	}

	Sim_Quiescence_Drain_Result :: enum u8 {
		Reached,
		Budget_Exhausted,
		Current_Incarnation_Stalled,
		Stale_Incarnation_Stalled,
		Dispatch_Failed,
	}

	Sim_Quiescence_Baseline :: struct {
		pool_live:            uint,
		pool_used:            u64,
		pool_outstanding:     u64,
		invalid_releases:     u64,
		active_connections:   int,
		retained_connections: int,
	}

	sim_worker_quiescence_baseline :: proc() -> Sim_Quiescence_Baseline {
		return {
			pool_live = connection_lifetime_pool_live_alloc_count(td.spool),
			pool_used = td.spool.used,
			pool_outstanding = td.spool.allocation_count - td.spool.release_count,
			invalid_releases = td.spool.invalid_release_count,
			active_connections = td.connection_count,
			retained_connections = td.retained_connection_count,
		}
	}

	sim_world_drain_bounded :: proc(world: ^Sim_World, event_budget: int) -> (dispatched: int, result: Sim_Quiescence_Drain_Result) {
		if world == nil || event_budget < 0 do return 0, .Dispatch_Failed
		for len(world.events) > 0 {
			if dispatched >= event_budget do return dispatched, .Budget_Exhausted
			if sim_world_prepare_runnable(world) == 0 {
				for event in world.events {
					if event.process_incarnation == world.process_incarnation {
						return dispatched, .Current_Incarnation_Stalled
					}
				}
				return dispatched, .Stale_Incarnation_Stalled
			}
			if !sim_world_run_runnable_rank(world, 0) do return dispatched, .Dispatch_Failed
			dispatched += 1
		}
		return dispatched, .Reached
	}

	sim_worker_transport_quiescence_reason :: proc(handles: []Connection_Handle, baseline: Sim_Quiescence_Baseline) -> string {
		if td.shared_fanout_depth != 0 || td.draining_presence_updates || len(td.deferred_presence_updates) != 0 {
			return "worker fanout or presence work remains"
		}
		if len(td.inflight_send_handles) != 0 do return "worker send watchdog handles remain indexed"
		if deferred_outbox_pump_count() != 0 || td.defer_normal_outbox_pumps != 0 do return "worker deferred outbox work remains"
		if td.connection_count != baseline.active_connections || td.retained_connection_count != baseline.retained_connections {
			return "worker connection counts differ"
		}
		if len(handles) != baseline.retained_connections do return "worker retained connection set is incomplete"
		active_count := 0
		for handle, handle_index in handles {
			for prior_index in 0 ..< handle_index {
				if handles[prior_index] == handle do return "worker retained connection set contains duplicates"
			}
			conn := connection_get_by_handle(handle)
			if conn == nil || conn.handle != handle || conn.thread_index != td.thread_index {
				return "worker retained connection handle does not resolve locally"
			}
			if connection_get(conn.sock) == conn do active_count += 1
			if conn.pending_io != 0 || conn.retained_io != 0 || conn.deferred_shard_requests != 0 do return "connection I/O ownership remains"
			if conn.recv_completion != nil do return "connection receive completion remains"
			if conn.is_sending ||
			   conn.send_watchdog_slot != 0 ||
			   send_queue_len(conn) != 0 ||
			   conn.inline_len != 0 ||
			   connection_test_send_queue_backing_len(conn) != 0 {
				return "connection send work remains"
			}
			if conn.outbox_pump_deferred do return "connection deferred outbox marker remains"
			if conn.receive_accumulator.buf != nil || conn.receive_accumulator.used != 0 || conn.receive_accumulator.target != 0 {
				return "connection receive accumulator remains"
			}
			if conn.fragment_buf != nil || conn.fragment_len != 0 do return "connection fragment accumulator remains"
		}
		if active_count != baseline.active_connections do return "worker active connection set is incomplete"
		if connection_lifetime_pool_live_alloc_count(td.spool) != baseline.pool_live do return "worker pooled lease count differs"
		if td.spool.used != baseline.pool_used do return "worker pooled byte usage differs"
		if td.spool.allocation_count - td.spool.release_count != baseline.pool_outstanding do return "worker pooled allocation balance differs"
		if td.spool.invalid_release_count != baseline.invalid_releases do return "worker invalid pooled release count differs"
		return ""
	}

	sim_worker_quiescence_reason :: proc(handles: []Connection_Handle, baseline: Sim_Quiescence_Baseline) -> string {
		for &writer in td.shard_writers.writers {
			if writer.poisoned || !writer.wal.enabled do return "writer is poisoned or disabled"
			if writer.fsync_in_flight do return "writer fsync remains in flight"
			if writer.compaction != .Idle do return "writer compaction remains active"
			if len(writer.deferred_requests) != 0 || writer.deferred_request_bytes != 0 do return "writer deferred requests remain queued"
			if writer.prepared_active_generation != 0 do return "writer active reservation remains prepared"
			if writer.wal.pending_bytes != 0 ||
			   writer.wal.durable_record_count != writer.wal.record_count ||
			   writer.wal.write_offset != 0 ||
			   writer.wal.buffered_record_count != 0 {
				return "writer WAL remains nondurable"
			}
		}
		return sim_worker_transport_quiescence_reason(handles, baseline)
	}

	sim_quiescence_count_action :: proc(user: rawptr) {
		count := (^int)(user)
		count^ += 1
	}

	@(test)
	test_simulation_bounded_quiescence_drain_classifies_budget_and_dependency_stalls :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 97)
		defer simulation_test_end(&ctx)

		called := 0
		first := sim_world_enqueue_driver_action(&ctx.sim.world, &called, sim_quiescence_count_action)
		second := sim_world_enqueue_driver_action(&ctx.sim.world, &called, sim_quiescence_count_action)
		testing.expect(t, first != 0 && second != 0)
		dispatched, result := sim_world_drain_bounded(&ctx.sim.world, 1)
		testing.expect_value(t, dispatched, 1)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Budget_Exhausted)
		testing.expect_value(t, called, 1)
		dispatched, result = sim_world_drain_bounded(&ctx.sim.world, 1)
		testing.expect_value(t, dispatched, 1)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		testing.expect_value(t, called, 2)

		first_expected := ctx.sim.world.next_event_id + 1
		second_expected := first_expected + 1
		first = sim_world_enqueue_driver_action(&ctx.sim.world, &called, sim_quiescence_count_action, second_expected)
		second = sim_world_enqueue_driver_action(&ctx.sim.world, &called, sim_quiescence_count_action, first)
		testing.expect_value(t, first, first_expected)
		testing.expect_value(t, second, second_expected)
		dispatched, result = sim_world_drain_bounded(&ctx.sim.world, 4)
		testing.expect_value(t, dispatched, 0)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Current_Incarnation_Stalled)
		testing.expect_value(t, called, 2)

		sim_world_crash(&ctx.sim.world)
		dispatched, result = sim_world_drain_bounded(&ctx.sim.world, 4)
		testing.expect_value(t, dispatched, 0)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Stale_Incarnation_Stalled)
		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, second))
		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, first))
		dispatched, result = sim_world_drain_bounded(&ctx.sim.world, 0)
		testing.expect_value(t, dispatched, 0)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Reached)
		dispatched, result = sim_world_drain_bounded(nil, 1)
		testing.expect_value(t, dispatched, 0)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Dispatch_Failed)
		dispatched, result = sim_world_drain_bounded(&ctx.sim.world, -1)
		testing.expect_value(t, dispatched, 0)
		testing.expect_value(t, result, Sim_Quiescence_Drain_Result.Dispatch_Failed)
	}

	@(test)
	test_simulation_worker_quiescence_checker_rejects_internal_work :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 97)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "quiescence", "owner", init_send_queue = true)
		if !testing.expect(t, conn != nil) do return
		ctx.conns[0] = conn
		handles := [1]Connection_Handle{conn.handle}
		baseline := sim_worker_quiescence_baseline()
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "")
		testing.expect_value(t, sim_worker_quiescence_reason(nil, baseline), "worker retained connection set is incomplete")
		wrong_handle := [1]Connection_Handle{{}}
		testing.expect_value(t, sim_worker_quiescence_reason(wrong_handle[:], baseline), "worker retained connection handle does not resolve locally")
		duplicate_handles := [2]Connection_Handle{conn.handle, conn.handle}
		td.retained_connection_count += 1
		duplicate_baseline := baseline
		duplicate_baseline.retained_connections += 1
		testing.expect_value(t, sim_worker_quiescence_reason(duplicate_handles[:], duplicate_baseline), "worker retained connection set contains duplicates")
		td.retained_connection_count -= 1
		conn.thread_index = -1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "worker retained connection handle does not resolve locally")
		conn.thread_index = td.thread_index

		td.shard_writers.writers = make([dynamic]Shard_Transaction_Writer, 1)
		defer {
			delete(td.shard_writers.writers)
			td.shard_writers.writers = nil
		}
		writer := &td.shard_writers.writers[0]
		writer.wal.enabled = true
		writer.fsync_in_flight = true
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer fsync remains in flight")
		writer.fsync_in_flight = false
		writer.compaction = .Building
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer compaction remains active")
		writer.compaction = .Idle
		writer.prepared_active_generation = 7
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer active reservation remains prepared")
		writer.prepared_active_generation = 0
		append(&writer.deferred_requests, Shard_Deferred_Request{})
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer deferred requests remain queued")
		delete(writer.deferred_requests)
		writer.deferred_requests = nil
		writer.deferred_request_bytes = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer deferred requests remain queued")
		writer.deferred_request_bytes = 0
		writer.wal.pending_bytes = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer WAL remains nondurable")
		writer.wal.pending_bytes = 0
		writer.wal.write_offset = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer WAL remains nondurable")
		writer.wal.write_offset = 0
		writer.wal.buffered_record_count = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer WAL remains nondurable")
		writer.wal.buffered_record_count = 0
		writer.poisoned = true
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer is poisoned or disabled")
		writer.poisoned = false
		writer.wal.enabled = false
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "writer is poisoned or disabled")
		writer.wal.enabled = true

		conn.pending_io = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection I/O ownership remains")
		conn.pending_io = 0
		completion: nbio.Completion
		conn.recv_completion = &completion
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection receive completion remains")
		conn.recv_completion = nil
		conn.is_sending = true
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection send work remains")
		conn.is_sending = false
		conn.inline_len = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection send work remains")
		conn.inline_len = 0
		connection_test_mutate_queue_backing_without_count(conn, false, true)
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection send work remains")
		connection_test_mutate_queue_backing_without_count(conn, false, false)
		connection_test_mutate_queue_backing_without_count(conn, true, true)
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection send work remains")
		connection_test_mutate_queue_backing_without_count(conn, true, false)
		conn.receive_accumulator.used = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection receive accumulator remains")
		conn.receive_accumulator.used = 0
		conn.fragment_len = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "connection fragment accumulator remains")
		conn.fragment_len = 0
		td.shared_fanout_depth = 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "worker fanout or presence work remains")
		td.shared_fanout_depth = 0
		td.draining_presence_updates = true
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "worker fanout or presence work remains")
		td.draining_presence_updates = false
		append(&td.deferred_presence_updates, Deferred_Presence_Update{})
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "worker fanout or presence work remains")
		clear(&td.deferred_presence_updates)

		mismatch := baseline
		mismatch.pool_live += 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], mismatch), "worker pooled lease count differs")
		mismatch = baseline
		mismatch.pool_used += 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], mismatch), "worker pooled byte usage differs")
		mismatch = baseline
		mismatch.pool_outstanding += 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], mismatch), "worker pooled allocation balance differs")
		mismatch = baseline
		mismatch.invalid_releases += 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], mismatch), "worker invalid pooled release count differs")
		mismatch = baseline
		mismatch.active_connections += 1
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], mismatch), "worker connection counts differ")
		testing.expect_value(t, sim_worker_quiescence_reason(handles[:], baseline), "")
	}

	Sim_Op_Kind :: enum {
		Connect,
		Disconnect,
		Subscribe,
		Unsubscribe,
		Send_Message,
		Clear_Inboxes,
	}

	Sim_Op :: struct {
		kind:          Sim_Op_Kind,
		client_id:     int,
		workspace_id:  string,
		username:      string,
		conv_id:       pr.ConversationID,
		client_req_id: u32,
		content_type:  pr.MessageContentType,
		content:       []byte,
	}

	simulation_test_begin :: proc(ctx: ^Sim_Test_Context, thread_index: int = 97) {
		ctx^ = {}
		ctx.backing = context.allocator
		assert(worker_heap_init(&ctx.heap, &ctx.backing, 1024 * 1024))
		td.backing_allocator = ctx.backing
		worker_state_init_core(nil, thread_index)
		// Test-owned entities retain their tracking allocator; async buffer
		// ownership now exercises the real worker heap instead of virtual arenas.
		byte_pool.destroy_buffer_pool(td.spool)
		td.spool = byte_pool.init_buffer_pool(worker_heap_allocator(&ctx.heap))
		assert(td.spool != nil)
		nrc_sim_runtime_init(&ctx.sim)
	}

	// Handler equivalence tests explicitly cross the durability boundary before
	// comparing replies. Interleaving tests schedule individual completions instead.
	simulation_test_commit_shards :: proc(sim: ^Sim_Runtime) -> bool {
		for &writer in td.shard_writers.writers do writer.commit_started = {}
		_, ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !ok do return false
		for nrc_sim_run_next_fsync_completion(sim) {}
		nrc_sim_run_all_send_completions(sim)
		return true
	}

	// Model the production post-tick boundary, including input pressure and
	// batched presence updates caused by retained-message publication.
	simulation_test_message_write_wave :: proc(sim: ^Sim_Runtime) -> bool {
		index := sim_world_domain_event_index(&sim.world, .File_Write, 0)
		if index < 0 do return false
		ids := [1]u64{sim.world.events[index].id}
		return sim_world_dispatch_callback_wave(&sim.world, ids[:])
	}

	// Complete append syscalls without crossing any queued fsync boundary.
	// Tests that model a specific interleaving dispatch individual writes instead.
	simulation_test_flush_message_writes :: proc(sim: ^Sim_Runtime) -> bool {
		for {
			_, ok := flush_pending_retained_message_writes(&td.message_stores)
			if !ok do return false
			for nrc_sim_run_next_file_write(sim) {}
			if td.message_stores.pending_write_count == 0 do break
		}
		for &store in td.message_stores.stores do if !message_store_enabled(&store) do return false
		return true
	}

	simulation_test_commit_messages :: proc(sim: ^Sim_Runtime) -> bool {
		if !simulation_test_flush_message_writes(sim) do return false
		for nrc_sim_run_next_fsync_completion(sim) {}
		for &store in td.message_stores.stores {
			if !message_store_enabled(&store) do return false
			if store.wal.pending_bytes == 0 do continue
			store.commit_pending = true
			store.commit_started = {}
			_ = schedule_retained_message_fsync(&store)
		}
		for nrc_sim_run_next_fsync_completion(sim) {}
		nrc_sim_run_all_send_completions(sim)
		return true
	}

	simulation_test_end :: proc(ctx: ^Sim_Test_Context) {
		for conn in ctx.conns {
			simulation_test_uninstall_client(conn)
		}
		nrc_sim_runtime_destroy(&ctx.sim)
		connection_test_storage_destroy()
		worker_state_destroy_core_for_test()
		tlsf.destroy(&ctx.heap)
		td.backing_allocator = {}
		ctx^ = {}
	}

	simulation_test_install_client :: proc(
		sim: ^Sim_Runtime,
		client_id: int,
		workspace_id: string,
		username: string,
		init_send_queue: bool = false,
	) -> ^NRC_Connection {
		sock := connection_test_fake_socket(client_id)
		nrc_sim_register_client(sim, sock)

		conn := connection_test_install_fake(
			Fake_Connection_Options {
				sock = sock,
				state = .Idle,
				workspace_id = workspace_id,
				verified_username = username,
				authenticated = true,
				user_type = .User,
				init_send_queue = init_send_queue,
				track_active_socket = true,
				cache_workspace = true,
			},
		)
		if conn != nil {
			conn.rooms = make(map[pr.ConversationID]bool, 4)
			track_user_connection(conn)
		}
		return conn
	}

	simulation_test_uninstall_client :: proc(conn: ^NRC_Connection) {
		if conn == nil {
			return
		}
		if conn.rooms != nil {
			cleanup_connection_subscriptions(conn)
			remove_all_rooms(conn)
		}
		connection_test_uninstall(conn)
	}

	simulation_test_disconnect_client :: proc(ctx: ^Sim_Test_Context, client_id: int) -> bool {
		if client_id < 0 || client_id >= len(ctx.conns) {
			return false
		}
		conn := ctx.conns[client_id]
		if conn == nil {
			return false
		}

		simulation_test_uninstall_client(conn)
		ctx.conns[client_id] = nil
		return true
	}

	simulation_test_client :: proc(ctx: ^Sim_Test_Context, client_id: int) -> ^NRC_Connection {
		if client_id < 0 || client_id >= len(ctx.conns) {
			return nil
		}
		return ctx.conns[client_id]
	}

	Sim_Callback_Wave_Fanout_Context :: struct {
		sim:                            ^Sim_Runtime,
		sender:                         ^NRC_Connection,
		receiver:                       ^NRC_Connection,
		cancel_timer:                   ^nbio.Completion,
		second_callback_ran:            bool,
		normal_visible_during_callback: bool,
		nested_dispatch_succeeded:      bool,
		nested_dispatch_advanced_time:  bool,
		future_callback_ran:            bool,
	}

	sim_callback_wave_broadcast :: proc(ctx: ^Sim_Callback_Wave_Fanout_Context) {
		nrc_cancel_timer(ctx.cancel_timer)
		process_send_message(
			ctx.sender,
			pr.SendMessageRequest{conv_id = 78, client_req_id = 11, content_type = .PlainText, content = transmute([]byte)string("wave")},
		)
	}

	sim_callback_wave_priority :: proc(ctx: ^Sim_Callback_Wave_Fanout_Context) {
		ctx.second_callback_ran = true
		ctx.normal_visible_during_callback = nrc_sim_client_opcode_count(ctx.sim, ctx.receiver.sock, .S_NewMessage) != 0
		send_ack_message_direct(ctx.receiver, pr.AckSendMessage{client_req_id = 10})
		now_before_nested_dispatch := ctx.sim.world.now
		ctx.nested_dispatch_succeeded = sim_world_run_next_event(&ctx.sim.world)
		ctx.nested_dispatch_advanced_time = ctx.sim.world.now != now_before_nested_dispatch
	}

	sim_callback_wave_future :: proc(ctx: ^Sim_Callback_Wave_Fanout_Context) {
		ctx.future_callback_ran = true
	}

	@(test)
	test_simulation_explicit_callback_wave_defers_publication_until_all_callbacks_finish :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		sender := simulation_test_install_client(&ctx.sim, 1, "callback-wave", "sender", init_send_queue = true)
		receiver := simulation_test_install_client(&ctx.sim, 2, "callback-wave", "receiver", init_send_queue = true)
		ctx.conns[1] = sender
		ctx.conns[2] = receiver
		testing.expect(t, sender != nil && receiver != nil, "expected callback-wave clients")
		if sender == nil || receiver == nil do return

		conv_id := pr.ConversationID(78)
		subscribe_to_conversation(sender, conv_id)
		subscribe_to_conversation(receiver, conv_id)
		nrc_sim_run_all_send_completions(&ctx.sim)
		nrc_sim_clear_inboxes(&ctx.sim)
		record := Sim_Callback_Wave_Fanout_Context {
			sim      = &ctx.sim,
			sender   = sender,
			receiver = receiver,
		}
		broadcast_timer := nrc_schedule_timer(0, &record, sim_callback_wave_broadcast)
		priority_timer := nrc_schedule_timer(0, &record, sim_callback_wave_priority)
		_ = nrc_schedule_timer(time.Second, &record, sim_callback_wave_future)
		record.cancel_timer = priority_timer
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world), 2)
		event_ids := [2]u64{u64(uintptr(broadcast_timer.user_data)), u64(uintptr(priority_timer.user_data))}
		testing.expect(t, sim_world_dispatch_callback_wave(&ctx.sim.world, event_ids[:]), "both callbacks should dispatch as one wave")

		testing.expect(t, record.second_callback_ran, "second callback should run")
		testing.expect(t, !record.nested_dispatch_succeeded, "scheduler dispatch must be blocked while a callback wave owns its claimed completions")
		testing.expect(t, !record.nested_dispatch_advanced_time, "rejected nested dispatch must not advance virtual time")
		testing.expect(t, !record.future_callback_ran, "future callbacks must remain pending during the active wave")
		testing.expect(t, !record.normal_visible_during_callback, "normal fanout must remain unpublished during the callback wave")
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_AckSendMessage), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_NewMessage), 0)
		testing.expect_value(t, deferred_outbox_pump_count(), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 2)
		receiver_completion_index := -1
		for event, index in ctx.sim.world.events {
			completion, ok := event.payload.(Sim_Send_Completion)
			if ok && completion.sock == receiver.sock {
				receiver_completion_index = index
				break
			}
		}
		testing.expect(t, receiver_completion_index >= 0, "receiver priority completion should be published")
		if receiver_completion_index < 0 do return
		testing.expect(t, sim_world_dispatch_event(&ctx.sim.world, receiver_completion_index), "priority completion should publish the queued normal frame")
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_NewMessage), 1)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 2)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect(t, !receiver.is_sending, "callback-wave output should quiesce")
	}

	@(test)
	test_message_fanout_pumps_after_completion_wave :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)

		sender := simulation_test_install_client(&ctx.sim, 1, "deferred-fanout", "sender", init_send_queue = true)
		receiver := simulation_test_install_client(&ctx.sim, 2, "deferred-fanout", "receiver", init_send_queue = true)
		ctx.conns[1] = sender
		ctx.conns[2] = receiver
		testing.expect(t, sender != nil && receiver != nil, "expected simulation clients")
		if sender == nil || receiver == nil do return

		conv_id := pr.ConversationID(77)
		subscribe_to_conversation(sender, conv_id)
		subscribe_to_conversation(receiver, conv_id)
		nrc_sim_clear_inboxes(&ctx.sim)
		msg := pr.NewMessageEvent {
			conv_id         = conv_id,
			seq             = 1,
			author_username = transmute([]byte)string("sender"),
			timestamp       = 1,
			content_type    = .PlainText,
			content         = transmute([]byte)string("deferred"),
		}

		broadcast_new_message(msg, sender.sock, get_connection_workspace(sender))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, receiver.sock), 0)
		testing.expect_value(t, deferred_outbox_pump_count(), 1)
		testing.expect(t, receiver.outbox_pump_deferred, "receiver outbox should await the completion-wave boundary")
		send_ack_message_direct(receiver, pr.AckSendMessage{client_req_id = 9})
		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim), "priority completion callback should run")
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_AckSendMessage), 1)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_NewMessage), 0)
		testing.expect(t, receiver.outbox_pump_deferred, "normal fanout must remain queued before the explicit wave boundary")

		_, wave_ok := worker_finish_callback_wave()
		testing.expect(t, wave_ok, "explicit singleton callback wave should publish normal fanout")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, receiver.sock, .S_NewMessage), 1)
		testing.expect_value(t, deferred_outbox_pump_count(), 0)
		testing.expect(t, !receiver.is_sending, "receiver should quiesce after the published fanout completes")
	}

	simulation_test_apply_op :: proc(ctx: ^Sim_Test_Context, op: Sim_Op) -> bool {
		switch op.kind {
		case .Connect:
			if op.client_id < 0 || op.client_id >= len(ctx.conns) {
				return false
			}
			if ctx.conns[op.client_id] != nil {
				return false
			}
			ctx.conns[op.client_id] = simulation_test_install_client(&ctx.sim, op.client_id, op.workspace_id, op.username)
			return ctx.conns[op.client_id] != nil

		case .Disconnect:
			return simulation_test_disconnect_client(ctx, op.client_id)

		case .Subscribe:
			conn := simulation_test_client(ctx, op.client_id)
			if conn == nil {
				return false
			}
			subscribe_to_conversation(conn, op.conv_id)
			return true

		case .Unsubscribe:
			conn := simulation_test_client(ctx, op.client_id)
			if conn == nil {
				return false
			}
			unsubscribe_from_conversation(conn, op.conv_id)
			return true

		case .Send_Message:
			conn := simulation_test_client(ctx, op.client_id)
			if conn == nil {
				return false
			}
			process_send_message(
				conn,
				pr.SendMessageRequest{conv_id = op.conv_id, client_req_id = op.client_req_id, content_type = op.content_type, content = op.content},
			)
			return true

		case .Clear_Inboxes:
			nrc_sim_clear_inboxes(&ctx.sim)
			return true
		}

		return false
	}

	simulation_test_apply_ops :: proc(ctx: ^Sim_Test_Context, ops: []Sim_Op) -> bool {
		for op in ops {
			if !simulation_test_apply_op(ctx, op) {
				return false
			}
		}
		return true
	}

	Sim_Timer_Test_Record :: struct {
		order: ^[4]int,
		count: ^int,
		value: int,
	}

	Sim_Fsync_Test_Record :: struct {
		calls: int,
		err:   linux.Errno,
	}
	Sim_File_Read_Test_Record :: struct {
		calls: int,
		read:  int,
		err:   linux.Errno,
	}

	sim_fsync_test_callback :: proc(user: rawptr, err: linux.Errno) {
		record := (^Sim_Fsync_Test_Record)(user)
		record.calls += 1
		record.err = err
	}

	sim_file_read_test_callback :: proc(user: rawptr, read: int, err: linux.Errno) {
		record := (^Sim_File_Read_Test_Record)(user)
		record.calls += 1
		record.read = read
		record.err = err
	}

	Sim_Driver_Action_Test_Record :: struct {
		calls:           int,
		observed_worker: int,
	}

	Sim_Driver_Action_Test_Hooks :: struct {
		caller_worker:  int,
		entered_worker: int,
		enter_count:    int,
		leave_count:    int,
	}

	sim_driver_action_test_callback :: proc(user: rawptr) {
		record := (^Sim_Driver_Action_Test_Record)(user)
		record.calls += 1
		record.observed_worker = td.thread_index
	}

	sim_driver_action_test_enter :: proc(user: rawptr, worker_index: int) {
		hooks := (^Sim_Driver_Action_Test_Hooks)(user)
		hooks.caller_worker = td.thread_index
		hooks.entered_worker = worker_index
		hooks.enter_count += 1
		td.thread_index = worker_index
	}

	sim_driver_action_test_leave :: proc(user: rawptr) {
		hooks := (^Sim_Driver_Action_Test_Hooks)(user)
		td.thread_index = hooks.caller_worker
		hooks.leave_count += 1
	}

	Sim_Delayed_Send_Test_Record :: struct {
		callback_count:          int,
		nil_count:               int,
		error_count:             int,
		total_sent:              int,
		expected_handle:         Connection_Handle,
		unexpected_target_count: int,
	}

	simulation_delayed_send_test_callback :: proc(c: ^NRC_Connection, ctx: rawptr, sent: int, err: net.Network_Error) {
		record := (^Sim_Delayed_Send_Test_Record)(ctx)
		record.callback_count += 1
		if c == nil do record.nil_count += 1
		if c != nil && record.expected_handle != {} && c.handle != record.expected_handle {
			record.unexpected_target_count += 1
		}
		if err != nil do record.error_count += 1
		record.total_sent += sent
	}

	SIM_MODEL_CLIENTS :: 4
	SIM_MODEL_CONVS :: 2

	Sim_Model :: struct {
		connected:  [SIM_MODEL_CLIENTS]bool,
		subscribed: [SIM_MODEL_CLIENTS][SIM_MODEL_CONVS]bool,
	}

	Sim_Model_Diagnostic :: struct {
		reason:          string,
		op_index:        int,
		client_id:       int,
		expected_frames: int,
		actual_frames:   int,
		expected_opcode: pr.Opcode,
		actual_opcode:   pr.Opcode,
	}

	simulation_model_fail :: proc(
		diag: ^Sim_Model_Diagnostic,
		reason: string,
		client_id: int = -1,
		expected_frames: int = -1,
		actual_frames: int = -1,
		expected_opcode: pr.Opcode = {},
		actual_opcode: pr.Opcode = {},
	) -> bool {
		if diag != nil {
			diag.reason = reason
			diag.client_id = client_id
			diag.expected_frames = expected_frames
			diag.actual_frames = actual_frames
			diag.expected_opcode = expected_opcode
			diag.actual_opcode = actual_opcode
		}
		return false
	}

	simulation_model_workspace :: proc(client_id: int) -> string {
		switch client_id {
		case 0, 1:
			return "workspace_1"
		case:
			return "workspace_2"
		}
	}

	simulation_model_username :: proc(client_id: int) -> string {
		switch client_id {
		case 0:
			return "alice"
		case 1:
			return "bob"
		case 2:
			return "carol"
		case:
			return "dave"
		}
	}

	simulation_model_conv_id :: proc(conv_index: int) -> pr.ConversationID {
		switch conv_index {
		case 0:
			return pr.ConversationID(42)
		case:
			return pr.ConversationID(77)
		}
	}

	simulation_model_conv_index :: proc(conv_id: pr.ConversationID) -> int {
		if conv_id == simulation_model_conv_id(0) {
			return 0
		}
		return 1
	}

	simulation_model_connect_op :: proc(client_id: int) -> Sim_Op {
		return Sim_Op {
			kind = .Connect,
			client_id = client_id,
			workspace_id = simulation_model_workspace(client_id),
			username = simulation_model_username(client_id),
		}
	}

	simulation_model_connect_clients :: proc(ctx: ^Sim_Test_Context, model: ^Sim_Model) -> bool {
		for client_id in 0 ..< SIM_MODEL_CLIENTS {
			if !simulation_test_apply_op(ctx, simulation_model_connect_op(client_id)) {
				return false
			}
			model.connected[client_id] = true
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		return true
	}

	simulation_model_same_workspace :: proc(a, b: int) -> bool {
		return simulation_model_workspace(a) == simulation_model_workspace(b)
	}

	simulation_model_validate_send :: proc(ctx: ^Sim_Test_Context, model: ^Sim_Model, op: Sim_Op, diag: ^Sim_Model_Diagnostic = nil) -> bool {
		conv_index := simulation_model_conv_index(op.conv_id)
		for client_id in 0 ..< SIM_MODEL_CLIENTS {
			conn := simulation_test_client(ctx, client_id)
			if model.connected[client_id] && conn == nil {
				return simulation_model_fail(diag, "missing connected simulated client", client_id)
			}

			expected_frames := 0
			if model.connected[client_id] && client_id == op.client_id {
				expected_frames = 1
			} else if model.connected[client_id] && model.subscribed[client_id][conv_index] && simulation_model_same_workspace(client_id, op.client_id) {
				expected_frames = 1
			}

			sock := connection_test_fake_socket(client_id)
			if conn != nil {
				sock = conn.sock
			}
			actual_frames := nrc_sim_client_frame_count(&ctx.sim, sock)
			if actual_frames != expected_frames {
				return simulation_model_fail(diag, "frame count mismatch", client_id, expected_frames, actual_frames)
			}

			if expected_frames == 0 {
				continue
			}

			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, 0))
			if !ok || len(payload) < 2 {
				return simulation_model_fail(diag, "invalid websocket/protocol payload", client_id, expected_frames, actual_frames)
			}

			actual_opcode := pr.get_opcode(payload)
			if client_id == op.client_id {
				if actual_opcode != pr.Opcode.S_AckSendMessage {
					return simulation_model_fail(
						diag,
						"sender opcode mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_AckSendMessage,
						actual_opcode,
					)
				}
				ack, ack_err := pr.parseAckSendMessageMessage(payload)
				if ack_err != nil || ack.client_req_id != op.client_req_id {
					return simulation_model_fail(
						diag,
						"ack parse/client_req_id mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_AckSendMessage,
						actual_opcode,
					)
				}
			} else {
				if actual_opcode != pr.Opcode.S_NewMessage {
					return simulation_model_fail(
						diag,
						"broadcast opcode mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_NewMessage,
						actual_opcode,
					)
				}
				message, message_err := pr.parseNewMessageEventMessage(payload)
				if message_err != nil || message.conv_id != op.conv_id || message.content_type != op.content_type {
					return simulation_model_fail(
						diag,
						"broadcast parse/conversation/content-type mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_NewMessage,
						actual_opcode,
					)
				}
				if string(message.author_username) != simulation_model_username(op.client_id) {
					return simulation_model_fail(
						diag,
						"broadcast author mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_NewMessage,
						actual_opcode,
					)
				}
				if string(message.content) != string(op.content) {
					return simulation_model_fail(
						diag,
						"broadcast content mismatch",
						client_id,
						expected_frames,
						actual_frames,
						pr.Opcode.S_NewMessage,
						actual_opcode,
					)
				}
			}
		}

		return true
	}

	simulation_model_apply_and_check :: proc(
		ctx: ^Sim_Test_Context,
		model: ^Sim_Model,
		op: Sim_Op,
		op_index: int = -1,
		diag: ^Sim_Model_Diagnostic = nil,
	) -> bool {
		if diag != nil {
			diag^ = {
				op_index        = op_index,
				client_id       = -1,
				expected_frames = -1,
				actual_frames   = -1,
			}
		}
		if op.kind != .Clear_Inboxes && (op.client_id < 0 || op.client_id >= SIM_MODEL_CLIENTS) {
			return simulation_model_fail(diag, "client id out of simulation model bounds", op.client_id)
		}

		switch op.kind {
		case .Subscribe, .Unsubscribe:
			if !model.connected[op.client_id] {
				nrc_sim_clear_inboxes(&ctx.sim)
				return true
			}
			if !simulation_test_apply_op(ctx, op) {
				return simulation_model_fail(diag, "apply subscribe/unsubscribe failed", op.client_id)
			}
			model.subscribed[op.client_id][simulation_model_conv_index(op.conv_id)] = op.kind == .Subscribe
			nrc_sim_clear_inboxes(&ctx.sim)
			return true

		case .Send_Message:
			nrc_sim_clear_inboxes(&ctx.sim)
			if !model.connected[op.client_id] {
				return true
			}
			if !simulation_test_apply_op(ctx, op) {
				return simulation_model_fail(diag, "apply send failed", op.client_id)
			}
			ok := simulation_model_validate_send(ctx, model, op, diag)
			if !ok {
				return false
			}
			nrc_sim_clear_inboxes(&ctx.sim)
			return true

		case .Connect:
			if model.connected[op.client_id] {
				nrc_sim_clear_inboxes(&ctx.sim)
				return true
			}
			connect_op := op
			if connect_op.workspace_id == "" {
				connect_op.workspace_id = simulation_model_workspace(op.client_id)
			}
			if connect_op.username == "" {
				connect_op.username = simulation_model_username(op.client_id)
			}
			if !simulation_test_apply_op(ctx, connect_op) {
				return simulation_model_fail(diag, "apply connect failed", op.client_id)
			}
			model.connected[op.client_id] = true
			nrc_sim_clear_inboxes(&ctx.sim)
			return true

		case .Disconnect:
			if !model.connected[op.client_id] {
				nrc_sim_clear_inboxes(&ctx.sim)
				return true
			}
			if !simulation_test_apply_op(ctx, op) {
				return simulation_model_fail(diag, "apply disconnect failed", op.client_id)
			}
			model.connected[op.client_id] = false
			for conv_index in 0 ..< SIM_MODEL_CONVS {
				model.subscribed[op.client_id][conv_index] = false
			}
			nrc_sim_clear_inboxes(&ctx.sim)
			return true

		case .Clear_Inboxes:
			if !simulation_test_apply_op(ctx, op) {
				return simulation_model_fail(diag, "apply clear failed", op.client_id)
			}
			return true
		}

		return simulation_model_fail(diag, "unknown operation kind", op.client_id)
	}

	simulation_model_log_replay_fixture :: proc(ops: []Sim_Op, diag: Sim_Model_Diagnostic) {
		fmt.eprintf(
			"DST simulation replay failure: op_index=%d reason=%s client=%d expected_frames=%d actual_frames=%d expected_opcode=%v actual_opcode=%v\n",
			diag.op_index,
			diag.reason,
			diag.client_id,
			diag.expected_frames,
			diag.actual_frames,
			diag.expected_opcode,
			diag.actual_opcode,
		)
		fmt.eprintf("Copy this into a regression test fixture and run simulation_model_replay_ops(t, ops[:]):\n")
		fmt.eprintf("ops := [?]Sim_Op {\n")
		for op, index in ops {
			fmt.eprintf(
				"\t// %d\n\t{kind = .%v, client_id = %d, conv_id = pr.ConversationID(%d), client_req_id = %d, content_type = .%v, content = transmute([]byte)string(%q)},\n",
				index,
				op.kind,
				op.client_id,
				u64(op.conv_id),
				op.client_req_id,
				op.content_type,
				string(op.content),
			)
		}
		fmt.eprintf("}\n")
	}

	simulation_model_run_ops :: proc(ctx: ^Sim_Test_Context, ops: []Sim_Op) -> bool {
		model: Sim_Model
		if !simulation_model_connect_clients(ctx, &model) {
			return false
		}
		for op, op_index in ops {
			diag: Sim_Model_Diagnostic
			if !simulation_model_apply_and_check(ctx, &model, op, op_index, &diag) {
				simulation_model_log_replay_fixture(ops[:op_index + 1], diag)
				return false
			}
		}
		return true
	}

	simulation_model_replay_ops :: proc(t: ^testing.T, ops: []Sim_Op, thread_index: int = 93) -> bool {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, thread_index)
		defer simulation_test_end(&ctx)

		ok := simulation_model_run_ops(&ctx, ops)
		testing.expect(t, ok, "simulation replay fixture should match reference model")
		return ok
	}
}

@(test)
test_simulation_scenario_runner_checks_send_fanout_against_model :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		content_a := transmute([]byte)string("dst scenario a")
		content_b := transmute([]byte)string("dst scenario b")
		content_c := transmute([]byte)string("dst scenario c")
		ops := [?]Sim_Op {
			{kind = .Subscribe, client_id = 0, conv_id = simulation_model_conv_id(0)},
			{kind = .Subscribe, client_id = 1, conv_id = simulation_model_conv_id(0)},
			{kind = .Subscribe, client_id = 2, conv_id = simulation_model_conv_id(0)},
			{kind = .Send_Message, client_id = 0, conv_id = simulation_model_conv_id(0), client_req_id = 1, content_type = .PlainText, content = content_a},
			{kind = .Unsubscribe, client_id = 1, conv_id = simulation_model_conv_id(0)},
			{kind = .Send_Message, client_id = 0, conv_id = simulation_model_conv_id(0), client_req_id = 2, content_type = .PlainText, content = content_b},
			{kind = .Subscribe, client_id = 3, conv_id = simulation_model_conv_id(0)},
			{kind = .Send_Message, client_id = 2, conv_id = simulation_model_conv_id(0), client_req_id = 3, content_type = .PlainText, content = content_c},
		}

		simulation_model_replay_ops(t, ops[:], 95)
	}
}

@(test)
test_simulation_model_replay_ops_accepts_literal_fixture :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ops := [?]Sim_Op {
			{
				kind = .Subscribe,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Subscribe,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Send_Message,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 1,
				content_type = .PlainText,
				content = transmute([]byte)string("dst replay fixture"),
			},
			{
				kind = .Unsubscribe,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Send_Message,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 2,
				content_type = .PlainText,
				content = transmute([]byte)string("dst replay after unsubscribe"),
			},
		}

		simulation_model_replay_ops(t, ops[:])
	}
}

@(test)
test_simulation_model_replay_ops_handles_disconnect_reconnect :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ops := [?]Sim_Op {
			{
				kind = .Subscribe,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Subscribe,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Disconnect,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Send_Message,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 1,
				content_type = .PlainText,
				content = transmute([]byte)string("not delivered to disconnected client"),
			},
			{
				kind = .Connect,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Send_Message,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 2,
				content_type = .PlainText,
				content = transmute([]byte)string("not delivered before resubscribe"),
			},
			{
				kind = .Subscribe,
				client_id = 1,
				conv_id = pr.ConversationID(42),
				client_req_id = 0,
				content_type = .PlainText,
				content = transmute([]byte)string(""),
			},
			{
				kind = .Send_Message,
				client_id = 0,
				conv_id = pr.ConversationID(42),
				client_req_id = 3,
				content_type = .PlainText,
				content = transmute([]byte)string("delivered after resubscribe"),
			},
		}

		simulation_model_replay_ops(t, ops[:], 92)
	}
}

@(test)
test_hegel_simulation_generated_message_fanout_matches_model :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() {
			return
		}

		result, err := hgl.run(prop_simulation_generated_message_fanout_matches_model, nil, {test_cases = 200})
		testing.expectf(t, err == nil, "hegel simulation fanout property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

when NRC_SIMULATION {
	prop_simulation_generated_message_fanout_matches_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		op_count_raw, draw_err := hgl.draw_i64(tc, 0, 1000)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw operation count")

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 94)
		defer simulation_test_end(&ctx)

		model: Sim_Model
		if !simulation_model_connect_clients(&ctx, &model) {
			return hgl.interesting("connect clients")
		}

		content := transmute([]byte)string("dst generated message")
		ops := make([dynamic]Sim_Op, 0, int(op_count_raw))
		defer delete(ops)

		for op_index in 0 ..< int(op_count_raw) {
			op_kind_raw, op_kind_err := hgl.draw_i64(tc, 0, 4)
			if op_kind_err == .Stop_Test do return hgl.abort()
			if op_kind_err != nil do return hgl.interesting("draw operation kind")

			client_raw, client_err := hgl.draw_i64(tc, 0, SIM_MODEL_CLIENTS - 1)
			if client_err == .Stop_Test do return hgl.abort()
			if client_err != nil do return hgl.interesting("draw client")

			conv_raw, conv_err := hgl.draw_i64(tc, 0, SIM_MODEL_CONVS - 1)
			if conv_err == .Stop_Test do return hgl.abort()
			if conv_err != nil do return hgl.interesting("draw conversation")

			op := Sim_Op {
				client_id     = int(client_raw),
				conv_id       = simulation_model_conv_id(int(conv_raw)),
				client_req_id = u32(op_index + 1),
				content_type  = .PlainText,
				content       = content,
			}

			switch op_kind_raw {
			case 0:
				op.kind = .Subscribe
			case 1:
				op.kind = .Unsubscribe
			case 2:
				op.kind = .Send_Message
			case 3:
				op.kind = .Disconnect
			case:
				op.kind = .Connect
			}
			append(&ops, op)

			diag: Sim_Model_Diagnostic
			if !simulation_model_apply_and_check(&ctx, &model, op, op_index, &diag) {
				simulation_model_log_replay_fixture(ops[:], diag)
				return hgl.interesting(diag.reason)
			}
		}

		return hgl.valid()
	}
}

@(test)
test_simulation_timer_queue_fires_in_virtual_time_order :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 96)
		defer simulation_test_end(&ctx)

		order: [4]int
		count := 0
		records := [?]Sim_Timer_Test_Record {
			{order = &order, count = &count, value = 30},
			{order = &order, count = &count, value = 10},
			{order = &order, count = &count, value = 20},
		}
		sum := 0

		_ = nrc_schedule_timer(time.Millisecond * 30, &records[0], proc(record: ^Sim_Timer_Test_Record) {
			record.order[record.count^] = record.value
			record.count^ += 1
		})
		_ = nrc_schedule_timer(time.Millisecond * 10, &records[1], proc(record: ^Sim_Timer_Test_Record) {
			record.order[record.count^] = record.value
			record.count^ += 1
		})
		_ = nrc_schedule_timer(time.Millisecond * 20, &records[2], proc(record: ^Sim_Timer_Test_Record) {
			record.order[record.count^] = record.value
			record.count^ += 1
		})
		_ = nrc_schedule_timer(time.Millisecond * 20, &sum, 5, proc(sum: ^int, value: int) {
			sum^ += value
		})
		cancelled := nrc_schedule_timer(time.Millisecond * 5, &sum, 100, proc(sum: ^int, value: int) {
			sum^ += value
		})

		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 5)
		testing.expect_value(t, time.to_unix_nanoseconds(nrc_time_now()), NRC_SIM_TIME_EPOCH_NANOS)
		testing.expect_value(t, time.to_unix_nanoseconds(nrc_time_now_monotonic()), NRC_SIM_TIME_EPOCH_NANOS)
		nrc_cancel_timer(cancelled)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 4)
		nrc_sim_run_all_timers(&ctx.sim)
		testing.expect_value(t, time.to_unix_nanoseconds(nrc_time_now()), NRC_SIM_TIME_EPOCH_NANOS + i64(time.Millisecond * 30))

		testing.expect_value(t, count, 3)
		testing.expect_value(t, order[0], 10)
		testing.expect_value(t, order[1], 20)
		testing.expect_value(t, order[2], 30)
		testing.expect_value(t, sum, 5)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)

		fired := nrc_schedule_timer(time.Millisecond, &sum, 50, proc(sum: ^int, value: int) {
			sum^ += value
		})
		testing.expect(t, nrc_sim_run_next_timer(&ctx.sim), "expected fired timer to run")
		testing.expect_value(t, sum, 55)

		_ = nrc_schedule_timer(time.Millisecond, &sum, 7, proc(sum: ^int, value: int) {
			sum^ += value
		})
		nrc_cancel_timer(fired)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 1)
		nrc_sim_run_all_timers(&ctx.sim)
		testing.expect_value(t, sum, 62)
	}
}

@(test)
test_simulation_event_kernel_runs_timer_rank_and_discards_stale_incarnation :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 91)
		defer simulation_test_end(&ctx)

		order: [4]int
		count := 0
		records := [?]Sim_Timer_Test_Record {
			{order = &order, count = &count, value = 1},
			{order = &order, count = &count, value = 2},
			{order = &order, count = &count, value = 3},
			{order = &order, count = &count, value = 4},
		}
		for index in 0 ..< 3 {
			_ = nrc_schedule_timer(time.Millisecond * 10, &records[index], proc(record: ^Sim_Timer_Test_Record) {
				record.order[record.count^] = record.value
				record.count^ += 1
			})
		}
		testing.expect_value(t, len(ctx.sim.world.events), 3)
		first := ctx.sim.world.events[0]
		testing.expect_value(t, first.id, u64(1))
		testing.expect_value(t, first.ready_at, time.Millisecond * 10)
		testing.expect_value(t, first.process_incarnation, ctx.sim.world.process_incarnation)
		testing.expect_value(t, first.domain, Sim_Event_Domain.Timer)
		testing.expect_value(t, first.target.kind, Sim_Event_Target_Kind.Process)

		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 1), "ranked event should run")
		testing.expect_value(t, count, 1)
		testing.expect_value(t, order[0], 2)
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world))
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world))
		testing.expect_value(t, order[1], 1)
		testing.expect_value(t, order[2], 3)

		_ = nrc_schedule_timer(time.Millisecond, &records[3], proc(record: ^Sim_Timer_Test_Record) {
			record.order[record.count^] = record.value
			record.count^ += 1
		})
		old_incarnation := ctx.sim.world.process_incarnation
		sim_world_crash(&ctx.sim.world)
		testing.expect(t, ctx.sim.world.process_incarnation > old_incarnation)
		testing.expect(t, nrc_sim_run_next_timer(&ctx.sim), "stale timer should be consumed")
		testing.expect_value(t, count, 3)
		testing.expect_value(t, nrc_sim_timer_event_count(&ctx.sim), 0)
	}
}

@(test)
test_simulation_process_crash_is_a_ranked_kernel_event :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 91)
		defer simulation_test_end(&ctx)

		order: [4]int
		count := 0
		records := [?]Sim_Timer_Test_Record{{order = &order, count = &count, value = 1}, {order = &order, count = &count, value = 2}}
		for &record in records {
			_ = nrc_schedule_timer(0, &record, proc(record: ^Sim_Timer_Test_Record) {
				record.order[record.count^] = record.value
				record.count^ += 1
			})
		}
		crash_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		testing.expect(t, crash_id != 0)
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world), 3)
		crash_index := sim_world_domain_event_index(&ctx.sim.world, .Process_Crash, 0)
		testing.expect(t, crash_index >= 0)
		if crash_index < 0 do return
		testing.expect_value(t, ctx.sim.world.events[crash_index].worker_index, -1)

		old_incarnation := ctx.sim.world.process_incarnation
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 2), "process crash should compete by runnable rank")
		testing.expect(t, ctx.sim.world.process_incarnation > old_incarnation)
		testing.expect_value(t, count, 0)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Process_Crash), 0)

		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "first old-incarnation timer should stale-discard")
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "second old-incarnation timer should stale-discard")
		testing.expect_value(t, count, 0)
		testing.expect_value(t, len(ctx.sim.world.events), 0)

		cancel_incarnation := ctx.sim.world.process_incarnation
		cancel_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, cancel_id), "queued process crash should cancel")
		testing.expect_value(t, ctx.sim.world.process_incarnation, cancel_incarnation)
		testing.expect_value(t, len(ctx.sim.world.events), 0)
	}
}

@(test)
test_simulation_driver_action_dispatch_cancel_and_stale_suppression :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 91)
		defer simulation_test_end(&ctx)

		record: Sim_Driver_Action_Test_Record
		hooks: Sim_Driver_Action_Test_Hooks
		sim_world_set_worker_switch_hooks(&ctx.sim.world, &hooks, sim_driver_action_test_enter, sim_driver_action_test_leave)
		action_id := sim_world_enqueue_driver_action(&ctx.sim.world, &record, sim_driver_action_test_callback)
		testing.expect(t, action_id != 0)
		action_index := sim_world_domain_event_index(&ctx.sim.world, .Driver_Action, 0)
		testing.expect(t, action_index >= 0)
		if action_index < 0 do return
		testing.expect_value(t, ctx.sim.world.events[action_index].worker_index, 91)
		testing.expect_value(t, ctx.sim.world.events[action_index].target, Sim_Event_Target{kind = .Worker, id = 91})
		td.thread_index = 7
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "driver action should dispatch")
		testing.expect_value(t, record.calls, 1)
		testing.expect_value(t, record.observed_worker, 91)
		testing.expect_value(t, hooks.entered_worker, 91)
		testing.expect_value(t, hooks.enter_count, 1)
		testing.expect_value(t, hooks.leave_count, 1)
		testing.expect_value(t, td.thread_index, 7)
		td.thread_index = 91

		cancel_id := sim_world_enqueue_driver_action(&ctx.sim.world, &record, sim_driver_action_test_callback)
		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, cancel_id), "driver action should cancel")
		testing.expect_value(t, record.calls, 1)

		stale_id := sim_world_enqueue_driver_action(&ctx.sim.world, &record, sim_driver_action_test_callback)
		crash_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		testing.expect(t, stale_id != 0 && crash_id != 0)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 1), "process crash should overtake the driver action")
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "old driver action should stale-discard")
		testing.expect_value(t, record.calls, 1)
		testing.expect_value(t, len(ctx.sim.world.events), 0)
	}
}

@(test)
test_simulation_fsync_event_commits_captured_virtual_snapshot :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 90)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		file, open_err := storage_io.open(storage, "/async.wal", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		defer storage_io.discard(file)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		_, _ = storage_io.write(file, []byte{1})
		record: Sim_Fsync_Test_Record
		_ = nrc_io_sync_file(file, &record, sim_fsync_test_callback)
		_, _ = storage_io.write(file, []byte{2})
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world))
		testing.expect_value(t, record.calls, 1)
		testing.expect_value(t, record.err, linux.Errno.NONE)

		storage_io.discard(file)
		file = nil
		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		recovered, recovered_err := storage_io.open(storage, "/async.wal", {.Read})
		testing.expect(t, recovered_err == nil && recovered != nil)
		if recovered == nil do return
		buf: [2]byte
		read, read_err := storage_io.read_at(recovered, buf[:], 0)
		testing.expect(t, read_err == nil && read == 1 && buf[0] == 1, "fsync must commit the submission snapshot, not later writes")
		testing.expect(t, storage_io.close(recovered) == nil)
	}
}

@(test)
test_simulation_failed_and_stale_fsync_events_do_not_commit :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 91)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		file, open_err := storage_io.open(storage, "/failed.wal", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		_, _ = storage_io.write(file, []byte{1})
		testing.expect(t, storage_io.sync(file) == nil)

		_, _ = storage_io.write(file, []byte{2})
		failed: Sim_Fsync_Test_Record
		_ = nrc_io_sync_file(file, &failed, sim_fsync_test_callback)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO))
		testing.expect_value(t, failed.calls, 1)
		testing.expect_value(t, failed.err, linux.Errno.EIO)

		_, _ = storage_io.write(file, []byte{3})
		stale: Sim_Fsync_Test_Record
		_ = nrc_io_sync_file(file, &stale, sim_fsync_test_callback)
		storage_io.discard(file)
		sim_world_crash(&ctx.sim.world)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim), "stale fsync event should be consumed")
		testing.expect_value(t, stale.calls, 0)

		storage = sim_world_storage_context(&ctx.sim.world)
		recovered, recovered_err := storage_io.open(storage, "/failed.wal", {.Read})
		testing.expect(t, recovered_err == nil && recovered != nil)
		if recovered == nil do return
		buf: [2]byte
		read, read_err := storage_io.read_at(recovered, buf[:], 0)
		testing.expect(t, read_err == nil && read == 1 && buf[0] == 1, "failed and stale fsyncs must not change durable bytes")
		testing.expect(t, storage_io.close(recovered) == nil)
	}
}

@(test)
test_simulation_file_reads_are_scheduled_and_error_injectable :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 133)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		file, open_err := storage_io.open(storage, "/scheduled-read.wal", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		defer storage_io.discard(file)
		_, write_err := storage_io.write(file, []byte{11, 22, 33, 44})
		testing.expect(t, write_err == nil)

		buf: [2]byte
		success: Sim_File_Read_Test_Record
		_ = nrc_io_read_file_at(file, buf[:], 1, &success, sim_file_read_test_callback)
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 1)
		testing.expect_value(t, buf, [2]byte{})
		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim))
		testing.expect_value(t, success.calls, 1)
		testing.expect_value(t, success.read, 2)
		testing.expect_value(t, success.err, linux.Errno.NONE)
		testing.expect_value(t, buf, [2]byte{22, 33})

		failed_buf := [2]byte{9, 9}
		failed: Sim_File_Read_Test_Record
		_ = nrc_io_read_file_at(file, failed_buf[:], 0, &failed, sim_file_read_test_callback)
		testing.expect(t, nrc_sim_run_next_file_read(&ctx.sim, .EIO))
		testing.expect_value(t, failed.calls, 1)
		testing.expect_value(t, failed.read, 0)
		testing.expect_value(t, failed.err, linux.Errno.EIO)
		testing.expect_value(t, failed_buf, [2]byte{9, 9})
		testing.expect_value(t, nrc_sim_file_read_count(&ctx.sim), 0)
	}
}

@(test)
test_simulation_domain_view_does_not_advance_past_global_runnable_event :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 92)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		file, open_err := storage_io.open(storage, "/ordering.wal", {.Read, .Write, .Create})
		testing.expect(t, open_err == nil && file != nil)
		if file == nil do return
		defer storage_io.discard(file)
		_, _ = storage_io.write(file, []byte{1})
		fsync_record: Sim_Fsync_Test_Record
		_ = nrc_io_sync_file(file, &fsync_record, sim_fsync_test_callback)

		order: [4]int
		timer_count := 0
		timer_record := Sim_Timer_Test_Record {
			order = &order,
			count = &timer_count,
			value = 7,
		}
		_ = nrc_schedule_timer(time.Millisecond * 10, &timer_record, proc(record: ^Sim_Timer_Test_Record) {
			record.order[record.count^] = record.value
			record.count^ += 1
		})
		testing.expect(t, !nrc_sim_run_next_timer(&ctx.sim), "timer view must not skip globally runnable fsync")
		testing.expect_value(t, ctx.sim.world.now, time.Duration(0))
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect_value(t, fsync_record.calls, 1)
		testing.expect(t, nrc_sim_run_next_timer(&ctx.sim))
		testing.expect_value(t, timer_count, 1)
		testing.expect_value(t, order[0], 7)
	}
}

@(test)
test_simulation_idle_send_uses_outbox_completion_path :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 94)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "idle_outbox", "sender", init_send_queue = true)
		testing.expect(t, conn != nil, "idle-send client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		live_before := connection_lifetime_pool_live_alloc_count(td.spool)
		buf, alloc_err := byte_pool.alloc(td.spool, 8)
		testing.expect(t, alloc_err == .None, "idle-send buffer should allocate")
		if alloc_err != .None do return

		record := Sim_Delayed_Send_Test_Record {
			expected_handle = conn.handle,
		}
		nrc_sim_inject_next_queued_send_error(&ctx.sim, net.TCP_Send_Error(.Not_Connected))
		accepted := nrc_send_frame(
			conn,
			Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			observer = {callback = simulation_delayed_send_test_callback, ctx = &record},
		)

		testing.expect(t, accepted, "outbox ownership transfer should succeed before transport completion")
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, record.callback_count, 1)
		testing.expect_value(t, record.nil_count, 0)
		testing.expect_value(t, record.error_count, 1)
		testing.expect_value(t, record.total_sent, 0)
		testing.expect_value(t, record.unexpected_target_count, 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, send_queue_len(conn), 0)
		testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), live_before)
	}
}

@(test)
test_simulation_delayed_send_completion_order_error_and_socket_reuse :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 95)
		defer simulation_test_end(&ctx)

		first := simulation_test_install_client(&ctx.sim, 0, "delayed_ws", "old", init_send_queue = true)
		second := simulation_test_install_client(&ctx.sim, 1, "delayed_ws", "error", init_send_queue = true)
		testing.expect(t, first != nil && second != nil, "delayed-send clients should install")
		if first == nil || second == nil do return
		ctx.conns[0] = first
		ctx.conns[1] = second

		live_before := connection_lifetime_pool_live_alloc_count(td.spool)
		first_buf, first_err := byte_pool.alloc(td.spool, 8)
		second_buf, second_err := byte_pool.alloc(td.spool, 8)
		testing.expect(t, first_err == .None && second_err == .None, "delayed-send buffers should allocate")
		if first_err != .None || second_err != .None {
			if first_err == .None do byte_pool.release(td.spool, first_buf)
			if second_err == .None do byte_pool.release(td.spool, second_buf)
			return
		}
		copy(first_buf, []byte{1, 2, 3, 4, 5, 6, 7, 8})
		copy(second_buf, []byte{9, 10, 11, 12, 13, 14, 15, 16})

		first_record, second_record: Sim_Delayed_Send_Test_Record
		first_sent := nrc_send_frame(
			first,
			Frame_Lease(Pooled_Frame_Lease{data = first_buf, pool = td.spool}),
			observer = {callback = simulation_delayed_send_test_callback, ctx = &first_record},
		)
		nrc_sim_inject_next_queued_send_error(&ctx.sim, net.TCP_Send_Error(.Not_Connected))
		second_sent := nrc_send_frame(
			second,
			Frame_Lease(Pooled_Frame_Lease{data = second_buf, pool = td.spool}),
			observer = {callback = simulation_delayed_send_test_callback, ctx = &second_record},
		)
		testing.expect(t, first_sent && second_sent, "delayed sends should be accepted")
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 2)
		testing.expect_value(t, first_record.callback_count, 0)
		testing.expect_value(t, second_record.callback_count, 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, first.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, second.sock), 0)

		testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, 1), "selected error completion should run first")
		testing.expect_value(t, second_record.callback_count, 1)
		testing.expect_value(t, second_record.error_count, 1)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 1)

		first_sock := first.sock
		simulation_test_uninstall_client(first)
		ctx.conns[0] = nil
		replacement := simulation_test_install_client(&ctx.sim, 0, "delayed_ws", "replacement", init_send_queue = true)
		testing.expect(t, replacement != nil && replacement.sock == first_sock, "replacement should reuse the simulated socket")
		if replacement == nil do return
		ctx.conns[0] = replacement
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, replacement.sock), 0)

		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim), "stale success completion should run")
		testing.expect_value(t, first_record.callback_count, 1)
		testing.expect_value(t, first_record.nil_count, 0)
		testing.expect_value(t, first_record.error_count, 0)
		testing.expect_value(t, first_record.total_sent, 8)
		testing.expect_value(t, replacement.verified_username, "replacement")
		testing.expect(t, !replacement.is_sending, "stale completion must not mutate replacement send state")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, replacement.sock), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), live_before)
	}
}

@(test)
test_simulation_close_completion_retains_inflight_send_across_socket_reuse :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 120)
		defer simulation_test_end(&ctx)

		old_conn := simulation_test_install_client(&ctx.sim, 0, "pending_io_ws", "old", init_send_queue = true)
		testing.expect(t, old_conn != nil, "old client should install")
		if old_conn == nil do return
		old_handle := old_conn.handle
		old_sock := old_conn.sock
		retained_before := td.retained_connection_count

		buf, alloc_err := byte_pool.alloc(td.spool, 8)
		testing.expect(t, alloc_err == .None, "send buffer should allocate")
		if alloc_err != .None {
			simulation_test_uninstall_client(old_conn)
			return
		}
		record := Sim_Delayed_Send_Test_Record {
			expected_handle = old_handle,
		}
		testing.expect(
			t,
			nrc_send_frame(
				old_conn,
				Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
				observer = {callback = simulation_delayed_send_test_callback, ctx = &record},
			),
			"send should be accepted",
		)
		testing.expect_value(t, old_conn.pending_io, u32(1))

		connection_close(old_conn, false)
		testing.expect_value(t, old_conn.state, Connection_State.Closing)
		testing.expect_value(t, old_conn.pending_io, u32(2))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim), "old send completion should retire before close submission")
		testing.expect_value(t, record.callback_count, 1)
		testing.expect_value(t, record.nil_count, 0)
		testing.expect_value(t, record.unexpected_target_count, 0)
		testing.expect_value(t, old_conn.pending_io, u32(1))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "close pin must retain the old allocation")
		testing.expect(t, connection_get(old_sock) == nil, "logical close must release the socket mapping")
		testing.expect_value(t, td.retained_connection_count, retained_before)

		replacement := simulation_test_install_client(&ctx.sim, 0, "pending_io_ws", "replacement", init_send_queue = true)
		testing.expect(t, replacement != nil && replacement.sock == old_sock, "replacement should reuse the numeric socket")
		if replacement == nil do return
		ctx.conns[0] = replacement
		replacement_handle := replacement.handle

		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "old close completion should run after socket reuse")
		testing.expect(t, connection_get_by_handle(old_handle) == nil, "close completion should reclaim the old allocation")
		testing.expect(t, connection_get(old_sock) == replacement, "old close completion must not clear the replacement mapping")
		testing.expect_value(t, replacement.handle, replacement_handle)
		testing.expect_value(t, replacement.verified_username, "replacement")
		testing.expect_value(t, td.retained_connection_count, retained_before)
		connection_test_live_count -= 1 // Old allocation was reclaimed by the production path.
	}
}

@(test)
test_simulation_close_completion_retains_inflight_writev_across_socket_reuse :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 121)
		defer simulation_test_end(&ctx)

		old_conn := simulation_test_install_client(&ctx.sim, 0, "pending_io_writev", "old", init_send_queue = true)
		testing.expect(t, old_conn != nil, "old client should install")
		if old_conn == nil do return
		old_handle := old_conn.handle
		old_sock := old_conn.sock
		retained_before := td.retained_connection_count
		record := Sim_Delayed_Send_Test_Record {
			expected_handle = old_handle,
		}

		state := alloc_batch_state(2)
		testing.expect(t, state != nil, "batch state should allocate")
		if state == nil {
			simulation_test_uninstall_client(old_conn)
			return
		}
		state.count = 2
		state.items = state.items[:2]
		state.iovec = state.iovec[:2]
		for i in 0 ..< state.count {
			buf, alloc_err := byte_pool.alloc(td.spool, uint(8 + i))
			testing.expect(t, alloc_err == .None, "batch buffer should allocate")
			if alloc_err != .None do return
			state.items[i] = Batch_Item {
				observer = Send_Completion_Observer{callback = simulation_delayed_send_test_callback, ctx = &record},
				handle = old_handle,
				lease = Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			}
			state.iovec[i] = nbio.iovec {
				iov_base = raw_data(buf),
				iov_len  = uint(len(buf)),
			}
		}

		nrc_io_writev_all(old_conn, state)
		testing.expect_value(t, old_conn.pending_io, u32(1))
		connection_close(old_conn, false)
		testing.expect_value(t, old_conn.pending_io, u32(2))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, nrc_sim_run_next_send_completion(&ctx.sim), "old writev completion should retire before close submission")
		testing.expect_value(t, record.callback_count, 2)
		testing.expect_value(t, record.nil_count, 0)
		testing.expect_value(t, record.unexpected_target_count, 0)
		testing.expect_value(t, old_conn.pending_io, u32(1))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "close pin must retain the old allocation")

		replacement := simulation_test_install_client(&ctx.sim, 0, "pending_io_writev", "replacement", init_send_queue = true)
		testing.expect(t, replacement != nil && replacement.sock == old_sock, "replacement should reuse the numeric socket")
		if replacement == nil do return
		ctx.conns[0] = replacement
		replacement_handle := replacement.handle

		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "old close completion should run after socket reuse")
		testing.expect(t, connection_get_by_handle(old_handle) == nil, "close completion should reclaim the old allocation")
		testing.expect(t, connection_get(old_sock) == replacement, "old close completion must not affect replacement")
		testing.expect_value(t, replacement.handle, replacement_handle)
		testing.expect_value(t, td.retained_connection_count, retained_before)
		connection_test_live_count -= 1 // Old allocation was reclaimed by the production path.
	}
}

@(test)
test_simulation_close_completion_retains_inflight_receive_across_socket_reuse :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 123)
		defer simulation_test_end(&ctx)

		old_conn := simulation_test_install_client(&ctx.sim, 0, "pending_io_recv", "old", init_send_queue = true)
		testing.expect(t, old_conn != nil, "old client should install")
		if old_conn == nil do return
		old_handle := old_conn.handle
		old_sock := old_conn.sock
		retained_before := td.retained_connection_count

		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, old_conn, nil, err = net.TCP_Recv_Error(.Not_Connected)), "first receive should enqueue")
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, old_conn, nil, err = net.TCP_Recv_Error(.Not_Connected)), "second receive should enqueue")
		testing.expect_value(t, old_conn.pending_io, u32(2))
		connection_close(old_conn, false)
		testing.expect_value(t, old_conn.pending_io, u32(3))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "receive pins must retain the old allocation")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "old receive head should run")
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "old receive successor must retain the old allocation")
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "old receive successor should run")
		testing.expect_value(t, old_conn.pending_io, u32(1))
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "close pin must retain the old allocation")

		replacement := simulation_test_install_client(&ctx.sim, 0, "pending_io_recv", "replacement", init_send_queue = true)
		testing.expect(t, replacement != nil && replacement.sock == old_sock, "replacement should reuse the numeric socket")
		if replacement == nil do return
		ctx.conns[0] = replacement
		replacement_handle := replacement.handle

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, replacement, masked_ping[:]), "replacement receive should enqueue")
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 1)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, Sim_Event_Domain.Receive), "replacement receive should not depend on old generation")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, replacement.sock), 1)
		testing.expect(t, connection_get_by_handle(old_handle) == old_conn, "replacement receive must not release the old close pin")
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "old close completion should run after socket reuse")
		testing.expect(t, connection_get_by_handle(old_handle) == nil, "close completion should reclaim the old allocation")
		testing.expect(t, connection_get(old_sock) == replacement, "old close completion must not affect replacement")
		testing.expect_value(t, replacement.handle, replacement_handle)
		testing.expect_value(t, replacement.verified_username, "replacement")
		testing.expect_value(t, td.retained_connection_count, retained_before)
		connection_test_live_count -= 1 // Old allocation was reclaimed by the production path.
	}
}

@(test)
test_simulation_crash_discards_receive_dependency_chain_in_order :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 124)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "receive_crash", "client")
		testing.expect(t, conn != nil, "receive-crash client should install")
		if conn == nil do return
		ctx.conns[0] = conn
		for _ in 0 ..< 3 do testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, nil))
		testing.expect_value(t, conn.pending_io, u32(3))

		sim_world_crash(&ctx.sim.world)
		for step in 0 ..< 3 {
			testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 1)
			testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "stale receive head should discard")
			testing.expect_value(t, conn.pending_io, u32(2 - step))
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		}
		testing.expect_value(t, nrc_sim_receive_event_count(&ctx.sim), 0)
	}
}

@(test)
test_simulation_forced_error_terminalizes_partial_send :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 93)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "partial_override", "client", init_send_queue = true)
		testing.expect(t, conn != nil, "partial-override client should install")
		if conn == nil do return
		ctx.conns[0] = conn
		live_before := connection_lifetime_pool_live_alloc_count(td.spool)

		buf, alloc_err := byte_pool.alloc(td.spool, 8)
		testing.expect(t, alloc_err == .None, "partial-override frame should allocate")
		if alloc_err != .None do return
		copy(buf, []byte{1, 2, 3, 4, 5, 6, 7, 8})
		nrc_sim_inject_next_queued_send_partial(&ctx.sim, 3)
		record := Sim_Delayed_Send_Test_Record {
			expected_handle = conn.handle,
		}
		testing.expect(
			t,
			nrc_send_frame(
				conn,
				Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
				observer = {callback = simulation_delayed_send_test_callback, ctx = &record},
			),
			"partial-override send should submit",
		)

		testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, 0, net.TCP_Send_Error(.Unknown)), "forced terminal error should run")
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, record.callback_count, 1)
		testing.expect_value(t, record.error_count, 1)
		testing.expect_value(t, record.total_sent, 0)
		testing.expect_value(t, conn.pending_io, u32(0))
		testing.expect(t, !conn.is_sending && conn.send_watchdog_slot == 0, "forced terminal error should release send ownership")
		testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), live_before)
	}
}

@(test)
test_hegel_simulation_delayed_send_completion_lifetime_choices :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_simulation_delayed_send_completion_lifetime_choices, nil, {test_cases = 200})
		testing.expectf(t, err == nil, "hegel delayed-send lifetime property failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

prop_simulation_delayed_send_completion_lifetime_choices :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	when !NRC_SIMULATION {
		return hgl.valid()
	} else {
		lifetime_action, action_err := hgl.draw_i64(tc, 0, 2)
		if action_err == .Stop_Test do return hgl.abort()
		if action_err != nil do return hgl.interesting("draw delayed-send lifetime action")
		inject_error, error_draw_err := hgl.draw_bool(tc)
		if error_draw_err == .Stop_Test do return hgl.abort()
		if error_draw_err != nil do return hgl.interesting("draw delayed-send error choice")

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 93)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "generated_delayed_ws", "old", init_send_queue = true)
		if conn == nil do return hgl.interesting("install generated delayed-send client")
		ctx.conns[0] = conn
		live_before := connection_lifetime_pool_live_alloc_count(td.spool)

		buf, buf_err := byte_pool.alloc(td.spool, 8)
		if buf_err != .None do return hgl.interesting("allocate generated delayed-send buffer")
		copy(buf, []byte{1, 2, 3, 4, 5, 6, 7, 8})
		if inject_error {
			nrc_sim_inject_next_queued_send_error(&ctx.sim, net.TCP_Send_Error(.Not_Connected))
		}

		record := Sim_Delayed_Send_Test_Record {
			expected_handle = conn.handle,
		}
		if !nrc_send_frame(
			conn,
			Frame_Lease(Pooled_Frame_Lease{data = buf, pool = td.spool}),
			observer = {callback = simulation_delayed_send_test_callback, ctx = &record},
		) {
			return hgl.interesting("submit generated delayed send")
		}
		if nrc_sim_send_completion_count(&ctx.sim) != 1 do return hgl.interesting("generated delayed send completion count")

		switch lifetime_action {
		case 1:
			connection_close(conn, false)
		case 2:
			simulation_test_uninstall_client(conn)
			ctx.conns[0] = nil
			replacement := simulation_test_install_client(&ctx.sim, 0, "generated_delayed_ws", "replacement", init_send_queue = true)
			if replacement == nil do return hgl.interesting("install generated delayed-send replacement")
			ctx.conns[0] = replacement
		}

		if !nrc_sim_run_next_send_completion(&ctx.sim) do return hgl.interesting("run generated delayed send completion")
		if record.callback_count != 1 do return hgl.interesting("generated delayed send callback count")
		if record.nil_count != 0 || record.unexpected_target_count != 0 do return hgl.interesting("generated delayed send stale target mismatch")
		if (record.error_count == 1) != inject_error do return hgl.interesting("generated delayed send error mismatch")
		expected_sent := 8
		if inject_error do expected_sent = 0
		if record.total_sent != expected_sent do return hgl.interesting("generated delayed send byte count")
		if connection_lifetime_pool_live_alloc_count(td.spool) != live_before do return hgl.interesting("generated delayed send pool leak")
		return hgl.valid()
	}
}

@(test)
test_simulation_receive_dependencies_preserve_stream_order_without_serializing_connections :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 95)
		defer simulation_test_end(&ctx)

		first := simulation_test_install_client(&ctx.sim, 0, "receive_order", "first")
		second := simulation_test_install_client(&ctx.sim, 1, "receive_order", "second")
		testing.expect(t, first != nil && second != nil, "receive-order clients should install")
		if first == nil || second == nil do return
		ctx.conns[0] = first
		ctx.conns[1] = second

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, first, masked_ping[:3]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, first, masked_ping[3:]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, second, masked_ping[:3]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, second, masked_ping[3:]))

		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 2)
		testing.expect(t, !nrc_sim_run_receive_at(&ctx.sim, 1), "first connection's suffix must remain blocked")
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 1, Sim_Event_Domain.Receive), "second connection's prefix should run independently")
		testing.expect(t, second.receive_accumulator.buf != nil)
		testing.expect(t, first.receive_accumulator.buf == nil)

		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 2)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 1, Sim_Event_Domain.Receive), "second connection's suffix should follow its prefix")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, second.sock), 1)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, first.sock), 0)

		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "first connection's prefix should remain runnable")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "first connection's suffix should follow its prefix")
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, first.sock), 1)
	}
}

@(test)
test_simulation_receive_dependency_advances_virtual_time_by_unblocked_events :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 97)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "receive_time", "client")
		testing.expect(t, conn != nil, "receive-time client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[:3]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[3:]))
		first_index := sim_world_domain_event_index(&ctx.sim.world, .Receive, 0)
		second_index := sim_world_domain_event_index(&ctx.sim.world, .Receive, 1)
		testing.expect(t, first_index >= 0 && second_index >= 0)
		if first_index < 0 || second_index < 0 do return
		ctx.sim.world.events[first_index].ready_at = time.Millisecond * 30
		ctx.sim.world.events[second_index].ready_at = time.Millisecond * 10

		fired := 0
		_ = nrc_schedule_timer(time.Millisecond * 20, &fired, proc(value: ^int) {
			value^ += 1
		})
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world), 1)
		testing.expect_value(t, ctx.sim.world.now, time.Millisecond * 20)
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "intermediate timer should run before future receive head")
		testing.expect_value(t, fired, 1)

		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world), 1)
		testing.expect_value(t, ctx.sim.world.now, time.Millisecond * 30)
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "future receive head should run next")
		testing.expect_value(t, ctx.sim.world.now, time.Millisecond * 30)
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world), 1)
		testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "already-ready receive successor should run without reversing time")
		testing.expect_value(t, ctx.sim.world.now, time.Millisecond * 30)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
	}
}

@(test)
test_simulation_receive_dependency_cancel_splices_chain_and_blocked_override_is_inert :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 96)
		defer simulation_test_end(&ctx)

		conn := simulation_test_install_client(&ctx.sim, 0, "receive_cancel", "client")
		testing.expect(t, conn != nil, "receive-cancel client should install")
		if conn == nil do return
		ctx.conns[0] = conn

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[:2]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[2:4]))
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[4:]))
		first_index := sim_world_domain_event_index(&ctx.sim.world, .Receive, 0)
		middle_index := sim_world_domain_event_index(&ctx.sim.world, .Receive, 1)
		last_index := sim_world_domain_event_index(&ctx.sim.world, .Receive, 2)
		testing.expect(t, first_index >= 0 && middle_index >= 0 && last_index >= 0)
		if first_index < 0 || middle_index < 0 || last_index < 0 do return
		first_id := ctx.sim.world.events[first_index].id
		middle_id := ctx.sim.world.events[middle_index].id
		testing.expect_value(t, ctx.sim.world.events[last_index].after_event_id, middle_id)

		testing.expect(t, sim_world_cancel_event(&ctx.sim.world, middle_id), "middle receive should cancel")
		last_index = sim_world_domain_event_index(&ctx.sim.world, .Receive, 1)
		testing.expect(t, last_index >= 0)
		if last_index < 0 do return
		testing.expect_value(t, ctx.sim.world.events[last_index].after_event_id, first_id)
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 1)
		testing.expect_value(t, sim_world_runnable_rank_index(&ctx.sim.world, 1, Sim_Event_Domain.Receive), -1)

		before, before_ok := nrc_sim_receive_event_at(&ctx.sim, 1)
		testing.expect(t, before_ok)
		testing.expect(t, !nrc_sim_run_receive_at(&ctx.sim, 1, net.TCP_Recv_Error(.Connection_Closed)), "blocked override should be rejected")
		after, after_ok := nrc_sim_receive_event_at(&ctx.sim, 1)
		testing.expect(t, after_ok)
		testing.expect_value(t, after.received, before.received)
		testing.expect(t, after.err == before.err, "blocked override must not mutate the queued receive")

		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "receive head should run")
		testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 1)
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "spliced successor should run after the head")
	}
}

@(test)
test_simulation_receive_queue_drives_transport_segmentation_eof_and_errors :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 94)
		defer simulation_test_end(&ctx)

		masked_ping := [?]byte{0x89, 0x80, 1, 2, 3, 4}
		for split_at in 1 ..< len(masked_ping) {
			client_id := split_at - 1
			conn := simulation_test_install_client(&ctx.sim, client_id, "receive_ws", "split")
			testing.expectf(t, conn != nil, "split client should install: split_at=%d", split_at)
			if conn == nil do continue
			ctx.conns[client_id] = conn

			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[:split_at]), "first segment should enqueue")
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, masked_ping[split_at:]), "second segment should enqueue")
			testing.expect_value(t, nrc_sim_receive_event_count(&ctx.sim), 2)
			testing.expect_value(t, sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive), 1)
			testing.expect(t, !nrc_sim_run_receive_at(&ctx.sim, 1), "second segment must not overtake its same-connection predecessor")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "first segment should run")
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
			testing.expectf(t, conn.receive_accumulator.buf != nil, "first segment should remain buffered: split_at=%d", split_at)

			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "second segment should run")
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
			testing.expectf(t, conn.receive_accumulator.buf == nil, "complete frame should clear transport accumulator: split_at=%d", split_at)
		}

		// A 64-bit-length masked header needs all 14 bytes before its exact target is
		// known. The initial header allocation is retained when a tiny learned target
		// fits it, and every prefix byte survives target discovery.
		header_frame := make_masked_test_frame(65_536, .opBinary, true)
		header_conn := simulation_test_install_client(&ctx.sim, 12, "receive_ws", "header")
		testing.expect(t, header_conn != nil, "split-header client should install")
		if header_conn != nil {
			ctx.conns[12] = header_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, header_conn, header_frame[:13]), "incomplete 14-byte header should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "incomplete header should run")
			testing.expect_value(t, header_conn.receive_accumulator.target, 0)
			buffer := raw_data(header_conn.receive_accumulator.buf)
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, header_conn, header_frame[13:14]), "header completion should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "header completion should run")
			testing.expect_value(t, header_conn.receive_accumulator.target, len(header_frame))
			testing.expect(t, raw_data(header_conn.receive_accumulator.buf) != buffer, "large learned target should grow header allocation")
			testing.expect(t, bytes.equal(header_conn.receive_accumulator.buf[:14], header_frame[:14]), "split header bytes should be preserved")
		}
		delete(header_frame)

		fitting_frame := make_masked_test_frame(1, .opBinary, true)
		fitting_conn := simulation_test_install_client(&ctx.sim, 15, "receive_ws", "fitting")
		if fitting_conn != nil {
			ctx.conns[15] = fitting_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, fitting_conn, fitting_frame[:1]), "short header prefix should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "short header prefix should run")
			buffer := raw_data(fitting_conn.receive_accumulator.buf)
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, fitting_conn, fitting_frame[1:6]), "remaining short header should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "remaining short header should run")
			testing.expect_value(t, fitting_conn.receive_accumulator.target, len(fitting_frame))
			testing.expect(t, raw_data(fitting_conn.receive_accumulator.buf) == buffer, "fitting learned target should retain allocation")
		}
		delete(fitting_frame)

		// Medium and near-limit frames are accumulated over receive-sized chunks.
		payload_lengths := [2]int{24_000, MAX_FRAME_SIZE - 14}
		for payload_len, frame_index in payload_lengths {
			frame := make_masked_test_frame(payload_len, .opBinary, false)
			conn := simulation_test_install_client(&ctx.sim, 13 + frame_index, "receive_ws", "multi")
			testing.expect(t, conn != nil, "multi-receive client should install")
			if conn != nil {
				ctx.conns[13 + frame_index] = conn
				for offset := 0; offset < len(frame); offset += nbio.BUFFER_SIZE {
					end := min(len(frame), offset + nbio.BUFFER_SIZE)
					testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, frame[offset:end]), "frame chunk should enqueue")
				}
				for nrc_sim_receive_event_count(&ctx.sim) > 0 do testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "frame chunk should run")
				testing.expect(t, conn.state < .Will_Close, "valid multi-receive frame should keep the connection open")
				testing.expect(t, conn.receive_accumulator.buf == nil, "completed multi-receive frame should clear state")
				testing.expect(t, conn.fragment_buf != nil, "completed FIN=false frame should enter message fragmentation state")
				testing.expect_value(t, conn.fragment_len, payload_len)
				if conn.fragment_buf != nil && conn.fragment_len == payload_len {
					for i in 0 ..< payload_len {
						testing.expect_value(t, conn.fragment_buf[i], byte((i * 17 + 23) & 0xff))
					}
				}
				reset_fragment_accumulator(conn)
			}
			delete(frame)
		}

		suffix_conn := simulation_test_install_client(&ctx.sim, 11, "receive_ws", "suffix")
		if suffix_conn != nil {
			ctx.conns[11] = suffix_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, suffix_conn, masked_ping[:1]), "accumulator prefix should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "accumulator prefix should run")
			suffix := [?]byte{0x80, 1, 2, 3, 4, 0x89, 0x80, 5, 6, 7, 8}
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, suffix_conn, suffix[:]), "completion plus fresh frame should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "completion plus fresh frame should run")
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, suffix_conn.sock), 2)
			testing.expect(t, suffix_conn.receive_accumulator.buf == nil, "direct-parsed suffix should leave no accumulator")
		}

		incomplete_suffix_conn := simulation_test_install_client(&ctx.sim, 9, "receive_ws", "incomplete-suffix")
		if incomplete_suffix_conn != nil {
			ctx.conns[9] = incomplete_suffix_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, incomplete_suffix_conn, masked_ping[:1]), "first accumulator prefix should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "first accumulator prefix should run")
			completion_and_prefix := [?]byte{0x80, 1, 2, 3, 4, 0x89}
			testing.expect(
				t,
				nrc_sim_enqueue_receive(&ctx.sim, incomplete_suffix_conn, completion_and_prefix[:]),
				"completion plus incomplete suffix should enqueue",
			)
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "completion plus incomplete suffix should run")
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, incomplete_suffix_conn.sock), 1)
			testing.expect_value(t, incomplete_suffix_conn.receive_accumulator.used, 1)
			testing.expect_value(t, incomplete_suffix_conn.receive_accumulator.target, 0)
			second_completion := [?]byte{0x80, 5, 6, 7, 8}
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, incomplete_suffix_conn, second_completion[:]), "second completion should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "second completion should run")
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, incomplete_suffix_conn.sock), 2)
			testing.expect(t, incomplete_suffix_conn.receive_accumulator.buf == nil, "completed suffix accumulator should clear")
		}

		direct_conn := simulation_test_install_client(&ctx.sim, 10, "receive_ws", "direct")
		if direct_conn != nil {
			ctx.conns[10] = direct_conn
			direct_pong := make_masked_test_frame(4, .opPong, true)
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, direct_conn, direct_pong), "direct pong should enqueue")
			allocations_before := td.spool.allocation_count
			releases_before := td.spool.release_count
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "direct pong should run")
			testing.expect(t, direct_conn.state < .Will_Close, "direct complete frame should keep the connection open")
			testing.expect(t, direct_conn.receive_accumulator.buf == nil, "direct complete frame should not create an accumulator")
			testing.expect_value(t, td.spool.allocation_count, allocations_before)
			testing.expect_value(t, td.spool.release_count, releases_before)
			delete(direct_pong)
		}

		concat_id := len(masked_ping) - 1
		concat_conn := simulation_test_install_client(&ctx.sim, concat_id, "receive_ws", "concat")
		testing.expect(t, concat_conn != nil, "concatenated-frame client should install")
		if concat_conn != nil {
			ctx.conns[concat_id] = concat_conn
			concatenated := [?]byte{0x89, 0x80, 1, 2, 3, 4, 0x89, 0x80, 5, 6, 7, 8}
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, concat_conn, concatenated[:]), "concatenated frames should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "concatenated frames should run")
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, concat_conn.sock), 2)
		}

		eof_id := concat_id + 1
		eof_conn := simulation_test_install_client(&ctx.sim, eof_id, "receive_ws", "eof")
		testing.expect(t, eof_conn != nil, "EOF client should install")
		if eof_conn != nil {
			ctx.conns[eof_id] = eof_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, eof_conn, nil), "EOF should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "EOF should run")
			testing.expect_value(t, eof_conn.state, Connection_State.Closing)
			testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "EOF close completion should run asynchronously")
			connection_test_live_count -= 1
			ctx.conns[eof_id] = nil
		}

		error_id := eof_id + 1
		error_conn := simulation_test_install_client(&ctx.sim, error_id, "receive_ws", "error")
		testing.expect(t, error_conn != nil, "receive-error client should install")
		if error_conn != nil {
			ctx.conns[error_id] = error_conn
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, error_conn, nil, err = net.TCP_Recv_Error(.Not_Connected)), "receive error should enqueue")
			testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "receive error should run")
			testing.expect_value(t, error_conn.state, Connection_State.Closing)
			testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "receive-error close completion should run asynchronously")
			connection_test_live_count -= 1
			ctx.conns[error_id] = nil
		}

		testing.expect_value(t, nrc_sim_receive_event_count(&ctx.sim), 0)
	}
}

@(test)
test_split_websocket_header_growth_oom_closes_once_and_releases_accumulator :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		return
	} else {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 138)
		defer simulation_test_end(&ctx)
		ierr := nbio.init(&td.io)
		testing.expect(t, ierr == .NONE, "nbio.init should make accidental real receive scheduling observable")
		if ierr != .NONE do return
		defer nbio.destroy(&td.io)
		real_io_waiting_baseline := nbio.num_waiting(&td.io)

		conn := simulation_test_install_client(&ctx.sim, 0, "receive_growth_oom", "client")
		testing.expect(t, conn != nil, "receive-growth OOM client should install")
		if conn == nil do return
		ctx.conns[0] = conn
		conn_handle := conn.handle

		frame := make_masked_test_frame(65_536, .opBinary, true)
		defer delete(frame)
		live_before_prefix := connection_lifetime_pool_live_alloc_count(td.spool)
		outstanding_before_prefix := td.spool.allocation_count - td.spool.release_count

		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, frame[:13]), "incomplete extended header should enqueue")
		testing.expect(t, nrc_sim_run_next_receive(&ctx.sim), "incomplete extended header should run")
		testing.expect(t, conn.receive_accumulator.buf != nil, "incomplete header should allocate an accumulator")
		testing.expect_value(t, conn.receive_accumulator.target, 0)
		testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), live_before_prefix + 1)
		testing.expect_value(t, td.spool.allocation_count - td.spool.release_count, outstanding_before_prefix + 1)
		accumulator_ptr := raw_data(conn.receive_accumulator.buf)

		old_allocator := td.spool.backing_allocator
		fail_allocator := Receive_Growth_OOM_Allocator {
			backing = old_allocator,
		}
		td.spool.backing_allocator = runtime.Allocator {
			procedure = receive_growth_oom_allocator_proc,
			data      = &fail_allocator,
		}
		defer td.spool.backing_allocator = old_allocator

		allocations_before_growth := td.spool.allocation_count
		releases_before_growth := td.spool.release_count
		testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, frame[13:14]), "header-completing byte should enqueue")
		sim_client := ctx.sim.clients[conn.sock]
		testing.expect(t, sim_client != nil, "receive-growth OOM client should be registered with simulation")
		delete_key(&ctx.sim.clients, conn.sock)
		previous_logger := context.logger
		context.logger = log.nil_logger()
		receive_ran := nrc_sim_run_next_receive(&ctx.sim)
		context.logger = previous_logger
		testing.expect(t, receive_ran, "header-completing byte should run")
		ctx.sim.clients[conn.sock] = sim_client

		testing.expect_value(t, fail_allocator.failure_count, 1)
		testing.expect_value(t, conn.state, Connection_State.Closing)
		testing.expect_value(t, conn.pending_io, u32(1))
		testing.expect_value(t, nbio.num_waiting(&td.io), real_io_waiting_baseline)
		testing.expect(
			t,
			raw_data(conn.receive_accumulator.buf) == accumulator_ptr,
			"failed growth must retain the original accumulator until close completion",
		)
		testing.expect_value(t, td.spool.allocation_count, allocations_before_growth)
		testing.expect_value(t, td.spool.release_count, releases_before_growth)
		testing.expect_value(t, nrc_sim_receive_event_count(&ctx.sim), 0)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 1)

		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim), "OOM close completion should run")
		testing.expect_value(t, nrc_sim_close_completion_count(&ctx.sim), 0)
		testing.expect_value(t, td.spool.release_count, releases_before_growth + 1)
		testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), live_before_prefix)
		testing.expect_value(t, td.spool.allocation_count - td.spool.release_count, outstanding_before_prefix)
		testing.expect_value(t, td.spool.invalid_release_count, u64(0))
		testing.expect(t, connection_get_by_handle(conn_handle) == nil, "close completion should reclaim the connection handle")
		connection_test_live_count -= 1
		ctx.conns[0] = nil
	}
}
