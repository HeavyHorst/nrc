package main

import "core:os"
import "core:strings"
import "core:time"

import "persistence"
import "storage_io"
import "ulid"

SHARD_DISK_SOFT_AVAILABLE_BYTES :: #config(NRC_SHARD_DISK_SOFT_AVAILABLE_BYTES, 2 * 1024 * 1024 * 1024)
SHARD_DISK_HARD_AVAILABLE_BYTES :: #config(NRC_SHARD_DISK_HARD_AVAILABLE_BYTES, 1024 * 1024 * 1024)
SHARD_CLEAN_BACKLOG_SOFT_BYTES :: #config(NRC_SHARD_CLEAN_BACKLOG_SOFT_BYTES, 4 * 1024 * 1024 * 1024)
SHARD_CLEAN_BACKLOG_HARD_BYTES :: #config(NRC_SHARD_CLEAN_BACKLOG_HARD_BYTES, 8 * 1024 * 1024 * 1024)
SHARD_STORAGE_SPACE_CACHE_TTL :: time.Second
SHARD_COMMIT_WINDOW :: #config(NRC_SHARD_COMMIT_WINDOW_MS, 1) * time.Millisecond
SHARD_COMMIT_MAX_BYTES :: #config(NRC_SHARD_COMMIT_MAX_BYTES, 128 * 1024)
SHARD_COMMIT_PENDING_MAX_BYTES :: 32 * 1024 * 1024

Shard_Compaction_Status :: enum u8 {
	Idle,
	Sealed,
	Building,
}

Shard_Sweep_Metrics :: struct {
	runs:                   u64,
	ordinary_runs:          u64,
	raw_runs:               u64,
	input_bytes:            u64,
	dirty_bytes:            u64,
	prefix_read_bytes:      u64,
	latest_read_bytes:      u64,
	measure_read_bytes:     u64,
	copy_read_bytes:        u64,
	replay_read_bytes:      u64,
	metadata_fallbacks:     u64,
	metadata_written_bytes: u64,
}

Shard_Transaction_Writer :: struct {
	wal:                        persistence.WAL_State,
	storage:                    storage_io.Context,
	fsync_in_flight:            bool,
	fsync_snapshot:             persistence.WAL_Fsync_Snapshot,
	fsync_started:              time.Time,
	// Registry-owned writers batch writes; standalone writers retain immediate writes.
	batch_writes:               bool,
	commit_pending:             bool,
	commit_started:             time.Time,
	durability_generation:      u64,
	durability_waiters:         [dynamic]Connection_Handle,
	shard:                      int,
	owner_worker:               int,
	worker_count:               int,
	floors:                     Shard_High_Water_Requirements,
	poisoned:                   bool,
	managed:                    bool,
	shard_dir:                  string,
	manifest:                   Shard_Compaction_Manifest,
	catalog:                    Shard_Segment_Catalog,
	catalog_floors:             Shard_High_Water_Requirements,
	catalog_segments:           int,
	clean_cursor:               int,
	clean_sweep_generation:     u64,
	catalog_bytes:              u64,
	clean_backlog_bytes:        u64,
	raw_catalog_segments:       int,
	active_wal_append_only:     bool,
	prepared_active_generation: u64,
	deferred_requests:          [dynamic]Shard_Deferred_Request,
	deferred_request_bytes:     int,
	available_disk_bytes:       u64,
	space_known:                bool,
	space_checked_at:           time.Time,
	compaction:                 Shard_Compaction_Status,
	compaction_floors:          Shard_High_Water_Requirements,
	sweep_metrics:              Shard_Sweep_Metrics,
}

Shard_Append_Failure :: enum u8 {
	None,
	Backpressure,
	Deferred,
}

@(thread_local)
shard_append_failure: Shard_Append_Failure

consume_shard_append_backpressure :: proc() -> bool {
	backpressured := shard_append_failure == .Backpressure
	shard_append_failure = .None
	return backpressured
}

consume_shard_append_deferred :: proc() -> bool {
	deferred := shard_append_failure == .Deferred
	if deferred do shard_append_failure = .None
	return deferred
}

refresh_shard_writer_catalog_bytes :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil do return false
	total: u64
	backlog: u64
	raw_segments: int
	for descriptor in writer.catalog.segments {
		size, size_ok := shard_segment_descriptor_size(writer.storage, writer.shard_dir, descriptor)
		if !size_ok do return false
		total = size > max(u64) - total ? max(u64) : total + size
		if descriptor.kind == .Generation_WAL {
			backlog = size > max(u64) - backlog ? max(u64) : backlog + size
			raw_segments += 1
		}
	}
	writer.catalog_bytes = total
	writer.clean_backlog_bytes = backlog
	writer.raw_catalog_segments = raw_segments
	return true
}

