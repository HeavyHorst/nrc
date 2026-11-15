package main

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sys/linux"

STORAGE_LAYOUT_MANIFEST_NAME :: "storage-layout.manifest"
STORAGE_LAYOUT_LOCK_NAME :: "storage-layout.lock"
STORAGE_LAYOUT_MAGIC :: u32(0x4e52434c) // NRCL
STORAGE_LAYOUT_VERSION :: u16(1)
STORAGE_LAYOUT_MANIFEST_SIZE :: 40
MAX_SERVER_WORKER_COUNT :: 256
LOGICAL_SHARD_COUNT :: 256
SHARD_WAL_VERSION :: u16(1)
FRESH_STORAGE_LAYOUT_GENERATION :: u64(1)

Storage_Layout_Mode :: enum u8 {
	Sharded_V1 = 2,
	SQLite_V1  = 3,
}

Workspace_Hash_Algorithm :: enum u8 {
	XXH64_Seed_0_Raw = 1,
}

Storage_Layout_Manifest :: struct {
	generation:          u64,
	mode:                Storage_Layout_Mode,
	workspace_hash:      Workspace_Hash_Algorithm,
	logical_shard_count: u32,
	shard_wal_version:   u16,
}

valid_storage_layout_worker_count :: proc(worker_count: int) -> bool {
	return worker_count > 0 && worker_count <= MAX_SERVER_WORKER_COUNT
}

storage_layout_shape_is_coherent :: proc(m: Storage_Layout_Manifest) -> bool {
	return (m.mode == .Sharded_V1 || m.mode == .SQLite_V1) && m.logical_shard_count == LOGICAL_SHARD_COUNT && m.shard_wal_version == SHARD_WAL_VERSION
}

encode_storage_layout_manifest :: proc(m: Storage_Layout_Manifest, out: []byte) -> bool {
	if len(out) != STORAGE_LAYOUT_MANIFEST_SIZE || m.generation == 0 || m.workspace_hash != .XXH64_Seed_0_Raw || !storage_layout_shape_is_coherent(m) {
		return false
	}
	for &b in out do b = 0
	endian.put_u32(out[0:], .Big, STORAGE_LAYOUT_MAGIC)
	endian.put_u16(out[4:], .Big, STORAGE_LAYOUT_VERSION)
	endian.put_u64(out[8:], .Big, m.generation)
	out[16] = u8(m.mode)
	out[17] = u8(m.workspace_hash)
	endian.put_u32(out[24:], .Big, m.logical_shard_count)
	endian.put_u16(out[28:], .Big, m.shard_wal_version)
	endian.put_u64(out[32:], .Big, xxhash.XXH64(out[:32]))
	return true
}

decode_storage_layout_manifest :: proc(data: []byte) -> (m: Storage_Layout_Manifest, ok: bool) {
	if len(data) != STORAGE_LAYOUT_MANIFEST_SIZE do return m, false
	magic, _ := endian.get_u32(data[0:], .Big)
	version, _ := endian.get_u16(data[4:], .Big)
	reserved1, _ := endian.get_u16(data[6:], .Big)
	reserved2, _ := endian.get_u16(data[18:], .Big)
	legacy_worker_count, _ := endian.get_u32(data[20:], .Big)
	reserved3, _ := endian.get_u16(data[30:], .Big)
	checksum, _ := endian.get_u64(data[32:], .Big)
	if magic != STORAGE_LAYOUT_MAGIC ||
	   version != STORAGE_LAYOUT_VERSION ||
	   reserved1 != 0 ||
	   reserved2 != 0 ||
	   legacy_worker_count != 0 ||
	   reserved3 != 0 ||
	   checksum != xxhash.XXH64(data[:32]) {
		return m, false
	}
	m.generation, _ = endian.get_u64(data[8:], .Big)
	m.mode = Storage_Layout_Mode(data[16])
	m.workspace_hash = Workspace_Hash_Algorithm(data[17])
	m.logical_shard_count, _ = endian.get_u32(data[24:], .Big)
	m.shard_wal_version, _ = endian.get_u16(data[28:], .Big)
	if m.generation == 0 || m.workspace_hash != .XXH64_Seed_0_Raw || !storage_layout_shape_is_coherent(m) {
		return m, false
	}
	return m, true
}

