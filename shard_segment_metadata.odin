package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:os"
import "core:slice"

import "persistence"
import "storage_io"

SHARD_SEGMENT_METADATA_MAGIC :: u32(0x4e52434d) // NRCM
SHARD_SEGMENT_METADATA_VERSION :: u16(2)
SHARD_SEGMENT_METADATA_HEADER_SIZE :: 112
SHARD_SEGMENT_METADATA_CHECKSUM_SIZE :: 8
SHARD_SEGMENT_METADATA_RECORD_SIZE :: 24
SHARD_SEGMENT_METADATA_MAX_BYTES :: #config(NRC_SHARD_SEGMENT_METADATA_MAX_BYTES, 128 * 1024 * 1024)
SHARD_SEGMENT_METADATA_MAX_KEYS :: #config(NRC_SHARD_SEGMENT_METADATA_MAX_KEYS, 4 * 1024 * 1024)
SHARD_SEGMENT_METADATA_BLOOM_HASHES :: 7
SHARD_SEGMENT_METADATA_DECODED_ESTIMATE_MULTIPLIER :: 8

Shard_Segment_Metadata_Record :: struct {
	offset:          u64,
	physical_size:   u32,
	key_indices:     [dynamic]u32,
	synthetic:       bool,
	graph_sensitive: bool,
}

Shard_Segment_Metadata_Indexed_Key :: struct {
	key:       []byte,
	insertion: u32,
}

Shard_Segment_Metadata :: struct {
	shard:        int,
	descriptor:   Shard_Segment_Descriptor,
	segment_size: u64,
	start:        Shard_High_Water_Requirements,
	start_known:  bool,
	end:          Shard_High_Water_Requirements,
	bloom:        []byte,
	keys:         [dynamic][]byte,
	records:      [dynamic]Shard_Segment_Metadata_Record,
}

Shard_Segment_Metadata_Summary :: struct {
	shard:        int,
	descriptor:   Shard_Segment_Descriptor,
	segment_size: u64,
	start:        Shard_High_Water_Requirements,
	start_known:  bool,
	end:          Shard_High_Water_Requirements,
	key_count:    int,
	bloom:        []byte,
}

destroy_shard_segment_metadata_summary :: proc(summary: ^Shard_Segment_Metadata_Summary) {
	if summary == nil do return
	delete(summary.bloom)
	summary^ = {}
}

destroy_shard_segment_metadata :: proc(metadata: ^Shard_Segment_Metadata) {
	if metadata == nil do return
	for key in metadata.keys do delete(key)
	delete(metadata.keys)
	for &record in metadata.records do delete(record.key_indices)
	delete(metadata.records)
	delete(metadata.bloom)
	metadata^ = {}
}

shard_segment_metadata_key_less :: proc(a, b: []byte) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] do return a[i] < b[i]
	}
	return len(a) < len(b)
}

shard_segment_metadata_key_equal :: proc(a, b: []byte) -> bool {
	if len(a) != len(b) do return false
	for value, i in a do if value != b[i] do return false
	return true
}

shard_segment_metadata_bloom_size :: proc(key_count: int) -> (size: int, ok: bool) {
	if key_count < 0 || key_count > SHARD_SEGMENT_METADATA_MAX_KEYS do return
	if key_count == 0 do return 0, true
	// Ten bits per key gives seven useful probes; round up to whole bytes.
	if key_count > (SHARD_SEGMENT_METADATA_MAX_BYTES - 7) / 10 do return
	size = max(8, (key_count * 10 + 7) / 8)
	return size, true
}

shard_segment_metadata_bloom_apply :: proc(bloom: []byte, key: []byte, insert: bool) -> bool {
	if len(bloom) == 0 do return false
	bits := u64(len(bloom)) * 8
	h1 := xxhash.XXH64(key)
	h2 := ((h1 >> 29) | (h1 << 35)) ~ 0x9e3779b97f4a7c15
	h2 |= 1
	all := true
	for i in 0 ..< SHARD_SEGMENT_METADATA_BLOOM_HASHES {
		bit := (h1 + u64(i) * h2) % bits
		mask := byte(1 << u8(bit & 7))
		index := int(bit >> 3)
		if insert do bloom[index] |= mask
		all = all && bloom[index] & mask != 0
	}
	return all
}

