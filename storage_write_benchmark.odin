// Opt-in task and asset shard-WAL write benchmark.
package main

import "core:fmt"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

import "persistence"
import pr "protocol"

Storage_Write_Benchmark_Kind :: enum {
	Task,
	Asset,
}

storage_write_benchmark_kind :: proc() -> (Storage_Write_Benchmark_Kind, bool) {
	value := os.get_env_alloc("NRC_ENTITY_BENCH_KIND", context.allocator)
	defer delete(value)
	switch value {
	case "task":
		return .Task, true
	case "asset":
		return .Asset, true
	}
	return {}, false
}

storage_write_benchmark_external_barrier :: proc(phase: string) -> bool {
	ready_prefix := os.get_env_alloc("NRC_ENTITY_BENCH_READY_PREFIX", context.allocator)
	defer delete(ready_prefix)
	start_prefix := os.get_env_alloc("NRC_ENTITY_BENCH_START_PREFIX", context.allocator)
	defer delete(start_prefix)
	if ready_prefix == "" && start_prefix == "" do return true
	if ready_prefix == "" || start_prefix == "" do return false
	ready_path := fmt.aprintf("%s-%s", ready_prefix, phase)
	defer delete(ready_path)
	start_path := fmt.aprintf("%s-%s", start_prefix, phase)
	defer delete(start_path)
	if os.write_entire_file(ready_path, nil) != nil do return false
	wait_started := time.now()
	for !os.exists(start_path) && time.since(wait_started) < 30 * time.Second do time.sleep(time.Millisecond)
	return os.exists(start_path)
}

@(test)
benchmark_entity_write_throughput :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_ENTITY_WRITE", context.allocator)
	defer delete(enabled)
	if !found || enabled == "0" || enabled == "false" do return
	kind, kind_ok := storage_write_benchmark_kind()
	testing.expect(t, kind_ok)
	if !kind_ok do return

	payload_bytes := message_store_benchmark_env_int("NRC_ENTITY_BENCH_PAYLOAD_BYTES", 1024)
	record_count := message_store_benchmark_env_int("NRC_ENTITY_BENCH_RECORDS", 100_000)
	workspace := "entity-write-throughput"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	path := test_wal_path(kind == .Task ? "task-write-throughput.wal" : "asset-write-throughput.wal")
	_ = os.remove(path)
	testing.expect(t, os.write_entire_file(path, nil) == nil)
	defer os.remove(path)
	payload := make([]byte, payload_bytes)
	defer delete(payload)
	for &value, i in payload do value = byte('a' + i % 26)

	writer: Shard_Transaction_Writer
	testing.expect(t, init_shard_transaction_writer(&writer, path, shard, shard, LOGICAL_SHARD_COUNT))
	if !writer.wal.enabled do return
	if !storage_write_benchmark_external_barrier("write-throughput") {
		testing.expect(t, false, "entity benchmark profiler barrier failed")
		_ = shutdown_shard_transaction_writer(&writer)
		return
	}

	written := 0
	started := time.now()
	for i in 0 ..< record_count {
		ok := false
		switch kind {
		case .Task:
			task := pr.Task {
				id          = pr.TaskID(i + 1),
				conv_id     = 42,
				title       = transmute([]byte)string("benchmark"),
				description = payload,
				status      = .Backlog,
				created_by  = transmute([]byte)string("benchmark"),
				created_at  = i64(i + 1),
				updated_at  = i64(i + 1),
			}
			built, built_ok := build_shard_task_mutation(transmute([]byte)workspace, .Create, &task, writer.floors)
			if built_ok {
				ok = append_shard_transaction(&writer, &built.tx)
				destroy_shard_mutation_transaction(&built)
			}
		case .Asset:
			asset := pr.Asset {
				asset_type       = .Document,
				asset_id         = pr.AssetID(i + 1),
				owner            = transmute([]byte)string("benchmark"),
				created_at       = i64(i + 1),
				updated_at       = i64(i + 1),
				conv_id          = 42,
				payload_encoding = .Plain,
				payload_raw_len  = u32(payload_bytes),
				payload          = payload,
			}
			built, built_ok := build_shard_asset_mutation(transmute([]byte)workspace, .Create, &asset, writer.floors)
			if built_ok {
				ok = append_shard_transaction(&writer, &built.tx)
				destroy_shard_mutation_transaction(&built)
			}
		}
		if !ok do break
		written += 1
		if persistence.wal_fsync_due(&writer.wal) do persistence.force_fsync(&writer.wal)
	}
	elapsed := time.since(started)
	testing.expect_value(t, written, record_count)
	testing.expect_value(t, writer.wal.record_count, u64(record_count))
	wal_bytes := writer.wal.file_size_bytes
	seconds := time.duration_seconds(elapsed)
	label := kind == .Task ? "TASK" : "ASSET"
	log.infof(
		"%s_WRITE_RESULT payload_bytes=%d record_bytes=%d records=%d wal_bytes=%d elapsed_ns=%d messages_per_s=%.3f mib_per_s=%.3f write_calls=%d fsyncs=%d",
		label,
		payload_bytes,
		wal_bytes / u64(record_count),
		record_count,
		wal_bytes,
		time.duration_nanoseconds(elapsed),
		f64(record_count) / seconds,
		f64(wal_bytes) / (1024 * 1024) / seconds,
		writer.wal.write_count,
		writer.wal.fsync_count,
	)
	testing.expect(t, shutdown_shard_transaction_writer(&writer))
}
