package main

import "core:bytes"
import "core:log"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "storage_io"

when !NRC_SIMULATION {
	_ :: bytes.equal
	_ :: persistence.clear_wal_write_fault_for_test
	_ :: pr.SendMessageV2Request
	_ :: storage_io.make_directory
}

when !EXPERIMENT_ASYNC_MESSAGE_WRITE || NRC_SIMULATION {
	_ :: nbio.init
}

retained_async_test_queue_message :: proc(store: ^Message_Store, id: u64) {
	ctx := new(Retained_Dedup_Context)
	ctx.store = store
	ctx.message = test_retained_message("async-probe", 1, id, nrc_time_unix_nanos())
	ctx.message.workspace, _ = strings.clone("async-probe")
	ctx.message.sender_name, _ = strings.clone("alice")
	ctx.message.sender_principal, _ = strings.clone("alice-principal")
	ctx.message.content = make([]byte, 4096)
	retained_message_queue_append(ctx, false)
}

@(test)
test_retained_async_buffer_lease :: proc(t: ^testing.T) {
	when EXPERIMENT_ASYNC_MESSAGE_WRITE && !NRC_SIMULATION {
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE); defer nbio.destroy(&td.io)
		td.message_stores = {}; td.message_stores.enabled = true; td.message_stores.write_batch_records = 16
		dir := test_wal_path("async-buffer-lease"); defer os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil)
		store: Message_Store
		workspace := "async-probe"
		testing.expect(t, init_message_store(&store, dir, int(shard_for_workspace(transmute([]byte)workspace)), 24 * time.Hour, 0))
		defer {testing.expect(t, shutdown_message_store(&store)); td.message_stores = {}}
		for i in 0 ..< 16 do retained_async_test_queue_message(&store, u64(i + 1))
		_, ok := flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
		testing.expect(t, store.write_in_flight)
		testing.expect_value(t, store.wal.record_count, u64(0))
		frozen := store.wal.write_buffer
		retained_async_test_queue_message(&store, 17)
		testing.expect_value(t, store.wal.write_buffer, frozen)
		testing.expect_value(t, len(store.deferred_appends), 1)
		deadline := nrc_time_now()
		for store.wal.durable_record_count < 17 && time.since(deadline) < 10 * time.Second {
			_, ok = flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
			_ = schedule_retained_message_fsync(&store)
			_ = nbio.submit_pending(&td.io)
			_ = nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true)
		}
		testing.expect_value(t, store.wal.durable_record_count, u64(17))
		testing.expect_value(t, store.high_water, u64(17))
		testing.expect(t, !store.write_in_flight && !store.fsync_in_flight)
	}
}