// A true result means only "possibly present"; false is authoritative for a
// successfully loaded metadata object and has no false negatives.
shard_segment_metadata_bloom_maybe_contains :: proc(metadata: ^Shard_Segment_Metadata, key: []byte) -> bool {
	if metadata == nil || len(key) == 0 do return false
	return shard_segment_metadata_bloom_apply(metadata.bloom, key, false)
}

shard_segment_metadata_summary_maybe_contains :: proc(summary: ^Shard_Segment_Metadata_Summary, key: []byte) -> bool {
	if summary == nil || len(key) == 0 do return false
	return shard_segment_metadata_bloom_apply(summary.bloom, key, false)
}

shard_segment_metadata_contains :: proc(metadata: ^Shard_Segment_Metadata, key: []byte) -> bool {
	if metadata == nil || !shard_segment_metadata_bloom_maybe_contains(metadata, key) do return false
	lo, hi := 0, len(metadata.keys)
	for lo < hi {
		mid := lo + (hi - lo) / 2
		if shard_segment_metadata_key_less(metadata.keys[mid], key) {lo = mid + 1} else {hi = mid}
	}
	return lo < len(metadata.keys) && shard_segment_metadata_key_equal(metadata.keys[lo], key)
}

shard_segment_metadata_encoded_size :: proc(metadata: ^Shard_Segment_Metadata) -> (size: int, ok: bool) {
	if metadata == nil || len(metadata.keys) > SHARD_SEGMENT_METADATA_MAX_KEYS do return
	bloom_size, bloom_ok := shard_segment_metadata_bloom_size(len(metadata.keys))
	if !bloom_ok || len(metadata.bloom) != bloom_size do return
	size = SHARD_SEGMENT_METADATA_HEADER_SIZE + bloom_size + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE
	for key in metadata.keys {
		if len(key) == 0 || u64(len(key)) > u64(max(u32)) || size > SHARD_SEGMENT_METADATA_MAX_BYTES - 4 - len(key) do return 0, false
		size += 4 + len(key)
	}
	if len(metadata.records) > int(max(u32)) do return 0, false
	for &record in metadata.records {
		if len(record.key_indices) > int(max(u32)) || size > SHARD_SEGMENT_METADATA_MAX_BYTES - SHARD_SEGMENT_METADATA_RECORD_SIZE do return 0, false
		size += SHARD_SEGMENT_METADATA_RECORD_SIZE
		if len(record.key_indices) > (SHARD_SEGMENT_METADATA_MAX_BYTES - size) / 4 do return 0, false
		size += len(record.key_indices) * 4
	}
	return size, size <= SHARD_SEGMENT_METADATA_MAX_BYTES
}

shard_segment_metadata_is_valid :: proc(metadata: ^Shard_Segment_Metadata) -> bool {
	if metadata == nil ||
	   metadata.shard < 0 ||
	   metadata.shard >= LOGICAL_SHARD_COUNT ||
	   !shard_segment_descriptor_is_valid(metadata.descriptor) ||
	   metadata.descriptor != shard_segment_descriptor_physical_identity(metadata.descriptor) ||
	   metadata.start_known &&
		   (metadata.end.task < metadata.start.task || metadata.end.asset < metadata.start.asset || metadata.end.edge < metadata.start.edge) {
		return false
	}
	_, size_ok := shard_segment_metadata_encoded_size(metadata)
	if !size_ok do return false
	for key, i in metadata.keys {
		if i > 0 && !shard_segment_metadata_key_less(metadata.keys[i - 1], key) do return false
		if !shard_segment_metadata_bloom_apply(metadata.bloom, key, false) do return false
	}
	expected_offset: u64
	for &record in metadata.records {
		if record.offset != expected_offset || record.physical_size == 0 || u64(record.physical_size) > max(u64) - expected_offset do return false
		expected_offset += u64(record.physical_size)
		if record.synthetic != (len(record.key_indices) == 0) do return false
		previous: u32
		for index, i in record.key_indices {
			if int(index) >= len(metadata.keys) || i > 0 && index <= previous do return false
			previous = index
		}
	}
	if expected_offset != metadata.segment_size do return false
	return true
}

