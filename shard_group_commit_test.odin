package main

import "core:bytes"
import "core:log"
import "core:os"
import "core:sys/linux"
import "core:testing"
import "core:time"

import "byte_pool"
import "persistence"
import pr "protocol"
import "storage_io"

@(thread_local)
group_commit_test_now: time.Time

group_commit_test_clock :: proc "contextless" () -> time.Time {return group_commit_test_now}

@(test)
test_shard_group_commit_window_size_and_write_batch :: proc(t: ^testing.T) {
	path := test_wal_path("group-commit-window.log")
	defer os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	workspace := "group-commit-window"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, 0, 1))
	defer shutdown_shard_transaction_writer(&writer)
	writer.batch_writes = true
	writer.wal.get_time = group_commit_test_clock
	group_commit_test_now = time.Time {
		_nsec = i64(time.Hour),
	}
	data: Shard_Writer_Test_Data
	shard_writer_test_transaction_init(&data, workspace)
	defer shard_writer_test_transaction_destroy(&data)
	testing.expect(t, append_shard_transaction(&writer, &data.tx))
	started := writer.commit_started
	group_commit_test_now = time.Time {
		_nsec = started._nsec + i64(SHARD_COMMIT_WINDOW - time.Nanosecond),
	}
	testing.expect(t, append_shard_transaction(&writer, &data.tx))
	testing.expect_value(t, writer.commit_started, started)
	testing.expect(t, !shard_commit_due(&writer))
	testing.expect_value(t, writer.wal.write_count, u64(0))
	testing.expect_value(t, writer.wal.buffered_record_count, u64(2))
	group_commit_test_now = time.Time {
		_nsec = started._nsec + i64(SHARD_COMMIT_WINDOW),
	}
	testing.expect(t, shard_commit_due(&writer))
	testing.expect(t, persistence.flush_write_batch_deferred_fsync(&writer.wal))
	testing.expect_value(t, writer.wal.write_count, u64(1))
	testing.expect_value(t, writer.wal.record_count, u64(2))
	testing.expect_value(t, writer.wal.durable_record_count, u64(0))
	persistence.force_fsync(&writer.wal)
	testing.expect_value(t, writer.wal.durable_record_count, u64(2))
	writer.commit_pending = false
	// Independently check the byte threshold on either side, before the deadline.
	writer.wal.pending_bytes = SHARD_COMMIT_MAX_BYTES - 1
	testing.expect(t, !shard_commit_due(&writer))
	writer.wal.pending_bytes += 1
	testing.expect(t, shard_commit_due(&writer))
	writer.wal.pending_bytes = 0
}

@(test)
test_shard_group_commit_outbox_watermark_survives_rotation :: proc(t: ^testing.T) {
	writer := Shard_Transaction_Writer{}
	writer.wal.enabled = true
	writer.wal.record_count = 8
	writer.wal.durable_record_count = 4
	item := Send_Item {
		durability_writer = &writer,
		durability_record = 5,
	}
	testing.expect(t, !outbox_item_is_durable(&item))
	writer.wal.durable_record_count = 5
	testing.expect(t, outbox_item_is_durable(&item))
	writer.durability_generation += 1
	writer.wal.record_count = 0
	writer.wal.durable_record_count = 0
	testing.expect(t, outbox_item_is_durable(&item))
	writer.poisoned = true
	testing.expect(t, !outbox_item_is_durable(&item))
}

when !NRC_SIMULATION {
	_ :: pr.GetTaskRequest; _ :: log.nil_logger
	_ :: bytes.equal; _ :: linux.Errno; _ :: byte_pool.release; _ :: storage_io.file_size
}