when NRC_SIMULATION && EXPERIMENT_ASYNC_MESSAGE_WRITE {
	async_test_send :: proc(conn: ^NRC_Connection, id: u32) {
		req := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = id,
			content        = transmute([]byte)string("immutable batch"),
		}
		req.client_message_id[0] = byte(id)
		process_send_message_v2(conn, req)
	}

	// Outcomes isolate the write lease boundary, rather than repeat the WAL
	// corruption matrix: normal prefix interleaving, EIO, short write, three
	// pre-CQE crash windows, and shutdown with a deferred request.
	@(test)
	test_retained_async_write_boundaries :: proc(t: ^testing.T) {
		for outcome in 0 ..< 7 {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, 160 + outcome)
			defer simulation_test_end(&ctx)
			storage := sim_world_storage_context(&ctx.sim.world)
			dir := "/async-write-boundary"
			testing.expect(t, storage_io.make_directory(storage, dir) == nil)
			testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
			workspace := "async-boundary"
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, 24 * time.Hour, 0))
			// Establish the empty store before testing crashes of message appends.
			testing.expect(t, storage_io.sync(store.wal.file) == nil)
			testing.expect(t, storage_io.sync_directory(storage, store.directory) == nil)
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0
			defer shutdown_message_store_registry(&td.message_stores)
			conn := simulation_test_install_client(&ctx.sim, 0, workspace, "alice", init_send_queue = true)
			ctx.conns[0] = conn
			if !testing.expect(t, conn != nil) do return
			async_test_send(conn, 1)
			_, ok := flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, ok && store.write_in_flight)
			frozen := make([]byte, store.wal.write_offset)
			copy(frozen, store.wal.write_buffer[:store.wal.write_offset])
			defer delete(frozen)
			async_test_send(conn, 2)
			testing.expect(t, bytes.equal(frozen, store.wal.write_buffer[:store.wal.write_offset]))
			testing.expect_value(t, len(store.deferred_appends), 1)
			testing.expect_value(t, conn.retained_io, 2)
			testing.expect_value(t, conn.pending_io, u32(2))
			testing.expect_value(t, store.high_water, u64(0))
			testing.expect_value(t, store.wal.record_count, u64(0))
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
			if outcome >= 3 && outcome <= 5 {
				path := message_store_path(store.directory, store.active_generation, "wal")
				defer delete(path)
				prefix := 0
				if outcome >= 4 {
					if outcome == 5 do persistence.set_wal_short_write_for_test(1)
					testing.expect(t, nrc_sim_apply_next_file_write(&ctx.sim))
					persistence.clear_wal_write_fault_for_test()
					prefix = outcome == 4 ? len(frozen) : 1
				}
				sim_world_crash(&ctx.sim.world, path, prefix)
				testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim), "stale CQE must be discarded")
				testing.expect_value(t, store.high_water, u64(0))
				testing.expect_value(t, conn.retained_io, 2)
				retained_message_discard_speculative_process_state(&td.message_stores)
				testing.expect_value(t, conn.retained_io, 0)
				testing.expect_value(t, conn.pending_io, u32(0))
				testing.expect_value(t, store.retained_send_count, 0)
				crash_message_store_for_test(store)
				storage = sim_world_storage_context(&ctx.sim.world)
				testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, 24 * time.Hour, 0))
				testing.expect_value(t, store.high_water, outcome == 4 ? u64(1) : u64(0))
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
				continue
			}
			if outcome == 6 {
				// Shutdown rejects the never-written deferred request, but drains
				// and syncs the already-started batch before releasing its backing.
				// As in worker shutdown, close connections before destroying stores.
				// The write completion must retire the connection's remaining pins.
				handle, sock := conn.handle, conn.sock
				simulation_test_uninstall_client(conn)
				ctx.conns[0] = nil
				testing.expect(t, shutdown_message_store_registry(&td.message_stores))
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect(t, connection_get_by_handle(handle) == nil)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, sock, .S_AckSendMessage), 0)
				recovered: Message_Store
				testing.expect(t, init_message_store_with_storage(&recovered, storage, dir, shard, 24 * time.Hour, 0))
				testing.expect_value(t, recovered.high_water, u64(1))
				testing.expect(t, shutdown_message_store(&recovered))
				continue
			}
			if outcome == 1 do persistence.set_wal_write_error_for_test(os.Platform_Error(linux.Errno.EIO))
			if outcome == 2 do persistence.set_wal_short_write_for_test(1)
			completed := false
			if outcome == 1 || outcome == 2 {
				previous_logger := context.logger
				context.logger = log.nil_logger()
				completed = nrc_sim_run_next_file_write(&ctx.sim)
				context.logger = previous_logger
			} else {
				completed = nrc_sim_run_next_file_write(&ctx.sim)
			}
			testing.expect(t, completed)
			persistence.clear_wal_write_fault_for_test()
			if outcome != 0 {
				testing.expect(t, store.poisoned && !store.write_in_flight)
				testing.expect_value(t, len(store.pending_appends), 0)
				testing.expect_value(t, len(store.deferred_appends), 0)
				testing.expect_value(t, conn.retained_io, 0)
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect_value(t, conn.pending_io, u32(0))
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
				crash_message_store_for_test(store)
				continue
			}
			store.commit_started = {}
			testing.expect(t, schedule_retained_message_fsync(store))
			testing.expect_value(t, store.fsync_snapshot.record_count, u64(1))
			_, ok = flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, ok)
			testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
			testing.expect_value(t, store.high_water, u64(2))
			testing.expect_value(t, store.wal.durable_record_count, u64(0))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, store.wal.durable_record_count, u64(1))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
			store.commit_started = {}
			testing.expect(t, schedule_retained_message_fsync(store))
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			nrc_sim_run_all_send_completions(&ctx.sim)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 2)
		}
	}

	@(test)
	test_retained_async_duplicate_admission_bound :: proc(t: ^testing.T) {
		// Existing duplicate tests cover identity and rotation. This fixture
		// checks aggregate ownership across connections during a held write CQE.
		for path in 0 ..< 3 {
			for outcome in 0 ..< 3 {
				ctx: Sim_Test_Context
				simulation_test_begin(&ctx, 190 + path * 3 + outcome)
				defer simulation_test_end(&ctx)
				storage := sim_world_storage_context(&ctx.sim.world)
				dir := "/async-admission"
				testing.expect(t, storage_io.make_directory(storage, dir) == nil)
				workspace := "async-admission"
				shard := int(shard_for_workspace(transmute([]byte)workspace))
				for &index in td.message_stores.store_index do index = -1
				append(&td.message_stores.stores, Message_Store{})
				store := &td.message_stores.stores[0]
				testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
				td.message_stores.enabled = true
				td.message_stores.store_index[shard] = 0
				defer shutdown_message_store_registry(&td.message_stores)
				conns := make([]^NRC_Connection, MAX_RETAINED_SENDS_PER_STORE / MAX_RETAINED_IO_PER_CONNECTION + 2)
				defer {for conn in conns do simulation_test_uninstall_client(conn); delete(conns)}
				handles: [MAX_RETAINED_SENDS_PER_STORE / MAX_RETAINED_IO_PER_CONNECTION + 2]Connection_Handle
				for &conn, i in conns {
					conn = simulation_test_install_client(&ctx.sim, i, workspace, "alice", true)
					handles[i] = conn.handle
				}
				if path == 2 {
					async_test_send(conns[0], 3)
					testing.expect(t, simulation_test_commit_messages(&ctx.sim))
					nrc_sim_clear_inboxes(&ctx.sim)
				}
				async_test_send(conns[0], 1)
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, ok && store.write_in_flight)
				if path == 1 do async_test_send(conns[0], 2)
				frozen := make([]byte, store.wal.write_offset)
				copy(frozen, store.wal.write_buffer[:store.wal.write_offset])
				defer delete(frozen)
				// Exercise in-flight, deferred-follower and committed-duplicate paths.
				retry_id := u32(path + 1)
				initial_admitted := path == 1 ? 2 : 1
				testing.expect_value(t, store.retained_send_count, initial_admitted)
				remaining := MAX_RETAINED_SENDS_PER_STORE - initial_admitted
				for i in 0 ..< remaining do async_test_send(conns[1 + i / MAX_RETAINED_IO_PER_CONNECTION], retry_id)
				testing.expect_value(t, store.retained_send_count, MAX_RETAINED_SENDS_PER_STORE)
				rejected := conns[len(conns) - 1]
				async_test_send(rejected, retry_id)
				testing.expect_value(t, store.retained_send_count, MAX_RETAINED_SENDS_PER_STORE)
				testing.expect_value(t, rejected.retained_io, 0)
				testing.expect_value(t, rejected.pending_io, u32(0))
				testing.expect(t, bytes.equal(frozen, store.wal.write_buffer[:store.wal.write_offset]))
				for conn in conns do testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
				if outcome == 2 {
					for &conn in conns {simulation_test_uninstall_client(conn); conn = nil}
					cancel_message_seals(&td.message_stores)
				}
				if outcome == 1 {
					previous_logger := context.logger
					context.logger = log.nil_logger()
					completed := nrc_sim_run_next_file_write(&ctx.sim, .EIO)
					context.logger = previous_logger
					testing.expect(t, completed)
					testing.expect(t, store.poisoned)
				} else {
					testing.expect(t, simulation_test_flush_message_writes(&ctx.sim))
				}
				testing.expect_value(t, store.retained_send_count, 0)
				if outcome == 0 {
					// Full write completion alone must not send an ACK.
					for conn in conns do testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
					testing.expect(t, simulation_test_commit_messages(&ctx.sim))
					acks := 0
					for conn in conns do acks += nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage)
					testing.expect_value(t, acks, MAX_RETAINED_SENDS_PER_STORE)
					testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, rejected.sock, .S_ErrorResponse), 1)
				}
				nrc_sim_run_all_send_completions(&ctx.sim)
				if outcome == 2 {
					for handle in handles do testing.expect(t, connection_get_by_handle(handle) == nil)
				}
				for conn in conns {
					if conn == nil do continue
					testing.expect_value(t, conn.retained_io, 0)
					testing.expect_value(t, conn.pending_io, u32(0))
				}
			}
		}
	}
}