encode_shard_segment_metadata :: proc(metadata: ^Shard_Segment_Metadata, out: []byte) -> bool {
	expected, ok := shard_segment_metadata_encoded_size(metadata)
	if !ok || len(out) != expected || !shard_segment_metadata_is_valid(metadata) do return false
	for &b in out do b = 0
	endian.put_u32(out[0:], .Big, SHARD_SEGMENT_METADATA_MAGIC)
	endian.put_u16(out[4:], .Big, SHARD_SEGMENT_METADATA_VERSION)
	endian.put_u16(out[6:], .Big, u16(metadata.shard))
	out[8] = byte(metadata.descriptor.kind)
	if metadata.start_known do out[9] = 1
	endian.put_u64(out[16:], .Big, metadata.descriptor.generation)
	endian.put_u64(out[24:], .Big, metadata.segment_size)
	endian.put_u64(
		out[32:],
		.Big,
		metadata.start.task,
	); endian.put_u64(out[40:], .Big, metadata.start.asset); endian.put_u64(out[48:], .Big, metadata.start.edge)
	endian.put_u64(out[56:], .Big, metadata.end.task); endian.put_u64(out[64:], .Big, metadata.end.asset); endian.put_u64(out[72:], .Big, metadata.end.edge)
	endian.put_u32(out[80:], .Big, u32(len(metadata.keys)))
	endian.put_u32(out[84:], .Big, u32(len(metadata.bloom)))
	endian.put_u32(out[96:], .Big, u32(len(metadata.records)))
	posting_count: u64
	for &record in metadata.records do posting_count += u64(len(record.key_indices))
	if posting_count > u64(max(u32)) do return false
	endian.put_u32(out[100:], .Big, u32(posting_count))
	o := SHARD_SEGMENT_METADATA_HEADER_SIZE
	copy(out[o:], metadata.bloom); o += len(metadata.bloom)
	endian.put_u64(out[88:], .Big, xxhash.XXH64(out[:o]))
	for key in metadata.keys {
		endian.put_u32(out[o:], .Big, u32(len(key))); o += 4
		copy(out[o:], key); o += len(key)
	}
	posting_start: u32
	for &record in metadata.records {
		endian.put_u64(out[o:], .Big, record.offset)
		endian.put_u32(out[o + 8:], .Big, record.physical_size)
		endian.put_u32(out[o + 12:], .Big, posting_start)
		endian.put_u32(out[o + 16:], .Big, u32(len(record.key_indices)))
		if record.synthetic do out[o + 20] |= 1
		if record.graph_sensitive do out[o + 20] |= 2
		o += SHARD_SEGMENT_METADATA_RECORD_SIZE
		posting_start += u32(len(record.key_indices))
	}
	for &record in metadata.records do for index in record.key_indices {endian.put_u32(out[o:], .Big, index); o += 4}
	endian.put_u64(out[o:], .Big, xxhash.XXH64(out[:o]))
	return true
}

