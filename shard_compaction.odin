package main

import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync"
import "core:sync/chan"
import "core:time"

import "persistence"
import "spsc"
import "storage_io"
import "ulid"

SHARD_WAL_SEGMENT_MAX_BYTES :: #config(NRC_SHARD_COMPACTION_SIZE_THRESHOLD, 500 * 1024 * 1024)
SHARD_COMPACTION_FAULT_STAGE_ENV :: "NRC_TEST_COMPACTION_PAUSE_STAGE"
SHARD_COMPACTION_FAULT_MARKER :: ".nrc-compaction-fault-stage"

// Manifest-driven segmented compaction for one logical shard:
//
//   IDLE / normal writes
//
//     shard.manifest                    files selected by manifest
//     +---------------------------+     +------------------------+
//     | catalog    = C (optional) |---->| catalog-C.cat          |
//     | sealed     = none         |     +------------------------+
//     | active     = A            |---->| wal-A.wal (append here)|
//     +---------------------------+     +------------------------+
//                    |
//                    | active reaches threshold: fsync A; create+fsync B;
//                    | append A to a new durable catalog; publish manifest
//                    v
//   ROLLED / writes and later rolls continue during cleaning
//
//     +---------------------------+     +------------------------+
//     | catalog    = C'           |---->| catalog-C'.cat         |
//     | members    = [..., A]     |---->| wal-A.wal (immutable)  |
//     | active     = B            |---->| wal-B.wal (append here)|
//     +---------------------------+     +------------------------+
//                    |
//                    | background thread selects a bounded catalog group
//                    | cleans latest keys and verifies replay equivalence
//                    v
//   PUBLISH (owner worker only)
//
//     cleaned-N.tmp --rename+dir-fsync--> cleaned-N.seg
//                                          |
//                                          v
//     rebase over catalog members appended by later rolls;
//     fsync catalog-N.cat; publish manifest with the latest active WAL
//                                          |
//                                          v
//     delete only replaced catalog members; return to IDLE
//
// The manifest is the authority after every crash. Startup strictly replays
// ordered catalog members -> sealed -> active, recovering an interrupted tail
// only in the active WAL. Unreferenced files are never guessed into replay.
// Generation 0 uses the bootstrap filename active.wal; later generations use
// the wal-N.wal names shown above.

Shard_Compactor_Thread_Data :: struct {
	server: ^NRC_Server,
}

Shard_Compaction_Job :: struct {
	allocator:                     mem.Allocator, // Thread-safe ownership across the worker/service boundary.
	message_source_generation:     u64, // Nonzero selects immutable retained WAL sealing.
	owner_worker:                  int,
	shard:                         int,
	storage:                       storage_io.Context,
	manifest:                      Shard_Compaction_Manifest,
	checkpoint_generation:         u64,
	shard_dir:                     string,
	source:                        Shard_Segment_Clean_Source,
	source_present:                bool,
	clean_start:                   int,
	source_max_bytes:              u64,
	raw_backlog_priority:          bool,
	expected_source_floors:        Shard_High_Water_Requirements,
	active_reservation_generation: u64,
}

Shard_Compaction_Result :: struct {
	allocator:                     mem.Allocator,
	message_source_generation:     u64,
	message_sealed_bytes:          u64,
	owner_worker:                  int,
	shard:                         int,
	manifest_generation:           u64,
	checkpoint_generation:         u64,
	floors:                        Shard_High_Water_Requirements,
	segments:                      Shard_Segment_Clean_Result,
	active_reservation_generation: u64,
	active_reservation_prepared:   bool,
	active_reservation_storage:    storage_io.Context,
	active_reservation_path:       string,
	ok:                            bool,
}

destroy_shard_compaction_job :: proc(job: ^Shard_Compaction_Job) {
	allocator := context.allocator
	if job.allocator.procedure != nil do allocator = job.allocator
	context.allocator = allocator
	if job.shard_dir != "" do delete(job.shard_dir)
	if job.source_present do destroy_shard_segment_clean_source(&job.source)
	job^ = {}
}

destroy_shard_compaction_result :: proc(result: ^Shard_Compaction_Result, remove_reservation: bool) {
	if result == nil do return
	allocator := context.allocator
	if result.allocator.procedure != nil do allocator = result.allocator
	context.allocator = allocator
	if result.active_reservation_path != "" {
		if remove_reservation do _ = storage_io.remove(result.active_reservation_storage, result.active_reservation_path)
		delete(result.active_reservation_path)
	}
	destroy_shard_segment_clean_result(&result.segments)
	result^ = {}
}

// Real-process crash tests use this opt-in stop point to kill the production
// binary at exact durable-publication boundaries. It is inert unless the
// test-only environment variable names this stage.
shard_compaction_pause_for_process_fault_test :: proc(stage: string) {
	configured_stage, found := os.lookup_env_alloc(SHARD_COMPACTION_FAULT_STAGE_ENV, context.allocator)
	if !found do return
	defer delete(configured_stage)
	if configured_stage != stage do return
	if os.write_entire_file(SHARD_COMPACTION_FAULT_MARKER, transmute([]byte)stage) != nil do return
	for do time.sleep(time.Second)
}

shard_compaction_next_file_generation :: proc {
	shard_compaction_next_file_generation_host,
	shard_compaction_next_file_generation_with_storage,
}