when NRC_SIMULATION {
	@(test)
	test_shard_async_write_redeferred_request_preserves_tail_order :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 188)
		defer simulation_test_end(&ctx)
		workspace := "shard-redeferred-tail"
		path, ok := task_handler_test_init_sim_writer(workspace, "shard-redeferred-tail.log")
		defer os.remove(path)
		if !testing.expect(t, ok) do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		writer := &td.shard_writers.writers[0]
		writer.batch_writes = true
		td.task_seq = 0
		conn := simulation_test_install_client(&ctx.sim, 0, workspace, "writer", init_send_queue = true)
		ctx.conns[0] = conn
		request := pr.CreateTaskRequest {
			conv_id        = pr.WORKSPACE_DATA_ID,
			title          = transmute([]byte)string("ordered"),
			correlation_id = 81,
		}
		process_create_task(conn, request)
		submit_shard_writer_write(writer)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		testing.expect(t, writer.fsync_in_flight)
		process_create_task(conn, request)
		submit_shard_writer_write(writer)
		// Model the outstanding-byte cap without generating 32MiB of fixtures.
		writer.wal.pending_bytes = SHARD_COMMIT_PENDING_MAX_BYTES - u64(writer.wal.write_offset)
		payload: [512]byte
		length := pr.serializeCreateTaskRequest(request, payload[:])
		process_protocol_payload(conn, payload[:length])
		length = pr.serializeGetTaskRequest({conv_id = pr.WORKSPACE_DATA_ID, task_id = 3, correlation_id = 82}, payload[:])
		process_protocol_payload(conn, payload[:length])
		testing.expect_value(t, conn.deferred_shard_requests, u16(2))
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		testing.expect_value(t, td.task_seq, u64(2))
		testing.expect_value(t, len(writer.deferred_requests), 2)
		testing.expect_value(t, conn.deferred_shard_requests, u16(2))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect_value(t, td.task_seq, u64(3))
		testing.expect_value(t, conn.deferred_shard_requests, u16(0))
		testing.expect(t, simulation_test_commit_shards(&ctx.sim))
		testing.expect_value(t, writer.wal.durable_record_count, u64(3))
	}

	@(test)
	test_shard_async_write_lease_boundaries_failure_and_shutdown :: proc(t: ^testing.T) {
		// A batch just below capacity, exactly at capacity, an oversized record,
		// short writes, EIO, ENOSPC, shutdown and a crash with an oversized lease.
		for outcome in 0 ..< 8 {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, 180 + outcome)
			defer simulation_test_end(&ctx)
			workspace := "shard-async-boundary"
			path, ok := task_handler_test_init_sim_writer(workspace, "shard-async-boundary.log")
			defer os.remove(path)
			if !testing.expect(t, ok) do return
			defer shutdown_shard_writer_registry(&td.shard_writers)
			writer := &td.shard_writers.writers[0]
			writer.batch_writes = true
			td.task_seq = 0
			td.asset_seq = 20
			conn := simulation_test_install_client(&ctx.sim, 0, workspace, "writer", init_send_queue = true)
			ctx.conns[0] = conn
			if !testing.expect(t, conn != nil) do return

			asset := pr.Asset {
				asset_type       = .Document,
				asset_id         = 20,
				conv_id          = pr.WORKSPACE_DATA_ID,
				payload_encoding = .Plain,
			}
			// Derive overhead from the empty wire record, then choose its payload
			// so the entire outer WAL record lands on the exact batch boundary.
			empty_record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_asset_payload_size(workspace, &asset))
			serialize_asset_to_record(empty_record, workspace, &asset)
			_, prefix_size, _ := persistence.parse_workspace_prefix(empty_record[persistence.LOG_HEADER_SIZE:])
			mutations := [1]Shard_Mutation {
				{domain = .Asset, op = u8(Asset_Log_Op.Create), entity_record_version = 3, payload = empty_record[persistence.LOG_HEADER_SIZE + prefix_size:]},
			}
			tx := Shard_Transaction {
				workspace        = transmute([]byte)workspace,
				asset_high_water = 20,
				mutations        = mutations[:],
			}
			empty_size, size_err := shard_transaction_size(&tx)
			testing.expect_value(t, size_err, Shard_Transaction_Error.None)
			target_size := persistence.WRITE_BATCH_MAX_BYTES + (outcome == 0 ? -1 : outcome == 1 ? 0 : 1)
			body_size := target_size - persistence.LOG_HEADER_SIZE - empty_size
			asset.payload = make([]byte, min(body_size, int(max(u16))))
			defer delete(asset.payload)
			asset.preview = make([]byte, body_size - len(asset.payload))
			defer delete(asset.preview)
			asset.payload[0] = 0x37; asset.payload[len(asset.payload) - 1] = 0xA9
			asset.payload_raw_len = u32(len(asset.payload))
			record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_asset_payload_size(workspace, &asset))
			defer delete(record)
			serialize_asset_to_record(record, workspace, &asset)
			mutations[0].payload = record[persistence.LOG_HEADER_SIZE + prefix_size:]
			delete(empty_record)
			pool_before := td.spool.live_allocs
			if !testing.expect(t, append_shard_transaction(writer, &tx)) do return
			testing.expect_value(t, writer.wal.write_offset, target_size)
			testing.expect_value(t, writer.wal.record_count, u64(0))
			leased := writer.oversized_write
			if leased == nil do leased = writer.wal.write_buffer[:target_size]
			copy_before := make([]byte, len(leased)); copy(copy_before, leased); defer delete(copy_before)
			if outcome >= 2 do testing.expect_value(t, td.spool.live_allocs, pool_before + 1)
			request := pr.CreateTaskRequest {
				conv_id        = pr.WORKSPACE_DATA_ID,
				title          = transmute([]byte)string("deferred suffix"),
				correlation_id = 71,
			}
			payload: [512]byte
			length := pr.serializeCreateTaskRequest(request, payload[:])
			process_protocol_payload(conn, payload[:length])
			testing.expect(t, writer.write_in_flight)
			testing.expect(t, bytes.equal(copy_before, leased), "new request must not modify the leased bytes")
			testing.expect_value(t, len(writer.deferred_requests), 1)
			testing.expect_value(t, conn.deferred_shard_requests, u16(1))
			testing.expect_value(t, td.task_seq, u64(0))
			file_size, _ := storage_io.file_size(writer.wal.file)
			testing.expect(t, file_size == 0, "submission must not synchronously write")
			testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 0)
			if outcome == 6 {
				sim_world_crash(&ctx.sim.world)
				generated_semantic_virtual_process_discard(writer)
				testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
				testing.expect_value(t, conn.deferred_shard_requests, u16(0))
				testing.expect_value(t, td.spool.live_allocs, pool_before)
				continue
			}
			if outcome == 5 {
				testing.expect(t, shutdown_shard_writer_registry(&td.shard_writers))
				testing.expect_value(t, conn.deferred_shard_requests, u16(0))
				testing.expect_value(t, td.task_seq, u64(0))
				testing.expect_value(t, td.spool.live_allocs, pool_before)
				inspection, _, replay_ok := scan_shard_transaction_wal(
					path,
					int(shard_for_workspace(transmute([]byte)workspace)),
					Shard_High_Water_Requirements{},
					false,
					false,
				)
				testing.expect(t, replay_ok && inspection.record_count == 1)
				continue
			}
			if outcome == 3 do persistence.set_wal_short_write_for_test(1)
			completed := false
			if outcome == 3 || outcome == 4 || outcome == 7 {
				context.logger = log.nil_logger()
				completed = nrc_sim_run_next_file_write(&ctx.sim, outcome == 7 ? linux.Errno.ENOSPC : outcome == 4 ? linux.Errno.EIO : linux.Errno.NONE)
			} else {
				completed = nrc_sim_run_next_file_write(&ctx.sim)
			}
			persistence.clear_wal_write_fault_for_test()
			testing.expect(t, completed)
			testing.expect_value(t, conn.deferred_shard_requests, u16(0))
			testing.expect(t, !writer.write_in_flight && writer.oversized_write == nil)
			if outcome == 3 || outcome == 4 || outcome == 7 {
				testing.expect(t, writer.poisoned && !writer.wal.enabled)
				testing.expect_value(t, writer.wal.record_count, u64(0))
				testing.expect_value(t, td.spool.live_allocs, pool_before)
				testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 0)
				testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 0)
				continue
			}
			testing.expect_value(t, writer.fsync_snapshot.record_count, u64(1))
			testing.expect_value(t, writer.wal.buffered_record_count, u64(1))
			testing.expect_value(t, td.task_seq, u64(1))
			testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
			testing.expect(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock) == 0, "first fsync must not ACK the deferred suffix")
			testing.expect(t, simulation_test_commit_shards(&ctx.sim))
			testing.expect_value(t, writer.wal.durable_record_count, u64(2))
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock), 1)
			inspection, floors, replay_ok := scan_shard_transaction_wal(path, writer.shard, Shard_High_Water_Requirements{}, false, false)
			testing.expect(t, replay_ok && inspection.record_count == 2)
			testing.expect_value(t, floors, Shard_High_Water_Requirements{task = 1, asset = 20})
		}
	}

	@(test)
	test_shard_group_commit_rotation_failure_wakes_durable_outboxes :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		data_dir := storage_layout_test_setup("group-commit-rotation")
		defer os.remove_all(data_dir)
		testing.expect(t, storage_layout_test_create_generation(data_dir, 1))
		generation_dir := sharded_generation_path(data_dir, 1)
		defer delete(generation_dir)
		workspace := "group-commit-rotation"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		testing.expect(t, init_shard_writer_registry(&td.shard_writers, generation_dir, shard, LOGICAL_SHARD_COUNT))
		defer shutdown_shard_writer_registry(&td.shard_writers)
		writer := &td.shard_writers.writers[0]
		ctx.conns[0] = simulation_test_install_client(&ctx.sim, 0, workspace, "writer", init_send_queue = true)
		c := ctx.conns[0]
		process_create_task(c, pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("first")})
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 0)
		actual_size := persistence.get_file_size(&writer.wal)
		writer.wal.file_size_bytes = SHARD_WAL_SEGMENT_MAX_BYTES
		writer.commit_started = {}
		set_shard_compaction_fault_for_test(.New_Active_Create)
		did_work, ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, did_work && ok && writer.write_in_flight)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		testing.expect(t, shard_compaction_fault_triggered_for_test())
		clear_shard_compaction_fault_for_test()
		writer.wal.file_size_bytes = actual_size
		testing.expect(t, !writer.commit_pending && !writer.fsync_in_flight)
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 0)
		testing.expect_value(t, writer.wal.durable_record_count, u64(1))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 1)
		nrc_sim_run_all_send_completions(&ctx.sim)
		process_create_task(c, pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("second")})
		writer.commit_started = {}
		did_work, ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, did_work && ok)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		process_create_task(c, pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("buffered suffix")})
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		testing.expect_value(t, writer.wal.durable_record_count, u64(2))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 2)
		// Rotate with a buffered suffix while the previous ACK is in transport.
		testing.expect(t, rotate_shard_writer_for_compaction(writer))
		testing.expect_value(t, writer.durability_generation, u64(1))
		process_create_task(c, pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("new generation")})
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 3)
		testing.expect_value(t, send_queue_len(c), 1)
		testing.expect(t, simulation_test_commit_shards(&ctx.sim))
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 4)
	}

	@(test)
	test_shard_group_commit_holds_ack_broadcast_and_query_until_snapshot_fsync :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		workspace := "group-commit-visibility"
		path, ok := task_handler_test_init_sim_writer(workspace, "group-commit-visibility.log")
		defer os.remove(path)
		testing.expect(t, ok)
		if !ok do return
		defer shutdown_shard_writer_registry(&td.shard_writers)
		writer := &td.shard_writers.writers[0]
		writer.batch_writes = true
		for i in 0 ..< 2 {
			ctx.conns[i] = simulation_test_install_client(&ctx.sim, i, workspace, "user", init_send_queue = true)
			subscribe_to_conversation(ctx.conns[i], 77)
		}
		nrc_sim_clear_inboxes(&ctx.sim)
		for i in 0 ..< 2 {
			process_create_task(ctx.conns[0], pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("batched"), correlation_id = u32(i + 1)})
		}
		process_get_task(ctx.conns[1], pr.GetTaskRequest{conv_id = 77, task_id = 2, correlation_id = 3})
		for c in ctx.conns[:2] do testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 0)
		testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		testing.expect_value(t, writer.wal.write_count, u64(0))
		writer.commit_started = {}
		did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, did_work && sync_ok)
		testing.expect_value(t, writer.wal.write_count, u64(0))
		testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 0)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		testing.expect_value(t, writer.wal.write_count, u64(1))
		testing.expect_value(t, writer.fsync_snapshot.record_count, u64(2))
		for c in ctx.conns[:2] do testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, c.sock), 0)
		// A later mutation is not covered by the first completion, even if the
		// device happens to persist more than the submitted snapshot.
		process_create_task(ctx.conns[0], pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("next batch"), correlation_id = 4})
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, ctx.conns[0].sock), 2)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, ctx.conns[1].sock), 3)
		testing.expect_value(t, writer.wal.durable_record_count, u64(2))
		writer.commit_started = {}
		did_work, sync_ok = schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
		testing.expect(t, did_work && sync_ok)
		testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
		testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, ctx.conns[0].sock), 3)
		testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, ctx.conns[1].sock), 4)
		testing.expect_value(t, writer.wal.durable_record_count, u64(3))
		testing.expect_value(t, writer.wal.fsync_count, u64(2))
	}

	@(test)
	test_shard_group_commit_failure_and_disconnect_do_not_publish_ack :: proc(t: ^testing.T) {
		for fail_sync in ([?]bool{false, true}) {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx)
			defer simulation_test_end(&ctx)
			workspace := "group-commit-failure"
			path, ok := task_handler_test_init_sim_writer(workspace, "group-commit-failure.log")
			defer os.remove(path)
			testing.expect(t, ok)
			if !ok do return
			defer shutdown_shard_writer_registry(&td.shard_writers)
			writer := &td.shard_writers.writers[0]
			writer.batch_writes = true
			ctx.conns[0] = simulation_test_install_client(&ctx.sim, 0, workspace, "old", init_send_queue = true)
			process_create_task(ctx.conns[0], pr.CreateTaskRequest{conv_id = 77, title = transmute([]byte)string("pending")})
			writer.commit_started = {}
			did_work, sync_ok := schedule_shard_writer_fsyncs_if_due(&td.shard_writers)
			testing.expect(t, did_work && sync_ok)
			testing.expect(t, nrc_sim_run_next_file_write(&ctx.sim))
			if fail_sync {
				previous_logger := context.logger
				context.logger = log.nil_logger()
				completed := nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO)
				context.logger = previous_logger
				testing.expect(t, completed)
				testing.expect(t, writer.poisoned)
				testing.expect_value(t, writer.wal.durable_record_count, u64(0))
			} else {
				old_handle := ctx.conns[0].handle
				simulation_test_uninstall_client(ctx.conns[0])
				ctx.conns[0] = simulation_test_install_client(&ctx.sim, 0, workspace, "replacement", init_send_queue = true)
				testing.expect(t, ctx.conns[0].handle != old_handle)
				testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
				testing.expect(t, !ctx.conns[0].outbox_waiting_durability)
			}
			testing.expect_value(t, nrc_sim_client_frame_count(&ctx.sim, ctx.conns[0].sock), 0)
			testing.expect_value(t, nrc_sim_send_completion_count(&ctx.sim), 0)
		}
	}
}
