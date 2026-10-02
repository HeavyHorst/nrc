// Opt-in stress benchmark for the manifest-driven sharded compactor.
//
// Run with:
//   BENCH_SHARD_COMPACTION=1 odin test . -o:speed \
//     -define:ODIN_TEST_THREADS=1 \
//     -define:ODIN_TEST_NAMES=main.benchmark_shard_compaction_stress
package main

import "base:runtime"
import "core:log"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

import "persistence"
import pr "protocol"
import "storage_io"

SHARD_COMPACTION_BENCH_BASE_UPDATES :: 550_000
SHARD_COMPACTION_BENCH_ACTIVE_UPDATES :: 100_000
SHARD_COMPACTION_BENCH_PAYLOAD_BYTES :: 1024
SHARD_ORDINARY_SWEEP_BENCH_GIB :: 5
SHARD_ORDINARY_SWEEP_BENCH_SEGMENT_MIB :: 500
SHARD_ORDINARY_SWEEP_BENCH_MUTATIONS_PER_RECORD :: 240
SHARD_ORDINARY_SWEEP_BENCH_DESCRIPTION_BYTES :: 60 * 1024

Shard_Compaction_Benchmark_Thread_Data :: struct {
	job:    Shard_Compaction_Job,
	result: ^Shard_Compaction_Result,
	wg:     ^sync.Wait_Group,
	done:   ^u32,
}

shard_compaction_benchmark_env_int :: proc(name: string, fallback: int) -> int {
	value, found := os.lookup_env_alloc(name, context.allocator)
	if !found do return fallback
	defer delete(value)
	parsed, ok := strconv.parse_int(value)
	if !ok || parsed <= 0 do return fallback
	return int(parsed)
}

shard_compaction_benchmark_append_update :: proc(
	writer: ^Shard_Transaction_Writer,
	workspace: string,
	description: []byte,
	updated_at: i64,
	op: Task_Log_Op,
) -> bool {
	task := pr.Task {
		id          = 1,
		conv_id     = 1,
		title       = transmute([]byte)string("shard compaction stress task"),
		description = description,
		status      = .Todo,
		updated_at  = updated_at,
	}
	built, ok := build_shard_task_mutation(transmute([]byte)workspace, op, &task, writer.floors)
	if !ok do return false
	defer destroy_shard_mutation_transaction(&built)
	return append_shard_transaction(writer, &built.tx)
}

shard_compaction_benchmark_thread_entry :: proc(data_raw: rawptr) {
	data := (^Shard_Compaction_Benchmark_Thread_Data)(data_raw)
	defer sync.wait_group_done(data.wg)
	data.result^ = run_shard_compaction_job(data.job)
	sync.atomic_store(data.done, 1)
}