shard_compaction_next_file_generation_host :: proc(shard_dir: string, manifest: Shard_Compaction_Manifest) -> (generation: u64, ok: bool) {
	return shard_compaction_next_file_generation_with_storage(storage_io.host_context(), shard_dir, manifest)
}

shard_compaction_next_file_generation_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
) -> (
	generation: u64,
	ok: bool,
) {
	generation = manifest.active_generation
	if manifest.sealed_present && manifest.sealed_generation > generation do generation = manifest.sealed_generation
	if manifest.checkpoint_present && manifest.checkpoint_generation > generation do generation = manifest.checkpoint_generation
	return shard_compaction_next_file_generation_after(storage, shard_dir, generation)
}

shard_compaction_next_file_generation_after :: proc(storage: storage_io.Context, shard_dir: string, generation: u64) -> (u64, bool) {
	current := generation
	for {
		if current == max(u64) do return 0, false
		current += 1
		// A crash can leave a fully durable new active WAL before its manifest
		// publication. It is unreferenced and must not permanently block the
		// next exclusive create; skip it without ever replaying or deleting it.
		path := shard_generation_wal_path(shard_dir, current)
		exists, exists_err := storage_io.exists(storage, path)
		delete(path)
		if exists_err != nil do return 0, false
		if exists do continue
		catalog_path := shard_segment_catalog_path(shard_dir, current)
		catalog_exists, catalog_exists_err := storage_io.exists(storage, catalog_path)
		delete(catalog_path)
		if catalog_exists_err != nil do return 0, false
		if catalog_exists do continue
		cleaned_path := shard_cleaned_segment_path(shard_dir, current)
		cleaned_exists, cleaned_exists_err := storage_io.exists(storage, cleaned_path)
		delete(cleaned_path)
		if cleaned_exists_err != nil do return 0, false
		if !cleaned_exists do return current, true
	}
}

remove_shard_active_reservation :: proc(storage: storage_io.Context, shard_dir: string, generation: u64) -> bool {
	if generation == 0 do return true
	path := shard_generation_wal_path(shard_dir, generation)
	remove_err := storage_io.remove(storage, path)
	delete(path)
	return remove_err == nil
}

reserve_shard_active_generation :: proc(storage: storage_io.Context, shard_dir: string, after_generation: u64) -> (generation: u64, ok: bool) {
	generation_ok: bool
	generation, generation_ok = shard_compaction_next_file_generation_after(storage, shard_dir, after_generation)
	if !generation_ok do return 0, false
	path := shard_generation_wal_path(shard_dir, generation)
	defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Write, .Create, .Excl, .Append}, os.perm(0o644))
	if open_err != nil do return 0, false
	if close_err := storage_io.close(file); close_err != nil {
		remove_shard_active_reservation(storage, shard_dir, generation)
		return 0, false
	}
	return generation, true
}

prepare_shard_active_reservation :: proc(storage: storage_io.Context, shard_dir: string, generation: u64) -> bool {
	if generation == 0 do return false
	path := shard_generation_wal_path(shard_dir, generation)
	defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Write, .Append}, os.perm(0o644))
	if open_err != nil do return false
	size, size_err := storage_io.file_size(file)
	sync_ok := size_err == nil && size == 0 && storage_io.sync(file) == nil
	close_err := storage_io.close(file)
	if !sync_ok || close_err != nil || storage_io.sync_directory(storage, shard_dir) != nil {
		remove_shard_active_reservation(storage, shard_dir, generation)
		return false
	}
	return true
}

shard_writer_authoritative_generation :: proc(writer: ^Shard_Transaction_Writer) -> u64 {
	if writer == nil do return 0
	generation := writer.manifest.active_generation
	if writer.manifest.sealed_present && writer.manifest.sealed_generation > generation do generation = writer.manifest.sealed_generation
	if writer.manifest.checkpoint_present && writer.manifest.checkpoint_generation > generation do generation = writer.manifest.checkpoint_generation
	for descriptor in writer.catalog.segments do if descriptor.generation > generation do generation = descriptor.generation
	return generation
}

shard_writer_generation_referenced :: proc(writer: ^Shard_Transaction_Writer, generation: u64) -> bool {
	if writer == nil || generation == 0 do return false
	if writer.manifest.active_generation == generation || writer.manifest.sealed_present && writer.manifest.sealed_generation == generation {
		return true
	}
	candidate := Shard_Segment_Descriptor{.Generation_WAL, generation}
	for descriptor in writer.catalog.segments do if shard_segment_descriptors_share_file(candidate, descriptor) do return true
	return false
}

shard_prepared_active_is_usable :: proc(writer: ^Shard_Transaction_Writer, generation: u64) -> (usable, integrity_ok: bool) {
	if writer == nil || generation == 0 || generation <= shard_writer_authoritative_generation(writer) do return false, true
	path := shard_generation_wal_path(writer.shard_dir, generation)
	defer delete(path)
	file, open_err := storage_io.open(writer.storage, path, {.Write, .Append}, os.perm(0o644))
	if open_err != nil do return false, false
	size, size_err := storage_io.file_size(file)
	close_err := storage_io.close(file)
	if size_err != nil || size != 0 || close_err != nil do return false, false
	catalog_path := shard_segment_catalog_path(writer.shard_dir, generation)
	catalog_exists, catalog_err := storage_io.exists(writer.storage, catalog_path)
	delete(catalog_path)
	if catalog_err != nil do return false, false
	if catalog_exists do return false, true
	cleaned_path := shard_cleaned_segment_path(writer.shard_dir, generation)
	cleaned_exists, cleaned_err := storage_io.exists(writer.storage, cleaned_path)
	delete(cleaned_path)
	if cleaned_err != nil do return false, false
	return !cleaned_exists, true
}

