package main

import "core:log"
import "core:strings"
import "core:sync/chan"
import "persistence"
import "storage_io"

Storage_Lifecycle_Kind :: enum {
	Shard_Rotate,
	Shard_Publish,
	Message_Roll,
	Message_Seal,
	Message_Retain,
}

Storage_Lifecycle_Shard :: struct {
	using state: Shard_Storage_State,
	wal:         persistence.WAL_Metadata,
}

Storage_Lifecycle_Message :: struct {
	using state: Message_Storage_State,
	wal:         persistence.WAL_Metadata,
	segments:    [dynamic]Message_Segment_Descriptor,
	frozen:      Message_Segment_Descriptor,
	seal_bytes:  u64,
}

// Detached, backing-allocator-owned snapshots. They contain no worker indexes,
// arenas, readers, waiters, append buffers, or borrowed file objects.
Storage_Lifecycle :: struct {
	kind:        Storage_Lifecycle_Kind,
	writer:      ^Storage_Lifecycle_Shard,
	store:       ^Storage_Lifecycle_Message,
	publication: Shard_Compaction_Result,
	index_data:  []byte,
	identity:    u64,
	now_ns:      i64,
	ok:          bool,
}

@(thread_local)
storage_lifecycle_on_service: bool

storage_lifecycle_available :: proc() -> bool {
	return !storage_lifecycle_on_service && td.state == .Running && message_seal_service_available()
}

destroy_storage_lifecycle :: proc(plan: ^Storage_Lifecycle) {
	if plan == nil do return
	if plan.writer != nil {
		storage_io.discard(plan.writer.wal.file)
		delete(plan.writer.wal.path, plan.writer.wal.path_allocator)
		delete(plan.writer.shard_dir)
		destroy_shard_segment_catalog(&plan.writer.catalog)
		free(plan.writer)
	}
	if plan.store != nil {
		storage_io.discard(plan.store.wal.file)
		delete(plan.store.wal.path, plan.store.wal.path_allocator)
		delete(plan.store.directory)
		// Snapshots have no metadata; only the newly sealed descriptor can own it.
		if plan.kind == .Message_Seal && len(plan.store.segments) > 0 {
			destroy_message_segment_metadata(nil, plan.store.segments[len(plan.store.segments) - 1:])
		}
		delete(plan.store.segments)
		free(plan.store)
	}
	destroy_shard_compaction_result(&plan.publication, false)
	delete(plan.index_data)
	free(plan)
}

submit_storage_lifecycle :: proc(plan: ^Storage_Lifecycle, shard: int) -> bool {
	job := Shard_Compaction_Job {
		allocator    = context.allocator,
		owner_worker = td.thread_index,
		shard        = shard,
		lifecycle    = plan,
	}
	when NRC_SIMULATION {
		if nrc_sim_runtime != nil && nrc_sim_runtime.compaction_job_event_submission {
			event_id := sim_world_enqueue_event(
				&nrc_sim_runtime.world,
				nrc_sim_runtime.world.now,
				{kind = .Storage, id = u64(shard)},
				.Compaction_Job,
				Sim_Event_Payload(Sim_Compaction_Job_Event{job = job}),
			)
			// The simulator destroys rejected payloads; this is terminal, not
			// a recoverable channel refusal, even with assertions disabled.
			if event_id == 0 do panic("simulation lifecycle event submission failed")
			return true
		}
	}
	if chan.try_send(td.server.shard_compaction_jobs, job) do return true
	return false
}

