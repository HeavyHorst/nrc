package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:testing"
import "core:time"
import pr "protocol"
import sql "sqlite"
import db "workspace_db"

storage_layout_test_dir :: proc(name: string) -> string {
	mode := "prod"
	when NRC_SIMULATION do mode = "sim"
	return fmt.tprintf("/tmp/nrc-layout-%s-pid%d-%s", mode, os.get_pid(), name)
}

storage_layout_test_setup :: proc(name: string) -> string {
	dir := storage_layout_test_dir(name)
	_ = os.remove_all(dir)
	_ = os.make_directory(dir)
	return dir
}

storage_layout_test_manifest :: proc(generation: u64) -> Storage_Layout_Manifest {
	return {
		generation = generation,
		mode = .Sharded_V1,
		workspace_hash = .XXH64_Seed_0_Raw,
		logical_shard_count = LOGICAL_SHARD_COUNT,
		shard_wal_version = SHARD_WAL_VERSION,
	}
}

storage_layout_test_write_manifest :: proc(dir: string, manifest: Storage_Layout_Manifest) -> bool {
	data: [STORAGE_LAYOUT_MANIFEST_SIZE]byte
	if !encode_storage_layout_manifest(manifest, data[:]) do return false
	path := storage_layout_path(dir, STORAGE_LAYOUT_MANIFEST_NAME)
	defer delete(path)
	return os.write_entire_file(path, data[:]) == nil
}

storage_layout_test_create_generation :: proc(dir: string, generation: u64) -> bool {
	generation_dir := sharded_generation_path(dir, generation)
	defer delete(generation_dir)
	if os.make_directory(generation_dir) != nil do return false
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		shard_dir := sharded_shard_path(generation_dir, shard)
		if os.make_directory(shard_dir) != nil {
			delete(shard_dir)
			return false
		}
		active_path := sharded_active_wal_path(generation_dir, shard)
		write_ok := os.write_entire_file(active_path, nil) == nil
		delete(active_path)
		delete(shard_dir)
		if !write_ok do return false
	}
	return true
}

@(test)
test_storage_layout_manifest_roundtrip_preserves_generation_two_wire_format :: proc(t: ^testing.T) {
	manifest := storage_layout_test_manifest(2)
	data: [STORAGE_LAYOUT_MANIFEST_SIZE]byte
	testing.expect(t, encode_storage_layout_manifest(manifest, data[:]))
	decoded, ok := decode_storage_layout_manifest(data[:])
	testing.expect(t, ok)
	testing.expect_value(t, decoded, manifest)
	testing.expect_value(t, data[16], u8(Storage_Layout_Mode.Sharded_V1))
	legacy_worker_count, _ := endian.get_u32(data[20:], .Big)
	testing.expect_value(t, legacy_worker_count, u32(0))
}

@(test)
test_storage_layout_manifest_rejects_legacy_mode_and_legacy_worker_count :: proc(t: ^testing.T) {
	data: [STORAGE_LAYOUT_MANIFEST_SIZE]byte
	testing.expect(t, encode_storage_layout_manifest(storage_layout_test_manifest(2), data[:]))

	data[16] = 1
	endian.put_u64(data[32:], .Big, xxhash.XXH64(data[:32]))
	_, legacy_mode_ok := decode_storage_layout_manifest(data[:])
	testing.expect(t, !legacy_mode_ok)

	testing.expect(t, encode_storage_layout_manifest(storage_layout_test_manifest(2), data[:]))
	endian.put_u32(data[20:], .Big, 1)
	endian.put_u64(data[32:], .Big, xxhash.XXH64(data[:32]))
	_, legacy_count_ok := decode_storage_layout_manifest(data[:])
	testing.expect(t, !legacy_count_ok)
}

@(test)
test_sqlite_storage_layout_gate_bootstraps_cold_directory :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("cold-bootstrap")
	defer os.remove_all(dir)

	lock, ok := sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, ok)
	if !ok do return
	release_data_directory_lock(&lock)

	m, found, valid := load_storage_layout_manifest(dir)
	testing.expect(t, found)
	testing.expect(t, valid)
	testing.expect_value(t, m.generation, FRESH_STORAGE_LAYOUT_GENERATION)
	testing.expect_value(t, m.mode, Storage_Layout_Mode.SQLite_V1)
}

@(test)
test_sqlite_storage_layout_gate_refuses_legacy_data_without_manifest :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("legacy-refusal")
	defer os.remove_all(dir)

	legacy := storage_layout_path(dir, "tasks_thread_0.log")
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(legacy, nil) == nil)

	_, ok := sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, !ok)
}

@(test)
test_sqlite_storage_layout_gate_requires_valid_generation_after_manifest :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("startup-requirements")
	defer os.remove_all(dir)

	manifest := storage_layout_test_manifest(2)
	manifest.mode = .SQLite_V1
	testing.expect(t, storage_layout_test_write_manifest(dir, manifest))
	_, missing_generation_ok := sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, !missing_generation_ok)

	testing.expect(t, storage_layout_test_create_generation(dir, 2))
	lock, ok := sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, !ok, "workspace WAL files must not substitute for SQLite databases")
	if ok do release_data_directory_lock(&lock)
}

