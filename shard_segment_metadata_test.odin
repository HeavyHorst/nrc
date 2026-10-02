package main

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:os"
import "core:testing"

import "storage_io"

shard_segment_metadata_test_value :: proc() -> Shard_Segment_Metadata {
	metadata := Shard_Segment_Metadata {
		shard = 7,
		descriptor = {.Cleaned_Segment, 42},
		segment_size = 8192,
		start = {task = 10, asset = 20, edge = 30},
		start_known = true,
		end = {task = 13, asset = 24, edge = 31},
		keys = make([dynamic][]byte, 2),
		records = make([dynamic]Shard_Segment_Metadata_Record, 2),
	}
	metadata.records[0] = {
		offset          = 0,
		physical_size   = 4096,
		key_indices     = make([dynamic]u32, 1),
		graph_sensitive = true,
	}
	metadata.records[1] = {
		offset        = 4096,
		physical_size = 4096,
		key_indices   = make([dynamic]u32, 1),
	}
	metadata.records[0].key_indices[0] = 0; metadata.records[1].key_indices[0] = 1
	metadata.keys[0] = make([]byte, 3); copy(metadata.keys[0], []byte{1, 2, 3})
	metadata.keys[1] = make([]byte, 4); copy(metadata.keys[1], []byte{2, 3, 4, 5})
	bloom_size, _ := shard_segment_metadata_bloom_size(len(metadata.keys))
	metadata.bloom = make([]byte, bloom_size)
	for key in metadata.keys do _ = shard_segment_metadata_bloom_apply(metadata.bloom, key, true)
	return metadata
}

@(test)
test_shard_segment_metadata_roundtrip_membership_and_corruption :: proc(t: ^testing.T) {
	metadata := shard_segment_metadata_test_value(); defer destroy_shard_segment_metadata(&metadata)
	size, size_ok := shard_segment_metadata_encoded_size(&metadata)
	testing.expect(t, size_ok)
	encoded := make([]byte, size); defer delete(encoded)
	testing.expect(t, encode_shard_segment_metadata(&metadata, encoded))
	decoded, decode_ok := decode_shard_segment_metadata(encoded); defer destroy_shard_segment_metadata(&decoded)
	testing.expect(t, decode_ok)
	testing.expect_value(t, decoded.shard, metadata.shard)
	testing.expect_value(t, decoded.descriptor, metadata.descriptor)
	testing.expect_value(t, decoded.start, metadata.start)
	testing.expect_value(t, decoded.end, metadata.end)
	testing.expect(t, decoded.start_known)
	testing.expect_value(t, len(decoded.records), 2)
	testing.expect_value(t, decoded.records[0].offset, u64(0))
	testing.expect_value(t, decoded.records[0].physical_size, u32(4096))
	testing.expect(t, decoded.records[0].graph_sensitive)
	testing.expect_value(t, decoded.records[0].key_indices[0], u32(0))
	for key in metadata.keys {
		testing.expect(t, shard_segment_metadata_bloom_maybe_contains(&decoded, key), "Bloom filter must have no false negatives")
		testing.expect(t, shard_segment_metadata_contains(&decoded, key))
	}
	miss := []byte{99}
	for shard_segment_metadata_bloom_maybe_contains(&decoded, miss) do miss[0] += 1
	testing.expect(t, !shard_segment_metadata_contains(&decoded, miss))

	encoded[17] ~= 1
	corrupt, corrupt_ok := decode_shard_segment_metadata(encoded)
	destroy_shard_segment_metadata(&corrupt)
	testing.expect(t, !corrupt_ok, "checksum corruption must be a cache miss")
}