decode_shard_segment_metadata :: proc(data: []byte) -> (metadata: Shard_Segment_Metadata, ok: bool) {
	if len(data) < SHARD_SEGMENT_METADATA_HEADER_SIZE + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE || len(data) > SHARD_SEGMENT_METADATA_MAX_BYTES do return
	magic, _ := endian.get_u32(data, .Big); version, _ := endian.get_u16(data[4:], .Big); shard, _ := endian.get_u16(data[6:], .Big)
	if magic != SHARD_SEGMENT_METADATA_MAGIC || version != SHARD_SEGMENT_METADATA_VERSION do return
	if data[9] > 1 do return
	for b in data[10:16] do if b != 0 do return
	checksum_offset := len(data) - SHARD_SEGMENT_METADATA_CHECKSUM_SIZE
	checksum, _ := endian.get_u64(data[checksum_offset:], .Big)
	if checksum != xxhash.XXH64(data[:checksum_offset]) do return
	count32, _ := endian.get_u32(data[80:], .Big); bloom32, _ := endian.get_u32(data[84:], .Big)
	record_count, _ := endian.get_u32(data[96:], .Big); posting_count, _ := endian.get_u32(data[100:], .Big)
	for b in data[104:112] do if b != 0 do return
	if count32 > SHARD_SEGMENT_METADATA_MAX_KEYS || u64(bloom32) > u64(checksum_offset - SHARD_SEGMENT_METADATA_HEADER_SIZE) do return
	expected_bloom, bloom_ok := shard_segment_metadata_bloom_size(int(count32))
	if !bloom_ok || int(bloom32) != expected_bloom do return
	summary_end := SHARD_SEGMENT_METADATA_HEADER_SIZE + int(bloom32)
	if summary_end > checksum_offset do return
	minimum_body_bytes := u64(count32) * 5 + u64(record_count) * SHARD_SEGMENT_METADATA_RECORD_SIZE + u64(posting_count) * 4
	if minimum_body_bytes > u64(checksum_offset - summary_end) do return
	summary_checksum, _ := endian.get_u64(data[88:], .Big)
	endian.put_u64(data[88:], .Big, 0)
	valid_summary_checksum := summary_checksum == xxhash.XXH64(data[:summary_end])
	endian.put_u64(data[88:], .Big, summary_checksum)
	if !valid_summary_checksum do return
	metadata = {
		shard       = int(shard),
		descriptor  = {Shard_Segment_Kind(data[8]), 0},
		start_known = data[9] == 1,
	}
	metadata.descriptor.generation, _ = endian.get_u64(data[16:], .Big); metadata.segment_size, _ = endian.get_u64(data[24:], .Big)
	metadata.start.task, _ = endian.get_u64(
		data[32:],
		.Big,
	); metadata.start.asset, _ = endian.get_u64(data[40:], .Big); metadata.start.edge, _ = endian.get_u64(data[48:], .Big)
	metadata.end.task, _ = endian.get_u64(
		data[56:],
		.Big,
	); metadata.end.asset, _ = endian.get_u64(data[64:], .Big); metadata.end.edge, _ = endian.get_u64(data[72:], .Big)
	metadata.bloom = make([]byte, int(bloom32)); metadata.keys = make([dynamic][]byte, int(count32))
	metadata.records = make([dynamic]Shard_Segment_Metadata_Record, int(record_count))
	decoded := false; defer if !decoded do destroy_shard_segment_metadata(&metadata)
	o := SHARD_SEGMENT_METADATA_HEADER_SIZE; copy(metadata.bloom, data[o:o + int(bloom32)]); o += int(bloom32)
	for i in 0 ..< int(count32) {
		if checksum_offset - o < 4 do return
		n, _ := endian.get_u32(data[o:], .Big); o += 4
		if n == 0 || u64(n) > u64(checksum_offset - o) do return
		metadata.keys[i] = make([]byte, int(n)); copy(metadata.keys[i], data[o:o + int(n)]); o += int(n)
	}
	if u64(record_count) * SHARD_SEGMENT_METADATA_RECORD_SIZE + u64(posting_count) * 4 > u64(checksum_offset - o) do return
	postings_offset := o + int(record_count) * SHARD_SEGMENT_METADATA_RECORD_SIZE
	expected_first: u64
	for i in 0 ..< int(record_count) {
		r := &metadata.records[i]
		r.offset, _ = endian.get_u64(data[o:], .Big); r.physical_size, _ = endian.get_u32(data[o + 8:], .Big)
		first, _ := endian.get_u32(data[o + 12:], .Big); count, _ := endian.get_u32(data[o + 16:], .Big)
		flags := data[o + 20]; if flags & ~u8(3) != 0 do return
		for b in data[o + 21:o + 24] do if b != 0 do return
		if u64(first) != expected_first || expected_first + u64(count) > u64(posting_count) do return
		expected_first += u64(count)
		r.synthetic = flags & 1 != 0; r.graph_sensitive = flags & 2 != 0
		r.key_indices = make([dynamic]u32, int(count))
		for j in 0 ..< int(count) {r.key_indices[j], _ = endian.get_u32(data[postings_offset + (int(first) + j) * 4:], .Big)}
		o += SHARD_SEGMENT_METADATA_RECORD_SIZE
	}
	if expected_first != u64(posting_count) do return
	o = postings_offset + int(posting_count) * 4
	if o != checksum_offset || !shard_segment_metadata_is_valid(&metadata) do return
	decoded = true
	return metadata, true
}

