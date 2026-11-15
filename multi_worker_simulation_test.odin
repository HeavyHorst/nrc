package main

import "base:runtime"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:testing"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: runtime.Allocator_Error
	_ :: fmt.tprintf
	_ :: net.TCP_Socket
	_ :: strings.has_prefix
	_ :: testing.T
	_ :: pr.parseServerReadyMessage
}

when NRC_SIMULATION {
	SIM_MULTI_WORKER_COUNT :: 2

	Sim_Test_Worker_State :: struct {
		thread:                         Server_Thread,
		connection_storage_initialized: bool,
		connection_test_live_count:     int,
		message_seq_counter:            pr.MessageSeq,
		worker_fast_tick_budget:        int,
		initialized:                    bool,
	}

	Sim_Multi_Worker_Test_Context :: struct {
		sim:                   Sim_Runtime,
		workers:               [SIM_MULTI_WORKER_COUNT]Sim_Test_Worker_State,
		active_worker:         int,
		event_entered_workers: [24]int,
		event_enter_count:     int,
		driver_thread:         Server_Thread,
		driver_message_seq:    pr.MessageSeq,
		driver_fast_budget:    int,
	}

	Sim_Multi_Worker_Handoff_Action :: struct {
		expected_worker:         int,
		observed_worker:         int,
		call_count:              int,
		did_work:                bool,
		pool_live_before:        uint,
		invalid_releases_before: u64,
	}

	sim_multi_worker_handoff_action :: proc(user: rawptr) {
		action := (^Sim_Multi_Worker_Handoff_Action)(user)
		action.observed_worker = td.thread_index
		action.call_count += 1
		action.pool_live_before = connection_lifetime_pool_live_alloc_count(td.spool)
		action.invalid_releases_before = td.spool.invalid_release_count
		action.did_work = process_pending_connections()
	}

	sim_multi_worker_move_into_tls :: proc(ctx: ^Sim_Multi_Worker_Test_Context, worker_index: int) {
		assert(ctx.active_worker == -1, "simulation test worker already active")
		assert(worker_index >= 0 && worker_index < SIM_MULTI_WORKER_COUNT, "invalid simulation test worker")
		state := &ctx.workers[worker_index]
		assert(state.initialized, "simulation test worker not initialized")
		td = state.thread
		state.thread = {}
		connection_storage_initialized = state.connection_storage_initialized
		state.connection_storage_initialized = false
		connection_test_live_count = state.connection_test_live_count
		state.connection_test_live_count = 0
		message_seq_counter = state.message_seq_counter
		state.message_seq_counter = 0
		worker_fast_tick_budget = state.worker_fast_tick_budget
		state.worker_fast_tick_budget = 0
		ctx.active_worker = worker_index
	}

	sim_multi_worker_move_out_of_tls :: proc(ctx: ^Sim_Multi_Worker_Test_Context) {
		assert(ctx.active_worker >= 0 && ctx.active_worker < SIM_MULTI_WORKER_COUNT, "no simulation test worker active")
		state := &ctx.workers[ctx.active_worker]
		state.thread = td
		td = {
			thread_index = -1,
		}
		state.connection_storage_initialized = connection_storage_initialized
		connection_storage_initialized = false
		state.connection_test_live_count = connection_test_live_count
		connection_test_live_count = 0
		state.message_seq_counter = message_seq_counter
		message_seq_counter = 0
		state.worker_fast_tick_budget = worker_fast_tick_budget
		worker_fast_tick_budget = 0
		ctx.active_worker = -1
	}

	sim_multi_worker_event_enter :: proc(raw_ctx: rawptr, worker_index: int) {
		ctx := cast(^Sim_Multi_Worker_Test_Context)raw_ctx
		assert(ctx.event_enter_count < len(ctx.event_entered_workers), "simulation worker event trace exhausted")
		ctx.event_entered_workers[ctx.event_enter_count] = worker_index
		ctx.event_enter_count += 1
		sim_multi_worker_move_into_tls(ctx, worker_index)
	}

	sim_multi_worker_event_leave :: proc(raw_ctx: rawptr) {
		ctx := cast(^Sim_Multi_Worker_Test_Context)raw_ctx
		sim_multi_worker_move_out_of_tls(ctx)
	}

	sim_multi_worker_test_begin :: proc(ctx: ^Sim_Multi_Worker_Test_Context, server: ^NRC_Server) {
		ctx^ = {
			active_worker = -1,
		}
		assert(!connection_storage_initialized, "simulation driver unexpectedly owns connection storage")
		assert(connection_test_live_count == 0, "simulation driver unexpectedly owns test connections")
		ctx.driver_thread = td
		ctx.driver_message_seq = message_seq_counter
		ctx.driver_fast_budget = worker_fast_tick_budget
		td = {
			thread_index = -1,
		}
		message_seq_counter = 0
		worker_fast_tick_budget = 0
		nrc_sim_runtime_init(&ctx.sim)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			worker_state_init_core(server, worker_index, 8)
			ctx.workers[worker_index].initialized = true
			ctx.active_worker = worker_index
			sim_multi_worker_move_out_of_tls(ctx)
		}
		sim_world_set_worker_switch_hooks(&ctx.sim.world, ctx, sim_multi_worker_event_enter, sim_multi_worker_event_leave)
	}

	sim_multi_worker_test_end :: proc(ctx: ^Sim_Multi_Worker_Test_Context, socks: []net.TCP_Socket) {
		assert(ctx.active_worker == -1, "simulation test ended with active worker")
		nrc_sim_runtime_destroy(&ctx.sim)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			for sock in socks {
				if conn := connection_get(sock); conn != nil {
					simulation_test_uninstall_client(conn)
				}
			}
			worker_state_destroy_core_for_test()
			ctx.workers[worker_index].initialized = false
			td = {
				thread_index = -1,
			}
			connection_storage_initialized = false
			connection_test_live_count = 0
			message_seq_counter = 0
			worker_fast_tick_budget = 0
			ctx.active_worker = -1
		}
		td = ctx.driver_thread
		message_seq_counter = ctx.driver_message_seq
		worker_fast_tick_budget = ctx.driver_fast_budget
		ctx^ = {}
	}

	sim_multi_worker_workspace_for :: proc(worker_index: int) -> string {
		candidates := [?]string {
			"multi_worker_alpha",
			"multi_worker_beta",
			"multi_worker_gamma",
			"multi_worker_delta",
			"multi_worker_epsilon",
			"multi_worker_zeta",
			"multi_worker_eta",
			"multi_worker_theta",
		}
		for candidate in candidates {
			if http_upgrade_target_worker_index(candidate, SIM_MULTI_WORKER_COUNT) == worker_index do return candidate
		}
		return ""
	}

	sim_multi_worker_owned_event_index :: proc(world: ^Sim_World, domain: Sim_Event_Domain, worker_index: int) -> int {
		for event, index in world.events {
			if event.domain == domain && event.worker_index == worker_index do return index
		}
		return -1
	}

	sim_multi_worker_send_ordinal_for_worker :: proc(ctx: ^Sim_Multi_Worker_Test_Context, worker_index: int) -> int {
		ordinal := 0
		for {
			index := sim_world_domain_event_index(&ctx.sim.world, .Send, ordinal)
			if index < 0 do return -1
			if ctx.sim.world.events[index].worker_index == worker_index do return ordinal
			ordinal += 1
		}
	}

	@(test)
	// HTTP requests route through production pending queues into independent
	// worker-owned TLS; each asynchronous completion returns to its owner.
	test_simulation_world_dispatches_events_in_independent_worker_state :: proc(t: ^testing.T) {
		queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			queue, queue_err := pending_queue_create(4)
			testing.expect_value(t, queue_err, runtime.Allocator_Error.None)
			if queue_err != .None {
				for cleanup_index in 0 ..< worker_index do pending_queue_destroy(queues[cleanup_index])
				return
			}
			queues[worker_index] = queue
		}
		defer for queue in queues do pending_queue_destroy(queue)
		pending_queues := make([]Pending_Connection_Queue, SIM_MULTI_WORKER_COUNT)
		defer delete(pending_queues)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do pending_queues[worker_index] = queues[worker_index]
		server := NRC_Server {
			main_thread         = 0,
			pending_connections = pending_queues,
		}
		old_thread_count := thread_count
		old_bot_secret := bot_auth_secret
		thread_count = SIM_MULTI_WORKER_COUNT
		bot_auth_secret = "multi-worker-secret"
		defer {
			thread_count = old_thread_count
			bot_auth_secret = old_bot_secret
		}
		socks := [?]net.TCP_Socket{connection_test_fake_socket(300), connection_test_fake_socket(301)}
		workspaces := [?]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
		usernames := [?]string{"multi-worker-user-0", "multi-worker-user-1"}
		testing.expect(t, workspaces[0] != "" && workspaces[1] != "", "workspace fixtures should cover both workers")
		if workspaces[0] == "" || workspaces[1] == "" do return
		ctx := new(Sim_Multi_Worker_Test_Context)
		sim_multi_worker_test_begin(ctx, &server)
		defer {
			// A failed prerequisite can leave an upgrade owned by a pending queue.
			// Adopt and terminalize it to release its HTTP temporary connection.
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, worker_index)
				_ = process_pending_connections()
				sim_multi_worker_move_out_of_tls(ctx)
			}
			nrc_sim_run_all_send_completions(&ctx.sim)
			sim_multi_worker_test_end(ctx, socks[:])
			free(ctx)
		}
		for sock in socks do nrc_sim_register_client(&ctx.sim, sock)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			request := fmt.tprintf(
				"GET /%s HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nX-NRC-User-Type: bot\r\nX-NRC-Bot-Secret: multi-worker-secret\r\nX-NRC-Bot-Nickname: %s\r\n\r\n",
				workspaces[worker_index],
				usernames[worker_index],
			)
			upgrade := new(HTTP_Upgrade_Connection)
			upgrade.server = &server
			upgrade.sock = socks[worker_index]
			upgrade.state = .New
			result := http_upgrade_process_received(upgrade, len(request), transmute([]byte)request)
			testing.expect_value(t, result, HTTP_Upgrade_Recv_Result.Done)
		}
		handoff_actions: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_Handoff_Action
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			handoff_actions[worker_index].expected_worker = worker_index
			action_id := sim_world_enqueue_driver_action(&ctx.sim.world, &handoff_actions[worker_index], sim_multi_worker_handoff_action)
			testing.expect(t, action_id != 0, "worker-owned handoff action should enqueue")
			sim_multi_worker_move_out_of_tls(ctx)
		}
		// Worker 1 makes partial bootstrap progress while worker 0 remains pending.
		nrc_sim_inject_next_queued_send_partial(&ctx.sim, 3)
		worker_one_action_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 1)
		testing.expect(
			t,
			worker_one_action_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, worker_one_action_index),
			"worker 1 handoff action should run first",
		)
		testing.expect_value(t, handoff_actions[1].call_count, 1)
		testing.expect_value(t, handoff_actions[1].observed_worker, 1)
		testing.expect(t, handoff_actions[1].did_work, "worker 1 should adopt its pending upgrade")
		sim_multi_worker_move_into_tls(ctx, 0)
		testing.expect_value(t, td.connection_count, 0)
		testing.expect_value(t, len(td.workspaces), 0)
		testing.expect(t, connection_get(socks[0]) == nil && connection_get(socks[1]) == nil, "unadopted worker must not resolve either socket")
		sim_multi_worker_move_out_of_tls(ctx)
		worker_one_send_ordinal := sim_multi_worker_send_ordinal_for_worker(ctx, 1)
		worker_one_progress, progress_ok := nrc_sim_send_completion_at(&ctx.sim, worker_one_send_ordinal)
		testing.expect(t, progress_ok && worker_one_progress.continues && worker_one_progress.sent == 3, "worker 1 bootstrap should expose partial progress")
		testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, worker_one_send_ordinal), "worker 1 bootstrap progress should run")
		sim_multi_worker_move_into_tls(ctx, 1)
		worker_one_conn := connection_get(socks[1])
		testing.expect(t, worker_one_conn != nil, "worker 1 connection should remain installed after partial progress")
		if worker_one_conn != nil {
			testing.expect_value(t, td.connection_count, 1)
			testing.expect_value(t, len(td.workspaces), 1)
			testing.expect_value(t, worker_one_conn.pending_io, u32(1))
			testing.expect(t, worker_one_conn.is_sending && worker_one_conn.send_watchdog_slot > 0, "partial bootstrap should retain send/watchdog ownership")
			testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), handoff_actions[1].pool_live_before + 1)
			testing.expect_value(t, td.spool.invalid_release_count, handoff_actions[1].invalid_releases_before)
		}
		testing.expect(t, connection_get(socks[0]) == nil, "worker 1 must not resolve worker 0's pending socket")
		sim_multi_worker_move_out_of_tls(ctx)
		worker_zero_action_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 0)
		testing.expect(
			t,
			worker_zero_action_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, worker_zero_action_index),
			"worker 0 handoff action should run after peer progress",
		)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			testing.expect_value(t, handoff_actions[worker_index].call_count, 1)
			testing.expect_value(t, handoff_actions[worker_index].observed_worker, worker_index)
			testing.expect(t, handoff_actions[worker_index].did_work, "target worker should adopt exactly one routed upgrade")
		}
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), SIM_MULTI_WORKER_COUNT)
		for event in ctx.sim.world.events {
			if event.domain == .Send do testing.expect_value(t, event.worker_index, int(event.target.id) == int(socks[0]) ? 0 : 1)
		}
		// Complete in the opposite order from adoption, checking TLS and leases.
		worker_zero_send_ordinal := sim_multi_worker_send_ordinal_for_worker(ctx, 0)
		testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, worker_zero_send_ordinal), "worker 0 terminal completion should run first")
		worker_one_send_ordinal = sim_multi_worker_send_ordinal_for_worker(ctx, 1)
		testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, worker_one_send_ordinal), "worker 1 terminal completion should run second")
		testing.expect_value(t, ctx.event_enter_count, 5)
		expected_event_workers := [?]int{1, 1, 0, 0, 1}
		for worker_index, event_index in expected_event_workers do testing.expect_value(t, ctx.event_entered_workers[event_index], worker_index)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			conn := connection_get(socks[worker_index])
			testing.expect_value(t, td.connection_count, 1)
			testing.expect_value(t, len(td.workspaces), 1)
			testing.expect(t, conn != nil, "completion should preserve owner connection")
			if conn != nil {
				testing.expect_value(t, conn.thread_index, worker_index)
				testing.expect(t, conn.workspace_id == workspaces[worker_index], "worker workspace should remain isolated")
				testing.expect(t, conn.verified_username == usernames[worker_index], "worker identity should remain isolated")
				testing.expect_value(t, conn.pending_io, 0)
				testing.expect(t, !conn.is_sending && conn.send_watchdog_slot == 0, "terminal bootstrap should clear send ownership")
			}
			testing.expect(t, connection_get(socks[1 - worker_index]) == nil, "completion must not leak the other worker's handle")
			testing.expect(t, !process_pending_connections(), "empty pending queue should not repeat adoption")
			testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), handoff_actions[worker_index].pool_live_before)
			testing.expect_value(t, td.spool.invalid_release_count, handoff_actions[worker_index].invalid_releases_before)
			sim_multi_worker_move_out_of_tls(ctx)
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, socks[worker_index]), 1)
			wire := nrc_sim_client_frame(&ctx.sim, socks[worker_index], 0)
			testing.expect(t, strings.has_prefix(string(wire), "HTTP/1.1 101 Switching Protocols"), "bootstrap should begin with HTTP 101")
			if len(wire) <= 126 do continue
			ready_payload, ready_ok := nrc_sim_frame_protocol_payload(wire[126:])
			testing.expect(t, ready_ok, "bootstrap should contain a ServerReady frame")
			if ready_ok {
				ready, ready_err := pr.parseServerReadyMessage(ready_payload)
				testing.expect(t, ready_err == nil, "ServerReady should parse")
				if ready_err == nil do testing.expect(t, string(ready.username) == usernames[worker_index], "ServerReady must carry the owner identity")
			}
		}
	}
}
