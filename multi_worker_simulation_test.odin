package main

import "base:runtime"

import "core:fmt"
import "core:log"
import "core:net"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:sys/linux"
import "core:testing"

import hgl "hegel"
import "persistence"
import pr "protocol"
import "spsc"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: runtime.Allocator_Error
	_ :: fmt.tprintf
	_ :: log.nil_logger
	_ :: net.TCP_Socket
	_ :: chan.try_recv
	_ :: strings.has_prefix
	_ :: sync.atomic_load
	_ :: testing.T
	_ :: linux.Errno
	_ :: hgl.run
	_ :: persistence.LOG_HEADER_SIZE
	_ :: pr.parseServerReadyMessage
	_ :: spsc.can_pop
	_ :: ws.opcode
}

when NRC_SIMULATION {
	SIM_MULTI_WORKER_COUNT :: 2

	Sim_Multi_Worker_WebSocket_Mutation :: enum u8 {
		Update_Task,
		Delete_Task,
		Create_Asset,
		Create_Edge,
		Create_Asset_Edge,
	}

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

	Sim_Multi_Worker_Pre_Tick_Action :: struct {
		called:   bool,
		did_work: bool,
	}

	sim_multi_worker_handoff_action :: proc(user: rawptr) {
		action := (^Sim_Multi_Worker_Handoff_Action)(user)
		action.observed_worker = td.thread_index
		action.call_count += 1
		action.pool_live_before = connection_lifetime_pool_live_alloc_count(td.spool)
		action.invalid_releases_before = td.spool.invalid_release_count
		action.did_work = process_pending_connections()
	}

	sim_multi_worker_pre_tick_action :: proc(user: rawptr) {
		action := (^Sim_Multi_Worker_Pre_Tick_Action)(user)
		action.called = true
		nrc_sim_runtime.compaction_job_event_submission = true
		defer if nrc_sim_runtime != nil do nrc_sim_runtime.compaction_job_event_submission = false
		action.did_work = worker_run_pre_tick()
	}

	Sim_Multi_Worker_Generated_Campaign :: struct {
		ctx:                      ^Sim_Multi_Worker_Test_Context,
		queues:                   [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue,
		queue_count:              int,
		pending_queues:           []Pending_Connection_Queue,
		server:                   NRC_Server,
		models:                   [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model,
		first_epoch_models:       [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model,
		intermediate_models:      [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model,
		first_epoch_records:      [SIM_MULTI_WORKER_COUNT]u64,
		intermediate_records:     [SIM_MULTI_WORKER_COUNT]u64,
		record_counts:            [SIM_MULTI_WORKER_COUNT]u64,
		mutation_counts:          [SIM_MULTI_WORKER_COUNT]int,
		enqueued_mutation_counts: [SIM_MULTI_WORKER_COUNT]int,
		second_epoch_mutations:   [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation,
		intermediate_durable:     [SIM_MULTI_WORKER_COUNT]bool,
		fsync_error_attempts:     [SIM_MULTI_WORKER_COUNT]int,
		fsync_attempt_counts:     [SIM_MULTI_WORKER_COUNT]int,
		durable_epochs:           [SIM_MULTI_WORKER_COUNT]int,
		fsync_error_observed:     [SIM_MULTI_WORKER_COUNT]bool,
		fatal_error_observed:     bool,
		dependent_edge_enqueued:  [SIM_MULTI_WORKER_COUNT]bool,
		recovered_intermediate:   [SIM_MULTI_WORKER_COUNT]bool,
		connections:              [SIM_MULTI_WORKER_COUNT]^NRC_Connection,
		pool_live_before:         [SIM_MULTI_WORKER_COUNT]uint,
		invalid_releases_before:  [SIM_MULTI_WORKER_COUNT]u64,
		workspaces:               [SIM_MULTI_WORKER_COUNT]string,
		shard_dirs:               [SIM_MULTI_WORKER_COUNT]string,
		started:                  bool,
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
		for nrc_sim_run_fsync_completion_at(&ctx.sim, 0, .EIO) {}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			if td.shard_writers.mode != .Inactive || len(td.shard_writers.writers) != 0 {
				assert(shutdown_shard_writer_registry(&td.shard_writers), "simulation worker shard writer shutdown failed")
			}
			sim_multi_worker_move_out_of_tls(ctx)
		}
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
			if http_upgrade_target_worker_index(candidate, SIM_MULTI_WORKER_COUNT) == worker_index {
				return candidate
			}
		}
		return ""
	}

	sim_multi_worker_init_single_shard_writer :: proc(
		ctx: ^Sim_Multi_Worker_Test_Context,
		worker_index: int,
		workspace, shard_dir: string,
		prepare_storage: bool,
	) -> ^Shard_Transaction_Writer {
		sim_multi_worker_move_into_tls(ctx, worker_index)
		defer sim_multi_worker_move_out_of_tls(ctx)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		owner, owner_ok := logical_shard_worker(shard, SIM_MULTI_WORKER_COUNT)
		if !owner_ok || owner != worker_index do return nil
		if prepare_storage {
			if _, storage_ok := generated_semantic_virtual_storage_prepare(&ctx.sim.world, shard_dir); !storage_ok do return nil
		}

		registry := &td.shard_writers
		if registry.mode != .Inactive || len(registry.writers) != 0 do return nil
		for &writer_index in registry.writer_index do writer_index = -1
		registry.worker = worker_index
		registry.worker_count = SIM_MULTI_WORKER_COUNT
		registry.writers = make([dynamic]Shard_Transaction_Writer, 1)
		if !init_managed_shard_transaction_writer(
			&registry.writers[0],
			sim_world_storage_context(&ctx.sim.world),
			shard_dir,
			shard,
			worker_index,
			SIM_MULTI_WORKER_COUNT,
		) {
			delete(registry.writers)
			registry^ = {}
			return nil
		}
		registry.writer_index[shard] = 0
		registry.mode = .Active
		return &registry.writers[0]
	}

	sim_multi_worker_discard_process_writer :: proc(ctx: ^Sim_Multi_Worker_Test_Context, worker_index: int) -> bool {
		sim_multi_worker_move_into_tls(ctx, worker_index)
		defer sim_multi_worker_move_out_of_tls(ctx)
		registry := &td.shard_writers
		if registry.mode != .Active || len(registry.writers) != 1 do return false
		generated_semantic_virtual_process_discard(&registry.writers[0])
		delete(registry.writers)
		registry^ = {}
		return true
	}

	sim_multi_worker_generated_campaign_end :: proc(campaign: ^Sim_Multi_Worker_Generated_Campaign) {
		if campaign == nil do return
		if campaign.started && campaign.ctx != nil {
			if campaign.ctx.active_worker >= 0 do sim_multi_worker_move_out_of_tls(campaign.ctx)
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do _ = sim_multi_worker_discard_process_writer(campaign.ctx, worker_index)
			sim_world_crash(&campaign.ctx.sim.world)
			for len(campaign.ctx.sim.world.events) > 0 do if !sim_world_run_next_event(&campaign.ctx.sim.world) do break
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(campaign.ctx, worker_index)
				if conn := campaign.connections[worker_index]; conn != nil && connection_get_by_handle(conn.handle) != nil {
					send_watchdog_untrack(conn)
					conn.is_sending = false
					conn.send_started_at = {}
					td.next_send_watchdog_at = {}
					simulation_test_uninstall_client(conn)
				}
				campaign.connections[worker_index] = nil
				sim_multi_worker_move_out_of_tls(campaign.ctx)
			}
			sim_multi_worker_test_end(campaign.ctx, nil)
			free(campaign.ctx)
		}
		if campaign.pending_queues != nil do delete(campaign.pending_queues)
		for queue_index in 0 ..< campaign.queue_count do pending_queue_destroy(campaign.queues[queue_index])
		campaign^ = {}
	}

	Sim_Multi_Worker_Compaction_Step :: enum u8 {
		Job_0,
		Job_1,
		Result_0,
		Result_1,
		Crash,
	}

	Sim_Multi_Worker_Compaction_Case :: struct {
		steps:            [5]Sim_Multi_Worker_Compaction_Step,
		step_count:       int,
		publication_mask: u8,
	}

	Sim_Multi_Worker_Compaction_Issuance_Step :: enum u8 {
		Fsync_0,
		Fsync_1,
		Receive_0,
		Receive_1,
		Issue_0,
		Issue_1,
		Job_0,
		Job_1,
		Result_0,
		Result_1,
		Rotate_0,
		Rotate_1,
		Crash,
	}

	Sim_Multi_Worker_Compaction_Issuance_Case :: struct {
		steps:            [12]Sim_Multi_Worker_Compaction_Issuance_Step,
		step_count:       int,
		issuance_mask:    u8,
		publication_mask: u8,
		recover:          bool,
	}

	Sim_Multi_Worker_Compaction_Rotation_Action :: struct {
		worker_index:     int,
		called:           bool,
		rotated:          bool,
		manifest:         Shard_Compaction_Manifest,
		later_descriptor: Shard_Segment_Descriptor,
	}

	sim_multi_worker_compaction_rotation_action :: proc(user: rawptr) {
		action := (^Sim_Multi_Worker_Compaction_Rotation_Action)(user)
		action.called = true
		if td.thread_index != action.worker_index || len(td.shard_writers.writers) != 1 do return
		writer := &td.shard_writers.writers[0]
		prior_count := len(writer.catalog.segments)
		if writer.owner_worker != action.worker_index ||
		   writer.fsync_in_flight ||
		   writer.wal.durable_record_count != writer.wal.record_count ||
		   !rotate_shard_writer_for_compaction(writer) ||
		   len(writer.catalog.segments) != prior_count + 1 {
			return
		}
		action.rotated = true
		action.manifest = writer.manifest
		action.later_descriptor = writer.catalog.segments[prior_count]
	}

	Sim_Multi_Worker_Compaction_Issuance_Action :: struct {
		world:             ^Sim_World,
		worker_index:      int,
		expected_manifest: Shard_Compaction_Manifest,
		expected_segments: [4]Shard_Segment_Descriptor,
		expected_count:    int,
		called:            bool,
		source_exact:      bool,
		issued:            bool,
		job_event_id:      u64,
	}

	sim_multi_worker_compaction_issuance_job_exact :: proc(action: ^Sim_Multi_Worker_Compaction_Issuance_Action) -> bool {
		if action == nil || !action.issued || action.job_event_id == 0 do return false
		for event in action.world.events {
			if event.id != action.job_event_id do continue
			payload, payload_ok := event.payload.(Sim_Compaction_Job_Event)
			if !payload_ok ||
			   event.domain != .Compaction_Job ||
			   event.worker_index != action.worker_index ||
			   payload.job.owner_worker != action.worker_index ||
			   payload.job.manifest != action.expected_manifest ||
			   len(payload.job.source.segments) != action.expected_count {
				return false
			}
			for index in 0 ..< action.expected_count {
				if payload.job.source.segments[index] != action.expected_segments[index] do return false
			}
			return true
		}
		return false
	}

	sim_multi_worker_compaction_issuance_action :: proc(user: rawptr) {
		action := (^Sim_Multi_Worker_Compaction_Issuance_Action)(user)
		action.called = true
		if td.thread_index != action.worker_index || len(td.shard_writers.writers) != 1 || nrc_sim_runtime == nil || &nrc_sim_runtime.world != action.world {
			return
		}
		writer := &td.shard_writers.writers[0]
		if writer.owner_worker != action.worker_index || writer.manifest != action.expected_manifest do return
		source, source_ok := shard_segment_source_for_writer(writer)
		if !source_ok do return
		defer destroy_shard_segment_clean_source(&source)
		if source.shard != writer.shard || len(source.segments) != action.expected_count do return
		for index in 0 ..< action.expected_count {
			if source.segments[index] != action.expected_segments[index] do return
		}
		action.source_exact = true
		nrc_sim_runtime.compaction_job_event_submission = true
		defer if nrc_sim_runtime != nil do nrc_sim_runtime.compaction_job_event_submission = false
		if !worker_run_pre_tick() do return
		index := sim_multi_worker_compaction_event_index(action.world, .Compaction_Job, action.worker_index)
		if index < 0 do return
		event := action.world.events[index]
		payload, payload_ok := event.payload.(Sim_Compaction_Job_Event)
		if !payload_ok ||
		   payload.job.owner_worker != action.worker_index ||
		   payload.job.manifest != action.expected_manifest ||
		   payload.job.source.shard != writer.shard ||
		   len(payload.job.source.segments) != action.expected_count {
			return
		}
		for segment_index in 0 ..< action.expected_count {
			if payload.job.source.segments[segment_index] != action.expected_segments[segment_index] do return
		}
		action.issued = true
		action.job_event_id = event.id
	}

	sim_multi_worker_owned_event_index :: proc(world: ^Sim_World, domain: Sim_Event_Domain, worker_index: int) -> int {
		for event, index in world.events {
			if event.domain == domain && event.worker_index == worker_index do return index
		}
		return -1
	}

	sim_multi_worker_compaction_event_index :: proc(world: ^Sim_World, domain: Sim_Event_Domain, worker_index: int) -> int {
		for event, index in world.events {
			if event.domain != domain do continue
			if domain == .Compaction_Job {
				payload, ok := event.payload.(Sim_Compaction_Job_Event)
				if ok && payload.job.owner_worker == worker_index do return index
			} else if domain == .Compaction_Result {
				payload, ok := event.payload.(Sim_Compaction_Result_Event)
				if ok && payload.result.owner_worker == worker_index do return index
			}
		}
		return -1
	}

	sim_multi_worker_runnable_rank_for_event :: proc(world: ^Sim_World, event_id: u64) -> int {
		count := sim_world_prepare_runnable(world)
		for rank in 0 ..< count {
			index := sim_world_runnable_rank_index(world, rank)
			if index >= 0 && world.events[index].id == event_id do return rank
		}
		return -1
	}

	@(test)
	test_simulation_pre_tick_rotation_makes_compaction_eligible_in_same_turn :: proc(t: ^testing.T) {
		when SHARD_WAL_SEGMENT_MAX_BYTES <= persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE {
			return
		} else {
			queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				queue, queue_err := pending_queue_create(1)
				if !testing.expect_value(t, queue_err, runtime.Allocator_Error.None) {
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
				pending_connections = pending_queues,
			}

			ctx := new(Sim_Multi_Worker_Test_Context)
			sim_multi_worker_test_begin(ctx, &server)
			defer {
				sim_multi_worker_test_end(ctx, nil)
				free(ctx)
			}
			workspaces := [SIM_MULTI_WORKER_COUNT]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
			shard_dirs := [SIM_MULTI_WORKER_COUNT]string{"/pre-tick-worker-0", "/pre-tick-worker-1"}
			models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
			baseline_manifests: [SIM_MULTI_WORKER_COUNT]Shard_Compaction_Manifest
			active_generations: [SIM_MULTI_WORKER_COUNT]u64
			actions: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_Pre_Tick_Action
			action_ids: [SIM_MULTI_WORKER_COUNT]u64
			rotation_reserve := u64(persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE)

			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], true)
				if !testing.expect(t, writer != nil, "pre-tick worker should initialize its shard") do return
				sim_multi_worker_move_into_tls(ctx, worker_index)
				if !testing.expect(
					t,
					generated_shard_apply_op(
						&models[worker_index],
						writer,
						transmute([]byte)workspaces[worker_index],
						shard_dirs[worker_index],
						Generated_Shard_Op{kind = .Create_Task},
					),
					"pre-tick worker transaction should apply",
				) {
					sim_multi_worker_move_out_of_tls(ctx)
					return
				}
				baseline_manifests[worker_index] = writer.manifest
				active_generations[worker_index] = writer.manifest.active_generation
				writer.commit_started = {}
				writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES - rotation_reserve - (worker_index == 0 ? 1 : 0)
				action_ids[worker_index] = sim_world_enqueue_driver_action(&ctx.sim.world, &actions[worker_index], sim_multi_worker_pre_tick_action)
				testing.expect(t, action_ids[worker_index] != 0, "pre-tick action should enqueue")
				sim_multi_worker_move_out_of_tls(ctx)
			}

			worker_zero_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 0)
			if !testing.expect(t, worker_zero_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, worker_zero_index), "below-boundary pre-tick action should dispatch") do return
			testing.expect(t, actions[0].called && actions[0].did_work, "below-boundary turn should submit fsync work")
			testing.expect_value(t, sim_multi_worker_owned_event_index(&ctx.sim.world, .Fsync, 0) >= 0, true)
			testing.expect_value(t, sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Job, 0), -1)

			sim_multi_worker_move_into_tls(ctx, 0)
			writer_zero := &td.shard_writers.writers[0]
			testing.expect_value(t, writer_zero.manifest, baseline_manifests[0])
			testing.expect(
				t,
				writer_zero.fsync_in_flight && writer_zero.fsync_snapshot.record_count == 1,
				"below-boundary turn should capture the pending transaction",
			)
			if diagnostic, exact := generated_shard_compare(&models[0], workspaces[0], writer_zero.floors); !exact {
				testing.expectf(t, false, "below-boundary semantic state differed: %s", diagnostic)
			}
			sim_multi_worker_move_out_of_tls(ctx)

			// The peer remains untouched until its own worker-owned turn runs.
			sim_multi_worker_move_into_tls(ctx, 1)
			writer_one := &td.shard_writers.writers[0]
			testing.expect_value(t, writer_one.manifest, baseline_manifests[1])
			testing.expect(t, !writer_one.fsync_in_flight && writer_one.wal.record_count == 1, "peer pending WAL should remain untouched")
			sim_multi_worker_move_out_of_tls(ctx)

			worker_one_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 1)
			if !testing.expect(t, worker_one_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, worker_one_index), "rotation-boundary pre-tick action should dispatch") do return
			testing.expect(t, actions[1].called && actions[1].did_work, "rotation-boundary turn should rotate and issue compaction")
			testing.expect_value(t, sim_multi_worker_owned_event_index(&ctx.sim.world, .Fsync, 1), -1)
			job_index := sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Job, 1)
			if !testing.expect(t, job_index >= 0, "same turn should issue newly eligible compaction") do return

			sim_multi_worker_move_into_tls(ctx, 1)
			writer_one = &td.shard_writers.writers[0]
			expected_descriptor := Shard_Segment_Descriptor{.Generation_WAL, active_generations[1]}
			testing.expect(t, writer_one.manifest.manifest_generation > baseline_manifests[1].manifest_generation)
			testing.expect(t, writer_one.manifest.active_generation != active_generations[1])
			testing.expect_value(t, writer_one.catalog_segments, 1)
			testing.expect_value(t, len(writer_one.catalog.segments), 1)
			if len(writer_one.catalog.segments) == 1 do testing.expect_value(t, writer_one.catalog.segments[0], expected_descriptor)
			testing.expect_value(t, writer_one.compaction, Shard_Compaction_Status.Building)
			if diagnostic, exact := generated_shard_compare(&models[1], workspaces[1], writer_one.floors); !exact {
				testing.expectf(t, false, "rotation-boundary semantic state differed: %s", diagnostic)
			}
			expected_manifest := writer_one.manifest
			expected_floors := writer_one.catalog_floors
			sim_multi_worker_move_out_of_tls(ctx)

			job_event := ctx.sim.world.events[job_index]
			job, job_ok := job_event.payload.(Sim_Compaction_Job_Event)
			if !testing.expect(t, job_ok, "same-turn compaction event should decode") do return
			testing.expect_value(t, job.job.owner_worker, 1)
			testing.expect_value(t, job.job.manifest, expected_manifest)
			testing.expect_value(t, job.job.expected_source_floors, expected_floors)
			testing.expect_value(t, job.job.source.shard, int(shard_for_workspace(transmute([]byte)workspaces[1])))
			testing.expect_value(t, len(job.job.source.segments), 1)
			if len(job.job.source.segments) == 1 do testing.expect_value(t, job.job.source.segments[0], expected_descriptor)

			second_action: Sim_Multi_Worker_Pre_Tick_Action
			sim_multi_worker_move_into_tls(ctx, 1)
			second_action_id := sim_world_enqueue_driver_action(&ctx.sim.world, &second_action, sim_multi_worker_pre_tick_action)
			sim_multi_worker_move_out_of_tls(ctx)
			second_action_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 1)
			testing.expect(
				t,
				second_action_id != 0 && second_action_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, second_action_index),
				"second pre-tick action should dispatch",
			)
			testing.expect(t, second_action.called && !second_action.did_work, "pending compaction must not issue duplicate work")
			testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), 1)
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim), "below-boundary fsync should complete before teardown")
		}
	}

	@(test)
	test_simulation_two_worker_pre_tick_drains_owner_result_after_peer_storage_progress :: proc(t: ^testing.T) {
		queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			queue, queue_err := pending_queue_create(1)
			if !testing.expect_value(t, queue_err, runtime.Allocator_Error.None) {
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
			pending_connections = pending_queues,
		}
		channel_err: runtime.Allocator_Error
		server.shard_compaction_jobs, channel_err = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 2, context.allocator)
		if !testing.expect_value(t, channel_err, runtime.Allocator_Error.None) do return
		server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), SIM_MULTI_WORKER_COUNT)
		result_queues := 0
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			server.shard_compaction_results[worker_index], channel_err = spsc.create(Shard_Compaction_Result, 1, context.allocator)
			if channel_err != .None do break
			result_queues += 1
		}
		if !testing.expect_value(t, result_queues, SIM_MULTI_WORKER_COUNT) {
			for queue_index in 0 ..< result_queues do spsc.destroy(server.shard_compaction_results[queue_index])
			delete(server.shard_compaction_results)
			_ = chan.destroy(server.shard_compaction_jobs)
			return
		}

		ctx := new(Sim_Multi_Worker_Test_Context)
		sim_multi_worker_test_begin(ctx, &server)
		defer {
			discard_queued_shard_compaction_jobs(&server)
			discard_queued_shard_compaction_results(&server)
			sim_multi_worker_test_end(ctx, nil)
			free(ctx)
			for result_queue in server.shard_compaction_results do spsc.destroy(result_queue)
			delete(server.shard_compaction_results)
			_ = chan.destroy(server.shard_compaction_jobs)
		}

		workspaces := [SIM_MULTI_WORKER_COUNT]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
		writer_zero := sim_multi_worker_init_single_shard_writer(ctx, 0, workspaces[0], "/owner-result-worker-0", true)
		writer_one := sim_multi_worker_init_single_shard_writer(ctx, 1, workspaces[1], "/owner-result-worker-1", true)
		if !testing.expect(t, writer_zero != nil && writer_one != nil, "owner-result workers should initialize") do return

		sim_multi_worker_move_into_tls(ctx, 0)
		if !testing.expect(t, shard_compaction_test_append_task(writer_zero, workspaces[0], 10, "owner-result-sealed-1")) ||
		   !testing.expect(t, rotate_shard_writer_for_compaction(writer_zero)) ||
		   !testing.expect(t, shard_compaction_test_append_task(writer_zero, workspaces[0], 11, "owner-result-sealed-2")) ||
		   !testing.expect(t, rotate_shard_writer_for_compaction(writer_zero)) ||
		   !testing.expect(t, enqueue_shard_compaction_job(&server, writer_zero)) {
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		submitted_floors := writer_zero.catalog_floors
		if !testing.expect(t, shard_compaction_test_append_task(writer_zero, workspaces[0], 12, "owner-result-later")) ||
		   !testing.expect(t, rotate_shard_writer_for_compaction(writer_zero), "later owner rotation should extend the compaction source") {
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		manifest_after_rotation := writer_zero.manifest
		floors_after_rotation := writer_zero.catalog_floors
		if !testing.expect(t, floors_after_rotation != submitted_floors, "later owner rotation should advance source floors") ||
		   !testing.expect(t, len(writer_zero.catalog.segments) > 0, "later owner rotation should publish a catalog descriptor") {
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		later_descriptor := writer_zero.catalog.segments[len(writer_zero.catalog.segments) - 1]
		sim_multi_worker_move_out_of_tls(ctx)

		if !testing.expect(t, service_shard_compaction_job(&server), "compactor should queue worker-zero result") do return
		testing.expect_value(t, chan.len(server.shard_compaction_jobs), 0)
		testing.expect(t, spsc.can_pop(server.shard_compaction_results[0]))
		testing.expect(t, !spsc.can_pop(server.shard_compaction_results[1]))

		peer_model: Generated_Shard_Model
		sim_multi_worker_move_into_tls(ctx, 1)
		if !testing.expect(
			t,
			generated_shard_apply_op(
				&peer_model,
				writer_one,
				transmute([]byte)workspaces[1],
				"/owner-result-worker-1",
				Generated_Shard_Op{kind = .Create_Task},
			),
			"peer transaction should apply",
		) {
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		writer_one.commit_started = {}
		peer_action: Sim_Multi_Worker_Pre_Tick_Action
		peer_action_id := sim_world_enqueue_driver_action(&ctx.sim.world, &peer_action, sim_multi_worker_pre_tick_action)
		sim_multi_worker_move_out_of_tls(ctx)

		sim_multi_worker_move_into_tls(ctx, 0)
		owner_action: Sim_Multi_Worker_Pre_Tick_Action
		owner_action_id := sim_world_enqueue_driver_action(&ctx.sim.world, &owner_action, sim_multi_worker_pre_tick_action)
		sim_multi_worker_move_out_of_tls(ctx)
		if !testing.expect(t, peer_action_id != 0 && owner_action_id != 0, "both worker pre-tick actions should enqueue") do return

		peer_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 1)
		if !testing.expect(t, peer_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, peer_index), "peer pre-tick should run before owner result drain") do return
		testing.expect(t, peer_action.called && peer_action.did_work, "peer pre-tick should submit storage work")
		testing.expect(t, spsc.can_pop(server.shard_compaction_results[0]))
		testing.expect(t, !spsc.can_pop(server.shard_compaction_results[1]))
		peer_fsync_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Fsync, 1)
		if !testing.expect(t, peer_fsync_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, peer_fsync_index), "peer fsync should complete before owner result drain") do return

		sim_multi_worker_move_into_tls(ctx, 1)
		writer_one = &td.shard_writers.writers[0]
		testing.expect_value(t, writer_one.wal.durable_record_count, u64(1))
		peer_manifest := writer_one.manifest
		peer_floors := writer_one.floors
		if diagnostic, exact := generated_shard_compare(&peer_model, workspaces[1], writer_one.floors); !exact {
			testing.expectf(t, false, "peer state changed while owner result waited: %s", diagnostic)
		}
		sim_multi_worker_move_out_of_tls(ctx)
		testing.expect(t, spsc.can_pop(server.shard_compaction_results[0]))
		sim_multi_worker_move_into_tls(ctx, 0)
		writer_zero = &td.shard_writers.writers[0]
		testing.expect_value(t, writer_zero.manifest, manifest_after_rotation)
		testing.expect_value(t, writer_zero.catalog_floors, floors_after_rotation)
		testing.expect(t, semantic_global_segmented_catalog_contains(writer_zero, later_descriptor))
		sim_multi_worker_move_out_of_tls(ctx)

		owner_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Driver_Action, 0)
		if !testing.expect(t, owner_index >= 0 && sim_world_dispatch_event(&ctx.sim.world, owner_index), "owner pre-tick should drain its result") do return
		testing.expect(t, owner_action.called && owner_action.did_work, "owner pre-tick should publish and issue follow-up work")
		testing.expect(t, !spsc.can_pop(server.shard_compaction_results[0]))
		testing.expect(t, !spsc.can_pop(server.shard_compaction_results[1]))

		sim_multi_worker_move_into_tls(ctx, 0)
		writer_zero = &td.shard_writers.writers[0]
		testing.expect(t, writer_zero.manifest.manifest_generation > manifest_after_rotation.manifest_generation)
		testing.expect_value(t, writer_zero.manifest.active_generation, manifest_after_rotation.active_generation)
		testing.expect_value(t, writer_zero.catalog_floors, floors_after_rotation)
		testing.expect(t, semantic_global_segmented_catalog_contains(writer_zero, later_descriptor))
		testing.expect_value(t, writer_zero.compaction, Shard_Compaction_Status.Building)
		owner_manifest := writer_zero.manifest
		owner_source, owner_source_ok := shard_segment_source_for_writer(writer_zero)
		if !testing.expect(t, owner_source_ok && len(owner_source.segments) > 0, "published owner source should remain cleanable") {
			if owner_source_ok do destroy_shard_segment_clean_source(&owner_source)
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		owner_source_segments: [8]Shard_Segment_Descriptor
		if !testing.expect(t, len(owner_source.segments) <= len(owner_source_segments), "published owner source should fit exact oracle") {
			destroy_shard_segment_clean_source(&owner_source)
			sim_multi_worker_move_out_of_tls(ctx)
			return
		}
		owner_source_count := len(owner_source.segments)
		copy(owner_source_segments[:owner_source_count], owner_source.segments[:])
		destroy_shard_segment_clean_source(&owner_source)
		sim_multi_worker_move_out_of_tls(ctx)
		sim_multi_worker_move_into_tls(ctx, 1)
		writer_one = &td.shard_writers.writers[0]
		testing.expect_value(t, writer_one.manifest, peer_manifest)
		testing.expect_value(t, writer_one.floors, peer_floors)
		if diagnostic, exact := generated_shard_compare(&peer_model, workspaces[1], writer_one.floors); !exact {
			testing.expectf(t, false, "owner result publication changed peer state: %s", diagnostic)
		}
		sim_multi_worker_move_out_of_tls(ctx)
		followup_index := sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Job, 0)
		if !testing.expect(t, followup_index >= 0, "owner result should make one same-turn follow-up job eligible") do return
		followup, followup_ok := ctx.sim.world.events[followup_index].payload.(Sim_Compaction_Job_Event)
		testing.expect(
			t,
			followup_ok &&
			followup.job.owner_worker == 0 &&
			followup.job.manifest == owner_manifest &&
			followup.job.expected_source_floors == floors_after_rotation &&
			followup.job.source_present &&
			len(followup.job.source.segments) == owner_source_count,
			"same-turn follow-up should snapshot the exact owner source",
		)
		if followup_ok && len(followup.job.source.segments) == owner_source_count {
			for descriptor, descriptor_index in followup.job.source.segments {
				testing.expect_value(t, descriptor, owner_source_segments[descriptor_index])
			}
		}
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), 1)
		testing.expect_value(t, sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Job, 1), -1)
	}

	sim_multi_worker_compaction_crash_case :: proc(t: ^testing.T, test_case: Sim_Multi_Worker_Compaction_Case) {
		queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			queue, queue_err := pending_queue_create(1)
			if !testing.expect_value(t, queue_err, runtime.Allocator_Error.None) {
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
			pending_connections = pending_queues,
		}

		ctx := new(Sim_Multi_Worker_Test_Context)
		sim_multi_worker_test_begin(ctx, &server)
		defer {
			sim_multi_worker_test_end(ctx, nil)
			free(ctx)
		}
		workspaces := [SIM_MULTI_WORKER_COUNT]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
		shard_dirs := [SIM_MULTI_WORKER_COUNT]string{"/compaction-worker-0", "/compaction-worker-1"}
		models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
		baseline_manifests: [SIM_MULTI_WORKER_COUNT]Shard_Compaction_Manifest
		expected_enter_count := 0

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], true)
			if !testing.expect(t, writer != nil, "compaction worker should initialize its shard") do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			if !testing.expect(
				t,
				generated_shard_apply_op(
					&models[worker_index],
					writer,
					transmute([]byte)workspaces[worker_index],
					shard_dirs[worker_index],
					Generated_Shard_Op{kind = .Create_Task},
				),
				"compaction worker foundation task should apply",
			) {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			if worker_index == 1 &&
			   !testing.expect(
					   t,
					   generated_shard_apply_op(
						   &models[worker_index],
						   writer,
						   transmute([]byte)workspaces[worker_index],
						   shard_dirs[worker_index],
						   Generated_Shard_Op{kind = .Create_Asset},
					   ),
					   "second compaction worker asset should apply",
				   ) {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			testing.expect(t, sync_ok && did_work, "compaction worker foundation should submit fsync")
			sim_multi_worker_move_out_of_tls(ctx)
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if !sim_multi_worker_complete_selected_fsync(t, ctx, worker_index, &expected_enter_count) do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			if !testing.expect(t, writer.wal.durable_record_count == writer.wal.record_count, "compaction foundation should be fully durable") ||
			   !testing.expect(t, rotate_shard_writer_for_compaction(writer), "first compaction rotation should succeed") ||
			   !testing.expect(t, rotate_shard_writer_for_compaction(writer), "second compaction rotation should succeed") ||
			   !testing.expect(t, enqueue_shard_compaction_job_event(&ctx.sim.world, writer), "worker compaction job should enqueue") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			baseline_manifests[worker_index] = writer.manifest
			testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Building)
			sim_multi_worker_move_out_of_tls(ctx)
		}
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), SIM_MULTI_WORKER_COUNT)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Result), 0)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			index := sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Job, worker_index)
			if !testing.expect(t, index >= 0, "worker compaction job should be identifiable") do return
			event := ctx.sim.world.events[index]
			payload, payload_ok := event.payload.(Sim_Compaction_Job_Event)
			testing.expect(t, payload_ok, "worker compaction job payload should decode")
			if !payload_ok do return
			testing.expect_value(t, event.worker_index, worker_index)
			testing.expect_value(t, payload.job.owner_worker, worker_index)
			testing.expect_value(t, payload.job.shard_dir, shard_dirs[worker_index])
		}

		crash_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		if !testing.expect(t, crash_id != 0, "cross-worker compaction crash should enqueue") do return
		published_mask: u8
		for step_index in 0 ..< test_case.step_count {
			step := test_case.steps[step_index]
			trace_before := ctx.event_enter_count
			if step == .Crash {
				rank := sim_multi_worker_runnable_rank_for_event(&ctx.sim.world, crash_id)
				if !testing.expect(t, rank >= 0, "cross-worker compaction crash should be runnable") do return
				incarnation_before := ctx.sim.world.process_incarnation
				if !testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, rank), "cross-worker compaction crash should dispatch") do return
				testing.expect_value(t, ctx.event_enter_count, trace_before)
				testing.expect(t, ctx.sim.world.process_incarnation > incarnation_before)
				continue
			}

			worker_index := (step == .Job_1 || step == .Result_1) ? 1 : 0
			domain := (step == .Job_0 || step == .Job_1) ? Sim_Event_Domain.Compaction_Job : Sim_Event_Domain.Compaction_Result
			index := sim_multi_worker_compaction_event_index(&ctx.sim.world, domain, worker_index)
			if !testing.expect(t, index >= 0, "selected worker compaction event should exist") do return
			if !testing.expect(t, sim_world_dispatch_event(&ctx.sim.world, index), "selected worker compaction event should dispatch") do return
			testing.expect_value(t, ctx.event_enter_count, trace_before + 1)
			testing.expect_value(t, ctx.event_entered_workers[trace_before], worker_index)
			if domain == .Compaction_Result do published_mask |= u8(1) << u8(worker_index)

			for inspect_worker in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, inspect_worker)
				writer := &td.shard_writers.writers[0]
				published := published_mask & (u8(1) << u8(inspect_worker)) != 0
				if published {
					testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Idle)
					testing.expect(t, writer.manifest.manifest_generation > baseline_manifests[inspect_worker].manifest_generation)
					testing.expect(t, writer.manifest.checkpoint_present)
				} else {
					testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Building)
					testing.expect_value(t, writer.manifest, baseline_manifests[inspect_worker])
				}
				sim_multi_worker_move_out_of_tls(ctx)
			}
			testing.expect(t, !sync.atomic_load(&server.closing) && !sync.atomic_load(&server.fatal_storage_error))
		}
		testing.expect_value(t, published_mask, test_case.publication_mask)

		manifests_at_crash: [SIM_MULTI_WORKER_COUNT]Shard_Compaction_Manifest
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			manifests_at_crash[worker_index] = td.shard_writers.writers[0].manifest
			sim_multi_worker_move_out_of_tls(ctx)
			if !testing.expect(t, sim_multi_worker_discard_process_writer(ctx, worker_index), "crashed compaction writer should discard") do return
		}

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			cleanup_workspaces()
			td.workspaces = make(map[string]^Workspace_State, 8)
			td.task_seq = 0
			td.asset_seq = 0
			td.edge_seq = 0
			sim_multi_worker_move_out_of_tls(ctx)
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], false)
			if !testing.expect(t, writer != nil, "compaction worker should reopen after crash") do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			testing.expect(t, replay_ok, "compaction worker should replay after crash")
			testing.expect_value(t, floors, writer.floors)
			td.task_seq = floors.task
			td.asset_seq = floors.asset
			td.edge_seq = floors.edge
			diagnostic, exact := generated_shard_compare(&models[worker_index], workspaces[worker_index], floors)
			testing.expectf(t, exact, "compaction worker %d recovery differs: %s", worker_index, diagnostic)
			testing.expect_value(t, writer.manifest.manifest_generation, manifests_at_crash[worker_index].manifest_generation)
			shard := int(shard_for_workspace(transmute([]byte)workspaces[worker_index]))
			testing.expect_value(t, td.shard_writers.writer_index[shard], 0)
			testing.expect_value(t, len(td.shard_writers.writers), 1)
			testing.expect(t, get_workspace(workspaces[1 - worker_index]) == nil)
			sim_multi_worker_move_out_of_tls(ctx)
		}

		for len(ctx.sim.world.events) > 0 {
			index := sim_world_runnable_rank_index(&ctx.sim.world, 0)
			if !testing.expect(t, index >= 0, "stale compaction event should be runnable") do return
			event := ctx.sim.world.events[index]
			testing.expect(t, event.process_incarnation < ctx.sim.world.process_incarnation, "queued compaction work should belong to the crashed incarnation")
			testing.expect(t, event.domain == .Compaction_Job || event.domain == .Compaction_Result, "only stale compaction work should remain")
			owner := event.worker_index
			trace_before := ctx.event_enter_count
			if !testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "stale compaction event should drain") do return
			testing.expect_value(t, ctx.event_enter_count, trace_before + 1)
			testing.expect_value(t, ctx.event_entered_workers[trace_before], owner)
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, worker_index)
				writer := &td.shard_writers.writers[0]
				testing.expect_value(t, writer.manifest, manifests_at_crash[worker_index])
				diagnostic, exact := generated_shard_compare(&models[worker_index], workspaces[worker_index], writer.floors)
				testing.expectf(t, exact, "stale event changed compaction worker %d: %s", worker_index, diagnostic)
				sim_multi_worker_move_out_of_tls(ctx)
			}
			testing.expect(t, !sync.atomic_load(&server.closing) && !sync.atomic_load(&server.fatal_storage_error))
		}
		testing.expect_value(t, len(ctx.sim.world.events), 0)

		expected_enter_count = ctx.event_enter_count
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			if !testing.expect(
				t,
				generated_shard_apply_op(
					&models[worker_index],
					writer,
					transmute([]byte)workspaces[worker_index],
					shard_dirs[worker_index],
					Generated_Shard_Op{kind = .Create_Task},
				),
				"recovered compaction worker continuation should apply",
			) {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			testing.expect(t, sync_ok && did_work, "recovered compaction worker should submit continuation fsync")
			sim_multi_worker_move_out_of_tls(ctx)
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if !sim_multi_worker_complete_selected_fsync(t, ctx, worker_index, &expected_enter_count) do return
		}

		continuation_manifests: [SIM_MULTI_WORKER_COUNT]Shard_Compaction_Manifest
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			testing.expect(t, writer.wal.durable_record_count == writer.wal.record_count, "continuation should be fully durable")
			if !testing.expect(t, rotate_shard_writer_for_compaction(writer), "recovered compaction worker should rotate its continuation") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			continuation_manifests[worker_index] = writer.manifest
			diagnostic, exact := generated_shard_compare(&models[worker_index], workspaces[worker_index], writer.floors)
			testing.expectf(t, exact, "rotated continuation differs for compaction worker %d: %s", worker_index, diagnostic)
			sim_multi_worker_move_out_of_tls(ctx)
		}

		trace_before_second_crash := ctx.event_enter_count
		second_crash_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		second_crash_rank := sim_multi_worker_runnable_rank_for_event(&ctx.sim.world, second_crash_id)
		second_incarnation_before := ctx.sim.world.process_incarnation
		if !testing.expect(t, second_crash_rank >= 0, "second compaction crash should be runnable") ||
		   !testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, second_crash_rank), "second compaction crash should dispatch") {
			return
		}
		testing.expect_value(t, ctx.event_enter_count, trace_before_second_crash)
		testing.expect(t, ctx.sim.world.process_incarnation > second_incarnation_before, "second compaction crash should advance process incarnation")

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if !testing.expect(t, sim_multi_worker_discard_process_writer(ctx, worker_index), "second crashed compaction writer should discard") do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			cleanup_workspaces()
			td.workspaces = make(map[string]^Workspace_State, 8)
			td.task_seq = 0
			td.asset_seq = 0
			td.edge_seq = 0
			sim_multi_worker_move_out_of_tls(ctx)
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], false)
			if !testing.expect(t, writer != nil, "compaction worker should reopen after second crash") do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			testing.expect(t, replay_ok, "compaction worker should replay after second crash")
			testing.expect_value(t, floors, writer.floors)
			td.task_seq = floors.task
			td.asset_seq = floors.asset
			td.edge_seq = floors.edge
			diagnostic, exact := generated_shard_compare(&models[worker_index], workspaces[worker_index], floors)
			testing.expectf(t, exact, "compaction worker %d second recovery differs: %s", worker_index, diagnostic)
			testing.expect_value(t, writer.manifest, continuation_manifests[worker_index])
			sim_multi_worker_move_out_of_tls(ctx)
		}
		testing.expect(t, !sync.atomic_load(&server.closing) && !sync.atomic_load(&server.fatal_storage_error))
		testing.expect_value(t, len(ctx.sim.world.events), 0)
	}

	sim_multi_worker_compaction_issuance_case :: proc(t: ^testing.T, test_case: Sim_Multi_Worker_Compaction_Issuance_Case) {
		queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			queue, queue_err := pending_queue_create(1)
			if !testing.expect_value(t, queue_err, runtime.Allocator_Error.None) {
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
			pending_connections = pending_queues,
		}

		ctx := new(Sim_Multi_Worker_Test_Context)
		sim_multi_worker_test_begin(ctx, &server)
		socks: [SIM_MULTI_WORKER_COUNT]net.TCP_Socket
		defer {
			sim_multi_worker_test_end(ctx, socks[:])
			free(ctx)
		}
		workspaces := [SIM_MULTI_WORKER_COUNT]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
		shard_dirs := [SIM_MULTI_WORKER_COUNT]string{"/issuance-worker-0", "/issuance-worker-1"}
		models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
		connections: [SIM_MULTI_WORKER_COUNT]^NRC_Connection
		connection_handles: [SIM_MULTI_WORKER_COUNT]Connection_Handle
		quiescence_baselines: [SIM_MULTI_WORKER_COUNT]Sim_Quiescence_Baseline
		post_teardown_baselines: [SIM_MULTI_WORKER_COUNT]Sim_Quiescence_Baseline
		actions: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_Compaction_Issuance_Action
		action_event_ids: [SIM_MULTI_WORKER_COUNT]u64
		rotation_actions: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_Compaction_Rotation_Action
		rotation_event_ids: [SIM_MULTI_WORKER_COUNT]u64
		expected_manifests: [SIM_MULTI_WORKER_COUNT]Shard_Compaction_Manifest
		expected_enter_count := 0

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], true)
			if !testing.expect(t, writer != nil, "issuance worker should initialize its shard") do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			if !testing.expect(
				t,
				generated_shard_apply_op(
					&models[worker_index],
					writer,
					transmute([]byte)workspaces[worker_index],
					shard_dirs[worker_index],
					Generated_Shard_Op{kind = .Create_Task},
				),
				"issuance foundation task should apply",
			) {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !testing.expect(t, sync_ok && did_work, "issuance foundation should submit fsync") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			sim_multi_worker_move_out_of_tls(ctx)
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if !sim_multi_worker_complete_selected_fsync(t, ctx, worker_index, &expected_enter_count) do return
		}

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			if !testing.expect(t, rotate_shard_writer_for_compaction(writer), "issuance worker should establish a cleanable catalog") ||
			   !testing.expect(t, shard_writer_catalog_cleaning_ready(writer), "issuance worker catalog should be eligible") ||
			   !testing.expect(
					   t,
					   generated_shard_apply_op(
						   &models[worker_index],
						   writer,
						   transmute([]byte)workspaces[worker_index],
						   shard_dirs[worker_index],
						   Generated_Shard_Op{kind = .Create_Task},
					   ),
					   "issuance worker active-WAL task should apply",
				   ) {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !testing.expect(t, sync_ok && did_work, "issuance worker active WAL should submit fsync") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}

			conn := simulation_test_install_client(&ctx.sim, 560 + worker_index, workspaces[worker_index], "issuance-owner", init_send_queue = true)
			if !testing.expect(t, conn != nil, "issuance worker transport should initialize") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			connections[worker_index] = conn
			connection_handles[worker_index] = conn.handle
			socks[worker_index] = conn.sock
			quiescence_baselines[worker_index] = sim_worker_quiescence_baseline()
			pong_payload := [3]byte{byte(worker_index), 0x56, 0x00}
			pong_frame := make_test_ws_frame(pong_payload[:], .opPong, true)
			if !testing.expect(t, len(pong_frame) > 2, "issuance worker Pong frame should serialize") ||
			   !testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, pong_frame[:2]), "issuance worker Pong prefix should enqueue") ||
			   !testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, pong_frame[2:]), "issuance worker Pong suffix should enqueue") {
				delete(pong_frame)
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			delete(pong_frame)

			source, source_ok := shard_segment_source_for_writer(writer)
			if !testing.expect(
				t,
				source_ok && len(source.segments) > 0 && len(source.segments) <= len(actions[worker_index].expected_segments),
				"issuance worker source should fit exact oracle",
			) {
				if source_ok do destroy_shard_segment_clean_source(&source)
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			actions[worker_index] = {
				world             = &ctx.sim.world,
				worker_index      = worker_index,
				expected_manifest = writer.manifest,
				expected_count    = len(source.segments),
			}
			copy(actions[worker_index].expected_segments[:len(source.segments)], source.segments[:])
			destroy_shard_segment_clean_source(&source)
			expected_manifests[worker_index] = writer.manifest
			action_event_ids[worker_index] = sim_world_enqueue_driver_action(
				&ctx.sim.world,
				&actions[worker_index],
				sim_multi_worker_compaction_issuance_action,
			)
			if !testing.expect(t, action_event_ids[worker_index] != 0, "worker-owned compaction issuance should enqueue") {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			has_rotation := false
			for step_index in 0 ..< test_case.step_count {
				step := test_case.steps[step_index]
				if (worker_index == 0 && step == .Rotate_0) || (worker_index == 1 && step == .Rotate_1) {
					has_rotation = true
					break
				}
			}
			if has_rotation {
				fsync_index := sim_multi_worker_owned_event_index(&ctx.sim.world, .Fsync, worker_index)
				if !testing.expect(t, fsync_index >= 0, "rotation dependency fsync should exist") {
					sim_multi_worker_move_out_of_tls(ctx)
					return
				}
				rotation_actions[worker_index].worker_index = worker_index
				rotation_event_ids[worker_index] = sim_world_enqueue_driver_action(
					&ctx.sim.world,
					&rotation_actions[worker_index],
					sim_multi_worker_compaction_rotation_action,
					ctx.sim.world.events[fsync_index].id,
				)
				if !testing.expect(t, rotation_event_ids[worker_index] != 0, "owner-local later rotation should enqueue") {
					sim_multi_worker_move_out_of_tls(ctx)
					return
				}
			}
			sim_multi_worker_move_out_of_tls(ctx)
		}

		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Fsync), SIM_MULTI_WORKER_COUNT)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Receive), 2 * SIM_MULTI_WORKER_COUNT)
		expected_driver_actions := SIM_MULTI_WORKER_COUNT
		for id in rotation_event_ids do if id != 0 do expected_driver_actions += 1
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Driver_Action), expected_driver_actions)
		crash_event_id := sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
		if !testing.expect(t, crash_event_id != 0, "issuance process crash should enqueue") do return
		issued_mask: u8
		jobs_dispatched_mask: u8
		publication_mask: u8
		receive_counts: [SIM_MULTI_WORKER_COUNT]int
		for step_index in 0 ..< test_case.step_count {
			step := test_case.steps[step_index]
			worker_index := 0
			domain := Sim_Event_Domain.Fsync
			event_id: u64
			switch step {
			case .Fsync_0, .Fsync_1:
				worker_index = step == .Fsync_1 ? 1 : 0
				domain = .Fsync
			case .Receive_0, .Receive_1:
				worker_index = step == .Receive_1 ? 1 : 0
				domain = .Receive
			case .Issue_0, .Issue_1:
				worker_index = step == .Issue_1 ? 1 : 0
				domain = .Driver_Action
				event_id = action_event_ids[worker_index]
			case .Job_0, .Job_1:
				worker_index = step == .Job_1 ? 1 : 0
				domain = .Compaction_Job
				event_id = actions[worker_index].job_event_id
			case .Result_0, .Result_1:
				worker_index = step == .Result_1 ? 1 : 0
				domain = .Compaction_Result
			case .Rotate_0, .Rotate_1:
				worker_index = step == .Rotate_1 ? 1 : 0
				domain = .Driver_Action
				event_id = rotation_event_ids[worker_index]
			case .Crash:
				domain = .Process_Crash
				event_id = crash_event_id
			}
			if event_id == 0 {
				index := sim_multi_worker_owned_event_index(&ctx.sim.world, domain, worker_index)
				if !testing.expect(t, index >= 0, "selected issuance event should exist") do return
				event_id = ctx.sim.world.events[index].id
			}
			rank := sim_multi_worker_runnable_rank_for_event(&ctx.sim.world, event_id)
			if !testing.expect(t, rank >= 0, "selected issuance event should be runnable") do return
			result_rebase_required := false
			manifest_before_result: Shard_Compaction_Manifest
			peer_manifest_before_result: Shard_Compaction_Manifest
			peer_catalog_before_result: [8]Shard_Segment_Descriptor
			peer_catalog_count := 0
			if domain == .Compaction_Result {
				result_index := sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Result, worker_index)
				if !testing.expect(t, result_index >= 0, "selected compaction result should exist") do return
				result_event, result_ok := ctx.sim.world.events[result_index].payload.(Sim_Compaction_Result_Event)
				if !testing.expect(t, result_ok, "selected compaction result payload should decode") do return
				result_rebase_required = rotation_actions[worker_index].rotated
				if result_rebase_required {
					segments := &result_event.result.segments
					if !testing.expect(
						t,
						segments.removed_count > 0 &&
						segments.removed_count == len(segments.removed) &&
						segments.removed_start >= 0 &&
						segments.removed_start + segments.removed_count <= actions[worker_index].expected_count,
						"delayed compaction result should replace a real source prefix",
					) {
						return
					}
					for removed, removed_index in segments.removed {
						if !testing.expect_value(t, removed, actions[worker_index].expected_segments[segments.removed_start + removed_index]) {
							return
						}
					}
				}
				sim_multi_worker_move_into_tls(ctx, worker_index)
				manifest_before_result = td.shard_writers.writers[0].manifest
				sim_multi_worker_move_out_of_tls(ctx)
				peer_index := 1 - worker_index
				sim_multi_worker_move_into_tls(ctx, peer_index)
				peer := &td.shard_writers.writers[0]
				peer_manifest_before_result = peer.manifest
				peer_catalog_count = len(peer.catalog.segments)
				if !testing.expect(t, peer_catalog_count <= len(peer_catalog_before_result), "peer catalog should fit non-interference oracle") {
					sim_multi_worker_move_out_of_tls(ctx)
					return
				}
				copy(peer_catalog_before_result[:peer_catalog_count], peer.catalog.segments[:])
				sim_multi_worker_move_out_of_tls(ctx)
			}
			trace_before := ctx.event_enter_count
			incarnation_before := ctx.sim.world.process_incarnation
			if !testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, rank), "selected issuance event should dispatch") do return
			if step == .Crash {
				testing.expect_value(t, ctx.event_enter_count, trace_before)
				testing.expect(t, ctx.sim.world.process_incarnation > incarnation_before)
				continue
			}
			testing.expect_value(t, ctx.event_enter_count, trace_before + 1)
			testing.expect_value(t, ctx.event_entered_workers[trace_before], worker_index)
			if domain == .Receive {
				receive_counts[worker_index] += 1
				if receive_counts[worker_index] == 2 {
					sim_multi_worker_move_into_tls(ctx, worker_index)
					conn := connections[worker_index]
					testing.expect_value(t, conn.state, Connection_State.Idle)
					testing.expect(t, conn.receive_accumulator.buf == nil && conn.receive_accumulator.used == 0 && conn.receive_accumulator.target == 0)
					testing.expect(t, conn.fragment_buf == nil && conn.fragment_len == 0)
					testing.expect_value(t, conn.pending_io, u32(0))
					testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Send), 0)
					testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
					sim_multi_worker_move_out_of_tls(ctx)
				}
			}
			if event_id == action_event_ids[worker_index] {
				action := &actions[worker_index]
				testing.expect(
					t,
					action.called && action.source_exact && sim_multi_worker_compaction_issuance_job_exact(action),
					"worker compaction issuance should snapshot its exact owner source",
				)
				issued_mask |= u8(1) << u8(worker_index)
			} else if event_id == rotation_event_ids[worker_index] {
				action := &rotation_actions[worker_index]
				testing.expect(t, action.called && action.rotated, "owner-local later rotation should publish its catalog")
				expected_manifests[worker_index] = action.manifest
			} else if domain == .Compaction_Job {
				jobs_dispatched_mask |= u8(1) << u8(worker_index)
				testing.expect(
					t,
					sim_multi_worker_compaction_event_index(&ctx.sim.world, .Compaction_Result, worker_index) >= 0,
					"cleaner job should return an owner result",
				)
			} else if domain == .Compaction_Result {
				publication_mask |= u8(1) << u8(worker_index)
				sim_multi_worker_move_into_tls(ctx, worker_index)
				writer := &td.shard_writers.writers[0]
				expected_manifests[worker_index] = writer.manifest
				if result_rebase_required {
					testing.expect_value(t, writer.compaction, Shard_Compaction_Status.Idle)
					testing.expect(t, writer.manifest.manifest_generation > manifest_before_result.manifest_generation)
					testing.expect_value(t, writer.manifest.active_generation, manifest_before_result.active_generation)
					testing.expect(
						t,
						semantic_global_segmented_catalog_contains(writer, rotation_actions[worker_index].later_descriptor),
						"rebased result should preserve the owner's later descriptor",
					)
				}
				sim_multi_worker_move_out_of_tls(ctx)
				peer_index := 1 - worker_index
				sim_multi_worker_move_into_tls(ctx, peer_index)
				peer := &td.shard_writers.writers[0]
				testing.expect_value(t, peer.manifest, peer_manifest_before_result)
				testing.expect_value(t, len(peer.catalog.segments), peer_catalog_count)
				for descriptor, descriptor_index in peer.catalog.segments {
					testing.expect_value(t, descriptor, peer_catalog_before_result[descriptor_index])
				}
				sim_multi_worker_move_out_of_tls(ctx)
			}
			for action_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				if actions[action_index].issued && jobs_dispatched_mask & (u8(1) << u8(action_index)) == 0 {
					testing.expect(
						t,
						sim_multi_worker_compaction_issuance_job_exact(&actions[action_index]),
						"peer progress changed an issued compaction source snapshot",
					)
				}
			}
			for inspect_worker in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, inspect_worker)
				testing.expect_value(t, td.shard_writers.writers[0].manifest, expected_manifests[inspect_worker])
				sim_multi_worker_move_out_of_tls(ctx)
			}
		}
		testing.expect_value(t, issued_mask, test_case.issuance_mask)
		testing.expect_value(t, publication_mask, test_case.publication_mask)

		events_before_drain := len(ctx.sim.world.events)
		if test_case.recover {
			if !testing.expect(t, events_before_drain > 0, "recovering issuance schedule should retain stale work") do return
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, worker_index)
				reason := sim_worker_transport_quiescence_reason(connection_handles[worker_index:worker_index + 1], quiescence_baselines[worker_index])
				pending_transport := connections[worker_index].pending_io
				sim_multi_worker_move_out_of_tls(ctx)
				if !testing.expect(t, pending_transport > 0, "recovering issuance worker should retain transport ownership") ||
				   !testing.expect_value(t, reason, "connection I/O ownership remains") {
					return
				}
			}
		}
		drained, drain_result := sim_world_drain_bounded(&ctx.sim.world, 64)
		if test_case.recover && !testing.expect(t, drained > 0, "recovering issuance schedule should drain stale work") do return
		if !testing.expect_value(t, drain_result, Sim_Quiescence_Drain_Result.Reached) do return
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			expected_called := test_case.issuance_mask & (u8(1) << u8(worker_index)) != 0
			testing.expect_value(t, actions[worker_index].called, expected_called)
			testing.expect_value(t, actions[worker_index].issued, expected_called)
			sim_multi_worker_move_into_tls(ctx, worker_index)
			testing.expect_value(t, td.shard_writers.writers[0].manifest, expected_manifests[worker_index])
			if test_case.recover {
				quiescence_reason := sim_worker_transport_quiescence_reason(
					connection_handles[worker_index:worker_index + 1],
					quiescence_baselines[worker_index],
				)
				if !testing.expectf(t, quiescence_reason == "", "issuance worker %d transport did not quiesce: %s", worker_index, quiescence_reason) {
					sim_multi_worker_move_out_of_tls(ctx)
					return
				}
				simulation_test_uninstall_client(connections[worker_index])
				connections[worker_index] = nil
				post_teardown_baselines[worker_index] = sim_worker_quiescence_baseline()
			}
			sim_multi_worker_move_out_of_tls(ctx)
			if !testing.expect(t, sim_multi_worker_discard_process_writer(ctx, worker_index), "issuance worker should discard after crash") do return
		}
		testing.expect(t, !sync.atomic_load(&server.closing) && !sync.atomic_load(&server.fatal_storage_error))
		testing.expect_value(t, len(ctx.sim.world.events), 0)

		if test_case.recover {
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, worker_index)
				cleanup_workspaces()
				td.workspaces = make(map[string]^Workspace_State, 8)
				td.task_seq = 0
				td.asset_seq = 0
				td.edge_seq = 0
				sim_multi_worker_move_out_of_tls(ctx)
				writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], false)
				if !testing.expect(t, writer != nil, "issuance worker should reopen after publication crash") do return
				sim_multi_worker_move_into_tls(ctx, worker_index)
				floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
				testing.expect(t, replay_ok, "issuance worker should replay after publication crash")
				testing.expect_value(t, floors, writer.floors)
				td.task_seq = floors.task
				td.asset_seq = floors.asset
				td.edge_seq = floors.edge
				diagnostic, exact := generated_shard_compare(&models[worker_index], workspaces[worker_index], floors)
				testing.expectf(t, exact, "issuance worker %d recovery differs: %s", worker_index, diagnostic)
				testing.expect_value(t, writer.manifest, expected_manifests[worker_index])
				if rotation_actions[worker_index].rotated {
					testing.expect(
						t,
						semantic_global_segmented_catalog_contains(writer, rotation_actions[worker_index].later_descriptor),
						"recovered rebased catalog should retain the later descriptor",
					)
				}
				quiescence_reason := sim_worker_quiescence_reason(nil, post_teardown_baselines[worker_index])
				testing.expectf(t, quiescence_reason == "", "issuance worker %d did not quiesce: %s", worker_index, quiescence_reason)
				sim_multi_worker_move_out_of_tls(ctx)
			}
		}
	}

	sim_multi_worker_prepare_websocket_update :: proc(model: ^Generated_Shard_Model, worker_index: int) -> pr.UpdateTaskRequest {
		id := u64(1)
		assert(model.tasks[id].live, "generated WebSocket update requires task 1")
		next := model.tasks[id]
		model_sequence := model.task_mutation_sequence + 1
		next.status = .Todo
		next.updated_at = NRC_SIM_TIME_EPOCH_NANOS
		next.completed_at = 0
		next.update_variant = next.update_variant == 1 ? 2 : 1
		attachments: [1]pr.Attachment
		expected := generated_shard_task_snapshot(next, id, &attachments)
		model.tasks[id] = next
		model.task_mutation_sequence = model_sequence
		return pr.UpdateTaskRequest {
			conv_id = GENERATED_SHARD_CONV,
			task_id = pr.TaskID(id),
			title = expected.title,
			description = expected.description,
			status = expected.status,
			assignee = expected.assignee,
			priority = expected.priority,
			color = expected.color,
			external_ref = expected.external_ref,
			due_at = expected.due_at,
			preserve_attachments = true,
			project = expected.project,
			correlation_id = 0xE200 + u32(worker_index),
		}
	}

	sim_multi_worker_serialize_websocket_asset_create :: proc(model: ^Generated_Shard_Model, worker_index: int, buf: []byte) -> int {
		id := model.asset_high + 1
		assert(id < GENERATED_SHARD_MAX_ENTITIES, "generated WebSocket asset exceeds model capacity")
		assert(model.tasks[1].live, "generated WebSocket asset requires task 1")
		state := Generated_Shard_Model_Asset {
			live        = true,
			asset_type  = id & 1 == 1 ? .Note : .Document,
			parent_type = .Task,
			parent_id   = 1,
			created_at  = NRC_SIM_TIME_EPOCH_NANOS,
			updated_at  = NRC_SIM_TIME_EPOCH_NANOS,
		}
		// One worker exercises explicit containers over the fragmented wire;
		// the other retains note/document coverage in the same schedule.
		if worker_index == 1 {
			state.asset_type = .Slice
			state.parent_type = .None
			state.parent_id = 0
		}
		attachments: [1]pr.Attachment
		expected := generated_shard_asset_snapshot(state, id, &attachments)
		request_len := pr.serializeCreateAssetRequest(
			pr.CreateAssetRequest {
				conv_id = expected.conv_id,
				asset_type = expected.asset_type,
				parent_type = expected.parent_type,
				parent_id = expected.parent_id,
				payload_encoding = expected.payload_encoding,
				payload_raw_len = expected.payload_raw_len,
				preview = expected.preview,
				payload = expected.payload,
				attachments = expected.attachments,
				correlation_id = 0xE200 + u32(worker_index),
			},
			buf,
		)
		if request_len > 0 {
			model.asset_high = id
			model.assets[id] = state
		}
		return request_len
	}

	sim_multi_worker_serialize_websocket_edge_create :: proc(model: ^Generated_Shard_Model, worker_index: int, buf: []byte, target_asset_id: u64 = 0) -> int {
		id := model.edge_high + 1
		assert(id < GENERATED_SHARD_MAX_ENTITIES, "generated WebSocket edge exceeds model capacity")
		assert(model.tasks[1].live, "generated WebSocket edge requires task 1")
		asset_id := target_asset_id
		if asset_id == 0 {
			for candidate in 1 ..< GENERATED_SHARD_MAX_ENTITIES do if model.assets[candidate].live {asset_id = u64(candidate); break}
		}
		assert(asset_id != 0, "generated WebSocket edge requires an asset")
		assert(model.assets[asset_id].live, "generated WebSocket edge target must be live")
		state := Generated_Shard_Model_Edge {
			live        = true,
			source_type = .Task,
			source_id   = 1,
			target_type = .Asset,
			target_id   = asset_id,
			relation    = .References,
			created_at  = NRC_SIM_TIME_EPOCH_NANOS,
			created_by  = "generated-owner",
		}
		if model.assets[asset_id].asset_type == .Slice {
			state.relation = .MemberOf
			// Repeated edge operations still need an accepted write; the
			// duplicate rejection itself is covered by the real-server test.
			for edge in model.edges {
				if !edge.live || edge.relation != .MemberOf do continue
				same := edge.source_type == .Task && edge.source_id == 1 && edge.target_type == .Asset && edge.target_id == asset_id
				reverse := edge.target_type == .Task && edge.target_id == 1 && edge.source_type == .Asset && edge.source_id == asset_id
				if same || reverse do state.relation = .References
			}
		}
		request_len := pr.serializeCreateEdgeRequest(
			pr.CreateEdgeRequest {
				conv_id = GENERATED_SHARD_CONV,
				source_type = state.source_type,
				source_id = state.source_id,
				target_type = state.target_type,
				target_id = state.target_id,
				relation = state.relation,
				correlation_id = 0xE200 + u32(worker_index),
			},
			buf,
		)
		if request_len > 0 {
			model.edge_high = id
			model.edges[id] = state
		}
		return request_len
	}

	sim_multi_worker_history_mutation :: proc(kind: Sim_Multi_Worker_WebSocket_Mutation, mutation_index: int) -> Sim_Multi_Worker_WebSocket_Mutation {
		if kind != .Create_Asset_Edge do return kind
		return mutation_index == 0 ? .Create_Asset : .Create_Edge
	}

	sim_multi_worker_generated_campaign_begin :: proc(
		campaign: ^Sim_Multi_Worker_Generated_Campaign,
		semantic_ops: ^[SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op,
		semantic_op_counts: [SIM_MULTI_WORKER_COUNT]int,
		second_epoch_mutations: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation,
		intermediate_durable: [SIM_MULTI_WORKER_COUNT]bool,
		fsync_error_attempts: [SIM_MULTI_WORKER_COUNT]int,
	) -> string {
		campaign^ = {
			workspaces             = {sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)},
			shard_dirs             = {"/generated-worker-0-shard", "/generated-worker-1-shard"},
			second_epoch_mutations = second_epoch_mutations,
			intermediate_durable   = intermediate_durable,
			fsync_error_attempts   = fsync_error_attempts,
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if second_epoch_mutations[worker_index] != .Create_Asset_Edge {
				campaign.intermediate_durable[worker_index] = false
			}
			queue, queue_err := pending_queue_create(1)
			if queue_err != .None do return "generated two-worker pending queue initialization failed"
			campaign.queues[worker_index] = queue
			campaign.queue_count += 1
		}
		campaign.pending_queues = make([]Pending_Connection_Queue, SIM_MULTI_WORKER_COUNT)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do campaign.pending_queues[worker_index] = campaign.queues[worker_index]
		campaign.server.pending_connections = campaign.pending_queues
		campaign.ctx = new(Sim_Multi_Worker_Test_Context)
		if campaign.ctx == nil do return "generated two-worker context allocation failed"
		sim_multi_worker_test_begin(campaign.ctx, &campaign.server)
		campaign.started = true

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			assert(semantic_op_counts[worker_index] >= 1 && semantic_op_counts[worker_index] <= 3)
			writer := sim_multi_worker_init_single_shard_writer(
				campaign.ctx,
				worker_index,
				campaign.workspaces[worker_index],
				campaign.shard_dirs[worker_index],
				true,
			)
			if writer == nil do return "generated two-worker shard initialization failed"
			sim_multi_worker_move_into_tls(campaign.ctx, worker_index)
			for op_index in 0 ..< semantic_op_counts[worker_index] {
				if !generated_shard_apply_op(
					&campaign.models[worker_index],
					writer,
					transmute([]byte)campaign.workspaces[worker_index],
					campaign.shard_dirs[worker_index],
					semantic_ops[worker_index][op_index],
				) {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker semantic operation failed"
				}
				if _, exact := generated_shard_compare(&campaign.models[worker_index], campaign.workspaces[worker_index], writer.floors); !exact {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker live semantic model differs"
				}
			}
			if second_epoch_mutations[worker_index] == .Create_Edge && generated_shard_live_asset_count(&campaign.models[worker_index]) == 0 {
				if !generated_shard_apply_op(
					&campaign.models[worker_index],
					writer,
					transmute([]byte)campaign.workspaces[worker_index],
					campaign.shard_dirs[worker_index],
					Generated_Shard_Op{kind = .Create_Asset},
				) {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker edge prerequisite failed"
				}
				if _, exact := generated_shard_compare(&campaign.models[worker_index], campaign.workspaces[worker_index], writer.floors); !exact {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker edge prerequisite model differs"
				}
			}
			campaign.first_epoch_models[worker_index] = campaign.models[worker_index]
			campaign.first_epoch_records[worker_index] = writer.wal.record_count + writer.wal.buffered_record_count
			td.task_seq = writer.floors.task
			td.asset_seq = writer.floors.asset
			td.edge_seq = writer.floors.edge
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work {
				sim_multi_worker_move_out_of_tls(campaign.ctx)
				return "generated two-worker first epoch fsync submission failed"
			}
			campaign.mutation_counts[worker_index] = second_epoch_mutations[worker_index] == .Create_Asset_Edge ? 2 : 1
			campaign.record_counts[worker_index] = campaign.first_epoch_records[worker_index] + u64(campaign.mutation_counts[worker_index])
			campaign.connections[worker_index] = simulation_test_install_client(
				&campaign.ctx.sim,
				470 + worker_index,
				campaign.workspaces[worker_index],
				"generated-owner",
				init_send_queue = true,
			)
			conn := campaign.connections[worker_index]
			if conn == nil {
				sim_multi_worker_move_out_of_tls(campaign.ctx)
				return "generated two-worker transport installation failed"
			}
			for mutation_index in 0 ..< campaign.mutation_counts[worker_index] {
				if campaign.intermediate_durable[worker_index] && mutation_index == 1 {
					continue
				}
				request_buf: [4_096]byte
				request_len := 0
				mutation := sim_multi_worker_history_mutation(second_epoch_mutations[worker_index], mutation_index)
				switch mutation {
				case .Update_Task:
					update_req := sim_multi_worker_prepare_websocket_update(&campaign.models[worker_index], worker_index)
					request_len = pr.serializeUpdateTaskRequest(update_req, request_buf[:])
				case .Delete_Task:
					generated_shard_model_delete_task(&campaign.models[worker_index], 1)
					request_len = pr.serializeDeleteTaskRequest(GENERATED_SHARD_CONV, 1, request_buf[:], 0xE200 + u32(worker_index))
				case .Create_Asset:
					request_len = sim_multi_worker_serialize_websocket_asset_create(&campaign.models[worker_index], worker_index, request_buf[:])
				case .Create_Edge:
					target_asset_id: u64
					if second_epoch_mutations[worker_index] == .Create_Asset_Edge {
						target_asset_id = campaign.intermediate_models[worker_index].asset_high
					}
					request_len = sim_multi_worker_serialize_websocket_edge_create(
						&campaign.models[worker_index],
						worker_index,
						request_buf[:],
						target_asset_id,
					)
				case .Create_Asset_Edge:
					unreachable()
				}
				if request_len <= 0 {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker mutation serialization failed"
				}
				if second_epoch_mutations[worker_index] == .Create_Asset_Edge &&
				   mutation == .Create_Edge &&
				   campaign.models[worker_index].edges[campaign.models[worker_index].edge_high].target_id !=
					   campaign.intermediate_models[worker_index].asset_high {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker dependent edge targeted the wrong asset"
				}
				if mutation_index == 0 && campaign.mutation_counts[worker_index] == 2 {
					campaign.intermediate_models[worker_index] = campaign.models[worker_index]
					campaign.intermediate_records[worker_index] = campaign.first_epoch_records[worker_index] + 1
				}
				frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
				defer delete(frame)
				split := (worker_index + mutation_index) & 1 == 0 ? 3 : len(frame) - 2
				if !nrc_sim_enqueue_receive(&campaign.ctx.sim, conn, frame[:split]) || !nrc_sim_enqueue_receive(&campaign.ctx.sim, conn, frame[split:]) {
					sim_multi_worker_move_out_of_tls(campaign.ctx)
					return "generated two-worker receive enqueue failed"
				}
				campaign.enqueued_mutation_counts[worker_index] += 1
				if mutation_index == 1 do campaign.dependent_edge_enqueued[worker_index] = true
			}
			campaign.pool_live_before[worker_index] = connection_lifetime_pool_live_alloc_count(td.spool)
			campaign.invalid_releases_before[worker_index] = td.spool.invalid_release_count
			sim_multi_worker_move_out_of_tls(campaign.ctx)
		}
		expected_receive_events := 0
		for count in campaign.enqueued_mutation_counts do expected_receive_events += 2 * count
		if sim_world_event_count(&campaign.ctx.sim.world, .Fsync) != SIM_MULTI_WORKER_COUNT ||
		   sim_world_event_count(&campaign.ctx.sim.world, .Receive) != expected_receive_events {
			return "generated two-worker initial event set differs"
		}
		return ""
	}

	sim_multi_worker_enqueue_dependent_edge_active :: proc(campaign: ^Sim_Multi_Worker_Generated_Campaign, worker_index: int) -> string {
		if campaign.dependent_edge_enqueued[worker_index] do return ""
		if !campaign.intermediate_durable[worker_index] || campaign.second_epoch_mutations[worker_index] != .Create_Asset_Edge {
			return "generated two-worker deferred edge precondition differs"
		}
		if campaign.models[worker_index] != campaign.intermediate_models[worker_index] {
			return "generated two-worker model advanced before deferred edge"
		}
		request_buf: [4_096]byte
		request_len := sim_multi_worker_serialize_websocket_edge_create(
			&campaign.models[worker_index],
			worker_index,
			request_buf[:],
			campaign.intermediate_models[worker_index].asset_high,
		)
		if request_len <= 0 ||
		   campaign.models[worker_index].edges[campaign.models[worker_index].edge_high].target_id != campaign.intermediate_models[worker_index].asset_high {
			return "generated two-worker deferred edge serialization differs"
		}
		frame := make_test_ws_frame(request_buf[:request_len], .opBinary, true)
		defer delete(frame)
		split := len(frame) - 2
		conn := campaign.connections[worker_index]
		if !nrc_sim_enqueue_receive(&campaign.ctx.sim, conn, frame[:split]) || !nrc_sim_enqueue_receive(&campaign.ctx.sim, conn, frame[split:]) {
			return "generated two-worker deferred edge enqueue failed"
		}
		campaign.enqueued_mutation_counts[worker_index] += 1
		campaign.dependent_edge_enqueued[worker_index] = true
		return ""
	}

	sim_multi_worker_advance_durability :: proc(campaign: ^Sim_Multi_Worker_Generated_Campaign, worker_index: int) -> (submitted: bool, reason: string) {
		ctx := campaign.ctx
		sim_multi_worker_move_into_tls(ctx, worker_index)
		defer sim_multi_worker_move_out_of_tls(ctx)
		writer := &td.shard_writers.writers[0]
		if campaign.intermediate_durable[worker_index] &&
		   !campaign.dependent_edge_enqueued[worker_index] &&
		   writer.wal.durable_record_count == campaign.intermediate_records[worker_index] {
			if writer.wal.record_count != campaign.intermediate_records[worker_index] {
				return false, "generated two-worker deferred edge durable prefix differs"
			}
			if enqueue_reason := sim_multi_worker_enqueue_dependent_edge_active(campaign, worker_index); enqueue_reason != "" {
				return false, enqueue_reason
			}
		}
		if writer.fsync_in_flight {
			return false, ""
		}
		should_submit := false
		accepted_records := writer.wal.record_count + writer.wal.buffered_record_count
		if writer.wal.durable_record_count == campaign.first_epoch_records[worker_index] {
			if campaign.intermediate_durable[worker_index] {
				should_submit = accepted_records == campaign.intermediate_records[worker_index]
			} else {
				should_submit = accepted_records == campaign.record_counts[worker_index]
			}
		} else if campaign.intermediate_durable[worker_index] && writer.wal.durable_record_count == campaign.intermediate_records[worker_index] {
			should_submit = accepted_records == campaign.record_counts[worker_index]
		}
		if !should_submit do return false, ""
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		if !sync_ok || !did_work do return false, "generated two-worker next epoch fsync submission failed"
		return true, ""
	}

	sim_multi_worker_send_completion_frame_count :: proc(completion: Sim_Send_Completion) -> int {
		switch completion.kind {
		case .Queued_Send:
			return 1
		case .Writev:
			if completion.batch_state != nil do return completion.batch_state.count
		}
		return 0
	}

	sim_multi_worker_generated_campaign_run :: proc(
		campaign: ^Sim_Multi_Worker_Generated_Campaign,
		crash_after_events: int,
		rank_choices: []u8,
		tc: ^hgl.Test_Case,
		rank_process_crash: bool = false,
	) -> string {
		if len(rank_choices) == 0 do return "generated two-worker rank choices are empty"
		ctx := campaign.ctx
		durable_epochs: [SIM_MULTI_WORKER_COUNT]int
		fsync_attempt_counts: [SIM_MULTI_WORKER_COUNT]int
		subsequent_fsync_submitted_count := 0
		send_completed_frame_count: [SIM_MULTI_WORKER_COUNT]int
		send_event_count := 0
		receive_count: [SIM_MULTI_WORKER_COUNT]int
		dispatched_count := 0
		crash_event_id: u64
		crash_incarnation_before := ctx.sim.world.process_incarnation
		if rank_process_crash {
			crash_event_id = sim_world_enqueue_process_crash(&ctx.sim.world, ctx.sim.world.now)
			if crash_event_id == 0 do return "generated two-worker process crash failed to enqueue"
		}
		crash_dispatched := false
		for rank_process_crash || dispatched_count < crash_after_events {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count == 0 {
				if len(ctx.sim.world.events) == 0 do break
				return "generated two-worker schedule stalled before crash"
			}
			selected_rank := int(rank_choices[dispatched_count % len(rank_choices)]) * runnable_count / 256
			index := sim_world_runnable_rank_index(&ctx.sim.world, selected_rank)
			if index < 0 do return "generated two-worker runnable rank missing"
			event := ctx.sim.world.events[index]
			hgl.note(
				tc,
				fmt.tprintf(
					"phase=live step=%d rank=%d event_id=%d domain=%v worker=%d",
					dispatched_count,
					selected_rank,
					event.id,
					event.domain,
					event.worker_index,
				),
			)
			fsync_failed := false
			if event.domain == .Fsync {
				worker_index := event.worker_index
				attempt := fsync_attempt_counts[worker_index]
				if campaign.fsync_error_attempts[worker_index] == attempt {
					completion, completion_ok := ctx.sim.world.events[index].payload.(Sim_Fsync_Completion)
					if !completion_ok do return "generated two-worker fsync payload differs"
					completion.err = linux.Errno.EIO
					ctx.sim.world.events[index].payload = Sim_Event_Payload(completion)
					fsync_failed = true
				}
				hgl.note(tc, fmt.tprintf("phase=live fsync worker=%d attempt=%d result=%s", worker_index, attempt, fsync_failed ? "error" : "success"))
			}
			send_event_frame_count := 0
			if event.domain == .Send {
				completion, completion_ok := event.payload.(Sim_Send_Completion)
				if !completion_ok do return "generated two-worker send payload differs"
				send_event_frame_count = sim_multi_worker_send_completion_frame_count(completion)
				if send_event_frame_count <= 0 do return "generated two-worker send frame count differs"
			}
			trace_index := ctx.event_enter_count
			if !sim_world_dispatch_event(&ctx.sim.world, index) do return "generated two-worker event dispatch failed"
			if event.id == crash_event_id {
				if event.domain != .Process_Crash || ctx.event_enter_count != trace_index || ctx.sim.world.process_incarnation <= crash_incarnation_before {
					return "generated two-worker process crash dispatch differs"
				}
				crash_dispatched = true
				dispatched_count += 1
				break
			}
			if ctx.event_enter_count != trace_index + 1 || ctx.event_entered_workers[trace_index] != event.worker_index {
				return "generated two-worker event entered the wrong owner"
			}
			#partial switch event.domain {
			case .Fsync:
				fsync_attempt_counts[event.worker_index] += 1
				campaign.fsync_attempt_counts[event.worker_index] = fsync_attempt_counts[event.worker_index]
				if fsync_failed {
					campaign.fsync_error_observed[event.worker_index] = true
				} else {
					durable_epochs[event.worker_index] += 1
					campaign.durable_epochs[event.worker_index] = durable_epochs[event.worker_index]
				}
				max_durable_epochs := campaign.intermediate_durable[event.worker_index] ? 3 : 2
				if durable_epochs[event.worker_index] > max_durable_epochs {
					return "generated two-worker completed too many durability epochs"
				}
			case .Receive:
				receive_count[event.worker_index] += 1
			case .Send:
				send_completed_frame_count[event.worker_index] += send_event_frame_count
				send_event_count += 1
			case:
				return "generated two-worker schedule dispatched an unexpected domain"
			}
			fatal_storage_error := sync.atomic_load(&campaign.server.fatal_storage_error)
			if fsync_failed && (!fatal_storage_error || !sync.atomic_load(&campaign.server.closing)) {
				return "generated two-worker fsync error did not request process shutdown"
			}
			if !fatal_storage_error && (event.domain == .Fsync || event.domain == .Receive) {
				submitted, schedule_reason := sim_multi_worker_advance_durability(campaign, event.worker_index)
				if schedule_reason != "" do return schedule_reason
				if submitted do subsequent_fsync_submitted_count += 1
			}
			dispatched_count += 1
			for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
				sim_multi_worker_move_into_tls(ctx, worker_index)
				writer := &td.shard_writers.writers[0]
				if fatal_storage_error {
					if worker_index == event.worker_index {
						if !writer.poisoned || writer.wal.enabled || writer.fsync_in_flight {
							sim_multi_worker_move_out_of_tls(ctx)
							return "generated two-worker failed writer did not become poisoned"
						}
					} else if writer.poisoned || !writer.wal.enabled {
						sim_multi_worker_move_out_of_tls(ctx)
						return "generated two-worker fsync failure poisoned its peer writer"
					}
				}
				at_first := writer.wal.record_count == campaign.first_epoch_records[worker_index]
				at_intermediate := campaign.mutation_counts[worker_index] == 2 && writer.wal.record_count == campaign.intermediate_records[worker_index]
				at_final := writer.wal.record_count == campaign.record_counts[worker_index]
				if !at_first && !at_intermediate && !at_final {
					sim_multi_worker_move_out_of_tls(ctx)
					return "generated two-worker live WAL prefix differs"
				}
				expected_durable: u64
				switch durable_epochs[worker_index] {
				case 0:
				case 1:
					expected_durable = campaign.first_epoch_records[worker_index]
				case 2:
					if campaign.intermediate_durable[worker_index] {
						expected_durable = campaign.intermediate_records[worker_index]
					} else {
						expected_durable = campaign.record_counts[worker_index]
					}
				case 3:
					expected_durable = campaign.record_counts[worker_index]
				}
				if writer.wal.durable_record_count != expected_durable ||
				   td.spool.invalid_release_count != campaign.invalid_releases_before[worker_index] ||
				   connection_lifetime_pool_live_alloc_count(td.spool) < campaign.pool_live_before[worker_index] {
					sim_multi_worker_move_out_of_tls(ctx)
					return "generated two-worker live ownership or durability diverged"
				}
				expected_model := &campaign.first_epoch_models[worker_index]
				if at_intermediate do expected_model = &campaign.intermediate_models[worker_index]
				if at_final do expected_model = &campaign.models[worker_index]
				if _, exact := generated_shard_compare(expected_model, campaign.workspaces[worker_index], writer.floors); !exact {
					sim_multi_worker_move_out_of_tls(ctx)
					return "generated two-worker live WebSocket semantic model differs"
				}
				sim_multi_worker_move_out_of_tls(ctx)
			}
			if fatal_storage_error {
				campaign.fatal_error_observed = true
				if rank_process_crash {
					crash_index := sim_world_domain_event_index(&ctx.sim.world, .Process_Crash, 0)
					if crash_index < 0 do return "generated two-worker fatal path lost its process crash event"
					trace_index = ctx.event_enter_count
					if !sim_world_dispatch_event(&ctx.sim.world, crash_index) ||
					   ctx.event_enter_count != trace_index ||
					   ctx.sim.world.process_incarnation <= crash_incarnation_before {
						return "generated two-worker fatal process crash dispatch differs"
					}
					crash_dispatched = true
					dispatched_count += 1
				}
				break
			}
		}
		if rank_process_crash && !crash_dispatched do return "generated two-worker ranked process crash did not dispatch"

		created_response_count: [SIM_MULTI_WORKER_COUNT]int
		send_in_flight_after_crash: [SIM_MULTI_WORKER_COUNT]bool
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			// Only mutation responses covered by the selected durable epoch can
			// enter transport; received but speculative suffixes stay in the outbox.
			if durable_epochs[worker_index] >= 2 {
				created_response_count[worker_index] =
					campaign.intermediate_durable[worker_index] && durable_epochs[worker_index] == 2 ? 1 : campaign.mutation_counts[worker_index]
			}
			submitted_frames := send_completed_frame_count[worker_index]
			pending_send_count := 0
			for pending_event in ctx.sim.world.events {
				if pending_event.domain != .Send || pending_event.worker_index != worker_index do continue
				pending_send_count += 1
				completion, completion_ok := pending_event.payload.(Sim_Send_Completion)
				if !completion_ok do return "generated two-worker pending send payload differs"
				pending_frames := sim_multi_worker_send_completion_frame_count(completion)
				if pending_frames <= 0 do return "generated two-worker pending send frame count differs"
				submitted_frames += pending_frames
			}
			conn := campaign.connections[worker_index]
			if pending_send_count > 1 || conn.is_sending != (pending_send_count == 1) {
				return "generated two-worker pending send ownership differs"
			}
			send_in_flight_after_crash[worker_index] = pending_send_count == 1
			actual_frames := nrc_sim_client_frame_count(&ctx.sim, conn.sock)
			if actual_frames != submitted_frames ||
			   actual_frames > created_response_count[worker_index] ||
			   (pending_send_count == 0 && actual_frames != created_response_count[worker_index]) {
				return fmt.tprintf(
					"generated two-worker response visibility differs: worker=%d receives=%d durable=%d submitted=%d actual=%d sending=%v mutation=%v",
					worker_index,
					receive_count[worker_index],
					created_response_count[worker_index],
					submitted_frames,
					actual_frames,
					conn.is_sending,
					campaign.second_epoch_mutations[worker_index],
				)
			}
			for response_index in 0 ..< actual_frames {
				payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, response_index))
				if !payload_ok do return "generated two-worker mutation response frame did not decode"
				mutation := sim_multi_worker_history_mutation(campaign.second_epoch_mutations[worker_index], response_index)
				expected_model := &campaign.models[worker_index]
				if campaign.mutation_counts[worker_index] == 2 && response_index == 0 {
					expected_model = &campaign.intermediate_models[worker_index]
				}
				switch mutation {
				case .Update_Task:
					attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
					updated, update_err := pr.parseTaskUpdated(payload, attachments[:])
					expected_attachments: [1]pr.Attachment
					expected_task := generated_shard_task_snapshot(expected_model.tasks[1], 1, &expected_attachments)
					if update_err != nil ||
					   updated.correlation_id != 0xE200 + u32(worker_index) ||
					   updated.task.id != 1 ||
					   updated.task.updated_at != NRC_SIM_TIME_EPOCH_NANOS ||
					   string(updated.task.title) != string(expected_task.title) {
						return "generated two-worker task-updated response differs"
					}
				case .Delete_Task:
					deleted, delete_err := pr.parseTaskDeleted(payload)
					if delete_err != nil ||
					   deleted.correlation_id != 0xE200 + u32(worker_index) ||
					   deleted.conv_id != GENERATED_SHARD_CONV ||
					   deleted.task_id != 1 {
						return "generated two-worker task-deleted response differs"
					}
				case .Create_Asset:
					attachments: [pr.MAX_ATTACHMENTS_PER_TASK]pr.Attachment
					created, create_err := pr.parseAssetCreatedMessage(payload, attachments[:])
					expected_id := expected_model.asset_high
					expected_attachments: [1]pr.Attachment
					expected_asset := generated_shard_asset_snapshot(expected_model.assets[expected_id], expected_id, &expected_attachments)
					if create_err != nil ||
					   created.correlation_id != 0xE200 + u32(worker_index) ||
					   created.asset.asset_id != expected_asset.asset_id ||
					   created.asset.parent_type != expected_asset.parent_type ||
					   created.asset.parent_id != expected_asset.parent_id ||
					   created.asset.created_at != expected_asset.created_at ||
					   string(created.asset.owner) != string(expected_asset.owner) {
						return "generated two-worker asset-created response differs"
					}
				case .Create_Edge:
					created, create_err := pr.parseEdgeCreatedMessage(payload)
					expected_id := expected_model.edge_high
					expected_edge := expected_model.edges[expected_id]
					if create_err != nil ||
					   created.correlation_id != 0xE200 + u32(worker_index) ||
					   created.edge.edge_id != pr.EdgeID(expected_id) ||
					   created.edge.source_type != expected_edge.source_type ||
					   u64(created.edge.source_id) != expected_edge.source_id ||
					   created.edge.target_type != expected_edge.target_type ||
					   u64(created.edge.target_id) != expected_edge.target_id ||
					   created.edge.relation != expected_edge.relation ||
					   created.edge.created_at != expected_edge.created_at ||
					   string(created.edge.created_by) != expected_edge.created_by {
						return "generated two-worker edge-created response differs"
					}
				case .Create_Asset_Edge:
					unreachable()
				}
			}
			if !sim_multi_worker_discard_process_writer(ctx, worker_index) {
				return "generated two-worker process writer discard failed"
			}
		}

		if !crash_dispatched do sim_world_crash(&ctx.sim.world)
		for len(ctx.sim.world.events) > 0 {
			runnable_count := sim_world_prepare_runnable(&ctx.sim.world)
			if runnable_count == 0 do return "generated two-worker stale schedule stalled"
			selected_rank := int(rank_choices[dispatched_count % len(rank_choices)]) * runnable_count / 256
			index := sim_world_runnable_rank_index(&ctx.sim.world, selected_rank)
			if index < 0 do return "generated two-worker stale runnable rank missing"
			event := ctx.sim.world.events[index]
			hgl.note(
				tc,
				fmt.tprintf(
					"phase=stale step=%d rank=%d event_id=%d domain=%v worker=%d",
					dispatched_count,
					selected_rank,
					event.id,
					event.domain,
					event.worker_index,
				),
			)
			trace_index := ctx.event_enter_count
			if !sim_world_dispatch_event(&ctx.sim.world, index) do return "generated two-worker stale event dispatch failed"
			if ctx.event_enter_count != trace_index + 1 || ctx.event_entered_workers[trace_index] != event.worker_index {
				return "generated two-worker stale event entered the wrong owner"
			}
			if event.domain == .Send do send_event_count += 1
			dispatched_count += 1
		}
		expected_receive_event_count := 0
		for count in campaign.enqueued_mutation_counts do expected_receive_event_count += 2 * count
		expected_event_count := SIM_MULTI_WORKER_COUNT + expected_receive_event_count + send_event_count + subsequent_fsync_submitted_count
		if crash_dispatched do expected_event_count += 1
		if dispatched_count != expected_event_count {
			return "generated two-worker total event accounting differs"
		}
		if sync.atomic_load(&campaign.server.fatal_storage_error) != campaign.fatal_error_observed ||
		   sync.atomic_load(&campaign.server.closing) != campaign.fatal_error_observed {
			return "generated two-worker process-fatal state differs before restart"
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			conn := campaign.connections[worker_index]
			if conn.pending_io != 0 || td.spool.invalid_release_count != campaign.invalid_releases_before[worker_index] {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker crash did not reclaim transport ownership"
			}
			if conn.is_sending != send_in_flight_after_crash[worker_index] {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker stale send changed in-flight state"
			}
			expected_watchdog_count := send_in_flight_after_crash[worker_index] ? 1 : 0
			if len(td.inflight_send_handles) != expected_watchdog_count {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker watchdog ownership differs"
			}
			if expected_watchdog_count == 1 {
				if td.inflight_send_handles[0] != conn.handle || conn.send_watchdog_slot != 1 {
					sim_multi_worker_move_out_of_tls(ctx)
					return "generated two-worker stale watchdog handle differs"
				}
				conn.send_watchdog_slot = 0
				conn.is_sending = false
				conn.send_started_at = {}
				clear(&td.inflight_send_handles)
				td.next_send_watchdog_at = {}
			} else if conn.send_watchdog_slot != 0 {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker drained send retained watchdog slot"
			}
			simulation_test_uninstall_client(conn)
			campaign.connections[worker_index] = nil
			if connection_lifetime_pool_live_alloc_count(td.spool) != campaign.pool_live_before[worker_index] ||
			   td.spool.invalid_release_count != campaign.invalid_releases_before[worker_index] {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker connection teardown did not reclaim pooled ownership"
			}
			cleanup_workspaces()
			td.workspaces = make(map[string]^Workspace_State, 8)
			td.task_seq = 0
			td.asset_seq = 0
			td.edge_seq = 0
			sim_multi_worker_move_out_of_tls(ctx)
		}
		sync.atomic_store(&campaign.server.fatal_storage_error, false)
		sync.atomic_store(&campaign.server.closing, false)

		recovered_models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
		recovered_record_counts: [SIM_MULTI_WORKER_COUNT]u64
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, campaign.workspaces[worker_index], campaign.shard_dirs[worker_index], false)
			if writer == nil do return "generated two-worker recovery initialization failed"
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			if !replay_ok {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker recovery replay failed"
			}
			expected_model := Generated_Shard_Model{}
			expected_records: u64
			switch durable_epochs[worker_index] {
			case 0:
			case 1:
				expected_model = campaign.first_epoch_models[worker_index]
				expected_records = campaign.first_epoch_records[worker_index]
			case 2:
				if campaign.intermediate_durable[worker_index] {
					expected_model = campaign.intermediate_models[worker_index]
					expected_records = campaign.intermediate_records[worker_index]
					campaign.recovered_intermediate[worker_index] = true
				} else {
					expected_model = campaign.models[worker_index]
					expected_records = campaign.record_counts[worker_index]
				}
			case 3:
				expected_model = campaign.models[worker_index]
				expected_records = campaign.record_counts[worker_index]
			}
			diagnostic, exact := generated_shard_compare(&expected_model, campaign.workspaces[worker_index], floors)
			if !exact || writer.floors != floors || writer.wal.record_count != expected_records || writer.wal.durable_record_count != expected_records {
				hgl.note(tc, fmt.tprintf("worker=%d recovery=%s", worker_index, diagnostic))
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker recovered state differs from durable model"
			}
			recovered_models[worker_index] = expected_model
			recovered_record_counts[worker_index] = expected_records + 1
			td.task_seq = floors.task
			td.asset_seq = floors.asset
			td.edge_seq = floors.edge
			if !generated_shard_apply_op(
				&recovered_models[worker_index],
				writer,
				transmute([]byte)campaign.workspaces[worker_index],
				campaign.shard_dirs[worker_index],
				Generated_Shard_Op{kind = .Create_Task},
			) {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker recovery continuation failed"
			}
			diagnostic, exact = generated_shard_compare(&recovered_models[worker_index], campaign.workspaces[worker_index], writer.floors)
			if !exact || writer.wal.record_count != recovered_record_counts[worker_index] || writer.wal.durable_record_count != expected_records {
				hgl.note(tc, fmt.tprintf("worker=%d continuation=%s", worker_index, diagnostic))
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker continued state differs from model"
			}
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			if !sync_ok || !did_work {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker continuation fsync submission failed"
			}
			sim_multi_worker_move_out_of_tls(ctx)
		}

		if sim_world_event_count(&ctx.sim.world, .Fsync) != SIM_MULTI_WORKER_COUNT {
			return "generated two-worker continuation fsync set differs"
		}
		continuation_order := rank_choices[0] & 1 == 0 ? ([2]int{0, 1}) : ([2]int{1, 0})
		for worker_index in continuation_order {
			ordinal := sim_multi_worker_fsync_ordinal_for_worker(ctx, worker_index)
			if ordinal < 0 do return "generated two-worker continuation fsync missing"
			trace_index := ctx.event_enter_count
			hgl.note(tc, fmt.tprintf("phase=continuation event=fsync worker=%d", worker_index))
			if !nrc_sim_run_fsync_completion_at(&ctx.sim, ordinal) do return "generated two-worker continuation fsync failed"
			if ctx.event_enter_count != trace_index + 1 || ctx.event_entered_workers[trace_index] != worker_index {
				return "generated two-worker continuation fsync entered the wrong owner"
			}
		}

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			if writer.wal.record_count != recovered_record_counts[worker_index] || writer.wal.durable_record_count != recovered_record_counts[worker_index] {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker continuation did not become durable"
			}
			sim_multi_worker_move_out_of_tls(ctx)
			if !sim_multi_worker_discard_process_writer(ctx, worker_index) {
				return "generated two-worker continuation writer discard failed"
			}
		}
		sim_world_crash(&ctx.sim.world)
		if len(ctx.sim.world.events) != 0 do return "generated two-worker second crash retained events"

		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			cleanup_workspaces()
			td.workspaces = make(map[string]^Workspace_State, 8)
			td.task_seq = 0
			td.asset_seq = 0
			td.edge_seq = 0
			sim_multi_worker_move_out_of_tls(ctx)
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, campaign.workspaces[worker_index], campaign.shard_dirs[worker_index], false)
			if writer == nil do return "generated two-worker second recovery initialization failed"
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			if !replay_ok {
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker second recovery replay failed"
			}
			diagnostic, exact := generated_shard_compare(&recovered_models[worker_index], campaign.workspaces[worker_index], floors)
			if !exact ||
			   writer.floors != floors ||
			   writer.wal.record_count != recovered_record_counts[worker_index] ||
			   writer.wal.durable_record_count != recovered_record_counts[worker_index] {
				hgl.note(tc, fmt.tprintf("worker=%d second_recovery=%s", worker_index, diagnostic))
				sim_multi_worker_move_out_of_tls(ctx)
				return "generated two-worker second recovery differs from continued model"
			}
			sim_multi_worker_move_out_of_tls(ctx)
		}
		return ""
	}

	sim_multi_worker_fsync_ordinal_for_worker :: proc(ctx: ^Sim_Multi_Worker_Test_Context, worker_index: int) -> int {
		ordinal := 0
		for {
			index := sim_world_domain_event_index(&ctx.sim.world, .Fsync, ordinal)
			if index < 0 do return -1
			if ctx.sim.world.events[index].worker_index == worker_index do return ordinal
			ordinal += 1
		}
	}

	sim_multi_worker_complete_selected_fsync :: proc(
		t: ^testing.T,
		ctx: ^Sim_Multi_Worker_Test_Context,
		worker_index: int,
		expected_enter_count: ^int,
	) -> bool {
		ordinal := sim_multi_worker_fsync_ordinal_for_worker(ctx, worker_index)
		if !testing.expect(t, ordinal >= 0, "selected worker fsync should remain queued") do return false
		if !testing.expect(t, nrc_sim_run_fsync_completion_at(&ctx.sim, ordinal), "selected worker fsync should complete") do return false
		testing.expect_value(t, ctx.event_entered_workers[expected_enter_count^], worker_index)
		expected_enter_count^ += 1
		return true
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

	sim_multi_worker_complete_available_sends :: proc(
		t: ^testing.T,
		ctx: ^Sim_Multi_Worker_Test_Context,
		send_completion_mask: u8,
		completion_order: []int,
		next_completion: ^int,
		expected_enter_count: ^int,
	) -> bool {
		for next_completion^ < len(completion_order) {
			worker_index := completion_order[next_completion^]
			if send_completion_mask & (u8(1) << u8(worker_index)) == 0 {
				next_completion^ += 1
				continue
			}
			ordinal := sim_multi_worker_send_ordinal_for_worker(ctx, worker_index)
			if ordinal < 0 do return true
			if !testing.expect(t, nrc_sim_run_send_completion_at(&ctx.sim, ordinal), "selected worker send should complete") do return false
			testing.expect_value(t, ctx.event_entered_workers[expected_enter_count^], worker_index)
			expected_enter_count^ += 1
			next_completion^ += 1
		}
		return true
	}

	sim_multi_worker_runnable_receive_rank_for_connection :: proc(ctx: ^Sim_Multi_Worker_Test_Context, sock: net.TCP_Socket) -> int {
		runnable_count := sim_world_prepare_runnable(&ctx.sim.world, Sim_Event_Domain.Receive)
		for rank in 0 ..< runnable_count {
			index := sim_world_runnable_rank_index(&ctx.sim.world, rank, Sim_Event_Domain.Receive)
			if index >= 0 && ctx.sim.world.events[index].target.id == u64(sock) do return rank
		}
		return -1
	}

	@(test)
	// First vertical two-worker world: HTTP requests route through production
	// pending queues into independent worker-owned TLS, while one shared event
	// kernel dispatches each asynchronous completion back to its owner worker.
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
			// Adopt all such upgrades and terminalize bootstrap sends so their
			// production observers release the HTTP temporary connections.
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

		// Worker 1 adopts first and makes nonterminal progress on its bootstrap
		// while worker 0's routed upgrade remains pending and invisible.
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
			if event.domain == .Send {
				testing.expect_value(t, event.worker_index, int(event.target.id) == int(socks[0]) ? 0 : 1)
			}
		}

		// Complete in the opposite order from adoption. Each completion must
		// restore the owner worker before touching its handle or pooled lease.
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
				if ready_err == nil {
					testing.expect(t, string(ready.username) == usernames[worker_index], "ServerReady must carry the owner identity")
				}
			}
		}
	}

	// Two production shard owners append to one virtual storage world. A selected
	// subset of fsync completions runs before process crash; restart must recover
	// exactly those durable shards and discard every unselected pending record.
	// Both recovered workers then append, become durable, and survive a second
	// process-wide crash with their divergent histories intact.
	sim_multi_worker_shards_recover_exact_cross_worker_durable_prefix :: proc(
		t: ^testing.T,
		durable_mask: u8,
		reverse_completion_order: bool,
		fsync_after_receive_events: [SIM_MULTI_WORKER_COUNT]int,
		receive_worker_order: [2 * SIM_MULTI_WORKER_COUNT]int,
		send_completion_mask: u8,
		reverse_send_completion_order: bool,
	) {
		assert(durable_mask <= 3)
		assert(send_completion_mask <= 3)
		receive_count_by_worker: [SIM_MULTI_WORKER_COUNT]int
		for worker_index in receive_worker_order {
			assert(worker_index >= 0 && worker_index < SIM_MULTI_WORKER_COUNT)
			receive_count_by_worker[worker_index] += 1
		}
		for count in receive_count_by_worker do assert(count == 2)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			selected := durable_mask & (u8(1) << u8(worker_index)) != 0
			if selected {
				assert(fsync_after_receive_events[worker_index] >= 0 && fsync_after_receive_events[worker_index] <= 2 * SIM_MULTI_WORKER_COUNT)
			} else {
				assert(fsync_after_receive_events[worker_index] == -1)
			}
		}
		queues: [SIM_MULTI_WORKER_COUNT]Pending_Connection_Queue
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			queue, queue_err := pending_queue_create(1)
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
			pending_connections = pending_queues,
		}

		workspaces := [?]string{sim_multi_worker_workspace_for(0), sim_multi_worker_workspace_for(1)}
		shard_dirs := [?]string{"/worker-0-shard", "/worker-1-shard"}
		ctx := new(Sim_Multi_Worker_Test_Context)
		sim_multi_worker_test_begin(ctx, &server)
		defer {
			sim_multi_worker_test_end(ctx, nil)
			free(ctx)
		}

		models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
		transport_connections: [SIM_MULTI_WORKER_COUNT]^NRC_Connection
		pool_live_before: [SIM_MULTI_WORKER_COUNT]uint
		invalid_releases_before: [SIM_MULTI_WORKER_COUNT]u64
		ping_payload: [16]byte
		ping_len := pr.serializePingRequest(9_000 + i64(durable_mask), ping_payload[:])
		testing.expect(t, ping_len > 0, "cross-worker ping should serialize")
		if ping_len <= 0 do return
		ping_frame := make_test_ws_frame(ping_payload[:ping_len], .opBinary, true)
		defer delete(ping_frame)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], true)
			testing.expect(t, writer != nil, "worker should initialize its assigned virtual shard")
			if writer == nil do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			applied := generated_shard_apply_op(
				&models[worker_index],
				writer,
				transmute([]byte)workspaces[worker_index],
				shard_dirs[worker_index],
				Generated_Shard_Op{kind = .Create_Task},
			)
			testing.expect(t, applied, "worker mutation should append and apply through production shard transaction paths")
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			testing.expect(t, sync_ok && did_work, "worker should submit one async fsync")
			transport_connections[worker_index] = simulation_test_install_client(
				&ctx.sim,
				450 + worker_index,
				workspaces[worker_index],
				worker_index == 0 ? "transport-worker-0" : "transport-worker-1",
				init_send_queue = true,
			)
			conn := transport_connections[worker_index]
			testing.expect(t, conn != nil, "worker transport client should install")
			if conn == nil {
				sim_multi_worker_move_out_of_tls(ctx)
				return
			}
			split := worker_index == 0 ? 3 : len(ping_frame) - 2
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, ping_frame[:split]), "worker ping prefix should enqueue")
			testing.expect(t, nrc_sim_enqueue_receive(&ctx.sim, conn, ping_frame[split:]), "worker ping suffix should enqueue")
			pool_live_before[worker_index] = connection_lifetime_pool_live_alloc_count(td.spool)
			invalid_releases_before[worker_index] = td.spool.invalid_release_count
			sim_multi_worker_move_out_of_tls(ctx)
		}
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Fsync), SIM_MULTI_WORKER_COUNT)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Receive), 2 * SIM_MULTI_WORKER_COUNT)
		completion_order := reverse_completion_order ? ([2]int{1, 0}) : ([2]int{0, 1})
		send_completion_order := reverse_send_completion_order ? ([2]int{1, 0}) : ([2]int{0, 1})
		expected_enter_count := 0
		receive_events_dispatched := 0
		next_send_completion := 0
		receive_entries_by_worker: [SIM_MULTI_WORKER_COUNT]int
		for receive_events_dispatched <= 2 * SIM_MULTI_WORKER_COUNT {
			for worker_index in completion_order {
				if fsync_after_receive_events[worker_index] != receive_events_dispatched do continue
				if !sim_multi_worker_complete_selected_fsync(t, ctx, worker_index, &expected_enter_count) do return
			}
			if receive_events_dispatched == 2 * SIM_MULTI_WORKER_COUNT do break
			trace_index := ctx.event_enter_count
			expected_receive_worker := receive_worker_order[receive_events_dispatched]
			receive_rank := sim_multi_worker_runnable_receive_rank_for_connection(ctx, transport_connections[expected_receive_worker].sock)
			if !testing.expect(t, receive_rank >= 0, "selected worker receive should be runnable") do return
			if !testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, receive_rank, Sim_Event_Domain.Receive), "split worker receive should dispatch") do return
			worker_index := ctx.event_entered_workers[trace_index]
			testing.expect_value(t, worker_index, expected_receive_worker)
			if worker_index >= 0 && worker_index < SIM_MULTI_WORKER_COUNT do receive_entries_by_worker[worker_index] += 1
			receive_events_dispatched += 1
			expected_enter_count = ctx.event_enter_count
			if !sim_multi_worker_complete_available_sends(
				t,
				ctx,
				send_completion_mask,
				send_completion_order[:],
				&next_send_completion,
				&expected_enter_count,
			) {
				return
			}
		}
		testing.expect_value(t, receive_events_dispatched, 2 * SIM_MULTI_WORKER_COUNT)
		testing.expect_value(t, next_send_completion, SIM_MULTI_WORKER_COUNT)
		expected_send_pending := 0
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do if send_completion_mask & (u8(1) << u8(worker_index)) == 0 do expected_send_pending += 1
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), expected_send_pending)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			testing.expect_value(t, receive_entries_by_worker[worker_index], 2)
			sock := transport_connections[worker_index].sock
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, sock, .S_Pong), 1)
			payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, sock, 0))
			testing.expect(t, payload_ok, "worker Pong frame should decode")
			if payload_ok {
				pong, pong_err := pr.parsePongResponseMessage(payload)
				testing.expect(t, pong_err == nil, "worker Pong response should parse")
				if pong_err == nil do testing.expect_value(t, pong.timestamp, 9_000 + i64(durable_mask))
			}
		}

		expected_enter_count = ctx.event_enter_count
		expected_pending_count := 0
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do if durable_mask & (u8(1) << u8(worker_index)) == 0 do expected_pending_count += 1
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Fsync), expected_pending_count)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			writer := &td.shard_writers.writers[0]
			expected_durable := durable_mask & (u8(1) << u8(worker_index)) != 0 ? u64(1) : u64(0)
			testing.expect_value(t, writer.wal.durable_record_count, expected_durable)
			sim_multi_worker_move_out_of_tls(ctx)
			testing.expect(t, sim_multi_worker_discard_process_writer(ctx, worker_index), "process crash should discard worker writer ownership")
		}

		sim_world_crash(&ctx.sim.world)
		for len(ctx.sim.world.events) > 0 {
			index := sim_world_runnable_rank_index(&ctx.sim.world, 0)
			testing.expect(t, index >= 0, "stale cross-worker event should be runnable")
			if index < 0 do return
			worker_index := ctx.sim.world.events[index].worker_index
			testing.expect(t, sim_world_run_next_event(&ctx.sim.world), "stale cross-worker event should drain under its owner")
			testing.expect_value(t, ctx.event_enter_count, expected_enter_count + 1)
			testing.expect_value(t, ctx.event_entered_workers[expected_enter_count], worker_index)
			expected_enter_count += 1
		}
		testing.expect_value(t, ctx.event_enter_count, 4 * SIM_MULTI_WORKER_COUNT)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Fsync), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			conn := transport_connections[worker_index]
			testing.expect_value(t, conn.pending_io, 0)
			testing.expect_value(t, connection_lifetime_pool_live_alloc_count(td.spool), pool_live_before[worker_index])
			testing.expect_value(t, td.spool.invalid_release_count, invalid_releases_before[worker_index])
			send_completed := send_completion_mask & (u8(1) << u8(worker_index)) != 0
			expected_watchdog_count := send_completed ? 0 : 1
			testing.expect_value(t, len(td.inflight_send_handles), expected_watchdog_count)
			if !send_completed {
				if len(td.inflight_send_handles) == 1 do testing.expect_value(t, td.inflight_send_handles[0], conn.handle)
				conn.send_watchdog_slot = 0
				conn.is_sending = false
				conn.send_started_at = {}
				clear(&td.inflight_send_handles)
				td.next_send_watchdog_at = {}
			}
			simulation_test_uninstall_client(conn)
			transport_connections[worker_index] = nil
			cleanup_workspaces()
			td.workspaces = make(map[string]^Workspace_State, 8)
			td.task_seq = 0
			td.asset_seq = 0
			td.edge_seq = 0
			sim_multi_worker_move_out_of_tls(ctx)
		}

		recovered_models: [SIM_MULTI_WORKER_COUNT]Generated_Shard_Model
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			if durable_mask & (u8(1) << u8(worker_index)) != 0 do recovered_models[worker_index] = models[worker_index]
		}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], false)
			testing.expect(t, writer != nil, "worker should reopen its assigned shard after process crash")
			if writer == nil do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			testing.expect(t, replay_ok, "worker shard should replay through production recovery")
			testing.expect_value(t, writer.floors, floors)
			td.task_seq = floors.task
			td.asset_seq = floors.asset
			td.edge_seq = floors.edge
			diagnostic, exact := generated_shard_compare(&recovered_models[worker_index], workspaces[worker_index], floors)
			testing.expectf(t, exact, "worker %d recovered state differs from durable model: %s", worker_index, diagnostic)
			expected_records := durable_mask & (u8(1) << u8(worker_index)) != 0 ? u64(1) : u64(0)
			testing.expect_value(t, writer.wal.record_count, expected_records)
			testing.expect_value(t, writer.wal.durable_record_count, writer.wal.record_count)

			continued := generated_shard_apply_op(
				&recovered_models[worker_index],
				writer,
				transmute([]byte)workspaces[worker_index],
				shard_dirs[worker_index],
				Generated_Shard_Op{kind = .Create_Task},
			)
			testing.expect(t, continued, "recovered worker should accept a continued transaction")
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			testing.expect(t, sync_ok && did_work, "continued worker transaction should submit fsync")
			sim_multi_worker_move_out_of_tls(ctx)
		}

		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Fsync), SIM_MULTI_WORKER_COUNT)
		for worker_index in completion_order {
			ordinal := sim_multi_worker_fsync_ordinal_for_worker(ctx, worker_index)
			testing.expect(t, ordinal >= 0, "continued worker fsync should remain queued")
			if ordinal < 0 do return
			testing.expect(t, nrc_sim_run_fsync_completion_at(&ctx.sim, ordinal), "continued worker fsync should complete")
			testing.expect_value(t, ctx.event_entered_workers[expected_enter_count], worker_index)
			expected_enter_count += 1
		}
		testing.expect_value(t, ctx.event_enter_count, expected_enter_count)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			sim_multi_worker_move_into_tls(ctx, worker_index)
			expected_records := durable_mask & (u8(1) << u8(worker_index)) != 0 ? u64(2) : u64(1)
			testing.expect_value(t, td.shard_writers.writers[0].wal.durable_record_count, expected_records)
			sim_multi_worker_move_out_of_tls(ctx)
			testing.expect(t, sim_multi_worker_discard_process_writer(ctx, worker_index), "second process crash should discard worker writer ownership")
		}

		sim_world_crash(&ctx.sim.world)
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			writer := sim_multi_worker_init_single_shard_writer(ctx, worker_index, workspaces[worker_index], shard_dirs[worker_index], false)
			testing.expect(t, writer != nil, "worker should reopen its shard after the continuation crash")
			if writer == nil do return
			sim_multi_worker_move_into_tls(ctx, worker_index)
			floors, replay_ok := replay_shard_compaction_sequence(writer.storage, writer.shard_dir, writer.manifest, true, false)
			testing.expect(t, replay_ok, "continued worker history should replay after second crash")
			testing.expect_value(t, writer.floors, floors)
			td.task_seq = floors.task
			td.asset_seq = floors.asset
			td.edge_seq = floors.edge
			diagnostic, exact := generated_shard_compare(&recovered_models[worker_index], workspaces[worker_index], floors)
			testing.expectf(t, exact, "worker %d continued state differs after second crash: %s", worker_index, diagnostic)
			expected_records := durable_mask & (u8(1) << u8(worker_index)) != 0 ? u64(2) : u64(1)
			testing.expect_value(t, writer.wal.record_count, expected_records)
			testing.expect_value(t, writer.wal.durable_record_count, writer.wal.record_count)
			sim_multi_worker_move_out_of_tls(ctx)
		}
	}

	@(test)
	test_simulation_two_worker_shards_recover_exact_cross_worker_durable_prefix :: proc(t: ^testing.T) {
		completion_orders := [?]bool{false, true}
		receive_worker_orders := [6][2 * SIM_MULTI_WORKER_COUNT]int{{0, 0, 1, 1}, {0, 1, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, 1}, {1, 0, 1, 0}, {1, 1, 0, 0}}
		send_completion_masks := [6]u8{0, 1, 2, 3, 3, 0}
		reverse_send_completion_orders := [6]bool{false, false, false, false, true, true}
		for durable_mask in u8(0) ..= u8(3) {
			for reverse_completion_order in completion_orders {
				completion_order := reverse_completion_order ? ([2]int{1, 0}) : ([2]int{0, 1})
				if durable_mask == 3 {
					for first_position in 0 ..= 2 * SIM_MULTI_WORKER_COUNT {
						for second_position in first_position ..= 2 * SIM_MULTI_WORKER_COUNT {
							positions := [SIM_MULTI_WORKER_COUNT]int{-1, -1}
							positions[completion_order[0]] = first_position
							positions[completion_order[1]] = second_position
							for receive_worker_order, receive_order_index in receive_worker_orders {
								sim_multi_worker_shards_recover_exact_cross_worker_durable_prefix(
									t,
									durable_mask,
									reverse_completion_order,
									positions,
									receive_worker_order,
									send_completion_masks[receive_order_index],
									reverse_send_completion_orders[receive_order_index],
								)
							}
						}
					}
				} else if durable_mask != 0 {
					selected_worker := durable_mask == 1 ? 0 : 1
					for position in 0 ..= 2 * SIM_MULTI_WORKER_COUNT {
						positions := [SIM_MULTI_WORKER_COUNT]int{-1, -1}
						positions[selected_worker] = position
						for receive_worker_order, receive_order_index in receive_worker_orders {
							sim_multi_worker_shards_recover_exact_cross_worker_durable_prefix(
								t,
								durable_mask,
								reverse_completion_order,
								positions,
								receive_worker_order,
								send_completion_masks[receive_order_index],
								reverse_send_completion_orders[receive_order_index],
							)
						}
					}
				} else {
					for receive_worker_order, receive_order_index in receive_worker_orders {
						sim_multi_worker_shards_recover_exact_cross_worker_durable_prefix(
							t,
							durable_mask,
							reverse_completion_order,
							{-1, -1},
							receive_worker_order,
							send_completion_masks[receive_order_index],
							reverse_send_completion_orders[receive_order_index],
						)
					}
				}
			}
		}
	}

	prop_generated_two_worker_global_event_schedule :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		safe_semantic_kinds := [?]Generated_Shard_Op_Kind {
			.Create_Task,
			.Update_Task,
			.Move_Task,
			.Query_Tasks_Paged,
			.Create_Asset,
			.Create_Slice,
			.Create_File,
			.Create_Customer,
			.Update_Asset,
			.Query_Assets_Paged,
			.Create_Edge,
			.Create_Membership,
			.Query_Slices,
			.Query_Graph,
			.Delete_Asset,
			.Delete_Edge,
		}
		semantic_ops: [SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op
		semantic_op_counts: [SIM_MULTI_WORKER_COUNT]int
		second_epoch_mutations: [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation
		intermediate_durable: [SIM_MULTI_WORKER_COUNT]bool
		fsync_error_attempts: [SIM_MULTI_WORKER_COUNT]int
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			semantic_ops[worker_index][0] = {
				kind = .Create_Task,
			}
			semantic_op_counts[worker_index] = 1
			suffix_count, suffix_count_err := hgl.draw_i64(tc, 0, 2)
			if suffix_count_err == .Stop_Test do return hgl.abort()
			if suffix_count_err != nil do return hgl.interesting("draw two-worker semantic operation count")
			for suffix_index in 0 ..< int(suffix_count) {
				kind, kind_err := hgl.draw_i64(tc, 0, i64(len(safe_semantic_kinds) - 1))
				if kind_err == .Stop_Test do return hgl.abort()
				if kind_err != nil do return hgl.interesting("draw two-worker semantic operation kind")
				selector, selector_err := hgl.draw_i64(tc, 0, 255)
				if selector_err == .Stop_Test do return hgl.abort()
				if selector_err != nil do return hgl.interesting("draw two-worker semantic operation selector")
				semantic_ops[worker_index][semantic_op_counts[worker_index]] = {
					kind     = safe_semantic_kinds[kind],
					selector = u64(selector),
				}
				semantic_op_counts[worker_index] += 1
			}
			mutation, mutation_err := hgl.draw_i64(tc, 0, i64(Sim_Multi_Worker_WebSocket_Mutation.Create_Asset_Edge))
			if mutation_err == .Stop_Test do return hgl.abort()
			if mutation_err != nil do return hgl.interesting("draw two-worker WebSocket mutation")
			second_epoch_mutations[worker_index] = Sim_Multi_Worker_WebSocket_Mutation(mutation)
			if second_epoch_mutations[worker_index] == .Create_Asset_Edge {
				should_sync, should_sync_err := hgl.draw_bool(tc)
				if should_sync_err == .Stop_Test do return hgl.abort()
				if should_sync_err != nil do return hgl.interesting("draw two-worker intermediate durability")
				intermediate_durable[worker_index] = should_sync
			}
			max_fsync_attempt := intermediate_durable[worker_index] ? 2 : 1
			fsync_error_attempt, fsync_error_err := hgl.draw_i64(tc, -1, i64(max_fsync_attempt))
			if fsync_error_err == .Stop_Test do return hgl.abort()
			if fsync_error_err != nil do return hgl.interesting("draw two-worker fsync error attempt")
			fsync_error_attempts[worker_index] = int(fsync_error_attempt)
		}
		rank_choices: [21]u8
		for index in 0 ..< len(rank_choices) {
			choice, choice_err := hgl.draw_i64(tc, 0, 255)
			if choice_err == .Stop_Test do return hgl.abort()
			if choice_err != nil do return hgl.interesting("draw two-worker runnable rank")
			rank_choices[index] = u8(choice)
		}

		campaign: Sim_Multi_Worker_Generated_Campaign
		defer sim_multi_worker_generated_campaign_end(&campaign)
		hgl.note(
			tc,
			fmt.tprintf(
				"rank_choices=%v worker_0_ops=%v worker_1_ops=%v second_epoch=%v intermediate_durable=%v fsync_error_attempts=%v",
				rank_choices,
				semantic_ops[0][:semantic_op_counts[0]],
				semantic_ops[1][:semantic_op_counts[1]],
				second_epoch_mutations,
				intermediate_durable,
				fsync_error_attempts,
			),
		)
		if reason := sim_multi_worker_generated_campaign_begin(
			&campaign,
			&semantic_ops,
			semantic_op_counts,
			second_epoch_mutations,
			intermediate_durable,
			fsync_error_attempts,
		); reason != "" {
			hgl.note(tc, reason)
			return hgl.interesting("initialize generated two-worker campaign")
		}
		if reason := sim_multi_worker_generated_campaign_run(&campaign, 0, rank_choices[:], tc, rank_process_crash = true); reason != "" {
			hgl.note(tc, reason)
			if tc.is_final do fmt.eprintf("generated two-worker failure: reason=%s rank_choices=%v worker_0_ops=%v worker_1_ops=%v second_epoch=%v intermediate_durable=%v fsync_error_attempts=%v\n", reason, rank_choices, semantic_ops[0][:semantic_op_counts[0]], semantic_ops[1][:semantic_op_counts[1]], second_epoch_mutations, intermediate_durable, fsync_error_attempts)
			return hgl.interesting("generated two-worker invariant failed")
		}
		return hgl.valid()
	}

	@(test)
	test_generated_two_worker_ranked_process_crash_boundaries :: proc(t: ^testing.T) {
		semantic_ops: [SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op
		semantic_op_counts := [SIM_MULTI_WORKER_COUNT]int{1, 1}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do semantic_ops[worker_index][0] = {
			kind = .Create_Task,
		}
		mutations := [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation{.Update_Task, .Update_Task}
		intermediate_durable: [SIM_MULTI_WORKER_COUNT]bool
		fsync_error_attempts := [SIM_MULTI_WORKER_COUNT]int{-1, -1}
		rank_cases: [2][21]u8
		for &choice in rank_cases[0] do choice = 255
		expected_durable_epochs := [2][SIM_MULTI_WORKER_COUNT]int{{0, 0}, {1, 1}}

		for case_index in 0 ..< len(rank_cases) {
			campaign: Sim_Multi_Worker_Generated_Campaign
			reason := sim_multi_worker_generated_campaign_begin(
				&campaign,
				&semantic_ops,
				semantic_op_counts,
				mutations,
				intermediate_durable,
				fsync_error_attempts,
			)
			if reason == "" {
				reason = sim_multi_worker_generated_campaign_run(&campaign, 0, rank_cases[case_index][:], nil, rank_process_crash = true)
			}
			testing.expect_value(t, reason, "")
			testing.expect_value(t, campaign.durable_epochs, expected_durable_epochs[case_index])
			sim_multi_worker_generated_campaign_end(&campaign)
			if reason != "" do return
		}
	}

	@(test)
	test_generated_two_worker_batched_responses_clear_watchdog_before_process_crash :: proc(t: ^testing.T) {
		semantic_ops: [SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op
		semantic_op_counts := [SIM_MULTI_WORKER_COUNT]int{1, 1}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT do semantic_ops[worker_index][0] = {
			kind = .Create_Task,
		}
		mutations := [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation{.Update_Task, .Create_Asset_Edge}
		intermediate_durable: [SIM_MULTI_WORKER_COUNT]bool
		fsync_error_attempts := [SIM_MULTI_WORKER_COUNT]int{-1, -1}
		rank_choices := [21]u8{117, 72, 145, 2, 39, 0, 0, 56, 116, 146, 131, 202, 195, 130, 202, 79, 169, 58, 168, 180, 178}
		campaign: Sim_Multi_Worker_Generated_Campaign
		reason := sim_multi_worker_generated_campaign_begin(
			&campaign,
			&semantic_ops,
			semantic_op_counts,
			mutations,
			intermediate_durable,
			fsync_error_attempts,
		)
		if reason == "" {
			reason = sim_multi_worker_generated_campaign_run(&campaign, 0, rank_choices[:], nil, rank_process_crash = true)
		}
		testing.expect_value(t, reason, "")
		testing.expect_value(t, campaign.durable_epochs, [SIM_MULTI_WORKER_COUNT]int{2, 2})
		sim_multi_worker_generated_campaign_end(&campaign)
	}

	@(test)
	test_simulation_two_worker_compaction_publications_survive_ranked_process_crash_independently :: proc(t: ^testing.T) {
		cases := [?]Sim_Multi_Worker_Compaction_Case {
			{steps = {.Crash, .Crash, .Crash, .Crash, .Crash}, step_count = 1, publication_mask = 0b00},
			{steps = {.Job_0, .Crash, .Crash, .Crash, .Crash}, step_count = 2, publication_mask = 0b00},
			{steps = {.Job_1, .Crash, .Crash, .Crash, .Crash}, step_count = 2, publication_mask = 0b00},
			{steps = {.Job_0, .Job_1, .Result_0, .Crash, .Crash}, step_count = 4, publication_mask = 0b01},
			{steps = {.Job_1, .Job_0, .Result_1, .Crash, .Crash}, step_count = 4, publication_mask = 0b10},
			{steps = {.Job_0, .Job_1, .Result_1, .Result_0, .Crash}, step_count = 5, publication_mask = 0b11},
			{steps = {.Job_1, .Job_0, .Result_0, .Result_1, .Crash}, step_count = 5, publication_mask = 0b11},
		}
		for test_case in cases do sim_multi_worker_compaction_crash_case(t, test_case)
	}

	@(test)
	test_simulation_two_worker_compaction_issuance_is_owner_local_under_global_ranks :: proc(t: ^testing.T) {
		cases := [?]Sim_Multi_Worker_Compaction_Issuance_Case {
			{
				steps = {.Issue_0, .Fsync_1, .Receive_1, .Receive_1, .Issue_1, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash},
				step_count = 6,
				issuance_mask = 0b11,
			},
			{
				steps = {.Issue_1, .Fsync_0, .Receive_0, .Receive_0, .Issue_0, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash},
				step_count = 6,
				issuance_mask = 0b11,
			},
			{
				steps = {.Fsync_1, .Receive_1, .Receive_1, .Issue_0, .Issue_1, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash},
				step_count = 6,
				issuance_mask = 0b11,
			},
			{steps = {.Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash}, step_count = 1, issuance_mask = 0b00},
			{steps = {.Issue_0, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash, .Crash}, step_count = 2, issuance_mask = 0b01},
		}
		for test_case in cases do sim_multi_worker_compaction_issuance_case(t, test_case)
	}

	@(test)
	test_simulation_two_worker_issued_compaction_rebases_over_owner_later_rotation :: proc(t: ^testing.T) {
		cases := [?]Sim_Multi_Worker_Compaction_Issuance_Case {
			{
				steps = {.Issue_0, .Issue_1, .Job_0, .Fsync_0, .Rotate_0, .Job_1, .Result_1, .Result_0, .Fsync_1, .Crash, .Crash, .Crash},
				step_count = 10,
				issuance_mask = 0b11,
				publication_mask = 0b11,
				recover = true,
			},
			{
				steps = {.Issue_1, .Issue_0, .Job_1, .Fsync_1, .Rotate_1, .Job_0, .Result_0, .Result_1, .Fsync_0, .Crash, .Crash, .Crash},
				step_count = 10,
				issuance_mask = 0b11,
				publication_mask = 0b11,
				recover = true,
			},
		}
		for test_case in cases do sim_multi_worker_compaction_issuance_case(t, test_case)
	}

	@(test)
	test_generated_two_worker_intermediate_asset_prefix_recovers :: proc(t: ^testing.T) {
		semantic_ops: [SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op
		semantic_op_counts := [SIM_MULTI_WORKER_COUNT]int{1, 1}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			semantic_ops[worker_index][0] = {
				kind = .Create_Task,
			}
		}
		mutations := [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation{.Create_Asset_Edge, .Create_Asset_Edge}
		intermediate_durable := [SIM_MULTI_WORKER_COUNT]bool{true, true}
		fsync_error_attempts := [SIM_MULTI_WORKER_COUNT]int{-1, -1}
		rank_choices: [20]u8
		recovered_intermediate := false
		for crash_after in 0 ..= len(rank_choices) {
			campaign: Sim_Multi_Worker_Generated_Campaign
			reason := sim_multi_worker_generated_campaign_begin(
				&campaign,
				&semantic_ops,
				semantic_op_counts,
				mutations,
				intermediate_durable,
				fsync_error_attempts,
			)
			if reason == "" {
				reason = sim_multi_worker_generated_campaign_run(&campaign, crash_after, rank_choices[:], nil)
			}
			if reason != "" {
				testing.expect_value(t, reason, "")
				sim_multi_worker_generated_campaign_end(&campaign)
				return
			}
			recovered_intermediate = campaign.recovered_intermediate[0] || campaign.recovered_intermediate[1]
			sim_multi_worker_generated_campaign_end(&campaign)
			if recovered_intermediate do break
		}
		testing.expect(t, recovered_intermediate, "a fixed schedule should recover an intermediate asset-only durable prefix")
	}

	@(test)
	test_generated_two_worker_fsync_error_preserves_peer_durable_prefix :: proc(t: ^testing.T) {
		semantic_ops: [SIM_MULTI_WORKER_COUNT][4]Generated_Shard_Op
		semantic_op_counts := [SIM_MULTI_WORKER_COUNT]int{1, 1}
		for worker_index in 0 ..< SIM_MULTI_WORKER_COUNT {
			semantic_ops[worker_index][0] = {
				kind = .Create_Task,
			}
		}
		mutations := [SIM_MULTI_WORKER_COUNT]Sim_Multi_Worker_WebSocket_Mutation{.Update_Task, .Update_Task}
		intermediate_durable: [SIM_MULTI_WORKER_COUNT]bool
		fsync_error_cases := [2][SIM_MULTI_WORKER_COUNT]int{{0, -1}, {-1, 0}}
		rank_prefixes := [2][2]u8{{128, 0}, {0, 103}}
		previous_logger := context.logger
		context.logger = log.nil_logger()

		for case_index in 0 ..< len(fsync_error_cases) {
			rank_choices: [20]u8
			rank_choices[0] = rank_prefixes[case_index][0]
			rank_choices[1] = rank_prefixes[case_index][1]
			campaign: Sim_Multi_Worker_Generated_Campaign
			reason := sim_multi_worker_generated_campaign_begin(
				&campaign,
				&semantic_ops,
				semantic_op_counts,
				mutations,
				intermediate_durable,
				fsync_error_cases[case_index],
			)
			if reason == "" {
				reason = sim_multi_worker_generated_campaign_run(&campaign, 0, rank_choices[:], nil, rank_process_crash = true)
			}
			failed_worker := case_index
			successful_worker := 1 - case_index
			context.logger = previous_logger
			testing.expect_value(t, reason, "")
			testing.expect(t, campaign.fatal_error_observed, "fsync failure should terminate the process incarnation")
			testing.expect(t, campaign.fsync_error_observed[failed_worker], "selected worker fsync failure should be observed")
			testing.expect_value(t, campaign.fsync_attempt_counts[failed_worker], 1)
			testing.expect_value(t, campaign.durable_epochs[failed_worker], 0)
			testing.expect_value(t, campaign.fsync_attempt_counts[successful_worker], 1)
			testing.expect_value(t, campaign.durable_epochs[successful_worker], 1)
			context.logger = log.nil_logger()
			sim_multi_worker_generated_campaign_end(&campaign)
		}
		context.logger = previous_logger
	}

	@(test)
	test_hegel_generated_two_worker_global_event_schedules :: proc(t: ^testing.T) {
		if !hgl.can_run() do return
		previous_logger := context.logger
		context.logger = log.nil_logger()
		result, err := hgl.run(prop_generated_two_worker_global_event_schedule, nil, {test_cases = 96})
		context.logger = previous_logger
		testing.expectf(t, err == nil, "generated two-worker event campaign failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}
