package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import nbio "nbio/poly"
import "spsc"
import tlsf "vendor/tlsf"

storage_lifecycle_test_service :: proc(server: ^NRC_Server, service_context: runtime.Context) {
	service := thread.create_and_start_with_poly_data(server, proc(s: ^NRC_Server) {_ = service_shard_compaction_job(s)}, service_context)
	thread.join(service)
	thread.destroy(service)
}

@(test)
test_storage_lifecycle_snapshot_budget :: proc(t: ^testing.T) {
	// A full owner or WAL buffer in either snapshot violates this budget.
	testing.expect(t, size_of(Storage_Lifecycle_Shard) < 4096)
	testing.expect(t, size_of(Storage_Lifecycle_Message) < 4096)
	log.infof("Lifecycle snapshot bytes: shard=%d message=%d", size_of(Storage_Lifecycle_Shard), size_of(Storage_Lifecycle_Message))
}

@(test)
test_shard_lifecycle_channel_rotation_publication :: proc(t: ^testing.T) {
	service_context := context
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &service_context.allocator, 64 * 1024))
	defer tlsf.destroy(&heap)
	old_td := new(Server_Thread); old_td^ = td; td = {}
	defer {td = old_td^; free(old_td, service_context.allocator)}
	testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
	server: NRC_Server; td.server = &server
	server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
	defer chan.destroy(server.shard_compaction_jobs)
	server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), 1)
	server.shard_compaction_results[0], _ = spsc.create(Shard_Compaction_Result, 2)
	defer {spsc.destroy(server.shard_compaction_results[0]); delete(server.shard_compaction_results)}
	defer discard_queued_shard_compaction_results(&server)
	defer discard_queued_shard_compaction_jobs(&server)
	td.backing_allocator = service_context.allocator; context.allocator = worker_heap_allocator(&heap)
	dir := test_wal_path("shard-lifecycle-channel"); defer os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	workspace := "shard-lifecycle-channel"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	for &index in td.shard_writers.writer_index do index = -1
	td.shard_writers.writers = make([dynamic]Shard_Transaction_Writer, 1)
	td.shard_writers.writer_index[shard] = 0; td.shard_writers.mode = .Active
	w := &td.shard_writers.writers[0]
	initial_path := shard_generation_wal_path(dir, 0); defer delete(initial_path)
	testing.expect(t, os.write_entire_file(initial_path, []byte{}) == nil)
	testing.expect(t, init_managed_shard_transaction_writer(w, dir, shard, 0, 1))
	defer shutdown_shard_writer_registry(&td.shard_writers)
	testing.expect(t, shard_compaction_test_append_task(w, workspace, 10, "before first roll"))
	w.batch_writes = true
	old_manifest := w.manifest
	testing.expect(t, chan.try_send(server.shard_compaction_jobs, Shard_Compaction_Job{}))
	testing.expect(t, !rotate_shard_writer_for_compaction(w) && !w.poisoned && !w.lifecycle_in_flight)
	testing.expect_value(t, w.manifest, old_manifest)
	_, _ = chan.try_recv(server.shard_compaction_jobs)
	for round in 0 ..< 2 {
		testing.expect(t, rotate_shard_writer_for_compaction(w) && w.lifecycle_in_flight)
		job, queued := chan.try_recv(server.shard_compaction_jobs); assert(queued)
		testing.expect(t, job.lifecycle.writer.wal.file == nil)
		testing.expect(t, !worker_heap_contains_for_test(&heap, job.lifecycle.writer))
		testing.expect(t, !worker_heap_contains_for_test(&heap, raw_data(job.lifecycle.writer.wal.path)))
		assert(chan.try_send(server.shard_compaction_jobs, job))
		generation := w.manifest.active_generation
		storage_lifecycle_test_service(&server, service_context)
		// The disk has advanced, but the owner remains gated until adoption.
		manifest, found, ok := load_shard_compaction_manifest(dir)
		testing.expect(t, found && ok && manifest.active_generation > generation)
		testing.expect_value(t, w.manifest.active_generation, generation)
		testing.expect(t, !shard_compaction_test_append_task(w, workspace, 99, "must not reach old WAL"))
		result, received := spsc.try_pop(server.shard_compaction_results[0]); assert(received)
		incoming_path := raw_data(result.lifecycle.writer.wal.path)
		incoming_catalog := raw_data(result.lifecycle.writer.catalog.segments)
		testing.expect(t, process_shard_compaction_result(result) && !w.lifecycle_in_flight && !w.poisoned)
		testing.expect(t, raw_data(w.wal.path) == incoming_path && raw_data(w.catalog.segments) == incoming_catalog)
		testing.expect_value(t, w.manifest, manifest)
		testing.expect_value(t, w.wal.record_count, u64(0))
		if round == 0 {
			w.batch_writes = false
			testing.expect(t, shard_compaction_test_append_task(w, workspace, 11, "before second roll"))
			w.batch_writes = true
		}
	}
	testing.expect(t, enqueue_shard_compaction_job(&server, w))
	job, queued := chan.try_recv(server.shard_compaction_jobs); assert(queued)
	testing.expect(t, job.checkpoint_generation == 0, "generation discovery must run on the service")
	assert(chan.try_send(server.shard_compaction_jobs, job))
	storage_lifecycle_test_service(&server, service_context)
	testing.expect(t, process_shard_compaction_results() && w.pending_publication != nil)
	pending := w.pending_publication^
	testing.expect(t, chan.try_send(server.shard_compaction_jobs, Shard_Compaction_Job{}))
	testing.expect(t, !schedule_shard_compaction_work() && !w.lifecycle_in_flight)
	testing.expect(t, raw_data(w.pending_publication.segments.catalog.segments) == raw_data(pending.segments.catalog.segments))
	_, _ = chan.try_recv(server.shard_compaction_jobs)
	manifest := w.manifest
	testing.expect(t, schedule_shard_compaction_work() && w.lifecycle_in_flight)
	publication_job, publication_queued := chan.try_recv(server.shard_compaction_jobs); assert(publication_queued)
	testing.expect(t, raw_data(publication_job.lifecycle.publication.segments.catalog.segments) == raw_data(pending.segments.catalog.segments))
	testing.expect(t, len(w.pending_publication.segments.catalog.segments) == 0)
	assert(chan.try_send(server.shard_compaction_jobs, publication_job))
	storage_lifecycle_test_service(&server, service_context)
	testing.expect_value(t, w.manifest, manifest)
	testing.expect(t, process_shard_compaction_results() && w.pending_publication == nil && !w.lifecycle_in_flight)
	testing.expect(t, w.compaction == .Idle && w.floors.task == 11 && w.catalog_segments == len(w.catalog.segments))
	testing.expect(t, w.catalog_bytes > 0 && w.sweep_metrics.runs == 1)
	testing.expect(t, nbio.tick(&td.io, time.Millisecond) == .NONE)
}