@(test)
test_retained_async_failure_cleanup :: proc(t: ^testing.T) {
	when !NRC_SIMULATION {
		errors := []linux.Errno{.NONE, .EIO}
		for err in errors {
			td.message_stores = {}; td.message_stores.enabled = true; td.message_stores.write_batch_records = 16
			dir := test_wal_path("async-failure-cleanup"); defer os.remove_all(dir)
			testing.expect(t, os.make_directory(dir) == nil)
			store: Message_Store
			workspace := "async-probe"
			testing.expect(t, init_message_store(&store, dir, int(shard_for_workspace(transmute([]byte)workspace)), 24 * time.Hour, 0))
			retained_async_test_queue_message(&store, 1)
			store.write_in_flight = true; store.write_started = store.wal.get_time()
			retained_async_test_queue_message(&store, 2)
			written := err == .NONE ? 1 : 0
			previous_logger := context.logger
			context.logger = log.nil_logger()
			retained_message_write_complete(rawptr(&store), written, err)
			context.logger = previous_logger
			testing.expect(t, store.poisoned && !store.write_in_flight && !store.wal.enabled)
			testing.expect_value(t, len(store.pending_appends), 0)
			testing.expect_value(t, len(store.deferred_appends), 0)
			testing.expect_value(t, store.high_water, u64(0))
			testing.expect_value(t, store.wal.record_count, u64(0))
			testing.expect_value(t, store.wal.write_offset, 0)
			_, _ = flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, shutdown_message_store(&store)); td.message_stores = {}
		}
	}
}
