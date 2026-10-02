// Opt-in retained-message storage benchmark.
//
// Run with:
//   BENCH_MESSAGE_STORE=1 odin test . -o:speed -define:ODIN_TEST_THREADS=1 \
//     -define:ODIN_TEST_NAMES=main.benchmark_message_store_initial
package main

import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sys/linux"
import "core:testing"
import "core:time"

import nbio "nbio/poly"
import pr "protocol"

when !NRC_SIMULATION {
	_ :: slice.sort_by
	_ :: linux.Errno
	_ :: nbio.tick
	_ :: pr.MessageRangeRequest
}

message_store_benchmark_env_int :: proc(name: string, fallback: int) -> int {
	value, found := os.lookup_env_alloc(name, context.allocator)
	if !found do return fallback
	defer delete(value)
	parsed, ok := strconv.parse_int(value)
	if !ok || parsed <= 0 do return fallback
	return int(parsed)
}

message_store_benchmark_env_enabled :: proc(name: string) -> bool {
	value, found := os.lookup_env_alloc(name, context.allocator)
	defer delete(value)
	return found && value != "0" && value != "false"
}

message_history_benchmark_external_barrier :: proc(phase: string) -> bool {
	ready_prefix := os.get_env_alloc("NRC_MESSAGE_BENCH_READY_PREFIX", context.allocator)
	defer delete(ready_prefix)
	start_prefix := os.get_env_alloc("NRC_MESSAGE_BENCH_START_PREFIX", context.allocator)
	defer delete(start_prefix)
	if ready_prefix == "" && start_prefix == "" do return true
	if ready_prefix == "" || start_prefix == "" do return false
	ready_path := fmt.aprintf("%s-%s", ready_prefix, phase); defer delete(ready_path)
	start_path := fmt.aprintf("%s-%s", start_prefix, phase); defer delete(start_path)
	if os.write_entire_file(ready_path, nil) != nil do return false
	wait_started := time.now()
	for !os.exists(start_path) && time.since(wait_started) < 30 * time.Second do time.sleep(time.Millisecond)
	return os.exists(start_path)
}

@(test)
benchmark_message_store_initial :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_MESSAGE_STORE", context.allocator)
	defer delete(enabled)
	if !found || enabled == "0" || enabled == "false" do return

	record_count := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_RECORDS", 100_000)
	content_bytes := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONTENT_BYTES", 256)
	conversation_count := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONVERSATIONS", 64)
	workspace := "retained-message-storage-benchmark"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-benchmark"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	content := make([]byte, content_bytes); defer delete(content)
	for &value, i in content do value = byte('a' + i % 26)
	track_allocations := message_store_benchmark_env_enabled("NRC_MESSAGE_BENCH_TRACK_ALLOC")
	original_allocator := context.allocator
	allocation_tracker: mem.Tracking_Allocator
	if track_allocations {
		mem.tracking_allocator_init(&allocation_tracker, original_allocator, original_allocator)
	}
	selected_allocator := original_allocator
	if track_allocations do selected_allocator = mem.tracking_allocator(&allocation_tracker)
	context.allocator = selected_allocator
	defer {
		context.allocator = original_allocator
		if track_allocations do mem.tracking_allocator_destroy(&allocation_tracker)
	}

	store: Message_Store
	if !init_message_store(&store, dir, shard, 24 * time.Hour, 0) {testing.expect(t, false, "message store init failed"); return}
	allocation_count_before := allocation_tracker.total_allocation_count
	allocated_bytes_before := allocation_tracker.total_memory_allocated
	now := nrc_time_unix_nanos()
	appended := 0
	append_started := time.now()
	for i in 0 ..< record_count {
		message := test_retained_message(workspace, u64(i % conversation_count + 1), u64(i + 1), now + i64(i))
		message.content = content
		result, _ := append_or_deduplicate_message(&store, &message)
		if result != .Appended do break
		appended += 1
	}
	append_elapsed := time.since(append_started)
	written_bytes := store.active_bytes
	testing.expect_value(t, appended, record_count)
	testing.expect_value(t, store.high_water, u64(record_count))
	append_allocation_count := allocation_tracker.total_allocation_count - allocation_count_before
	append_allocated_bytes := allocation_tracker.total_memory_allocated - allocated_bytes_before
	append_peak_bytes := allocation_tracker.peak_memory_allocated

	probe := test_retained_message(workspace, u64((record_count - 1) % conversation_count + 1), u64(record_count), now)
	probe.content = content
	dedup_iterations := max(record_count, 100_000)
	dedup_valid := 0
	dedup_started := time.now()
	for _ in 0 ..< dedup_iterations {
		result, sequence := append_or_deduplicate_message(&store, &probe)
		if result == .Duplicate && sequence == u64(record_count) do dedup_valid += 1
	}
	dedup_elapsed := time.since(dedup_started)
	testing.expect_value(t, dedup_valid, dedup_iterations)

	testing.expect(t, shutdown_message_store(&store))
	recovery_started := time.now()
	testing.expect(t, init_message_store(&store, dir, shard, 24 * time.Hour, 0))
	recovery_elapsed := time.since(recovery_started)
	testing.expect_value(t, store.high_water, u64(record_count))

	rotation_started := time.now()
	testing.expect(t, rotate_message_store(&store, now + i64(time.Hour)))
	rotation_elapsed := time.since(rotation_started)
	testing.expect_value(t, len(store.segments), 1)
	index_path := message_store_path(store.directory, store.segments[0].generation, "idx")
	index_file, index_open_err := os.open(index_path)
	index_bytes: i64
	if index_open_err == nil {index_bytes, _ = os.file_size(index_file); os.close(index_file)}
	delete(index_path)
	testing.expect(t, shutdown_message_store(&store))

	append_seconds := time.duration_seconds(append_elapsed)
	dedup_seconds := time.duration_seconds(dedup_elapsed)
	log.infof("=== Retained Message Store Initial Benchmark ===")
	log.infof(
		"records=%d conversations=%d content=%dB WAL=%.2fMiB append=%.0f msg/s %.2fMiB/s",
		record_count,
		conversation_count,
		content_bytes,
		f64(written_bytes) / (1024 * 1024),
		f64(record_count) / append_seconds,
		f64(written_bytes) / (1024 * 1024) / append_seconds,
	)
	if track_allocations {
		log.infof(
			"append_allocations=%d (%.2f/msg) allocated=%.2fMiB tracker_peak_live=%.2fMiB",
			append_allocation_count,
			f64(append_allocation_count) / f64(record_count),
			f64(append_allocated_bytes) / (1024 * 1024),
			f64(append_peak_bytes) / (1024 * 1024),
		)
	}
	log.infof(
		"active_dedup=%d lookups/s recovery=%v (%.0f msg/s)",
		int(f64(dedup_iterations) / dedup_seconds),
		recovery_elapsed,
		f64(record_count) / time.duration_seconds(recovery_elapsed),
	)
	log.infof("seal_and_build_index=%v index=%.2fMiB", rotation_elapsed, f64(index_bytes) / (1024 * 1024))
}