refresh_shard_writer_storage_space :: proc(writer: ^Shard_Transaction_Writer, force := false) -> bool {
	if writer == nil do return false
	now := ulid.time_now()
	if !force && writer.space_checked_at != (time.Time{}) && time.diff(writer.space_checked_at, now) < SHARD_STORAGE_SPACE_CACHE_TTL do return true
	space, space_err := storage_io.storage_space(writer.storage, writer.shard_dir)
	if space_err != nil do return false
	writer.available_disk_bytes = space.available_bytes
	writer.space_known = true
	writer.space_checked_at = now
	return true
}

shard_writer_backpressured :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil do return true
	disk_hard := false
	if writer.managed {
		if !refresh_shard_writer_storage_space(writer) do return true
		disk_hard = writer.available_disk_bytes <= SHARD_DISK_HARD_AVAILABLE_BYTES
	}
	return disk_hard || writer.clean_backlog_bytes >= SHARD_CLEAN_BACKLOG_HARD_BYTES
}

shard_writer_soft_storage_pressure :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil do return false
	disk_soft := false
	if writer.managed {
		if !refresh_shard_writer_storage_space(writer) do return true
		disk_soft = writer.available_disk_bytes <= SHARD_DISK_SOFT_AVAILABLE_BYTES
	}
	return disk_soft || writer.clean_backlog_bytes >= SHARD_CLEAN_BACKLOG_SOFT_BYTES
}

Shard_Writer_Scan_Context :: struct {
	shard:    int,
	previous: Shard_High_Water_Requirements,
	apply:    bool,
}

@(thread_local)
shard_writer_scan_context: Shard_Writer_Scan_Context

Shard_Replay_Apply_Fault :: struct {
	armed: bool,
	shard: int,
}

@(thread_local)
shard_replay_apply_fault: Shard_Replay_Apply_Fault

set_shard_replay_apply_failure_for_test :: proc(shard: int) {
	shard_replay_apply_fault = {
		armed = true,
		shard = shard,
	}
}

clear_shard_replay_apply_failure_for_test :: proc() {
	shard_replay_apply_fault = {}
}

shard_writer_scan_record :: proc(op: u8, version: u16, payload: []byte) -> bool {
	ctx := &shard_writer_scan_context
	if op != u8(Shard_Log_Op.Transaction) || version != SHARD_WAL_VERSION do return false
	view, decode_err := decode_shard_transaction(payload)
	if decode_err != .None || int(shard_for_workspace(view.workspace)) != ctx.shard do return false
	next, validate_err := validate_shard_transaction_view(&view, ctx.previous)
	if validate_err != .None do return false
	if !visit_shard_transaction_mutations(&view, validate_workspace_data_origin, &view) do return false
	if ctx.apply && shard_replay_apply_fault.armed && shard_replay_apply_fault.shard == ctx.shard {
		shard_replay_apply_fault.armed = false
		return false
	}
	if ctx.apply && !visit_shard_transaction_mutations(&view, apply_shard_transaction_mutation, &view) do return false
	ctx.previous = next
	return true
}

scan_shard_transaction_wal :: proc {
	scan_shard_transaction_wal_host,
	scan_shard_transaction_wal_with_storage,
}

scan_shard_transaction_wal_host :: proc(
	path: string,
	shard: int,
	previous: Shard_High_Water_Requirements,
	apply: bool,
	recover_tail: bool,
) -> (
	inspection: persistence.Strict_WAL_Inspection,
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	return scan_shard_transaction_wal_with_storage(storage_io.host_context(), path, shard, previous, apply, recover_tail)
}

scan_shard_transaction_wal_with_storage :: proc(
	storage: storage_io.Context,
	path: string,
	shard: int,
	previous: Shard_High_Water_Requirements,
	apply: bool,
	recover_tail: bool,
) -> (
	inspection: persistence.Strict_WAL_Inspection,
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	if shard < 0 || shard >= LOGICAL_SHARD_COUNT || apply && td.workspaces == nil do return
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	shard_writer_scan_context = {
		shard    = shard,
		previous = previous,
		apply    = apply,
	}
	defer {shard_writer_scan_context = {}}
	if recover_tail {
		inspection = persistence.inspect_wal_file_with_tail_recovery(storage, path, SHARD_WAL_MAGIC, shard, shard_writer_scan_record)
	} else {
		inspection = persistence.inspect_wal_file_strict(storage, path, SHARD_WAL_MAGIC, shard, shard_writer_scan_record)
	}
	floors = shard_writer_scan_context.previous
	return inspection, floors, inspection.ok
}

