package main

import "core:strings"
import "core:sync/chan"
import "core:time"
import "persistence"
import "storage_io"

EXPERIMENT_ASYNC_MESSAGE_DELETE :: #config(EXPERIMENT_ASYNC_MESSAGE_DELETE, false)

// Refusal keeps the frozen holder for maintenance to retry. No worker memory
// crosses the queue, and shutdown may safely leave the unreferenced file behind.
enqueue_message_source_delete :: proc(store: ^Message_Store, generation: u64) -> bool {
	context.allocator = worker_backing_allocator()
	directory, err := strings.clone(store.directory)
	if err != nil do return false
	job := Shard_Compaction_Job {
		allocator                 = context.allocator,
		message_remove_generation = generation,
		owner_worker              = td.thread_index,
		shard                     = store.shard,
		storage                   = store.storage,
		shard_dir                 = directory,
	}
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && nrc_sim_runtime.compaction_job_event_submission {
			return(
				sim_world_enqueue_event(
					&nrc_sim_runtime.world,
					nrc_sim_runtime.world.now,
					{kind = .Storage, id = u64(store.shard)},
					.Compaction_Job,
					Sim_Event_Payload(Sim_Compaction_Job_Event{job = job}),
				) !=
				0 \
			)
		}
	}
	if chan.try_send(td.server.shard_compaction_jobs, job) do return true
	delete(directory)
	return false
}

frozen_message_descriptor :: proc(frozen: ^Message_Store) -> Message_Segment_Descriptor {
	return {
		generation = frozen.active_generation,
		first_seq = frozen.active_first_seq,
		last_seq = frozen.high_water,
		min_time = frozen.active_min_time,
		max_time = frozen.active_max_time,
		bytes = frozen.active_bytes,
	}
}

destroy_frozen_message_store :: proc(store: ^Message_Store, remove_source: bool) {
	frozen := store.frozen
	if frozen == nil do return
	assert(frozen.async_readers == 0)
	// Close before dispatch: otherwise the worker's final close can perform the
	// eviction after the service unlinks the still-open file.
	if frozen.active_read_file != nil {storage_io.discard(frozen.active_read_file); frozen.active_read_file = nil}
	if remove_source {
		if EXPERIMENT_ASYNC_MESSAGE_DELETE && message_seal_service_available() {
			if !enqueue_message_source_delete(store, frozen.active_generation) do return
		} else {
			path := message_store_path(store.directory, frozen.active_generation, "wal"); defer delete(path)
			_ = storage_io.remove(store.storage, path)
			_ = storage_io.sync_directory(store.storage, store.directory)
		}
	}
	destroy_active_message_indexes(frozen)
	free(frozen)
	store.frozen = nil
	store.frozen_published = false
}

// A remains recoverable until the durable manifest explicitly names both A and
// B. Generation A+1 is reserved for clustered output, A+2 for the next writer.
roll_message_store :: proc(store: ^Message_Store, now_ns: i64) -> bool {
	assert(store.frozen == nil && store.async_readers == 0 && !store.fsync_in_flight)
	assert(len(store.pending_appends) == 0 && store.wal.write_offset == 0)
	if store.active_generation > max(u64) - 2 || len(store.segments) >= MESSAGE_MAX_SEGMENTS do return false
	// Publication later appends without moving any descriptor borrowed by a
	// sealed reader. Initial rollover already requires the old readers drained.
	if reserve(&store.segments, len(store.segments) + 1) != nil do return false
	persistence.force_fsync(&store.wal)
	if !store.wal.enabled || store.wal.durable_record_count != store.wal.record_count do return false
	if !persistence.shutdown_wal(&store.wal) do return false
	next := store.active_generation + 2
	path := message_store_path(store.directory, next, "wal"); defer delete(path)
	_ = storage_io.remove(store.storage, path)
	if !create_empty_message_wal_with_storage(store.storage, path) do return false
	if !persistence.init_wal_with_storage(&store.wal, store.storage, path, MESSAGE_WAL_MAGIC, MESSAGE_WAL_VERSION, store.shard, nrc_wal_time_now) do return false
	frozen := new(Message_Store)
	frozen^ = {
		directory           = store.directory,
		storage             = store.storage,
		shard               = store.shard,
		active_generation   = store.active_generation,
		active_first_seq    = store.active_first_seq,
		high_water          = store.high_water,
		active_min_time     = store.active_min_time,
		active_max_time     = store.active_max_time,
		active_bytes        = store.active_bytes,
		active_read_file    = store.active_read_file,
		active_index_arena  = store.active_index_arena,
		active_arena_ready  = store.active_arena_ready,
		active_record_arena = store.active_record_arena,
		active_record_ready = store.active_record_ready,
		active_cached_bytes = store.active_cached_bytes,
		active_cache_budget = store.active_cache_budget,
		active_dedup        = store.active_dedup,
		active_offsets      = store.active_offsets,
	}
	store.frozen = frozen
	store.active_generation = next
	store.active_first_seq = 0; store.active_min_time = 0; store.active_max_time = 0; store.active_bytes = 0
	store.active_read_file = nil
	store.active_index_arena = nil; store.active_arena_ready = false
	store.active_record_arena = nil; store.active_record_ready = false; store.active_cached_bytes = 0
	store.active_dedup = nil; store.active_offsets = nil
	store.active_started_hour = now_ns / i64(time.Hour)
	store.fsync_snapshot = {}; store.commit_pending = false
	if !write_message_manifest(store) do return false
	store.rotation_pending = false
	resume_durable_outboxes(&store.durability_waiters)
	return true
}