@(test)
benchmark_message_store_write_throughput :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_MESSAGE_STORE_WRITE", context.allocator)
	defer delete(enabled)
	if !found || enabled == "0" || enabled == "false" do return

	record_count := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_RECORDS", 100_000)
	content_bytes := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONTENT_BYTES", 1024)
	workspace := "retained-message-write-throughput"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	dir := test_wal_path("message-store-write-throughput"); _ = os.remove_all(dir)
	testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
	content := make([]byte, content_bytes); defer delete(content)
	for &value, i in content do value = byte('a' + i % 26)
	write_batch_records := message_store_benchmark_env_int("NRC_MESSAGE_WRITE_BATCH_RECORDS", DEFAULT_MESSAGE_WRITE_BATCH_RECORDS)
	write_batch_records = min(write_batch_records, MAX_MESSAGE_WRITE_BATCH_RECORDS)
	testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
	defer nbio.destroy(&td.io)
	td.message_stores = {}
	td.message_stores.enabled = true
	td.message_stores.write_batch_records = write_batch_records

	store: Message_Store
	if !init_message_store(&store, dir, shard, 24 * time.Hour, 0) {
		testing.expect(t, false, "message store init failed")
		return
	}
	if !message_history_benchmark_external_barrier("write-throughput") {
		testing.expect(t, false, "retained-message benchmark profiler barrier failed")
		_ = shutdown_message_store(&store)
		return
	}
	now := nrc_time_unix_nanos()
	submitted := 0
	write_ok := true
	started := time.now()
	for i in 0 ..< record_count {
		ctx := new(Retained_Dedup_Context)
		ctx.store = &store
		ctx.message = test_retained_message(workspace, u64(i % 64 + 1), u64(i + 1), now + i64(i))
		ctx.message.workspace, _ = strings.clone(workspace)
		ctx.message.sender_name, _ = strings.clone("alice")
		ctx.message.sender_principal, _ = strings.clone("alice-principal")
		ctx.message.content = make([]byte, content_bytes); copy(ctx.message.content, content)
		ctx.dedup_cutoff_ns = message_store_dedup_cutoff(&store, ctx.message.accepted_at_ns)
		retained_message_queue_append(ctx, false)
		submitted += 1
		if (write_batch_records > 0 && len(store.pending_appends) >= write_batch_records) || len(store.deferred_appends) > 0 {
			_, write_ok = flush_pending_retained_message_writes(&td.message_stores)
			if !write_ok do break
			_ = nbio.submit_pending(&td.io)
			_ = nbio.tick(&td.io, 0, yield_after_callbacks = true)
		}
	}
	for write_ok && td.message_stores.pending_write_count > 0 {
		_, write_ok = flush_pending_retained_message_writes(&td.message_stores)
		_ = nbio.submit_pending(&td.io)
		_ = nbio.tick(&td.io, 0, yield_after_callbacks = true)
	}
	_ = nbio.submit_pending(&td.io)
	for store.fsync_in_flight && time.since(started) < 30 * time.Second {
		if nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true) != linux.Errno.NONE {write_ok = false; break}
	}
	if write_ok && schedule_retained_message_fsync(&store) {
		_ = nbio.submit_pending(&td.io)
		for store.fsync_in_flight && time.since(started) < 30 * time.Second {
			if nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true) != linux.Errno.NONE {write_ok = false; break}
		}
	}
	elapsed := time.since(started)
	wal_bytes := store.active_bytes
	testing.expect(t, write_ok)
	testing.expect_value(t, submitted, record_count)
	testing.expect_value(t, store.high_water, u64(record_count))

	seconds := time.duration_seconds(elapsed)
	log.infof(
		"RETAINED_WRITE_RESULT content_bytes=%d record_bytes=%d records=%d wal_bytes=%d elapsed_ns=%d messages_per_s=%.3f mib_per_s=%.3f write_calls=%d fsyncs=%d batch_records=%d",
		content_bytes,
		wal_bytes / u64(record_count),
		record_count,
		wal_bytes,
		time.duration_nanoseconds(elapsed),
		f64(record_count) / seconds,
		f64(wal_bytes) / (1024 * 1024) / seconds,
		store.wal.write_count,
		store.wal.fsync_count,
		write_batch_records,
	)
	testing.expect(t, shutdown_message_store(&store))
	td.message_stores = {}
}

