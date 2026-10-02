package main

import "core:encoding/endian"

import "persistence"
import "storage_io"

SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES :: 1024 * 1024 * 1024
SHARD_CLEANED_SEGMENT_MAX_BYTES :: #config(NRC_SHARD_CLEANED_SEGMENT_MAX_BYTES, 500 * 1024 * 1024)
SHARD_SEGMENT_CLEAN_MIN_DIRTY_PERCENT :: #config(NRC_SHARD_SEGMENT_CLEAN_MIN_DIRTY_PERCENT, 20)
SHARD_RAW_COPY_METADATA_MAX_BYTES :: #config(NRC_SHARD_RAW_COPY_METADATA_MAX_BYTES, 32 * 1024 * 1024)
SHARD_SEGMENT_METADATA_INDEX_ENABLED :: #config(NRC_SHARD_SEGMENT_METADATA_INDEX_ENABLED, true)
SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES :: #config(NRC_SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES, 256 * 1024 * 1024)

Shard_Segment_Key_Storage :: struct {
	latest: map[string]u64,
	owned:  [dynamic][]byte,
}

shard_segment_key_storage_destroy :: proc(storage: ^Shard_Segment_Key_Storage) {
	for key in storage.owned do delete(key)
	delete(storage.owned)
	delete(storage.latest)
	storage^ = {}
}

shard_segment_mutation_conversation_id :: proc(mutation: Shard_Mutation) -> (conversation_id: u64, ok: bool) {
	if mutation.op == u8(Task_Log_Op.Delete) && mutation.domain == .Task ||
	   mutation.op == u8(Asset_Log_Op.Delete) && mutation.domain == .Asset ||
	   mutation.op == u8(Edge_Log_Op.Delete) && mutation.domain == .Edge {
		if len(mutation.payload) != 16 do return
		conversation_id, _ = endian.get_u64(mutation.payload, .Big)
		return conversation_id, true
	}
	switch mutation.domain {
	case .Task:
		o := 0
		for o < len(mutation.payload) {
			if len(mutation.payload) - o < 3 do return
			tag := mutation.payload[o]
			size, _ := endian.get_u16(mutation.payload[o + 1:], .Big)
			o += 3
			if int(size) > len(mutation.payload) - o do return
			if tag == u8(Task_Field_Tag.ConvID) {
				if size != 8 do return
				conversation_id, _ = endian.get_u64(mutation.payload[o:], .Big)
				return conversation_id, true
			}
			o += int(size)
		}
	case .Asset:
		if len(mutation.payload) < 22 do return
		owner_size, _ := endian.get_u16(mutation.payload[20:], .Big)
		conversation_offset := 22 + int(owner_size) + 16
		if conversation_offset > len(mutation.payload) - 8 do return
		conversation_id, _ = endian.get_u64(mutation.payload[conversation_offset:], .Big)
		return conversation_id, true
	case .Edge:
		if len(mutation.payload) < 16 do return
		conversation_id, _ = endian.get_u64(mutation.payload[8:], .Big)
		return conversation_id, true
	}
	return
}

shard_segment_entity_key :: proc(workspace: []byte, mutation: Shard_Mutation) -> (key: []byte, ok: bool) {
	id, id_ok := shard_mutation_entity_id(mutation)
	conversation_id, conversation_ok := shard_segment_mutation_conversation_id(mutation)
	if !id_ok || !conversation_ok do return
	// Keep original scopes in raw compaction keys. This preserves collision
	// evidence and legacy records until validated semantic checkpoint replay.
	// A canonical tombstone remains a distinct last mutation in source order.
	key = make([]byte, 17 + len(workspace))
	key[0] = byte(mutation.domain)
	endian.put_u64(key[1:], .Big, conversation_id)
	endian.put_u64(key[9:], .Big, id)
	copy(key[17:], workspace)
	return key, true
}

Shard_Segment_Latest_Visit_Context :: struct {
	storage:         ^Shard_Segment_Key_Storage,
	workspace:       []byte,
	position:        u64,
	graph_sensitive: bool,
	append_only:     bool,
	append_floors:   Shard_High_Water_Requirements,
	ok:              bool,
}

shard_segment_record_latest_mutation :: proc(mutation: Shard_Mutation, user_data: rawptr) -> bool {
	ctx := cast(^Shard_Segment_Latest_Visit_Context)user_data
	key, key_ok := shard_segment_entity_key(ctx.workspace, mutation)
	if !key_ok {ctx.ok = false; return false}
	lookup := transmute(string)key
	if existing := &ctx.storage.latest[lookup]; existing != nil {
		existing^ = ctx.position
		delete(key)
	} else {
		ctx.storage.latest[lookup] = ctx.position
		append(&ctx.storage.owned, key)
	}
	ctx.graph_sensitive = ctx.graph_sensitive || shard_segment_mutation_requires_exact_raw_retention(mutation)
	ctx.append_only = ctx.append_only && shard_mutation_advances_append_only_floor(mutation, &ctx.append_floors)
	return true
}

Shard_Segment_Copy_Visit_Context :: struct {
	latest:                 ^map[string]u64,
	workspace:              []byte,
	position:               u64,
	retain:                 bool,
	retain_graph_sensitive: bool,
	ok:                     bool,
}

shard_segment_mutation_requires_exact_raw_retention :: proc(mutation: Shard_Mutation) -> bool {
	return(
		mutation.domain == .Edge ||
		mutation.domain == .Task && mutation.op == u8(Task_Log_Op.Delete) ||
		mutation.domain == .Asset && mutation.op == u8(Asset_Log_Op.Delete) \
	)
}

shard_segment_record_is_latest_mutation :: proc(mutation: Shard_Mutation, user_data: rawptr) -> bool {
	ctx := cast(^Shard_Segment_Copy_Visit_Context)user_data
	key, key_ok := shard_segment_entity_key(ctx.workspace, mutation)
	if !key_ok {ctx.ok = false; return false}
	latest, found := ctx.latest^[transmute(string)key]
	delete(key)
	if !found {ctx.ok = false; return false}
	if latest == ctx.position || ctx.retain_graph_sensitive && shard_segment_mutation_requires_exact_raw_retention(mutation) {
		ctx.retain = true
	}
	return true
}

Shard_Segment_Clean_Scan_Mode :: enum u8 {
	Latest,
	Measure,
	Copy,
}

Shard_Raw_Record_Metadata :: struct {
	offset:          u64,
	physical_size:   u32,
	position:        u64,
	graph_sensitive: bool,
	synthetic:       bool,
}

Shard_Segment_Clean_Scan_Context :: struct {
	shard:                  int,
	previous:               Shard_High_Water_Requirements,
	position:               u64,
	mode:                   Shard_Segment_Clean_Scan_Mode,
	keys:                   ^Shard_Segment_Key_Storage,
	storage:                storage_io.Context,
	shard_dir:              string,
	builder:                persistence.WAL_File_Builder,
	outputs:                ^[dynamic]Shard_Segment_Descriptor,
	next_output_generation: u64,
	witness_reserve:        u64,
	output_max_bytes:       u64,
	retained_bytes:         u64,
	synthetic_bytes:        u64,
	retain_graph_sensitive: bool,
	capture_raw_metadata:   bool,
	raw_metadata_limit:     int,
	raw_metadata_overflow:  bool,
	raw_offset:             u64,
	raw_records:            ^[dynamic]Shard_Raw_Record_Metadata,
	raw_append_only:        bool,
	segment_metadata:       ^Shard_Segment_Metadata_Build_Context,
}

@(thread_local)
shard_segment_clean_scan_context: Shard_Segment_Clean_Scan_Context

shard_segment_remove_cache_file :: proc(storage: storage_io.Context, path: string) -> bool {
	exists, exists_err := storage_io.exists(storage, path)
	if exists_err != nil do return false
	if !exists do return true
	if storage_io.remove(storage, path) != nil do return false
	exists, exists_err = storage_io.exists(storage, path)
	return exists_err == nil && !exists
}

