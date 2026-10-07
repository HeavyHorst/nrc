package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync/chan"
import "core:testing"
import "core:time"
import "spsc"
import "storage_io"
import tlsf "vendor/tlsf"

Owner_Bench_State :: struct {
	heap:    ^tlsf.Allocator,
	message: bool,
	size:    int,
	w:       ^Shard_Transaction_Writer,
	s:       ^Message_Store,
	server:  ^NRC_Server,
	queue:   ^spsc.Queue(Shard_Compaction_Result),
	store:   ^Message_Store,
	segment: ^Message_Segment_Descriptor,
	dedup:   bool,
	data:    []byte,
}

// Opt-in CPU workloads. BENCH_STORAGE_OWNER_ALLOC selects a separate, single-op
// counting run (no timings). BENCH_STORAGE_OWNER_MS sets the timing target.
// Lifecycle results are synthetic successes: no service execution, disk I/O,
// thread scheduling, WAL buffers, or durability latency is measured. Both queue
// endpoints execute on this thread using the real channel/SPSC and owner paths.
owner_bench_measure :: proc(label: string, operation: proc() -> u64, expected: u64, bytes_per_op: int, allocations: bool, tracker: ^mem.Tracking_Allocator) {
	if allocations {
		count := tracker.total_allocation_count
		bytes := tracker.total_memory_allocated
		live := tracker.current_memory_allocated
		tracker.peak_memory_allocated = live
		checksum := operation()
		assert(checksum == expected)
		fmt.printf(
			"OWNER_ALLOC %s allocations=%d bytes=%d peak_extra_bytes=%d checksum=%d\n",
			label,
			tracker.total_allocation_count - count,
			tracker.total_memory_allocated - bytes,
			tracker.peak_memory_allocated - live,
			checksum,
		)
		return
	}
	// Untimed warmup/calibration. A fixed measured loop avoids clock calls per op.
	pilot_rounds := 16
	elapsed: i64
	for {
		pilot := time.tick_now()
		checksum: u64
		for _ in 0 ..< pilot_rounds do checksum += operation()
		elapsed = max(i64(time.tick_since(pilot)), 1)
		assert(checksum == u64(pilot_rounds) * expected)
		if elapsed >= 25_000_000 do break
		pilot_rounds *= 2
	}
	target := message_store_benchmark_env_int("BENCH_STORAGE_OWNER_MS", 750)
	rounds := max(1, int(i64(target) * 1_000_000 * i64(pilot_rounds) / elapsed))
	callback_operation := operation
	options := time.Benchmark_Options {
		bench = proc(options: ^time.Benchmark_Options, _: mem.Allocator) -> time.Benchmark_Error {
			op := (cast(^proc() -> u64)options.user_data)^
			checksum: u64
			for _ in 0 ..< options.rounds do checksum += op()
			options.count = options.rounds
			options.processed = options.rounds * options.bytes
			options.hash = u128(checksum)
			return .Okay
		},
		rounds = rounds,
		bytes = bytes_per_op,
		user_data = &callback_operation,
	}
	assert(time.benchmark(&options) == .Okay)
	assert(options.hash == u128(rounds) * u128(expected))
	fmt.printf(
		"OWNER_TIME %s rounds=%d seconds=%.3f ns_per_op=%.2f processed_bytes=%d checksum=%d\n",
		label,
		rounds,
		time.duration_seconds(options.duration),
		f64(options.duration) / f64(rounds),
		options.processed,
		options.hash,
	)
}