@(test)
test_shard_segment_metadata_rejects_impossible_counts_before_allocation :: proc(t: ^testing.T) {
	metadata := shard_segment_metadata_test_value()
	defer destroy_shard_segment_metadata(&metadata)
	size, size_ok := shard_segment_metadata_encoded_size(&metadata)
	testing.expect(t, size_ok)
	encoded := make([]byte, size)
	defer delete(encoded)
	testing.expect(t, encode_shard_segment_metadata(&metadata, encoded))
	endian.put_u32(encoded[96:], .Big, max(u32))
	endian.put_u64(encoded[88:], .Big, 0)
	summary_end := SHARD_SEGMENT_METADATA_HEADER_SIZE + len(metadata.bloom)
	endian.put_u64(encoded[88:], .Big, xxhash.XXH64(encoded[:summary_end]))
	checksum_offset := len(encoded) - SHARD_SEGMENT_METADATA_CHECKSUM_SIZE
	endian.put_u64(encoded[checksum_offset:], .Big, xxhash.XXH64(encoded[:checksum_offset]))
	decoded, decoded_ok := decode_shard_segment_metadata(encoded)
	destroy_shard_segment_metadata(&decoded)
	testing.expect(t, !decoded_ok)
}

@(test)
test_shard_segment_metadata_record_table_validation :: proc(t: ^testing.T) {
	metadata := shard_segment_metadata_test_value()
	defer destroy_shard_segment_metadata(&metadata)
	testing.expect(t, shard_segment_metadata_is_valid(&metadata))
	metadata.records[1].offset = 4095
	testing.expect(t, !shard_segment_metadata_is_valid(&metadata), "record offsets must be contiguous")
	metadata.records[1].offset = 4096
	metadata.segment_size += 1
	testing.expect(t, !shard_segment_metadata_is_valid(&metadata), "record sizes must exactly cover the segment")
	metadata.segment_size -= 1
	append(&metadata.records[0].key_indices, 1)
	testing.expect(t, shard_segment_metadata_is_valid(&metadata), "an atomic record may post multiple exact keys")
	append(&metadata.records[0].key_indices, 1)
	testing.expect(t, !shard_segment_metadata_is_valid(&metadata), "one record must deduplicate repeated keys")
}

@(test)
test_shard_segment_metadata_retains_whole_atomic_record_for_any_latest_key :: proc(t: ^testing.T) {
	metadata := shard_segment_metadata_test_value()
	defer destroy_shard_segment_metadata(&metadata)
	append(&metadata.records[0].key_indices, 1)
	metadata.records[1].key_indices[0] = 0
	keys := Shard_Segment_Key_Storage {
		latest = make(map[string]u64),
		owned  = make([dynamic][]byte),
	}
	defer shard_segment_key_storage_destroy(&keys)
	position: u64
	testing.expect(t, shard_segment_metadata_apply_latest(&metadata, &keys, &position))
	measure_position: u64
	retained, synthetic, measured := shard_segment_metadata_retained_bytes(&metadata, &keys, &measure_position)
	testing.expect(t, measured)
	testing.expect_value(t, retained, u64(8192))
	testing.expect_value(t, synthetic, u64(0))
}