shard_segment_clean_start_output :: proc(ctx: ^Shard_Segment_Clean_Scan_Context) -> bool {
	if ctx.builder.active || ctx.next_output_generation == 0 do return false
	descriptor := Shard_Segment_Descriptor{.Cleaned_Segment, ctx.next_output_generation}
	metadata_path := shard_segment_metadata_path(ctx.shard_dir, descriptor)
	defer delete(metadata_path)
	metadata_temp_path := shard_segment_metadata_temp_path(ctx.shard_dir, descriptor)
	defer delete(metadata_temp_path)
	// A failed unpublished result may have used this generation. Invalidate
	// both cache names before replacing its temporary WAL.
	if !shard_segment_remove_cache_file(ctx.storage, metadata_path) || !shard_segment_remove_cache_file(ctx.storage, metadata_temp_path) {
		return false
	}
	path := shard_cleaned_segment_temp_path(ctx.shard_dir, ctx.next_output_generation)
	defer delete(path)
	_ = storage_io.remove(ctx.storage, path)
	return persistence.create_wal_file_builder(&ctx.builder, ctx.storage, path, SHARD_WAL_MAGIC, SHARD_WAL_VERSION)
}

shard_segment_clean_finish_output :: proc(ctx: ^Shard_Segment_Clean_Scan_Context) -> bool {
	if !ctx.builder.active || !persistence.finish_wal_file_builder(&ctx.builder) do return false
	if len(ctx.outputs^) >= SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return false
	_, append_err := append(ctx.outputs, Shard_Segment_Descriptor{.Cleaned_Segment, ctx.next_output_generation})
	if append_err != nil || ctx.next_output_generation == max(u64) do return false
	ctx.next_output_generation += 1
	return true
}

shard_segment_clean_append_payload :: proc(ctx: ^Shard_Segment_Clean_Scan_Context, op: u8, payload: []byte) -> bool {
	record_bytes := u64(persistence.LOG_HEADER_SIZE + len(payload))
	if !ctx.builder.active && !shard_segment_clean_start_output(ctx) do return false
	if ctx.builder.record_count > 0 && ctx.builder.file_size + record_bytes + ctx.witness_reserve > ctx.output_max_bytes {
		if !shard_segment_clean_finish_output(ctx) || !shard_segment_clean_start_output(ctx) do return false
	}
	if record_bytes > ctx.output_max_bytes do return false
	record := make([]byte, int(record_bytes))
	defer delete(record)
	copy(record[persistence.LOG_HEADER_SIZE:], payload)
	return persistence.append_wal_file_builder(&ctx.builder, op, record)
}

shard_segment_clean_scan_record :: proc(op: u8, version: u16, payload: []byte, physical_record_size: int) -> bool {
	ctx := &shard_segment_clean_scan_context
	if op != u8(Shard_Log_Op.Transaction) || version != SHARD_WAL_VERSION do return false
	view, decode_err := decode_shard_transaction(payload)
	if decode_err != .None || int(shard_for_workspace(view.workspace)) != ctx.shard do return false
	next, validate_err := validate_shard_transaction_view(&view, ctx.previous)
	if validate_err != .None do return false
	ctx.position += 1
	switch ctx.mode {
	case .Latest:
		visit := Shard_Segment_Latest_Visit_Context {
			storage       = ctx.keys,
			workspace     = view.workspace,
			position      = ctx.position,
			append_only   = true,
			append_floors = ctx.previous,
			ok            = true,
		}
		if !visit_shard_transaction_mutations(&view, shard_segment_record_latest_mutation, &visit) || !visit.ok do return false
		ctx.raw_append_only = ctx.raw_append_only && view.mutation_count > 0 && visit.append_only
		if ctx.capture_raw_metadata && !ctx.raw_metadata_overflow {
			metadata_size := size_of(Shard_Raw_Record_Metadata)
			if physical_record_size < 0 ||
			   u64(physical_record_size) > u64(max(u32)) ||
			   ctx.raw_metadata_limit < metadata_size ||
			   len(ctx.raw_records^) >= ctx.raw_metadata_limit / metadata_size {
				delete(ctx.raw_records^)
				ctx.raw_records^ = make([dynamic]Shard_Raw_Record_Metadata)
				ctx.raw_metadata_overflow = true
			} else {
				_, append_err := append(
					ctx.raw_records,
					Shard_Raw_Record_Metadata {
						offset = ctx.raw_offset,
						physical_size = u32(physical_record_size),
						position = ctx.position,
						graph_sensitive = visit.graph_sensitive,
						synthetic = view.mutation_count == 0,
					},
				)
				if append_err != nil do return false
			}
		}
	case .Measure, .Copy:
		visit := Shard_Segment_Copy_Visit_Context {
			latest                 = &ctx.keys.latest,
			workspace              = view.workspace,
			position               = ctx.position,
			retain_graph_sensitive = ctx.retain_graph_sensitive,
			ok                     = true,
		}
		if !visit_shard_transaction_mutations(&view, shard_segment_record_is_latest_mutation, &visit) || !visit.ok do return false
		if (ctx.mode == .Measure || ctx.mode == .Copy) && view.mutation_count == 0 {
			ctx.synthetic_bytes += u64(physical_record_size)
		}
		if visit.retain {
			physical_bytes := u64(physical_record_size)
			ctx.retained_bytes += physical_bytes
			if ctx.mode == .Copy {
				if !shard_segment_clean_append_payload(ctx, u8(Shard_Log_Op.Transaction), payload) do return false
			}
		}
	}
	ctx.previous = next
	if ctx.segment_metadata != nil && !collect_shard_segment_metadata_record(ctx.segment_metadata, &view, u64(physical_record_size)) {
		// Metadata is a rebuildable cache; its size/allocation limits must not
		// turn an otherwise valid normalization scan into a compaction failure.
		ctx.segment_metadata = nil
	}
	if ctx.capture_raw_metadata {
		if u64(physical_record_size) > max(u64) - ctx.raw_offset do return false
		ctx.raw_offset += u64(physical_record_size)
	}
	return true
}

shard_segment_metadata_apply_latest :: proc(metadata: ^Shard_Segment_Metadata, keys: ^Shard_Segment_Key_Storage, position: ^u64) -> bool {
	if metadata == nil || keys == nil || position == nil do return false
	for &record in metadata.records {
		if position^ == max(u64) do return false
		position^ += 1
		for index in record.key_indices {
			key := metadata.keys[index]
			lookup := transmute(string)key
			if existing := &keys.latest[lookup]; existing != nil {
				existing^ = position^
				continue
			}
			owned := make([]byte, len(key))
			copy(owned, key)
			keys.latest[transmute(string)owned] = position^
			append(&keys.owned, owned)
		}
	}
	return true
}

shard_segment_metadata_record_retained :: proc(
	metadata: ^Shard_Segment_Metadata,
	record: ^Shard_Segment_Metadata_Record,
	keys: ^Shard_Segment_Key_Storage,
	position: u64,
) -> bool {
	for index in record.key_indices {
		latest, found := keys.latest[transmute(string)metadata.keys[index]]
		if found && latest == position do return true
	}
	return false
}

shard_segment_metadata_retained_bytes :: proc(
	metadata: ^Shard_Segment_Metadata,
	keys: ^Shard_Segment_Key_Storage,
	position: ^u64,
) -> (
	retained_bytes, synthetic_bytes: u64,
	ok: bool,
) {
	if metadata == nil || keys == nil || position == nil do return
	for &record in metadata.records {
		if position^ == max(u64) do return
		position^ += 1
		physical_size := u64(record.physical_size)
		if record.synthetic {
			if physical_size > max(u64) - synthetic_bytes do return
			synthetic_bytes += physical_size
		} else if shard_segment_metadata_record_retained(metadata, &record, keys, position^) {
			if physical_size > max(u64) - retained_bytes do return
			retained_bytes += physical_size
		}
	}
	return retained_bytes, synthetic_bytes, true
}

