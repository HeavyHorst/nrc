// Opt-in full production persistence startup, with balanced, fixed-size shard data.
package main

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import mem_tlsf "vendor/tlsf"

import "persistence"
import pr "protocol"
import "ulid"

Replay_Bench_Worker :: struct {
	dir, kind:                                string,
	index, workers, per_shard, payload_bytes: int,
	cpu:                                      int,
	ready, done:                              ^sync.Wait_Group,
	start, release:                           ^u32,
	ok:                                       bool,
	entities:                                 int,
	tlsf_bytes:                               int,
	worker_heap:                              bool,
	clock_setup:                              time.Duration,
}

replay_bench_worker :: proc(raw: rawptr) {
	d := cast(^Replay_Bench_Worker)raw
	assert(set_thread_cpu_affinity(d.cpu))
	// Heap setup and initial page touching precede the replay gate. Production
	// pool growth remains timed; the historical fixed-budget mode has no growth.
	// Keep the allocator alive through verification and all individual frees.
	heap := context.allocator
	backing: []byte
	control: mem_tlsf.Allocator
	selected := heap
	if d.worker_heap {
		assert(worker_heap_init(&control, &heap))
		selected = worker_heap_allocator(&control)
	} else if d.tlsf_bytes > 0 {
		backing = make([]byte, d.tlsf_bytes, heap)
		for i := 0; i < len(backing); i += 4096 do backing[i] = 1
		assert(mem_tlsf.init(&control, backing) == .None)
		selected = mem_tlsf.allocator(&control)
	}
	// Odin context assignments are lexical: switch in the replay's own scope.
	td.backing_allocator = heap
	context.allocator = selected
	defer {
		context.allocator = heap
		mem_tlsf.destroy(&control)
		delete(backing, heap)
	}
	shard_replay_state_init()
	// The clock is thread-local. Match production worker initialization rather
	// than timing its potentially two-second TSC calibration as WAL replay.
	clock_watch: time.Stopwatch
	time.stopwatch_start(&clock_watch)
	ulid.init()
	d.clock_setup = time.stopwatch_duration(clock_watch)
	sync.wait_group_done(d.ready)
	for sync.atomic_load(d.start) == 0 do time.sleep(100 * time.Microsecond)
	d.ok = init_active_sharded_worker_persistence(d.dir, FRESH_STORAGE_LAYOUT_GENERATION, d.index, d.workers)
	sync.wait_group_done(d.done)
	// Validation and destruction are deliberately outside the timed interval.
	for sync.atomic_load(d.release) == 0 do time.sleep(100 * time.Microsecond)
	for workspace, ws in td.workspaces {
		shard := int(shard_for_workspace(transmute([]byte)workspace))
		d.ok = d.ok && shard % d.workers == d.index && len(ws.conversations) == 1
		for _, conv in ws.conversations {
			tasks := d.kind == "asset" ? 0 : (d.kind == "mixed" ? d.per_shard / 2 : d.per_shard)
			d.ok = d.ok && len(conv.tasks) == tasks && len(conv.assets) == d.per_shard - tasks
			for id, task in conv.tasks {
				d.ok =
					d.ok &&
					int(id) >= 1 &&
					int(id) <= d.per_shard &&
					task.conv_id == pr.WORKSPACE_DATA_ID &&
					task.status == .Todo &&
					len(task.description) == d.payload_bytes &&
					task.updated_at == i64(id)
				if len(backing) > 0 {
					d.ok = d.ok && uintptr(task) >= uintptr(raw_data(backing)) && uintptr(task) < uintptr(raw_data(backing)) + uintptr(len(backing))
				}
				for value, i in task.description do d.ok = d.ok && value == byte('a' + i % 26)
				d.entities += 1
			}
			for id, asset in conv.assets {
				d.ok =
					d.ok &&
					int(id) >= 1 &&
					int(id) <= d.per_shard &&
					asset.conv_id == pr.WORKSPACE_DATA_ID &&
					asset.asset_type == .Document &&
					len(asset.payload) == d.payload_bytes &&
					asset.updated_at == i64(id)
				if len(backing) > 0 {
					d.ok = d.ok && uintptr(asset) >= uintptr(raw_data(backing)) && uintptr(asset) < uintptr(raw_data(backing)) + uintptr(len(backing))
				}
				for value, i in asset.payload do d.ok = d.ok && value == byte('a' + i % 26)
				d.entities += 1
			}
		}
	}
	d.ok = shutdown_shard_writer_registry(&td.shard_writers) && d.ok
	shard_replay_state_destroy()
}

