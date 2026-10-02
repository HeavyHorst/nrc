package main

import "core:encoding/endian"
import "core:hash/xxhash"
import "core:testing"

@(test)
test_shard_segment_catalog_variable_roundtrip_and_corruption :: proc(t: ^testing.T) {
	catalog := Shard_Segment_Catalog {
		shard              = 17,
		catalog_generation = 142,
		segments           = make([dynamic]Shard_Segment_Descriptor, 130),
	}
	defer destroy_shard_segment_catalog(&catalog)
	for index in 0 ..< len(catalog.segments) {
		catalog.segments[index] = {
			kind       = .Generation_WAL,
			generation = u64(index + 1),
		}
	}
	size, size_ok := shard_segment_catalog_encoded_size(len(catalog.segments))
	testing.expect(t, size_ok)
	data := make([]byte, size)
	defer delete(data)
	testing.expect(t, encode_shard_segment_catalog(catalog, data))
	decoded, ok := decode_shard_segment_catalog(data)
	defer destroy_shard_segment_catalog(&decoded)
	testing.expect(t, ok)
	testing.expect_value(t, decoded.shard, catalog.shard)
	testing.expect_value(t, decoded.catalog_generation, catalog.catalog_generation)
	testing.expect_value(t, len(decoded.segments), len(catalog.segments))
	if len(decoded.segments) == len(catalog.segments) {
		for descriptor, index in catalog.segments do testing.expect_value(t, decoded.segments[index], descriptor)
	}

	data[SHARD_SEGMENT_CATALOG_HEADER_SIZE + 8] ~= 1
	corrupt, corrupt_ok := decode_shard_segment_catalog(data)
	destroy_shard_segment_catalog(&corrupt)
	testing.expect(t, !corrupt_ok)
	short, short_ok := decode_shard_segment_catalog(data[:len(data) - 1])
	destroy_shard_segment_catalog(&short)
	testing.expect(t, !short_ok)
}

@(test)
test_shard_segment_catalog_rejects_invalid_catalogs :: proc(t: ^testing.T) {
	_, too_many_ok := shard_segment_catalog_encoded_size(SHARD_SEGMENT_CATALOG_MAX_SEGMENTS + 1)
	testing.expect(t, !too_many_ok)
	catalog := Shard_Segment_Catalog {
		shard              = 1,
		catalog_generation = 1,
		segments           = make([dynamic]Shard_Segment_Descriptor, 1),
	}
	defer destroy_shard_segment_catalog(&catalog)
	catalog.segments[0] = {.Legacy_Checkpoint_WAL, 1}
	size, _ := shard_segment_catalog_encoded_size(1)
	data := make([]byte, size)
	defer delete(data)

	catalog.segments[0].kind = Shard_Segment_Kind(99)
	testing.expect(t, !encode_shard_segment_catalog(catalog, data))
	catalog.segments[0] = {.Legacy_Checkpoint_WAL, 0}
	testing.expect(t, !encode_shard_segment_catalog(catalog, data))
	catalog.segments[0] = {.Cleaned_Segment, 0}
	testing.expect(t, !encode_shard_segment_catalog(catalog, data))
	resize(&catalog.segments, 2)
	catalog.segments[0] = {.Generation_WAL, 1}
	catalog.segments[1] = catalog.segments[0]
	data_two := make([]byte, SHARD_SEGMENT_CATALOG_HEADER_SIZE + 2 * SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE + SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE)
	defer delete(data_two)
	testing.expect(t, !encode_shard_segment_catalog(catalog, data_two))
	catalog.segments[1] = {.Adopted_Generation_WAL, 1}
	testing.expect(t, !encode_shard_segment_catalog(catalog, data_two))
	catalog.segments[0] = {.Adopted_Generation_WAL, 0}
	resize(&catalog.segments, 1)
	testing.expect(t, encode_shard_segment_catalog(catalog, data))
}

@(test)
test_shard_segment_catalog_decode_rejects_reserved_and_invalid_kind :: proc(t: ^testing.T) {
	catalog := Shard_Segment_Catalog {
		shard              = 1,
		catalog_generation = 1,
		segments           = make([dynamic]Shard_Segment_Descriptor, 1),
	}
	defer destroy_shard_segment_catalog(&catalog)
	catalog.segments[0] = {.Generation_WAL, 3}
	size, _ := shard_segment_catalog_encoded_size(1)
	data := make([]byte, size)
	defer delete(data)
	testing.expect(t, encode_shard_segment_catalog(catalog, data))
	checksum_offset := len(data) - SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE

	data[20] = 1
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	reserved, reserved_ok := decode_shard_segment_catalog(data)
	destroy_shard_segment_catalog(&reserved)
	testing.expect(t, !reserved_ok)
	data[20] = 0
	data[SHARD_SEGMENT_CATALOG_HEADER_SIZE + 1] = 1
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	descriptor_reserved, descriptor_reserved_ok := decode_shard_segment_catalog(data)
	testing.expect(t, !descriptor_reserved_ok)
	testing.expect_value(t, cap(descriptor_reserved.segments), 0)
	destroy_shard_segment_catalog(&descriptor_reserved)
	data[SHARD_SEGMENT_CATALOG_HEADER_SIZE + 1] = 0
	data[SHARD_SEGMENT_CATALOG_HEADER_SIZE] = 99
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	invalid, kind_ok := decode_shard_segment_catalog(data)
	testing.expect(t, !kind_ok)
	testing.expect_value(t, cap(invalid.segments), 0)
	destroy_shard_segment_catalog(&invalid)
}