enqueue_shard_lifecycle :: proc(writer: ^Shard_Transaction_Writer, kind: Storage_Lifecycle_Kind) -> bool {
	if writer.lifecycle_in_flight || writer.write_in_flight || writer.fsync_in_flight || writer.wal.write_offset != 0 do return false
	context.allocator = worker_backing_allocator()
	plan := new(Storage_Lifecycle)
	plan.kind = kind; plan.identity = writer.manifest.manifest_generation
	snapshot := new(Storage_Lifecycle_Shard)
	plan.writer = snapshot
	snapshot^ = {
		state = writer.state,
		wal   = writer.wal.metadata,
	}
	snapshot.wal.file = nil; snapshot.wal.virtual_file = nil
	snapshot.wal.path, _ = strings.clone(writer.wal.path)
	snapshot.wal.path_allocator = context.allocator
	snapshot.shard_dir, _ = strings.clone(writer.shard_dir)
	snapshot.catalog = writer.catalog
	snapshot.catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(writer.catalog.segments))
	copy(snapshot.catalog.segments[:], writer.catalog.segments[:])
	if kind == .Shard_Publish {
		assert(writer.pending_publication != nil)
		plan.publication = writer.pending_publication^
		writer.pending_publication^ = {
			allocator = plan.publication.allocator,
		}
	}
	if !submit_storage_lifecycle(plan, writer.shard) {
		// Rejection leaves the pending result intact for the next attempt.
		if kind == .Shard_Publish {
			writer.pending_publication^ = plan.publication
			plan.publication = {}
		}
		destroy_storage_lifecycle(plan)
		return false
	}
	writer.lifecycle_in_flight = true
	return true
}

enqueue_message_lifecycle :: proc(store: ^Message_Store, kind: Storage_Lifecycle_Kind, now_ns: i64 = 0) -> bool {
	if store.lifecycle_in_flight || store.write_in_flight || store.fsync_in_flight && kind != .Message_Seal || store.wal.write_offset != 0 || len(store.pending_appends) != 0 do return false
	if (kind == .Message_Roll || kind == .Message_Retain) && store.async_readers != 0 do return false
	if kind == .Message_Roll && reserve(&store.segments, len(store.segments) + 1) != nil do return false
	context.allocator = worker_backing_allocator()
	plan := new(Storage_Lifecycle)
	plan.kind = kind; plan.identity = store.active_generation; plan.now_ns = now_ns
	snapshot := new(Storage_Lifecycle_Message)
	plan.store = snapshot
	snapshot^ = {
		state      = store.state,
		wal        = store.wal.metadata,
		seal_bytes = store.seal_bytes,
	}
	snapshot.wal.file = nil; snapshot.wal.virtual_file = nil
	snapshot.wal.path, _ = strings.clone(store.wal.path)
	snapshot.wal.path_allocator = context.allocator
	snapshot.directory, _ = strings.clone(store.directory)
	snapshot.segments = make([dynamic]Message_Segment_Descriptor, len(store.segments), len(store.segments) + 1)
	for segment, i in store.segments {
		snapshot.segments[i] = {
			generation = segment.generation,
			first_seq  = segment.first_seq,
			last_seq   = segment.last_seq,
			min_time   = segment.min_time,
			max_time   = segment.max_time,
			bytes      = segment.bytes,
		}
	}
	if store.frozen != nil do snapshot.frozen = frozen_message_descriptor(store.frozen)
	if !submit_storage_lifecycle(plan, store.shard) {
		destroy_storage_lifecycle(plan)
		return false
	}
	store.lifecycle_in_flight = true
	return true
}

