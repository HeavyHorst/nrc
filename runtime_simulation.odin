//
// runtime_simulation.odin - Deterministic simulation runtime support
//
// This file contains simulation-only implementations behind NRC_SIMULATION.
// Production-facing seams stay in runtime.odin so handlers depend on one stable
// boundary while simulation builds can intercept environmental effects here.
//
package main

import "core:mem"
import "core:net"
import "core:os"
import "core:sys/linux"
import "core:time"

import nbio_raw "nbio"
import nbio "nbio/poly"
import "persistence"
import "storage_io"
import ws "websocket"

when !NRC_SIMULATION {
	_ :: mem.ptr_to_bytes
	_ :: net.TCP_Socket
	_ :: os.Error
	_ :: linux.Errno
	_ :: time.Duration
	_ :: nbio_raw.MAX_USER_ARGUMENTS
	_ :: nbio.Completion
	_ :: persistence.wal_write_with_test_faults
	_ :: storage_io.Context
	_ :: ws.readFrameHeader
}

when NRC_SIMULATION {
	NRC_SIM_TIME_EPOCH_NANOS :: i64(4_000_000_000_000)

	Sim_Event_Domain :: enum u8 {
		Timer,
		Send,
		Shutdown_Send,
		Receive,
		Close,
		Fsync,
		Compaction_Job,
		Compaction_Result,
		Driver_Action,
		Process_Crash,
		File_Read,
		File_Write,
		Input_Turn,
	}

	Sim_Event_Target_Kind :: enum u8 {
		Process,
		Worker,
		Connection,
		Storage,
	}

	Sim_Event_Target :: struct {
		kind: Sim_Event_Target_Kind,
		id:   u64,
	}

	Sim_Timer_Callback :: proc(completion: rawptr)

	Sim_Timer_Event :: struct {
		completion: ^nbio.Completion,
		callback:   Sim_Timer_Callback,
	}

	Sim_Compaction_Job_Event :: struct {
		job: Shard_Compaction_Job,
	}

	Sim_Compaction_Result_Event :: struct {
		result: Shard_Compaction_Result,
	}

	Sim_Process_Crash_Event :: struct {}
	Sim_Input_Turn_Event :: struct {}
	Sim_Input_Key :: struct {
		worker_index: int,
		handle:       Connection_Handle,
	}

	Sim_Driver_Action_Callback :: proc(user: rawptr)

	Sim_Driver_Action_Event :: struct {
		user:     rawptr,
		callback: Sim_Driver_Action_Callback,
	}

	Sim_Event_Payload :: union {
		Sim_Timer_Event,
		Sim_Send_Completion,
		Sim_Shutdown_Send_Event,
		Sim_Receive_Event,
		Sim_Close_Event,
		Sim_Fsync_Completion,
		Sim_Compaction_Job_Event,
		Sim_Compaction_Result_Event,
		Sim_Driver_Action_Event,
		Sim_Process_Crash_Event,
		Sim_File_Read_Completion,
		Sim_File_Write_Completion,
		Sim_Input_Turn_Event,
	}

	Sim_Event :: struct {
		id:                  u64,
		after_event_id:      u64,
		ready_at:            time.Duration,
		process_incarnation: u64,
		worker_index:        int,
		target:              Sim_Event_Target,
		domain:              Sim_Event_Domain,
		payload:             Sim_Event_Payload,
	}

	Sim_Worker_Enter_Proc :: proc(user: rawptr, worker_index: int)
	Sim_Worker_Leave_Proc :: proc(user: rawptr)

	Sim_World :: struct {
		process_incarnation:  u64,
		now:                  time.Duration,
		next_event_id:        u64,
		events:               [dynamic]Sim_Event,
		callback_wave_active: bool,
		blocked_input:        map[Sim_Input_Key]bool,
		storage:              storage_io.Virtual_FS,
		worker_context:       rawptr,
		worker_enter:         Sim_Worker_Enter_Proc,
		worker_leave:         Sim_Worker_Leave_Proc,
	}

	sim_world_init :: proc(world: ^Sim_World) -> bool {
		if world == nil do return false
		world^ = {}
		if !storage_io.virtual_fs_init(&world.storage) do return false
		world.process_incarnation = world.storage.incarnation
		world.events = make([dynamic]Sim_Event, 0, 16)
		world.blocked_input = make(map[Sim_Input_Key]bool)
		return true
	}

	sim_world_destroy :: proc(world: ^Sim_World) {
		if world == nil do return
		for event in world.events do sim_world_discard_event(world, event)
		delete(world.events)
		delete(world.blocked_input)
		storage_io.virtual_fs_destroy(&world.storage)
		world^ = {}
	}

	sim_world_set_worker_switch_hooks :: proc(world: ^Sim_World, user: rawptr, enter: Sim_Worker_Enter_Proc, leave: Sim_Worker_Leave_Proc) {
		assert(world != nil)
		assert((enter == nil) == (leave == nil), "simulation worker switch hooks must be installed as a pair")
		world.worker_context = user
		world.worker_enter = enter
		world.worker_leave = leave
	}

	sim_world_storage_context :: proc(world: ^Sim_World) -> storage_io.Context {
		if world == nil do return {}
		return storage_io.virtual_context(&world.storage)
	}

	sim_world_crash :: proc(world: ^Sim_World, torn_path: string = "", persist_unsynced_prefix: int = 0) {
		if world == nil do return
		storage_io.virtual_fs_crash(&world.storage, torn_path, persist_unsynced_prefix)
		world.process_incarnation = world.storage.incarnation
	}

	nrc_sim_process_crash_discard_connections :: proc(sim: ^Sim_Runtime, conns: []^NRC_Connection, world_already_crashed: bool = false) -> bool {
		if sim == nil do return false
		// Callers retain these pointers through stale-event and subsystem cleanup.
		// A completed close may be reclaimed by the final context unpin, so that
		// lifecycle must be handled by its close/reuse campaign instead.
		for conn in conns do if conn == nil || conn.close_completed do return false
		if !world_already_crashed {
			sim_world_crash(&sim.world)
		} else {
			for event in sim.world.events do if event.process_incarnation == sim.world.process_incarnation do return false
		}
		for len(sim.world.events) > 0 {
			if !sim_world_run_next_event(&sim.world) do return false
		}
		if len(sim.world.events) != 0 do return false
		retained_message_discard_speculative_process_state(&td.message_stores)
		discard_deferred_input()
		discard_deferred_outbox_pumps()
		for handle in td.inflight_send_handles {
			if conn := connection_get_by_handle(handle); conn != nil {
				conn.send_watchdog_slot = 0
				conn.is_sending = false
				conn.send_started_at = {}
			}
		}
		clear(&td.inflight_send_handles)
		td.next_send_watchdog_at = {}
		for conn in conns {
			if conn == nil || conn.pending_io != 0 do return false
			send_queue_drain(conn)
		}
		return true
	}

	sim_event_payload_destroy :: proc(payload: Sim_Event_Payload) {
		#partial switch value in payload {
		case Sim_Timer_Event:
		case Sim_Send_Completion:
			sim_send_completion_discard(value)
		case Sim_Shutdown_Send_Event:
			connection_io_unpin(value.ctx)
			if value.discard != nil do value.discard(value.user)
		case Sim_Receive_Event:
			delete(value.buf)
			connection_io_unpin(value.ctx)
		case Sim_Close_Event:
			connection_io_unpin(value.ctx)
		case Sim_Fsync_Completion:
			snapshot := value.snapshot
			storage_io.destroy_sync_snapshot(&snapshot)
		case Sim_Compaction_Job_Event:
			job := value.job
			destroy_shard_compaction_job(&job)
		case Sim_Compaction_Result_Event:
			result := value.result
			destroy_shard_compaction_result(&result, false)
		case Sim_Driver_Action_Event:
		case Sim_Process_Crash_Event:
		case Sim_File_Read_Completion:
			if value.discard != nil do value.discard(value.user)
		case Sim_File_Write_Completion:
		// Borrowed batch only. Crash teardown releases its owner; never call
		// a stale write callback or touch its old-process bytes here.
		}
	}

	sim_world_enter_event_worker :: #force_inline proc(world: ^Sim_World, event: Sim_Event) -> bool {
		// Negative ownership denotes process/driver work that has no worker TLS.
		if world.worker_enter == nil || event.worker_index < 0 do return false
		world.worker_enter(world.worker_context, event.worker_index)
		return true
	}

	sim_world_leave_event_worker :: #force_inline proc(world: ^Sim_World, entered: bool) {
		if entered do world.worker_leave(world.worker_context)
	}

	sim_world_discard_event :: proc(world: ^Sim_World, event: Sim_Event) {
		entered := sim_world_enter_event_worker(world, event)
		sim_event_payload_destroy(event.payload)
		sim_world_leave_event_worker(world, entered)
	}

	sim_world_enqueue_event :: proc(
		world: ^Sim_World,
		ready_at: time.Duration,
		target: Sim_Event_Target,
		domain: Sim_Event_Domain,
		payload: Sim_Event_Payload,
		after_event_id: u64 = 0,
		worker_index: Maybe(int) = nil,
	) -> u64 {
		if world == nil || world.next_event_id == max(u64) {
			sim_event_payload_destroy(payload)
			assert(false, "simulation event queue unavailable or event ID exhausted")
			return 0
		}
		event_id := world.next_event_id + 1
		owner_worker := td.thread_index
		if value, present := worker_index.?; present do owner_worker = value
		if owner_worker < 0 {
			_, process_crash := payload.(Sim_Process_Crash_Event)
			assert(owner_worker == -1 && domain == .Process_Crash && target.kind == .Process && process_crash, "only process-crash events may be workerless")
		}
		_, append_err := append(
			&world.events,
			Sim_Event {
				id = event_id,
				after_event_id = after_event_id,
				ready_at = ready_at,
				process_incarnation = world.process_incarnation,
				worker_index = owner_worker,
				target = target,
				domain = domain,
				payload = payload,
			},
		)
		if append_err != nil {
			sim_event_payload_destroy(payload)
			assert(false, "simulation event queue allocation failed")
			return 0
		}
		world.next_event_id = event_id
		return event_id
	}

	sim_world_enqueue_process_crash :: proc(world: ^Sim_World, ready_at: time.Duration) -> u64 {
		if world == nil do return 0
		return sim_world_enqueue_event(
			world,
			ready_at,
			{kind = .Process, id = world.process_incarnation},
			.Process_Crash,
			Sim_Event_Payload(Sim_Process_Crash_Event{}),
			worker_index = -1,
		)
	}

	sim_world_enqueue_driver_action :: proc(world: ^Sim_World, user: rawptr, callback: Sim_Driver_Action_Callback, after_event_id: u64 = 0) -> u64 {
		owner_worker := td.thread_index
		if world == nil || callback == nil || owner_worker < 0 do return 0
		return sim_world_enqueue_event(
			world,
			world.now,
			{kind = .Worker, id = u64(owner_worker)},
			.Driver_Action,
			Sim_Event_Payload(Sim_Driver_Action_Event{user = user, callback = callback}),
			after_event_id,
			worker_index = owner_worker,
		)
	}

	sim_world_event_count :: proc(world: ^Sim_World, domain: Sim_Event_Domain) -> int {
		if world == nil do return 0
		count := 0
		for event in world.events do if event.domain == domain do count += 1
		return count
	}

	sim_world_domain_event_index :: proc(world: ^Sim_World, domain: Sim_Event_Domain, ordinal: int) -> int {
		if world == nil || ordinal < 0 do return -1
		previous_id: u64
		for position in 0 ..= ordinal {
			selected_index := -1
			selected_id := max(u64)
			for event, index in world.events {
				if event.domain != domain || event.id <= previous_id || event.id >= selected_id do continue
				selected_index = index
				selected_id = event.id
			}
			if selected_index < 0 do return -1
			if position == ordinal do return selected_index
			previous_id = selected_id
		}
		return -1
	}

	sim_world_cancel_event :: proc(world: ^Sim_World, event_id: u64) -> bool {
		if world == nil || event_id == 0 do return false
		for event, index in world.events {
			if event.id != event_id do continue
			for &candidate in world.events {
				if candidate.after_event_id == event_id {
					candidate.after_event_id = event.after_event_id
				}
			}
			#partial switch payload in event.payload {
			case Sim_Compaction_Job_Event:
				if payload.job.active_reservation_generation != 0 {
					remove_shard_active_reservation(payload.job.storage, payload.job.shard_dir, payload.job.active_reservation_generation)
				}
			}
			sim_world_discard_event(world, event)
			ordered_remove(&world.events, index)
			return true
		}
		return false
	}

	sim_world_enqueue_compaction_result :: proc(world: ^Sim_World, result: Shard_Compaction_Result) -> u64 {
		if world == nil do return 0
		return sim_world_enqueue_event(
			world,
			world.now,
			{kind = .Worker, id = u64(result.owner_worker)},
			.Compaction_Result,
			Sim_Event_Payload(Sim_Compaction_Result_Event{result = result}),
		)
	}

	sim_world_take_compaction_result_for_test :: proc(world: ^Sim_World, ordinal: int = 0) -> (Shard_Compaction_Result, bool) {
		index := sim_world_domain_event_index(world, .Compaction_Result, ordinal)
		if index < 0 do return {}, false
		payload, ok := world.events[index].payload.(Sim_Compaction_Result_Event)
		if !ok do return {}, false
		ordered_remove(&world.events, index)
		return payload.result, true
	}

	sim_run_shard_compaction_job :: proc(job: Shard_Compaction_Job) -> Shard_Compaction_Result {
		// Production compaction runs on its own thread and therefore owns separate
		// replay TLS. Preserve the owner worker's live semantic state while the
		// deterministic kernel executes the background job on this thread.
		owner_workspaces := td.workspaces
		owner_workspace_intern := td.workspace_intern
		owner_message_scan := message_scan_context
		td.workspaces = nil
		td.workspace_intern = {}
		message_scan_context = {}
		defer {
			td.workspaces = owner_workspaces
			td.workspace_intern = owner_workspace_intern
			message_scan_context = owner_message_scan
		}
		return run_shard_compaction_job(job)
	}

	sim_world_event_dependency_pending :: proc(world: ^Sim_World, event: Sim_Event) -> bool {
		if event.process_incarnation == world.process_incarnation {
			if receive, ok := event.payload.(Sim_Receive_Event); ok && receive.err == nil && receive.received > 0 {
				if world.blocked_input[{event.worker_index, receive.ctx.handle}] do return true
			}
		}
		if event.after_event_id == 0 do return false
		for candidate in world.events {
			if candidate.id == event.after_event_id do return true
		}
		return false
	}

	sim_world_prepare_runnable :: proc(world: ^Sim_World, domain: Maybe(Sim_Event_Domain) = nil) -> int {
		if world == nil || world.callback_wave_active do return 0
		minimum_ready := time.Duration(max(i64))
		for event in world.events {
			if sim_world_event_dependency_pending(world, event) do continue
			minimum_ready = min(minimum_ready, event.ready_at)
		}
		if len(world.events) == 0 || minimum_ready == time.Duration(max(i64)) do return 0
		if minimum_ready > world.now do world.now = minimum_ready
		count := 0
		for event in world.events {
			if value, has_domain := domain.?; has_domain && event.domain != value do continue
			if event.ready_at <= world.now && !sim_world_event_dependency_pending(world, event) do count += 1
		}
		return count
	}

	sim_world_runnable_rank_index :: proc(world: ^Sim_World, rank: int, domain: Maybe(Sim_Event_Domain) = nil) -> int {
		if world == nil || rank < 0 do return -1
		previous_ready := time.Duration(min(i64))
		previous_id: u64
		for position in 0 ..= rank {
			selected_index := -1
			selected_ready := time.Duration(max(i64))
			selected_id := max(u64)
			for event, index in world.events {
				if value, has_domain := domain.?; has_domain && event.domain != value do continue
				if sim_world_event_dependency_pending(world, event) ||
				   event.ready_at > world.now ||
				   event.ready_at < previous_ready ||
				   (event.ready_at == previous_ready && event.id <= previous_id) ||
				   event.ready_at > selected_ready ||
				   (event.ready_at == selected_ready && event.id >= selected_id) {
					continue
				}
				selected_index = index
				selected_ready = event.ready_at
				selected_id = event.id
			}
			if selected_index < 0 do return -1
			if position == rank do return selected_index
			previous_ready = selected_ready
			previous_id = selected_id
		}
		return -1
	}

	sim_event_is_io_callback :: #force_inline proc(domain: Sim_Event_Domain) -> bool {
		switch domain {
		case .Timer, .Send, .Shutdown_Send, .Receive, .Close, .Fsync, .File_Read, .File_Write:
			return true
		case .Compaction_Job, .Compaction_Result, .Driver_Action, .Process_Crash, .Input_Turn:
			return false
		}
		return false
	}

	sim_world_dispatch_event_payload :: proc(world: ^Sim_World, event: Sim_Event) {
		#partial switch payload in event.payload {
		case Sim_Timer_Event:
			payload.callback(payload.completion)
		case Sim_Send_Completion:
			nrc_sim_execute_send_completion(payload)
		case Sim_Shutdown_Send_Event:
			payload.callback(payload.user, payload.err)
		case Sim_Receive_Event:
			on_recv_websocket_fixed(payload.ctx, payload.received, payload.buf, payload.endpoint, payload.err)
			delete(payload.buf)
		case Sim_Input_Turn_Event:
			world.callback_wave_active = true
			defer {world.callback_wave_active = false}
			begin_input_turn()
			begin_presence_batch_wave()
			_, _ = worker_finish_callback_wave()
		case Sim_Close_Event:
			payload.callback(payload.ctx, payload.shutdown, true)
		case Sim_Fsync_Completion:
			err := payload.err
			snapshot := payload.snapshot
			if err == .NONE && storage_io.commit_sync_snapshot(&snapshot) != nil do err = .EIO
			payload.callback(payload.user, err)
			storage_io.destroy_sync_snapshot(&snapshot)
		case Sim_Compaction_Job_Event:
			result := sim_run_shard_compaction_job(payload.job)
			if result.message_remove_generation != 0 {
				destroy_shard_compaction_result(&result, true)
			} else {
				_ = sim_world_enqueue_compaction_result(world, result)
			}
		case Sim_Compaction_Result_Event:
			_ = process_shard_compaction_result(payload.result)
		case Sim_Driver_Action_Event:
			payload.callback(payload.user)
		case Sim_Process_Crash_Event:
			sim_world_crash(world)
		case Sim_File_Write_Completion:
			completion := payload
			sim_file_write_apply(&completion)
			completion.callback(completion.user, completion.written, completion.err)
		case Sim_File_Read_Completion:
			read := 0
			err := payload.err
			if err == .NONE {
				if payload.offset > u64(max(int)) {
					err = .EOVERFLOW
				} else {
					read_err: os.Error
					read, read_err = storage_io.read_at(payload.file, payload.buf, int(payload.offset))
					if read_err != nil {
						read = 0
						err = .EIO
					}
				}
			}
			payload.callback(payload.user, read, err)
		}
	}

	// Dispatch an explicit set of already-runnable completions as one io_uring
	// callback wave. Events created by these callbacks cannot be selected until
	// the entire wave finishes and the worker publishes retained writes and
	// deferred normal outboxes at the production post-tick boundary.
	sim_world_dispatch_callback_wave :: proc(world: ^Sim_World, event_ids: []u64) -> bool {
		if world == nil || world.callback_wave_active || len(event_ids) == 0 do return false
		worker_index := -1
		for event_id, position in event_ids {
			if event_id == 0 do return false
			for prior in event_ids[:position] do if prior == event_id do return false
			found := false
			for event in world.events {
				if event.id != event_id do continue
				if event.process_incarnation != world.process_incarnation ||
				   event.ready_at > world.now ||
				   sim_world_event_dependency_pending(world, event) ||
				   !sim_event_is_io_callback(event.domain) {
					return false
				}
				if worker_index < 0 {
					worker_index = event.worker_index
				} else if event.worker_index != worker_index {
					return false
				}
				found = true
				break
			}
			if !found do return false
		}

		claimed_events, alloc_err := make([]Sim_Event, len(event_ids))
		if alloc_err != nil do return false
		defer delete(claimed_events)
		for event_id, position in event_ids {
			index := -1
			for event, event_index in world.events {
				if event.id == event_id {
					index = event_index
					break
				}
			}
			assert(index >= 0, "validated callback-wave event disappeared before claim")
			claimed_events[position] = world.events[index]
			ordered_remove(&world.events, index)
		}

		world.callback_wave_active = true
		defer {world.callback_wave_active = false}
		if world.worker_enter != nil do world.worker_enter(world.worker_context, worker_index)
		defer if world.worker_leave != nil do world.worker_leave(world.worker_context)
		begin_input_turn()
		begin_presence_batch_wave()
		for event in claimed_events do sim_world_dispatch_event_payload(world, event)
		_, ok := worker_finish_callback_wave()
		return ok
	}

	sim_world_dispatch_event :: proc(world: ^Sim_World, index: int) -> bool {
		if world == nil || world.callback_wave_active || index < 0 || index >= len(world.events) do return false
		event := world.events[index]
		if sim_world_event_dependency_pending(world, event) do return false
		ordered_remove(&world.events, index)
		entered := sim_world_enter_event_worker(world, event)
		defer sim_world_leave_event_worker(world, entered)
		if event.process_incarnation != world.process_incarnation {
			sim_event_payload_destroy(event.payload)
			return true
		}
		sim_world_dispatch_event_payload(world, event)
		return true
	}

	sim_world_run_runnable_rank :: proc(world: ^Sim_World, rank: int, domain: Maybe(Sim_Event_Domain) = nil) -> bool {
		count := sim_world_prepare_runnable(world, domain)
		if rank < 0 || rank >= count do return false
		return sim_world_dispatch_event(world, sim_world_runnable_rank_index(world, rank, domain))
	}

	sim_world_run_next_event :: proc(world: ^Sim_World) -> bool {
		return sim_world_run_runnable_rank(world, 0)
	}

	Sim_Client :: struct {
		sock:               net.TCP_Socket,
		inbox:              [dynamic][]u8,
		inbox_submitted_at: [dynamic]time.Time,
	}

	Sim_Send_Completion_Kind :: enum {
		Queued_Send,
		Writev,
	}

	Sim_Send_Completion :: struct {
		kind:        Sim_Send_Completion_Kind,
		sock:        net.TCP_Socket,
		item:        Send_Item,
		batch_state: ^Batch_Send_State,
		sent:        int,
		err:         net.Network_Error,
		continues:   bool,
		final_sent:  int,
		final_err:   net.Network_Error,
	}

	Sim_Receive_Event :: struct {
		ctx:      Connection_IO_Context,
		received: int,
		buf:      []byte,
		endpoint: Maybe(net.Endpoint),
		err:      net.Network_Error,
	}

	Sim_Shutdown_Send_Event :: struct {
		ctx:      Connection_IO_Context,
		user:     rawptr,
		callback: proc(user: rawptr, err: net.Shutdown_Error),
		discard:  proc(user: rawptr),
		err:      net.Shutdown_Error,
	}

	Sim_Close_Event :: struct {
		ctx:      Connection_IO_Context,
		shutdown: bool,
		callback: proc(ctx: Connection_IO_Context, shutdown: bool, ok: bool),
	}

	Sim_Fsync_Completion :: struct {
		user:     rawptr,
		callback: nbio_raw.On_File_Sync,
		err:      linux.Errno,
		snapshot: storage_io.Sync_Snapshot,
	}

	Sim_File_Read_Completion :: struct {
		file:     ^storage_io.File,
		buf:      []byte,
		offset:   u64,
		user:     rawptr,
		callback: nbio_raw.On_File_Read,
		discard:  proc(user: rawptr),
		err:      linux.Errno,
	}

	Sim_Runtime :: struct {
		clients:                         map[net.TCP_Socket]^Sim_Client,
		world:                           Sim_World,
		timer_completions:               [dynamic]^nbio.Completion,
		next_queued_send_error:          net.Network_Error,
		next_writev_error:               net.Network_Error,
		next_queued_send_partial:        int,
		next_writev_partial:             int,
		compaction_job_event_submission: bool,
	}

	Sim_File_Write_Completion :: struct {
		file:     ^storage_io.File,
		buf:      []byte,
		user:     rawptr,
		callback: nbio_raw.On_File_Write,
		err:      linux.Errno,
		applied:  bool,
		written:  int,
	}

	// Separate kernel append from callback delivery for crash interleavings.
	sim_file_write_apply :: proc(completion: ^Sim_File_Write_Completion) {
		if completion.applied do return
		completion.applied = true
		if completion.err != .NONE do return
		err: os.Error
		completion.written, err = persistence.wal_write_with_test_faults(completion.file, completion.buf)
		if err != nil do completion.err = .EIO
	}

	nrc_sim_apply_next_file_write :: proc(sim: ^Sim_Runtime) -> bool {
		index := sim_world_domain_event_index(&sim.world, .File_Write, 0)
		if index < 0 do return false
		completion := sim.world.events[index].payload.(Sim_File_Write_Completion)
		sim_file_write_apply(&completion)
		sim.world.events[index].payload = Sim_Event_Payload(completion)
		return true
	}

	nrc_sim_capture_wal_append :: proc(sim: ^Sim_Runtime, file: ^storage_io.File, buf: []byte, user: rawptr, callback: nbio_raw.On_File_Write) {
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Storage},
			.File_Write,
			Sim_Event_Payload(Sim_File_Write_Completion{file = file, buf = buf, user = user, callback = callback}),
		)
	}

	nrc_sim_run_next_file_write :: proc(sim: ^Sim_Runtime, err: linux.Errno = .NONE) -> bool {
		index := sim_world_domain_event_index(&sim.world, .File_Write, 0)
		if index < 0 do return false
		completion := sim.world.events[index].payload.(Sim_File_Write_Completion)
		if err != .NONE do completion.err = err
		sim.world.events[index].payload = Sim_Event_Payload(completion)
		return sim_world_dispatch_event(&sim.world, index)
	}

	@(thread_local)
	nrc_sim_runtime: ^Sim_Runtime

	nrc_sim_runtime_init :: proc(sim: ^Sim_Runtime) {
		assert(sim_world_init(&sim.world), "simulation world initialization failed")
		sim.clients = make(map[net.TCP_Socket]^Sim_Client, 16)
		sim.timer_completions = make([dynamic]^nbio.Completion, 0, 16)
		nrc_sim_runtime = sim
	}

	nrc_sim_time_now :: #force_inline proc() -> time.Time {
		return time.Time{_nsec = NRC_SIM_TIME_EPOCH_NANOS + i64(nrc_sim_runtime.world.now)}
	}

	nrc_sim_runtime_destroy :: proc(sim: ^Sim_Runtime) {
		closed_err := net.TCP_Send_Error(.Connection_Closed)
		for nrc_sim_run_send_completion_at(sim, 0, closed_err) {}
		for nrc_sim_run_receive_at(sim, 0, net.TCP_Recv_Error(.Connection_Closed)) {}
		for {
			index := sim_world_domain_event_index(&sim.world, .Shutdown_Send, 0)
			if index < 0 do break
			_ = sim_world_cancel_event(&sim.world, sim.world.events[index].id)
		}
		nrc_sim_run_all_close_completions(sim)
		for nrc_sim_run_next_file_write(sim, .EIO) {}
		for nrc_sim_run_fsync_completion_at(sim, 0, .EIO) {}
		for nrc_sim_run_file_read_at(sim, 0, .EIO) {}
		for _, client in sim.clients {
			for frame in client.inbox {
				delete(frame)
			}
			delete(client.inbox)
			delete(client.inbox_submitted_at)
			free(client)
		}
		for completion in sim.timer_completions {
			if completion != nil {
				free(completion)
			}
		}
		sim_world_destroy(&sim.world)
		delete(sim.timer_completions)
		delete(sim.clients)
		if nrc_sim_runtime == sim {
			nrc_sim_runtime = nil
		}
		sim^ = {}
	}

	nrc_sim_send_completion_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Send)
	}

	nrc_sim_send_completion_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> (Sim_Send_Completion, bool) {
		if sim == nil do return {}, false
		index := sim_world_domain_event_index(&sim.world, .Send, ordinal)
		if index < 0 do return {}, false
		return sim.world.events[index].payload.(Sim_Send_Completion)
	}

	nrc_sim_execute_send_completion :: proc(completion: Sim_Send_Completion, override_err: net.Network_Error = nil) {
		err := completion.err
		sent := completion.sent
		if override_err != nil {
			err = override_err
			sent = 0
		} else if completion.continues {
			continuation := completion
			continuation.continues = false
			continuation.sent = completion.final_sent
			continuation.err = completion.final_err
			continuation.final_sent = 0
			continuation.final_err = nil
			nrc_sim_enqueue_send_completion(nrc_sim_runtime, continuation)
			return
		}

		switch completion.kind {
		case .Queued_Send:
			on_queued_send_complete(completion.sock, completion.item, sent, err)
		case .Writev:
			on_batch_send_complete(completion.sock, completion.batch_state, sent, err)
		}
	}

	nrc_sim_enqueue_send_completion :: proc(sim: ^Sim_Runtime, completion: Sim_Send_Completion) {
		_ = sim_world_enqueue_event(&sim.world, sim.world.now, {kind = .Connection, id = u64(completion.sock)}, .Send, Sim_Event_Payload(completion))
	}

	sim_send_completion_discard :: proc(completion: Sim_Send_Completion) {
		switch completion.kind {
		case .Queued_Send:
			item := completion.item
			frame_lease_dispose(&item.lease)
			connection_io_unpin({sock = completion.sock, handle = item.handle, pinned = item.io_pinned})
		case .Writev:
			state := completion.batch_state
			if state == nil do return
			io_ctx: Connection_IO_Context
			if state.count > 0 {
				io_ctx = {
					sock   = completion.sock,
					handle = state.items[0].handle,
					pinned = state.io_pinned,
				}
			}
			for index in 0 ..< state.count do frame_lease_dispose(&state.items[index].lease)
			free_batch_state(state)
			connection_io_unpin(io_ctx)
		}
	}

	nrc_sim_run_send_completion_at :: proc(sim: ^Sim_Runtime, ordinal: int, override_err: net.Network_Error = nil) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .Send, ordinal)
		if index < 0 do return false
		completion, ok := sim.world.events[index].payload.(Sim_Send_Completion)
		assert(ok)
		if !ok do return false
		if override_err != nil {
			completion.err = override_err
			completion.sent = 0
			completion.continues = false
			completion.final_sent = 0
			completion.final_err = nil
			sim.world.events[index].payload = Sim_Event_Payload(completion)
		}
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_next_send_completion :: proc(sim: ^Sim_Runtime) -> bool {
		return nrc_sim_run_send_completion_at(sim, 0)
	}

	nrc_sim_run_all_send_completions :: proc(sim: ^Sim_Runtime) {
		for nrc_sim_run_next_send_completion(sim) {}
	}

	nrc_sim_capture_close :: proc(
		sim: ^Sim_Runtime,
		ctx: Connection_IO_Context,
		shutdown: bool,
		callback: proc(ctx: Connection_IO_Context, shutdown: bool, ok: bool),
	) {
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Connection, id = u64(ctx.sock)},
			.Close,
			Sim_Event_Payload(Sim_Close_Event{ctx = ctx, shutdown = shutdown, callback = callback}),
		)
	}

	nrc_sim_capture_shutdown_send :: proc(
		sim: ^Sim_Runtime,
		ctx: Connection_IO_Context,
		user: rawptr,
		callback: proc(user: rawptr, err: net.Shutdown_Error),
		discard: proc(user: rawptr),
	) {
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Connection, id = u64(ctx.sock)},
			.Shutdown_Send,
			Sim_Event_Payload(Sim_Shutdown_Send_Event{ctx = ctx, user = user, callback = callback, discard = discard}),
		)
	}

	nrc_sim_shutdown_send_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Shutdown_Send)
	}

	nrc_sim_shutdown_send_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> (Sim_Shutdown_Send_Event, bool) {
		if sim == nil do return {}, false
		index := sim_world_domain_event_index(&sim.world, .Shutdown_Send, ordinal)
		if index < 0 do return {}, false
		return sim.world.events[index].payload.(Sim_Shutdown_Send_Event)
	}

	nrc_sim_run_shutdown_send_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .Shutdown_Send, ordinal)
		if index < 0 do return false
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_all_shutdown_sends :: proc(sim: ^Sim_Runtime) {
		for nrc_sim_run_shutdown_send_at(sim, 0) {}
	}

	nrc_sim_close_completion_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Close)
	}

	nrc_sim_close_event_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> (Sim_Close_Event, bool) {
		if sim == nil do return {}, false
		index := sim_world_domain_event_index(&sim.world, .Close, ordinal)
		if index < 0 do return {}, false
		return sim.world.events[index].payload.(Sim_Close_Event)
	}

	nrc_sim_run_close_completion_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .Close, ordinal)
		if index < 0 do return false
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_next_close_completion :: proc(sim: ^Sim_Runtime) -> bool {
		return nrc_sim_run_close_completion_at(sim, 0)
	}

	nrc_sim_run_all_close_completions :: proc(sim: ^Sim_Runtime) {
		for nrc_sim_run_next_close_completion(sim) {}
	}

	nrc_sim_capture_fsync :: proc(sim: ^Sim_Runtime, file: ^storage_io.File, user: rawptr, callback: nbio_raw.On_File_Sync) {
		snapshot, snapshot_err := storage_io.capture_sync_snapshot(file)
		err := linux.Errno.NONE
		if snapshot_err != nil do err = .EIO
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Storage},
			.Fsync,
			Sim_Event_Payload(Sim_Fsync_Completion{user = user, callback = callback, err = err, snapshot = snapshot}),
		)
	}

	nrc_sim_fsync_completion_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Fsync)
	}

	nrc_sim_run_fsync_completion_at :: proc(sim: ^Sim_Runtime, ordinal: int, err: linux.Errno = .NONE) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .Fsync, ordinal)
		if index < 0 do return false
		completion, ok := sim.world.events[index].payload.(Sim_Fsync_Completion)
		assert(ok)
		if !ok do return false
		if err != .NONE {
			completion.err = err
			sim.world.events[index].payload = Sim_Event_Payload(completion)
		}
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_next_fsync_completion :: proc(sim: ^Sim_Runtime, err: linux.Errno = .NONE) -> bool {
		return nrc_sim_run_fsync_completion_at(sim, 0, err)
	}

	nrc_sim_capture_file_read :: proc(
		sim: ^Sim_Runtime,
		file: ^storage_io.File,
		buf: []byte,
		offset: u64,
		user: rawptr,
		callback: nbio_raw.On_File_Read,
		discard: proc(user: rawptr),
	) {
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Storage},
			.File_Read,
			Sim_Event_Payload(Sim_File_Read_Completion{file = file, buf = buf, offset = offset, user = user, callback = callback, discard = discard}),
		)
	}

	nrc_sim_file_read_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .File_Read)
	}

	nrc_sim_run_file_read_at :: proc(sim: ^Sim_Runtime, ordinal: int, err: linux.Errno = .NONE) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .File_Read, ordinal)
		if index < 0 do return false
		completion, ok := sim.world.events[index].payload.(Sim_File_Read_Completion)
		assert(ok)
		if !ok do return false
		if err != .NONE {
			completion.err = err
			sim.world.events[index].payload = Sim_Event_Payload(completion)
		}
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_next_file_read :: proc(sim: ^Sim_Runtime, err: linux.Errno = .NONE) -> bool {
		return nrc_sim_run_file_read_at(sim, 0, err)
	}

	nrc_sim_schedule_input_turn :: proc(world: ^Sim_World) {
		for event in world.events {
			if event.domain == .Input_Turn && event.worker_index == td.thread_index && event.process_incarnation == world.process_incarnation do return
		}
		_ = sim_world_enqueue_event(world, world.now, {kind = .Worker}, .Input_Turn, Sim_Event_Payload(Sim_Input_Turn_Event{}))
	}

	nrc_sim_enqueue_receive :: proc(
		sim: ^Sim_Runtime,
		c: ^NRC_Connection,
		data: []byte,
		received: int = -1,
		err: net.Network_Error = nil,
		endpoint: Maybe(net.Endpoint) = nil,
	) -> bool {
		if sim == nil || c == nil {
			return false
		}
		actual_received := received
		if actual_received < 0 {
			actual_received = len(data)
		}
		if actual_received < 0 || actual_received > len(data) {
			return false
		}

		buf, alloc_err := make([]byte, actual_received)
		if alloc_err != nil {
			return false
		}
		copy(buf, data[:actual_received])
		if !connection_io_pin(c) {
			delete(buf)
			return false
		}
		after_event_id: u64
		for event in sim.world.events {
			if event.domain != .Receive do continue
			previous, ok := event.payload.(Sim_Receive_Event)
			if ok && event.worker_index == td.thread_index && previous.ctx.handle == c.handle && event.id > after_event_id {
				after_event_id = event.id
			}
		}
		_ = sim_world_enqueue_event(
			&sim.world,
			sim.world.now,
			{kind = .Connection, id = u64(c.sock)},
			.Receive,
			Sim_Event_Payload(
				Sim_Receive_Event {
					ctx = Connection_IO_Context{sock = c.sock, handle = c.handle, pinned = true},
					received = actual_received,
					buf = buf,
					endpoint = endpoint,
					err = err,
				},
			),
			after_event_id,
		)
		return true
	}

	nrc_sim_receive_event_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Receive)
	}

	nrc_sim_receive_event_at :: proc(sim: ^Sim_Runtime, ordinal: int) -> (Sim_Receive_Event, bool) {
		if sim == nil do return {}, false
		index := sim_world_domain_event_index(&sim.world, .Receive, ordinal)
		if index < 0 do return {}, false
		return sim.world.events[index].payload.(Sim_Receive_Event)
	}

	nrc_sim_run_receive_at :: proc(sim: ^Sim_Runtime, ordinal: int, override_err: net.Network_Error = nil) -> bool {
		if sim == nil do return false
		index := sim_world_domain_event_index(&sim.world, .Receive, ordinal)
		if index < 0 do return false
		event := sim.world.events[index]
		receive, ok := event.payload.(Sim_Receive_Event)
		assert(ok)
		if !ok do return false
		if override_err != nil {
			receive.err = override_err
			receive.received = 0
			event.payload = Sim_Event_Payload(receive)
		}
		if sim_world_event_dependency_pending(&sim.world, event) do return false
		sim.world.events[index] = event
		return sim_world_dispatch_event(&sim.world, index)
	}

	nrc_sim_run_next_receive :: proc(sim: ^Sim_Runtime) -> bool {
		return nrc_sim_run_receive_at(sim, 0)
	}

	nrc_sim_run_all_receives :: proc(sim: ^Sim_Runtime) {
		for nrc_sim_run_next_receive(sim) {}
	}

	nrc_sim_enqueue_timer :: proc(dur: time.Duration, completion: ^nbio.Completion, callback: Sim_Timer_Callback) {
		timer_id := sim_world_enqueue_event(
			&nrc_sim_runtime.world,
			nrc_sim_runtime.world.now + dur,
			{kind = .Process, id = nrc_sim_runtime.world.process_incarnation},
			.Timer,
			Sim_Event_Payload(Sim_Timer_Event{completion = completion, callback = callback}),
		)
		assert(timer_id != 0, "simulation event ID exhausted")
		completion.user_data = rawptr(uintptr(timer_id))
		append(&nrc_sim_runtime.timer_completions, completion)
	}

	nrc_sim_schedule_timer1 :: proc(dur: time.Duration, p: $T, callback: $C/proc(p: T)) -> ^nbio.Completion where size_of(T) <= nbio_raw.MAX_USER_ARGUMENTS {
		completion := new(nbio.Completion)
		callback, p := callback, p
		n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
		_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p))

		nrc_sim_enqueue_timer(dur, completion, proc(completion_raw: rawptr) {
			completion := (^nbio.Completion)(completion_raw)
			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			cb(p)
		})
		return completion
	}

	nrc_sim_schedule_timer2 :: proc(
		dur: time.Duration,
		p: $T,
		p2: $T2,
		callback: $C/proc(p: T, p2: T2),
	) -> ^nbio.Completion where size_of(T) + size_of(T2) <=
		nbio_raw.MAX_USER_ARGUMENTS {
		completion := new(nbio.Completion)
		callback, p, p2 := callback, p, p2
		n := copy(completion.user_args[:], mem.ptr_to_bytes(&callback))
		n += copy(completion.user_args[n:], mem.ptr_to_bytes(&p))
		_ = copy(completion.user_args[n:], mem.ptr_to_bytes(&p2))

		nrc_sim_enqueue_timer(dur, completion, proc(completion_raw: rawptr) {
			completion := (^nbio.Completion)(completion_raw)
			cb := (^C)(&completion.user_args[0])^
			p := (^T)(raw_data(completion.user_args[size_of(C):]))^
			p2 := (^T2)(raw_data(completion.user_args[size_of(C) + size_of(T):]))^
			cb(p, p2)
		})
		return completion
	}

	nrc_sim_timer_event_count :: proc(sim: ^Sim_Runtime) -> int {
		if sim == nil do return 0
		return sim_world_event_count(&sim.world, .Timer)
	}

	nrc_sim_cancel_timer :: proc(completion: ^nbio.Completion) {
		if completion == nil || nrc_sim_runtime == nil {
			return
		}

		timer_id := u64(uintptr(completion.user_data))
		_ = sim_world_cancel_event(&nrc_sim_runtime.world, timer_id)
	}

	nrc_sim_run_next_timer :: proc(sim: ^Sim_Runtime) -> bool {
		if sim == nil do return false
		return sim_world_run_runnable_rank(&sim.world, 0, Maybe(Sim_Event_Domain)(.Timer))
	}

	nrc_sim_run_all_timers :: proc(sim: ^Sim_Runtime) {
		for nrc_sim_run_next_timer(sim) {}
	}

	nrc_sim_register_client :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket) -> ^Sim_Client {
		if client := sim.clients[sock]; client != nil {
			// Registration denotes a new transport generation for this numeric
			// socket. Captured bytes belong to the prior peer and must not become
			// visible through the replacement connection's inbox.
			for frame in client.inbox do delete(frame)
			clear(&client.inbox)
			clear(&client.inbox_submitted_at)
			return client
		}

		client := new(Sim_Client)
		client.sock = sock
		client.inbox = make([dynamic][]u8, 0, 16)
		client.inbox_submitted_at = make([dynamic]time.Time, 0, 16)
		sim.clients[sock] = client
		return client
	}

	nrc_sim_has_client :: proc(sock: net.TCP_Socket) -> bool {
		if nrc_sim_runtime == nil {
			return false
		}
		return nrc_sim_runtime.clients[sock] != nil
	}

	nrc_sim_clear_captured_frames :: proc(sim: ^Sim_Runtime) {
		for _, client in sim.clients {
			for frame in client.inbox {
				delete(frame)
			}
			clear(&client.inbox)
			clear(&client.inbox_submitted_at)
		}
	}

	nrc_sim_clear_inboxes :: proc(sim: ^Sim_Runtime) {
		nrc_sim_run_all_send_completions(sim)
		nrc_sim_clear_captured_frames(sim)
	}

	nrc_sim_client_frame_count :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket) -> int {
		if client := sim.clients[sock]; client != nil {
			return len(client.inbox)
		}
		return 0
	}

	nrc_sim_client_frame :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, index: int) -> []u8 {
		if client := sim.clients[sock]; client != nil {
			if index >= 0 && index < len(client.inbox) {
				return client.inbox[index]
			}
		}
		return nil
	}

	nrc_sim_client_frame_submitted_at :: proc(sim: ^Sim_Runtime, sock: net.TCP_Socket, index: int) -> (time.Time, bool) {
		if client := sim.clients[sock]; client != nil {
			if index >= 0 && index < len(client.inbox_submitted_at) {
				return client.inbox_submitted_at[index], true
			}
		}
		return {}, false
	}

	nrc_sim_inject_next_queued_send_error :: proc(sim: ^Sim_Runtime, err: net.Network_Error) {
		if sim == nil {
			return
		}
		sim.next_queued_send_error = err
	}

	nrc_sim_inject_next_queued_send_partial :: proc(sim: ^Sim_Runtime, sent: int) {
		if sim == nil || sent <= 0 do return
		sim.next_queued_send_partial = sent
	}

	nrc_sim_inject_next_writev_error :: proc(sim: ^Sim_Runtime, err: net.Network_Error) {
		if sim == nil {
			return
		}
		sim.next_writev_error = err
	}

	nrc_sim_inject_next_writev_partial :: proc(sim: ^Sim_Runtime, sent: int) {
		if sim == nil || sent <= 0 do return
		sim.next_writev_partial = sent
	}

	nrc_sim_inject_next_close_frame_error :: proc(sim: ^Sim_Runtime, err: net.Network_Error) {
		nrc_sim_inject_next_queued_send_error(sim, err)
	}

	nrc_sim_frame_protocol_payload :: proc(frame: []u8) -> (payload: []u8, ok: bool) {
		if len(frame) < 2 {
			return nil, false
		}

		header, header_len, err := ws.readFrameHeader(frame)
		if err != nil {
			return nil, false
		}

		payload_len := int(header.payloadLength)
		if payload_len < 0 || len(frame) < header_len + payload_len {
			return nil, false
		}

		return frame[header_len:header_len + payload_len], true
	}

	nrc_sim_capture_queued_send :: proc(c: ^NRC_Connection, item: Send_Item) -> bool {
		if c == nil || c.state >= .Closing {
			return false
		}

		send_err := nrc_sim_runtime.next_queued_send_error
		nrc_sim_runtime.next_queued_send_error = nil
		partial_sent := nrc_sim_runtime.next_queued_send_partial
		nrc_sim_runtime.next_queued_send_partial = 0

		client := nrc_sim_runtime.clients[c.sock]
		if client == nil {
			return false
		}

		buf := frame_lease_data(item.lease)
		if partial_sent >= len(buf) do partial_sent = 0
		if send_err != nil && partial_sent == 0 {
			nrc_sim_enqueue_send_completion(nrc_sim_runtime, {kind = .Queued_Send, sock = c.sock, item = item, err = send_err})
			return true
		}
		if partial_sent > 0 {
			final_sent := len(buf)
			if send_err != nil do final_sent = partial_sent
			if send_err != nil {
				nrc_sim_enqueue_send_completion(
					nrc_sim_runtime,
					{kind = .Queued_Send, sock = c.sock, item = item, sent = partial_sent, continues = true, final_sent = final_sent, final_err = send_err},
				)
				return true
			}
		}
		frame, err := make([]u8, len(buf))
		if err != nil {
			return false
		}
		copy(frame, buf)
		if reserve(&client.inbox, len(client.inbox) + 1) != nil || reserve(&client.inbox_submitted_at, len(client.inbox_submitted_at) + 1) != nil {
			delete(frame)
			return false
		}
		append(&client.inbox, frame)
		append(&client.inbox_submitted_at, nrc_sim_time_now())

		if partial_sent > 0 {
			nrc_sim_enqueue_send_completion(
				nrc_sim_runtime,
				{kind = .Queued_Send, sock = c.sock, item = item, sent = partial_sent, continues = true, final_sent = len(buf)},
			)
		} else {
			nrc_sim_enqueue_send_completion(nrc_sim_runtime, {kind = .Queued_Send, sock = c.sock, item = item, sent = len(buf)})
		}
		return true
	}

	nrc_sim_capture_writev_all :: proc(c: ^NRC_Connection, state: ^Batch_Send_State) -> bool {
		if c == nil || c.state >= .Closing || state == nil {
			return false
		}

		send_err := nrc_sim_runtime.next_writev_error
		nrc_sim_runtime.next_writev_error = nil
		partial_sent := nrc_sim_runtime.next_writev_partial
		nrc_sim_runtime.next_writev_partial = 0

		client := nrc_sim_runtime.clients[c.sock]
		if client == nil {
			return false
		}

		total_sent := 0
		for i in 0 ..< state.count do total_sent += int(state.iovec[i].iov_len)
		if partial_sent >= total_sent do partial_sent = 0
		if send_err != nil {
			if partial_sent > 0 {
				nrc_sim_enqueue_send_completion(
					nrc_sim_runtime,
					{
						kind = .Writev,
						sock = c.sock,
						batch_state = state,
						sent = partial_sent,
						continues = true,
						final_sent = partial_sent,
						final_err = send_err,
					},
				)
			} else {
				nrc_sim_enqueue_send_completion(nrc_sim_runtime, {kind = .Writev, sock = c.sock, batch_state = state, err = send_err})
			}
			return true
		}

		frames := make([dynamic][]u8, 0, state.count)
		defer delete(frames)
		for i in 0 ..< state.count {
			vec := state.iovec[i]
			src: []u8
			if vec.iov_len > 0 {
				src = mem.slice_ptr((^u8)(vec.iov_base), int(vec.iov_len))
			}

			frame, err := make([]u8, len(src))
			if err != nil {
				for owned in frames do delete(owned)
				return false
			}
			copy(frame, src)
			append(&frames, frame)
		}
		if reserve(&client.inbox, len(client.inbox) + len(frames)) != nil ||
		   reserve(&client.inbox_submitted_at, len(client.inbox_submitted_at) + len(frames)) != nil {
			for frame in frames do delete(frame)
			return false
		}
		for frame in frames {
			append(&client.inbox, frame)
			append(&client.inbox_submitted_at, nrc_sim_time_now())
		}

		if partial_sent > 0 {
			nrc_sim_enqueue_send_completion(
				nrc_sim_runtime,
				{kind = .Writev, sock = c.sock, batch_state = state, sent = partial_sent, continues = true, final_sent = total_sent},
			)
		} else {
			nrc_sim_enqueue_send_completion(nrc_sim_runtime, {kind = .Writev, sock = c.sock, batch_state = state, sent = total_sent})
		}
		return true
	}

}