@(test)
benchmark_shard_compaction_stress :: proc(t: ^testing.T) {
	context.allocator = runtime.default_allocator()
	enabled, found := os.lookup_env_alloc("BENCH_SHARD_COMPACTION", context.allocator)
	defer delete(enabled)
	if !found {
		log.info("Skipping sharded compaction stress benchmark (set BENCH_SHARD_COMPACTION=1 to run)")
		return
	}

	base_updates := shard_compaction_benchmark_env_int("NRC_SHARD_BENCH_BASE_UPDATES", SHARD_COMPACTION_BENCH_BASE_UPDATES)
	active_updates := shard_compaction_benchmark_env_int("NRC_SHARD_BENCH_ACTIVE_UPDATES", SHARD_COMPACTION_BENCH_ACTIVE_UPDATES)
	payload_bytes := shard_compaction_benchmark_env_int("NRC_SHARD_BENCH_PAYLOAD_BYTES", SHARD_COMPACTION_BENCH_PAYLOAD_BYTES)
	data_dir := storage_layout_test_setup("shard-compaction-stress-benchmark")
	defer os.remove_all(data_dir)
	generation: u64 = 10
	if !storage_layout_test_create_generation(data_dir, generation) {
		testing.expect(t, false, "failed to create benchmark generation")
		return
	}
	workspace := "shard-compaction-stress-benchmark"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, generation); defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard); defer delete(shard_dir)
	description := make([]byte, payload_bytes); defer delete(description)
	for i in 0 ..< len(description) do description[i] = byte('a' + i % 26)

	writer: Shard_Transaction_Writer
	if !init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT) {
		testing.expect(t, false, "failed to initialize benchmark writer")
		return
	}
	defer shutdown_shard_transaction_writer(&writer)
	if !shard_compaction_benchmark_append_update(&writer, workspace, description, 0, .Create) {
		testing.expect(t, false, "failed to append benchmark seed task")
		return
	}
	// Normalize the seed WAL first so the timed cycle measures dirty cleaning
	// of a cleaned segment plus a newer immutable WAL.
	if !rotate_shard_writer_for_compaction(&writer) {
		testing.expect(t, false, "failed to rotate benchmark seed shard")
		return
	}
	adoption_dir, adoption_clone_err := strings.clone(writer.shard_dir)
	if adoption_clone_err != nil {
		testing.expect(t, false, "failed to clone benchmark adoption directory")
		return
	}
	adoption_job := Shard_Compaction_Job {
		owner_worker          = writer.owner_worker,
		shard                 = writer.shard,
		storage               = writer.storage,
		manifest              = writer.manifest,
		checkpoint_generation = writer.manifest.manifest_generation + 1,
		shard_dir             = adoption_dir,
	}
	writer.compaction = .Building
	writer.compaction_floors = writer.catalog_floors
	adoption := run_shard_compaction_job(adoption_job)
	defer destroy_shard_segment_clean_result(&adoption.segments)
	if !adoption.ok || !adoption.segments.output_present || !publish_shard_compaction_result(&writer, adoption) {
		testing.expect(t, false, "failed to normalize benchmark seed WAL")
		return
	}
	seed_file_bytes, seed_size_err := storage_io.file_size(writer.wal.file)
	testing.expect(t, seed_size_err == nil)
	if seed_size_err != nil do return
	seed_bytes := u64(seed_file_bytes)

	log.infof("=== Sharded Compaction Stress: base_updates=%d active_updates=%d payload=%d bytes ===", base_updates, active_updates, payload_bytes)
	base_written := 0
	base_started := time.now()
	for i in 0 ..< base_updates {
		if !shard_compaction_benchmark_append_update(&writer, workspace, description, i64(i + 1), .Update) {
			break
		}
		base_written += 1
	}
	base_elapsed := time.since(base_started)
	testing.expect_value(t, base_written, base_updates)
	if base_written != base_updates do return
	sealed_records := writer.wal.record_count
	sealed_file_bytes, sealed_size_err := storage_io.file_size(writer.wal.file)
	testing.expect(t, sealed_size_err == nil)
	if sealed_size_err != nil do return
	sealed_bytes := u64(sealed_file_bytes)
	timed_base_bytes := sealed_bytes - seed_bytes
	if !rotate_shard_writer_for_compaction(&writer) {
		testing.expect(t, false, "failed to rotate benchmark shard")
		return
	}

	job_dir, clone_err := strings.clone(writer.shard_dir)
	if clone_err != nil {
		testing.expect(t, false, "failed to clone benchmark shard directory")
		return
	}
	job := Shard_Compaction_Job {
		owner_worker          = writer.owner_worker,
		shard                 = writer.shard,
		storage               = writer.storage,
		manifest              = writer.manifest,
		checkpoint_generation = writer.manifest.manifest_generation + 1,
		shard_dir             = job_dir,
	}
	writer.compaction = .Building
	writer.compaction_floors = writer.catalog_floors
	result: Shard_Compaction_Result
	defer destroy_shard_segment_clean_result(&result.segments)
	compaction_done: u32
	wg: sync.Wait_Group
	thread_data := Shard_Compaction_Benchmark_Thread_Data {
		job    = job,
		result = &result,
		wg     = &wg,
		done   = &compaction_done,
	}
	sync.wait_group_add(&wg, 1)
	compaction_started := time.now()
	compactor := thread.create_and_start_with_data(&thread_data, shard_compaction_benchmark_thread_entry, context)
	if compactor == nil {
		sync.wait_group_done(&wg)
		delete(job_dir)
		testing.expect(t, false, "failed to start benchmark compactor thread")
		return
	}

	active_started := time.now()
	active_written := 0
	overlapped_cleaning := false
	for i in 0 ..< active_updates {
		if sync.atomic_load(&compaction_done) == 0 do overlapped_cleaning = true
		updated_at := i64(base_updates + i + 1)
		if !shard_compaction_benchmark_append_update(&writer, workspace, description, updated_at, .Update) {
			break
		}
		active_written += 1
	}
	active_elapsed := time.since(active_started)
	testing.expect_value(t, active_written, active_updates)
	sync.wait(&wg)
	compaction_elapsed := time.since(compaction_started)
	thread.destroy(compactor)
	if !result.ok || !publish_shard_compaction_result(&writer, result) {
		testing.expect(t, false, "background segment cleaning or publication failed")
		return
	}

	catalog, catalog_ok := load_shard_segment_catalog(writer.storage, writer.shard_dir, writer.manifest.checkpoint_generation)
	defer destroy_shard_segment_catalog(&catalog)
	cleaned_bytes: i64
	if catalog_ok && len(catalog.segments) == 1 && catalog.segments[0].kind == .Cleaned_Segment {
		cleaned_path := shard_segment_descriptor_path(writer.shard_dir, catalog.segments[0])
		cleaned_file, cleaned_open_err := os.open(cleaned_path)
		if cleaned_open_err == nil {
			cleaned_bytes, _ = os.file_size(cleaned_file)
			os.close(cleaned_file)
		}
		delete(cleaned_path)
	}
	testing.expect(t, cleaned_bytes > 0, "published benchmark catalog should reference one cleaned segment")
	active_bytes := persistence.get_file_size(&writer.wal)
	shutdown_shard_transaction_writer(&writer)

	manifest, manifest_found, manifest_ok := load_shard_compaction_manifest(shard_dir)
	testing.expect(t, manifest_found && manifest_ok, "published benchmark manifest should load")
	shard_replay_state_init()
	floors, replay_ok := replay_shard_compaction_sequence(shard_dir, manifest, true, false)
	final_task := get_task(workspace, 1, 1)
	expected_updated_at := i64(base_updates + active_written)
	testing.expect(t, replay_ok, "published benchmark sequence should replay")
	testing.expect_value(t, floors.task, u64(1))
	testing.expect(t, final_task != nil, "benchmark task should survive compaction")
	if final_task != nil do testing.expect_value(t, final_task.updated_at, expected_updated_at)
	shard_replay_state_destroy()

	base_seconds := time.duration_seconds(base_elapsed)
	active_seconds := time.duration_seconds(active_elapsed)
	compaction_seconds := time.duration_seconds(compaction_elapsed)
	reduction := cleaned_bytes > 0 ? f64(sealed_bytes) / f64(cleaned_bytes) : 0
	log.infof(
		"Base WAL: %d records, %.2f MiB, %.0f records/s, %.2f MiB/s",
		sealed_records,
		f64(sealed_bytes) / (1024 * 1024),
		f64(base_updates) / base_seconds,
		f64(timed_base_bytes) / (1024 * 1024) / base_seconds,
	)
	log.infof(
		"Background segment cleaning: %.2f MiB in %.3fs, reduction %.1fx; active WAL %.2f MiB",
		f64(cleaned_bytes) / (1024 * 1024),
		compaction_seconds,
		reduction,
		f64(active_bytes) / (1024 * 1024),
	)
	log.infof(
		"Concurrent active writes: %d in %.3fs (%.0f records/s); overlapped cleaning=%v",
		active_written,
		active_seconds,
		f64(active_written) / active_seconds,
		overlapped_cleaning,
	)
}