@(test)
test_shard_segment_metadata_persistence_identity_size_and_floor_validation :: proc(t: ^testing.T) {
	dir := storage_layout_test_setup("segment-metadata")
	defer os.remove_all(dir)
	metadata := shard_segment_metadata_test_value(); defer destroy_shard_segment_metadata(&metadata)
	written, write_ok := write_shard_segment_metadata(storage_io.host_context(), dir, &metadata)
	testing.expect(t, write_ok && written > 0)
	loaded, read, load_ok := load_shard_segment_metadata(
		storage_io.host_context(),
		dir,
		metadata.shard,
		metadata.descriptor,
		metadata.segment_size,
		metadata.start,
	)
	testing.expect(t, load_ok && read == written)
	destroy_shard_segment_metadata(&loaded)
	summary, summary_read, summary_ok := load_shard_segment_metadata_summary(
		storage_io.host_context(),
		dir,
		metadata.shard,
		metadata.descriptor,
		metadata.segment_size,
		&metadata.start,
	)
	testing.expect(t, summary_ok && summary_read < written && summary.start_known)
	destroy_shard_segment_metadata_summary(&summary)

	wrong_size, _, wrong_size_ok := load_shard_segment_metadata(
		storage_io.host_context(),
		dir,
		metadata.shard,
		metadata.descriptor,
		metadata.segment_size + 1,
		metadata.start,
	)
	destroy_shard_segment_metadata(&wrong_size)
	testing.expect(t, !wrong_size_ok)
	wrong_floor, _, wrong_floor_ok := load_shard_segment_metadata(
		storage_io.host_context(),
		dir,
		metadata.shard,
		metadata.descriptor,
		metadata.segment_size,
		{task = 9, asset = 20, edge = 30},
	)
	destroy_shard_segment_metadata(&wrong_floor)
	testing.expect(t, !wrong_floor_ok)
	wrong_shard, _, wrong_shard_ok := load_shard_segment_metadata(
		storage_io.host_context(),
		dir,
		metadata.shard + 1,
		metadata.descriptor,
		metadata.segment_size,
		metadata.start,
	)
	destroy_shard_segment_metadata(&wrong_shard)
	testing.expect(t, !wrong_shard_ok)

	adopted := shard_segment_metadata_path(dir, {.Adopted_Generation_WAL, 9}); defer delete(adopted)
	generation := shard_segment_metadata_path(dir, {.Generation_WAL, 9}); defer delete(generation)
	cleaned := shard_segment_metadata_path(dir, {.Cleaned_Segment, 9}); defer delete(cleaned)
	testing.expect_value(t, adopted, generation)
	testing.expect(t, cleaned != generation)

	metadata.start_known = false
	metadata.start = {}
	written, write_ok = write_shard_segment_metadata(storage_io.host_context(), dir, &metadata)
	testing.expect(t, write_ok)
	unknown, _, unknown_ok := load_shard_segment_metadata(
		storage_io.host_context(),
		dir,
		metadata.shard,
		metadata.descriptor,
		metadata.segment_size,
		{task = 999},
	)
	testing.expect(t, unknown_ok && !unknown.start_known && unknown.end == metadata.end)
	destroy_shard_segment_metadata(&unknown)
}

@(test)
test_shard_segment_metadata_prunes_tail_and_prefix_wal_reads_exactly :: proc(t: ^testing.T) {
	data_dir := storage_layout_test_setup("segment-metadata-pruning")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "segment-metadata-pruning"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)

	for id in u64(10) ..< 13 {
		testing.expect(t, shard_compaction_test_append_task(&writer, workspace, id, "metadata distinct key"))
		testing.expect(t, rotate_shard_writer_for_compaction(&writer))
		result := shard_compaction_test_build_result(&writer)
		testing.expect(t, result.ok && result.segments.raw_adopted)
		testing.expect(t, publish_shard_compaction_result(&writer, result))
		destroy_shard_segment_clean_result(&result.segments)
	}
	testing.expect(t, shard_compaction_test_update_task(&writer, workspace, 10, "metadata exact overlap"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	updated := shard_compaction_test_build_result(&writer)
	testing.expect(t, updated.ok && updated.segments.raw_adopted)
	testing.expect(t, publish_shard_compaction_result(&writer, updated))
	destroy_shard_segment_clean_result(&updated.segments)

	source, source_ok := shard_segment_source_for_writer(&writer)
	defer destroy_shard_segment_clean_source(&source)
	testing.expect(t, source_ok && len(source.segments) == 4)
	if !source_ok || len(source.segments) != 4 do return
	candidate_size: u64
	for descriptor, index in source.segments {
		size, size_ok := shard_segment_descriptor_size(writer.storage, writer.shard_dir, descriptor)
		testing.expect(t, size_ok)
		if index == 0 do candidate_size = size
		metadata_path := shard_segment_metadata_path(writer.shard_dir, descriptor)
		testing.expect(t, os.exists(metadata_path), "raw normalization must persist metadata during its validation scan")
		delete(metadata_path)
	}

	cold := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		writer.manifest.manifest_generation + 10,
		&source,
		0,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
	)
	defer destroy_shard_segment_clean_result(&cold)
	testing.expect(t, cold.ok && cold.output_present, "newer exact key must supersede the first segment")
	when SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES <= 1 {
		testing.expect(t, cold.latest_read_bytes >= candidate_size, "candidate metadata budget must fall back to its WAL")
		testing.expect(t, cold.measure_read_bytes >= candidate_size)
	} else {
		testing.expect_value(t, cold.measure_read_bytes, u64(0))
		testing.expect_value(t, cold.copy_read_bytes, u64(0))
	}
	for descriptor in source.segments[1:] {
		path := shard_segment_metadata_path(writer.shard_dir, descriptor)
		testing.expect(t, os.exists(path), "cold sweep should persist tail metadata")
		delete(path)
	}

	warm := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		writer.manifest.manifest_generation + 20,
		&source,
		0,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
	)
	defer destroy_shard_segment_clean_result(&warm)
	testing.expect(t, warm.ok && warm.output_present)
	when SHARD_SEGMENT_CANDIDATE_METADATA_MAX_BYTES > 1 do testing.expect_value(t, warm.measure_read_bytes, u64(0))

	prefix_cold := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		writer.manifest.manifest_generation + 30,
		&source,
		1,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
	)
	defer destroy_shard_segment_clean_result(&prefix_cold)
	testing.expect(t, prefix_cold.ok)
	prefix_warm := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		writer.manifest.manifest_generation + 40,
		&source,
		1,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
	)
	defer destroy_shard_segment_clean_result(&prefix_warm)
	testing.expect(t, prefix_warm.ok)
	first_size, _ := shard_segment_descriptor_size(writer.storage, writer.shard_dir, source.segments[0])
	testing.expect(t, prefix_warm.prefix_read_bytes < first_size, "persisted end floors must replace the prefix WAL scan")
}

