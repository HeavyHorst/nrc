package main

import "core:log"
import "core:os"
import "core:sys/linux"
import "core:time"

import "byte_pool"
import nbio "nbio/poly"
import "persistence"

Sharded_Persistence_Mode :: enum u8 {
	Inactive,
	Active,
}

Shard_Writer_Registry :: struct {
	mode:              Sharded_Persistence_Mode,
	worker:            int,
	worker_count:      int,
	writers:           [dynamic]Shard_Transaction_Writer,
	writer_index:      [LOGICAL_SHARD_COUNT]i16,
	compaction_cursor: int,
}

shard_sweep_metric_add :: proc(total: ^u64, value: u64) {
	if value > max(u64) - total^ {total^ = max(u64)} else {total^ += value}
}

shard_sweep_metrics_add :: proc(total: ^Shard_Sweep_Metrics, value: Shard_Sweep_Metrics) {
	shard_sweep_metric_add(&total.runs, value.runs)
	shard_sweep_metric_add(&total.ordinary_runs, value.ordinary_runs)
	shard_sweep_metric_add(&total.raw_runs, value.raw_runs)
	shard_sweep_metric_add(&total.input_bytes, value.input_bytes)
	shard_sweep_metric_add(&total.dirty_bytes, value.dirty_bytes)
	shard_sweep_metric_add(&total.prefix_read_bytes, value.prefix_read_bytes)
	shard_sweep_metric_add(&total.latest_read_bytes, value.latest_read_bytes)
	shard_sweep_metric_add(&total.measure_read_bytes, value.measure_read_bytes)
	shard_sweep_metric_add(&total.copy_read_bytes, value.copy_read_bytes)
	shard_sweep_metric_add(&total.replay_read_bytes, value.replay_read_bytes)
	shard_sweep_metric_add(&total.metadata_fallbacks, value.metadata_fallbacks)
	shard_sweep_metric_add(&total.metadata_written_bytes, value.metadata_written_bytes)
}

shard_writer_registry_sweep_metrics :: proc(registry: ^Shard_Writer_Registry) -> (metrics: Shard_Sweep_Metrics) {
	if registry == nil || registry.mode != .Active do return
	for &writer in registry.writers do shard_sweep_metrics_add(&metrics, writer.sweep_metrics)
	return
}

logical_shard_worker :: proc(shard, worker_count: int) -> (worker: int, ok: bool) {
	if shard < 0 || shard >= LOGICAL_SHARD_COUNT || !valid_storage_layout_worker_count(worker_count) do return
	return shard % worker_count, true
}

shutdown_shard_writer_registry :: proc(registry: ^Shard_Writer_Registry) -> bool {
	if registry == nil do return true
	for &writer in registry.writers do discard_shard_deferred_requests(&writer)
	for {
		leased := false
		for &writer in registry.writers do leased = leased || writer.write_in_flight || writer.fsync_in_flight
		if !leased do break
		when NRC_SIMULATION {
			if nrc_sim_runtime != nil {
				for nrc_sim_run_next_file_write(nrc_sim_runtime) {}
				for nrc_sim_run_next_fsync_completion(nrc_sim_runtime) {}
				continue
			}
		}
		err := nbio.tick(&td.io, time.Millisecond)
		assert(err == .NONE, "I/O failed while draining shard WAL leases")
	}
	ok := true
	for &writer in registry.writers {
		if !shutdown_shard_transaction_writer(&writer) do ok = false
	}
	delete(registry.writers)
	registry^ = {}
	return ok
}