accept_shard_active_reservation :: proc(writer: ^Shard_Transaction_Writer, result: Shard_Compaction_Result) -> bool {
	generation := result.active_reservation_generation
	if generation == 0 do return true
	if !result.active_reservation_prepared {
		remove_shard_active_reservation(writer.storage, writer.shard_dir, generation)
		return true
	}
	usable, integrity_ok := shard_prepared_active_is_usable(writer, generation)
	if !integrity_ok do return false
	if writer.prepared_active_generation != 0 || !usable {
		if !shard_writer_generation_referenced(writer, generation) {
			remove_shard_active_reservation(writer.storage, writer.shard_dir, generation)
		}
		return true
	}
	writer.prepared_active_generation = generation
	return true
}

rotate_shard_writer_for_compaction :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	rotation_started := ulid.time_now()
	if writer == nil ||
	   !writer.managed ||
	   writer.poisoned ||
	   !writer.wal.enabled ||
	   writer.fsync_in_flight ||
	   writer.manifest.sealed_present ||
	   writer.compaction == .Sealed {
		return false
	}
	ordinary_sweep_current := !writer.manifest.checkpoint_present || writer.clean_sweep_generation == writer.manifest.checkpoint_generation
	rolled_wal_append_only := writer.active_wal_append_only
	source, source_ok := shard_segment_source_for_writer(writer)
	if !source_ok || len(source.segments) >= SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return false
	defer destroy_shard_segment_clean_source(&source)
	next_generation := writer.prepared_active_generation
	prepared_active := false
	prepared_integrity_ok := true
	if next_generation != 0 {
		prepared_active, prepared_integrity_ok = shard_prepared_active_is_usable(writer, next_generation)
	}
	if !prepared_integrity_ok {
		writer.poisoned = true
		return false
	}
	if next_generation != 0 && !prepared_active {
		if !shard_writer_generation_referenced(writer, next_generation) {
			remove_shard_active_reservation(writer.storage, writer.shard_dir, next_generation)
		}
		writer.prepared_active_generation = 0
	}
	if !prepared_active {
		generation_ok: bool
		next_generation, generation_ok = shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
		if !generation_ok do return false
	}
	prepare_elapsed := time.diff(rotation_started, ulid.time_now())

	stage_started := ulid.time_now()
	injected_sync_failure := shard_compaction_fault_hit(.Sealed_WAL_Sync)
	if injected_sync_failure do persistence.set_wal_sync_failure_for_test()
	persistence.force_fsync(&writer.wal)
	if injected_sync_failure do persistence.clear_wal_sync_failure_for_test()
	if !writer.wal.enabled || writer.wal.durable_record_count != writer.wal.record_count {
		writer.poisoned = true
		return false
	}
	writer.commit_pending = false
	// The old prefix is durable even if later rotation preparation fails. Wake
	// its waiters only after the rotation's final state is settled.
	defer if !writer.poisoned && writer.wal.enabled do resume_shard_durable_outboxes(writer)
	wal_sync_elapsed := time.diff(stage_started, ulid.time_now())
	stage_started = ulid.time_now()
	new_active_path := shard_generation_wal_path(writer.shard_dir, next_generation)
	defer delete(new_active_path)
	if !prepared_active {
		if shard_compaction_fault_hit(.New_Active_Create) do return false
		new_file, open_err := storage_io.open(writer.storage, new_active_path, {.Write, .Create, .Excl, .Append}, os.perm(0o644))
		if open_err != nil do return false
		sync_ok := !shard_compaction_fault_hit(.New_Active_Sync) && storage_io.sync(new_file) == nil
		close_err := storage_io.close(new_file)
		directory_synced := false
		if sync_ok && close_err == nil {
			directory_synced = !shard_compaction_fault_hit(.New_Active_Directory_Sync) && storage_io.sync_directory(writer.storage, writer.shard_dir) == nil
		}
		if !sync_ok || close_err != nil || !directory_synced {
			_ = storage_io.remove(writer.storage, new_active_path)
			return false
		}
	}
	shard_compaction_pause_for_process_fault_test("rotation")
	new_active_elapsed := time.diff(stage_started, ulid.time_now())

	stage_started = ulid.time_now()
	next_catalog := Shard_Segment_Catalog {
		shard              = writer.shard,
		catalog_generation = next_generation,
		segments           = make([dynamic]Shard_Segment_Descriptor, len(source.segments) + 1),
	}
	owned_catalog := true
	defer if owned_catalog do destroy_shard_segment_catalog(&next_catalog)
	copy(next_catalog.segments[:len(source.segments)], source.segments[:])
	next_catalog.segments[len(source.segments)] = {.Generation_WAL, writer.manifest.active_generation}
	if !write_shard_segment_catalog(writer.storage, writer.shard_dir, next_catalog) {
		if prepared_active do writer.prepared_active_generation = 0
		_ = storage_io.remove(writer.storage, new_active_path)
		catalog_path := shard_segment_catalog_path(writer.shard_dir, next_generation)
		_ = storage_io.remove(writer.storage, catalog_path)
		delete(catalog_path)
		return false
	}
	catalog_elapsed := time.diff(stage_started, ulid.time_now())

	stage_started = ulid.time_now()
	next_manifest := writer.manifest
	if next_manifest.manifest_generation == max(u64) {
		if prepared_active do writer.prepared_active_generation = 0
		_ = storage_io.remove(writer.storage, new_active_path)
		catalog_path := shard_segment_catalog_path(writer.shard_dir, next_generation)
		_ = storage_io.remove(writer.storage, catalog_path)
		delete(catalog_path)
		return false
	}
	next_manifest.manifest_generation += 1
	next_manifest.checkpoint_present = true
	next_manifest.checkpoint_generation = next_generation
	next_manifest.segmented = true
	next_manifest.sealed_present = false
	next_manifest.sealed_generation = 0
	next_manifest.active_generation = next_generation
	publish_result := publish_shard_compaction_manifest(writer.storage, writer.shard_dir, next_manifest)
	if publish_result != .Published {
		if publish_result == .Failed_Unpublished {
			if prepared_active do writer.prepared_active_generation = 0
			_ = storage_io.remove(writer.storage, new_active_path)
			catalog_path := shard_segment_catalog_path(writer.shard_dir, next_generation)
			_ = storage_io.remove(writer.storage, catalog_path)
			delete(catalog_path)
		} else {
			if prepared_active do writer.prepared_active_generation = 0
			writer.poisoned = true
		}
		return false
	}
	if prepared_active do writer.prepared_active_generation = 0
	manifest_elapsed := time.diff(stage_started, ulid.time_now())

	stage_started = ulid.time_now()
	old_floors := writer.floors
	persistence.shutdown_wal(&writer.wal)
	writer.durability_generation += 1
	if !persistence.init_wal(&writer.wal, writer.storage, new_active_path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION, writer.shard, nrc_wal_time_now) {
		writer.poisoned = true
		return false
	}
	writer.floors = old_floors
	old_manifest := writer.manifest
	writer.manifest = next_manifest
	writer.catalog_floors = old_floors
	destroy_shard_segment_catalog(&writer.catalog)
	writer.catalog = next_catalog
	owned_catalog = false
	writer.catalog_segments = len(writer.catalog.segments)
	if !refresh_shard_writer_catalog_bytes(writer) {
		writer.poisoned = true
		return false
	}
	writer.clean_cursor = 0
	writer.clean_sweep_generation = rolled_wal_append_only && ordinary_sweep_current ? writer.manifest.checkpoint_generation : 0
	writer.active_wal_append_only = true
	if old_manifest.segmented {
		old_catalog := shard_segment_catalog_path(writer.shard_dir, old_manifest.checkpoint_generation)
		if !shard_compaction_fault_hit(.Old_Checkpoint_Remove) do _ = storage_io.remove(writer.storage, old_catalog)
		delete(old_catalog)
	}
	if !shard_compaction_fault_hit(.Cleanup_Directory_Sync) do _ = storage_io.sync_directory(writer.storage, writer.shard_dir)
	finalize_elapsed := time.diff(stage_started, ulid.time_now())
	total_elapsed := time.diff(rotation_started, ulid.time_now())
	log.infof(
		"[T%d] Shard %d rotation timing total=%v prepare=%v wal_sync=%v new_active=%v catalog=%v manifest=%v finalize=%v prepared_active=%v generation=%d members=%d",
		writer.owner_worker,
		writer.shard,
		total_elapsed,
		prepare_elapsed,
		wal_sync_elapsed,
		new_active_elapsed,
		catalog_elapsed,
		manifest_elapsed,
		finalize_elapsed,
		prepared_active,
		writer.manifest.active_generation,
		writer.catalog_segments,
	)
	return true
}