@(test)
benchmark_storage_owner_lifecycle :: proc(t: ^testing.T) {
	if !message_store_benchmark_env_enabled("BENCH_STORAGE_OWNER") do return
	allocations := message_store_benchmark_env_enabled("BENCH_STORAGE_OWNER_ALLOC")
	backing := context.allocator
	tracker: mem.Tracking_Allocator
	if allocations {
		mem.tracking_allocator_init(&tracker, backing, backing)
		backing = mem.tracking_allocator(&tracker)
	}
	defer if allocations do mem.tracking_allocator_destroy(&tracker)
	context.allocator = backing
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, 64 * 1024))
	defer tlsf.destroy(&heap)
	old := new(Server_Thread); old^ = td; td = {}
	defer {td = old^; free(old)}
	td.backing_allocator = backing
	server: NRC_Server; td.server = &server
	server.shard_compaction_jobs, _ = chan.create_buffered(chan.Chan(Shard_Compaction_Job), 1, context.allocator)
	defer chan.destroy(server.shard_compaction_jobs)
	queue, _ := spsc.create(Shard_Compaction_Result, 2)
	defer spsc.destroy(queue)
	td.shard_writers.writers = make([dynamic]Shard_Transaction_Writer, 1)
	defer delete(td.shard_writers.writers)
	td.shard_writers.writer_index[0] = 0
	td.message_stores.stores = make([dynamic]Message_Store, 1)
	defer delete(td.message_stores.stores)
	td.message_stores.store_index[0] = 0
	for size in ([2]int{8, 4096}) {
		w := &td.shard_writers.writers[0]
		w.catalog.segments = make([dynamic]Shard_Segment_Descriptor, size, backing)
		w.wal.path_allocator = backing
		w.wal.path, _ = strings.clone("data/shard-000/active-00000001.wal")
		w.shard_dir = "data/shard-000"
		defer {destroy_shard_segment_catalog(&w.catalog); delete(w.wal.path, w.wal.path_allocator)}
		for &segment, i in w.catalog.segments do segment.generation = u64(17 + i * 3)
		s := &td.message_stores.stores[0]
		s.directory = "data/shard-000/messages"
		s.wal.path = "data/shard-000/messages/active-00000001.wal"
		s.segments = make([dynamic]Message_Segment_Descriptor, size, size + 1, worker_heap_allocator(&heap))
		defer delete(s.segments)
		for &segment, i in s.segments do segment.generation = u64(i + 1)
		for message in ([2]bool{false, true}) {
			state := Owner_Bench_State {
				heap    = &heap,
				message = message,
				size    = size,
				w       = w,
				s       = s,
				server  = &server,
				queue   = queue,
			}
			context.user_ptr = &state
			operation := proc() -> u64 {
				using state := cast(^Owner_Bench_State)context.user_ptr
				context.allocator = worker_heap_allocator(heap)
				if message {
					if !enqueue_message_lifecycle(s, .Message_Retain) do return 0
				} else if !enqueue_shard_lifecycle(w, .Shard_Rotate) do return 0
				job, received := chan.try_recv(server.shard_compaction_jobs); if !received do return 0
				context.allocator = job.allocator
				job.lifecycle.ok = true
				if message {
					resize(&job.lifecycle.store.segments, size - 1)
					job.lifecycle.store.total_bytes = 1234567
				} else do job.lifecycle.writer.catalog.segments[0].generation = 23
				if !spsc.try_push(queue, Shard_Compaction_Result{allocator = job.allocator, lifecycle = job.lifecycle, shard = 0}) do return 0
				result, popped := spsc.try_pop(queue); if !popped do return 0
				context.allocator = worker_heap_allocator(heap)
				if !process_shard_compaction_result(result) do return 0
				checksum := w.catalog.segments[0].generation * 31 + w.catalog.segments[size - 1].generation
				if message {
					checksum = s.total_bytes + u64(len(s.segments))
					// Include descriptor-list restoration in this upper-bound cost.
					append(&s.segments, Message_Segment_Descriptor{})
					copy(s.segments[1:], s.segments[:size - 1])
					s.segments[0] = {
						generation = 1,
					}
					s.total_bytes = 0
				} else do w.catalog.segments[0].generation = 17
				return checksum
			}
			expected := message ? u64(1234567 + size - 1) : u64(23 * 31 + 17 + (size - 1) * 3)
			testing.expect_value(t, operation(), expected)
			testing.expect(t, !w.lifecycle_in_flight && !s.lifecycle_in_flight)
			testing.expect(t, !worker_heap_contains_for_test(&heap, raw_data(w.catalog.segments)))
			label := fmt.aprintf("lifecycle message=%v descriptors=%d", message, size); defer delete(label)
			owner_bench_measure(
				label,
				operation,
				expected,
				size * (message ? size_of(Message_Segment_Descriptor) : size_of(Shard_Segment_Descriptor)),
				allocations,
				&tracker,
			)
		}
	}
}

