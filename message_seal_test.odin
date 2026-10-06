package main

import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:thread"
import "core:time"
import nbio "nbio/poly"
import "persistence"
import pr "protocol"
import "spsc"
import "storage_io"
import tlsf "vendor/tlsf"

when !NRC_SIMULATION {
	_ :: nbio.init
	_ :: pr.MessageRangeRequest
	_ :: storage_io.Context
	_ :: strings.clone
	_ :: log.nil_logger
}

// Exercise the actual channel service on a separate OS thread, not direct
// rotate_message_store. Delaying service deterministically exposes admission
// and owner responsiveness before any sealed file exists.
@(test)
test_message_seal_channel_lifecycle :: proc(t: ^testing.T) {
	service_context := context
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &service_context.allocator, 64 * 1024))
	defer tlsf.destroy(&heap)
	old_td := new(Server_Thread)
	old_td^ = td
	td = {}
	defer {td = old_td^; free(old_td, service_context.allocator)}
	server: NRC_Server
	td.server = &server
	server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
	defer chan.destroy(server.shard_compaction_jobs)
	server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), 1)
	defer delete(server.shard_compaction_results)
	server.shard_compaction_results[0], _ = spsc.create(Shard_Compaction_Result, 2, context.allocator)
	defer spsc.destroy(server.shard_compaction_results[0])
	defer discard_queued_shard_compaction_jobs(&server)
	defer discard_queued_shard_compaction_results(&server)
	td.backing_allocator = service_context.allocator
	context.allocator = worker_heap_allocator(&heap)
	dir := test_wal_path("message-seal-channel")
	_ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil)
	defer os.remove_all(dir)
	workspace := "message-seal-channel"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	for &i in td.message_stores.store_index do i = -1
	append(&td.message_stores.stores, Message_Store{})
	store := &td.message_stores.stores[0]
	testing.expect(t, init_message_store(store, dir, shard, 24 * time.Hour, 0))
	td.message_stores.enabled = true
	td.message_stores.store_index[shard] = 0
	defer shutdown_message_store_registry(&td.message_stores)
	now := nrc_time_unix_nanos()
	seed := test_retained_message(workspace, 42, 1, now)
	result, _ := append_or_deduplicate_message(store, &seed)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	store.rotation_pending = true
	// A full queue must not build inline or poison the store.
	testing.expect(t, chan.try_send(server.shard_compaction_jobs, Shard_Compaction_Job{}))
	testing.expect(t, retained_message_flush_store(store))
	testing.expect(t, !store.rotation_pending && store.frozen != nil && !store.seal_in_flight && !store.poisoned)
	second := test_retained_message(workspace, 42, 2, now)
	result, _ = append_or_deduplicate_message(store, &second)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect(t, store.active_index_arena != store.frozen.active_index_arena)
	ack_a := Send_Item {
		message_store      = store,
		message_generation = 1,
		message_record     = 1,
	}
	ack_b := Send_Item {
		message_store      = store,
		message_generation = 3,
		message_record     = 1,
	}
	testing.expect(t, outbox_item_message_is_durable(&ack_a))
	testing.expect(t, !outbox_item_message_is_durable(&ack_b))
	persistence.force_fsync(&store.wal)
	testing.expect(t, outbox_item_message_is_durable(&ack_b))
	_, _ = chan.try_recv(server.shard_compaction_jobs)
	_, maintained := maintain_message_store_registry(&td.message_stores)
	testing.expect(t, maintained)
	_, flushed := flush_pending_retained_message_writes(&td.message_stores)
	testing.expect(t, flushed && store.seal_in_flight)
	testing.expect(t, worker_heap_contains_for_test(&heap, store.frozen))
	job, queued := chan.try_recv(server.shard_compaction_jobs)
	assert(queued)
	testing.expect_value(t, job.allocator, service_context.allocator)
	testing.expect(t, !worker_heap_contains_for_test(&heap, raw_data(job.shard_dir)))
	assert(chan.try_send(server.shard_compaction_jobs, job))
	sealed_path := message_store_path(store.directory, 2, "wal"); defer delete(sealed_path)
	testing.expect(t, !os.exists(sealed_path))
	testing.expect(t, store.wal.enabled && store.active_generation == 3)
	sequence: u64
	result, sequence = append_or_deduplicate_message(store, &seed)
	testing.expect(t, result == .Duplicate && sequence == 1)
	// B can append while a reader borrows A; filling B applies backpressure.
	store.async_readers = 1
	store.frozen.async_readers = 1
	store.active_started_hour -= 1
	third := test_retained_message(workspace, 42, 3, now)
	result, _ = append_or_deduplicate_message(store, &third)
	testing.expect_value(t, result, Message_Store_Result.Capacity)
	store.active_started_hour += 1
	testing.expect_value(t, store.wal.write_offset, 0)
	worker := thread.create_and_start_with_poly_data(&server, proc(s: ^NRC_Server) {_ = service_shard_compaction_job(s)}, service_context)
	thread.join(worker)
	thread.destroy(worker)
	testing.expect(t, process_shard_compaction_results())
	testing.expect(t, store.seal_ready)
	_, flushed = flush_pending_retained_message_writes(&td.message_stores)
	testing.expect(t, flushed && store.active_generation == 3 && store.frozen_published)
	result, _ = append_message_after_sealed_lookup(store, &third)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	persistence.force_fsync(&store.wal)
	store.frozen.async_readers -= 1
	_, maintained = maintain_message_store_registry(&td.message_stores)
	testing.expect(t, maintained && store.frozen == nil)
	retained_message_release_store_reader(store)
	_, flushed = flush_pending_retained_message_writes(&td.message_stores)
	testing.expect(t, flushed && store.active_generation == 3 && !store.seal_in_flight)
	testing.expect_value(t, len(store.segments), 1)
	// Duplicate/stale failures cannot poison or delete a published generation.
	testing.expect(t, process_message_seal_result({owner_worker = 0, shard = shard, message_source_generation = 1, ok = false}))
	testing.expect(t, !store.poisoned && os.exists(sealed_path))
	testing.expect(t, shutdown_message_store(store))
	testing.expect(t, init_message_store(store, dir, shard, 24 * time.Hour, 0))
	testing.expect(t, store.active_generation == 3 && store.high_water == 3)
	data := read_validated_message_segment_index(store, store.segments[0])
	testing.expect(t, data != nil)
	delete(data)
}