shard_writer_catalog_cleaning_ready :: proc(writer: ^Shard_Transaction_Writer) -> bool {
	return(
		writer != nil &&
		!writer.manifest.sealed_present &&
		writer.compaction == .Idle &&
		writer.catalog_segments > 0 &&
		(writer.raw_catalog_segments > 0 || writer.clean_sweep_generation != writer.manifest.checkpoint_generation) \
	)
}

shard_compaction_cleaning_plan :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	source: Shard_Segment_Clean_Source,
	clean_cursor: int,
	prioritize_raw: bool,
) -> (
	clean_start: int,
	source_max_bytes: u64,
	raw_backlog_priority: bool,
	ok: bool,
) {
	cursor := clean_cursor
	if cursor < 0 || cursor >= len(source.segments) do cursor = 0
	if prioritize_raw {
		for index := len(source.segments) - 1; index >= 0; index -= 1 {
			if source.segments[index].kind != .Generation_WAL do continue
			size, size_ok := shard_segment_descriptor_size(storage, shard_dir, source.segments[index])
			if !size_ok do return
			return index, size, true, true
		}
	}
	return cursor, SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES, false, true
}

enqueue_shard_compaction_job :: proc(server: ^NRC_Server, writer: ^Shard_Transaction_Writer) -> bool {
	if server == nil || writer == nil || !writer.managed do return false
	context.allocator = worker_backing_allocator()
	legacy_sealed := writer.manifest.sealed_present && writer.compaction == .Sealed
	catalog_ready := shard_writer_catalog_cleaning_ready(writer)
	if !legacy_sealed && !catalog_ready do return false
	source, source_ok := shard_segment_source_for_writer(writer)
	if !source_ok do return false
	source_owned := true
	defer if source_owned do destroy_shard_segment_clean_source(&source)
	clean_start, source_max_bytes, raw_backlog_priority, plan_ok := shard_compaction_cleaning_plan(
		writer.storage,
		writer.shard_dir,
		source,
		writer.clean_cursor,
		writer.manifest.segmented,
	)
	if !plan_ok do return false
	checkpoint_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	if !generation_ok do return false
	reservation_generation: u64
	reservation_owned := false
	if raw_backlog_priority && writer.prepared_active_generation == 0 {
		reservation_generation, reservation_owned = reserve_shard_active_generation(writer.storage, writer.shard_dir, checkpoint_generation)
	}
	defer if reservation_owned do remove_shard_active_reservation(writer.storage, writer.shard_dir, reservation_generation)
	cloned_dir, clone_err := strings.clone(writer.shard_dir)
	if clone_err != nil do return false
	job := Shard_Compaction_Job {
		allocator                     = context.allocator,
		owner_worker                  = writer.owner_worker,
		shard                         = writer.shard,
		storage                       = writer.storage,
		manifest                      = writer.manifest,
		checkpoint_generation         = checkpoint_generation,
		shard_dir                     = cloned_dir,
		source                        = source,
		source_present                = true,
		clean_start                   = clean_start,
		source_max_bytes              = source_max_bytes,
		raw_backlog_priority          = raw_backlog_priority,
		expected_source_floors        = writer.catalog_floors,
		active_reservation_generation = reservation_generation,
	}
	submitted_as_event := false
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && nrc_sim_runtime.compaction_job_event_submission {
			event_id := sim_world_enqueue_event(
				&nrc_sim_runtime.world,
				nrc_sim_runtime.world.now,
				{kind = .Storage, id = u64(writer.shard)},
				.Compaction_Job,
				Sim_Event_Payload(Sim_Compaction_Job_Event{job = job}),
			)
			if event_id == 0 {
				// The event queue consumed and destroyed the transferred job.
				source_owned = false
				return false
			}
			submitted_as_event = true
		}
	}
	if !submitted_as_event {
		if !chan.try_send(server.shard_compaction_jobs, job) {
			delete(cloned_dir)
			return false
		}
	}
	reservation_owned = false
	source_owned = false
	writer.compaction = .Building
	if catalog_ready do writer.compaction_floors = writer.catalog_floors
	return true
}

