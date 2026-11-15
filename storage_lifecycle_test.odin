package main

import "base:runtime"
import "core:fmt"
import "core:log"
import "core:os"
import "core:sync"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import "spsc"
import "storage_io"

storage_lifecycle_test_service :: proc(server: ^NRC_Server, service_context: runtime.Context) {
	service := thread.create_and_start_with_poly_data(server, proc(s: ^NRC_Server) {_ = service_storage_job(s)}, service_context)
	thread.join(service)
	thread.destroy(service)
}

@(test)
test_storage_lifecycle_snapshot_budget :: proc(t: ^testing.T) {
	// A full owner or WAL buffer in either snapshot violates this budget.
	testing.expect(t, size_of(Storage_Lifecycle_Message) < 4096)
	log.infof("Lifecycle snapshot bytes: message=%d", size_of(Storage_Lifecycle_Message))
}

@(test)
test_storage_control_admission_fairness_and_discard :: proc(t: ^testing.T) {
	server: NRC_Server
	server.storage_control_jobs, _ = chan.create_buffered(chan.Chan(Storage_Service_Job), 65, context.allocator)
	defer chan.destroy(server.storage_control_jobs)
	server.storage_bulk_jobs, _ = chan.create_buffered(chan.Chan(Storage_Service_Job), 1, context.allocator)
	defer chan.destroy(server.storage_bulk_jobs)
	server.storage_service_results = make([]^spsc.Queue(Storage_Service_Result), 1)
	server.storage_service_results[0], _ = spsc.create(Storage_Service_Result, 16)
	defer {spsc.destroy(server.storage_service_results[0]); delete(server.storage_service_results)}
	defer discard_queued_storage_service_results(&server)
	defer discard_queued_storage_service_jobs(&server)
	dir := test_wal_path("storage-control-fairness"); defer os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	path := message_store_path(dir, 17, "wal"); defer delete(path)
	testing.expect(t, os.write_entire_file(path, []byte{1}) == nil)
	bulk := Storage_Service_Job {
		allocator                 = context.allocator,
		storage                   = storage_io.host_context(),
		shard_dir                 = fmt.aprintf("%s", dir),
		message_remove_generation = 17,
	}
	assert(chan.try_send(server.storage_bulk_jobs, bulk))
	testing.expect(t, !chan.try_send(server.storage_bulk_jobs, Storage_Service_Job{}))
	// Empty control jobs exercise queue admission without filesystem work.
	// Full bulk admission cannot prevent controls; control admission is bounded too.
	for i in 0 ..< 65 {
		assert(
			chan.try_send(
				server.storage_control_jobs,
				Storage_Service_Job{allocator = context.allocator, storage = storage_io.host_context(), shard_dir = fmt.aprintf("%s", dir), shard = i},
			),
		)
	}
	testing.expect(t, !chan.try_send(server.storage_control_jobs, Storage_Service_Job{}))
	for i in 0 ..< 64 {
		testing.expect(t, service_storage_job(&server) && os.exists(path))
		result, received := spsc.try_pop(server.storage_service_results[0])
		testing.expect(t, received && result.shard == i)
		destroy_storage_service_result(&result)
	}
	// Strict priority would leave this obsolete WAL forever under control load.
	testing.expect(t, service_storage_job(&server) && !os.exists(path))
	testing.expect(t, service_storage_job(&server))
	result, received := spsc.try_pop(server.storage_service_results[0])
	testing.expect(t, received && result.shard == 64)
	destroy_storage_service_result(&result)
	testing.expect(t, !service_storage_job(&server))
	// With no bulk, controls continue past the burst; a later bulk still runs.
	for _ in 0 ..< 66 {
		assert(
			chan.try_send(
				server.storage_control_jobs,
				Storage_Service_Job{allocator = context.allocator, storage = storage_io.host_context(), shard_dir = fmt.aprintf("%s", dir)},
			),
		)
		testing.expect(t, service_storage_job(&server))
		result, received = spsc.try_pop(server.storage_service_results[0])
		testing.expect(t, received)
		destroy_storage_service_result(&result)
	}
	testing.expect(t, os.write_entire_file(path, []byte{1}) == nil)
	bulk.shard_dir = fmt.aprintf("%s", dir)
	assert(chan.try_send(server.storage_bulk_jobs, bulk))
	plan := new(Storage_Lifecycle)
	plan.kind = .Message_Seal
	plan.store = new(Storage_Lifecycle_Message)
	plan.store.directory = fmt.aprintf("%s", dir)
	plan.store.wal.path = fmt.aprintf("%s", path)
	plan.store.wal.path_allocator = context.allocator
	plan.store.segments = make([dynamic]Message_Segment_Descriptor, 1)
	assert(chan.try_send(server.storage_control_jobs, Storage_Service_Job{allocator = context.allocator, lifecycle = plan}))
	testing.expect(t, service_storage_job(&server) && !os.exists(path))
	// Shutdown discards owned payloads in both lanes without executing them.
	testing.expect(t, os.write_entire_file(path, []byte{1}) == nil)
	bulk.shard_dir = fmt.aprintf("%s", dir)
	assert(chan.try_send(server.storage_bulk_jobs, bulk))
	discard_queued_storage_service_jobs(&server)
	_, received = chan.try_recv(server.storage_control_jobs); testing.expect(t, !received)
	_, received = chan.try_recv(server.storage_bulk_jobs); testing.expect(t, !received)
	testing.expect(t, os.exists(path) && !service_storage_job(&server))
}