when NRC_SIMULATION {
	message_history_benchmark_page :: proc(
		conn: ^NRC_Connection,
		request: pr.MessageRangeRequest,
		ascending: bool,
	) -> (
		elapsed: time.Duration,
		count: int,
		ok: bool,
	) {
		// Benchmark durable history, excluding fixture commits from page latency.
		if !simulation_test_commit_messages(nrc_sim_runtime) do return
		nrc_sim_clear_inboxes(nrc_sim_runtime)
		started := time.now()
		process_message_history(conn, request, ascending)
		for conn.retained_io > 0 && time.since(started) < 10 * time.Second {
			if nrc_sim_run_next_file_read(nrc_sim_runtime) do continue
			if nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true) != linux.Errno.NONE do return
		}
		if conn.retained_io != 0 || nrc_sim_client_frame_count(nrc_sim_runtime, conn.sock) != 1 do return
		// Host I/O is timed on the host clock; simulated submission timestamps
		// belong to a different epoch and cannot be subtracted from started.
		elapsed = time.since(started)
		payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(nrc_sim_runtime, conn.sock, 0))
		if !payload_ok || pr.get_opcode(payload) != .S_MessagePage do return
		page, parse_err := pr.parseMessagePage(payload[2:])
		if parse_err != nil do return
		return elapsed, len(page.messages), true
	}

	message_history_benchmark_warm_cache :: proc(conn: ^NRC_Connection, conversation_id: pr.ConversationID, record_count: int) -> bool {
		request := pr.MessageRangeRequest {
			conv_id        = conversation_id,
			cursor         = pr.MessageSeq(record_count),
			limit          = 100,
			correlation_id = 0xffff_fffe,
		}
		_, _, descending_ok := message_history_benchmark_page(conn, request, false)
		request.cursor = 0
		request.correlation_id = 0xffff_ffff
		_, _, ascending_ok := message_history_benchmark_page(conn, request, true)
		return descending_ok && ascending_ok
	}

	message_history_benchmark_log :: proc(label: string, samples: []time.Duration, total_messages: int) {
		slice.sort_by(samples, proc(a, b: time.Duration) -> bool {return a < b})
		total: time.Duration
		for sample in samples do total += sample
		average := total / time.Duration(len(samples))
		p50 := samples[len(samples) / 2]
		p95 := samples[min(len(samples) - 1, len(samples) * 95 / 100)]
		log.infof("%s pages=%d messages=%d avg=%v p50=%v p95=%v max=%v", label, len(samples), total_messages, average, p50, p95, samples[len(samples) - 1])
	}

	message_history_profile_log :: proc(label: string, samples: []time.Duration) {
		slice.sort_by(samples, proc(a, b: time.Duration) -> bool {return a < b})
		total: time.Duration
		for sample in samples do total += sample
		log.infof(
			"sealed profile %s samples=%d avg=%v p50=%v p95=%v max=%v",
			label,
			len(samples),
			total / time.Duration(len(samples)),
			samples[len(samples) / 2],
			samples[min(len(samples) - 1, len(samples) * 95 / 100)],
			samples[len(samples) - 1],
		)
	}

	Message_History_Live_Benchmark_Result :: struct {
		descending:           [dynamic]time.Duration,
		ascending:            [dynamic]time.Duration,
		submit_commit_turns:  [dynamic]time.Duration,
		commit_publish_turns: [dynamic]time.Duration,
		wal_write_calls:      [dynamic]time.Duration,
		wal_fsync_calls:      [dynamic]time.Duration,
		descending_messages:  int,
		ascending_messages:   int,
		live_submitted:       int,
		elapsed:              time.Duration,
	}

	message_history_live_result_destroy :: proc(result: ^Message_History_Live_Benchmark_Result) {
		delete(result.descending)
		delete(result.ascending)
		delete(result.submit_commit_turns)
		delete(result.commit_publish_turns)
		delete(result.wal_write_calls)
		delete(result.wal_fsync_calls)
		result^ = {}
	}

	Message_History_WAL_Counters :: struct {
		write_count:      u64,
		write_latency_ns: u64,
		fsync_count:      u64,
		fsync_latency_ns: u64,
	}

	message_history_wal_counters :: proc() -> Message_History_WAL_Counters {
		result: Message_History_WAL_Counters
		for &store in td.message_stores.stores {
			result.write_count += store.wal.write_count
			result.write_latency_ns += store.wal.total_write_latency_ns
			result.fsync_count += store.wal.fsync_count
			result.fsync_latency_ns += store.wal.total_fsync_latency_ns
		}
		return result
	}

	message_history_capture_wal_calls :: proc(result: ^Message_History_Live_Benchmark_Result, before: Message_History_WAL_Counters) {
		after := message_history_wal_counters()
		if after.write_count > before.write_count {
			append(&result.wal_write_calls, time.Duration(after.write_latency_ns - before.write_latency_ns))
		}
		if after.fsync_count > before.fsync_count {
			append(&result.wal_fsync_calls, time.Duration(after.fsync_latency_ns - before.fsync_latency_ns))
		}
	}

	message_history_live_writers_pending :: proc(writers: []^NRC_Connection) -> bool {
		for writer in writers {
			if writer.retained_io > 0 do return true
		}
		return false
	}

	message_history_live_submit_due :: proc(
		writers: []^NRC_Connection,
		conversation_id: pr.ConversationID,
		content: []byte,
		write_rate: int,
		phase_started: time.Time,
		marker: ^u64,
		result: ^Message_History_Live_Benchmark_Result,
	) {
		if write_rate <= 0 do return
		due := int(time.duration_seconds(time.since(phase_started)) * f64(write_rate))
		remaining := min(max(due - result.live_submitted, 0), 256)
		for remaining > 0 {
			writer: ^NRC_Connection
			for candidate in writers {
				if candidate.retained_io < MAX_RETAINED_IO_PER_CONNECTION {
					writer = candidate
					break
				}
			}
			if writer == nil do break
			marker^ += 1
			client_message_id: [16]byte
			message_put_u64(client_message_id[:], marker^)
			process_send_message_v2(
				writer,
				pr.SendMessageV2Request {
					conv_id = conversation_id,
					client_message_id = client_message_id,
					content_type = .PlainText,
					content = content,
					correlation_id = u32(marker^),
				},
			)
			result.live_submitted += 1
			remaining -= 1
		}
	}

	message_history_concurrent_benchmark_phase :: proc(
		readers: []^NRC_Connection,
		writers: []^NRC_Connection,
		sim: ^Sim_Runtime,
		conversation_id: pr.ConversationID,
		live_conversation_id: pr.ConversationID,
		record_count: int,
		sequence_stride: u64,
		rounds: int,
		duration: time.Duration,
		content: []byte,
		write_rate: int,
		marker: ^u64,
		result: ^Message_History_Live_Benchmark_Result,
	) -> bool {
		result^ = {}
		result.descending = make([dynamic]time.Duration, 0, rounds * (len(readers) + 1) / 2)
		result.ascending = make([dynamic]time.Duration, 0, rounds * len(readers) / 2)
		result.submit_commit_turns = make([dynamic]time.Duration, 0, rounds)
		result.commit_publish_turns = make([dynamic]time.Duration, 0, rounds)
		result.wal_write_calls = make([dynamic]time.Duration, 0, rounds)
		result.wal_fsync_calls = make([dynamic]time.Duration, 0, max(rounds / 100, 2))
		phase_started := time.now()
		cursor_span := max(record_count - 101, 1)
		for round := 0;; round += 1 {
			if duration == 0 && round >= rounds do break
			if duration > 0 && time.since(phase_started) >= duration do break
			nrc_sim_clear_inboxes(sim)
			started: [8]time.Time
			completed: [8]bool
			pending := len(readers)
			for reader_index in 0 ..< len(readers) {
				ascending := (reader_index + round) % 2 == 1
				cursor: u64
				if ascending {
					target_index := u64((round * 991 + reader_index * 313) % cursor_span)
					cursor = target_index * sequence_stride
				} else {
					target_index := u64(record_count - ((round * 997 + reader_index * 307) % cursor_span))
					cursor = (target_index - 1) * sequence_stride + 1
				}
				started[reader_index] = time.now()
				process_message_history(
					readers[reader_index],
					pr.MessageRangeRequest {
						conv_id = conversation_id,
						cursor = pr.MessageSeq(cursor),
						limit = 100,
						correlation_id = u32(round * len(readers) + reader_index),
					},
					ascending,
				)
			}
			wait_started := time.now()
			for pending > 0 && time.since(wait_started) < 10 * time.Second {
				submit_commit_started := time.now()
				message_history_live_submit_due(writers, live_conversation_id, content, write_rate, phase_started, marker, result)
				commit_publish_started := time.now()
				wal_before := message_history_wal_counters()
				did_commit, writes_ok := flush_pending_retained_message_writes(&td.message_stores)
				message_history_capture_wal_calls(result, wal_before)
				if !writes_ok do return false
				if did_commit {
					append(&result.submit_commit_turns, time.since(submit_commit_started))
					append(&result.commit_publish_turns, time.since(commit_publish_started))
				}
				for nrc_sim_run_next_file_read(sim) {}
				for nrc_sim_run_next_fsync_completion(sim) {}
				nrc_sim_run_all_send_completions(sim)
				for reader_index in 0 ..< len(readers) {
					if completed[reader_index] || nrc_sim_client_frame_count(sim, readers[reader_index].sock) == 0 do continue
					payload, payload_ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(sim, readers[reader_index].sock, 0))
					if !payload_ok || pr.get_opcode(payload) != .S_MessagePage do return false
					page, parse_err := pr.parseMessagePage(payload[2:])
					if parse_err != nil do return false
					latency := time.since(started[reader_index])
					if (reader_index + round) % 2 == 1 {
						append(&result.ascending, latency)
						result.ascending_messages += len(page.messages)
					} else {
						append(&result.descending, latency)
						result.descending_messages += len(page.messages)
					}
					completed[reader_index] = true
					pending -= 1
				}
				if pending > 0 {
					wal_before := message_history_wal_counters()
					tick_err := nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true)
					message_history_capture_wal_calls(result, wal_before)
					if tick_err != linux.Errno.NONE do return false
				}
			}
			if pending != 0 do return false
		}
		wait_started := time.now()
		for message_history_live_writers_pending(writers) && time.since(wait_started) < 10 * time.Second {
			commit_publish_started := time.now()
			wal_before := message_history_wal_counters()
			did_commit, writes_ok := flush_pending_retained_message_writes(&td.message_stores)
			message_history_capture_wal_calls(result, wal_before)
			if !writes_ok do return false
			if did_commit do append(&result.commit_publish_turns, time.since(commit_publish_started))
			for nrc_sim_run_next_file_read(sim) {}
			if !simulation_test_commit_messages(sim) do return false
			wal_before = message_history_wal_counters()
			tick_err := nbio.tick(&td.io, time.Millisecond, yield_after_callbacks = true)
			message_history_capture_wal_calls(result, wal_before)
			if tick_err != linux.Errno.NONE do return false
		}
		if message_history_live_writers_pending(writers) do return false
		// Dedup I/O can finish before its ACK becomes durable. Include the final
		// commit and delivery even when every writer has already released its I/O.
		if !simulation_test_commit_messages(sim) do return false
		for &store in td.message_stores.stores {
			if store.wal.pending_bytes != 0 || store.wal.write_offset != 0 || store.wal.durable_record_count != store.wal.record_count {
				return false
			}
		}
		for writer in writers {
			if writer.retained_io != 0 || writer.pending_io != 0 || writer.is_sending || send_queue_len(writer) != 0 do return false
		}
		if nrc_sim_send_completion_count(sim) != 0 do return false
		result.elapsed = time.since(phase_started)
		return true
	}

	@(test)
	benchmark_message_store_sealed_history :: proc(t: ^testing.T) {
		if !message_store_benchmark_env_enabled("BENCH_MESSAGE_HISTORY") do return
		record_count := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_RECORDS", 100_000)
		content_bytes := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONTENT_BYTES", 256)
		rounds := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_HISTORY_ROUNDS", 200)
		if record_count < 200 do record_count = 200
		workspace := "retained-message-history-benchmark"
		conversation_id := pr.ConversationID(42)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("message-history-benchmark"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		content := make([]byte, content_bytes); defer delete(content)
		for &value, i in content do value = byte('a' + i % 26)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return
		subscribe_to_conversation(conn, conversation_id)
		nrc_sim_clear_inboxes(&ctx.sim)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		sealed_cache_bytes, sealed_cache_valid := configured_message_sealed_index_cache_bytes()
		testing.expect(t, sealed_cache_valid)
		if !sealed_cache_valid do return
		td.message_stores.sealed_index_cache.limit_bytes = sealed_cache_bytes
		td.message_stores.sealed_wal_cache.limit = MESSAGE_SEALED_WAL_CACHE_LIMIT
		testing.expect(
			t,
			init_message_store(
				&td.message_stores.stores[0],
				dir,
				shard,
				24 * time.Hour,
				0,
				sealed_index_cache = &td.message_stores.sealed_index_cache,
				sealed_wal_cache = &td.message_stores.sealed_wal_cache,
			),
		)
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		for i in 0 ..< record_count {
			message := test_retained_message(workspace, u64(conversation_id), u64(i + 1), now + i64(i))
			message.content = content
			result, _ := append_or_deduplicate_message(store, &message)
			if result != .Appended {testing.expectf(t, false, "append %d failed: %v", i, result); return}
		}
		testing.expect(t, rotate_message_store(store, now + i64(time.Hour)))
		testing.expect(t, message_history_benchmark_warm_cache(conn, conversation_id, record_count), "history warmup failed")

		descending := make([]time.Duration, rounds); defer delete(descending)
		ascending := make([]time.Duration, rounds); defer delete(ascending)
		profile_retrieval := make([]time.Duration, rounds * 2); defer delete(profile_retrieval)
		profile_decode := make([]time.Duration, rounds * 2); defer delete(profile_decode)
		profile_serialization := make([]time.Duration, rounds * 2); defer delete(profile_serialization)
		profile_full := make([]time.Duration, rounds * 2); defer delete(profile_full)
		retained_history_profile_enabled = true
		defer {retained_history_profile_enabled = false}
		descending_messages, ascending_messages := 0, 0
		cursor_span := max(record_count - 101, 1)
		for round in 0 ..< rounds {
			before := u64(record_count - (round * 997 % cursor_span))
			request := pr.MessageRangeRequest {
				conv_id        = conversation_id,
				cursor         = pr.MessageSeq(before),
				limit          = 100,
				correlation_id = u32(round),
			}
			elapsed, count, page_ok := message_history_benchmark_page(conn, request, false)
			testing.expect(t, page_ok); if !page_ok do return
			descending[round] = elapsed; descending_messages += count
			profile_index := round * 2
			profile_retrieval[profile_index] = retained_history_profile_latest.retrieval
			profile_decode[profile_index] = retained_history_profile_latest.decode
			profile_serialization[profile_index] = retained_history_profile_latest.serialization
			profile_full[profile_index] = elapsed
			after := u64(round * 991 % cursor_span)
			request.cursor = pr.MessageSeq(after)
			elapsed, count, page_ok = message_history_benchmark_page(conn, request, true)
			testing.expect(t, page_ok); if !page_ok do return
			ascending[round] = elapsed; ascending_messages += count
			profile_retrieval[profile_index + 1] = retained_history_profile_latest.retrieval
			profile_decode[profile_index + 1] = retained_history_profile_latest.decode
			profile_serialization[profile_index + 1] = retained_history_profile_latest.serialization
			profile_full[profile_index + 1] = elapsed
		}
		log.infof("=== Retained Message Sealed History (io_uring, warm cache) ===")
		log.infof(
			"records=%d content=%dB WAL=%.2fMiB index=%.2fMiB",
			record_count,
			content_bytes,
			f64(store.segments[0].bytes) / (1024 * 1024),
			f64(record_count * (MESSAGE_INDEX_ENTRY_SIZE + MESSAGE_DEDUP_ENTRY_SIZE) + MESSAGE_INDEX_HEADER_SIZE) / (1024 * 1024),
		)
		message_history_benchmark_log("descending", descending, descending_messages)
		message_history_benchmark_log("ascending", ascending, ascending_messages)
		message_history_profile_log("retrieval_to_bytes", profile_retrieval)
		message_history_profile_log("decode_validate", profile_decode)
		message_history_profile_log("serialize_submit", profile_serialization)
		message_history_profile_log("full_delivery", profile_full)
	}

	@(test)
	benchmark_message_store_active_history :: proc(t: ^testing.T) {
		if !message_store_benchmark_env_enabled("BENCH_MESSAGE_HISTORY_ACTIVE") do return
		target_count := max(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_ACTIVE_RECORDS", 10_000), 200)
		distractors_per_target := clamp(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_ACTIVE_DISTRACTORS", 5), 1, 20)
		content_bytes := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONTENT_BYTES", 256)
		rounds := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_HISTORY_ROUNDS", 200)
		concurrent_rounds := max(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_ACTIVE_CONCURRENT_ROUNDS", 0), 0)
		reader_count := clamp(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_ACTIVE_READERS", 1), 1, 8)
		workspace := "retained-message-active-history-benchmark"
		conversation_id := pr.ConversationID(42)
		distractor_conversation_id := pr.ConversationID(43)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("message-active-history-benchmark"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		content := make([]byte, content_bytes); defer delete(content)
		for &value, i in content do value = byte('a' + i % 26)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		conn := simulation_test_install_client(&ctx.sim, 1, workspace, "history-reader", init_send_queue = true)
		ctx.conns[1] = conn
		testing.expect(t, conn != nil)
		if conn == nil do return
		subscribe_to_conversation(conn, conversation_id)
		nrc_sim_clear_inboxes(&ctx.sim)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		testing.expect(t, append_err == nil)
		if append_err != nil do return
		cache_bytes, cache_valid := configured_message_active_cache_bytes()
		testing.expect(t, cache_valid)
		if !cache_valid do return
		td.message_stores.active_cache.limit_bytes = cache_bytes
		testing.expect(
			t,
			init_message_store(&td.message_stores.stores[0], dir, shard, 24 * time.Hour, 0, active_cache_budget = &td.message_stores.active_cache),
		)
		td.message_stores.enabled = true
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		now := nrc_time_unix_nanos()
		marker: u64 = 1
		for _ in 0 ..< target_count {
			message := test_retained_message(workspace, u64(conversation_id), marker, now)
			message.content = content
			marker += 1
			result, _ := append_or_deduplicate_message(store, &message)
			if result != .Appended {testing.expectf(t, false, "target append failed: %v", result); return}
			for _ in 0 ..< distractors_per_target {
				distractor := test_retained_message(workspace, u64(distractor_conversation_id), marker, now)
				distractor.content = content
				marker += 1
				result, _ = append_or_deduplicate_message(store, &distractor)
				if result != .Appended {testing.expectf(t, false, "distractor append failed: %v", result); return}
			}
		}
		testing.expect_value(t, len(store.segments), 0)
		_, warm_count, warm_ok := message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = 0, limit = 100, correlation_id = 0xffff_fffe},
			false,
		)
		testing.expect(t, warm_ok && warm_count == 100, "active descending warmup failed")
		_, warm_count, warm_ok = message_history_benchmark_page(
			conn,
			pr.MessageRangeRequest{conv_id = conversation_id, cursor = 0, limit = 100, correlation_id = 0xffff_ffff},
			true,
		)
		testing.expect(t, warm_ok && warm_count == 100, "active ascending warmup failed")

		descending := make([]time.Duration, rounds); defer delete(descending)
		ascending := make([]time.Duration, rounds); defer delete(ascending)
		descending_messages, ascending_messages := 0, 0
		cursor_span := max(target_count - 101, 1)
		stride := u64(distractors_per_target + 1)
		for round in 0 ..< rounds {
			target_index := target_count - (round * 997 % cursor_span)
			before := u64(target_index) * stride + 1
			request := pr.MessageRangeRequest {
				conv_id        = conversation_id,
				cursor         = pr.MessageSeq(before),
				limit          = 100,
				correlation_id = u32(round),
			}
			elapsed, count, page_ok := message_history_benchmark_page(conn, request, false)
			testing.expect(t, page_ok); if !page_ok do return
			descending[round] = elapsed; descending_messages += count
			target_index = round * 991 % cursor_span
			request.cursor = pr.MessageSeq(u64(target_index) * stride + 1)
			elapsed, count, page_ok = message_history_benchmark_page(conn, request, true)
			testing.expect(t, page_ok); if !page_ok do return
			ascending[round] = elapsed; ascending_messages += count
		}
		log.infof("=== Retained Message Active History (memtable with io_uring fallback) ===")
		log.infof(
			"target_records=%d total_records=%d distractors_per_target=%d content=%dB WAL=%.2fMiB active_cache=%.2fMiB/%.2fMiB",
			target_count,
			target_count * (distractors_per_target + 1),
			distractors_per_target,
			content_bytes,
			f64(store.active_bytes) / (1024 * 1024),
			f64(store.active_cached_bytes) / (1024 * 1024),
			f64(td.message_stores.active_cache.limit_bytes) / (1024 * 1024),
		)
		message_history_benchmark_log("active descending", descending, descending_messages)
		message_history_benchmark_log("active ascending", ascending, ascending_messages)

		if concurrent_rounds > 0 {
			readers: [8]^NRC_Connection
			readers[0] = conn
			for i in 1 ..< reader_count {
				readers[i] = simulation_test_install_client(&ctx.sim, i + 1, workspace, "active-history-reader", init_send_queue = true)
				ctx.conns[i + 1] = readers[i]
				if readers[i] == nil {testing.expect(t, false, "failed to install active history reader"); return}
				subscribe_to_conversation(readers[i], conversation_id)
			}
			concurrent: Message_History_Live_Benchmark_Result
			defer message_history_live_result_destroy(&concurrent)
			testing.expect(t, message_history_benchmark_external_barrier("active"), "active history scale-out barrier failed")
			testing.expect(
				t,
				message_history_concurrent_benchmark_phase(
					readers[:reader_count],
					nil,
					&ctx.sim,
					conversation_id,
					0,
					target_count,
					stride,
					concurrent_rounds,
					0,
					content,
					0,
					&marker,
					&concurrent,
				),
			)
			if len(concurrent.descending) > 0 do message_history_benchmark_log("active concurrent descending", concurrent.descending[:], concurrent.descending_messages)
			if len(concurrent.ascending) > 0 do message_history_benchmark_log("active concurrent ascending", concurrent.ascending[:], concurrent.ascending_messages)
			log.infof(
				"active concurrent readers=%d elapsed=%v pages/s=%.0f",
				reader_count,
				concurrent.elapsed,
				f64(len(concurrent.descending) + len(concurrent.ascending)) / time.duration_seconds(concurrent.elapsed),
			)
		}
	}

	@(test)
	benchmark_message_store_history_under_live_traffic :: proc(t: ^testing.T) {
		if !message_store_benchmark_env_enabled("BENCH_MESSAGE_HISTORY_LIVE") do return
		record_count := max(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_RECORDS", 100_000), 200)
		content_bytes := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_CONTENT_BYTES", 1024)
		rounds := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_HISTORY_ROUNDS", 1_000)
		reader_count := clamp(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_HISTORY_READERS", 4), 1, 8)
		writer_count := clamp(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_LIVE_WRITERS", 4), 1, 15 - reader_count)
		write_rate := message_store_benchmark_env_int("NRC_MESSAGE_BENCH_LIVE_WRITE_RATE", 25_000)
		write_batch_records, write_batch_records_valid := configured_message_write_batch_records()
		testing.expect(t, write_batch_records_valid)
		if !write_batch_records_valid do return
		live_duration_ms := max(message_store_benchmark_env_int("NRC_MESSAGE_BENCH_LIVE_DURATION_MS", 0), 0)
		live_duration := time.Duration(live_duration_ms) * time.Millisecond
		skip_baseline := message_store_benchmark_env_enabled("NRC_MESSAGE_BENCH_SKIP_BASELINE")
		workspace := "retained-message-live-history-benchmark"
		conversation_id := pr.ConversationID(42)
		live_conversation_id := pr.ConversationID(777)
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		dir := test_wal_path("message-history-live-benchmark"); _ = os.remove_all(dir)
		testing.expect(t, os.make_directory(dir) == nil); defer os.remove_all(dir)
		content := make([]byte, content_bytes); defer delete(content)
		for &value, i in content do value = byte('a' + i % 26)

		ctx: Sim_Test_Context
		simulation_test_begin(&ctx)
		defer simulation_test_end(&ctx)
		testing.expect_value(t, nbio.init(&td.io), linux.Errno.NONE)
		defer nbio.destroy(&td.io)
		readers := make([]^NRC_Connection, reader_count); defer delete(readers)
		writers := make([]^NRC_Connection, writer_count); defer delete(writers)
		for i in 0 ..< reader_count {
			readers[i] = simulation_test_install_client(&ctx.sim, i + 1, workspace, "history-reader", init_send_queue = true)
			ctx.conns[i + 1] = readers[i]
			if readers[i] == nil {testing.expect(t, false, "failed to install history reader"); return}
			subscribe_to_conversation(readers[i], conversation_id)
		}
		for i in 0 ..< writer_count {
			client_id := reader_count + i + 1
			writers[i] = simulation_test_install_client(&ctx.sim, client_id, workspace, "live-writer", init_send_queue = true)
			ctx.conns[client_id] = writers[i]
			if writers[i] == nil {testing.expect(t, false, "failed to install live writer"); return}
		}
		nrc_sim_clear_inboxes(&ctx.sim)

		for &index in td.message_stores.store_index do index = -1
		_, append_err := append(&td.message_stores.stores, Message_Store{})
		if append_err != nil {testing.expect(t, false, "failed to allocate message store"); return}
		cache_bytes, cache_valid := configured_message_active_cache_bytes()
		testing.expect(t, cache_valid)
		if !cache_valid do return
		td.message_stores.active_cache.limit_bytes = cache_bytes
		sealed_cache_bytes, sealed_cache_valid := configured_message_sealed_index_cache_bytes()
		testing.expect(t, sealed_cache_valid)
		if !sealed_cache_valid do return
		td.message_stores.sealed_index_cache.limit_bytes = sealed_cache_bytes
		td.message_stores.sealed_wal_cache.limit = MESSAGE_SEALED_WAL_CACHE_LIMIT
		testing.expect(
			t,
			init_message_store(
				&td.message_stores.stores[0],
				dir,
				shard,
				24 * time.Hour,
				0,
				active_cache_budget = &td.message_stores.active_cache,
				sealed_index_cache = &td.message_stores.sealed_index_cache,
				sealed_wal_cache = &td.message_stores.sealed_wal_cache,
			),
		)
		td.message_stores.enabled = true
		td.message_stores.write_batch_records = write_batch_records
		td.message_stores.store_index[shard] = 0
		defer shutdown_message_store_registry(&td.message_stores)
		store := &td.message_stores.stores[0]
		seed_now := nrc_time_unix_nanos()
		for i in 0 ..< record_count {
			message := test_retained_message(workspace, u64(conversation_id), u64(i + 1), seed_now + i64(i))
			message.content = content
			result, _ := append_or_deduplicate_message(store, &message)
			if result != .Appended {testing.expectf(t, false, "seed append %d failed: %v", i, result); return}
		}
		testing.expect(t, rotate_message_store(store, nrc_time_unix_nanos()))
		testing.expect(t, message_history_benchmark_warm_cache(readers[0], conversation_id, record_count), "history warmup failed")

		marker := u64(record_count)
		baseline, loaded: Message_History_Live_Benchmark_Result
		defer message_history_live_result_destroy(&baseline)
		defer message_history_live_result_destroy(&loaded)
		if !skip_baseline {
			testing.expect(t, message_history_benchmark_external_barrier("baseline"), "sealed history baseline scale-out barrier failed")
			testing.expect(
				t,
				message_history_concurrent_benchmark_phase(
					readers,
					writers,
					&ctx.sim,
					conversation_id,
					live_conversation_id,
					record_count,
					1,
					rounds,
					0,
					content,
					0,
					&marker,
					&baseline,
				),
			)
		}
		high_water_before := store.high_water
		testing.expect(t, message_history_benchmark_external_barrier("loaded"), "sealed history loaded scale-out barrier failed")
		testing.expect(
			t,
			message_history_concurrent_benchmark_phase(
				readers,
				writers,
				&ctx.sim,
				conversation_id,
				live_conversation_id,
				record_count,
				1,
				rounds,
				live_duration,
				content,
				write_rate,
				&marker,
				&loaded,
			),
		)
		testing.expect_value(t, store.high_water - high_water_before, u64(loaded.live_submitted))

		log.infof("=== Concurrent Retained History Under Live Traffic (io_uring, warm cache) ===")
		log.infof(
			"records=%d content=%dB readers=%d writers=%d rounds=%d loaded_duration=%v write_batch_records=%d target_live_rate=%d msg/s",
			record_count,
			content_bytes,
			reader_count,
			writer_count,
			rounds,
			live_duration,
			write_batch_records,
			write_rate,
		)
		if !skip_baseline {
			message_history_benchmark_log("baseline descending", baseline.descending[:], baseline.descending_messages)
			message_history_benchmark_log("baseline ascending", baseline.ascending[:], baseline.ascending_messages)
		}
		message_history_benchmark_log("loaded descending", loaded.descending[:], loaded.descending_messages)
		message_history_benchmark_log("loaded ascending", loaded.ascending[:], loaded.ascending_messages)
		if len(loaded.submit_commit_turns) > 0 do message_history_profile_log("loaded write_submit_commit_publish", loaded.submit_commit_turns[:])
		if len(loaded.commit_publish_turns) > 0 do message_history_profile_log("loaded write_commit_publish", loaded.commit_publish_turns[:])
		if len(loaded.wal_write_calls) > 0 do message_history_profile_log("loaded wal_write_syscall", loaded.wal_write_calls[:])
		if len(loaded.wal_fsync_calls) > 0 do message_history_profile_log("loaded wal_fsync", loaded.wal_fsync_calls[:])
		if !skip_baseline {
			log.infof(
				"baseline elapsed=%v pages/s=%.0f; loaded elapsed=%v pages/s=%.0f live_submitted=%d achieved_live_rate=%.0f msg/s",
				baseline.elapsed,
				f64(len(baseline.descending) + len(baseline.ascending)) / time.duration_seconds(baseline.elapsed),
				loaded.elapsed,
				f64(len(loaded.descending) + len(loaded.ascending)) / time.duration_seconds(loaded.elapsed),
				loaded.live_submitted,
				f64(loaded.live_submitted) / time.duration_seconds(loaded.elapsed),
			)
		} else {
			log.infof(
				"loaded elapsed=%v pages/s=%.0f live_submitted=%d achieved_live_rate=%.0f msg/s",
				loaded.elapsed,
				f64(len(loaded.descending) + len(loaded.ascending)) / time.duration_seconds(loaded.elapsed),
				loaded.live_submitted,
				f64(loaded.live_submitted) / time.duration_seconds(loaded.elapsed),
			)
		}
	}
}