shard_ordinary_sweep_benchmark_append_record :: proc(
	builder: ^persistence.WAL_File_Builder,
	metadata_builder: ^Shard_Segment_Metadata_Build_Context,
	workspace: []byte,
	description: []byte,
	task_id: u64,
) -> bool {
	task := pr.Task {
		id          = pr.TaskID(task_id),
		conv_id     = 1,
		title       = transmute([]byte)string("ordinary sweep benchmark"),
		description = description,
		status      = .Todo,
		updated_at  = i64(task_id),
	}
	built, built_ok := build_shard_task_mutation(workspace, .Create, &task, {task = task_id - 1})
	if !built_ok do return false
	defer destroy_shard_mutation_transaction(&built)
	mutations := make([]Shard_Mutation, SHARD_ORDINARY_SWEEP_BENCH_MUTATIONS_PER_RECORD)
	defer delete(mutations)
	for &mutation, index in mutations {
		mutation = built.tx.mutations[0]
		if index > 0 do mutation.op = u8(Task_Log_Op.Update)
	}
	tx := Shard_Transaction {
		workspace       = workspace,
		task_high_water = task_id,
		mutations       = mutations,
	}
	payload_size, size_err := shard_transaction_size(&tx)
	if size_err != .None do return false
	record := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(record)
	if encode_shard_transaction(&tx, record[persistence.LOG_HEADER_SIZE:]) != .None do return false
	if !persistence.append_wal_file_builder(builder, u8(Shard_Log_Op.Transaction), record) do return false
	view, decode_err := decode_shard_transaction(record[persistence.LOG_HEADER_SIZE:])
	return decode_err == .None && collect_shard_segment_metadata_record(metadata_builder, &view, u64(len(record)))
}