@(test)
test_message_retention_lifecycle_publication_and_failure :: proc(t: ^testing.T) {
	for fail_publication in ([2]bool{false, true}) {
		service_context := context
		old_td := new(Server_Thread); old_td^ = td; td = {}
		defer {td = old_td^; free(old_td)}
		server: NRC_Server
		dir := test_wal_path("retention-lifecycle-%v", fail_publication); defer os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil)
		workspace := "retention-lifecycle"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		append(&td.message_stores.stores, Message_Store{})
		s := &td.message_stores.stores[0]
		testing.expect(t, init_message_store(s, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		accepted_at := nrc_time_unix_nanos()
		now := accepted_at + i64(time.Hour) + 1
		for index in 0 ..< 2 {
			message := test_retained_message(workspace, 42, u64(index + 1), accepted_at + i64(index))
			message.fingerprint = message_fingerprint(&message)
			result, _ := append_message_after_sealed_lookup(s, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			testing.expect(t, rotate_message_store(s, now))
		}
		testing.expect_value(t, len(s.segments), 2)
		expired := s.segments[0]; retained := s.segments[1]
		wal_path := message_store_path(s.directory, expired.generation, "wal"); defer delete(wal_path)
		index_path := message_store_path(s.directory, expired.generation, "idx"); defer delete(index_path)
		td.server = &server
		server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
		defer chan.destroy(server.shard_compaction_jobs)
		server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), 1)
		server.shard_compaction_results[0], _ = spsc.create(Shard_Compaction_Result, 2)
		defer {spsc.destroy(server.shard_compaction_results[0]); delete(server.shard_compaction_results)}
		defer discard_queued_shard_compaction_jobs(&server)
		defer discard_queued_shard_compaction_results(&server)
		s.async_readers = 1
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && !s.lifecycle_in_flight)
		s.async_readers = 0
		testing.expect(t, chan.try_send(server.shard_compaction_jobs, Shard_Compaction_Job{}))
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && !s.lifecycle_in_flight && len(s.segments) == 2)
		_, _ = chan.try_recv(server.shard_compaction_jobs)
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && s.lifecycle_in_flight)
		testing.expect(t, os.exists(wal_path) && os.exists(index_path) && len(s.segments) == 2)
		if fail_publication {
			tmp := fmt.aprintf("%s/manifest.tmp", s.directory); defer delete(tmp)
			block := fmt.aprintf("%s/block", tmp); defer delete(block)
			testing.expect(t, os.make_directory(tmp) == nil && os.write_entire_file(block, []byte{1}) == nil)
		}
		storage_lifecycle_test_service(&server, service_context)
		testing.expect(t, len(s.segments) == 2, "owner descriptors change only at completion")
		_ = process_shard_compaction_results()
		if fail_publication {
			testing.expect(t, s.poisoned && server.fatal_storage_error && len(s.segments) == 2)
			testing.expect(t, os.exists(wal_path) && os.exists(index_path))
		} else {
			testing.expect(t, !s.lifecycle_in_flight && !s.poisoned && len(s.segments) == 1)
			testing.expect_value(t, s.segments[0].generation, retained.generation)
			testing.expect_value(t, s.total_bytes, retained.bytes)
			testing.expect(t, !os.exists(wal_path) && !os.exists(index_path))
		}
	}
}