when NRC_SIMULATION {
	enqueue_shard_compaction_job_event :: proc(world: ^Sim_World, writer: ^Shard_Transaction_Writer) -> bool {
		if world == nil || writer == nil || !writer.managed do return false
		context.allocator = worker_backing_allocator()
		legacy_sealed := writer.manifest.sealed_present && writer.compaction == .Sealed
		catalog_ready := shard_writer_catalog_cleaning_ready(writer)
		if !legacy_sealed && !catalog_ready do return false
		source, source_ok := shard_segment_source_for_writer(writer)
		if !source_ok do return false
		source_owned := true
		defer if source_owned do destroy_shard_segment_clean_source(&source)
		clean_start, source_max_bytes, raw_backlog_priority, plan_ok := shard_compaction_cleaning_plan(
			writer.storage,
			writer.shard_dir,
			source,
			writer.clean_cursor,
			writer.manifest.segmented,
		)
		if !plan_ok do return false
		checkpoint_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
		if !generation_ok do return false
		reservation_generation: u64
		reservation_owned := false
		if raw_backlog_priority && writer.prepared_active_generation == 0 {
			reservation_generation, reservation_owned = reserve_shard_active_generation(writer.storage, writer.shard_dir, checkpoint_generation)
		}
		defer if reservation_owned do remove_shard_active_reservation(writer.storage, writer.shard_dir, reservation_generation)
		cloned_dir, clone_err := strings.clone(writer.shard_dir)
		if clone_err != nil do return false
		job := Shard_Compaction_Job {
			allocator                     = context.allocator,
			owner_worker                  = writer.owner_worker,
			shard                         = writer.shard,
			storage                       = writer.storage,
			manifest                      = writer.manifest,
			checkpoint_generation         = checkpoint_generation,
			shard_dir                     = cloned_dir,
			source                        = source,
			source_present                = true,
			clean_start                   = clean_start,
			source_max_bytes              = source_max_bytes,
			raw_backlog_priority          = raw_backlog_priority,
			expected_source_floors        = writer.catalog_floors,
			active_reservation_generation = reservation_generation,
		}
		event_id := sim_world_enqueue_event(
			world,
			world.now,
			{kind = .Storage, id = u64(writer.shard)},
			.Compaction_Job,
			Sim_Event_Payload(Sim_Compaction_Job_Event{job = job}),
		)
		if event_id == 0 {
			source_owned = false
			return false
		}
		reservation_owned = false
		source_owned = false
		writer.compaction = .Building
		if catalog_ready do writer.compaction_floors = writer.catalog_floors
		return true
	}
}

