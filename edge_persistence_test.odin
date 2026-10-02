//
// edge_persistence_test.odin - Tests and Benchmarks for Edge Persistence
//
// Tests:
// - Record serialization/parsing roundtrip
// - CRC validation and corruption detection
// - Hash chain linking
// - Empty payload handling
// - Fixed-order format verification
// - All relation types serialize correctly
// - All target types serialize correctly
//
// Benchmarks:
// - Full edge record serialization
//
package main

import "base:intrinsics"
import "base:runtime"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:hash/xxhash"
import "core:log"
import "core:testing"
import "core:time"

import "persistence"
import pr "protocol"

// ============================================================================
// Record Serialization Tests
// ============================================================================

@(test)
test_edge_record_structure :: proc(t: ^testing.T) {
	// Verify the record structure matches expected layout
	// Header: magic(4) + version(2) + op(1) + flags(1) + length(4) + prev_hash(32) + record_hash(4) = 48
	// Payload: workspace_len(2) + workspace + edge_id(8) + conv_id(8) + source_type(2) + source_id(8)
	//          + target_type(2) + target_id(8) + relation(2) + created_at(8) + created_by_len(2) + created_by

	workspace_id := "test-workspace"
	created_by := "alice"

	payload_size := 2 + len(workspace_id) + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + len(created_by)
	expected_record_size := persistence.LOG_HEADER_SIZE + payload_size

	// Verify current XXH64 header constant
	testing.expect_value(t, persistence.LOG_HEADER_SIZE, 52)

	// Build a record manually and verify structure
	buf := make([]byte, expected_record_size)
	defer delete(buf)

	// Fill header
	endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
	buf[6] = u8(Edge_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64 // flags
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	// prev_hash at 12-43 (zeros for first record)
	// record_hash at 44-51 (computed later)

	// Fill payload in fixed order
	payload_buf := buf[persistence.LOG_HEADER_SIZE:]
	offset := 0

	// workspace_id
	endian.put_u16(payload_buf[offset:], .Big, u16(len(workspace_id)))
	offset += 2
	copy(payload_buf[offset:], workspace_id)
	offset += len(workspace_id)

	// edge_id
	endian.put_u64(payload_buf[offset:], .Big, 42)
	offset += 8

	// conv_id
	endian.put_u64(payload_buf[offset:], .Big, 100)
	offset += 8

	// source_type
	endian.put_u16(payload_buf[offset:], .Big, u16(pr.TargetType.Asset))
	offset += 2

	// source_id
	endian.put_u64(payload_buf[offset:], .Big, 1001)
	offset += 8

	// target_type
	endian.put_u16(payload_buf[offset:], .Big, u16(pr.TargetType.Task))
	offset += 2

	// target_id
	endian.put_u64(payload_buf[offset:], .Big, 2001)
	offset += 8

	// relation
	endian.put_u16(payload_buf[offset:], .Big, u16(pr.RelationType.References))
	offset += 2

	// created_at
	endian.put_u64(payload_buf[offset:], .Big, 1234567890)
	offset += 8

	// created_by
	endian.put_u16(payload_buf[offset:], .Big, u16(len(created_by)))
	offset += 2
	copy(payload_buf[offset:], created_by)
	offset += len(created_by)

	testing.expect_value(t, offset, payload_size)

	// Verify magic can be read back
	read_magic, _ := endian.get_u32(buf[0:], .Big)
	testing.expect_value(t, read_magic, EDGE_LOG_MAGIC)

	// Verify version can be read back
	read_version, _ := endian.get_u16(buf[4:], .Big)
	testing.expect_value(t, read_version, EDGE_LOG_VERSION)

	// Verify op can be read back
	testing.expect_value(t, buf[6], u8(Edge_Log_Op.Create))
}

@(test)
test_edge_workspace_prefix_roundtrip :: proc(t: ^testing.T) {
	workspace_id := "my-test-workspace-123"

	buf: [256]byte
	written := persistence.write_workspace_prefix(buf[:], workspace_id)

	testing.expect_value(t, written, 2 + len(workspace_id))

	// Parse it back
	parsed_ws, offset, ok := persistence.parse_workspace_prefix(buf[:written])
	testing.expect(t, ok, "parse should succeed")
	testing.expect_value(t, offset, written)
	testing.expect(t, parsed_ws == workspace_id, "workspace should match")
}

@(test)
test_edge_payload_size_calculation :: proc(t: ^testing.T) {
	workspace_id := "workspace"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 42,
		source_type = .Asset,
		source_id   = 100,
		target_type = .Task,
		target_id   = 200,
		relation    = .DependsOn,
		created_at  = 1000,
		created_by  = transmute([]byte)string("alice"),
	}

	size := calculate_edge_payload_size(workspace_id, &edge)

	// Expected: ws(2+9) + edge_id(8) + conv_id(8) + source_type(2) + source_id(8)
	//           + target_type(2) + target_id(8) + relation(2) + created_at(8) + created_by(2+5)
	expected := 2 + 9 + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + 5
	testing.expect_value(t, size, expected)
}