shard_segment_metadata_path :: proc(shard_dir: string, descriptor: Shard_Segment_Descriptor) -> string {
	identity := shard_segment_descriptor_physical_identity(descriptor)
	name := fmt.aprintf("metadata-%03d-%020d.meta", u8(identity.kind), identity.generation); defer delete(name)
	return storage_layout_path(shard_dir, name)
}

shard_segment_metadata_temp_path :: proc(shard_dir: string, descriptor: Shard_Segment_Descriptor) -> string {
	identity := shard_segment_descriptor_physical_identity(descriptor)
	name := fmt.aprintf("metadata-%03d-%020d.tmp", u8(identity.kind), identity.generation); defer delete(name)
	return storage_layout_path(shard_dir, name)
}

Shard_Segment_Metadata_Build_Context :: struct {
	shard:       int,
	previous:    Shard_High_Water_Requirements,
	start:       Shard_High_Water_Requirements,
	start_known: bool,
	keys:        map[string]u32,
	owned_keys:  [dynamic][]byte,
	records:     [dynamic]Shard_Segment_Metadata_Record,
	offset:      u64,
	key_bytes:   int,
	table_bytes: int,
	overflow:    bool,
	ok:          bool,
}

@(thread_local)
shard_segment_metadata_build_context: Shard_Segment_Metadata_Build_Context

shard_segment_metadata_collect_mutation :: proc(mutation: Shard_Mutation, user: rawptr) -> bool {
	ctx := cast(^Shard_Segment_Metadata_Build_Context)user
	if ctx.overflow do return true
	key, key_ok := shard_segment_entity_key(shard_segment_metadata_build_workspace, mutation)
	if !key_ok {ctx.ok = false; return false}
	s := transmute(string)key
	index, found := ctx.keys[s]
	if found {
		delete(key)
	} else {
		next_count := len(ctx.keys) + 1
		bloom_size, bloom_ok := shard_segment_metadata_bloom_size(next_count)
		key_bytes := 4 + len(key)
		if !bloom_ok ||
		   next_count > SHARD_SEGMENT_METADATA_MAX_KEYS ||
		   ctx.key_bytes >
			   SHARD_SEGMENT_METADATA_MAX_BYTES -
				   SHARD_SEGMENT_METADATA_HEADER_SIZE -
				   SHARD_SEGMENT_METADATA_CHECKSUM_SIZE -
				   bloom_size -
				   ctx.table_bytes -
				   key_bytes {
			delete(key); ctx.overflow = true; return true
		}
		index = u32(len(ctx.owned_keys)); ctx.keys[s] = index; append(&ctx.owned_keys, key); ctx.key_bytes += key_bytes
	}
	record := &ctx.records[len(ctx.records) - 1]
	for existing in record.key_indices do if existing == index do return true
	append(&record.key_indices, index)
	record.graph_sensitive = record.graph_sensitive || shard_segment_mutation_requires_exact_raw_retention(mutation)
	return true
}

@(thread_local)
shard_segment_metadata_build_workspace: []byte

init_shard_segment_metadata_builder :: proc(
	ctx: ^Shard_Segment_Metadata_Build_Context,
	shard: int,
	start: Shard_High_Water_Requirements,
	start_known: bool = true,
) -> bool {
	if ctx == nil || shard < 0 || shard >= LOGICAL_SHARD_COUNT do return false
	ctx^ = {
		shard       = shard,
		previous    = start,
		start       = start,
		start_known = start_known,
		keys        = make(map[string]u32),
		owned_keys  = make([dynamic][]byte),
		records     = make([dynamic]Shard_Segment_Metadata_Record),
		ok          = true,
	}
	return true
}

destroy_shard_segment_metadata_builder :: proc(ctx: ^Shard_Segment_Metadata_Build_Context) {
	if ctx == nil do return
	for key in ctx.owned_keys do delete(key)
	for &record in ctx.records do delete(record.key_indices)
	delete(ctx.owned_keys); delete(ctx.records); delete(ctx.keys); ctx^ = {}
}

