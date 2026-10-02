package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:testing"

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
test_sharded_storage_layout_gate_bootstraps_cold_directory :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("cold-bootstrap")
	defer os.remove_all(dir)

	lock, ok := sharded_storage_layout_gate(dir, 3)
	testing.expect(t, ok)
	if !ok do return
	release_data_directory_lock(&lock)

	m, found, valid := load_storage_layout_manifest(dir)
	testing.expect(t, found)
	testing.expect(t, valid)
	testing.expect_value(t, m.generation, FRESH_STORAGE_LAYOUT_GENERATION)
	testing.expect(t, active_sharded_generation_structure_is_valid(dir, m.generation))
}

@(test)
test_sharded_storage_layout_gate_refuses_legacy_data_without_manifest :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("legacy-refusal")
	defer os.remove_all(dir)

	legacy := storage_layout_path(dir, "tasks_thread_0.log")
	defer delete(legacy)
	testing.expect(t, os.write_entire_file(legacy, nil) == nil)

	_, ok := sharded_storage_layout_gate(dir, 3)
	testing.expect(t, !ok)
}

@(test)
test_sharded_storage_layout_gate_requires_valid_generation_after_manifest :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("startup-requirements")
	defer os.remove_all(dir)

	testing.expect(t, storage_layout_test_write_manifest(dir, storage_layout_test_manifest(2)))
	_, missing_generation_ok := sharded_storage_layout_gate(dir, 3)
	testing.expect(t, !missing_generation_ok)

	testing.expect(t, storage_layout_test_create_generation(dir, 2))
	lock, ok := sharded_storage_layout_gate(dir, 3)
	testing.expect(t, ok)
	if ok do release_data_directory_lock(&lock)
}

@(test)
test_sharded_storage_layout_gate_accepts_worker_count_changes_and_non_divisors :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("worker-resize")
	defer os.remove_all(dir)
	testing.expect(t, storage_layout_test_create_generation(dir, 2))
	testing.expect(t, storage_layout_test_write_manifest(dir, storage_layout_test_manifest(2)))

	for worker_count in ([?]int{1, 3, 7, 16, 255, 256}) {
		lock, ok := sharded_storage_layout_gate(dir, worker_count)
		testing.expectf(t, ok, "sharded startup should accept worker_count=%d", worker_count)
		if ok do release_data_directory_lock(&lock)
	}
	_, zero_ok := sharded_storage_layout_gate(dir, 0)
	testing.expect(t, !zero_ok)
	_, excessive_ok := sharded_storage_layout_gate(dir, MAX_SERVER_WORKER_COUNT + 1)
	testing.expect(t, !excessive_ok)
}

@(test)
test_sharded_storage_layout_gate_rejects_incomplete_generation :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("incomplete-generation")
	defer os.remove_all(dir)
	testing.expect(t, storage_layout_test_create_generation(dir, 2))
	testing.expect(t, storage_layout_test_write_manifest(dir, storage_layout_test_manifest(2)))
	generation_dir := sharded_generation_path(dir, 2)
	defer delete(generation_dir)
	missing := sharded_active_wal_path(generation_dir, 73)
	defer delete(missing)
	testing.expect(t, os.remove(missing) == nil)
	_, ok := sharded_storage_layout_gate(dir, 4)
	testing.expect(t, !ok)
}