@(test)
test_storage_bulk_completion_backpressure_preserves_control_progress :: proc(t: ^testing.T) {
	server := NRC_Server {
		storage_bulk_executor_count = STORAGE_BULK_EXECUTORS,
	}
	server.storage_control_jobs, _ = chan.create_buffered(chan.Chan(Storage_Service_Job), 1, context.allocator)
	defer chan.destroy(server.storage_control_jobs)
	server.storage_bulk_results, _ = chan.create_buffered(chan.Chan(Storage_Service_Result), STORAGE_BULK_EXECUTORS, context.allocator)
	defer chan.destroy(server.storage_bulk_results)
	server.storage_service_results = make([]^spsc.Queue(Storage_Service_Result), 2)
	for &queue in server.storage_service_results do queue, _ = spsc.create(Storage_Service_Result, 1)
	defer {for queue in server.storage_service_results do spsc.destroy(queue); delete(server.storage_service_results)}
	defer discard_queued_storage_service_results(&server)
	dir := test_wal_path("bulk-completion-backpressure"); defer os.remove_all(dir)
	assert(os.make_directory(dir) == nil)
	assert(spsc.try_push(server.storage_service_results[0], Storage_Service_Result{shard = 99}))
	for generation in ([2]u64{17, 19}) {
		assert(chan.try_send(server.storage_bulk_results, Storage_Service_Result{owner_worker = 0, message_source_generation = generation, ok = true}))
	}
	assert(
		chan.try_send(
			server.storage_control_jobs,
			Storage_Service_Job{allocator = context.allocator, storage = storage_io.host_context(), shard_dir = fmt.aprintf("%s", dir), owner_worker = 1},
		),
	)
	// A full owner's queue holds both bulk completions, not the control service.
	testing.expect(t, service_storage_job(&server))
	control, received := spsc.try_pop(server.storage_service_results[1])
	testing.expect(t, received && control.owner_worker == 1)
	destroy_storage_service_result(&control)
	_, received = spsc.try_pop(server.storage_service_results[0]); testing.expect(t, received)
	for generation in ([2]u64{17, 19}) {
		testing.expect(t, service_storage_job(&server))
		result: Storage_Service_Result
		result, received = spsc.try_pop(server.storage_service_results[0])
		testing.expect(t, received && result.ok && result.message_source_generation == generation)
		destroy_storage_service_result(&result)
	}
	testing.expect(t, !service_storage_job(&server))
	// Shutdown frees completions both in service slots and still in the channel.
	for generation in ([2]u64{21, 23}) {
		result := Storage_Service_Result {
			owner_worker              = 0,
			message_source_generation = generation,
			allocator                 = context.allocator,
		}
		result.lifecycle = new(Storage_Lifecycle)
		result.lifecycle.index_data = make([]byte, 17)
		assert(chan.try_send(server.storage_bulk_results, result))
	}
	assert(spsc.try_push(server.storage_service_results[0], Storage_Service_Result{}))
	testing.expect(t, service_storage_job(&server))
	result := Storage_Service_Result {
		allocator    = context.allocator,
		owner_worker = 0,
	}
	result.lifecycle = new(Storage_Lifecycle)
	result.lifecycle.index_data = make([]byte, 25)
	assert(chan.try_send(server.storage_bulk_results, result))
	discard_queued_storage_service_results(&server)
	testing.expect(t, !service_storage_job(&server))
}

