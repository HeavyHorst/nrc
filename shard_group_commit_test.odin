package main

import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "persistence"
import pr "protocol"

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
	// A full batch triggers before the new deadline, even if the buffer already
	// auto-flushed to the kernel. Independent transactions keep separate records.
	for !shard_commit_due(&writer) {
		testing.expect(t, append_shard_transaction(&writer, &data.tx))
	}
	testing.expect_value(t, writer.commit_started, group_commit_test_now)
	testing.expect(t, writer.wal.pending_bytes + u64(writer.wal.write_offset) >= SHARD_COMMIT_MAX_BYTES)
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

when !NRC_SIMULATION {_ :: pr.GetTaskRequest; _ :: log.nil_logger}

when NRC_SIMULATION {
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
		testing.expect(t, did_work && ok && shard_compaction_fault_triggered_for_test())
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
