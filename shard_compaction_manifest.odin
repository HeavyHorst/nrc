package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"

import "storage_io"

SHARD_COMPACTION_MANIFEST_NAME :: "shard.manifest"
SHARD_COMPACTION_MANIFEST_TEMP_NAME :: "shard.manifest.tmp"
SHARD_COMPACTION_MANIFEST_MAGIC :: u32(0x4e52434b) // NRCK
SHARD_COMPACTION_MANIFEST_VERSION :: u16(1)
SHARD_COMPACTION_MANIFEST_SIZE :: 56
SHARD_COMPACTION_HAS_CHECKPOINT :: u16(1 << 0)
SHARD_COMPACTION_HAS_SEALED :: u16(1 << 1)
SHARD_COMPACTION_HAS_SEGMENT_CATALOG :: u16(1 << 2)

Shard_Compaction_Manifest :: struct {
	shard:                 int,
	manifest_generation:   u64,
	checkpoint_present:    bool,
	checkpoint_generation: u64,
	sealed_present:        bool,
	sealed_generation:     u64,
	active_generation:     u64,
	segmented:             bool,
}

Shard_Manifest_Publish_Result :: enum u8 {
	Failed_Unpublished,
	Published,
	Published_Uncertain,
}

Shard_Compaction_Fault_Point :: enum u8 {
	None,
	Sealed_WAL_Sync,
	New_Active_Create,
	New_Active_Sync,
	New_Active_Directory_Sync,
	Manifest_Create,
	Manifest_Write,
	Manifest_Sync,
	Manifest_Rename,
	Manifest_Directory_Sync,
	Checkpoint_Rename,
	Checkpoint_Directory_Sync,
	Checkpoint_Write,
	Checkpoint_Sync,
	Catalog_Create,
	Catalog_Write,
	Catalog_Sync,
	Catalog_Rename,
	Catalog_Directory_Sync,
	Old_Checkpoint_Remove,
	Sealed_WAL_Remove,
	Cleanup_Directory_Sync,
}

Shard_Compaction_Fault_State :: struct {
	point:     Shard_Compaction_Fault_Point,
	triggered: bool,
}

@(thread_local)
shard_compaction_fault_state: Shard_Compaction_Fault_State

set_shard_compaction_fault_for_test :: proc(point: Shard_Compaction_Fault_Point) {
	shard_compaction_fault_state = {
		point = point,
	}
}

clear_shard_compaction_fault_for_test :: proc() {
	shard_compaction_fault_state = {}
}

shard_compaction_fault_triggered_for_test :: proc() -> bool {
	return shard_compaction_fault_state.triggered
}

shard_compaction_fault_hit :: proc(point: Shard_Compaction_Fault_Point) -> bool {
	if point == .None || shard_compaction_fault_state.point != point do return false
	shard_compaction_fault_state.point = .None
	shard_compaction_fault_state.triggered = true
	return true
}

shard_compaction_manifest_is_valid :: proc(manifest: Shard_Compaction_Manifest) -> bool {
	if manifest.shard < 0 || manifest.shard >= LOGICAL_SHARD_COUNT || manifest.manifest_generation == 0 do return false
	if manifest.checkpoint_present && manifest.checkpoint_generation == 0 do return false
	if !manifest.checkpoint_present && manifest.checkpoint_generation != 0 do return false
	if manifest.segmented && !manifest.checkpoint_present do return false
	if !manifest.sealed_present && manifest.sealed_generation != 0 do return false
	if manifest.sealed_present && manifest.sealed_generation == manifest.active_generation do return false
	return true
}