shard_segment_clean_scan_file :: proc(storage: storage_io.Context, path: string, ctx: ^Shard_Segment_Clean_Scan_Context) -> bool {
	shard_segment_clean_scan_context = ctx^
	inspection := persistence.inspect_wal_file_strict_sized(storage, path, SHARD_WAL_MAGIC, ctx.shard, shard_segment_clean_scan_record)
	ctx^ = shard_segment_clean_scan_context
	shard_segment_clean_scan_context = {}
	return inspection.ok
}

shard_segment_read_exact_at :: proc(file: ^storage_io.File, out: []byte, offset: int) -> bool {
	read := 0
	for read < len(out) {
		count, read_err := storage_io.read_at(file, out[read:], offset + read)
		if read_err != nil || count <= 0 do return false
		read += count
	}
	return true
}

shard_segment_clean_copy_retained_raw_records :: proc(
	storage: storage_io.Context,
	path: string,
	expected_size: u64,
	records: []Shard_Raw_Record_Metadata,
	keys: ^Shard_Segment_Key_Storage,
	ctx: ^Shard_Segment_Clean_Scan_Context,
) -> bool {
	if expected_size > u64(max(int)) do return false
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return false
	defer storage_io.discard(file)
	file_size, size_err := storage_io.file_size(file)
	if size_err != nil || file_size < 0 || u64(file_size) != expected_size do return false
	retained_positions := make(map[u64]bool, len(keys.latest))
	defer delete(retained_positions)
	for _, position in keys.latest do retained_positions[position] = true
	for metadata in records {
		if metadata.synthetic {
			ctx.synthetic_bytes += u64(metadata.physical_size)
			continue
		}
		if !metadata.graph_sensitive && !retained_positions[metadata.position] do continue
		if metadata.offset > u64(max(int)) || u64(metadata.physical_size) > expected_size - min(expected_size, metadata.offset) do return false
		record := make([]byte, int(metadata.physical_size))
		read_ok := shard_segment_read_exact_at(file, record, int(metadata.offset))
		if !read_ok || len(record) < persistence.LEGACY_LOG_HEADER_SIZE {
			delete(record)
			return false
		}
		magic, _ := endian.get_u32(record, .Big)
		version, _ := endian.get_u16(record[4:], .Big)
		payload_size, _ := endian.get_u32(record[8:], .Big)
		header_size := persistence.LEGACY_LOG_HEADER_SIZE
		if record[7] == persistence.LOG_FLAG_CHECKSUM_XXH64 {
			header_size = persistence.LOG_HEADER_SIZE
		} else if record[7] != 0 {
			delete(record)
			return false
		}
		valid :=
			magic == SHARD_WAL_MAGIC &&
			version == SHARD_WAL_VERSION &&
			record[6] == u8(Shard_Log_Op.Transaction) &&
			payload_size <= persistence.MAX_WAL_PAYLOAD_SIZE &&
			header_size + int(payload_size) == len(record)
		if valid do valid = persistence.validate_record_checksum_alloc(record, int(payload_size))
		if !valid || !shard_segment_clean_append_payload(ctx, record[6], record[header_size:]) {
			delete(record)
			return false
		}
		delete(record)
		ctx.retained_bytes += u64(metadata.physical_size)
	}
	final_size, final_size_err := storage_io.file_size(file)
	return final_size_err == nil && final_size >= 0 && u64(final_size) == expected_size
}

shard_segment_clean_copy_retained_metadata_records :: proc(
	storage: storage_io.Context,
	path: string,
	metadata: ^Shard_Segment_Metadata,
	keys: ^Shard_Segment_Key_Storage,
	position: ^u64,
	ctx: ^Shard_Segment_Clean_Scan_Context,
) -> (
	read_bytes: u64,
	ok: bool,
) {
	if metadata == nil || keys == nil || position == nil || ctx == nil || metadata.segment_size > u64(max(int)) do return
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return
	defer storage_io.discard(file)
	file_size, size_err := storage_io.file_size(file)
	if size_err != nil || file_size < 0 || u64(file_size) != metadata.segment_size do return
	for &record_metadata in metadata.records {
		if position^ == max(u64) do return
		position^ += 1
		if record_metadata.synthetic {
			ctx.synthetic_bytes += u64(record_metadata.physical_size)
			continue
		}
		if !shard_segment_metadata_record_retained(metadata, &record_metadata, keys, position^) do continue
		if record_metadata.offset > u64(max(int)) ||
		   u64(record_metadata.physical_size) > metadata.segment_size - min(metadata.segment_size, record_metadata.offset) {
			return
		}
		record := make([]byte, int(record_metadata.physical_size))
		read_ok := shard_segment_read_exact_at(file, record, int(record_metadata.offset))
		if !read_ok || len(record) < persistence.LEGACY_LOG_HEADER_SIZE {
			delete(record)
			return
		}
		magic, _ := endian.get_u32(record, .Big)
		version, _ := endian.get_u16(record[4:], .Big)
		payload_size, _ := endian.get_u32(record[8:], .Big)
		header_size := persistence.LEGACY_LOG_HEADER_SIZE
		if record[7] == persistence.LOG_FLAG_CHECKSUM_XXH64 {
			header_size = persistence.LOG_HEADER_SIZE
		} else if record[7] != 0 {
			delete(record)
			return
		}
		valid :=
			magic == SHARD_WAL_MAGIC &&
			version == SHARD_WAL_VERSION &&
			record[6] == u8(Shard_Log_Op.Transaction) &&
			payload_size <= persistence.MAX_WAL_PAYLOAD_SIZE &&
			header_size + int(payload_size) == len(record)
		if valid do valid = persistence.validate_record_checksum_alloc(record, int(payload_size))
		if !valid || !shard_segment_clean_append_payload(ctx, record[6], record[header_size:]) {
			delete(record)
			return
		}
		delete(record)
		physical_size := u64(record_metadata.physical_size)
		ctx.retained_bytes += physical_size
		read_bytes += physical_size
	}
	final_size, final_size_err := storage_io.file_size(file)
	return read_bytes, final_size_err == nil && final_size >= 0 && u64(final_size) == metadata.segment_size
}

shard_segment_raw_retained_bytes :: proc(
	records: []Shard_Raw_Record_Metadata,
	keys: ^Shard_Segment_Key_Storage,
) -> (
	retained_bytes: u64,
	synthetic_bytes: u64,
	ok: bool,
) {
	if keys == nil do return
	retained_positions := make(map[u64]bool, len(keys.latest), context.temp_allocator)
	for _, position in keys.latest do retained_positions[position] = true
	for metadata in records {
		physical_size := u64(metadata.physical_size)
		if metadata.synthetic {
			if physical_size > max(u64) - synthetic_bytes do return
			synthetic_bytes += physical_size
		} else if metadata.graph_sensitive || retained_positions[metadata.position] {
			if physical_size > max(u64) - retained_bytes do return
			retained_bytes += physical_size
		}
	}
	return retained_bytes, synthetic_bytes, true
}

shard_segment_descriptor_size :: proc(storage: storage_io.Context, shard_dir: string, descriptor: Shard_Segment_Descriptor) -> (u64, bool) {
	path := shard_segment_descriptor_path(shard_dir, descriptor)
	if path == "" do return 0, false
	defer delete(path)
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return 0, false
	defer storage_io.discard(file)
	size, size_err := storage_io.file_size(file)
	return u64(size), size_err == nil && size >= 0
}

Shard_Segment_Clean_Source :: struct {
	shard:    int,
	segments: [dynamic]Shard_Segment_Descriptor,
}

destroy_shard_segment_clean_source :: proc(source: ^Shard_Segment_Clean_Source) {
	if source == nil do return
	delete(source.segments)
	source^ = {}
}

clone_shard_segment_clean_source :: proc(source: Shard_Segment_Clean_Source) -> (clone: Shard_Segment_Clean_Source, ok: bool) {
	clone.shard = source.shard
	clone.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments))
	copy(clone.segments[:], source.segments[:])
	return clone, true
}