collect_shard_segment_metadata_record :: proc(ctx: ^Shard_Segment_Metadata_Build_Context, view: ^Shard_Transaction_View, physical_size: u64) -> bool {
	if ctx == nil || view == nil || !ctx.ok || ctx.overflow || physical_size == 0 || physical_size > u64(max(u32)) || physical_size > max(u64) - ctx.offset do return false
	// The caller has already decoded and validated this view.
	if int(shard_for_workspace(view.workspace)) != ctx.shard do return false
	reserve := SHARD_SEGMENT_METADATA_RECORD_SIZE + int(view.mutation_count) * 4
	bloom_size, bloom_ok := shard_segment_metadata_bloom_size(len(ctx.keys))
	base := SHARD_SEGMENT_METADATA_HEADER_SIZE + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE + bloom_size
	if !bloom_ok ||
	   reserve > SHARD_SEGMENT_METADATA_MAX_BYTES ||
	   ctx.key_bytes + ctx.table_bytes > SHARD_SEGMENT_METADATA_MAX_BYTES - base - reserve {ctx.overflow = true; return false}
	append(
		&ctx.records,
		Shard_Segment_Metadata_Record {
			offset = ctx.offset,
			physical_size = u32(physical_size),
			synthetic = view.mutation_count == 0,
			key_indices = make([dynamic]u32, 0, int(view.mutation_count)),
		},
	)
	shard_segment_metadata_build_workspace = view.workspace
	visited := visit_shard_transaction_mutations(view, shard_segment_metadata_collect_mutation, ctx)
	shard_segment_metadata_build_workspace = nil
	if !visited || !ctx.ok || ctx.overflow do return false
	ctx.table_bytes += SHARD_SEGMENT_METADATA_RECORD_SIZE + len(ctx.records[len(ctx.records) - 1].key_indices) * 4
	ctx.offset += physical_size
	ctx.previous = {view.task_high_water, view.asset_high_water, view.edge_high_water}
	return true
}

shard_segment_metadata_scan_record :: proc(op: u8, version: u16, payload: []byte, physical_size: int) -> bool {
	ctx := &shard_segment_metadata_build_context
	if op != u8(Shard_Log_Op.Transaction) || version != SHARD_WAL_VERSION do return false
	view, decode_err := decode_shard_transaction(payload)
	if decode_err != .None || int(shard_for_workspace(view.workspace)) != ctx.shard do return false
	next, validate_err := validate_shard_transaction_view(&view, ctx.previous)
	if validate_err != .None do return false
	if next != (Shard_High_Water_Requirements{view.task_high_water, view.asset_high_water, view.edge_high_water}) do return false
	return collect_shard_segment_metadata_record(ctx, &view, u64(physical_size))
}

finalize_shard_segment_metadata_builder :: proc(
	ctx: ^Shard_Segment_Metadata_Build_Context,
	descriptor: Shard_Segment_Descriptor,
	segment_size: u64,
) -> (
	metadata: Shard_Segment_Metadata,
	ok: bool,
) {
	if ctx == nil || !ctx.ok || ctx.overflow || ctx.offset != segment_size do return
	metadata = {
		shard        = ctx.shard,
		descriptor   = shard_segment_descriptor_physical_identity(descriptor),
		segment_size = segment_size,
		start        = ctx.start,
		start_known  = ctx.start_known,
		end          = ctx.previous,
		keys         = ctx.owned_keys,
		records      = ctx.records,
	}
	ctx.owned_keys = nil; ctx.records = nil
	remap := make([]u32, len(metadata.keys), context.temp_allocator)
	indexed := make([]Shard_Segment_Metadata_Indexed_Key, len(metadata.keys), context.temp_allocator)
	for key, i in metadata.keys do indexed[i] = {key, u32(i)}
	slice.sort_by(indexed, proc(a, b: Shard_Segment_Metadata_Indexed_Key) -> bool {return shard_segment_metadata_key_less(a.key, b.key)})
	for item, i in indexed {metadata.keys[i] = item.key; remap[item.insertion] = u32(i)}
	for &record in metadata.records {for &index in record.key_indices do index = remap[index]; slice.sort(record.key_indices[:])}
	bloom_size, bloom_ok := shard_segment_metadata_bloom_size(len(metadata.keys)); if !bloom_ok do return
	metadata.bloom = make([]byte, bloom_size); for key in metadata.keys do _ = shard_segment_metadata_bloom_apply(metadata.bloom, key, true)
	if !shard_segment_metadata_is_valid(&metadata) {destroy_shard_segment_metadata(&metadata); return}
	return metadata, true
}