storage_layout_path :: proc(dir, name: string) -> string {
	p, err := filepath.join({dir, name}, context.allocator)
	if err != nil do return strings.concatenate({dir, "/", name})
	return p
}

storage_layout_is_real_directory :: proc(path: string) -> bool {
	info, err := os.lstat(path, context.allocator)
	if err != nil do return false
	defer os.file_info_delete(info, context.allocator)
	return info.type == .Directory
}

Data_Directory_Lock :: struct {
	file: ^os.File,
}

acquire_data_directory_lock :: proc(dir: string) -> (lock: Data_Directory_Lock, ok: bool) {
	if !storage_layout_is_real_directory(dir) {
		if os.make_directory(dir) != nil do return lock, false
	}
	path := storage_layout_path(dir, STORAGE_LAYOUT_LOCK_NAME)
	defer delete(path)
	file, open_err := os.open(path, {.Write, .Create}, os.perm(0o644))
	if open_err != nil do return lock, false
	lock.file = file
	if linux.flock(linux.Fd(os.fd(lock.file)), {.EX, .NB}) != .NONE {
		os.close(lock.file)
		lock.file = nil
		return lock, false
	}
	return lock, true
}

install_storage_layout_manifest :: proc(dir: string, m: Storage_Layout_Manifest) -> bool {
	path := storage_layout_path(dir, STORAGE_LAYOUT_MANIFEST_NAME)
	defer delete(path)
	if os.exists(path) do return false
	tmp := storage_layout_path(dir, ".storage-layout.manifest.tmp")
	defer delete(tmp)
	defer os.remove(tmp)
	_ = os.remove(tmp)
	buf: [STORAGE_LAYOUT_MANIFEST_SIZE]byte
	if !encode_storage_layout_manifest(m, buf[:]) do return false
	f, err := os.open(tmp, {.Write, .Create, .Excl, .Trunc}, os.perm(0o644))
	if err != nil do return false
	total := 0
	for total < len(buf) {
		written, write_err := os.write(f, buf[total:])
		if write_err != nil || written <= 0 {os.close(f); return false}
		total += written
	}
	if sync_err := os.sync(f); sync_err != nil {os.close(f); return false}
	if close_err := os.close(f); close_err != nil do return false
	if os.exists(path) do return false
	if os.rename(tmp, path) != nil do return false
	d, open_err := os.open(dir, {.Read})
	if open_err != nil do return false
	sync_err := os.sync(d)
	os.close(d)
	return sync_err == nil
}

data_directory_is_cold :: proc(dir: string) -> bool {
	entries, read_err := os.read_all_directory_by_path(dir, context.allocator)
	if read_err != nil do return false
	defer os.file_info_slice_delete(entries, context.allocator)
	for entry in entries {
		if entry.name == STORAGE_LAYOUT_LOCK_NAME do continue
		if entry.name == STORAGE_LAYOUT_MANIFEST_NAME do continue
		if entry.name == ".storage-layout.manifest.tmp" do continue
		return false
	}
	return true
}

release_data_directory_lock :: proc(lock: ^Data_Directory_Lock) {
	if lock.file != nil {
		_ = linux.flock(linux.Fd(os.fd(lock.file)), {.UN})
		os.close(lock.file)
		lock.file = nil
	}
}

load_storage_layout_manifest :: proc(dir: string) -> (m: Storage_Layout_Manifest, found, ok: bool) {
	path := storage_layout_path(dir, STORAGE_LAYOUT_MANIFEST_NAME)
	defer delete(path)
	if !os.exists(path) do return m, false, true
	data, err := os.read_entire_file(path, context.allocator)
	defer delete(data)
	if err != nil do return m, true, false
	m, ok = decode_storage_layout_manifest(data)
	return m, true, ok
}