shard_segment_source_for_manifest :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
) -> (
	source: Shard_Segment_Clean_Source,
	ok: bool,
) {
	source.shard = manifest.shard
	source.segments = make([dynamic]Shard_Segment_Descriptor)
	loaded := false
	defer if !loaded do destroy_shard_segment_clean_source(&source)
	if manifest.segmented {
		catalog, catalog_ok := load_shard_segment_catalog(storage, shard_dir, manifest.checkpoint_generation)
		if !catalog_ok do return
		defer destroy_shard_segment_catalog(&catalog)
		if catalog.shard != manifest.shard do return
		if _, append_err := append(&source.segments, ..catalog.segments[:]); append_err != nil do return
	} else if manifest.checkpoint_present {
		append(&source.segments, Shard_Segment_Descriptor{.Legacy_Checkpoint_WAL, manifest.checkpoint_generation})
	}
	if manifest.sealed_present {
		if len(source.segments) >= SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return
		append(&source.segments, Shard_Segment_Descriptor{.Generation_WAL, manifest.sealed_generation})
	}
	loaded = true
	return source, true
}

shard_segment_source_for_writer :: proc(writer: ^Shard_Transaction_Writer) -> (source: Shard_Segment_Clean_Source, ok: bool) {
	if writer == nil || !writer.managed do return
	if !writer.manifest.segmented {
		return shard_segment_source_for_manifest(writer.storage, writer.shard_dir, writer.manifest)
	}
	if writer.catalog.shard != writer.shard || writer.catalog.catalog_generation != writer.manifest.checkpoint_generation do return
	source.shard = writer.shard
	source.segments = make([dynamic]Shard_Segment_Descriptor, len(writer.catalog.segments) + (writer.manifest.sealed_present ? 1 : 0))
	copy(source.segments[:len(writer.catalog.segments)], writer.catalog.segments[:])
	if writer.manifest.sealed_present {
		source.segments[len(writer.catalog.segments)] = {.Generation_WAL, writer.manifest.sealed_generation}
	}
	return source, true
}

shard_segment_catalog_replay :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	catalog: Shard_Segment_Catalog,
	apply: bool,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	for descriptor in catalog.segments {
		path := shard_segment_descriptor_path(shard_dir, descriptor)
		if path == "" do return floors, false
		_, floors, ok = scan_shard_transaction_wal(storage, path, catalog.shard, floors, apply, false)
		delete(path)
		if !ok do return
	}
	if apply && !validate_replayed_shard_edges(catalog.shard) do return floors, false
	return floors, true
}

shard_segment_source_replay :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	source: Shard_Segment_Clean_Source,
	apply: bool,
) -> (
	floors: Shard_High_Water_Requirements,
	ok: bool,
) {
	origins: Workspace_Data_Replay_Origins
	owns_origins := workspace_data_origins_begin(&origins)
	defer workspace_data_origins_end(&origins, owns_origins)
	for descriptor in source.segments {
		path := shard_segment_descriptor_path(shard_dir, descriptor)
		if path == "" do return floors, false
		_, floors, ok = scan_shard_transaction_wal(storage, path, source.shard, floors, apply, false)
		delete(path)
		if !ok do return
	}
	if apply && !validate_replayed_shard_edges(source.shard) do return floors, false
	return floors, true
}

shard_segment_floor_witness :: proc(
	shard: int,
	floors: Shard_High_Water_Requirements,
) -> (
	tx: Shard_Transaction,
	workspace: string,
	record_size: int,
	ok: bool,
) {
	workspace = shard_checkpoint_floor_witness(shard)
	if workspace == "" do return
	tx = {
		workspace        = transmute([]byte)workspace,
		task_high_water  = floors.task,
		asset_high_water = floors.asset,
		edge_high_water  = floors.edge,
	}
	payload_size, size_err := shard_transaction_size(&tx)
	if size_err != .None do return
	return tx, workspace, persistence.LOG_HEADER_SIZE + payload_size, true
}

shard_segment_append_floor_witness :: proc(builder: ^persistence.WAL_File_Builder, tx: ^Shard_Transaction, record_size: int) -> bool {
	record := make([]byte, record_size)
	defer delete(record)
	if encode_shard_transaction(tx, record[persistence.LOG_HEADER_SIZE:]) != .None do return false
	return persistence.append_wal_file_builder(builder, u8(Shard_Log_Op.Transaction), record)
}

Shard_Segment_Clean_Result :: struct {
	catalog:                Shard_Segment_Catalog,
	removed_start:          int,
	removed_count:          int,
	removed:                [dynamic]Shard_Segment_Descriptor,
	outputs:                [dynamic]Shard_Segment_Descriptor,
	output_present:         bool,
	output_generation:      u64,
	input_bytes:            u64,
	dirty_bytes:            u64,
	prefix_read_bytes:      u64,
	latest_read_bytes:      u64,
	measure_read_bytes:     u64,
	copy_read_bytes:        u64,
	replay_read_bytes:      u64,
	metadata_fallbacks:     u64,
	metadata_written_bytes: u64,
	next_cursor:            int,
	floors:                 Shard_High_Water_Requirements,
	raw_fast_path_used:     bool,
	raw_direct_copy_used:   bool,
	raw_adopted:            bool,
	raw_append_only:        bool,
	ok:                     bool,
}

destroy_shard_segment_clean_result :: proc(result: ^Shard_Segment_Clean_Result) {
	if result == nil do return
	destroy_shard_segment_catalog(&result.catalog)
	delete(result.removed)
	delete(result.outputs)
	result^ = {}
}

shard_segment_clean_result_is_publishable :: proc(result: Shard_Segment_Clean_Result) -> bool {
	if !result.ok || !shard_segment_catalog_is_valid(result.catalog) || result.removed_start < 0 || result.next_cursor < 0 do return false
	if result.raw_adopted {
		if result.output_present || result.output_generation != 0 || result.removed_count != 1 || len(result.removed) != 1 || len(result.outputs) != 1 do return false
		if result.removed[0].kind != .Generation_WAL ||
		   result.outputs[0].kind != .Adopted_Generation_WAL ||
		   !shard_segment_descriptors_share_file(result.removed[0], result.outputs[0]) {
			return false
		}
		found := false
		for descriptor in result.catalog.segments do if descriptor == result.outputs[0] {found = true; break}
		return found
	}
	if result.raw_append_only do return false
	if !result.output_present {
		if len(result.outputs) != 0 || result.output_generation != 0 || result.removed_count != len(result.removed) do return false
		if result.removed_count == 0 do return len(result.removed) == 0
		if result.removed_start > len(result.catalog.segments) || result.removed_count > SHARD_SEGMENT_CATALOG_MAX_SEGMENTS - len(result.catalog.segments) do return false
		for removed in result.removed do if !shard_segment_descriptor_is_valid(removed) do return false
		return true
	}
	if result.removed_count < 1 || result.removed_count != len(result.removed) || len(result.outputs) < 1 || result.output_generation != result.outputs[0].generation do return false
	for output in result.outputs {
		if output.kind != .Cleaned_Segment || !shard_segment_descriptor_is_valid(output) do return false
		found := false
		for descriptor in result.catalog.segments do if descriptor == output {found = true; break}
		if !found do return false
	}
	for removed in result.removed {
		if !shard_segment_descriptor_is_valid(removed) do return false
		for descriptor in result.catalog.segments do if descriptor == removed do return false
	}
	return true
}