replay_bench_fixture :: proc(dir, kind: string, per_shard, payload_bytes: int) -> (total_bytes: u64) {
	assert(os.make_directory(dir) == nil)
	assert(bootstrap_sharded_storage_layout(dir))
	generation := sharded_generation_path(dir, FRESH_STORAGE_LAYOUT_GENERATION)
	defer delete(generation)
	payload := make([]byte, payload_bytes)
	defer delete(payload)
	for &value, i in payload do value = byte('a' + i % 26)
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		workspace: string
		for candidate in 0 ..< 100_000 {
			workspace = fmt.aprintf("replay-%03d-%06d", shard, candidate)
			if int(shard_for_workspace(transmute([]byte)workspace)) == shard do break
			delete(workspace)
			workspace = ""
		}
		assert(workspace != "")
		path := sharded_active_wal_path(generation, shard)
		assert(os.remove(path) == nil)
		builder: persistence.WAL_File_Builder
		assert(persistence.create_wal_file_builder(&builder, path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION))
		floors: Shard_High_Water_Requirements
		for i in 0 ..< per_shard {
			id := i + 1
			built: Shard_Mutation_Transaction
			ok: bool
			if kind == "task" || (kind == "mixed" && i % 2 == 0) {
				task := pr.Task {
					id          = pr.TaskID(id),
					conv_id     = pr.WORKSPACE_DATA_ID,
					title       = transmute([]byte)string("replay benchmark"),
					description = payload,
					status      = .Todo,
					updated_at  = i64(id),
				}
				built, ok = build_shard_task_mutation(transmute([]byte)workspace, .Create, &task, floors)
			} else {
				asset := pr.Asset {
					asset_type       = .Document,
					asset_id         = pr.AssetID(id),
					conv_id          = pr.WORKSPACE_DATA_ID,
					owner            = transmute([]byte)string("benchmark"),
					payload_encoding = .Plain,
					payload_raw_len  = u32(payload_bytes),
					payload          = payload,
					updated_at       = i64(id),
				}
				built, ok = build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, floors)
			}
			assert(ok)
			size, err := shard_transaction_size(&built.tx)
			assert(err == .None)
			record := make([]byte, persistence.LOG_HEADER_SIZE + size)
			assert(encode_shard_transaction(&built.tx, record[persistence.LOG_HEADER_SIZE:]) == .None)
			assert(persistence.append_wal_file_builder(&builder, u8(Shard_Log_Op.Transaction), record))
			floors = {
				task  = built.tx.task_high_water,
				asset = built.tx.asset_high_water,
				edge  = built.tx.edge_high_water,
			}
			delete(record)
			destroy_shard_mutation_transaction(&built)
		}
		total_bytes += builder.file_size
		assert(persistence.finish_wal_file_builder(&builder))
		delete(path)
		delete(workspace)
	}
	return
}

// perf's FIFO acknowledgement keeps setup, validation and teardown out of profiles.
replay_bench_perf_control :: proc(path: string, ack: ^os.File, command: string) {
	if path == "" do return
	assert(os.write_entire_file(path, transmute([]byte)command) == nil)
	// perf includes the C-string terminator in each acknowledgement.
	response: [5]byte
	filled := 0
	for filled < len(response) {
		n, err := os.read(ack, response[filled:])
		assert(err == nil && n > 0)
		filled += n
	}
	assert(string(response[:]) == "ack\n\x00")
}

