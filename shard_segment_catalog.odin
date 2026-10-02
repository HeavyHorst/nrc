package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"

import "storage_io"

SHARD_SEGMENT_CATALOG_MAGIC :: u32(0x4e524353) // NRCS
SHARD_SEGMENT_CATALOG_VERSION :: u16(2)
SHARD_SEGMENT_CATALOG_LEGACY_VERSION :: u16(1)
SHARD_SEGMENT_CATALOG_HEADER_SIZE :: 32
SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE :: 16
SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE :: 8
// This protects allocation and arithmetic when reading corrupt input. It is not
// an operational segment-count limit: a 64 MiB catalog describes more than four
// million immutable segments.
SHARD_SEGMENT_CATALOG_MAX_BYTES :: 64 * 1024 * 1024
SHARD_SEGMENT_CATALOG_MAX_SEGMENTS ::
	(SHARD_SEGMENT_CATALOG_MAX_BYTES - SHARD_SEGMENT_CATALOG_HEADER_SIZE - SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE) / SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
SHARD_SEGMENT_CATALOG_LEGACY_MAX_SEGMENTS :: 64
SHARD_SEGMENT_CATALOG_LEGACY_SIZE ::
	SHARD_SEGMENT_CATALOG_HEADER_SIZE + SHARD_SEGMENT_CATALOG_LEGACY_MAX_SEGMENTS * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE + SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE

Shard_Segment_Kind :: enum u8 {
	Legacy_Checkpoint_WAL = 1,
	Generation_WAL,
	Cleaned_Segment,
	Adopted_Generation_WAL,
}

Shard_Segment_Descriptor :: struct {
	kind:       Shard_Segment_Kind,
	generation: u64,
}

Shard_Segment_Catalog :: struct {
	shard:              int,
	catalog_generation: u64,
	segments:           [dynamic]Shard_Segment_Descriptor,
}

destroy_shard_segment_catalog :: proc(catalog: ^Shard_Segment_Catalog) {
	if catalog == nil do return
	delete(catalog.segments)
	catalog^ = {}
}

clone_shard_segment_catalog :: proc(source: Shard_Segment_Catalog) -> (catalog: Shard_Segment_Catalog, ok: bool) {
	catalog.shard = source.shard
	catalog.catalog_generation = source.catalog_generation
	catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments))
	copy(catalog.segments[:], source.segments[:])
	return catalog, true
}

shard_segment_descriptor_is_valid :: proc(descriptor: Shard_Segment_Descriptor) -> bool {
	switch descriptor.kind {
	case .Legacy_Checkpoint_WAL, .Cleaned_Segment:
		return descriptor.generation != 0
	case .Generation_WAL, .Adopted_Generation_WAL:
		return true
	}
	return false
}

shard_segment_descriptor_physical_identity :: proc(descriptor: Shard_Segment_Descriptor) -> Shard_Segment_Descriptor {
	if descriptor.kind == .Adopted_Generation_WAL do return {.Generation_WAL, descriptor.generation}
	return descriptor
}

shard_segment_descriptors_share_file :: proc(a, b: Shard_Segment_Descriptor) -> bool {
	return shard_segment_descriptor_physical_identity(a) == shard_segment_descriptor_physical_identity(b)
}

shard_segment_catalog_encoded_size :: proc(segment_count: int) -> (size: int, ok: bool) {
	if segment_count < 0 || segment_count > SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return
	size = SHARD_SEGMENT_CATALOG_HEADER_SIZE + segment_count * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE + SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE
	return size, size <= SHARD_SEGMENT_CATALOG_MAX_BYTES
}

shard_segment_catalog_is_valid :: proc(catalog: Shard_Segment_Catalog) -> bool {
	if catalog.shard < 0 || catalog.shard >= LOGICAL_SHARD_COUNT || catalog.catalog_generation == 0 do return false
	_, size_ok := shard_segment_catalog_encoded_size(len(catalog.segments))
	if !size_ok do return false
	seen := make(map[Shard_Segment_Descriptor]bool, len(catalog.segments), context.temp_allocator)
	for descriptor in catalog.segments {
		if !shard_segment_descriptor_is_valid(descriptor) do return false
		identity := shard_segment_descriptor_physical_identity(descriptor)
		if seen[identity] do return false
		seen[identity] = true
	}
	return true
}