@(test)
test_message_seal_failure_and_shutdown_keep_source :: proc(t: ^testing.T) {
	for scenario in 0 ..< 3 {
		old_td := new(Server_Thread)
		old_td^ = td
		td = {}
		defer {td = old_td^; free(old_td)}
		server: NRC_Server
		td.server = &server
		// Registry shutdown drains outstanding WAL fsyncs through the real I/O
		// loop in this host-storage fixture (there is no simulation runtime).
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)
		server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
		defer chan.destroy(server.shard_compaction_jobs)
		dir := test_wal_path("message-seal-failure-shutdown")
		_ = os.remove_all(dir); testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		workspace := "message-seal-failure"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		td.message_stores.store_index[shard] = 0
		testing.expect(t, init_message_store(store, dir, shard, 24 * time.Hour, 0))
		seed := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
		result, _ := append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		store.rotation_pending = true
		testing.expect(t, retained_message_flush_store(store) && store.seal_in_flight)
		job, received := chan.try_recv(server.shard_compaction_jobs)
		testing.expect(t, received)
		second := test_retained_message(workspace, 42, 2, seed.accepted_at_ns)
		result, _ = append_or_deduplicate_message(store, &second)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		if scenario == 1 {
			// Fail sealed output creation after scheduling, before any manifest
			// publication. The original source must survive fatal shutdown.
			path := message_store_path(store.directory, 2, "wal")
			testing.expect(t, os.make_directory(path) == nil)
			blocker := message_store_path(path, 0, "block")
			testing.expect(t, os.write_entire_file(blocker, []byte{1}) == nil)
			built := run_shard_compaction_job(job)
			testing.expect(t, !built.ok)
			testing.expect(t, !process_message_seal_result(built))
			testing.expect(t, store.poisoned && server.fatal_storage_error && server.closing)
			testing.expect(t, os.remove_all(path) == nil)
			delete(blocker); delete(path)
			testing.expect(t, shutdown_message_store_registry(&td.message_stores))
		} else if scenario == 0 {
			// The job survives destruction of the entire registry and its paths.
			testing.expect(t, shutdown_message_store_registry(&td.message_stores))
			built := run_shard_compaction_job(job)
			testing.expect(t, built.ok)
			testing.expect(t, process_message_seal_result(built))
		} else {
			built := run_shard_compaction_job(job)
			testing.expect(t, built.ok && process_message_seal_result(built))
			path := fmt.aprintf("%s/manifest.tmp", store.directory)
			blocker := fmt.aprintf("%s/block", path)
			testing.expect(t, os.make_directory(path) == nil)
			testing.expect(t, os.write_entire_file(blocker, []byte{1}) == nil)
			_, ok := flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, !ok && store.poisoned && server.fatal_storage_error)
			// Removing the fault before shutdown catches accidental publication
			// of the partially updated in-memory descriptor during teardown.
			testing.expect(t, os.remove_all(path) == nil)
			delete(blocker); delete(path)
			testing.expect(t, shutdown_message_store_registry(&td.message_stores))
		}
		recovered: Message_Store
		testing.expect(t, init_message_store(&recovered, dir, shard, 24 * time.Hour, 0))
		testing.expect(t, recovered.active_generation == 3 && recovered.high_water == 2 && len(recovered.segments) == 1)
		sequence: u64
		result, sequence = append_or_deduplicate_message(&recovered, &second)
		testing.expect(t, result == .Duplicate && sequence == 2)
		testing.expect(t, shutdown_message_store(&recovered))
	}
}