@(test)
test_shard_segment_catalog_decodes_legacy_fixed_size_and_rejects_nonzero_padding :: proc(t: ^testing.T) {
	data: [SHARD_SEGMENT_CATALOG_LEGACY_SIZE]byte
	endian.put_u32(data[0:], .Big, SHARD_SEGMENT_CATALOG_MAGIC)
	endian.put_u16(data[4:], .Big, SHARD_SEGMENT_CATALOG_LEGACY_VERSION)
	endian.put_u16(data[6:], .Big, 17)
	endian.put_u64(data[8:], .Big, 42)
	endian.put_u16(data[16:], .Big, 2)
	first_offset := SHARD_SEGMENT_CATALOG_HEADER_SIZE
	data[first_offset] = byte(Shard_Segment_Kind.Legacy_Checkpoint_WAL)
	endian.put_u64(data[first_offset + 8:], .Big, 7)
	second_offset := first_offset + SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
	data[second_offset] = byte(Shard_Segment_Kind.Generation_WAL)
	endian.put_u64(data[second_offset + 8:], .Big, 8)
	checksum_offset := len(data) - SHARD_SEGMENT_CATALOG_CHECKSUM_SIZE
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))

	decoded, ok := decode_shard_segment_catalog(data[:])
	testing.expect(t, ok)
	testing.expect_value(t, decoded.shard, 17)
	testing.expect_value(t, decoded.catalog_generation, u64(42))
	testing.expect_value(t, len(decoded.segments), 2)
	if len(decoded.segments) == 2 {
		testing.expect_value(t, decoded.segments[0], Shard_Segment_Descriptor{.Legacy_Checkpoint_WAL, 7})
		testing.expect_value(t, decoded.segments[1], Shard_Segment_Descriptor{.Generation_WAL, 8})
	}
	destroy_shard_segment_catalog(&decoded)

	data[18] = 1
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	reserved, reserved_ok := decode_shard_segment_catalog(data[:])
	destroy_shard_segment_catalog(&reserved)
	testing.expect(t, !reserved_ok)
	data[18] = 0

	unused_offset := second_offset + SHARD_SEGMENT_CATALOG_DESCRIPTOR_SIZE
	data[unused_offset] = 1
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	unused, unused_ok := decode_shard_segment_catalog(data[:])
	testing.expect(t, !unused_ok)
	testing.expect_value(t, cap(unused.segments), 0)
	destroy_shard_segment_catalog(&unused)
	data[unused_offset] = 0

	endian.put_u16(data[16:], .Big, SHARD_SEGMENT_CATALOG_LEGACY_MAX_SEGMENTS + 1)
	endian.put_u64(data[checksum_offset:], .Big, xxhash.XXH64(data[:checksum_offset]))
	too_many, too_many_ok := decode_shard_segment_catalog(data[:])
	destroy_shard_segment_catalog(&too_many)
	testing.expect(t, !too_many_ok)
}

@(test)
test_shard_segment_catalog_paths :: proc(t: ^testing.T) {
	catalog_path := shard_segment_catalog_path("data/shard-007", 19)
	temp_path := shard_segment_catalog_temp_path("data/shard-007", 19)
	cleaned_path := shard_cleaned_segment_path("data/shard-007", 23)
	cleaned_temp_path := shard_cleaned_segment_temp_path("data/shard-007", 23)
	adopted_path := shard_segment_descriptor_path("data/shard-007", {.Adopted_Generation_WAL, 29})
	defer delete(catalog_path)
	defer delete(temp_path)
	defer delete(cleaned_path)
	defer delete(cleaned_temp_path)
	defer delete(adopted_path)
	testing.expect_value(t, catalog_path, "data/shard-007/catalog-00000000000000000019.cat")
	testing.expect_value(t, temp_path, "data/shard-007/catalog-00000000000000000019.tmp")
	testing.expect_value(t, cleaned_path, "data/shard-007/cleaned-00000000000000000023.seg")
	testing.expect_value(t, cleaned_temp_path, "data/shard-007/cleaned-00000000000000000023.tmp")
	testing.expect_value(t, adopted_path, "data/shard-007/wal-00000000000000000029.wal")
}