// ============================================================================
// CRC Validation Tests
// ============================================================================

@(test)
test_edge_crc_computation :: proc(t: ^testing.T) {
	workspace_id := "test-workspace"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 42,
		source_type = .Asset,
		source_id   = 100,
		target_type = .Task,
		target_id   = 200,
		relation    = .References,
		created_at  = 1234567890,
		created_by  = transmute([]byte)string("bob"),
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	// Build header
	endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
	buf[6] = u8(Edge_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	// Build payload
	serialize_edge_to_record(buf, workspace_id, &edge)

	// Compute CRC
	record_crc := persistence.compute_record_crc64(buf, payload_size)
	endian.put_u64(buf[44:], .Big, record_crc)

	// Verify stored CRC
	stored_crc, _ := endian.get_u64(buf[44:], .Big)
	testing.expect_value(t, stored_crc, record_crc)

	// Recomputing should give same result
	recomputed_crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect_value(t, recomputed_crc, record_crc)
}

@(test)
test_edge_crc_detects_corruption :: proc(t: ^testing.T) {
	workspace_id := "workspace"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 1,
		source_type = .Asset,
		source_id   = 10,
		target_type = .Asset,
		target_id   = 20,
		relation    = .RelatedTo,
		created_at  = 1000,
		created_by  = transmute([]byte)string("user"),
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	// Build valid record
	endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
	buf[6] = u8(Edge_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	serialize_edge_to_record(buf, workspace_id, &edge)

	original_crc := persistence.compute_record_crc64(buf, payload_size)

	// Corrupt one byte in payload
	buf[persistence.LOG_HEADER_SIZE + 5] ~= 0xFF

	corrupted_crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect(t, corrupted_crc != original_crc, "CRC should detect corruption")
}

// ============================================================================
// Hash Chain Tests
// ============================================================================

@(test)
test_edge_hash_chain_linking :: proc(t: ^testing.T) {
	workspace_id := "ws"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 1,
		source_type = .Asset,
		source_id   = 10,
		target_type = .Task,
		target_id   = 20,
		relation    = .DependsOn,
		created_by  = transmute([]byte)string("test"),
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	buf1 := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	buf2 := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf1)
	defer delete(buf2)

	// Build first record with zero prev_hash
	endian.put_u32(buf1[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf1[4:], .Big, EDGE_LOG_VERSION)
	buf1[6] = u8(Edge_Log_Op.Create)
	buf1[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf1[8:], .Big, u32(payload_size))
	serialize_edge_to_record(buf1, workspace_id, &edge)

	crc1 := persistence.compute_record_crc64(buf1, payload_size)
	endian.put_u64(buf1[44:], .Big, crc1)

	// Compute hash of first record
	hash1: [32]byte
	hash.hash_bytes_to_buffer(.SHA256, buf1, hash1[:])

	// Build second record with prev_hash = hash of first
	edge.edge_id = 2
	endian.put_u32(buf2[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf2[4:], .Big, EDGE_LOG_VERSION)
	buf2[6] = u8(Edge_Log_Op.Create)
	buf2[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf2[8:], .Big, u32(payload_size))
	copy(buf2[12:44], hash1[:]) // prev_hash
	serialize_edge_to_record(buf2, workspace_id, &edge)

	crc2 := persistence.compute_record_crc64(buf2, payload_size)
	endian.put_u64(buf2[44:], .Big, crc2)

	// Verify prev_hash is set correctly
	prev_hash: [32]byte
	copy(prev_hash[:], buf2[12:44])
	testing.expect(t, prev_hash == hash1, "prev_hash should match first record hash")
}

// ============================================================================
// Empty and Edge Case Tests
// ============================================================================

@(test)
test_edge_empty_created_by :: proc(t: ^testing.T) {
	workspace_id := "ws"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 1,
		source_type = .Asset,
		source_id   = 10,
		target_type = .Asset,
		target_id   = 20,
		relation    = .References,
		created_at  = 1000,
		created_by  = nil, // Empty
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	// Should still have valid size (2+2 + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + 0)
	expected := 2 + 2 + 8 + 8 + 2 + 8 + 2 + 8 + 2 + 8 + 2 + 0
	testing.expect_value(t, payload_size, expected)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
	buf[6] = u8(Edge_Log_Op.Create)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	serialize_edge_to_record(buf, workspace_id, &edge)

	// Should compute valid CRC
	crc := persistence.compute_record_crc64(buf, payload_size)
	testing.expect(t, crc != 0, "CRC should be computed")
}

@(test)
test_edge_max_record_size :: proc(t: ^testing.T) {
	// Test edge with maximum reasonable field sizes
	workspace_buf := make([]byte, 128)
	defer delete(workspace_buf)
	for i in 0 ..< len(workspace_buf) {
		workspace_buf[i] = 'w'
	}
	workspace_id := string(workspace_buf)

	max_created_by := make([]byte, 64) // Reasonable max for created_by
	defer delete(max_created_by)
	for i in 0 ..< len(max_created_by) {
		max_created_by[i] = 'a'
	}

	edge := pr.Edge {
		edge_id     = 0xFFFFFFFFFFFFFFFF,
		conv_id     = 0xFFFFFFFFFFFFFFFF,
		source_type = .Task,
		source_id   = 0xFFFFFFFFFFFFFFFF,
		target_type = .Asset,
		target_id   = 0xFFFFFFFFFFFFFFFF,
		relation    = .Supersedes,
		created_at  = 0x7FFFFFFFFFFFFFFF,
		created_by  = max_created_by,
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	// Should fit in EDGE_MAX_RECORD_SIZE
	testing.expect(t, persistence.LOG_HEADER_SIZE + payload_size <= EDGE_MAX_RECORD_SIZE, "max edge should fit in record buffer")
}

@(test)
test_edge_delete_record_structure :: proc(t: ^testing.T) {
	// Delete records have minimal payload: workspace + conv_id + edge_id
	workspace_id := "test-ws"

	payload_size := 2 + len(workspace_id) + 8 + 8

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
	endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
	buf[6] = u8(Edge_Log_Op.Delete)
	buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
	endian.put_u32(buf[8:], .Big, u32(payload_size))

	payload := buf[persistence.LOG_HEADER_SIZE:]
	offset := persistence.write_workspace_prefix(payload, workspace_id)
	endian.put_u64(payload[offset:], .Big, 999) // conv_id
	offset += 8
	endian.put_u64(payload[offset:], .Big, 42) // edge_id

	// Should compute valid CRC
	crc := persistence.compute_record_crc64(buf, payload_size)
	endian.put_u64(buf[44:], .Big, crc)

	// Verify op is Delete
	testing.expect_value(t, buf[6], u8(Edge_Log_Op.Delete))

	// Verify length matches
	read_len, _ := endian.get_u32(buf[8:], .Big)
	testing.expect_value(t, read_len, u32(payload_size))
}

// ============================================================================
// Magic Number Tests
// ============================================================================

@(test)
test_edge_magic_number :: proc(t: ^testing.T) {
	// EDGE_LOG_MAGIC should be "NRCE" in ASCII
	// N=0x4E, R=0x52, C=0x43, E=0x45
	expected := 0x4E524345
	testing.expect_value(t, EDGE_LOG_MAGIC, expected)

	// Verify it differs from other magic numbers
	testing.expect(t, EDGE_LOG_MAGIC != TASK_LOG_MAGIC, "edge and task magic should differ")
	testing.expect(t, EDGE_LOG_MAGIC != ASSET_LOG_MAGIC, "edge and asset magic should differ")
}

// ============================================================================
// Relation Type Tests
// ============================================================================

@(test)
test_edge_all_relation_types_serialize :: proc(t: ^testing.T) {
	workspace_id := "ws"
	relation_types := []pr.RelationType{.References, .RelatedTo, .DependsOn, .Blocks, .DerivedFrom, .Supersedes}

	for relation in relation_types {
		edge := pr.Edge {
			edge_id     = 1,
			conv_id     = 1,
			source_type = .Asset,
			source_id   = 10,
			target_type = .Asset,
			target_id   = 20,
			relation    = relation,
		}

		payload_size := calculate_edge_payload_size(workspace_id, &edge)
		buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)

		endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
		endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
		buf[6] = u8(Edge_Log_Op.Create)
		endian.put_u32(buf[8:], .Big, u32(payload_size))

		serialize_edge_to_record(buf, workspace_id, &edge)

		// Verify relation is correctly written
		// Payload layout: ws_prefix + edge_id(8) + conv_id(8) + source_type(2) + source_id(8) + target_type(2) + target_id(8) + relation(2)
		payload := buf[persistence.LOG_HEADER_SIZE:]
		_, ws_offset, _ := persistence.parse_workspace_prefix(payload)
		relation_offset := ws_offset + 8 + 8 + 2 + 8 + 2 + 8
		read_relation, _ := endian.get_u16(payload[relation_offset:], .Big)
		testing.expect_value(t, pr.RelationType(read_relation), relation)

		delete(buf)
	}
}

// ============================================================================
// Target Type Tests
// ============================================================================

@(test)
test_edge_all_target_types_serialize :: proc(t: ^testing.T) {
	workspace_id := "ws"
	target_types := []pr.TargetType{.Asset, .Task}

	for source_type in target_types {
		for target_type in target_types {
			edge := pr.Edge {
				edge_id     = 1,
				conv_id     = 1,
				source_type = source_type,
				source_id   = 10,
				target_type = target_type,
				target_id   = 20,
				relation    = .References,
			}

			payload_size := calculate_edge_payload_size(workspace_id, &edge)
			buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)

			endian.put_u32(buf[0:], .Big, EDGE_LOG_MAGIC)
			endian.put_u16(buf[4:], .Big, EDGE_LOG_VERSION)
			buf[6] = u8(Edge_Log_Op.Create)
			endian.put_u32(buf[8:], .Big, u32(payload_size))

			serialize_edge_to_record(buf, workspace_id, &edge)

			// Verify source_type is correctly written
			payload := buf[persistence.LOG_HEADER_SIZE:]
			_, ws_offset, _ := persistence.parse_workspace_prefix(payload)
			source_type_offset := ws_offset + 8 + 8 // after edge_id and conv_id
			read_source_type, _ := endian.get_u16(payload[source_type_offset:], .Big)
			testing.expect_value(t, pr.TargetType(read_source_type), source_type)

			// Verify target_type is correctly written
			target_type_offset := source_type_offset + 2 + 8 // after source_type and source_id
			read_target_type, _ := endian.get_u16(payload[target_type_offset:], .Big)
			testing.expect_value(t, pr.TargetType(read_target_type), target_type)

			delete(buf)
		}
	}
}

// ============================================================================
// Benchmarks
// ============================================================================

Edge_Benchmark_State :: struct {
	workspace_id: string,
	edge:         ^pr.Edge,
	buf:          []byte,
	payload_size: int,
	checksum:     u64,
}

benchmark_edge_serialize_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Edge_Benchmark_State)options.user_data
	last_hash: [32]byte
	for _ in 0 ..< options.rounds {
		endian.put_u32(state.buf[0:], .Big, EDGE_LOG_MAGIC)
		endian.put_u16(state.buf[4:], .Big, EDGE_LOG_VERSION)
		state.buf[6] = u8(Edge_Log_Op.Create)
		state.buf[7] = persistence.LOG_FLAG_CHECKSUM_XXH64
		endian.put_u32(state.buf[8:], .Big, u32(state.payload_size))
		copy(state.buf[12:44], last_hash[:])
		serialize_edge_to_record(state.buf, state.workspace_id, state.edge)
		record_crc := persistence.compute_record_crc64(state.buf, state.payload_size)
		endian.put_u64(state.buf[44:], .Big, record_crc)
		hash.hash_bytes_to_buffer(.SHA256, state.buf, last_hash[:])
	}
	state.checksum, _ = endian.get_u64(last_hash[:], .Big)
	options.count = options.rounds
	options.processed = options.rounds * len(state.buf)
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_edge_size_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Edge_Benchmark_State)options.user_data
	for _ in 0 ..< options.rounds {
		workspace_id := intrinsics.volatile_load(&state.workspace_id)
		edge := intrinsics.volatile_load(&state.edge)
		state.checksum += u64(calculate_edge_payload_size(workspace_id, edge))
	}
	options.count = options.rounds
	options.hash = u128(state.checksum)
	return .Okay
}