@(test)
benchmark_wal_replay :: proc(t: ^testing.T) {
	dir := os.get_env_alloc("NRC_REPLAY_BENCH_DIR", context.allocator)
	defer delete(dir)
	if dir == "" do return
	kind := os.get_env_alloc("NRC_REPLAY_BENCH_KIND", context.allocator)
	defer delete(kind)
	assert(kind == "task" || kind == "asset" || kind == "mixed")
	per_shard := message_store_benchmark_env_int("NRC_REPLAY_BENCH_PER_SHARD", 2048)
	payload_bytes := message_store_benchmark_env_int("NRC_REPLAY_BENCH_PAYLOAD_BYTES", 1024)
	assert(per_shard > 0 && per_shard % 2 == 0 && payload_bytes > 0)
	mode := os.get_env_alloc("NRC_REPLAY_BENCH_MODE", context.allocator)
	defer delete(mode)
	if mode == "generate" {
		bytes := replay_bench_fixture(dir, kind, per_shard, payload_bytes)
		fmt.printf("REPLAY_FIXTURE kind=%s records=%d bytes=%d\n", kind, per_shard * LOGICAL_SHARD_COUNT, bytes)
		return
	}
	perf_control := os.get_env_alloc("NRC_REPLAY_BENCH_PERF_CONTROL", context.allocator)
	defer delete(perf_control)
	perf_ack_path := os.get_env_alloc("NRC_REPLAY_BENCH_PERF_ACK", context.allocator)
	defer delete(perf_ack_path)
	perf_ack: ^os.File
	if perf_control != "" {
		ack, err := os.open(perf_ack_path, {.Read})
		assert(err == nil)
		perf_ack = ack
	}
	defer if perf_ack != nil do os.close(perf_ack)
	workers := message_store_benchmark_env_int("NRC_REPLAY_BENCH_WORKERS", 1)
	assert(workers >= 1 && workers <= 16)
	allocator_kind := os.get_env_alloc("NRC_REPLAY_BENCH_ALLOCATOR", context.allocator)
	defer delete(allocator_kind)
	assert(allocator_kind == "" || allocator_kind == "worker" || allocator_kind == "heap" || allocator_kind == "tlsf")
	// Fixed total budget, partitioned by shard ownership. No timed pool growth.
	tlsf_bytes := 0
	if allocator_kind == "tlsf" {
		tlsf_bytes = ((LOGICAL_SHARD_COUNT + workers - 1) / workers) * (per_shard * (payload_bytes + 2048) + 1024 * 1024)
	}
	topology := detect_cpu_topology()
	assert(topology.complete && topology.entry_count >= workers)
	cpus: [1024]int
	cpu_count := 0
	passes := [2]bool{true, false}
	for primary in passes {
		for entry, i in topology.entries[:topology.entry_count] {
			if cpu_topology_is_primary_thread(topology.entries[:topology.entry_count], i) != primary do continue
			cpus[cpu_count] = entry.cpu
			cpu_count += 1
		}
	}
	data := make([]Replay_Bench_Worker, workers)
	defer delete(data)
	threads := make([]^thread.Thread, workers)
	defer delete(threads)
	ready, done: sync.Wait_Group
	start, release: u32
	sync.wait_group_add(&ready, workers)
	sync.wait_group_add(&done, workers)
	setup_watch: time.Stopwatch
	time.stopwatch_start(&setup_watch)
	for &d, index in data {
		d = {
			dir           = dir,
			kind          = kind,
			index         = index,
			workers       = workers,
			per_shard     = per_shard,
			payload_bytes = payload_bytes,
			tlsf_bytes    = tlsf_bytes,
			worker_heap   = allocator_kind == "" || allocator_kind == "worker",
			cpu           = cpus[index],
			ready         = &ready,
			done          = &done,
			start         = &start,
			release       = &release,
		}
		// Default per-thread context: the test runner's allocator is not shared.
		threads[index] = thread.create_and_start_with_data(&d, replay_bench_worker)
		assert(threads[index] != nil)
	}
	sync.wait_group_wait(&ready)
	setup_elapsed := time.stopwatch_duration(setup_watch)
	clock_max: time.Duration
	for d in data do clock_max = max(clock_max, d.clock_setup)
	fmt.printf(
		"REPLAY_SETUP kind=%s workers=%d seconds=%.9f clock_max_seconds=%.9f\n",
		kind,
		workers,
		time.duration_seconds(setup_elapsed),
		time.duration_seconds(clock_max),
	)
	replay_bench_perf_control(perf_control, perf_ack, "enable\n")
	watch: time.Stopwatch
	time.stopwatch_start(&watch)
	sync.atomic_store(&start, 1)
	sync.wait_group_wait(&done)
	elapsed := time.stopwatch_duration(watch)
	replay_bench_perf_control(perf_control, perf_ack, "disable\n")
	sync.atomic_store(&release, 1)
	entities := 0
	for th, index in threads {
		thread.join(th)
		thread.destroy(th)
		testing.expect(t, data[index].ok, "production replay and full payload verification")
		entities += data[index].entities
	}
	testing.expect_value(t, entities, per_shard * LOGICAL_SHARD_COUNT)
	fmt.printf(
		"REPLAY_RESULT kind=%s workers=%d records=%d seconds=%.9f records_per_second=%.3f\n",
		kind,
		workers,
		entities,
		time.duration_seconds(elapsed),
		f64(entities) / time.duration_seconds(elapsed),
	)
}