// The production serializer writes fixtures before timing; loading measures only
// range folding, optional dedup filter construction and metadata destruction.
// Index cache is disabled. Validation/checksum/sorting/file I/O are excluded.
@(test)
benchmark_storage_owner_seal_metadata :: proc(t: ^testing.T) {
	if !message_store_benchmark_env_enabled("BENCH_STORAGE_OWNER") do return
	allocations := message_store_benchmark_env_enabled("BENCH_STORAGE_OWNER_ALLOC")
	count := message_store_benchmark_env_int("BENCH_STORAGE_OWNER_RECORDS", 100_000)
	assert(count >= 12 && count <= MESSAGE_MAX_INDEX_RECORDS)
	groups := message_store_benchmark_env_int("BENCH_STORAGE_OWNER_CONVERSATIONS", 4)
	assert(groups >= 4 && groups % 4 == 0 && groups <= count / 3)
	dir := test_wal_path("owner-seal-benchmark"); assert(os.make_directory(dir) == nil)
	defer os.remove_all(dir)
	store := Message_Store {
		directory = dir,
		storage   = storage_io.host_context(),
	}
	records := make([]Message_Index_Record, count); defer delete(records)
	// Unequal populations (weights 1,3,2,2), reusing conversation IDs in
	// two workspaces. Four groups have boundaries at 1/8, 1/2 and 3/4.
	boundaries := make([]int, groups + 1); defer delete(boundaries)
	weights := [4]int{1, 3, 2, 2}
	weight := 0
	for group in 0 ..< groups {
		weight += weights[group % 4]
		boundaries[group + 1] = count * weight / (groups * 2)
		for i in boundaries[group] ..< boundaries[group + 1] {
			records[i] = {
				workspace_hash  = u64(group / (groups / 2) + 1),
				conversation_id = u64(group % (groups / 2) + 1),
				sequence        = u64(i + 1),
				offset          = u64(i * 256),
				length          = 256,
				principal_hash  = u64(i % 17),
				fingerprint     = u64(i + 7),
			}
			message_put_u64(records[i].client_id[:], u64(i + 1))
		}
	}
	segment := Message_Segment_Descriptor {
		generation = 1,
		bytes      = u64(count * 256),
	}
	assert(write_message_segment_index(&store, 1, segment.bytes, records))
	data := read_validated_message_segment_index(&store, segment); assert(data != nil)
	defer delete(data)
	backing := context.allocator
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, 64 * 1024))
	defer tlsf.destroy(&heap)
	for dedup in ([2]bool{false, true}) {
		assert(load_message_segment_index_metadata(&store, &segment, dedup, data))
		testing.expect_value(t, len(segment.conversation_ranges), groups)
		for range, group in segment.conversation_ranges {
			testing.expect_value(t, range.start, u64(boundaries[group]))
			testing.expect_value(t, range.end, u64(boundaries[group + 1]))
			testing.expect_value(t, range.workspace_hash, u64(group / (groups / 2) + 1))
			testing.expect_value(t, range.conversation_id, u64(group % (groups / 2) + 1))
		}
		if dedup {
			expected := make([]u64, (count * MESSAGE_DEDUP_FILTER_BITS_PER_ENTRY + 63) / 64); defer delete(expected)
			for record in records {
				key: [32]byte
				message_put_u64(key[:], record.workspace_hash); message_put_u64(key[8:], record.principal_hash)
				for value, i in record.client_id do key[16 + i] = value
				message_dedup_filter_add(expected, key[:])
			}
			for word, i in expected do testing.expect_value(t, segment.dedup_filter[i], word)
		} else {testing.expect_value(t, len(segment.dedup_filter), 0)}
		destroy_message_segment_metadata(&store, slice.from_ptr(&segment, 1))
		original := context.allocator
		tracker: mem.Tracking_Allocator
		selected := worker_heap_allocator(&heap)
		if allocations do mem.tracking_allocator_init(&tracker, selected, original)
		if allocations do selected = mem.tracking_allocator(&tracker)
		context.allocator = selected
		state := Owner_Bench_State {
			store   = &store,
			segment = &segment,
			dedup   = dedup,
			data    = data,
		}
		context.user_ptr = &state
		operation := proc() -> u64 {
			using state := cast(^Owner_Bench_State)context.user_ptr
			if !load_message_segment_index_metadata(store, segment, dedup, data) do return 0
			checksum :=
				segment.conversation_ranges[len(segment.conversation_ranges) - 1].end + u64(len(segment.conversation_ranges) * 31 + len(segment.dedup_filter))
			destroy_message_segment_metadata(store, slice.from_ptr(segment, 1))
			return checksum
		}
		label := fmt.aprintf("seal records=%d conversations=%d serialized_bytes=%d dedup=%v", count, groups, len(data), dedup)
		owner_bench_measure(
			label,
			operation,
			u64(count + groups * 31 + (dedup ? (count * MESSAGE_DEDUP_FILTER_BITS_PER_ENTRY + 63) / 64 : 0)),
			count * (MESSAGE_INDEX_ENTRY_SIZE + (dedup ? MESSAGE_DEDUP_ENTRY_SIZE : 0)),
			allocations,
			&tracker,
		)
		delete(label)
		context.allocator = original
		if allocations {testing.expect_value(t, tracker.current_memory_allocated, 0); mem.tracking_allocator_destroy(&tracker)}
	}
}