encode_shard_compaction_manifest :: proc(manifest: Shard_Compaction_Manifest, out: []byte) -> bool {
	if len(out) != SHARD_COMPACTION_MANIFEST_SIZE || !shard_compaction_manifest_is_valid(manifest) do return false
	for &b in out do b = 0
	flags: u16
	if manifest.checkpoint_present do flags |= SHARD_COMPACTION_HAS_CHECKPOINT
	if manifest.sealed_present do flags |= SHARD_COMPACTION_HAS_SEALED
	if manifest.segmented do flags |= SHARD_COMPACTION_HAS_SEGMENT_CATALOG
	endian.put_u32(out[0:], .Big, SHARD_COMPACTION_MANIFEST_MAGIC)
	endian.put_u16(out[4:], .Big, SHARD_COMPACTION_MANIFEST_VERSION)
	endian.put_u16(out[6:], .Big, flags)
	endian.put_u16(out[8:], .Big, u16(manifest.shard))
	endian.put_u64(out[16:], .Big, manifest.manifest_generation)
	endian.put_u64(out[24:], .Big, manifest.checkpoint_generation)
	endian.put_u64(out[32:], .Big, manifest.sealed_generation)
	endian.put_u64(out[40:], .Big, manifest.active_generation)
	endian.put_u64(out[48:], .Big, xxhash.XXH64(out[:48]))
	return true
}

decode_shard_compaction_manifest :: proc(data: []byte) -> (manifest: Shard_Compaction_Manifest, ok: bool) {
	if len(data) != SHARD_COMPACTION_MANIFEST_SIZE do return
	magic, _ := endian.get_u32(data[0:], .Big)
	version, _ := endian.get_u16(data[4:], .Big)
	flags, _ := endian.get_u16(data[6:], .Big)
	shard, _ := endian.get_u16(data[8:], .Big)
	reserved16, _ := endian.get_u16(data[10:], .Big)
	reserved32, _ := endian.get_u32(data[12:], .Big)
	checksum, _ := endian.get_u64(data[48:], .Big)
	if magic != SHARD_COMPACTION_MANIFEST_MAGIC ||
	   version != SHARD_COMPACTION_MANIFEST_VERSION ||
	   flags & ~(SHARD_COMPACTION_HAS_CHECKPOINT | SHARD_COMPACTION_HAS_SEALED | SHARD_COMPACTION_HAS_SEGMENT_CATALOG) != 0 ||
	   reserved16 != 0 ||
	   reserved32 != 0 ||
	   checksum != xxhash.XXH64(data[:48]) {
		return
	}
	manifest_generation, _ := endian.get_u64(data[16:], .Big)
	checkpoint_generation, _ := endian.get_u64(data[24:], .Big)
	sealed_generation, _ := endian.get_u64(data[32:], .Big)
	active_generation, _ := endian.get_u64(data[40:], .Big)
	manifest = {
		shard                 = int(shard),
		manifest_generation   = manifest_generation,
		checkpoint_present    = flags & SHARD_COMPACTION_HAS_CHECKPOINT != 0,
		checkpoint_generation = checkpoint_generation,
		sealed_present        = flags & SHARD_COMPACTION_HAS_SEALED != 0,
		sealed_generation     = sealed_generation,
		active_generation     = active_generation,
		segmented             = flags & SHARD_COMPACTION_HAS_SEGMENT_CATALOG != 0,
	}
	return manifest, shard_compaction_manifest_is_valid(manifest)
}

shard_compaction_manifest_path :: proc(shard_dir: string) -> string {
	return storage_layout_path(shard_dir, SHARD_COMPACTION_MANIFEST_NAME)
}

shard_compaction_manifest_temp_path :: proc(shard_dir: string) -> string {
	return storage_layout_path(shard_dir, SHARD_COMPACTION_MANIFEST_TEMP_NAME)
}

