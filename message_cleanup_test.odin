package main

import "core:os"
import "core:sync/chan"
import "core:testing"
import "core:time"
import "spsc"
import "storage_io"

when !EXPERIMENT_ASYNC_MESSAGE_DELETE || NRC_SIMULATION {
	_ :: os.remove_all
	_ :: chan.create_buffered
	_ :: time.Hour
	_ :: spsc.create
	_ :: storage_io.exists
}

@(test)
test_message_cleanup_queue :: proc(t: ^testing.T) {
	when EXPERIMENT_ASYNC_MESSAGE_DELETE && !NRC_SIMULATION {
		workspace := "cleanup-queue"
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("cleanup-queue"); defer os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil)
		budget := Message_Active_Cache_Budget {
			limit_bytes = 4 * 1024 * 1024,
		}
		store: Message_Store
		if !testing.expect(t, init_message_store(&store, dir, shard, time.Hour, 0, active_cache_budget = &budget)) do return
		defer {testing.expect(t, shutdown_message_store(&store)); testing.expect_value(t, budget.used_bytes, u64(0))}
		now := nrc_time_unix_nanos()
		first := test_retained_message(workspace, 42, 1, now)
		result, _ := append_or_deduplicate_message(&store, &first)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		testing.expect(t, roll_message_store(&store, now))
		second := test_retained_message(workspace, 42, 2, now + 1)
		second.fingerprint = message_fingerprint(&second)
		result, _ = append_message_after_sealed_lookup(&store, &second)
		testing.expect_value(t, result, Message_Store_Result.Appended)
		bytes, ok := cluster_message_segment_wal(&store, 1, 2)
		testing.expect(t, ok); store.seal_bytes = bytes
		store.frozen.async_readers = 1
		testing.expect(t, publish_frozen_message_seal(&store))
		testing.expect(t, store.frozen != nil)
		store.frozen.async_readers = 0
		frozen := store.frozen
		server: NRC_Server
		server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
		defer chan.destroy(server.shard_compaction_jobs)
		server.shard_compaction_results = make([]^spsc.Queue(Shard_Compaction_Result), 2)
		for &queue in server.shard_compaction_results do queue, _ = spsc.create(Shard_Compaction_Result, 1)
		defer {for queue in server.shard_compaction_results do spsc.destroy(queue); delete(server.shard_compaction_results)}
		td.server = &server; defer {discard_queued_shard_compaction_jobs(&server); td.server = nil}
		previous_worker := td.thread_index; defer {td.thread_index = previous_worker}
		td.thread_index = 1
		testing.expect(t, chan.try_send(server.shard_compaction_jobs, Shard_Compaction_Job{}))
		destroy_frozen_message_store(&store, true)
		testing.expect(t, store.frozen == frozen, "queue refusal must preserve the holder for retry")
		_, received := chan.try_recv(server.shard_compaction_jobs); testing.expect(t, received)
		destroy_frozen_message_store(&store, true)
		testing.expect(t, store.frozen == nil)
		path := message_store_path(store.directory, 1, "wal"); defer delete(path)
		exists, err := storage_io.exists(store.storage, path)
		testing.expect(t, err == nil && exists, "delete must wait for service")
		testing.expect(t, service_shard_compaction_job(&server))
		for queue in server.shard_compaction_results {
			_, received = spsc.try_pop(queue)
			testing.expect(t, !received, "cleanup must not occupy any completion queue")
		}
		exists, err = storage_io.exists(store.storage, path)
		testing.expect(t, err == nil && !exists)
	}
}