// Replays a normal post-cutover shard WAL into isolated, unpublished state.
// Validation of each complete transaction precedes its mutation traversal.
replay_shard_transaction_wal :: proc(
	path: string,
	shard: int,
) -> (
	inspection: persistence.Strict_WAL_Inspection,
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	return scan_shard_transaction_wal(path, shard, {}, true, false)
}

replay_shard_compaction_sequence :: proc {
	replay_shard_compaction_sequence_host,
	replay_shard_compaction_sequence_with_storage,
}

replay_shard_compaction_sequence_host :: proc(
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	apply: bool,
	recover_active_tail: bool,
	replayed_record_count: ^u64 = nil,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	return replay_shard_compaction_sequence_with_storage(storage_io.host_context(), shard_dir, manifest, apply, recover_active_tail, replayed_record_count)
}

replay_shard_compaction_sequence_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	apply: bool,
	recover_active_tail: bool,
	replayed_record_count: ^u64 = nil,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	if !shard_compaction_manifest_is_valid(manifest) do return
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	if replayed_record_count != nil do replayed_record_count^ = 0
	if manifest.checkpoint_present {
		if manifest.segmented {
			catalog, catalog_ok := load_shard_segment_catalog(storage, shard_dir, manifest.checkpoint_generation)
			if !catalog_ok || catalog.shard != manifest.shard do return floors, false
			defer destroy_shard_segment_catalog(&catalog)
			for descriptor in catalog.segments {
				path := shard_segment_descriptor_path(shard_dir, descriptor)
				if path == "" do return floors, false
				inspection, next, replay_ok := scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
				delete(path)
				if !replay_ok do return floors, false
				if replayed_record_count != nil do replayed_record_count^ += inspection.record_count
				floors = next
			}
		} else {
			path := shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation)
			inspection, next, replay_ok := scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
			delete(path)
			if !replay_ok do return floors, false
			if replayed_record_count != nil do replayed_record_count^ += inspection.record_count
			floors = next
		}
	}
	if manifest.sealed_present {
		path := shard_generation_wal_path(shard_dir, manifest.sealed_generation)
		inspection, next, replay_ok := scan_shard_transaction_wal(storage, path, manifest.shard, floors, apply, false)
		delete(path)
		if !replay_ok do return floors, false
		if replayed_record_count != nil do replayed_record_count^ += inspection.record_count
		floors = next
	}
	active_path := shard_generation_wal_path(shard_dir, manifest.active_generation)
	inspection, next_floors, replay_ok := scan_shard_transaction_wal(storage, active_path, manifest.shard, floors, apply, recover_active_tail)
	delete(active_path)
	if !replay_ok do return floors, false
	if replayed_record_count != nil do replayed_record_count^ += inspection.record_count
	if apply && !validate_replayed_shard_edges(manifest.shard) do return floors, false
	return next_floors, true
}

init_shard_transaction_writer :: proc(writer: ^Shard_Transaction_Writer, path: string, shard, owner_worker, worker_count: int) -> bool {
	if writer == nil || writer.wal.enabled || writer.poisoned do return false
	owner, assignment_ok := logical_shard_worker(shard, worker_count)
	if !assignment_ok || owner != owner_worker do return false
	info, stat_err := os.lstat(path, context.temp_allocator)
	if stat_err != nil do return false
	defer os.file_info_delete(info, context.temp_allocator)
	if info.type != .Regular do return false
	if !persistence.init_wal(&writer.wal, path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION, shard, nrc_wal_time_now) do return false
	shard_writer_scan_context = {
		shard = shard,
	}
	inspection := persistence.inspect_wal_file_with_tail_recovery(path, SHARD_WAL_MAGIC, shard, shard_writer_scan_record)
	floors := shard_writer_scan_context.previous
	shard_writer_scan_context = {}
	if !inspection.ok {
		persistence.shutdown_wal(&writer.wal)
		writer^ = {}
		return false
	}
	persistence.set_recovered_wal_state(&writer.wal, inspection.last_hash, inspection.record_count)
	writer.shard = shard
	writer.storage = storage_io.host_context()
	writer.owner_worker = owner_worker
	writer.worker_count = worker_count
	writer.floors = floors
	return true
}