@(test)
test_replay_tlsf_reuses_variable_size_entity_storage :: proc(t: ^testing.T) {
	heap := context.allocator
	backing := make([]byte, 256 * 1024, heap)
	control: mem_tlsf.Allocator
	assert(mem_tlsf.init(&control, backing) == .None)
	context.allocator = mem_tlsf.allocator(&control)
	defer {
		context.allocator = heap
		mem_tlsf.destroy(&control)
		delete(backing, heap)
	}
	shard_replay_state_init()
	defer shard_replay_state_destroy()
	workspace := "tlsf-churn"
	ws := get_or_create_workspace(workspace)
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	payload: [1536]byte
	// Cumulative allocations exceed the backing many times. A bump allocator
	// or mismatched free would exhaust it; live old/new post-images must coexist.
	for i in 0 ..< 1000 {
		n := i % 2 == 0 ? 513 : len(payload)
		for &value, j in payload do value = byte((i + j) % 251)
		task := alloc_task(transmute([]byte)string("task"), payload[:n], nil, nil, nil, nil, nil, nil)
		asset := alloc_asset(nil, nil, payload[:n])
		assert(task != nil && asset != nil)
		task.id = 1
		task.status = .Todo
		asset.asset_id = 2
		asset.asset_type = .Document
		task_store_put(conv, task)
		asset_store_put(ws, workspace, conv, asset)
		// Stored bytes must belong to the entity block, not borrow the input.
		for &value in payload do value = 255
		testing.expect_value(t, len(conv.tasks[1].description), n)
		testing.expect_value(t, len(conv.assets[2].payload), n)
		for j in 0 ..< n {
			testing.expect_value(t, conv.tasks[1].description[j], byte((i + j) % 251))
			testing.expect_value(t, conv.assets[2].payload[j], byte((i + j) % 251))
		}
		if i % 3 == 0 {
			task_store_remove(conv, 1)
			asset_store_remove(ws, conv, 2)
			testing.expect_value(t, len(conv.tasks), 0)
			testing.expect_value(t, len(conv.assets), 0)
		}
	}
}