@(test)
test_storage_owner_seal_workspace_boundary :: proc(t: ^testing.T) {
	dir := test_wal_path("owner-seal-workspace-boundary"); assert(os.make_directory(dir) == nil)
	defer os.remove_all(dir)
	store := Message_Store {
		directory = dir,
		storage   = storage_io.host_context(),
	}
	records: [3]Message_Index_Record
	for &record, i in records {
		record = {
			workspace_hash  = i == 0 ? 101 : 202,
			conversation_id = 7,
			sequence        = u64(41 + i),
			offset          = u64(i * 256),
			length          = 256,
			principal_hash  = u64(11 + i),
			fingerprint     = u64(17 + i),
		}
		message_put_u64(record.client_id[:], u64(i + 1))
	}
	segment := Message_Segment_Descriptor {
		generation = 1,
		bytes      = 768,
	}
	assert(write_message_segment_index(&store, 1, 768, records[:]))
	data := read_validated_message_segment_index(&store, segment); assert(data != nil)
	defer delete(data)
	assert(load_message_segment_index_metadata(&store, &segment, true, data))
	defer destroy_message_segment_metadata(&store, slice.from_ptr(&segment, 1))
	// Adjacent equal conversation IDs must not merge across workspaces. The
	// asymmetric 1/2 split also detects inclusive end boundaries and bad offsets.
	testing.expect_value(t, len(segment.conversation_ranges), 2)
	if len(segment.conversation_ranges) == 2 {
		testing.expect_value(t, segment.conversation_ranges[0], Message_Conversation_Range{101, 7, 0, 1})
		testing.expect_value(t, segment.conversation_ranges[1], Message_Conversation_Range{202, 7, 1, 3})
	}
}