shard_segment_clean_result_matches_source :: proc(result: Shard_Segment_Clean_Result, source: Shard_Segment_Clean_Source) -> bool {
	if !shard_segment_clean_result_is_publishable(result) || source.shard != result.catalog.shard do return false
	if len(result.outputs) == 0 {
		if result.removed_start + result.removed_count > len(source.segments) || len(result.catalog.segments) != len(source.segments) - result.removed_count {
			return false
		}
		for index in 0 ..< result.removed_start do if result.catalog.segments[index] != source.segments[index] do return false
		for descriptor, index in result.removed do if descriptor != source.segments[result.removed_start + index] do return false
		for index in result.removed_start + result.removed_count ..< len(source.segments) {
			if result.catalog.segments[index - result.removed_count] != source.segments[index] do return false
		}
		return true
	}
	if result.removed_start + result.removed_count > len(source.segments) do return false
	expected_count := len(source.segments) - result.removed_count + len(result.outputs)
	if len(result.catalog.segments) != expected_count do return false
	for index in 0 ..< result.removed_start do if result.catalog.segments[index] != source.segments[index] do return false
	for descriptor, index in result.removed do if descriptor != source.segments[result.removed_start + index] do return false
	for output, index in result.outputs do if result.catalog.segments[result.removed_start + index] != output do return false
	source_suffix := result.removed_start + result.removed_count
	catalog_suffix := result.removed_start + len(result.outputs)
	for index in source_suffix ..< len(source.segments) {
		if result.catalog.segments[catalog_suffix + index - source_suffix] != source.segments[index] do return false
	}
	return true
}

shard_segment_clean_result_source :: proc(result: Shard_Segment_Clean_Result) -> (source: Shard_Segment_Clean_Source, ok: bool) {
	if !shard_segment_clean_result_is_publishable(result) do return
	source.shard = result.catalog.shard
	if len(result.outputs) == 0 {
		source.segments = make([dynamic]Shard_Segment_Descriptor, len(result.catalog.segments) + result.removed_count)
		copy(source.segments[:result.removed_start], result.catalog.segments[:result.removed_start])
		copy(source.segments[result.removed_start:][:result.removed_count], result.removed[:])
		copy(source.segments[result.removed_start + result.removed_count:], result.catalog.segments[result.removed_start:])
		return source, true
	}
	count := len(result.catalog.segments) - len(result.outputs) + result.removed_count
	if count < 0 || count > SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return
	source.segments = make([dynamic]Shard_Segment_Descriptor, count)
	copy(source.segments[:result.removed_start], result.catalog.segments[:result.removed_start])
	copy(source.segments[result.removed_start:][:result.removed_count], result.removed[:])
	catalog_suffix := result.removed_start + len(result.outputs)
	source_suffix := result.removed_start + result.removed_count
	copy(source.segments[source_suffix:], result.catalog.segments[catalog_suffix:])
	return source, true
}

shard_segment_clean_result_rebase :: proc(
	result: Shard_Segment_Clean_Result,
	current: Shard_Segment_Clean_Source,
	catalog_generation: u64,
) -> (
	catalog: Shard_Segment_Catalog,
	ok: bool,
) {
	snapshot, snapshot_ok := shard_segment_clean_result_source(result)
	if !snapshot_ok do return
	defer destroy_shard_segment_clean_source(&snapshot)
	if current.shard != snapshot.shard || len(current.segments) < len(snapshot.segments) || catalog_generation == 0 do return
	for descriptor, index in snapshot.segments do if current.segments[index] != descriptor do return
	appended_count := len(current.segments) - len(snapshot.segments)
	if len(result.catalog.segments) + appended_count > SHARD_SEGMENT_CATALOG_MAX_SEGMENTS do return
	catalog.shard = result.catalog.shard
	catalog.catalog_generation = catalog_generation
	catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(result.catalog.segments) + appended_count)
	copy(catalog.segments[:len(result.catalog.segments)], result.catalog.segments[:])
	copy(catalog.segments[len(result.catalog.segments):], current.segments[len(snapshot.segments):])
	if !shard_segment_catalog_is_valid(catalog) {destroy_shard_segment_catalog(&catalog); return}
	return catalog, true
}

shard_segment_clean_group_end :: proc(
	sizes: []u64,
	start: int,
	target_bytes: u64 = SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
	max_segments: int = 0,
) -> (
	end: int,
	ok: bool,
) {
	if start < 0 || start >= len(sizes) do return
	end = start
	bytes: u64
	for index in start ..< len(sizes) {
		if max_segments > 0 && end - start >= max_segments do break
		size := sizes[index]
		if end > start && (bytes > target_bytes || size > target_bytes - bytes) do break
		bytes = size > max(u64) - bytes ? max(u64) : bytes + size
		end = index + 1
	}
	return end, end > start
}

shard_segment_clean_start_floors_from_metadata :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	source: Shard_Segment_Clean_Source,
	source_sizes: []u64,
	clean_start: int,
) -> (
	floors: Shard_High_Water_Requirements,
	read_bytes: u64,
	metadata_fallbacks: u64,
	metadata_written_bytes: u64,
	ok: bool,
) {
	if clean_start <= 0 do return {}, 0, 0, 0, true
	previous := clean_start - 1
	previous_summary, summary_bytes, summary_ok := load_shard_segment_metadata_summary(
		storage,
		shard_dir,
		source.shard,
		source.segments[previous],
		source_sizes[previous],
	)
	read_bytes += summary_bytes
	if summary_ok {
		floors = previous_summary.end
		destroy_shard_segment_metadata_summary(&previous_summary)
		ok = true
		return
	}

	for index in 0 ..< clean_start {
		summary, loaded_bytes, loaded := load_shard_segment_metadata_summary(
			storage,
			shard_dir,
			source.shard,
			source.segments[index],
			source_sizes[index],
			&floors,
		)
		read_bytes += loaded_bytes
		if loaded {
			floors = summary.end
			destroy_shard_segment_metadata_summary(&summary)
			continue
		}
		metadata_fallbacks += 1
		metadata, scanned_bytes, built := build_shard_segment_metadata(storage, shard_dir, source.shard, source.segments[index], source_sizes[index], floors)
		read_bytes += scanned_bytes
		if !built {
			path := shard_segment_descriptor_path(shard_dir, source.segments[index])
			if path == "" do return
			_, next_floors, scanned := scan_shard_transaction_wal(storage, path, source.shard, floors, false, false)
			delete(path)
			if !scanned do return
			read_bytes += source_sizes[index]
			floors = next_floors
			continue
		}
		floors = metadata.end
		written_bytes, written := write_shard_segment_metadata(storage, shard_dir, &metadata)
		if written {
			metadata_written_bytes += written_bytes
		} else {
			metadata_fallbacks += 1
		}
		destroy_shard_segment_metadata(&metadata)
	}
	ok = true
	return
}

shard_segment_clean_apply_tail_metadata :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	source: Shard_Segment_Clean_Source,
	source_sizes: []u64,
	tail_start: int,
	ctx: ^Shard_Segment_Clean_Scan_Context,
) -> (
	read_bytes: u64,
	metadata_fallbacks: u64,
	metadata_written_bytes: u64,
	ok: bool,
) {
	if ctx == nil || ctx.keys == nil do return
	for index in tail_start ..< len(source.segments) {
		segment_start := ctx.previous
		summary, summary_bytes, summary_ok := load_shard_segment_metadata_summary(
			storage,
			shard_dir,
			source.shard,
			source.segments[index],
			source_sizes[index],
			&ctx.previous,
		)
		read_bytes += summary_bytes
		metadata: Shard_Segment_Metadata
		metadata_loaded := false
		if !summary_ok {
			metadata_fallbacks += 1
			scanned_bytes: u64
			metadata, scanned_bytes, metadata_loaded = build_shard_segment_metadata(
				storage,
				shard_dir,
				source.shard,
				source.segments[index],
				source_sizes[index],
				ctx.previous,
			)
			read_bytes += scanned_bytes
			if metadata_loaded {
				written_bytes, written := write_shard_segment_metadata(storage, shard_dir, &metadata)
				if written {metadata_written_bytes += written_bytes} else {metadata_fallbacks += 1}
			}
		}

		maybe_overlap := !summary_ok
		if summary_ok {
			for key in ctx.keys.latest {
				if shard_segment_metadata_summary_maybe_contains(&summary, transmute([]byte)key) {
					maybe_overlap = true
					break
				}
			}
			ctx.previous = summary.end
		}
		if summary_ok && !maybe_overlap {
			destroy_shard_segment_metadata_summary(&summary)
			continue
		}
		if maybe_overlap && !metadata_loaded && summary_ok {
			loaded_bytes: u64
			metadata, loaded_bytes, metadata_loaded = load_shard_segment_metadata(
				storage,
				shard_dir,
				source.shard,
				source.segments[index],
				source_sizes[index],
				summary.start,
			)
			read_bytes += loaded_bytes
			if !metadata_loaded {
				metadata_fallbacks += 1
				metadata, loaded_bytes, metadata_loaded = build_shard_segment_metadata(
					storage,
					shard_dir,
					source.shard,
					source.segments[index],
					source_sizes[index],
					summary.start,
				)
				read_bytes += loaded_bytes
				if metadata_loaded {
					written_bytes, written := write_shard_segment_metadata(storage, shard_dir, &metadata)
					if written {metadata_written_bytes += written_bytes} else {metadata_fallbacks += 1}
				}
			}
		}
		if metadata_loaded {
			for key in ctx.keys.latest {
				if shard_segment_metadata_contains(&metadata, transmute([]byte)key) do ctx.keys.latest[key] = 0
			}
			ctx.previous = metadata.end
			destroy_shard_segment_metadata(&metadata)
			destroy_shard_segment_metadata_summary(&summary)
			continue
		}
		if summary_ok {
			destroy_shard_segment_metadata_summary(&summary)
		}

		ctx.previous = segment_start
		path := shard_segment_descriptor_path(shard_dir, source.segments[index])
		if path == "" do return
		scanned := shard_segment_clean_scan_file(storage, path, ctx)
		delete(path)
		if !scanned do return
		read_bytes += source_sizes[index]
	}
	ok = true
	return
}