@(test)
test_message_rollover_reads_v2_manifest :: proc(t: ^testing.T) {
	dir := test_wal_path("retained-v2-manifest")
	_ = os.remove_all(dir); testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	workspace := "retained-v2-manifest"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	store: Message_Store
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	message := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
	result, _ := append_or_deduplicate_message(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	testing.expect(t, rotate_message_store(&store, message.accepted_at_ns))
	message.client_message_id[0] = 2
	result, _ = append_message_after_sealed_lookup(&store, &message)
	testing.expect_value(t, result, Message_Store_Result.Appended)
	// Byte-for-byte v2 layout from the shipped writer: 64-byte header and
	// 48-byte sealed descriptor. No v3 frozen field or extra descriptor.
	fixture: [112]byte
	message_put_u32(fixture[:], MESSAGE_MANIFEST_MAGIC); message_put_u16(fixture[4:], 2)
	message_put_u16(fixture[6:], u16(shard)); message_put_u64(fixture[8:], 3)
	message_put_u64(fixture[16:], 2); message_put_u64(fixture[24:], u64(store.purge_floor_ns))
	message_put_u64(fixture[32:], store.total_bytes); message_put_u32(fixture[40:], 1)
	message_put_u64(fixture[48:], u64(store.retention))
	segment := store.segments[0]
	message_put_u64(fixture[64:], segment.generation); message_put_u64(fixture[72:], segment.first_seq)
	message_put_u64(fixture[80:], segment.last_seq); message_put_u64(fixture[88:], u64(segment.min_time))
	message_put_u64(fixture[96:], u64(segment.max_time)); message_put_u64(fixture[104:], segment.bytes)
	message_put_u64(fixture[56:], xxhash.XXH64(fixture[:]))
	path := message_store_manifest_path(store.directory); defer delete(path)
	testing.expect(t, shutdown_message_store(&store))
	testing.expect(t, os.write_entire_file(path, fixture[:]) == nil)
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	testing.expect(t, store.high_water == 2 && store.active_generation == 3 && store.frozen == nil && len(store.segments) == 1)
	testing.expect(t, shutdown_message_store(&store))
}

when NRC_SIMULATION {
	// Model replacement of only the server process. Unlike
	// crash_message_store_for_test, this leaves the virtual filesystem's
	// process-visible, unsynced bytes intact.
	message_rollover_discard_store_for_test :: proc(store: ^Message_Store) {
		assert(store.async_readers == 0)
		if store.wal.file != nil do storage_io.discard(store.wal.file)
		store.wal.file = nil
		store.wal.enabled = false
		persistence.reset_buffered_write_state(&store.wal)
		if len(store.wal.path) > 0 do delete(store.wal.path)
		store.wal.path = ""
		if store.active_read_file != nil do storage_io.discard(store.active_read_file)
		destroy_frozen_message_store(store, false)
		destroy_active_message_indexes(store)
		destroy_message_segment_metadata(store, store.segments[:])
		delete(store.segments)
		delete(store.pending_appends)
		delete(store.pending_dedup)
		delete(store.deferred_appends)
		delete(store.deferred_dedup)
		delete(store.durability_waiters)
		delete(store.directory)
		store^ = {}
	}

	@(test)
	test_message_seal_failure_releases_staged_handler_context :: proc(t: ^testing.T) {
		for scenario in 0 ..< 2 {
			failed_build := scenario == 1
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, failed_build ? 302 : 301)
			defer simulation_test_end(&ctx)
			server: NRC_Server
			td.server = &server
			testing.expect(t, nbio.init(&td.io) == .NONE)
			defer nbio.destroy(&td.io)
			workspace := failed_build ? "seal-build-failure-staged" : "seal-publication-failure-staged"
			conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
			ctx.conns[1] = conn
			if !testing.expect(t, conn != nil) do return
			storage := storage_io.host_context()
			dir := test_wal_path("seal-failure-staged-%d", scenario)
			_ = os.remove_all(dir)
			testing.expect(t, os.make_directory(dir) == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			for &index in td.message_stores.store_index do index = -1
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
			td.message_stores.enabled = true
			td.message_stores.store_index[shard] = 0

			seed := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
			result, _ := append_or_deduplicate_message(store, &seed)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			testing.expect(t, roll_message_store(store, seed.accepted_at_ns) && store.frozen != nil)
			prefix := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = 2,
				content_type   = .PlainText,
				content        = transmute([]byte)string("durable B prefix"),
			}
			prefix.client_message_id[0] = 2
			process_send_message_v2(conn, prefix)
			_, ok := flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, ok && simulation_test_commit_messages(&ctx.sim))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
			nrc_sim_clear_inboxes(&ctx.sim)
			store.seal_in_flight = true

			publication_fault_path := fmt.aprintf("%s/manifest.tmp", store.directory)
			defer delete(publication_fault_path)
			if !failed_build {
				job_dir, clone_err := strings.clone(store.directory)
				testing.expect(t, clone_err == nil)
				job := Shard_Compaction_Job {
					owner_worker              = td.thread_index,
					shard                     = shard,
					message_source_generation = store.frozen.active_generation,
					storage                   = storage,
					shard_dir                 = job_dir,
				}
				built := run_shard_compaction_job(job)
				testing.expect(t, built.ok && process_message_seal_result(built))
				testing.expect(t, store.seal_ready)
				// Fail manifest replacement after metadata mutation, while B's
				// next handler request remains staged and owns a connection pin.
				testing.expect(t, os.make_directory(publication_fault_path) == nil)
				blocker := fmt.aprintf("%s/block", publication_fault_path)
				testing.expect(t, os.write_entire_file(blocker, []byte{1}) == nil)
				delete(blocker)
			}
			third := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = 3,
				content_type   = .PlainText,
				content        = transmute([]byte)string("never published B suffix"),
			}
			third.client_message_id[0] = 3
			process_send_message_v2(conn, third)
			testing.expect_value(t, len(store.pending_appends), 1)
			testing.expect(t, store.wal.write_offset > 0)
			testing.expect_value(t, conn.retained_io, 1)
			testing.expect_value(t, conn.pending_io, u32(1))

			if failed_build {
				previous_logger := context.logger
				context.logger = log.nil_logger()
				processed := process_message_seal_result(
					{owner_worker = td.thread_index, shard = shard, message_source_generation = store.frozen.active_generation, ok = false},
				)
				context.logger = previous_logger
				testing.expect(t, !processed)
			} else {
				previous_logger := context.logger
				context.logger = log.nil_logger()
				_, ok = flush_pending_retained_message_writes(&td.message_stores)
				context.logger = previous_logger
				testing.expect(t, !ok)
			}
			if failed_build {
				_, ok = flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, !ok)
			}
			testing.expect_value(t, len(store.pending_appends), 0)
			testing.expect_value(t, store.wal.write_offset, 0)
			testing.expect_value(t, conn.pending_io, u32(0))
			testing.expect_value(t, conn.retained_io, 0)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
			testing.expect(t, store.poisoned && server.fatal_storage_error && server.closing)
			if !failed_build do testing.expect(t, os.remove_all(publication_fault_path) == nil)
			testing.expect(t, shutdown_message_store_registry(&td.message_stores))

			recovered: Message_Store
			testing.expect(t, init_message_store_with_storage(&recovered, storage, dir, shard, time.Hour, 0))
			testing.expect(t, recovered.high_water == 2 && recovered.active_generation == 3 && len(recovered.segments) == 1)
			testing.expect(t, shutdown_message_store(&recovered))
			testing.expect(t, os.remove_all(dir) == nil)
		}
	}

	@(test)
	test_message_process_restart_syncs_recovered_record_before_duplicate_ack :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 303)
		defer simulation_test_end(&ctx)
		server: NRC_Server; td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
		workspace := "process-restart-recovered-message"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn; if !testing.expect(t, conn != nil) do return
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/process-restart-recovered-message"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		req := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 1,
			content_type   = .PlainText,
			content        = transmute([]byte)string("complete but unsynced"),
		}
		req.client_message_id[0] = 1
		process_send_message_v2(conn, req)
		// Complete the write, but leave its bytes unsynced for process replacement.
		ok := simulation_test_flush_message_writes(&ctx.sim)
		testing.expect(t, ok && store.wal.record_count == 1 && store.wal.durable_record_count == 0 && store.wal.pending_bytes > 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
		send_queue_drain(conn)
		message_rollover_discard_store_for_test(store)
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		testing.expect(t, store.wal.record_count == 1 && store.wal.durable_record_count == 1 && store.high_water == 1)
		nrc_sim_clear_inboxes(&ctx.sim)
		req.correlation_id = 2
		process_send_message_v2(conn, req)
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
		sim_world_crash(&ctx.sim.world)
		connections := [?]^NRC_Connection{conn}
		testing.expect(t, nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:], true))
		message_rollover_discard_store_for_test(store)
		storage = sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		testing.expect(t, store.high_water == 1 && store.wal.record_count == 1)
		testing.expect(t, shutdown_message_store_registry(&td.message_stores))
	}

	message_rollover_expect_history :: proc(t: ^testing.T, conn: ^NRC_Connection, ledger: []Retained_Message, stage, boundary: int, high_water: u64 = 0) {
		for conversation in 42 ..= 44 {
			for direction in 0 ..< 2 {
				ascending := direction == 0
				indices: [3]int
				count := 0
				for ordinal in 0 ..< len(ledger) {
					i := ascending ? ordinal : len(ledger) - 1 - ordinal
					if ledger[i].conversation_id == u64(conversation) {
						indices[count] = i
						count += 1
					}
				}
				cursor: pr.MessageSeq
				// One-record pages cross sealed A / active B, followed by an
				// explicit empty page. Conversation 44 must always be empty.
				for page_index in 0 ..= count {
					page, ok := retained_history_simulation_page(
						conn,
						{conv_id = pr.ConversationID(conversation), cursor = cursor, limit = 1, correlation_id = 77},
						ascending,
					)
					if !testing.expectf(t, ok, "stage=%d boundary=%d conversation=%d history failed", stage, boundary, conversation) do return
					expected_count := page_index < count ? 1 : 0
					testing.expectf(
						t,
						page.conv_id == pr.ConversationID(conversation) &&
						page.ascending == ascending &&
						page.correlation_id == 77 &&
						!page.truncated &&
						u64(page.high_water_seq) == (high_water == 0 ? u64(len(ledger)) : high_water) &&
						page.retention_cutoff_seq == pr.MessageSeq(1) &&
						page.has_more == (page_index + 1 < count),
						"stage=%d boundary=%d invalid page metadata",
						stage,
						boundary,
					)
					if !testing.expectf(t, len(page.messages) == expected_count, "stage=%d boundary=%d conversation=%d page=%d count=%d want=%d", stage, boundary, conversation, page_index, len(page.messages), expected_count) do return
					if expected_count == 0 {
						testing.expect_value(t, page.continuation_cursor, pr.MessageSeq(0))
						continue
					}
					i := indices[page_index]
					want := ledger[i]
					got := page.messages[0]
					testing.expectf(
						t,
						got.conv_id == pr.ConversationID(want.conversation_id) &&
						u64(got.seq) == u64(i + 1) &&
						got.client_message_id == want.client_message_id &&
						string(got.author_username) == want.sender_name &&
						got.timestamp == want.accepted_at_ns &&
						u8(got.content_type) == want.content_type &&
						string(got.content) == string(want.content),
						"stage=%d boundary=%d conversation=%d sequence=%d recovered message differs from ledger",
						stage,
						boundary,
						conversation,
						i + 1,
					)
					cursor = pr.MessageSeq(i + 1)
					testing.expect_value(t, page.continuation_cursor, cursor)
				}
			}
		}
	}

	// Sweep every completed storage effect, including rename-before-directory-
	// fsync, rather than choosing only convenient pre-operation failure points.
	message_rollover_fault_case :: proc(t: ^testing.T, stage, boundary: int) -> int {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0)
		defer simulation_test_end(&ctx)
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/roll-fault") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		workspace := "retained-roll-fault"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		store: Message_Store
		testing.expect(t, init_message_store_with_storage(&store, storage, "/roll-fault", shard, time.Hour, 0))
		now := nrc_time_unix_nanos()
		// Expected bytes/identity are defined before writing, never reconstructed
		// from the recovered WAL or its indexes. Interleaved conversations force
		// clustered A's physical order to differ from sequence order.
		ledger := [3]Retained_Message {
			test_retained_message(workspace, 43, 1, now),
			test_retained_message(workspace, 42, 2, now + 1),
			test_retained_message(workspace, 42, 3, now + 2),
		}
		contents := [3]string{"A / conversation 43", "**A / conversation 42**", "B / durable suffix"}
		for &message, i in ledger {
			message.sender_principal = "alice"
			message.content = transmute([]byte)contents[i]
			message.content_type = u8(i % 2)
		}
		for entry in ledger[:2] {
			message := entry
			result, _ := append_or_deduplicate_message(&store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
		}
		persistence.force_fsync(&store.wal)
		if stage > 0 {
			testing.expect(t, roll_message_store(&store, now))
			message := ledger[2]
			result, _ := append_or_deduplicate_message(&store, &message)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			persistence.force_fsync(&store.wal)
		}
		if stage == 2 || stage == 4 {
			bytes, built := cluster_message_segment_wal(&store, 1, 2)
			testing.expect(t, built)
			store.seal_bytes = bytes
		}
		if stage == 4 {
			// Publish first, but keep the obsolete source pinned until the
			// separate cleanup job. Recovery must ignore it even if unlink fails.
			store.frozen.async_readers = 1
			testing.expect(t, publish_frozen_message_seal(&store))
			store.frozen.async_readers = 0
			path := message_store_path(store.directory, 1, "wal"); defer delete(path)
			exists, err := storage_io.exists(storage, path)
			testing.expect(t, err == nil && exists)
		}
		if stage == 3 {
			crash_message_store_for_test(&store)
			sim_world_crash(&ctx.sim.world)
			storage = sim_world_storage_context(&ctx.sim.world)
		}
		storage_io.virtual_set_fail_stop_after_effect_for_test(&ctx.sim.world.storage, boundary > 0 ? boundary : max(int))
		ok: bool
		// WAL initialization intentionally logs ESTALE at injected fail-stops.
		// Suppress only that operation, never the assertions or recovery checks.
		logger := context.logger
		context.logger = boundary > 0 ? log.nil_logger() : logger
		switch stage {
		case 0:
			ok = roll_message_store(&store, now)
		case 1:
			directory, _ := strings.clone(store.directory)
			result := sim_run_shard_compaction_job({message_source_generation = 1, shard = shard, storage = storage, shard_dir = directory})
			ok = result.ok
		case 2:
			ok = publish_frozen_message_seal(&store)
		case 3:
			ok = init_message_store_with_storage(&store, storage, "/roll-fault", shard, time.Hour, 0)
		case 4:
			directory, _ := strings.clone(store.directory)
			result := sim_run_shard_compaction_job({message_remove_generation = 1, shard = shard, storage = storage, shard_dir = directory})
			ok = result.ok
		}
		context.logger = logger
		effects := ctx.sim.world.storage.effect_count
		if boundary > 0 {
			testing.expectf(
				t,
				storage_io.virtual_fail_stop_triggered_for_test(&ctx.sim.world.storage),
				"stage=%d boundary=%d did not trigger",
				stage,
				boundary,
			)
		} else {
			testing.expectf(t, ok, "stage=%d baseline failed", stage)
		}
		crash_message_store_for_test(&store)
		sim_world_crash(&ctx.sim.world)
		storage = sim_world_storage_context(&ctx.sim.world)
		if !testing.expectf(t, init_message_store_with_storage(&store, storage, "/roll-fault", shard, time.Hour, 0), "stage=%d boundary=%d recovery failed", stage, boundary) do return effects
		expected := stage > 0 ? u64(3) : u64(2)
		testing.expectf(t, store.high_water == expected, "stage=%d boundary=%d lost durable suffix", stage, boundary)
		if store.active_generation == 1 {
			testing.expect(t, stage == 0 && store.wal.record_count == 2 && len(store.segments) == 0)
		} else {
			testing.expect(t, store.active_generation == 3 && len(store.segments) == 1 && store.segments[0].last_seq == 2)
			testing.expect_value(t, store.wal.record_count, expected - 2)
			data := read_validated_message_segment_index(&store, store.segments[0])
			testing.expect(t, data != nil && message_get_u64(data[24:]) == 2)
			delete(data)
		}
		// Transfer the recovered store into the handler registry. Requests below
		// exercise real history and asynchronous sealed dedup, not index counts.
		server: NRC_Server; td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, store)
		store = {}
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		defer testing.expect(t, shutdown_message_store_registry(&td.message_stores))
		recovered := &td.message_stores.stores[0]
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn
		if !testing.expect(t, conn != nil) do return effects
		for conversation in 42 ..= 44 do subscribe_to_conversation(conn, pr.ConversationID(conversation))
		message_rollover_expect_history(t, conn, ledger[:int(expected)], stage, boundary)
		active_records, active_bytes := recovered.wal.record_count, recovered.active_bytes
		for entry, i in ledger[:int(expected)] {
			for attempt in 0 ..< 2 {
				conflict := attempt == 1
				nrc_sim_clear_inboxes(&ctx.sim)
				request := pr.SendMessageV2Request {
					conv_id           = pr.ConversationID(entry.conversation_id),
					client_message_id = entry.client_message_id,
					content_type      = pr.MessageContentType(entry.content_type),
					content           = conflict ? transmute([]byte)string("wrong payload") : entry.content,
					correlation_id    = u32(100 + i),
				}
				process_send_message_v2(conn, request)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				_, flushed := flush_pending_retained_message_writes(&td.message_stores)
				if !testing.expect(t, flushed) do return effects
				if !testing.expect(t, simulation_test_commit_messages(&ctx.sim)) do return effects
				if !testing.expectf(t, nrc_sim_client_frame_count(&ctx.sim, conn.sock) == 1, "stage=%d boundary=%d message=%d conflict=%v unexpected response count", stage, boundary, i + 1, conflict) do return effects
				payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 0))
				if !testing.expect(t, valid) do return effects
				if conflict {
					error, err := pr.parseErrorResponseMessage(payload)
					testing.expect(
						t,
						err == nil &&
						error.origin_opcode == .C_SendMessageV2 &&
						error.correlation_id == request.correlation_id &&
						string(error.error_msg) == "client message id conflicts with an earlier message",
					)
				} else {
					ack, err := pr.parseAckSendMessageMessage(payload)
					testing.expectf(
						t,
						err == nil &&
						ack.client_req_id == request.correlation_id &&
						u64(ack.assigned_seq) == u64(i + 1) &&
						ack.timestamp == entry.accepted_at_ns,
						"stage=%d boundary=%d message=%d duplicate ACK differs from ledger",
						stage,
						boundary,
						i + 1,
					)
				}
				testing.expect(
					t,
					recovered.high_water == expected &&
					recovered.wal.record_count == active_records &&
					recovered.active_bytes == active_bytes &&
					recovered.wal.write_offset == 0,
				)
			}
		}
		message_rollover_expect_history(t, conn, ledger[:int(expected)], stage, boundary)
		return effects
	}

	@(test)
	test_message_rollover_exhaustive_storage_boundaries :: proc(t: ^testing.T) {
		for stage in 0 ..< 5 {
			effects := message_rollover_fault_case(t, stage, 0)
			testing.expect(t, effects > 0)
			for boundary in 1 ..= effects do _ = message_rollover_fault_case(t, stage, boundary)
		}
	}

	@(test)
	test_message_rollover_acked_suffix_survives_pending_seal_crash :: proc(t: ^testing.T) {
		for stage in 0 ..< 4 {
			ctx: Sim_Test_Context
			simulation_test_begin(&ctx, 0)
			defer simulation_test_end(&ctx)
			ctx.sim.compaction_job_event_submission = true
			server: NRC_Server; td.server = &server
			testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
			workspace := "retained-acked-suffix-crash"
			conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
			ctx.conns[1] = conn
			storage := sim_world_storage_context(&ctx.sim.world)
			testing.expect(t, storage_io.make_directory(storage, "/acked-suffix") == nil)
			testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
			shard := int(shard_for_workspace(transmute([]byte)workspace))
			append(&td.message_stores.stores, Message_Store{})
			store := &td.message_stores.stores[0]
			testing.expect(t, init_message_store_with_storage(store, storage, "/acked-suffix", shard, time.Hour, 0))
			td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
			defer shutdown_message_store_registry(&td.message_stores)
			seed := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
			seed.sender_principal = "alice"
			result, _ := append_or_deduplicate_message(store, &seed)
			testing.expect_value(t, result, Message_Store_Result.Appended)
			store.rotation_pending = true
			testing.expect(t, retained_message_flush_store(store))
			req := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = 2,
				content        = transmute([]byte)string("acked B suffix"),
			}
			req.client_message_id[0] = 2
			process_send_message_v2(conn, req)
			ok := simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok && store.active_generation == 3 && store.high_water == 2)
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
			testing.expect(t, simulation_test_commit_messages(&ctx.sim))
			testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
			req_a := pr.SendMessageV2Request {
				conv_id           = 42,
				client_message_id = seed.client_message_id,
				content           = seed.content,
				correlation_id    = 3,
			}
			// A must deduplicate/conflict from its frozen RAM index before the
			// build, and from the sealed index after publication.
			for phase in 0 ..< (stage == 3 ? 2 : 1) {
				if phase == 1 {
					testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
					testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
					_, ok = flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
				}
				nrc_sim_clear_inboxes(&ctx.sim)
				req_a.content = seed.content
				process_send_message_v2(conn, req_a)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				_, ok = flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
				testing.expect(t, simulation_test_commit_messages(&ctx.sim))
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
				req_a.content = transmute([]byte)string("conflicting A")
				process_send_message_v2(conn, req_a)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				nrc_sim_run_all_send_completions(&ctx.sim)
				testing.expect(t, store.high_water == 2 && nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_ErrorResponse) == 1)
			}
			if stage == 1 || stage == 2 do testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
			if stage == 2 do testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
			connections := [?]^NRC_Connection{conn}
			testing.expect(t, nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:]))
			crash_message_store_for_test(store)
			storage = sim_world_storage_context(&ctx.sim.world)
			testing.expect(t, init_message_store_with_storage(store, storage, "/acked-suffix", shard, time.Hour, 0))
			testing.expect(t, store.high_water == 2 && store.wal.record_count == 1 && len(store.segments) == 1)
			duplicate := test_retained_message(workspace, 42, 2, nrc_time_unix_nanos())
			duplicate.sender_principal = "alice"; duplicate.content = req.content
			sequence: u64
			result, sequence = append_or_deduplicate_message(store, &duplicate)
			testing.expect(t, result == .Duplicate && sequence == 2)
		}
	}
	@(test)
	test_message_seal_publication_while_active_fsync_is_outstanding :: proc(t: ^testing.T) {
		for publication_fails in ([2]bool{false, true}) {
			for case_index in 0 ..< 4 {
				// The extra success case crashes after only the captured prefix sync.
				if publication_fails && case_index == 3 do continue
				outcome := case_index == 3 ? Retained_Fsync_Outcome.Success : Retained_Fsync_Outcome(case_index)
				finish_suffix := case_index != 3
				ctx: Sim_Test_Context
				simulation_test_begin(&ctx, 340 + int(outcome) + (publication_fails ? 10 : 0))
				defer simulation_test_end(&ctx)
				ctx.sim.compaction_job_event_submission = true
				server: NRC_Server; td.server = &server
				testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
				workspace := publication_fails ? "seal-publish-fail-during-b-fsync" : "seal-publish-ok-during-b-fsync"
				conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
				ctx.conns[1] = conn
				if !testing.expect(t, conn != nil) do return
				for conversation in 42 ..= 44 do subscribe_to_conversation(conn, pr.ConversationID(conversation))

				// A host fixture is used only for the publication-failure half: the
				// virtual backend deliberately permits unlinking a non-empty directory,
				// so it cannot represent the manifest.tmp blocker without fail-stopping
				// the already-captured fsync too. Successful publication and crash
				// semantics use the virtual filesystem.
				storage := sim_world_storage_context(&ctx.sim.world)
				dir := "/seal-during-b-fsync"
				host_dir := ""
				if publication_fails {
					host_dir = test_wal_path("seal-during-b-fsync-%d", int(outcome))
					_ = os.remove_all(host_dir)
					testing.expect(t, os.make_directory(host_dir) == nil)
					storage = storage_io.host_context(); dir = host_dir
				} else {
					testing.expect(t, storage_io.make_directory(storage, dir) == nil)
					testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
				}
				shard := int(shard_for_workspace(transmute([]byte)workspace))
				for &index in td.message_stores.store_index do index = -1
				append(&td.message_stores.stores, Message_Store{})
				store := &td.message_stores.stores[0]
				testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
				td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
				group_commit_test_now = time.Time {
					_nsec = i64(time.Hour),
				}
				store.wal.get_time = group_commit_test_clock

				// Handler appends use the fixed simulation NRC clock; requests do not
				// carry the prefilled timestamps from this expected-value ledger.
				now := NRC_SIM_TIME_EPOCH_NANOS
				ledger := [4]Retained_Message {
					test_retained_message(workspace, 42, 1, now),
					test_retained_message(workspace, 43, 2, now),
					test_retained_message(workspace, 42, 3, now),
					test_retained_message(workspace, 43, 4, now),
				}
				contents := [4]string{"durable A", "durable B prefix", "captured B prefix", "later B suffix"}
				for &message, i in ledger {
					message.sender_principal = "alice"; message.content = transmute([]byte)contents[i]
				}
				seed := ledger[0]
				result, _ := append_or_deduplicate_message(store, &seed)
				testing.expect_value(t, result, Message_Store_Result.Appended)
				persistence.force_fsync(&store.wal)
				store.rotation_pending = true
				testing.expect(t, retained_message_flush_store(store) && store.frozen != nil && store.seal_in_flight)
				store.wal.get_time = group_commit_test_clock

				send := proc(conn: ^NRC_Connection, message: ^Retained_Message, correlation: u32) {
					process_send_message_v2(
						conn,
						{
							conv_id = pr.ConversationID(message.conversation_id),
							client_message_id = message.client_message_id,
							correlation_id = correlation,
							content_type = pr.MessageContentType(message.content_type),
							content = message.content,
						},
					)
				}
				send(conn, &ledger[1], 2)
				_, ok := flush_pending_retained_message_writes(&td.message_stores)
				testing.expect(t, ok && simulation_test_commit_messages(&ctx.sim))
				nrc_sim_run_all_send_completions(&ctx.sim)
				ack_matches := 0
				for frame_index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
					payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame_index))
					if !valid do continue
					parsed, err := pr.parseAckSendMessageMessage(payload)
					if err == nil && parsed.client_req_id == 2 && parsed.assigned_seq == 2 && parsed.timestamp == ledger[1].accepted_at_ns do ack_matches += 1
				}
				testing.expect_value(t, ack_matches, 1)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
				nrc_sim_clear_inboxes(&ctx.sim)

				send(conn, &ledger[2], 3)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				ok = simulation_test_flush_message_writes(&ctx.sim)
				testing.expect(t, ok)
				group_commit_test_now._nsec += i64(RETAINED_COMMIT_WINDOW)
				testing.expect(t, schedule_retained_message_fsync(store))
				snapshot := store.fsync_snapshot
				generation := store.active_generation
				durable_before := store.wal.durable_record_count
				testing.expect(t, snapshot.record_count == 2 && snapshot.pending_bytes > 0)
				testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
				send(conn, &ledger[3], 4)
				for nrc_sim_run_next_file_read(&ctx.sim) {}
				// Complete only the write: the captured prefix fsync stays outstanding.
				ok = simulation_test_flush_message_writes(&ctx.sim)
				testing.expect(t, ok && store.wal.record_count == 3)
				// This suffix has reached the active WAL but is outside the captured
				// fsync snapshot. Fully staged (not yet written) suffixes are covered
				// by the pending-seal crash test above.
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)

				testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
				fault_path := fmt.aprintf("%s/manifest.tmp", store.directory); defer delete(fault_path)
				if publication_fails {
					testing.expect(t, os.make_directory(fault_path) == nil)
					blocker := fmt.aprintf("%s/block", fault_path)
					testing.expect(t, os.write_entire_file(blocker, []byte{1}) == nil); delete(blocker)
				}
				previous_logger := context.logger
				if publication_fails do context.logger = log.nil_logger()
				compaction_ran := sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result)
				_, publication_ok := flush_pending_retained_message_writes(&td.message_stores)
				context.logger = previous_logger
				testing.expect(t, compaction_ran)
				testing.expect_value(t, publication_ok, !publication_fails)
				if publication_fails {
					// Publication failure releases all retained request ownership even
					// though the stale fsync completion remains queued.
					testing.expect(t, store.poisoned && conn.retained_io == 0 && conn.pending_io == 0)
				}
				testing.expect(t, store.active_generation == generation && store.fsync_in_flight && store.fsync_snapshot == snapshot)
				testing.expect_value(t, store.wal.durable_record_count, durable_before)
				testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 1)
				testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)

				expected := 2
				if outcome == .Success {
					testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
					nrc_sim_run_all_send_completions(&ctx.sim)
					testing.expect_value(t, store.wal.durable_record_count, snapshot.record_count)
					testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), publication_fails ? 0 : 1)
					if !publication_fails {
						ack_matches = 0
						for frame_index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
							payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame_index))
							if !valid do continue
							parsed, err := pr.parseAckSendMessageMessage(payload)
							if err == nil && parsed.client_req_id == 3 && parsed.assigned_seq == 3 && parsed.timestamp == ledger[2].accepted_at_ns do ack_matches += 1
						}
						testing.expect_value(t, ack_matches, 1)
					}
					expected = 3
					if !publication_fails && finish_suffix {
						testing.expect(t, store.wal.pending_bytes > 0, "later suffix still needs its own fsync")
						group_commit_test_now._nsec += i64(RETAINED_COMMIT_WINDOW)
						testing.expect(t, schedule_retained_message_fsync(store))
						testing.expect(t, nrc_sim_run_next_fsync_completion(&ctx.sim))
						nrc_sim_run_all_send_completions(&ctx.sim)
						testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 2)
						ack_matches = 0
						for frame_index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
							payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame_index))
							if !valid do continue
							parsed, err := pr.parseAckSendMessageMessage(payload)
							if err == nil && parsed.client_req_id == 4 && parsed.assigned_seq == 4 && parsed.timestamp == ledger[3].accepted_at_ns do ack_matches += 1
						}
						testing.expect_value(t, ack_matches, 1)
						expected = 4
					}
				} else if outcome == .Error {
					context.logger = log.nil_logger()
					completed := nrc_sim_run_next_fsync_completion(&ctx.sim, .EIO)
					context.logger = previous_logger
					testing.expect(t, completed)
					nrc_sim_run_all_send_completions(&ctx.sim)
					testing.expect(t, store.poisoned)
					testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 0)
				}
				if publication_fails {
					testing.expect(t, os.remove_all(fault_path) == nil)
					// Host process replacement preserves written unsynced bytes. This
					// branch checks recovery and cleanup, not power-loss durability; the
					// successful-publication virtual branch models an actual crash.
					expected = 4
				}

				connections := [?]^NRC_Connection{conn}
				testing.expect(t, nrc_sim_process_crash_discard_connections(&ctx.sim, connections[:]))
				crash_message_store_for_test(store)
				testing.expect_value(t, nrc_sim_fsync_completion_count(&ctx.sim), 0)
				storage = publication_fails ? storage_io.host_context() : sim_world_storage_context(&ctx.sim.world)
				testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
				// Publication persisted the allocated high-water, not B's pending bytes.
				testing.expect(t, store.high_water == 4 && store.wal.record_count == u64(expected - 1) && len(store.segments) == 1)
				message_rollover_expect_history(t, conn, ledger[:expected], 4, int(outcome) + (publication_fails ? 10 : 0), high_water = 4)
				testing.expect(t, shutdown_message_store_registry(&td.message_stores))
				if host_dir != "" do _ = os.remove_all(host_dir)
			}
		}
	}

	@(test)
	test_message_seal_shutdown_cancels_capacity_deferred_rotation :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 91)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server
		td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)

		workspace := "message-seal-shutdown-capacity-tail"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn
		if !testing.expect(t, conn != nil) do return
		conn.rooms[42] = true
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/message-seal-shutdown-capacity-tail"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.write_batch_records = 1
		td.message_stores.store_index[shard] = 0

		hour_h := (NRC_SIM_TIME_EPOCH_NANOS / i64(time.Hour) + 1) * i64(time.Hour)
		store.active_started_hour = hour_h / i64(time.Hour)
		ctx.sim.world.now = time.Duration(hour_h - NRC_SIM_TIME_EPOCH_NANOS)
		for marker in 1 ..= 2 {
			req := pr.SendMessageV2Request {
				conv_id        = 42,
				correlation_id = u32(marker),
				content_type   = .PlainText,
				content        = transmute([]byte)string("hour H"),
			}
			req.client_message_id[0] = byte(marker)
			process_send_message_v2(conn, req)
		}
		ctx.sim.world.now += time.Hour
		req_c := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 3,
			content_type   = .PlainText,
			content        = transmute([]byte)string("hour H+1"),
		}
		req_c.client_message_id[0] = 3
		process_send_message_v2(conn, req_c)
		testing.expect_value(t, len(store.pending_appends), 1)
		testing.expect_value(t, len(store.deferred_appends), 2)

		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		// One completed batch stages the next request. Do not drain that request
		// yet: shutdown below must still encounter retained append pins.
		for nrc_sim_run_next_file_write(&ctx.sim) {}
		testing.expect_value(t, len(store.pending_appends), 1)
		testing.expect_value(t, len(store.deferred_appends), 1)
		testing.expect(t, !store.seal_in_flight && !store.rotation_pending)
		testing.expect_value(t, conn.pending_io, u32(2))

		td.state = .Closing
		handle, sock := conn.handle, conn.sock
		connection_close(conn, true)
		testing.expect(t, !conn.close_submitted, "shutdown must wait for retained append pins")
		testing.expect(t, !conn.logical_cleanup_done && len(conn.rooms) == 1, "shutdown skips logical cleanup; final reclamation owns the room map")
		server.closing = true
		cancel_message_seals(&td.message_stores)
		ok = simulation_test_flush_message_writes(&ctx.sim)
		testing.expect(t, ok)
		for nrc_sim_run_next_fsync_completion(&ctx.sim) {
			ok = simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
		}
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), 0)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, conn.retained_io, 0)
		testing.expect_value(t, conn.pending_io, u32(1)) // Reserved close pin.
		testing.expect(t, conn.close_submitted)
		testing.expect(t, nrc_sim_run_next_close_completion(&ctx.sim))
		testing.expect(t, connection_get_by_handle(handle) == nil)
		ctx.conns[1] = nil
		connection_test_mark_removed(sock)
		testing.expect(t, shutdown_message_store_registry(&td.message_stores))
	}

	@(test)
	test_message_rollover_second_generation_waits_and_resumes :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server
		td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)
		workspace := "rollover-backpressure"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/backpressure") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, "/backpressure", shard, 24 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		seed := test_retained_message(workspace, 42, 1, nrc_time_unix_nanos())
		result, _ := append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		store.rotation_pending = true
		testing.expect(t, retained_message_flush_store(store))
		seed.client_message_id[0] = 2
		result, _ = append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		// The ordinary hourly threshold fills B while A is still queued.
		ctx.sim.world.now += time.Hour
		req := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 3,
			content        = seed.content,
		}
		req.client_message_id[0] = 3
		process_send_message_v2(conn, req)
		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && store.rotation_pending && store.active_generation == 3 && store.high_water == 2)
		testing.expect(t, len(store.deferred_appends) == 1 && len(store.pending_appends) == 0)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), 1)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		// Rollover staged the deferred request; the next worker tick writes it.
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		testing.expect(t, store.active_generation == 5 && store.frozen.active_generation == 3 && store.high_water == 3)
		testing.expect(t, len(store.deferred_appends) == 0 && len(store.segments) == 1)
		testing.expect_value(t, sim_world_event_count(&ctx.sim.world, .Compaction_Job), 2)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
		// Drain immutable sealing and cleanup jobs before freeing storage.
		for sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job) {
			// Sealing publishes a result; fire-and-forget cleanup does not.
			for sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result) {}
			_, ok = flush_pending_retained_message_writes(&td.message_stores)
			testing.expect(t, ok)
		}
		testing.expect(t, ok && store.frozen == nil && len(store.segments) == 2)
	}

	@(test)
	test_message_seal_simulation_history_and_deferred_lookup :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 0)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server
		td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE)
		defer nbio.destroy(&td.io)
		workspace := "message-seal-simulation"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn
		subscribe_to_conversation(conn, 42)
		storage := sim_world_storage_context(&ctx.sim.world)
		testing.expect(t, storage_io.make_directory(storage, "/seal") == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, "/seal", shard, 24 * time.Hour, 0))
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		now := nrc_time_unix_nanos()
		seed := test_retained_message(workspace, 42, 1, now)
		result, _ := append_or_deduplicate_message(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect(t, rotate_message_store(store, now))
		seed.client_message_id[0] = 2
		result, _ = append_or_deduplicate_message(store, &seed)
		if result == .Lookup_Required do result, _ = append_message_after_sealed_lookup(store, &seed)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		store.rotation_pending = true
		testing.expect(t, retained_message_flush_store(store) && store.seal_in_flight)
		page, page_ok := retained_history_simulation_page(conn, {conv_id = 42, limit = 10}, true)
		testing.expect(t, page_ok && len(page.messages) == 2)
		testing.expect(t, store.seal_in_flight && !store.seal_ready)
		// Force an async sealed lookup miss during the frozen-source interval.
		for &word in store.segments[0].dedup_filter do word = max(u64)
		req := pr.SendMessageV2Request {
			conv_id        = 42,
			content        = transmute([]byte)string("deferred"),
			correlation_id = 11,
		}
		req.client_message_id[0] = 3
		process_send_message_v2(conn, req)
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		testing.expect(t, store.async_readers == 0 && len(store.pending_appends) == 1 && store.wal.write_offset > 0)
		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok)
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)
		testing.expect(t, store.seal_in_flight && !store.seal_ready)
		testing.expect_value(t, store.high_water, u64(3))
		// Hold an A+B snapshot over publication. No store-wide reader drain is
		// needed, and its lazily opened A file must not resolve to B.
		nrc_sim_clear_inboxes(&ctx.sim)
		process_message_history(conn, {conv_id = 42, cursor = 1, limit = 10}, true)
		testing.expect(t, store.async_readers == 1 && store.frozen.async_readers == 1)
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
		testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && store.frozen_published && !store.seal_in_flight && store.active_generation == 5)
		fourth := test_retained_message(workspace, 42, 4, now)
		result, _ = append_message_after_sealed_lookup(store, &fourth)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_MessagePage), 1)
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, 0))
		if !testing.expect(t, payload_ok) do return
		held_page, parse_err := pr.parseMessagePage(payload[2:])
		testing.expect(t, parse_err == nil && len(held_page.messages) == 2 && held_page.high_water_seq == 3)
		for message, i in held_page.messages do testing.expect_value(t, u64(message.seq), u64(i + 2))
		_, ok = maintain_message_store_registry(&td.message_stores)
		testing.expect(t, ok && store.frozen == nil)
		page, page_ok = retained_history_simulation_page(conn, {conv_id = 42, limit = 10}, true)
		testing.expect(t, page_ok && len(page.messages) == 4)
		for message, i in page.messages do testing.expect_value(t, u64(message.seq), u64(i + 1))
		page, page_ok = retained_history_simulation_page(conn, {conv_id = 42, cursor = 4, limit = 2}, false)
		testing.expect(t, page_ok && len(page.messages) == 2 && page.messages[0].seq == 3 && page.messages[1].seq == 2 && page.has_more)
		process_send_message_v2(conn, req)
		for nrc_sim_run_next_file_read(&ctx.sim) {}
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && store.high_water == 4)
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
	}

	@(test)
	test_message_handler_duplicate_first_batch_stays_bounded_while_history_pins_rotation :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 304)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server; td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
		workspace := "message-handler-duplicate-first-pinned"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn; if !testing.expect(t, conn != nil) do return
		subscribe_to_conversation(conn, 42)
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/message-handler-duplicate-first-pinned"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)

		seed := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 1,
			content_type   = .PlainText,
			content        = transmute([]byte)string("durable A"),
		}
		seed.client_message_id[0] = 1
		process_send_message_v2(conn, seed)
		_, ok := flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && simulation_test_commit_messages(&ctx.sim))
		testing.expect(t, store.high_water == 1 && store.wal.durable_record_count == 1)
		nrc_sim_clear_inboxes(&ctx.sim)

		process_message_history(conn, {conv_id = 42, limit = 10, correlation_id = 20}, true)
		testing.expect(t, store.async_readers == 1)
		store.active_started_hour -= 1
		seed.correlation_id = 2
		process_send_message_v2(conn, seed)
		for marker in 2 ..= 3 {
			req := seed
			req.client_message_id[0] = byte(marker); req.correlation_id = u32(marker + 1)
			req.content = transmute([]byte)string("unique wave one")
			process_send_message_v2(conn, req)
		}
		_, ok = flush_pending_retained_message_writes(&td.message_stores)
		testing.expect(t, ok && store.rotation_pending)
		testing.expect_value(t, len(store.deferred_appends), 2)
		for marker in 4 ..= 4 {
			req := seed
			req.client_message_id[0] = byte(marker); req.correlation_id = u32(marker + 1)
			req.content = transmute([]byte)string("unique wave two")
			process_send_message_v2(conn, req)
		}
		testing.expect(t, store.rotation_pending && store.async_readers == 1)
		testing.expect_value(t, len(store.deferred_appends), 3)
		testing.expect_value(t, store.wal.record_count, u64(1))
		testing.expect_value(t, store.wal.buffered_record_count, u64(0))
		testing.expect_value(t, store.wal.write_offset, 0)
		nrc_sim_run_all_send_completions(&ctx.sim)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 1)

		for nrc_sim_run_next_file_read(&ctx.sim) {}
		testing.expect_value(t, store.async_readers, u32(0))
		for round in 0 ..< 16 {
			ok = simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
			for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
			if len(store.deferred_appends) == 0 && store.high_water == 4 do break
		}
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		testing.expect(t, store.active_generation > 1 && store.high_water == 4)
		testing.expect_value(t, len(store.deferred_appends), 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 4)
		ack_counts: [6]int
		for frame_index in 0 ..< nrc_sim_client_frame_count(&ctx.sim, conn.sock) {
			payload, valid := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, conn.sock, frame_index))
			if !valid do continue
			ack, err := pr.parseAckSendMessageMessage(payload)
			if err == nil && ack.client_req_id < len(ack_counts) do ack_counts[ack.client_req_id] += 1
		}
		for correlation_id in 2 ..= 5 do testing.expect_value(t, ack_counts[correlation_id], 1)
		if sim_world_event_count(&ctx.sim.world, .Compaction_Job) > 0 {
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
			_, ok = flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
		}
	}

	@(test)
	test_message_handler_projected_index_ceiling_defers_mid_batch :: proc(t: ^testing.T) {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 305)
		defer simulation_test_end(&ctx)
		ctx.sim.compaction_job_event_submission = true
		server: NRC_Server; td.server = &server
		testing.expect(t, nbio.init(&td.io) == .NONE); defer nbio.destroy(&td.io)
		workspace := "message-handler-projected-index-ceiling"
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "alice", init_send_queue = true)
		ctx.conns[1] = conn; if !testing.expect(t, conn != nil) do return
		storage := sim_world_storage_context(&ctx.sim.world)
		dir := "/message-handler-projected-index-ceiling"
		testing.expect(t, storage_io.make_directory(storage, dir) == nil)
		testing.expect(t, storage_io.sync_directory(storage, "/") == nil)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		for &index in td.message_stores.store_index do index = -1
		append(&td.message_stores.stores, Message_Store{})
		store := &td.message_stores.stores[0]
		testing.expect(t, init_message_store_with_storage(store, storage, dir, shard, time.Hour, 0))
		td.message_stores.enabled = true; td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)

		req := pr.SendMessageV2Request {
			conv_id        = 42,
			correlation_id = 1,
			content_type   = .PlainText,
			content        = transmute([]byte)string("projected ceiling"),
		}
		req.client_message_id[0] = 1
		process_send_message_v2(conn, req)
		testing.expect_value(t, store.wal.buffered_record_count, u64(1))
		bytes_at_ceiling := store.wal.write_offset
		store.wal.record_count = MESSAGE_MAX_INDEX_RECORDS - 1
		req.client_message_id[0] = 2; req.correlation_id = 2
		process_send_message_v2(conn, req)
		testing.expect(t, store.rotation_pending)
		testing.expect_value(t, len(store.pending_appends), 1)
		testing.expect_value(t, len(store.deferred_appends), 1)
		testing.expect_value(t, store.wal.record_count + store.wal.buffered_record_count, MESSAGE_MAX_INDEX_RECORDS)
		testing.expect_value(t, store.wal.buffered_record_count, u64(1))
		testing.expect_value(t, store.wal.write_offset, bytes_at_ceiling)

		// The inflated count models existing index entries only. Restore it
		// before any write completion, rollover, or teardown consumes contexts.
		store.wal.record_count = 0
		ok: bool
		for round in 0 ..< 16 {
			ok = simulation_test_flush_message_writes(&ctx.sim)
			testing.expect(t, ok)
			for nrc_sim_run_next_fsync_completion(&ctx.sim) {}
			if len(store.deferred_appends) == 0 && store.high_water == 2 do break
		}
		testing.expect(t, simulation_test_commit_messages(&ctx.sim))
		testing.expect(t, store.high_water == 2 && len(store.deferred_appends) == 0)
		testing.expect_value(t, nrc_sim_client_opcode_count(&ctx.sim, conn.sock, .S_AckSendMessage), 2)
		if sim_world_event_count(&ctx.sim.world, .Compaction_Job) > 0 {
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Job))
			testing.expect(t, sim_world_run_runnable_rank(&ctx.sim.world, 0, .Compaction_Result))
			_, ok = flush_pending_retained_message_writes(&td.message_stores); testing.expect(t, ok)
		}
	}
}