run_shard_compaction_job :: proc(job: Shard_Compaction_Job) -> Shard_Compaction_Result {
	allocator := context.allocator
	if job.allocator.procedure != nil do allocator = job.allocator
	context.allocator = allocator
	owned_job := job
	defer destroy_shard_compaction_job(&owned_job)
	if job.message_source_generation != 0 {
		// This value contains only job-owned immutable inputs, never a pointer
		// into the worker's live store, indexes, caches, or allocator arenas.
		build_store := Message_Store {
			directory = job.shard_dir,
			storage   = job.storage,
			shard     = job.shard,
		}
		bytes, ok := cluster_message_segment_wal(&build_store, job.message_source_generation, job.message_source_generation + 1)
		return {
			allocator = allocator,
			owner_worker = job.owner_worker,
			shard = job.shard,
			message_source_generation = job.message_source_generation,
			message_sealed_bytes = bytes,
			ok = ok,
		}
	}
	result := Shard_Compaction_Result {
		allocator             = allocator,
		owner_worker          = job.owner_worker,
		shard                 = job.shard,
		manifest_generation   = job.manifest.manifest_generation,
		checkpoint_generation = job.checkpoint_generation,
	}
	injected_write_failure := shard_compaction_fault_hit(.Checkpoint_Write)
	injected_sync_failure := shard_compaction_fault_hit(.Checkpoint_Sync)
	if injected_write_failure do persistence.set_wal_short_write_for_test(1)
	if injected_sync_failure do persistence.set_wal_sync_failure_for_test()
	source: ^Shard_Segment_Clean_Source
	if job.source_present do source = &owned_job.source
	source_max_bytes := job.source_max_bytes
	if source_max_bytes == 0 do source_max_bytes = SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES
	result.segments = build_shard_segment_catalog(
		job.storage,
		job.shard_dir,
		job.manifest,
		job.checkpoint_generation,
		source,
		job.clean_start,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		source_max_bytes,
		job.raw_backlog_priority ? 1 : 0,
		job.raw_backlog_priority,
		job.expected_source_floors,
	)
	if job.raw_backlog_priority && result.segments.ok do result.segments.next_cursor = 0
	result.floors = result.segments.floors
	result.ok = result.segments.ok
	log.debugf(
		"[T%d] Shard %d compaction reads prefix=%d latest=%d measure=%d copy=%d replay=%d input=%d dirty=%d indexed=%v",
		job.owner_worker,
		job.shard,
		result.segments.prefix_read_bytes,
		result.segments.latest_read_bytes,
		result.segments.measure_read_bytes,
		result.segments.copy_read_bytes,
		result.segments.replay_read_bytes,
		result.segments.input_bytes,
		result.segments.dirty_bytes,
		SHARD_SEGMENT_METADATA_INDEX_ENABLED,
	)
	if injected_write_failure do persistence.clear_wal_write_fault_for_test()
	if injected_sync_failure do persistence.clear_wal_sync_failure_for_test()
	if job.active_reservation_generation != 0 {
		if result.ok {
			result.active_reservation_generation = job.active_reservation_generation
			result.active_reservation_prepared = prepare_shard_active_reservation(job.storage, job.shard_dir, job.active_reservation_generation)
			result.active_reservation_storage = job.storage
			result.active_reservation_path = shard_generation_wal_path(job.shard_dir, job.active_reservation_generation)
		} else {
			remove_shard_active_reservation(job.storage, job.shard_dir, job.active_reservation_generation)
		}
	}
	if result.ok do shard_compaction_pause_for_process_fault_test("checkpoint")
	return result
}

discard_queued_shard_compaction_jobs :: proc(server: ^NRC_Server) {
	if server == nil do return
	for {
		job, received := chan.try_recv(server.shard_compaction_jobs)
		if !received do return
		if job.active_reservation_generation != 0 {
			remove_shard_active_reservation(job.storage, job.shard_dir, job.active_reservation_generation)
		}
		destroy_shard_compaction_job(&job)
	}
}

service_shard_compaction_job :: proc(server: ^NRC_Server) -> bool {
	if server == nil do return false
	job, received := chan.try_recv(server.shard_compaction_jobs)
	if !received do return false
	result := run_shard_compaction_job(job)
	if result.owner_worker >= 0 && result.owner_worker < len(server.shard_compaction_results) {
		if spsc.try_push(server.shard_compaction_results[result.owner_worker], result) do return true
	}
	destroy_shard_compaction_result(&result, true)
	return true
}

discard_queued_shard_compaction_results :: proc(server: ^NRC_Server) {
	if server == nil do return
	for result_queue in server.shard_compaction_results {
		for {
			result, received := spsc.try_pop(result_queue)
			if !received do break
			destroy_shard_compaction_result(&result, true)
		}
	}
}

shard_compactor_thread :: proc(data: Shard_Compactor_Thread_Data) {
	defer sync.wait_group_done(&data.server.wg)
	if !cpu_affinity_disabled() && cpu_role_plan.service_cpu >= 0 {
		set_thread_cpu_affinity(cpu_role_plan.service_cpu)
	}
	for {
		if sync.atomic_load(&data.server.closing) {
			// Workers no longer need results once shutdown starts. Do not make
			// shutdown wait for every queued cleaning job, but release the
			// directory strings transferred with those jobs.
			discard_queued_shard_compaction_jobs(data.server)
			return
		}
		if service_shard_compaction_job(data.server) {
			continue
		}
		time.sleep(10 * time.Millisecond)
	}
}

