package main

import "core:sys/linux"
import "core:time"

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
	ok := true
	for &writer in registry.writers {
		if !shutdown_shard_transaction_writer(&writer) do ok = false
	}
	delete(registry.writers)
	registry^ = {}
	return ok
}

init_shard_writer_registry :: proc(registry: ^Shard_Writer_Registry, generation_dir: string, worker, worker_count: int) -> bool {
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
		initialized := init_managed_shard_transaction_writer(&registry.writers[writer_index], shard_dir, shard, worker, worker_count)
		delete(shard_dir)
		if !initialized {shutdown_shard_writer_registry(registry); return false}
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
	if writer == nil || !writer.wal.enabled || writer.fsync_in_flight do return false
	bytes := writer.wal.pending_bytes + u64(writer.wal.write_offset)
	if bytes == 0 do return false
	return bytes >= SHARD_COMMIT_MAX_BYTES || (writer.commit_pending && time.diff(writer.commit_started, writer.wal.get_time()) >= SHARD_COMMIT_WINDOW)
}

shard_writer_should_rotate_before_async_fsync :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil ||
	   !writer.managed ||
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

schedule_shard_writer_fsyncs_if_due :: proc(registry: ^Shard_Writer_Registry) -> (did_work, ok: bool) {
	if registry == nil || registry.mode != .Active do return false, true
	for &writer in registry.writers {
		if writer.poisoned || !writer.wal.enabled do return did_work, false
		if !shard_commit_due(&writer) do continue
		if !persistence.flush_write_batch_deferred_fsync(&writer.wal) {
			writer.poisoned = true
			return did_work, false
		}
		// Near the segment boundary, rotating now avoids submitting an async
		// fsync that would make the next append reject while that fsync is in
		// flight. The reserve covers the largest accepted outer WAL record.
		if shard_writer_should_rotate_before_async_fsync(&writer) && rotate_shard_writer_for_compaction(&writer) {
			did_work = true
			continue
		}
		if writer.poisoned || !writer.wal.enabled do return did_work, false
		// A failed rotation may still have synced the old WAL. Never submit a
		// pre-rotation byte snapshot that could consume a later suffix's accounting.
		if writer.wal.pending_bytes == 0 {
			did_work = true
			continue
		}
		snapshot := persistence.WAL_Fsync_Snapshot {
			last_hash     = writer.wal.last_hash,
			record_count  = writer.wal.record_count,
			pending_bytes = writer.wal.pending_bytes,
		}
		writer.fsync_in_flight = true
		writer.fsync_snapshot = snapshot
		writer.fsync_started = writer.wal.get_time()
		writer.commit_pending = false
		_ = nrc_io_sync_file(
			writer.wal.file,
			rawptr(&writer),
			proc(user: rawptr, err: linux.Errno) {shard_writer_fsync_complete((^Shard_Transaction_Writer)(user), err)},
		)
		did_work = true
	}
	return did_work, true
}

init_active_sharded_worker_persistence :: proc(data_dir: string, generation: u64, worker, worker_count: int) -> bool {
	if td.workspaces == nil || len(td.workspaces) != 0 do return false
	generation_dir := sharded_generation_path(data_dir, generation)
	defer delete(generation_dir)
	// Opening the writers performs WAL tail recovery before strict replay. This
	// preserves the durable prefix after a process dies during the final record.
	if !init_shard_writer_registry(&td.shard_writers, generation_dir, worker, worker_count) do return false
	initialized := false
	defer if !initialized {
		shutdown_shard_writer_registry(&td.shard_writers)
		cleanup_workspaces()
		td.workspaces = make(map[string]^Workspace_State, 256)
		td.task_seq = 0
		td.asset_seq = 0
		td.edge_seq = 0
	}

	max_floors: Shard_High_Water_Requirements
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		owner, assignment_ok := logical_shard_worker(shard, worker_count)
		if !assignment_ok do return false
		if owner != worker do continue
		writer_index := td.shard_writers.writer_index[shard]
		if writer_index < 0 do return false
		writer := &td.shard_writers.writers[writer_index]
		floors, replay_ok := replay_shard_compaction_sequence(writer.shard_dir, writer.manifest, true, false)
		if !replay_ok || floors != writer.floors do return false
		shard_max_requirement(&max_floors.task, floors.task)
		shard_max_requirement(&max_floors.asset, floors.asset)
		shard_max_requirement(&max_floors.edge, floors.edge)
	}
	td.task_seq = max_floors.task
	td.asset_seq = max_floors.asset
	td.edge_seq = max_floors.edge
	initialized = true
	return true
}