@(test)
test_sqlite_storage_layout_gate_accepts_worker_count_changes_and_non_divisors :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("worker-resize")
	defer os.remove_all(dir)
	for worker_count in ([?]int{1, 3, 7, 16, 255, 256}) {
		lock, ok := sqlite_storage_layout_gate(dir, worker_count)
		testing.expectf(t, ok, "SQLite startup should accept worker_count=%d", worker_count)
		if ok do release_data_directory_lock(&lock)
	}
	_, zero_ok := sqlite_storage_layout_gate(dir, 0)
	testing.expect(t, !zero_ok)
	_, excessive_ok := sqlite_storage_layout_gate(dir, MAX_SERVER_WORKER_COUNT + 1)
	testing.expect(t, !excessive_ok)
}

@(test)
test_sqlite_storage_layout_gate_rejects_incomplete_generation :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("incomplete-generation")
	defer os.remove_all(dir)
	lock, started := sqlite_storage_layout_gate(dir, 4)
	if !testing.expect(t, started) do return
	release_data_directory_lock(&lock)
	missing := sqlite_shard_path(dir, FRESH_STORAGE_LAYOUT_GENERATION, 73)
	defer delete(missing)
	testing.expect(t, os.remove(missing) == nil)
	_, ok := sqlite_storage_layout_gate(dir, 4)
	testing.expect(t, !ok)
}

@(test)
test_sqlite_startup_layout_and_executor_routing :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("sqlite-startup")
	defer os.remove_all(dir)
	lock, ok := sqlite_storage_layout_gate(dir, 5)
	if !testing.expect(t, ok) do return
	defer release_data_directory_lock(&lock)
	_, competing := sqlite_storage_layout_gate(dir, 1)
	testing.expect(t, !competing, "startup must retain its exclusive directory lock")
	manifest, found, valid := load_storage_layout_manifest(dir)
	testing.expect(t, found && valid && manifest.mode == .SQLite_V1)
	root := sharded_generation_path(dir, manifest.generation); defer delete(root)
	for shard in 0 ..< LOGICAL_SHARD_COUNT {
		wal := sharded_active_wal_path(root, shard); defer delete(wal)
		testing.expect(t, !os.exists(wal), "SQLite bootstrap must not create a workspace WAL")
	}
	server: NRC_Server
	defer stop_server_databases(&server)
	// Restart with a different worker count. The same shard must still contain
	// the committed row, while every unowned shard path remains unassigned.
	for workers, run in ([2]int{5, 3}) {
		if !testing.expect(t, start_server_databases(&server, dir, manifest.generation, workers)) do return
		for shard in 0 ..< LOGICAL_SHARD_COUNT {
			worker := shard % workers
			port := server_database_port(&server, worker)
			for e, index in server.databases {
				testing.expect_value(t, len(string(e.paths[shard])) > 0, index == worker % len(server.databases))
			}
			request := db.Request {
				shard = shard,
				workspace = "startup-fixture",
				operation = run == 0 ? .Put_Task : .Get_Task,
				task_id = 7,
				task = pr.Task{id = 7, title = transmute([]byte)string("survives restart")},
			}
			if !testing.expect(t, db.submit(port, request)) do return
			deadline := nrc_time_now()
			for {
				job, received := db.receive(port)
				if received {
					testing.expect_value(t, job.result.status, sql.OK)
					if run == 1 do testing.expect(t, job.result.found && string(job.result.task.title) == "survives restart")
					db.release_completion(port, job)
					break
				}
				if time.since(deadline) > 5 * time.Second do testing.fail_now(t, "startup executor did not complete request")
				time.sleep(time.Millisecond)
			}
		}
		stop_server_databases(&server)
	}
	release_data_directory_lock(&lock)
	lock, ok = sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, ok)
	// Corruption in a later executor must unwind already-started executors.
	bad := sqlite_shard_path(dir, manifest.generation, 255); defer delete(bad)
	testing.expect(t, os.write_entire_file(bad, transmute([]byte)string("not sqlite")) == nil)
	testing.expect(t, !start_server_databases(&server, dir, manifest.generation, 4))
	testing.expect_value(t, len(server.databases), 0)
	release_data_directory_lock(&lock)
	testing.expect(t, os.remove(bad) == nil)
	_, missing_ok := sqlite_storage_layout_gate(dir, 3)
	testing.expect(t, !missing_ok && !os.exists(bad), "missing shards must not be recreated")
}

@(test)
test_sqlite_startup_refuses_legacy_and_partial_layouts :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("sqlite-refusal")
	defer os.remove_all(dir)
	if !testing.expect(t, storage_layout_test_create_generation(dir, 1)) do return
	if !testing.expect(t, storage_layout_test_write_manifest(dir, storage_layout_test_manifest(1))) do return
	_, accepted := sqlite_storage_layout_gate(dir, 1)
	testing.expect(t, !accepted)
	manifest, found, valid := load_storage_layout_manifest(dir)
	testing.expect(t, found && valid && manifest.mode == .Sharded_V1)
	path := sqlite_shard_path(dir, manifest.generation, 0); defer delete(path)
	testing.expect(t, !os.exists(path))
	manifest_path := storage_layout_path(dir, STORAGE_LAYOUT_MANIFEST_NAME); defer delete(manifest_path)
	testing.expect(t, os.remove(manifest_path) == nil)
	_, partial_ok := sqlite_storage_layout_gate(dir, 1)
	testing.expect(t, !partial_ok && !os.exists(manifest_path))
}