encode_shard_segment_catalog :: proc(catalog: Shard_Segment_Catalog, out: []byte) -> bool {
	expected_size, size_ok := shard_segment_catalog_encoded_size(len(catalog.segments))
	if !size_ok || len(out) != expected_size || !shard_segment_catalog_is_valid(catalog) do return false
	for &b in out do b = 0
	endian.put_u32(out[0:], .Big, SHARD_SEGMENT_CATALOG_MAGIC)
	endian.put_u16(out[4:], .Big, SHARD_SEGMENT_CATALOG_VERSION)
	endian.put_u16(out[6:], .Big, u16(catalog.shard))
	endian.put_u64(out[8:], .Big, catalog.catalog_generation)
	endian.put_u32(out[16:], .Big, u32(len(catalog.segments)))
	for descriptor, index in catalog.segments {
		offset := SHARD_SEGMENT_CATALOG_HEADER_SIZE + index * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
		out[offset] = byte(descriptor.kind)
		endian.put_u64(out[offset + 8:], .Big, descriptor.generation)
	}
	checksum_offset := len(out) - SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE
	endian.put_u64(out[checksum_offset:], .Big, xxhash.XXH64(out[:checksum_offset]))
	return true
}

decode_shard_segment_catalog :: proc(data: []byte) -> (result: Shard_Segment_Catalog, ok: bool) {
	if len(data) < SHARD_SEGMENT_CATALOG_HEADER_SIZE + SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE || len(data) > SHARD_SEGMENT_CATALOG_MAX_BYTES do return
	magic, _ := endian.get_u32(data[0:], .Big)
	version, _ := endian.get_u16(data[4:], .Big)
	shard, _ := endian.get_u16(data[6:], .Big)
	catalog_generation, _ := endian.get_u64(data[8:], .Big)
	segment_count: int
	switch version {
	case SHARD_SEGMENT_CATALOG_VERSION:
		count, _ := endian.get_u32(data[16:], .Big)
		if u64(count) > u64(max(int)) do return
		segment_count = int(count)
		expected_size, size_ok := shard_segment_catalog_encoded_size(segment_count)
		if !size_ok || len(data) != expected_size do return
		for b in data[20:SHARD_SEGMENT_CATALOG_HEADER_SIZE] do if b != 0 do return
	case SHARD_SEGMENT_CATALOG_LEGACY_VERSION:
		if len(data) != SHARD_SEGMENT_CATALOG_LEGACY_SIZE do return
		count, _ := endian.get_u16(data[16:], .Big)
		if count > SHARD_SEGMENT_CATALOG_LEGACY_MAX_SEGMENTS do return
		segment_count = int(count)
		for b in data[18:SHARD_SEGMENT_CATALOG_HEADER_SIZE] do if b != 0 do return
	case:
		return
	}
	checksum_offset := len(data) - SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE
	checksum, _ := endian.get_u64(data[checksum_offset:], .Big)
	if magic != SHARD_SEGMENT_CATALOG_MAGIC || checksum != xxhash.XXH64(data[:checksum_offset]) do return
	// Bare failure returns must stay empty: Odin copies results before defers run.
	// Keep the owned candidate local and transfer it only after validation succeeds.
	catalog: Shard_Segment_Catalog
	catalog.shard = int(shard)
	catalog.catalog_generation = catalog_generation
	catalog.segments = make([dynamic]Shard_Segment_Descriptor, segment_count)
	decoded := false
	defer if !decoded do destroy_shard_segment_catalog(&catalog)
	for index in 0 ..< segment_count {
		offset := SHARD_SEGMENT_CATALOG_HEADER_SIZE + index * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
		for b in data[offset + 1:offset + 8] do if b != 0 do return
		generation, _ := endian.get_u64(data[offset + 8:], .Big)
		catalog.segments[index] = {
			kind       = Shard_Segment_Kind(data[offset]),
			generation = generation,
		}
	}
	if version == SHARD_SEGMENT_CATALOG_LEGACY_VERSION {
		for index in segment_count ..< SHARD_SEGMENT_CATALOG_LEGACY_MAX_SEGMENTS {
			offset := SHARD_SEGMENT_CATALOG_HEADER_SIZE + index * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
			for b in data[offset:offset + SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE] do if b != 0 do return
		}
	}
	if !shard_segment_catalog_is_valid(catalog) do return
	decoded = true
	return catalog, true
}