run_storage_lifecycle :: proc(plan: ^Storage_Lifecycle) {
	previous := storage_lifecycle_on_service
	storage_lifecycle_on_service = true
	defer storage_lifecycle_on_service = previous
	// Existing synchronous storage routines get an execution-local writer.
	// Its append buffer is never allocated, initialized or copied by the owner.
	if plan.writer != nil {
		writer := Shard_Transaction_Writer {
			state = plan.writer.state,
		}
		writer.wal.metadata = plan.writer.wal
		switch plan.kind {
		case .Shard_Rotate:
			writer.wal.file, _ = storage_io.open_wal(writer.storage, writer.wal.path)
			plan.ok = writer.wal.file != nil && rotate_shard_writer_for_compaction(&writer)
		case .Shard_Publish:
			plan.ok = publish_shard_compaction_result(&writer, plan.publication)
			if plan.ok do plan.ok = accept_shard_active_reservation(&writer, plan.publication)
		case .Message_Roll, .Message_Seal, .Message_Retain:
			unreachable()
		}
		if !plan.ok {storage_io.discard(writer.wal.file); writer.wal.file = nil}
		plan.writer.state = writer.state; plan.writer.wal = writer.wal.metadata
		return
	}
	store := Message_Store {
		state      = plan.store.state,
		segments   = plan.store.segments,
		seal_bytes = plan.store.seal_bytes,
	}
	store.wal.metadata = plan.store.wal
	switch plan.kind {
	case .Message_Roll:
		store.wal.file, _ = storage_io.open_wal(store.storage, store.wal.path)
		plan.ok = store.wal.file != nil && roll_message_store(&store, plan.now_ns)
		// This storage-only holder has no indexes or readers to retain.
		if store.frozen != nil do free(store.frozen)
	case .Message_Seal:
		descriptor := plan.store.frozen; descriptor.generation += 1
		plan.index_data = read_validated_message_segment_index(&store, descriptor)
		if plan.index_data != nil && store.seal_bytes == descriptor.bytes {
			if _, err := append(&store.segments, descriptor); err == nil {
				// Service allocations use the job's thread-safe backing allocator.
				// Build once here; the owner only transfers the resulting metadata.
				sealed := &store.segments[len(store.segments) - 1]
				if load_message_segment_index_metadata(&store, sealed, true, plan.index_data) {
					store.frozen_published = true
					plan.ok = write_message_manifest(&store)
				}
			}
		}
	case .Message_Retain:
		plan.ok = maintain_message_store(&store, plan.now_ns, sync_wal = false)
	case .Shard_Rotate, .Shard_Publish:
		unreachable()
	}
	if !plan.ok {storage_io.discard(store.wal.file); store.wal.file = nil}
	plan.store.state = store.state; plan.store.wal = store.wal.metadata; plan.store.segments = store.segments
}

// Only ownership/memory changes happen on the worker after durable publication.
adopt_lifecycle_wal :: proc(target: ^persistence.WAL_State, source: ^persistence.WAL_Metadata) {
	assert(target.write_offset == 0 && source.write_offset == 0)
	nrc_io_discard_read_file(target.file)
	delete(target.path, target.path_allocator)
	target.metadata = source^
	source.file = nil; source.path = ""
}