shard_generation_wal_path :: proc(shard_dir: string, generation: u64) -> string {
	if generation == 0 do return storage_layout_path(shard_dir, SHARDED_ACTIVE_WAL_NAME)
	name := fmt.aprintf("wal-%020d.wal", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_checkpoint_wal_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("checkpoint-%020d.wal", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_checkpoint_temp_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("checkpoint-%020d.tmp", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_compaction_regular_file :: proc {
	shard_compaction_regular_file_host,
	shard_compaction_regular_file_with_storage,
}

shard_compaction_regular_file_host :: proc(path: string) -> bool {
	return shard_compaction_regular_file_with_storage(storage_io.host_context(), path)
}

shard_compaction_regular_file_with_storage :: proc(storage: storage_io.Context, path: string) -> bool {
	if storage_io.context_is_host(storage) {
		info, stat_err := os.lstat(path, context.temp_allocator)
		if stat_err != nil do return false
		defer os.file_info_delete(info, context.temp_allocator)
		return info.type == .Regular
	}
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return false
	return storage_io.close(file) == nil
}

shard_compaction_manifest_files_are_valid :: proc {
	shard_compaction_manifest_files_are_valid_host,
	shard_compaction_manifest_files_are_valid_with_storage,
}

shard_compaction_manifest_files_are_valid_host :: proc(shard_dir: string, manifest: Shard_Compaction_Manifest) -> bool {
	return shard_compaction_manifest_files_are_valid_with_storage(storage_io.host_context(), shard_dir, manifest)
}

shard_compaction_manifest_files_are_valid_with_storage :: proc(storage: storage_io.Context, shard_dir: string, manifest: Shard_Compaction_Manifest) -> bool {
	if !shard_compaction_manifest_is_valid(manifest) do return false
	active_path := shard_generation_wal_path(shard_dir, manifest.active_generation)
	defer delete(active_path)
	if !shard_compaction_regular_file(storage, active_path) do return false
	if manifest.checkpoint_present {
		if manifest.segmented {
			catalog_path := shard_segment_catalog_path(shard_dir, manifest.checkpoint_generation)
			catalog_regular := shard_compaction_regular_file(storage, catalog_path)
			delete(catalog_path)
			if !catalog_regular do return false
			catalog, catalog_ok := load_shard_segment_catalog(storage, shard_dir, manifest.checkpoint_generation)
			if !catalog_ok || catalog.shard != manifest.shard || catalog.catalog_generation != manifest.checkpoint_generation do return false
			defer destroy_shard_segment_catalog(&catalog)
			for descriptor in catalog.segments {
				path := shard_segment_descriptor_path(shard_dir, descriptor)
				valid := path != "" && shard_compaction_regular_file(storage, path)
				if path != "" do delete(path)
				if !valid do return false
			}
		} else {
			path := shard_checkpoint_wal_path(shard_dir, manifest.checkpoint_generation)
			valid := shard_compaction_regular_file(storage, path)
			delete(path)
			if !valid do return false
		}
	}
	if manifest.sealed_present {
		path := shard_generation_wal_path(shard_dir, manifest.sealed_generation)
		valid := shard_compaction_regular_file(storage, path)
		delete(path)
		if !valid do return false
	}
	return true
}

load_shard_compaction_manifest :: proc {
	load_shard_compaction_manifest_host,
	load_shard_compaction_manifest_with_storage,
}

load_shard_compaction_manifest_host :: proc(shard_dir: string) -> (Shard_Compaction_Manifest, bool, bool) {
	return load_shard_compaction_manifest_with_storage(storage_io.host_context(), shard_dir)
}

load_shard_compaction_manifest_with_storage :: proc(storage: storage_io.Context, shard_dir: string) -> (manifest: Shard_Compaction_Manifest, found, ok: bool) {
	path := shard_compaction_manifest_path(shard_dir)
	defer delete(path)
	path_exists, exists_err := storage_io.exists(storage, path)
	if exists_err != nil do return manifest, false, false
	if !path_exists do return manifest, false, true
	data, read_err := storage_io.read_entire_file(storage, path, context.temp_allocator)
	if read_err != nil do return manifest, true, false
	manifest, ok = decode_shard_compaction_manifest(data)
	if ok do ok = shard_compaction_manifest_files_are_valid(storage, shard_dir, manifest)
	return manifest, true, ok
}

publish_shard_compaction_manifest :: proc {
	publish_shard_compaction_manifest_host,
	publish_shard_compaction_manifest_with_storage,
}

publish_shard_compaction_manifest_host :: proc(shard_dir: string, manifest: Shard_Compaction_Manifest) -> Shard_Manifest_Publish_Result {
	return publish_shard_compaction_manifest_with_storage(storage_io.host_context(), shard_dir, manifest)
}

publish_shard_compaction_manifest_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
) -> Shard_Manifest_Publish_Result {
	data: [SHARD_COMPACTION_MANIFEST_SIZE]byte
	if !encode_shard_compaction_manifest(manifest, data[:]) do return .Failed_Unpublished
	temp_path := shard_compaction_manifest_temp_path(shard_dir)
	defer delete(temp_path)
	manifest_path := shard_compaction_manifest_path(shard_dir)
	defer delete(manifest_path)
	_ = storage_io.remove(storage, temp_path)
	if shard_compaction_fault_hit(.Manifest_Create) do return .Failed_Unpublished
	file, open_err := storage_io.open(storage, temp_path, {.Write, .Create, .Excl}, os.perm(0o644))
	if open_err != nil do return .Failed_Unpublished
	written, write_err := 0, os.Error(nil)
	if !shard_compaction_fault_hit(.Manifest_Write) {
		written, write_err = storage_io.write(file, data[:])
	}
	sync_ok := !shard_compaction_fault_hit(.Manifest_Sync) && storage_io.sync(file) == nil
	close_err := storage_io.close(file)
	if write_err != nil || written != len(data) || !sync_ok || close_err != nil {
		_ = storage_io.remove(storage, temp_path)
		return .Failed_Unpublished
	}
	if shard_compaction_fault_hit(.Manifest_Rename) do return .Failed_Unpublished
	if storage_io.rename(storage, temp_path, manifest_path) != nil do return .Failed_Unpublished
	if shard_compaction_fault_hit(.Manifest_Directory_Sync) do return .Published_Uncertain
	if storage_io.sync_directory(storage, shard_dir) != nil do return .Published_Uncertain
	return .Published
}

write_shard_compaction_manifest :: proc {
	write_shard_compaction_manifest_host,
	write_shard_compaction_manifest_with_storage,
}

write_shard_compaction_manifest_host :: proc(shard_dir: string, manifest: Shard_Compaction_Manifest) -> bool {
	return write_shard_compaction_manifest_with_storage(storage_io.host_context(), shard_dir, manifest)
}

write_shard_compaction_manifest_with_storage :: proc(storage: storage_io.Context, shard_dir: string, manifest: Shard_Compaction_Manifest) -> bool {
	return publish_shard_compaction_manifest(storage, shard_dir, manifest) == .Published
}

ensure_shard_compaction_manifest :: proc {
	ensure_shard_compaction_manifest_host,
	ensure_shard_compaction_manifest_with_storage,
}

ensure_shard_compaction_manifest_host :: proc(shard_dir: string, shard: int) -> (Shard_Compaction_Manifest, bool) {
	return ensure_shard_compaction_manifest_with_storage(storage_io.host_context(), shard_dir, shard)
}

ensure_shard_compaction_manifest_with_storage :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	shard: int,
) -> (
	manifest: Shard_Compaction_Manifest,
	ok: bool,
) {
	found, loaded: bool
	manifest, found, loaded = load_shard_compaction_manifest(storage, shard_dir)
	if found do return manifest, loaded && manifest.shard == shard
	if !loaded do return manifest, false
	legacy_active := shard_generation_wal_path(shard_dir, 0)
	defer delete(legacy_active)
	if !shard_compaction_regular_file(storage, legacy_active) do return manifest, false
	manifest = {
		shard               = shard,
		manifest_generation = 1,
	}
	if !write_shard_compaction_manifest(storage, shard_dir, manifest) do return manifest, false
	return manifest, true
}