publish_shard_compaction_result :: proc(writer: ^Shard_Transaction_Writer, result: Shard_Compaction_Result) -> bool {
	if writer == nil ||
	   !writer.managed ||
	   writer.compaction != .Building ||
	   result.shard != writer.shard ||
	   result.owner_worker != writer.owner_worker ||
	   result.manifest_generation > writer.manifest.manifest_generation ||
	   !result.ok ||
	   !shard_segment_clean_result_is_publishable(result.segments) ||
	   result.floors != writer.compaction_floors {
		return false
	}
	if result.segments.catalog.catalog_generation != result.checkpoint_generation || result.checkpoint_generation == 0 {
		return false
	}
	current_source, source_ok := shard_segment_source_for_writer(writer)
	if !source_ok do return false
	defer destroy_shard_segment_clean_source(&current_source)
	ordinary_sweep_current := writer.clean_sweep_generation == writer.manifest.checkpoint_generation
	if !result.segments.output_present && result.segments.removed_count == 0 && writer.manifest.segmented {
		snapshot, snapshot_ok := shard_segment_clean_result_source(result.segments)
		if !snapshot_ok do return false
		defer destroy_shard_segment_clean_source(&snapshot)
		if len(current_source.segments) < len(snapshot.segments) do return false
		for descriptor, index in snapshot.segments do if current_source.segments[index] != descriptor do return false
		writer.compaction = .Idle
		writer.compaction_floors = {}
		if result.segments.next_cursor >= len(current_source.segments) {
			writer.clean_cursor = 0
			writer.clean_sweep_generation = writer.manifest.checkpoint_generation
		} else {
			writer.clean_cursor = result.segments.next_cursor
			writer.clean_sweep_generation = 0
		}
		record_shard_sweep_metrics(writer, result.segments)
		return true
	}
	publication_generation, generation_ok := shard_compaction_next_file_generation(writer.storage, writer.shard_dir, writer.manifest)
	if !generation_ok do return false
	rebased_catalog, rebase_ok := shard_segment_clean_result_rebase(result.segments, current_source, publication_generation)
	if !rebase_ok do return false
	rebased_owned := true
	defer if rebased_owned do destroy_shard_segment_catalog(&rebased_catalog)
	if result.segments.output_present {
		for output, index in result.segments.outputs {
			temp_path := shard_cleaned_segment_temp_path(writer.shard_dir, output.generation)
			final_path := shard_cleaned_segment_path(writer.shard_dir, output.generation)
			rename_ok := !(index == 0 && shard_compaction_fault_hit(.Checkpoint_Rename)) && storage_io.rename(writer.storage, temp_path, final_path) == nil
			delete(temp_path)
			delete(final_path)
			if !rename_ok do return false
		}
		if shard_compaction_fault_hit(.Checkpoint_Directory_Sync) || storage_io.sync_directory(writer.storage, writer.shard_dir) != nil do return false
	}
	if !write_shard_segment_catalog(writer.storage, writer.shard_dir, rebased_catalog) do return false
	shard_compaction_pause_for_process_fault_test("manifest")

	old_manifest := writer.manifest
	next_manifest := old_manifest
	next_manifest.manifest_generation += 1
	next_manifest.checkpoint_present = true
	next_manifest.checkpoint_generation = publication_generation
	next_manifest.segmented = true
	next_manifest.sealed_present = false
	next_manifest.sealed_generation = 0
	publish_result := publish_shard_compaction_manifest(writer.storage, writer.shard_dir, next_manifest)
	if publish_result != .Published {
		if publish_result == .Published_Uncertain do writer.poisoned = true
		return false
	}
	writer.manifest = next_manifest
	if old_manifest.sealed_present do writer.catalog_floors = result.floors
	destroy_shard_segment_catalog(&writer.catalog)
	writer.catalog = rebased_catalog
	rebased_owned = false
	writer.catalog_segments = len(writer.catalog.segments)
	if !refresh_shard_writer_catalog_bytes(writer) {
		writer.poisoned = true
		return false
	}
	preserves_ordinary_sweep := result.segments.raw_fast_path_used && (result.segments.raw_append_only || result.segments.input_bytes == 0)
	if preserves_ordinary_sweep && ordinary_sweep_current {
		writer.clean_cursor = 0
		writer.clean_sweep_generation = writer.manifest.checkpoint_generation
	} else if result.segments.next_cursor >= writer.catalog_segments {
		writer.clean_cursor = 0
		writer.clean_sweep_generation = writer.manifest.checkpoint_generation
	} else {
		writer.clean_cursor = result.segments.next_cursor
		writer.clean_sweep_generation = 0
	}
	writer.compaction = .Idle
	writer.compaction_floors = {}

	if old_manifest.segmented {
		old_catalog := shard_segment_catalog_path(writer.shard_dir, old_manifest.checkpoint_generation)
		if !shard_compaction_fault_hit(.Old_Checkpoint_Remove) do _ = storage_io.remove(writer.storage, old_catalog)
		delete(old_catalog)
	} else if old_manifest.checkpoint_present && result.segments.removed_count > 0 {
		old_checkpoint := shard_checkpoint_wal_path(writer.shard_dir, old_manifest.checkpoint_generation)
		if !shard_compaction_fault_hit(.Old_Checkpoint_Remove) do _ = storage_io.remove(writer.storage, old_checkpoint)
		delete(old_checkpoint)
	}
	for index in 0 ..< result.segments.removed_count {
		descriptor := result.segments.removed[index]
		if descriptor.kind == .Legacy_Checkpoint_WAL && !old_manifest.segmented do continue
		still_referenced := false
		for current in writer.catalog.segments {
			if shard_segment_descriptors_share_file(descriptor, current) {still_referenced = true; break}
		}
		if still_referenced do continue
		metadata_path := shard_segment_metadata_path(writer.shard_dir, descriptor)
		_ = storage_io.remove(writer.storage, metadata_path)
		delete(metadata_path)
		metadata_temp_path := shard_segment_metadata_temp_path(writer.shard_dir, descriptor)
		_ = storage_io.remove(writer.storage, metadata_temp_path)
		delete(metadata_temp_path)
		path := shard_segment_descriptor_path(writer.shard_dir, descriptor)
		if path != "" {
			if !shard_compaction_fault_hit(.Sealed_WAL_Remove) do _ = storage_io.remove(writer.storage, path)
			delete(path)
		}
	}
	if !shard_compaction_fault_hit(.Cleanup_Directory_Sync) do _ = storage_io.sync_directory(writer.storage, writer.shard_dir)
	record_shard_sweep_metrics(writer, result.segments)
	return true
}