init_shard_writer_registry :: proc(registry: ^Shard_Writer_Registry, generation_dir: string, worker, worker_count: int, apply := false) -> bool {
	if registry == nil || registry.mode != .Inactive || len(registry.writers) != 0 || worker < 0 || worker >= worker_count || !valid_storage_layout_worker_count(worker_count) do return false
	registry.worker = worker
	registry.worker_count = worker_count
	for &index in registry.writer_index do index = -1
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		owner, ok := logical_shard_worker(shard, worker_count)
		if !ok {shutdown_shard_writer_registry(registry); return false}
		if owner != worker do continue
		writer_index := len(registry.writers)
		_, append_err := append(&registry.writers, Shard_Transaction_Writer{})
		if append_err != nil {shutdown_shard_writer_registry(registry); return false}
		shard_dir := sharded_shard_path(generation_dir, shard)
		initialized := init_managed_shard_transaction_writer(&registry.writers[writer_index], shard_dir, shard, worker, worker_count, apply)
		delete(shard_dir)
		if !initialized {shutdown_shard_writer_registry(registry); return false}
		if !refresh_shard_writer_storage_space(&registry.writers[writer_index], force = true) {shutdown_shard_writer_registry(registry); return false}
		registry.writers[writer_index].batch_writes = true
		registry.writer_index[shard] = i16(writer_index)
	}
	registry.mode = .Active
	return true
}

shard_writer_for_workspace :: proc(registry: ^Shard_Writer_Registry, workspace: []byte) -> ^Shard_Transaction_Writer {
	if registry == nil || registry.mode != .Active || len(workspace) == 0 do return nil
	shard := int(shard_for_workspace(workspace))
	owner, ok := logical_shard_worker(shard, registry.worker_count)
	if !ok || owner != registry.worker do return nil
	index := registry.writer_index[shard]
	if index < 0 || int(index) >= len(registry.writers) do return nil
	writer := &registry.writers[index]
	if writer.shard != shard || writer.owner_worker != registry.worker do return nil
	return writer
}

shard_writer_fsync_complete :: proc(writer: ^Shard_Transaction_Writer, err: linux.Errno) {
	if writer == nil || !writer.fsync_in_flight do return
	snapshot := writer.fsync_snapshot
	elapsed := time.diff(writer.fsync_started, writer.wal.get_time())
	writer.fsync_in_flight = false
	writer.fsync_snapshot = {}
	writer.fsync_started = {}
	if !persistence.complete_async_fsync(&writer.wal, snapshot, elapsed, err) {
		discard_shard_deferred_requests(writer)
		writer.poisoned = true
		if td.server != nil do server_shutdown_after_storage_error(td.server)
		return
	}
	resume_shard_durable_outboxes(writer)
	drain_shard_deferred_requests(writer)
}

shard_commit_due :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil || !writer.wal.enabled || writer.write_in_flight || writer.fsync_in_flight || writer.lifecycle_in_flight do return false
	bytes := writer.wal.pending_bytes + u64(writer.wal.write_offset)
	if bytes == 0 do return false
	return bytes >= SHARD_COMMIT_MAX_BYTES || (writer.commit_pending && time.diff(writer.commit_started, writer.wal.get_time()) >= SHARD_COMMIT_WINDOW)
}

shard_writer_should_rotate_before_async_fsync :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil ||
	   !writer.managed ||
	   writer.write_in_flight ||
	   writer.fsync_in_flight ||
	   writer.manifest.sealed_present ||
	   writer.compaction == .Sealed ||
	   SHARD_WAL_SEGMENT_MAX_BYTES <= persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE {
		return false
	}
	wal_bytes := persistence.get_file_size(&writer.wal)
	rotation_reserve := u64(persistence.MAX_WAL_PAYLOAD_SIZE + persistence.LOG_HEADER_SIZE)
	return wal_bytes > 0 && wal_bytes >= SHARD_WAL_SEGMENT_MAX_BYTES - rotation_reserve
}

submit_shard_writer_write :: proc(writer: ^Shard_Transaction_Writer) {
	assert(!writer.write_in_flight && writer.wal.write_offset > 0)
	buffer := writer.oversized_write
	if buffer == nil do buffer = writer.wal.write_buffer[:writer.wal.write_offset]
	writer.write_in_flight = true
	writer.write_started = writer.wal.get_time()
	_ = nrc_io_append_wal(writer.wal.file, buffer, rawptr(writer), shard_writer_write_complete)
}