@(test)
test_shard_segment_metadata_oversized_prefix_index_falls_back_to_wal :: proc(t: ^testing.T) {
	when SHARD_SEGMENT_METADATA_MAX_KEYS > 1 do return
	data_dir := storage_layout_test_setup("segment-metadata-prefix-overflow")
	defer os.remove_all(data_dir)
	testing.expect(t, storage_layout_test_create_generation(data_dir, 8))
	workspace := "segment-metadata-prefix-overflow"
	shard := int(shard_for_workspace(transmute([]byte)workspace))
	generation_dir := sharded_generation_path(data_dir, 8)
	defer delete(generation_dir)
	shard_dir := sharded_shard_path(generation_dir, shard)
	defer delete(shard_dir)
	writer: Shard_Transaction_Writer
	testing.expect(t, init_managed_shard_transaction_writer(&writer, shard_dir, shard, shard, LOGICAL_SHARD_COUNT))
	defer shutdown_shard_transaction_writer(&writer)

	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 10, "first metadata key"))
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 11, "second metadata key"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	first := shard_compaction_test_build_result(&writer)
	testing.expect(t, first.ok && publish_shard_compaction_result(&writer, first))
	destroy_shard_segment_clean_result(&first.segments)
	testing.expect(t, shard_compaction_test_append_task(&writer, workspace, 12, "tail metadata key"))
	testing.expect(t, rotate_shard_writer_for_compaction(&writer))
	second := shard_compaction_test_build_result(&writer)
	testing.expect(t, second.ok && publish_shard_compaction_result(&writer, second))
	destroy_shard_segment_clean_result(&second.segments)

	source, source_ok := shard_segment_source_for_writer(&writer)
	defer destroy_shard_segment_clean_source(&source)
	testing.expect(t, source_ok && len(source.segments) == 2)
	if !source_ok || len(source.segments) != 2 do return
	first_size, size_ok := shard_segment_descriptor_size(writer.storage, writer.shard_dir, source.segments[0])
	testing.expect(t, size_ok)
	result := build_shard_segment_catalog(
		writer.storage,
		writer.shard_dir,
		writer.manifest,
		writer.manifest.manifest_generation + 10,
		&source,
		1,
		SHARD_CLEANED_SEGMENT_MAX_BYTES,
		SHARD_SEGMENT_CLEAN_MAX_SOURCE_BYTES,
		1,
	)
	defer destroy_shard_segment_clean_result(&result)
	testing.expect(t, result.ok, "oversized prefix metadata must fall back instead of failing compaction")
	testing.expect(t, result.prefix_read_bytes >= first_size * 2, "overflow fallback should account metadata build and floor scan reads")
}