benchmark_edge_hash_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Edge_Benchmark_State)options.user_data
	for _ in 0 ..< options.rounds {
		data := intrinsics.volatile_load(&state.buf)
		state.checksum += xxhash.XXH64(data)
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.buf)
	options.hash = u128(state.checksum)
	return .Okay
}

@(test)
benchmark_edge_record_serialization :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	workspace_id := "production-workspace-123"
	edge := pr.Edge {
		edge_id     = 12345,
		conv_id     = 999,
		source_type = .Asset,
		source_id   = 100001,
		target_type = .Task,
		target_id   = 200002,
		relation    = .DependsOn,
		created_at  = 1700000000000,
		created_by  = transmute([]byte)string("user@example.com"),
	}

	payload_size := calculate_edge_payload_size(workspace_id, &edge)

	buf := make([]byte, persistence.LOG_HEADER_SIZE + payload_size)
	defer delete(buf)

	iterations := 2_000_000
	state := Edge_Benchmark_State {
		workspace_id = workspace_id,
		edge         = &edge,
		buf          = buf,
		payload_size = payload_size,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_edge_serialize_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect(t, state.checksum != 0 && options.hash == u128(state.checksum), "serialization checksum must be observable")
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof(
		"benchmark_edge_record_serialization: %.2f ns/op, %.2f ops/s, %.2f MiB/s (%d iterations)",
		ns_per_op,
		options.rounds_per_second,
		options.megabytes_per_second,
		options.count,
	)
}