shard_ordinary_sweep_benchmark_fixture :: proc(
	shard_dir: string,
	target_bytes: u64,
	segment_bytes: u64,
) -> (
	source: Shard_Segment_Clean_Source,
	actual_bytes: u64,
	ok: bool,
) {
	workspace_name := "ordinary-sweep-scaling-benchmark"
	workspace := transmute([]byte)workspace_name
	source.shard = int(shard_for_workspace(workspace))
	source.segments = make([dynamic]Shard_Segment_Descriptor)
	defer if !ok do destroy_shard_segment_clean_source(&source)
	description := make([]byte, SHARD_ORDINARY_SWEEP_BENCH_DESCRIPTION_BYTES)
	defer delete(description)
	for index in 0 ..< len(description) do description[index] = byte('a' + index % 26)

	generation: u64 = 1
	task_id: u64 = 1
	floors: Shard_High_Water_Requirements
	for actual_bytes < target_bytes {
		path := shard_generation_wal_path(shard_dir, generation)
		builder: persistence.WAL_File_Builder
		if !persistence.create_wal_file_builder(&builder, storage_io.host_context(), path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION) {
			delete(path)
			return
		}
		delete(path)
		metadata_builder: Shard_Segment_Metadata_Build_Context
		if !init_shard_segment_metadata_builder(&metadata_builder, source.shard, floors) {
			persistence.abort_wal_file_builder(&builder)
			return
		}
		for builder.file_size < segment_bytes && actual_bytes + builder.file_size < target_bytes {
			if !shard_ordinary_sweep_benchmark_append_record(&builder, &metadata_builder, workspace, description, task_id) {
				persistence.abort_wal_file_builder(&builder)
				destroy_shard_segment_metadata_builder(&metadata_builder)
				return
			}
			task_id += 1
		}
		segment_size := builder.file_size
		if !persistence.finish_wal_file_builder(&builder) {
			destroy_shard_segment_metadata_builder(&metadata_builder)
			return
		}
		descriptor := Shard_Segment_Descriptor{.Adopted_Generation_WAL, generation}
		metadata, metadata_ok := finalize_shard_segment_metadata_builder(&metadata_builder, descriptor, segment_size)
		destroy_shard_segment_metadata_builder(&metadata_builder)
		if !metadata_ok do return
		floors = metadata.end
		_, metadata_written := write_shard_segment_metadata(storage_io.host_context(), shard_dir, &metadata)
		destroy_shard_segment_metadata(&metadata)
		if !metadata_written do return
		if _, append_err := append(&source.segments, descriptor); append_err != nil do return
		actual_bytes += segment_size
		generation += 1
	}
	return source, actual_bytes, true
}