init_managed_shard_transaction_writer :: proc {
	init_managed_shard_transaction_writer_host,
	init_managed_shard_transaction_writer_with_storage,
}

init_managed_shard_transaction_writer_host :: proc(writer: ^Shard_Transaction_Writer, shard_dir: string, shard, owner_worker, worker_count: int) -> bool {
	return init_managed_shard_transaction_writer_with_storage(writer, storage_io.host_context(), shard_dir, shard, owner_worker, worker_count)
}

init_managed_shard_transaction_writer_with_storage :: proc(
	writer: ^Shard_Transaction_Writer,
	storage: storage_io.Context,
	shard_dir: string,
	shard, owner_worker, worker_count: int,
) -> bool {
	if writer == nil || writer.wal.enabled || writer.poisoned do return false
	owner, assignment_ok := logical_shard_worker(shard, worker_count)
	if !assignment_ok || owner != owner_worker do return false
	manifest, manifest_ok := ensure_shard_compaction_manifest(storage, shard_dir, shard)
	if !manifest_ok do return false
	active_path := shard_generation_wal_path(shard_dir, manifest.active_generation)
	defer delete(active_path)
	if !persistence.init_wal(&writer.wal, storage, active_path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION, shard, nrc_wal_time_now) do return false
	floors, replay_ok := replay_shard_compaction_sequence(storage, shard_dir, manifest, false, true)
	if !replay_ok {
		persistence.shutdown_wal(&writer.wal)
		writer^ = {}
		return false
	}
	cloned_dir, clone_err := strings.clone(shard_dir)
	if clone_err != nil {
		persistence.shutdown_wal(&writer.wal)
		writer^ = {}
		return false
	}
	// Each manifest member has an independent hash chain. The complete sequence
	// above validates cross-file high-water monotonicity; this second active-only
	// scan restores the append hash and record counters.
	active_inspection, active_floors, active_ok := scan_shard_transaction_wal(storage, active_path, shard, {}, false, false)
	_ = active_floors
	if !active_ok {
		delete(cloned_dir)
		persistence.shutdown_wal(&writer.wal)
		writer^ = {}
		return false
	}
	persistence.set_recovered_wal_state(&writer.wal, active_inspection.last_hash, active_inspection.record_count)
	writer.shard = shard
	writer.storage = storage
	writer.owner_worker = owner_worker
	writer.worker_count = worker_count
	writer.floors = floors
	writer.managed = true
	writer.shard_dir = cloned_dir
	writer.manifest = manifest
	writer.active_wal_append_only = active_inspection.record_count == 0
	writer.compaction = manifest.sealed_present ? .Sealed : .Idle
	if manifest.checkpoint_present {
		if manifest.segmented {
			catalog, catalog_ok := load_shard_segment_catalog(storage, shard_dir, manifest.checkpoint_generation)
			if !catalog_ok {
				shutdown_shard_transaction_writer(writer)
				return false
			}
			writer.catalog = catalog
			writer.catalog_segments = len(catalog.segments)
			if !refresh_shard_writer_catalog_bytes(writer) {
				shutdown_shard_transaction_writer(writer)
				return false
			}
		}
		writer.catalog_floors, replay_ok = replay_shard_checkpoint_input(storage, shard_dir, manifest, false)
		if !replay_ok {
			shutdown_shard_transaction_writer(writer)
			return false
		}
	}
	if manifest.sealed_present {
		writer.compaction_floors, replay_ok = replay_shard_checkpoint_input(storage, shard_dir, manifest, false)
		if !replay_ok {
			shutdown_shard_transaction_writer(writer)
			return false
		}
	}
	return true
}

shutdown_shard_transaction_writer :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	if writer == nil do return true
	assert(!writer.fsync_in_flight, "shard writer shutdown requires drained async fsync")
	discard_shard_deferred_requests(writer)
	delete(writer.durability_waiters)
	ok := persistence.shutdown_wal(&writer.wal)
	if writer.prepared_active_generation != 0 {
		if !remove_shard_active_reservation(writer.storage, writer.shard_dir, writer.prepared_active_generation) do ok = false
		if storage_io.sync_directory(writer.storage, writer.shard_dir) != nil do ok = false
	}
	destroy_shard_segment_catalog(&writer.catalog)
	if writer.shard_dir != "" do delete(writer.shard_dir)
	writer^ = {}
	return ok
}