shard_writer_write_complete :: proc(user: rawptr, written: int, err: linux.Errno) {
	writer := (^Shard_Transaction_Writer)(user)
	assert(writer.write_in_flight)
	writer.write_in_flight = false
	write_err: os.Error
	if err != .NONE do write_err = os.Platform_Error(err)
	ok := persistence.complete_deferred_write(&writer.wal, written, write_err, time.diff(writer.write_started, writer.wal.get_time()))
	writer.write_started = {}
	if writer.oversized_write != nil {
		byte_pool.release(td.spool, writer.oversized_write)
		writer.oversized_write = nil
	}
	if !ok {
		writer.poisoned = true
		discard_shard_deferred_requests(writer)
		log.errorf("[T%d] Shard WAL async write failed; shutting down (shard=%d)", td.thread_index, writer.shard)
		if td.server != nil do server_shutdown_after_storage_error(td.server)
		return
	}
	// Capture only completed writes, before deferred requests can stage a suffix.
	if !writer.fsync_in_flight do schedule_shard_writer_fsync(writer)
	if !writer.poisoned do drain_shard_deferred_requests(writer)
}

schedule_shard_writer_fsync :: proc(writer: ^Shard_Transaction_Writer) {
	assert(!writer.write_in_flight && !writer.fsync_in_flight)
	if writer.lifecycle_in_flight do return
	// Preserve preemptive rotation, but never rotate a leased or staged suffix.
	if writer.wal.write_offset == 0 && shard_writer_should_rotate_before_async_fsync(writer) && rotate_shard_writer_for_compaction(writer) do return
	if writer.poisoned || !writer.wal.enabled || writer.wal.pending_bytes == 0 do return
	writer.fsync_snapshot = {
		last_hash     = writer.wal.last_hash,
		record_count  = writer.wal.record_count,
		pending_bytes = writer.wal.pending_bytes,
	}
	writer.fsync_in_flight = true
	writer.fsync_started = writer.wal.get_time()
	writer.commit_pending = false
	_ = nrc_io_sync_file(
		writer.wal.file,
		rawptr(writer),
		proc(user: rawptr, err: linux.Errno) {shard_writer_fsync_complete((^Shard_Transaction_Writer)(user), err)},
	)
}

schedule_shard_writer_fsyncs_if_due :: proc(registry: ^Shard_Writer_Registry) -> (did_work, ok: bool) {
	if registry == nil || registry.mode != .Active do return false, true
	for &writer in registry.writers {
		if writer.poisoned || !writer.wal.enabled do return did_work, false
		if !shard_commit_due(&writer) do continue
		if writer.wal.write_offset > 0 {
			submit_shard_writer_write(&writer)
		} else {
			schedule_shard_writer_fsync(&writer)
		}
		if writer.poisoned || !writer.wal.enabled do return did_work, false
		did_work = true
	}
	return did_work, true
}

init_active_sharded_worker_persistence :: proc(data_dir: string, generation: u64, worker, worker_count: int) -> bool {
	if td.workspaces == nil || len(td.workspaces) != 0 do return false
	if td.shard_writers.mode != .Inactive || len(td.shard_writers.writers) != 0 do return false
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	initialized := false
	defer if !initialized {
		shutdown_shard_writer_registry(&td.shard_writers)
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
	}

	// Validate, recover and apply each file once into unpublished worker state.
	// Any writer-open/recovery/application failure discards all earlier state.
	// The listener remains behind the all-workers-ready barrier until success.
	if !init_shard_writer_registry(&td.shard_writers, generation_dir, worker, worker_count, true) do return false
	max_floors: Shard_High_Water_Requirements
	for &writer in td.shard_writers.writers {
		shard_max_requirement(&max_floors.task, writer.floors.task)
		shard_max_requirement(&max_floors.asset, writer.floors.asset)
		shard_max_requirement(&max_floors.edge, writer.floors.edge)
	}
	td.task_seq = max_floors.task
	td.asset_seq = max_floors.asset
	td.edge_seq = max_floors.edge
	initialized = true
	return true
}