@(test)
benchmark_shard_ordinary_sweep_scaling :: proc(t: ^testing.T) {
	context.allocator = runtime.default_allocator()
	enabled, found := os.lookup_env_alloc("BENCH_SHARD_ORDINARY_SWEEP", context.allocator)
	defer delete(enabled)
	if !found {
		log.info("Skipping ordinary sweep scaling benchmark (set BENCH_SHARD_ORDINARY_SWEEP=1 to run)")
		return
	}
	target_gib := shard_compaction_benchmark_env_int("NRC_SHARD_ORDINARY_SWEEP_GIB", SHARD_ORDINARY_SWEEP_BENCH_GIB)
	segment_mib := shard_compaction_benchmark_env_int("NRC_SHARD_ORDINARY_SWEEP_SEGMENT_MIB", SHARD_ORDINARY_SWEEP_BENCH_SEGMENT_MIB)
	data_dir := storage_layout_test_setup("shard-ordinary-sweep-scaling-benchmark")
	defer os.remove_all(data_dir)
	shard_dir := storage_layout_path(data_dir, "shard")
	defer delete(shard_dir)
	testing.expect(t, os.make_directory(shard_dir) == nil)
	target_bytes := u64(target_gib) * 1024 * 1024 * 1024
	segment_bytes := u64(segment_mib) * 1024 * 1024

	fixture_started := time.now()
	source, actual_bytes, fixture_ok := shard_ordinary_sweep_benchmark_fixture(shard_dir, target_bytes, segment_bytes)
	defer destroy_shard_segment_clean_source(&source)
	testing.expect(t, fixture_ok)
	if !fixture_ok do return
	fixture_elapsed := time.since(fixture_started)
	metadata_floors: Shard_High_Water_Requirements
	for descriptor in source.segments {
		segment_size, size_ok := shard_segment_descriptor_size(storage_io.host_context(), shard_dir, descriptor)
		testing.expect(t, size_ok)
		if !size_ok do return
		summary, _, summary_ok := load_shard_segment_metadata_summary(
			storage_io.host_context(),
			shard_dir,
			source.shard,
			descriptor,
			segment_size,
			&metadata_floors,
		)
		testing.expect(t, summary_ok, "benchmark fixture metadata floor chain must be complete")
		if !summary_ok do return
		metadata_floors = summary.end
		destroy_shard_segment_metadata_summary(&summary)
	}
	manifest := Shard_Compaction_Manifest {
		shard     = source.shard,
		segmented = true,
	}
	cursor := 0
	generation: u64 = u64(len(source.segments)) + 1
	groups := 0
	prefix_bytes, latest_bytes, measure_bytes, copy_bytes, replay_bytes: u64
	sweep_started := time.now()
	for cursor < len(source.segments) {
		result := build_shard_segment_catalog(storage_io.host_context(), shard_dir, manifest, generation, &source, cursor)
		testing.expect(t, result.ok && !result.output_present && result.next_cursor > cursor)
		if !result.ok || result.output_present || result.next_cursor <= cursor {
			destroy_shard_segment_clean_result(&result)
			return
		}
		prefix_bytes += result.prefix_read_bytes
		latest_bytes += result.latest_read_bytes
		measure_bytes += result.measure_read_bytes
		copy_bytes += result.copy_read_bytes
		replay_bytes += result.replay_read_bytes
		cursor = result.next_cursor
		generation += 1
		groups += 1
		destroy_shard_segment_clean_result(&result)
	}
	sweep_elapsed := time.since(sweep_started)
	total_read_bytes := prefix_bytes + latest_bytes + measure_bytes + copy_bytes + replay_bytes
	log.infof(
		"Ordinary sweep scaling: data=%.2f GiB segments=%d groups=%d fixture=%.3fs sweep=%.3fs logical_reads=%.2f GiB amplification=%.2fx prefix=%.2f latest=%.2f measure=%.2f copy=%.2f replay=%.2f GiB",
		f64(actual_bytes) / f64(1024 * 1024 * 1024),
		len(source.segments),
		groups,
		time.duration_seconds(fixture_elapsed),
		time.duration_seconds(sweep_elapsed),
		f64(total_read_bytes) / f64(1024 * 1024 * 1024),
		f64(total_read_bytes) / f64(actual_bytes),
		f64(prefix_bytes) / f64(1024 * 1024 * 1024),
		f64(latest_bytes) / f64(1024 * 1024 * 1024),
		f64(measure_bytes) / f64(1024 * 1024 * 1024),
		f64(copy_bytes) / f64(1024 * 1024 * 1024),
		f64(replay_bytes) / f64(1024 * 1024 * 1024),
	)
}