build_shard_segment_metadata :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	shard: int,
	descriptor: Shard_Segment_Descriptor,
	segment_size: u64,
	start: Shard_High_Water_Requirements,
) -> (
	metadata: Shard_Segment_Metadata,
	read_bytes: u64,
	ok: bool,
) {
	identity := shard_segment_descriptor_physical_identity(descriptor)
	if shard < 0 || shard >= LOGICAL_SHARD_COUNT || !shard_segment_descriptor_is_valid(identity) do return
	path := shard_segment_descriptor_path(shard_dir, identity); defer delete(path)
	ctx: Shard_Segment_Metadata_Build_Context
	if !init_shard_segment_metadata_builder(&ctx, shard, start) do return
	defer destroy_shard_segment_metadata_builder(&ctx)
	shard_segment_metadata_build_context = ctx
	inspection := persistence.inspect_wal_file_strict_sized(storage, path, SHARD_WAL_MAGIC, shard, shard_segment_metadata_scan_record)
	ctx = shard_segment_metadata_build_context; shard_segment_metadata_build_context = {}
	read_bytes = inspection.file_size
	if !inspection.ok || inspection.file_size != segment_size || ctx.overflow do return
	metadata, ok = finalize_shard_segment_metadata_builder(&ctx, identity, segment_size)
	return metadata, read_bytes, ok
}

write_shard_segment_metadata :: proc(storage: storage_io.Context, shard_dir: string, metadata: ^Shard_Segment_Metadata) -> (encoded_bytes: u64, ok: bool) {
	size, size_ok := shard_segment_metadata_encoded_size(metadata); if !size_ok do return
	data := make([]byte, size); defer delete(data); if !encode_shard_segment_metadata(metadata, data) do return
	temp := shard_segment_metadata_temp_path(shard_dir, metadata.descriptor); defer delete(temp)
	final := shard_segment_metadata_path(shard_dir, metadata.descriptor); defer delete(final)
	_ = storage_io.remove(storage, temp)
	defer if !ok do _ = storage_io.remove(storage, temp)
	file, open_err := storage_io.open(storage, temp, {.Write, .Create, .Excl}, os.perm(0o644)); if open_err != nil do return
	written := 0
	write_ok := true
	for written < len(data) {
		count, write_err := storage_io.write(file, data[written:])
		if write_err != nil || count <= 0 {write_ok = false; break}
		written += count
	}
	synced := write_ok && storage_io.sync(file) == nil; close_err := storage_io.close(file)
	if !write_ok || written != len(data) || !synced || close_err != nil do return
	if storage_io.rename(storage, temp, final) != nil do return
	if storage_io.sync_directory(storage, shard_dir) != nil do return
	return u64(size), true
}

// Any failure is a cache miss. The caller's expected identity, size, and floor
// are checked after the checksummed file has been fully decoded.
load_shard_segment_metadata :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	shard: int,
	descriptor: Shard_Segment_Descriptor,
	segment_size: u64,
	start: Shard_High_Water_Requirements,
	allocation_budget: u64 = 0,
) -> (
	metadata: Shard_Segment_Metadata,
	read_bytes: u64,
	ok: bool,
) {
	identity := shard_segment_descriptor_physical_identity(descriptor)
	path := shard_segment_metadata_path(shard_dir, identity); defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Read}); if open_err != nil do return
	defer storage_io.discard(file)
	size, size_err := storage_io.file_size(
		file,
	); if size_err != nil || size < SHARD_SEGMENT_METADATA_HEADER_SIZE + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE || size > SHARD_SEGMENT_METADATA_MAX_BYTES do return
	if allocation_budget > 0 && u64(size) > allocation_budget / SHARD_SEGMENT_METADATA_DECODED_ESTIMATE_MULTIPLIER do return
	data := make([]byte, int(size), context.temp_allocator)
	read := 0
	for read < len(data) {n, err := storage_io.read_at(file, data[read:], read); if err != nil || n <= 0 do return; read += n}
	read_bytes = u64(read)
	metadata, ok = decode_shard_segment_metadata(data)
	if !ok do return
	if metadata.shard != shard || metadata.descriptor != identity || metadata.segment_size != segment_size || metadata.start_known && metadata.start != start {
		destroy_shard_segment_metadata(&metadata); ok = false
	}
	return
}