// B's writer and durability state are untouched. Old history snapshots retain
// the frozen holder until their own borrows end; new snapshots use the index.
publish_frozen_message_seal :: proc(store: ^Message_Store) -> bool {
	if !message_store_enabled(store) || store.frozen == nil || store.frozen_published do return false
	descriptor := frozen_message_descriptor(store.frozen)
	descriptor.generation += 1
	if store.seal_bytes != descriptor.bytes do return false
	data := read_validated_message_segment_index(store, descriptor); defer delete(data)
	if data == nil || !load_message_segment_index_metadata(store, &descriptor, true, data) do return false
	assert(len(store.segments) < cap(store.segments))
	append(&store.segments, descriptor)
	store.frozen_published = true
	if !write_message_manifest(store) do return false
	store.seal_in_flight = false; store.seal_ready = false
	if store.frozen.async_readers == 0 do destroy_frozen_message_store(store, true)
	return true
}

// Startup has no readers or admitted writes. Finish a pending immutable source
// synchronously, but never replay it as active or infer an orphan into the set.
recover_frozen_message_seal :: proc(store: ^Message_Store) -> bool {
	if store.frozen == nil do return true
	path := message_store_path(store.directory, store.active_generation, "wal"); defer delete(path)
	exists, err := storage_io.exists(store.storage, path)
	if err != nil || !exists do return false
	bytes, ok := cluster_message_segment_wal(store, store.frozen.active_generation, store.frozen.active_generation + 1)
	if !ok || bytes != store.frozen.active_bytes do return false
	descriptor := frozen_message_descriptor(store.frozen)
	descriptor.generation += 1
	data := read_validated_message_segment_index(store, descriptor); defer delete(data)
	if data == nil do return false
	if _, append_err := append(&store.segments, descriptor); append_err != nil do return false
	store.frozen_published = true
	if !write_message_manifest(store) do return false
	destroy_frozen_message_store(store, true)
	return true
}

message_seal_service_available :: proc() -> bool {
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && nrc_sim_runtime.compaction_job_event_submission do return true
	}
	// Standalone stores/tests without a service retain direct rotation.
	return td.server != nil && td.server.shard_compaction_jobs.impl != nil
}

cancel_message_seals :: proc(registry: ^Message_Store_Registry) {
	for &store in registry.stores {
		store.rotation_pending = false
		// Do not unfreeze the source while the service may still be reading it.
		// Job-owned paths survive store destruction; unreferenced output is safe
		// to leave for recovery, which trusts only the old manifest.
		retained_message_fail_deferred(&store)
	}
}

// One seal per store; queue rejection is retried while B continues appending.
enqueue_message_seal :: proc(store: ^Message_Store, now_ns: i64) -> bool {
	if store.seal_in_flight do return true
	if store.frozen == nil && !roll_message_store(store, now_ns) {
		store.poisoned = true
		return false
	}
	if store.frozen_published do return true
	// Only immutable job inputs cross to the service; the frozen store above
	// remains worker-owned and uses the worker's long-lived allocator.
	context.allocator = worker_backing_allocator()
	directory, err := strings.clone(store.directory)
	if err != nil {store.poisoned = true; return false}
	job := Shard_Compaction_Job {
		allocator                 = context.allocator,
		message_source_generation = store.frozen.active_generation,
		owner_worker              = td.thread_index,
		shard                     = store.shard,
		storage                   = store.storage,
		shard_dir                 = directory,
	}
	submitted := false
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil {
			id := sim_world_enqueue_event(
				&nrc_sim_runtime.world,
				nrc_sim_runtime.world.now,
				{kind = .Storage, id = u64(store.shard)},
				.Compaction_Job,
				Sim_Event_Payload(Sim_Compaction_Job_Event{job = job}),
			)
			// Rejected events consume their payload, including the directory.
			if id == 0 do return true
			submitted = true
		}
	}
	if !submitted && !chan.try_send(td.server.shard_compaction_jobs, job) {
		delete(directory)
		return true
	}
	store.seal_in_flight = true
	return true
}

process_message_seal_result :: proc(result: Shard_Compaction_Result) -> bool {
	// Results own no live store memory or file handles. Ignore duplicates and
	// stale identities without deleting files a newer manifest may reference.
	if result.owner_worker != td.thread_index || result.shard < 0 || result.shard >= LOGICAL_SHARD_COUNT do return true
	i := td.message_stores.store_index[result.shard]
	if i < 0 || int(i) >= len(td.message_stores.stores) do return true
	store := &td.message_stores.stores[i]
	if store.shard != result.shard || !store.seal_in_flight || store.seal_ready || store.frozen == nil || store.frozen.active_generation != result.message_source_generation do return true
	if !result.ok {
		store.poisoned = true
		retained_message_fail_deferred(store)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	store.seal_bytes = result.message_sealed_bytes
	store.seal_ready = true
	retained_message_schedule_store_flush(store)
	return true
}