process_storage_lifecycle_result :: proc(result: ^Shard_Compaction_Result) -> bool {
	plan := result.lifecycle
	if plan.writer != nil {
		i := td.shard_writers.writer_index[result.shard]
		if i < 0 || int(i) >= len(td.shard_writers.writers) do return false
		w := &td.shard_writers.writers[i]
		assert(w.lifecycle_in_flight && w.manifest.manifest_generation == plan.identity)
		w.lifecycle_in_flight = false
		if !plan.ok {
			if plan.kind == .Shard_Rotate && !plan.writer.poisoned && plan.writer.manifest.manifest_generation == plan.identity {
				// Before publication the old WAL is still authoritative. Its sync
				// may have succeeded, but the triggering requests need explicit
				// backpressure instead of retrying a failed create indefinitely.
				s := &plan.writer.wal
				w.wal.durable_last_hash = s.durable_last_hash; w.wal.durable_record_count = s.durable_record_count
				w.wal.pending_bytes = s.pending_bytes; w.wal.last_fsync = s.last_fsync
				w.prepared_active_generation = plan.writer.prepared_active_generation
				for request in w.deferred_requests {
					if c := connection_from_io_context(request.connection); c != nil && c.state < .Will_Close {
						log.warnf("[T%d] Persistent request rejected by shard storage backpressure for workspace %s", td.thread_index, c.workspace_id)
						send_websocket_close_frame_and_close(c, 1013, "Server too busy")
					}
				}
				discard_shard_deferred_requests(w)
				resume_shard_durable_outboxes(w)
				return true
			}
			w.poisoned = true
			server_shutdown_after_storage_error(td.server)
			return false
		}
		s := plan.writer
		if plan.kind == .Shard_Rotate do adopt_lifecycle_wal(&w.wal, &s.wal)
		w.manifest = s.manifest; w.floors = s.floors; w.catalog_floors = s.catalog_floors
		w.durability_generation = s.durability_generation
		destroy_shard_segment_catalog(&w.catalog)
		w.catalog = s.catalog
		s.catalog = {}
		w.catalog_segments = s.catalog_segments; w.catalog_bytes = s.catalog_bytes
		w.clean_backlog_bytes = s.clean_backlog_bytes; w.raw_catalog_segments = s.raw_catalog_segments
		w.clean_cursor = s.clean_cursor; w.clean_sweep_generation = s.clean_sweep_generation
		w.active_wal_append_only = s.active_wal_append_only; w.prepared_active_generation = s.prepared_active_generation
		w.compaction = s.compaction; w.compaction_floors = s.compaction_floors
		if plan.kind == .Shard_Publish {
			record_shard_sweep_metrics(w, plan.publication.segments)
			allocator := w.pending_publication.allocator
			destroy_shard_compaction_result(w.pending_publication, false)
			free(w.pending_publication, allocator); w.pending_publication = nil
		}
		if plan.kind == .Shard_Rotate do w.commit_pending = false
		resume_shard_durable_outboxes(w)
		drain_shard_deferred_requests(w)
		return true
	}
	i := td.message_stores.store_index[result.shard]
	if i < 0 || int(i) >= len(td.message_stores.stores) do return false
	s := &td.message_stores.stores[i]
	assert(s.lifecycle_in_flight && s.active_generation == plan.identity)
	s.lifecycle_in_flight = false
	if !plan.ok {
		s.poisoned = true; s.rotation_pending = false
		_ = retained_message_finish_staged_batch(s, false)
		retained_message_fail_deferred(s)
		server_shutdown_after_storage_error(td.server)
		return false
	}
	switch plan.kind {
	case .Message_Roll:
		adopt_lifecycle_wal(&s.wal, &plan.store.wal)
		freeze_message_store_active(s, plan.store.active_generation, plan.now_ns)
		s.rotation_pending = false
		resume_durable_outboxes(&s.durability_waiters)
		_ = enqueue_message_seal(s, plan.now_ns)
	case .Message_Seal:
		sealed := &plan.store.segments[len(plan.store.segments) - 1]
		descriptor := sealed^
		sealed.dedup_filter = nil; sealed.conversation_ranges = nil
		dedup_offset := int(message_get_u64(plan.index_data[40:]))
		cache_message_segment_index(s, &descriptor, plan.index_data[MESSAGE_INDEX_HEADER_SIZE:dedup_offset])
		assert(len(s.segments) < cap(s.segments))
		append(&s.segments, descriptor)
		s.frozen_published = true; s.seal_in_flight = false; s.seal_ready = false
		if s.frozen.async_readers == 0 do destroy_frozen_message_store(s, true)
	case .Message_Retain:
		removed := len(s.segments) - len(plan.store.segments)
		assert(removed > 0 && s.async_readers == 0)
		destroy_message_segment_metadata(s, s.segments[:removed])
		copy(s.segments[:], s.segments[removed:]); resize(&s.segments, len(s.segments) - removed)
		s.total_bytes = plan.store.total_bytes; s.purge_floor_ns = plan.store.purge_floor_ns
	case .Shard_Rotate, .Shard_Publish:
		unreachable()
	}
	if len(s.deferred_appends) > 0 do retained_message_stage_deferred(s)
	// A duplicate flush may have been consumed while publication gated writes.
	if len(s.pending_appends) > 0 do retained_message_schedule_store_flush(s)
	if td.shard_writers.mode == .Active {
		index := td.shard_writers.writer_index[result.shard]
		if index >= 0 && int(index) < len(td.shard_writers.writers) do drain_shard_deferred_requests(&td.shard_writers.writers[index])
	}
	return true
}