load_shard_segment_metadata_summary :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	shard: int,
	descriptor: Shard_Segment_Descriptor,
	segment_size: u64,
	expected_start: ^Shard_High_Water_Requirements = nil,
) -> (
	summary: Shard_Segment_Metadata_Summary,
	read_bytes: u64,
	ok: bool,
) {
	identity := shard_segment_descriptor_physical_identity(descriptor)
	path := shard_segment_metadata_path(shard_dir, identity)
	defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return
	defer storage_io.discard(file)
	file_size, size_err := storage_io.file_size(file)
	if size_err != nil || file_size < SHARD_SEGMENT_METADATA_HEADER_SIZE + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE || file_size > SHARD_SEGMENT_METADATA_MAX_BYTES do return
	header: [SHARD_SEGMENT_METADATA_HEADER_SIZE]byte
	if !shard_segment_read_exact_at(file, header[:], 0) do return
	read_bytes = SHARD_SEGMENT_METADATA_HEADER_SIZE
	magic, _ := endian.get_u32(header[:], .Big)
	version, _ := endian.get_u16(header[4:], .Big)
	encoded_shard, _ := endian.get_u16(header[6:], .Big)
	generation, _ := endian.get_u64(header[16:], .Big)
	encoded_segment_size, _ := endian.get_u64(header[24:], .Big)
	key_count, _ := endian.get_u32(header[80:], .Big)
	bloom_size, _ := endian.get_u32(header[84:], .Big)
	if magic != SHARD_SEGMENT_METADATA_MAGIC ||
	   version != SHARD_SEGMENT_METADATA_VERSION ||
	   int(encoded_shard) != shard ||
	   Shard_Segment_Kind(header[8]) != identity.kind ||
	   generation != identity.generation ||
	   encoded_segment_size != segment_size ||
	   key_count > SHARD_SEGMENT_METADATA_MAX_KEYS {
		return
	}
	if header[9] > 1 do return
	for b in header[10:16] do if b != 0 do return
	expected_bloom_size, bloom_ok := shard_segment_metadata_bloom_size(int(key_count))
	if !bloom_ok || int(bloom_size) != expected_bloom_size || SHARD_SEGMENT_METADATA_HEADER_SIZE + int(bloom_size) + SHARD_SEGMENT_METADATA_CHECKSUM_SIZE > int(file_size) do return
	summary = {
		shard        = shard,
		descriptor   = identity,
		segment_size = segment_size,
		key_count    = int(key_count),
		bloom        = make([]byte, int(bloom_size)),
	}
	loaded := false
	defer if !loaded do destroy_shard_segment_metadata_summary(&summary)
	summary.start.task, _ = endian.get_u64(header[32:], .Big)
	summary.start_known = header[9] == 1
	summary.start.asset, _ = endian.get_u64(header[40:], .Big)
	summary.start.edge, _ = endian.get_u64(header[48:], .Big)
	summary.end.task, _ = endian.get_u64(header[56:], .Big)
	summary.end.asset, _ = endian.get_u64(header[64:], .Big)
	summary.end.edge, _ = endian.get_u64(header[72:], .Big)
	if summary.start_known && (summary.end.task < summary.start.task || summary.end.asset < summary.start.asset || summary.end.edge < summary.start.edge) || expected_start != nil && summary.start_known && summary.start != expected_start^ do return
	if len(summary.bloom) > 0 && !shard_segment_read_exact_at(file, summary.bloom, SHARD_SEGMENT_METADATA_HEADER_SIZE) do return
	read_bytes += u64(len(summary.bloom))
	checksum, _ := endian.get_u64(header[88:], .Big)
	endian.put_u64(header[88:], .Big, 0)
	checksum_data := make([]byte, len(header) + len(summary.bloom), context.temp_allocator)
	copy(checksum_data, header[:])
	copy(checksum_data[len(header):], summary.bloom)
	if checksum != xxhash.XXH64(checksum_data) do return
	loaded = true
	return summary, read_bytes, true
}