@(test)
benchmark_edge_payload_size_calculation :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	workspace_id := "workspace"
	edge := pr.Edge {
		edge_id     = 1,
		conv_id     = 42,
		source_type = .Asset,
		source_id   = 100,
		target_type = .Task,
		target_id   = 200,
		relation    = .References,
		created_at  = 1000,
		created_by  = transmute([]byte)string("user@example.com"),
	}

	iterations := 1_000_000_000
	state := Edge_Benchmark_State {
		workspace_id = workspace_id,
		edge         = &edge,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_edge_size_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	expected := u64(calculate_edge_payload_size(workspace_id, &edge)) * u64(iterations)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect_value(t, state.checksum, expected)
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof("benchmark_edge_payload_size_calculation: %.2f ns/op, %.2f ops/s (%d iterations)", ns_per_op, options.rounds_per_second, options.count)
}

@(test)
benchmark_edge_xxhash_crc :: proc(t: ^testing.T) {
	if !persistence_micro_benchmark_enabled() do return
	// Typical edge record size (smaller than assets)
	data := make([]byte, 256)
	defer delete(data)
	for i in 0 ..< len(data) {
		data[i] = u8(i)
	}

	iterations := 25_000_000
	state := Edge_Benchmark_State {
		buf = data,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_edge_hash_callback,
		rounds    = iterations,
		user_data = &state,
	}
	err := time.benchmark(&options)
	expected := xxhash.XXH64(data) * u64(iterations)
	testing.expect_value(t, err, time.Benchmark_Error.Okay)
	testing.expect_value(t, state.checksum, expected)
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof(
		"benchmark_edge_xxhash_crc (256 bytes): %.2f ns/op, %.2f ops/s, %.2f MiB/s (%d iterations)",
		ns_per_op,
		options.rounds_per_second,
		options.megabytes_per_second,
		options.count,
	)
}