@(test)
test_storage_bulk_executors_shutdown_with_full_completions :: proc(t: ^testing.T) {
	server := NRC_Server {
		storage_bulk_executor_count = 6,
	}
	server.storage_bulk_jobs, _ = chan.create_buffered(chan.Chan(Storage_Service_Job), 6, context.allocator)
	defer chan.destroy(server.storage_bulk_jobs)
	server.storage_bulk_results, _ = chan.create_buffered(chan.Chan(Storage_Service_Result), 6, context.allocator)
	defer chan.destroy(server.storage_bulk_results)
	dir := test_wal_path("bulk-shutdown-full-completions"); defer os.remove_all(dir)
	assert(os.make_directory(dir) == nil)
	paths: [6]string
	defer for path in paths do delete(path)
	for i in 0 ..< len(paths) {
		generation := u64(17 + 2 * i)
		paths[i] = message_store_path(dir, generation, "wal")
		assert(os.write_entire_file(paths[i], []byte{1}) == nil)
		assert(
			chan.try_send(
				server.storage_bulk_jobs,
				Storage_Service_Job {
					allocator = context.allocator,
					storage = storage_io.host_context(),
					shard_dir = fmt.aprintf("%s", dir),
					message_remove_generation = generation,
				},
			),
		)
	}
	for _ in 0 ..< server.storage_bulk_executor_count do assert(chan.try_send(server.storage_bulk_results, Storage_Service_Result{}))
	sync.wait_group_add(&server.wg, server.storage_bulk_executor_count)
	for &executor, i in server.storage_bulk_threads[:server.storage_bulk_executor_count] do executor = thread.create_and_start_with_poly_data(Storage_Service_Thread_Data{server = &server, bulk_index = i}, storage_bulk_thread, context)
	defer {
		sync.atomic_store(&server.closing, true)
		sync.wait(&server.wg)
		for executor in server.storage_bulk_threads[:server.storage_bulk_executor_count] {thread.join(executor); thread.destroy(executor)}
		discard_queued_storage_service_jobs(&server)
		discard_queued_storage_service_results(&server)
	}
	// Each executor blocks on its first completion. All six deleted files
	// therefore demonstrate concurrent progress beyond the old two-thread limit.
	started := time.tick_now()
	for time.tick_since(started) < 5 * time.Second {
		remaining := false
		for path in paths do remaining = remaining || os.exists(path)
		if !remaining do break
		time.sleep(time.Millisecond)
	}
	for path in paths do testing.expect(t, !os.exists(path))
	// The deferred join must finish even though nobody frees completion capacity.
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
		server.storage_control_jobs, _ = chan.create_buffered(chan.Chan(Storage_Service_Job), 1, context.allocator)
		defer chan.destroy(server.storage_control_jobs)
		server.storage_service_results = make([]^spsc.Queue(Storage_Service_Result), 1)
		server.storage_service_results[0], _ = spsc.create(Storage_Service_Result, 2)
		defer {spsc.destroy(server.storage_service_results[0]); delete(server.storage_service_results)}
		defer discard_queued_storage_service_jobs(&server)
		defer discard_queued_storage_service_results(&server)
		s.async_readers = 1
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && !s.lifecycle_in_flight)
		s.async_readers = 0
		testing.expect(t, chan.try_send(server.storage_control_jobs, Storage_Service_Job{}))
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && !s.lifecycle_in_flight && len(s.segments) == 2)
		_, _ = chan.try_recv(server.storage_control_jobs)
		testing.expect(t, maintain_message_store(s, now, sync_wal = false) && s.lifecycle_in_flight)
		testing.expect(t, os.exists(wal_path) && os.exists(index_path) && len(s.segments) == 2)
		if fail_publication {
			tmp := fmt.aprintf("%s/manifest.tmp", s.directory); defer delete(tmp)
			block := fmt.aprintf("%s/block", tmp); defer delete(block)
			testing.expect(t, os.make_directory(tmp) == nil && os.write_entire_file(block, []byte{1}) == nil)
		}
		storage_lifecycle_test_service(&server, service_context)
		testing.expect(t, len(s.segments) == 2, "owner descriptors change only at completion")
		_ = process_storage_service_results()
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