record_shard_sweep_metrics :: proc(writer: ^Shard_Transaction_Writer, result: Shard_Segment_Clean_Result) {
	if writer == nil || !result.ok do return
	metrics := Shard_Sweep_Metrics {
		runs                   = 1,
		ordinary_runs          = result.raw_fast_path_used ? 0 : 1,
		raw_runs               = result.raw_fast_path_used ? 1 : 0,
		input_bytes            = result.input_bytes,
		dirty_bytes            = result.dirty_bytes,
		prefix_read_bytes      = result.prefix_read_bytes,
		latest_read_bytes      = result.latest_read_bytes,
		measure_read_bytes     = result.measure_read_bytes,
		copy_read_bytes        = result.copy_read_bytes,
		replay_read_bytes      = result.replay_read_bytes,
		metadata_fallbacks     = result.metadata_fallbacks,
		metadata_written_bytes = result.metadata_written_bytes,
	}
	shard_sweep_metrics_add(&writer.sweep_metrics, metrics)
}

process_shard_compaction_result :: proc(result: Shard_Compaction_Result) -> bool {
	owned_result := result
	defer destroy_shard_compaction_result(&owned_result, false)
	if td.server == nil do return false
	if result.message_source_generation != 0 do return process_message_seal_result(result)
	if result.shard < 0 || result.shard >= len(td.shard_writers.writer_index) {
		log.errorf("[T%d] Invalid shard %d in checkpoint result; shutting down", td.thread_index, result.shard)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	index := td.shard_writers.writer_index[result.shard]
	if index < 0 || int(index) >= len(td.shard_writers.writers) {
		log.errorf("[T%d] Shard %d segment publication owner missing; shutting down", td.thread_index, result.shard)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	writer := &td.shard_writers.writers[index]
	if !publish_shard_compaction_result(writer, result) {
		result_identity_valid := result.segments.catalog.shard == result.shard
		if result_identity_valid &&
		   result.active_reservation_generation != 0 &&
		   result.active_reservation_generation != writer.prepared_active_generation &&
		   !shard_writer_generation_referenced(writer, result.active_reservation_generation) &&
		   !writer.poisoned {
			remove_shard_active_reservation(writer.storage, writer.shard_dir, result.active_reservation_generation)
		}
		log.errorf("[T%d] Shard %d segment publication failed; shutting down", td.thread_index, result.shard)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	if !accept_shard_active_reservation(writer, result) {
		writer.poisoned = true
		log.errorf("[T%d] Shard %d prepared active WAL validation failed; shutting down", td.thread_index, result.shard)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	return true
}

process_shard_compaction_results :: proc() -> bool {
	if td.server == nil || td.thread_index < 0 || td.thread_index >= len(td.server.shard_compaction_results) do return false
	did_work := false
	for {
		result, received := spsc.try_pop(td.server.shard_compaction_results[td.thread_index])
		if !received do return did_work
		did_work = true
		if !process_shard_compaction_result(result) do return true
	}
}

schedule_shard_compaction_work :: proc() -> bool {
	if td.server == nil || td.shard_writers.mode != .Active || len(td.shard_writers.writers) == 0 do return false
	index := td.shard_writers.compaction_cursor % len(td.shard_writers.writers)
	td.shard_writers.compaction_cursor = (index + 1) % len(td.shard_writers.writers)
	writer := &td.shard_writers.writers[index]
	soft_pressure := shard_writer_soft_storage_pressure(writer)
	if writer.compaction == .Sealed {
		return enqueue_shard_compaction_job(td.server, writer)
	}
	if soft_pressure && shard_writer_catalog_cleaning_ready(writer) {
		return enqueue_shard_compaction_job(td.server, writer)
	}
	if !writer.manifest.sealed_present && persistence.get_file_size(&writer.wal) >= SHARD_WAL_SEGMENT_MAX_BYTES {
		if !rotate_shard_writer_for_compaction(writer) {
			if writer.poisoned {
				server_shutdown_after_storage_error(td.server)
				return true
			}
			return false
		}
		if writer.compaction == .Idle do _ = enqueue_shard_compaction_job(td.server, writer)
		return true
	}
	if shard_writer_catalog_cleaning_ready(writer) {
		return enqueue_shard_compaction_job(td.server, writer)
	}
	return false
}