build_shard_segment_catalog :: proc(
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	catalog_generation: u64,
	source_override: ^Shard_Segment_Clean_Source = nil,
	clean_start: int = 0,
	output_max_bytes: u64 = SHARD_CLEANED_SEGMENT_MAX_BYTES,
	source_max_bytes: u64 = SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
	source_max_segments: int = 0,
	raw_fast_path: bool = false,
	expected_source_floors: Shard_High_Water_Requirements = {},
	raw_metadata_max_bytes: int = SHARD_RAW_COPY_METADATA_MAX_BYTES,
) -> (
	result: Shard_Segment_Clean_Result,
) {
	// Finish deferred rename restoration before copying the owning result to the caller.
	build_shard_segment_catalog_into(
		&result,
		storage,
		shard_dir,
		manifest,
		catalog_generation,
		source_override,
		clean_start,
		output_max_bytes,
		source_max_bytes,
		source_max_segments,
		raw_fast_path,
		expected_source_floors,
		raw_metadata_max_bytes,
	)
	if !result.ok do destroy_shard_segment_clean_result(&result)
	return
}

build_shard_segment_catalog_into :: proc(
	result: ^Shard_Segment_Clean_Result,
	storage: storage_io.Context,
	shard_dir: string,
	manifest: Shard_Compaction_Manifest,
	catalog_generation: u64,
	source_override: ^Shard_Segment_Clean_Source,
	clean_start: int,
	output_max_bytes: u64,
	source_max_bytes: u64,
	source_max_segments: int,
	raw_fast_path: bool,
	expected_source_floors: Shard_High_Water_Requirements,
	raw_metadata_max_bytes: int,
) {
	if catalog_generation == 0 do return
	source: Shard_Segment_Clean_Source
	if source_override != nil {
		cloned: bool
		source, cloned = clone_shard_segment_clean_source(source_override^)
		if !cloned do return
	} else {
		source_ok: bool
		source, source_ok = shard_segment_source_for_manifest(storage, shard_dir, manifest)
		if !source_ok do return
	}
	defer destroy_shard_segment_clean_source(&source)
	if source.shard != manifest.shard || clean_start < 0 || clean_start >= len(source.segments) do return
	result.catalog.shard = source.shard
	result.catalog.catalog_generation = catalog_generation
	result.catalog.segments = make([dynamic]Shard_Segment_Descriptor)
	result.removed = make([dynamic]Shard_Segment_Descriptor)
	result.outputs = make([dynamic]Shard_Segment_Descriptor)

	source_sizes := make([]u64, len(source.segments))
	defer delete(source_sizes)
	for descriptor, index in source.segments {
		size, size_ok := shard_segment_descriptor_size(storage, shard_dir, descriptor)
		if !size_ok do return
		source_sizes[index] = size
	}
	group_end, clean_group := shard_segment_clean_group_end(source_sizes, clean_start, source_max_bytes, source_max_segments)
	if !clean_group do return
	result.removed_start = clean_start
	result.removed_count = group_end - clean_start
	result.next_cursor = group_end
	for index in clean_start ..< group_end {
		if source_sizes[index] > max(u64) - result.input_bytes do return
		result.input_bytes += source_sizes[index]
	}

	fast_raw := raw_fast_path
	if fast_raw {
		if !manifest.segmented || manifest.sealed_present || group_end != clean_start + 1 || source.segments[clean_start].kind != .Generation_WAL {
			return
		}
		for index in clean_start + 1 ..< len(source.segments) do if source.segments[index].kind == .Generation_WAL do return
	}
	if fast_raw && source_sizes[clean_start] == 0 {
		path := shard_segment_descriptor_path(shard_dir, source.segments[clean_start])
		if path == "" do return
		inspection, _, empty_ok := scan_shard_transaction_wal(storage, path, source.shard, {}, false, false)
		delete(path)
		if !empty_ok || inspection.record_count != 0 do return
		delete(result.catalog.segments)
		result.catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments) - 1)
		copy(result.catalog.segments[:clean_start], source.segments[:clean_start])
		copy(result.catalog.segments[clean_start:], source.segments[clean_start + 1:])
		if _, append_err := append(&result.removed, source.segments[clean_start]); append_err != nil do return
		result.floors = expected_source_floors
		result.raw_fast_path_used = true
		result.ok = shard_segment_catalog_is_valid(result.catalog)
		return
	}
	start_floors: Shard_High_Water_Requirements
	if !fast_raw {
		when SHARD_SEGMENT_METADATA_INDEX_ENABLED {
			prefix_bytes: u64
			prefix_fallbacks: u64
			prefix_metadata_written: u64
			prefix_ok: bool
			start_floors, prefix_bytes, prefix_fallbacks, prefix_metadata_written, prefix_ok = shard_segment_clean_start_floors_from_metadata(
				storage,
				shard_dir,
				source,
				source_sizes,
				clean_start,
			)
			result.prefix_read_bytes += prefix_bytes
			result.metadata_fallbacks += prefix_fallbacks
			result.metadata_written_bytes += prefix_metadata_written
			if !prefix_ok do return
		} else {
			source_ok: bool
			for index in 0 ..< clean_start {
				path := shard_segment_descriptor_path(shard_dir, source.segments[index])
				if path == "" do return
				_, start_floors, source_ok = scan_shard_transaction_wal(storage, path, source.shard, start_floors, false, false)
				delete(path)
				if !source_ok do return
				result.prefix_read_bytes += source_sizes[index]
			}
		}
	}
	keys := Shard_Segment_Key_Storage {
		latest = make(map[string]u64),
		owned  = make([dynamic][]byte),
	}
	defer shard_segment_key_storage_destroy(&keys)
	raw_records := make([dynamic]Shard_Raw_Record_Metadata)
	defer delete(raw_records)
	latest_ctx := Shard_Segment_Clean_Scan_Context {
		shard                = source.shard,
		previous             = start_floors,
		mode                 = .Latest,
		keys                 = &keys,
		capture_raw_metadata = fast_raw,
		raw_metadata_limit   = max(raw_metadata_max_bytes, 0),
		raw_records          = &raw_records,
		raw_append_only      = fast_raw,
	}
	raw_metadata_builder: Shard_Segment_Metadata_Build_Context
	raw_metadata_builder_initialized := false
	defer if raw_metadata_builder_initialized do destroy_shard_segment_metadata_builder(&raw_metadata_builder)
	if fast_raw && SHARD_SEGMENT_METADATA_INDEX_ENABLED {
		raw_metadata_builder_initialized = init_shard_segment_metadata_builder(&raw_metadata_builder, source.shard, {}, false)
		if raw_metadata_builder_initialized do latest_ctx.segment_metadata = &raw_metadata_builder
	}
	candidate_metadata := make([dynamic]Shard_Segment_Metadata)
	defer {
		for &metadata in candidate_metadata do destroy_shard_segment_metadata(&metadata)
		delete(candidate_metadata)
	}
	candidate_metadata_ok := SHARD_SEGMENT_METADATA_INDEX_ENABLED && !fast_raw
	candidate_metadata_allocation: u64
	group_floors := start_floors
	if candidate_metadata_ok {
		floors := start_floors
		for index in clean_start ..< group_end {
			remaining_metadata_budget :=
				u64(SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES) - min(u64(SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES), candidate_metadata_allocation)
			if remaining_metadata_budget == 0 {
				candidate_metadata_ok = false
				break
			}
			metadata, metadata_bytes, loaded := load_shard_segment_metadata(
				storage,
				shard_dir,
				source.shard,
				source.segments[index],
				source_sizes[index],
				floors,
				remaining_metadata_budget,
			)
			result.latest_read_bytes += metadata_bytes
			if !loaded {
				candidate_metadata_ok = false
				break
			}
			estimated_allocation := metadata_bytes * SHARD_SEGMENT_METADATA_DECODED_ESTIMATE_MULTIPLIER
			if estimated_allocation > remaining_metadata_budget {
				destroy_shard_segment_metadata(&metadata)
				candidate_metadata_ok = false
				break
			}
			candidate_metadata_allocation += estimated_allocation
			floors = metadata.end
			append(&candidate_metadata, metadata)
		}
		if candidate_metadata_ok {
			for &metadata in candidate_metadata {
				if !shard_segment_metadata_apply_latest(&metadata, &keys, &latest_ctx.position) do return
			}
			latest_ctx.previous = floors
			group_floors = floors
		} else {
			for &metadata in candidate_metadata do destroy_shard_segment_metadata(&metadata)
			clear(&candidate_metadata)
		}
	}
	if !candidate_metadata_ok {
		when SHARD_SEGMENT_METADATA_INDEX_ENABLED do if !fast_raw do result.metadata_fallbacks += 1
		latest_end := SHARD_SEGMENT_METADATA_INDEX_ENABLED ? group_end : len(source.segments)
		for index in clean_start ..< latest_end {
			path := shard_segment_descriptor_path(shard_dir, source.segments[index])
			if path == "" do return
			scan_ok := shard_segment_clean_scan_file(storage, path, &latest_ctx)
			delete(path)
			if !scan_ok do return
			result.latest_read_bytes += source_sizes[index]
			if index + 1 == group_end do group_floors = latest_ctx.previous
		}
	}
	when SHARD_SEGMENT_METADATA_INDEX_ENABLED do if !fast_raw && group_end < len(source.segments) {
		tail_bytes, tail_fallbacks, tail_metadata_written, tail_ok := shard_segment_clean_apply_tail_metadata(
			storage,
			shard_dir,
			source,
			source_sizes,
			group_end,
			&latest_ctx,
		)
		result.latest_read_bytes += tail_bytes
		result.metadata_fallbacks += tail_fallbacks
		result.metadata_written_bytes += tail_metadata_written
		if !tail_ok do return
	}
	if fast_raw && latest_ctx.raw_offset != source_sizes[clean_start] do return
	if fast_raw &&
	   (latest_ctx.previous.task > expected_source_floors.task ||
			   latest_ctx.previous.asset > expected_source_floors.asset ||
			   latest_ctx.previous.edge > expected_source_floors.edge) {
		return
	}
	if fast_raw && latest_ctx.raw_metadata_overflow do result.metadata_fallbacks += 1
	if fast_raw && !latest_ctx.raw_metadata_overflow {
		retained_bytes, synthetic_bytes, measured := shard_segment_raw_retained_bytes(raw_records[:], &keys)
		if !measured || retained_bytes > result.input_bytes || synthetic_bytes > result.input_bytes - retained_bytes do return
		result.dirty_bytes = result.input_bytes - retained_bytes - synthetic_bytes
	}
	measure_ctx: Shard_Segment_Clean_Scan_Context
	if candidate_metadata_ok {
		position: u64
		retained_bytes, synthetic_bytes: u64
		for &metadata in candidate_metadata {
			segment_retained, segment_synthetic, measured := shard_segment_metadata_retained_bytes(&metadata, &keys, &position)
			if !measured || segment_retained > max(u64) - retained_bytes || segment_synthetic > max(u64) - synthetic_bytes do return
			retained_bytes += segment_retained
			synthetic_bytes += segment_synthetic
		}
		if retained_bytes > result.input_bytes || synthetic_bytes > result.input_bytes - retained_bytes do return
		result.dirty_bytes = result.input_bytes - retained_bytes - synthetic_bytes
	} else if !fast_raw {
		measure_ctx = {
			shard    = source.shard,
			previous = start_floors,
			mode     = .Measure,
			keys     = &keys,
		}
		for index in clean_start ..< group_end {
			path := shard_segment_descriptor_path(shard_dir, source.segments[index])
			if path == "" do return
			scan_ok := shard_segment_clean_scan_file(storage, path, &measure_ctx)
			delete(path)
			if !scan_ok do return
			result.measure_read_bytes += source_sizes[index]
		}
		if measure_ctx.retained_bytes > result.input_bytes || measure_ctx.synthetic_bytes > result.input_bytes - measure_ctx.retained_bytes do return
		result.dirty_bytes = result.input_bytes - measure_ctx.retained_bytes - measure_ctx.synthetic_bytes
	}
	contains_raw_wal := false
	for index in clean_start ..< group_end do if source.segments[index].kind == .Generation_WAL {contains_raw_wal = true; break}
	dirty_threshold := result.input_bytes / 100 * SHARD_SEGMENT_CLEAN_MIN_DIRTY_PERCENT
	dirty_threshold += (result.input_bytes % 100 * SHARD_SEGMENT_CLEAN_MIN_DIRTY_PERCENT + 99) / 100
	dirty_enough := result.dirty_bytes > 0 && result.dirty_bytes >= dirty_threshold
	if fast_raw && !latest_ctx.raw_metadata_overflow && !dirty_enough {
		adopted := Shard_Segment_Descriptor{.Adopted_Generation_WAL, source.segments[clean_start].generation}
		delete(result.catalog.segments)
		result.catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments))
		copy(result.catalog.segments[:], source.segments[:])
		result.catalog.segments[clean_start] = adopted
		if _, append_err := append(&result.removed, source.segments[clean_start]); append_err != nil do return
		if _, append_err := append(&result.outputs, adopted); append_err != nil do return
		result.next_cursor = clean_start + 1
		result.floors = expected_source_floors
		result.raw_fast_path_used = true
		result.raw_adopted = true
		result.raw_append_only = latest_ctx.raw_append_only
		if raw_metadata_builder_initialized {
			metadata, metadata_ok := finalize_shard_segment_metadata_builder(&raw_metadata_builder, adopted, source_sizes[clean_start])
			if metadata_ok {
				written_bytes, written := write_shard_segment_metadata(storage, shard_dir, &metadata)
				if written {result.metadata_written_bytes += written_bytes} else {result.metadata_fallbacks += 1}
				destroy_shard_segment_metadata(&metadata)
			} else {
				result.metadata_fallbacks += 1
			}
		}
		result.ok = shard_segment_catalog_is_valid(result.catalog)
		return
	}
	if !contains_raw_wal && !dirty_enough {
		if group_end >= len(source.segments) {
			shard_replay_state_init()
			_, source_valid := shard_segment_source_replay(storage, shard_dir, source, true)
			shard_replay_state_destroy()
			if !source_valid do return
			for size in source_sizes do result.replay_read_bytes += size
		}
		delete(result.catalog.segments)
		result.catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments))
		copy(result.catalog.segments[:], source.segments[:])
		result.removed_count = 0
		result.removed_start = 0
		result.next_cursor = group_end
		result.floors = latest_ctx.previous
		result.ok = shard_segment_catalog_is_valid(result.catalog)
		return
	}

	witness_tx, witness_workspace, witness_size, witness_ok := shard_segment_floor_witness(source.shard, group_floors)
	if !witness_ok || u64(witness_size) > output_max_bytes do return
	defer delete(witness_workspace)
	copy_ctx := Shard_Segment_Clean_Scan_Context {
		shard                  = source.shard,
		previous               = start_floors,
		mode                   = .Copy,
		keys                   = &keys,
		storage                = storage,
		shard_dir              = shard_dir,
		outputs                = &result.outputs,
		next_output_generation = catalog_generation,
		witness_reserve        = u64(witness_size),
		output_max_bytes       = output_max_bytes,
		retain_graph_sensitive = fast_raw,
	}
	defer if !result.ok {
		if copy_ctx.builder.active do persistence.abort_wal_file_builder(&copy_ctx.builder)
		for output in result.outputs {
			path := shard_cleaned_segment_temp_path(shard_dir, output.generation)
			_ = storage_io.remove(storage, path)
			delete(path)
			metadata_path := shard_segment_metadata_path(shard_dir, output)
			_ = storage_io.remove(storage, metadata_path)
			delete(metadata_path)
			metadata_temp_path := shard_segment_metadata_temp_path(shard_dir, output)
			_ = storage_io.remove(storage, metadata_temp_path)
			delete(metadata_temp_path)
		}
		path := shard_cleaned_segment_temp_path(shard_dir, copy_ctx.next_output_generation)
		_ = storage_io.remove(storage, path)
		delete(path)
	}
	if fast_raw && !latest_ctx.raw_metadata_overflow {
		path := shard_segment_descriptor_path(shard_dir, source.segments[clean_start])
		if path == "" do return
		copied := shard_segment_clean_copy_retained_raw_records(storage, path, source_sizes[clean_start], raw_records[:], &keys, &copy_ctx)
		delete(path)
		if !copied do return
		result.copy_read_bytes += copy_ctx.retained_bytes
		result.raw_direct_copy_used = true
	} else if candidate_metadata_ok {
		position: u64
		for &metadata, metadata_index in candidate_metadata {
			path := shard_segment_descriptor_path(shard_dir, source.segments[clean_start + metadata_index])
			if path == "" do return
			read_bytes, copied := shard_segment_clean_copy_retained_metadata_records(storage, path, &metadata, &keys, &position, &copy_ctx)
			delete(path)
			if !copied do return
			result.copy_read_bytes += read_bytes
		}
	} else {
		for index in clean_start ..< group_end {
			path := shard_segment_descriptor_path(shard_dir, source.segments[index])
			if path == "" do return
			scan_ok := shard_segment_clean_scan_file(storage, path, &copy_ctx)
			delete(path)
			if !scan_ok do return
			result.copy_read_bytes += source_sizes[index]
		}
	}
	if fast_raw {
		if copy_ctx.retained_bytes > result.input_bytes || copy_ctx.synthetic_bytes > result.input_bytes - copy_ctx.retained_bytes do return
		result.dirty_bytes = result.input_bytes - copy_ctx.retained_bytes - copy_ctx.synthetic_bytes
	}
	if !copy_ctx.builder.active && !shard_segment_clean_start_output(&copy_ctx) do return
	if copy_ctx.builder.record_count > 0 && copy_ctx.builder.file_size + u64(witness_size) > copy_ctx.output_max_bytes {
		if !shard_segment_clean_finish_output(&copy_ctx) || !shard_segment_clean_start_output(&copy_ctx) do return
	}
	if !shard_segment_append_floor_witness(&copy_ctx.builder, &witness_tx, witness_size) || !shard_segment_clean_finish_output(&copy_ctx) do return

	result.catalog.segments = make([dynamic]Shard_Segment_Descriptor, len(source.segments) - result.removed_count + len(result.outputs))
	copy(result.catalog.segments[:clean_start], source.segments[:clean_start])
	copy(result.catalog.segments[clean_start:][:len(result.outputs)], result.outputs[:])
	copy(result.catalog.segments[clean_start + len(result.outputs):], source.segments[group_end:])
	if !shard_segment_catalog_is_valid(result.catalog) do return
	if _, append_err := append(&result.removed, ..source.segments[clean_start:group_end]); append_err != nil do return
	result.output_present = true
	result.output_generation = result.outputs[0].generation
	result.next_cursor = clean_start + len(result.outputs)

	// Verification temporarily gives every candidate its final descriptor path,
	// then restores the unpublished temporary names after replay equivalence.
	renamed := 0
	for output in result.outputs {
		temp_path := shard_cleaned_segment_temp_path(shard_dir, output.generation)
		final_path := shard_cleaned_segment_path(shard_dir, output.generation)
		_ = storage_io.remove(storage, final_path)
		rename_ok := storage_io.rename(storage, temp_path, final_path) == nil
		delete(temp_path)
		delete(final_path)
		if !rename_ok do break
		renamed += 1
	}
	defer {
		for index in 0 ..< renamed {
			output := result.outputs[index]
			final_path := shard_cleaned_segment_path(shard_dir, output.generation)
			temp_path := shard_cleaned_segment_temp_path(shard_dir, output.generation)
			if storage_io.rename(storage, final_path, temp_path) != nil do result.ok = false
			delete(final_path)
			delete(temp_path)
		}
	}
	if renamed != len(result.outputs) do return
	if fast_raw {
		output_floors: Shard_High_Water_Requirements
		for output in result.outputs {
			output_start := output_floors
			output_size, output_size_ok := shard_segment_descriptor_size(storage, shard_dir, output)
			if !output_size_ok do return
			metadata, metadata_read_bytes, metadata_ok := build_shard_segment_metadata(storage, shard_dir, source.shard, output, output_size, output_floors)
			result.replay_read_bytes += metadata_read_bytes
			if metadata_ok && metadata_read_bytes == output_size {
				output_floors = metadata.end
				written_bytes, written := write_shard_segment_metadata(storage, shard_dir, &metadata)
				if written {result.metadata_written_bytes += written_bytes} else {result.metadata_fallbacks += 1}
				destroy_shard_segment_metadata(&metadata)
			} else {
				result.metadata_fallbacks += 1
				destroy_shard_segment_metadata(&metadata)
				path := shard_segment_descriptor_path(shard_dir, output)
				if path == "" do return
				source_ok: bool
				_, output_floors, source_ok = scan_shard_transaction_wal(storage, path, source.shard, output_start, false, false)
				delete(path)
				if !source_ok do return
				result.replay_read_bytes += output_size
			}
		}
		result.floors = expected_source_floors
		result.raw_fast_path_used = output_floors == group_floors
		result.ok = result.raw_fast_path_used
	} else {
		candidate_replay_bytes: u64
		for descriptor in result.catalog.segments {
			size, size_ok := shard_segment_descriptor_size(storage, shard_dir, descriptor)
			if !size_ok do return
			candidate_replay_bytes += size
		}
		shard_replay_state_init()
		source_floors, replay_source_ok := shard_segment_source_replay(storage, shard_dir, source, true)
		for size in source_sizes do result.replay_read_bytes += size
		source_digest := shard_checkpoint_state_digest(source.shard)
		shard_replay_state_destroy()
		if !replay_source_ok do return
		shard_replay_state_init()
		result.floors, result.ok = shard_segment_catalog_replay(storage, shard_dir, result.catalog, true)
		result.replay_read_bytes += candidate_replay_bytes
		candidate_digest := shard_checkpoint_state_digest(source.shard)
		shard_replay_state_destroy()
		result.ok = result.ok && result.floors == source_floors && candidate_digest == source_digest
	}
	return
}