append_shard_transaction :: proc(writer: ^Shard_Transaction_Writer, tx: ^Shard_Transaction) -> bool {
	shard_append_failure = .None
	if writer == nil || tx == nil || writer.poisoned || !writer.wal.enabled do return false
	if writer.batch_writes && writer.wal.pending_bytes + u64(writer.wal.write_offset) >= SHARD_COMMIT_PENDING_MAX_BYTES {
		if defer_current_shard_protocol_request(writer) {
			shard_append_failure = .Deferred
		} else {
			shard_append_failure = .Backpressure
		}
		return false
	}
	if shard_writer_backpressured(writer) {
		shard_append_failure = .Backpressure
		return false
	}
	if int(shard_for_workspace(tx.workspace)) != writer.shard do return false
	owner, assignment_ok := logical_shard_worker(writer.shard, writer.worker_count)
	if !assignment_ok || owner != writer.owner_worker do return false
	next, validation_err := validate_shard_transaction(tx, writer.floors)
	if validation_err != .None do return false
	payload_size, size_err := shard_transaction_size(tx)
	if size_err != .None do return false
	record := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(record)
	if encode_shard_transaction(tx, record[persistence.LOG_HEADER_SIZE:]) != .None do return false
	current_wal_bytes := persistence.get_file_size(&writer.wal)
	if writer.managed && current_wal_bytes > 0 && u64(len(record)) > SHARD_WAL_SEGMENT_MAX_BYTES - min(SHARD_WAL_SEGMENT_MAX_BYTES, current_wal_bytes) {
		if writer.fsync_in_flight && defer_current_shard_protocol_request(writer) {
			shard_append_failure = .Deferred
			return false
		}
		if !rotate_shard_writer_for_compaction(writer) {
			if !writer.poisoned do shard_append_failure = .Backpressure
			return false
		}
		if shard_writer_backpressured(writer) {
			shard_append_failure = .Backpressure
			return false
		}
	}
	if !persistence.finalize_and_write_record_deferred_fsync(&writer.wal, u8(Shard_Log_Op.Transaction), record) ||
	   (!writer.batch_writes && !persistence.flush_write_batch_deferred_fsync(&writer.wal)) {
		writer.poisoned = true
		return false
	}
	if !writer.commit_pending {
		writer.commit_pending = true
		writer.commit_started = writer.wal.get_time()
	}
	append_only := writer.active_wal_append_only && shard_transaction_is_append_only(tx, writer.floors)
	writer.floors = next
	writer.active_wal_append_only = append_only
	return true
}

shard_transaction_is_append_only :: proc(tx: ^Shard_Transaction, previous: Shard_High_Water_Requirements) -> bool {
	if tx == nil || len(tx.mutations) == 0 do return false
	floors := previous
	for mutation in tx.mutations {
		if !shard_mutation_advances_append_only_floor(mutation, &floors) do return false
	}
	return true
}

shard_mutation_advances_append_only_floor :: proc(mutation: Shard_Mutation, floors: ^Shard_High_Water_Requirements) -> bool {
	if floors == nil || !shard_mutation_is_create(mutation) do return false
	id, id_ok := shard_mutation_entity_id(mutation)
	if !id_ok do return false
	switch mutation.domain {
	case .Task:
		if id <= floors.task do return false
		floors.task = id
	case .Asset:
		if id <= floors.asset do return false
		floors.asset = id
	case .Edge:
		if id <= floors.edge do return false
		floors.edge = id
	}
	return true
}

shard_mutation_is_create :: proc(mutation: Shard_Mutation) -> bool {
	switch mutation.domain {
	case .Task:
		return mutation.op == u8(Task_Log_Op.Create)
	case .Asset:
		return mutation.op == u8(Asset_Log_Op.Create)
	case .Edge:
		return mutation.op == u8(Edge_Log_Op.Create)
	}
	return false
}

persist_and_apply_shard_delete_transaction :: proc(writer: ^Shard_Transaction_Writer, tx: ^Shard_Transaction) -> bool {
	if tx == nil do return false
	for mutation in tx.mutations {
		is_delete :=
			mutation.domain == .Task && mutation.op == u8(Task_Log_Op.Delete) ||
			mutation.domain == .Asset && mutation.op == u8(Asset_Log_Op.Delete) ||
			mutation.domain == .Edge && mutation.op == u8(Edge_Log_Op.Delete)
		if !is_delete do return false
	}
	if !append_shard_transaction(writer, tx) do return false
	for mutation in tx.mutations {
		if !apply_shard_mutation(tx.workspace, mutation) {
			writer.poisoned = true
			writer.wal.enabled = false
			return false
		}
	}
	return true
}