shard_segment_catalog_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("catalog-%020d.cat", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_segment_catalog_temp_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("catalog-%020d.tmp", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_cleaned_segment_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("cleaned-%020d.seg", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_cleaned_segment_temp_path :: proc(shard_dir: string, generation: u64) -> string {
	name := fmt.aprintf("cleaned-%020d.tmp", generation)
	defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_segment_descriptor_path :: proc(shard_dir: string, descriptor: Shard_Segment_Descriptor) -> string {
	switch descriptor.kind {
	case .Legacy_Checkpoint_WAL:
		return shard_checkpoint_wal_path(shard_dir, descriptor.generation)
	case .Generation_WAL, .Adopted_Generation_WAL:
		return shard_generation_wal_path(shard_dir, descriptor.generation)
	case .Cleaned_Segment:
		return shard_cleaned_segment_path(shard_dir, descriptor.generation)
	}
	return ""
}

load_shard_segment_catalog :: proc(storage: storage_io.Context, shard_dir: string, generation: u64) -> (catalog: Shard_Segment_Catalog, ok: bool) {
	path := shard_segment_catalog_path(shard_dir, generation)
	defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return
	defer storage_io.discard(file)
	size, size_err := storage_io.file_size(file)
	if size_err != nil || size < SHARD_SEGMENT_CATALOG_HEADER_SIZE + SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE || size > SHARD_SEGMENT_CATALOG_MAX_BYTES do return
	data := make([]byte, int(size), context.temp_allocator)
	read := 0
	for read < len(data) {
		count, read_err := storage_io.read_at(file, data[read:], read)
		if read_err != nil || count == 0 do return
		read += count
	}
	catalog, ok = decode_shard_segment_catalog(data)
	return
}

write_shard_segment_catalog :: proc(storage: storage_io.Context, shard_dir: string, catalog: Shard_Segment_Catalog) -> bool {
	size, size_ok := shard_segment_catalog_encoded_size(len(catalog.segments))
	if !size_ok do return false
	data := make([]byte, size)
	defer delete(data)
	if !encode_shard_segment_catalog(catalog, data) do return false
	temp_path := shard_segment_catalog_temp_path(shard_dir, catalog.catalog_generation)
	defer delete(temp_path)
	final_path := shard_segment_catalog_path(shard_dir, catalog.catalog_generation)
	defer delete(final_path)
	_ = storage_io.remove(storage, temp_path)
	if shard_compaction_fault_hit(.Catalog_Create) do return false
	file, open_err := storage_io.open(storage, temp_path, {.Write, .Create, .Excl}, os.perm(0o644))
	if open_err != nil do return false
	written: int
	write_err: os.Error
	if !shard_compaction_fault_hit(.Catalog_Write) {
		written, write_err = storage_io.write(file, data)
	}
	sync_ok := !shard_compaction_fault_hit(.Catalog_Sync) && storage_io.sync(file) == nil
	close_err := storage_io.close(file)
	if write_err != nil || written != len(data) || !sync_ok || close_err != nil {
		_ = storage_io.remove(storage, temp_path)
		return false
	}
	if shard_compaction_fault_hit(.Catalog_Rename) || storage_io.rename(storage, temp_path, final_path) != nil do return false
	return !shard_compaction_fault_hit(.Catalog_Directory_Sync) && storage_io.sync_directory(storage, shard_dir) == nil
}
