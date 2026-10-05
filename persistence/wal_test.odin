//
// persistence/wal_test.odin - Tests for WAL replay truncation behavior
//
// Tests:
// - W1: Truncation on CRC mismatch
// - W2: Truncation on hash chain break
// - W3: Truncation on incomplete record
// - W4: Truncation on invalid magic number
// - W5: Replay with non-zero initial hash
// - W13: Short write poisons WAL and replay truncates trailing bytes
// - W14: Durability contract separates written from fsynced state
// - W15: Oversized record bypasses write batch buffer safely
//
package persistence

import "../storage_io"
import "core:bytes"
import "core:crypto/hash"
import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:log"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:sys/linux"
import "core:testing"
import "core:time"

when !NRC_SIMULATION {
	_ :: bytes.equal
}

// ============================================================================
// Test Constants
// ============================================================================

TEST_MAGIC :: 0x54455354 // "TEST"
TEST_VERSION :: u16(1)
TEST_THREAD_INDEX :: 99

// Simple test ops
Test_Op :: enum u8 {
	Create = 1,
	Update = 2,
	Delete = 3,
}

// ============================================================================
// Test Helpers
// ============================================================================

@(thread_local)
test_wal_time_counter: i64
@(thread_local)
direct_short_read_data: []byte
@(thread_local)
direct_short_read_calls: int

test_short_direct_pread :: proc "contextless" (_: linux.Fd, buf: []byte, offset: i64) -> (int, linux.Errno) {
	direct_short_read_calls += 1
	if offset < 0 || offset >= i64(len(direct_short_read_data)) do return 0, .NONE
	read_size := min(len(buf), len(direct_short_read_data) - int(offset), 4096)
	if direct_short_read_calls <= 5 do read_size = min(read_size, 2048)
	copy(buf[:read_size], direct_short_read_data[int(offset):int(offset) + read_size])
	return read_size, .NONE
}

test_no_progress_direct_pread :: proc "contextless" (_: linux.Fd, buf: []byte, offset: i64) -> (int, linux.Errno) {
	direct_short_read_calls += 1
	if offset < 0 || offset >= i64(len(direct_short_read_data)) do return 0, .NONE
	read_size := min(len(buf), len(direct_short_read_data) - int(offset), 2048)
	copy(buf[:read_size], direct_short_read_data[int(offset):int(offset) + read_size])
	return read_size, .NONE
}

when NRC_SIMULATION {
	@(thread_local)
	mixed_virtual_replay_count: int
	@(thread_local)
	mixed_virtual_replay_ok: bool
}

test_read_file :: proc(path: string) -> ([]byte, bool) {
	data, err := os.read_entire_file(path, context.allocator)
	return data, err == nil
}

test_write_file :: proc(path: string, data: []byte) -> bool {
	return os.write_entire_file(path, data) == nil
}

test_wal_time_now :: proc "contextless" () -> time.Time {
	test_wal_time_counter += 1_000_000 // Advance 1ms per call
	return time.Time{_nsec = test_wal_time_counter}
}

benchmark_wal_time_now :: proc "contextless" () -> time.Time {
	return time.now()
}

benchmark_wal_env_int :: proc(name: string, fallback: int) -> int {
	value, found := os.lookup_env_alloc(name, context.allocator)
	if !found do return fallback
	defer delete(value)
	parsed, ok := strconv.parse_int(value)
	if !ok || parsed <= 0 do return fallback
	return int(parsed)
}

benchmark_wal_external_barrier :: proc(phase: string) -> bool {
	ready_prefix := os.get_env_alloc("NRC_WAL_BENCH_READY_PREFIX", context.allocator)
	defer delete(ready_prefix)
	start_prefix := os.get_env_alloc("NRC_WAL_BENCH_START_PREFIX", context.allocator)
	defer delete(start_prefix)
	if ready_prefix == "" && start_prefix == "" do return true
	if ready_prefix == "" || start_prefix == "" do return false
	ready_path := fmt.aprintf("%s-%s", ready_prefix, phase)
	defer delete(ready_path)
	start_path := fmt.aprintf("%s-%s", start_prefix, phase)
	defer delete(start_path)
	if os.write_entire_file(ready_path, nil) != nil do return false
	wait_started := time.now()
	for !os.exists(start_path) && time.since(wait_started) < 30 * time.Second do time.sleep(time.Millisecond)
	return os.exists(start_path)
}

reset_test_wal_clock :: proc() {
	test_wal_time_counter = 1_000_000_000_000
}

test_wal_path :: proc(name: string) -> string {
	mode := "prod"
	when NRC_SIMULATION {
		mode = "sim"
	}
	filename := fmt.tprintf("%s-pid%d-%s", mode, os.get_pid(), name)
	path, err := filepath.join({DATA_DIR, filename}, context.temp_allocator)
	if err != nil {
		return fmt.tprintf("%s/%s", DATA_DIR, filename)
	}
	return path
}

cleanup_wal_file :: proc(path: string) {
	os.remove(path)
}

// ============================================================================
// Test Infrastructure
// ============================================================================

// Write a valid record directly to a file (for test setup)
// Returns the SHA-256 hash of the written record and the record size
write_test_record :: proc(path: string, op: Test_Op, payload: string, prev_hash: ^[32]byte) -> (record_hash: [32]byte, record_size: int, ok: bool) {
	buf: [MAX_CRC_BUF_SIZE + LOG_HEADER_SIZE]byte
	record_size = LEGACY_LOG_HEADER_SIZE + len(payload)

	// Build header
	endian.put_u32(buf[0:], .Big, TEST_MAGIC)
	endian.put_u16(buf[4:], .Big, TEST_VERSION)
	buf[6] = u8(op)
	buf[7] = 0 // flags
	endian.put_u32(buf[8:], .Big, u32(len(payload)))
	copy(buf[12:44], prev_hash[:])

	// Copy payload
	copy(buf[LEGACY_LOG_HEADER_SIZE:], transmute([]byte)payload)

	// Compute and write CRC
	crc_state: xxhash.XXH32_state
	crc := compute_record_crc(&crc_state, buf[:record_size], len(payload))
	endian.put_u32(buf[44:], .Big, crc)

	// Compute record hash for chain linking
	hash.hash_bytes_to_buffer(.SHA256, buf[:record_size], record_hash[:])

	// Append to file
	f, err := os.open(path, {.Write, .Create, .Append}, os.perm(0o644))
	if err != nil {
		return record_hash, record_size, false
	}
	defer os.close(f)

	buf_slice := buf[:record_size]
	written, write_err := os.write(f, buf_slice)
	if write_err != nil || written != record_size {
		return record_hash, record_size, false
	}

	return record_hash, record_size, true
}

// Test apply function that just counts records
test_apply_fn :: proc(op: u8, version: u16, payload: []byte) -> bool {
	return true // Continue replay
}

make_test_record_buffer :: proc(payload: string) -> []byte {
	buf := make([]byte, LOG_HEADER_SIZE + len(payload))
	copy(buf[LOG_HEADER_SIZE:], transmute([]byte)payload)
	return buf
}

when NRC_SIMULATION {
	make_legacy_test_record_buffer :: proc(op: Test_Op, payload: string, prev_hash: ^[32]byte) -> (record: []byte, record_hash: [32]byte) {
		record = make([]byte, LEGACY_LOG_HEADER_SIZE + len(payload))
		endian.put_u32(record[0:], .Big, TEST_MAGIC)
		endian.put_u16(record[4:], .Big, TEST_VERSION)
		record[6] = u8(op)
		record[7] = 0
		endian.put_u32(record[8:], .Big, u32(len(payload)))
		copy(record[12:44], prev_hash[:])
		copy(record[LEGACY_LOG_HEADER_SIZE:], transmute([]byte)payload)

		crc_state: xxhash.XXH32_state
		crc := compute_record_crc(&crc_state, record, len(payload))
		endian.put_u32(record[44:], .Big, crc)
		hash.hash_bytes_to_buffer(.SHA256, record, record_hash[:])
		return record, record_hash
	}

	mixed_virtual_apply_fn :: proc(op: u8, version: u16, payload: []byte) -> bool {
		if version != TEST_VERSION {
			mixed_virtual_replay_ok = false
			return true
		}

		expected: []byte
		switch mixed_virtual_replay_count {
		case 0:
			expected = transmute([]byte)string("legacy-one")
			if op != u8(Test_Op.Create) {
				mixed_virtual_replay_ok = false
			}
		case 1:
			expected = transmute([]byte)string("current-two")
			if op != u8(Test_Op.Update) {
				mixed_virtual_replay_ok = false
			}
		case:
			mixed_virtual_replay_ok = false
			return true
		}

		if !bytes.equal(payload, expected) {
			mixed_virtual_replay_ok = false
		}
		mixed_virtual_replay_count += 1
		return true
	}

	reset_mixed_virtual_apply_state :: proc() {
		mixed_virtual_replay_count = 0
		mixed_virtual_replay_ok = true
	}
}

when NRC_SIMULATION {
	@(test)
	test_virtual_wal_replays_mixed_legacy_xxh32_and_current_xxh64 :: proc(t: ^testing.T) {
		device: Virtual_WAL_Device
		virtual_wal_device_init(&device)
		defer virtual_wal_device_destroy(&device)

		path := "virtual/mixed_checksum_formats"
		file := virtual_wal_open_file(&device, path)
		testing.expect(t, file != nil, "virtual WAL file should open")
		if file == nil {
			return
		}

		prev_hash: [32]byte
		legacy_record, legacy_hash := make_legacy_test_record_buffer(.Create, "legacy-one", &prev_hash)
		defer delete(legacy_record)

		testing.expect(t, virtual_wal_replace_durable(file, legacy_record), "should seed durable legacy record")
		testing.expect_value(t, len(virtual_wal_durable_bytes(file)), LEGACY_LOG_HEADER_SIZE + len("legacy-one"))

		reset_test_wal_clock()
		state: WAL_State
		testing.expect(
			t,
			init_virtual_wal(&state, file, path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now),
			"virtual WAL should initialize",
		)
		defer shutdown_wal(&state)

		reset_mixed_virtual_apply_state()
		legacy_replay := replay_virtual_wal(file, TEST_MAGIC, TEST_THREAD_INDEX, mixed_virtual_apply_fn)
		testing.expect(t, legacy_replay.ok, "legacy-only replay should succeed")
		testing.expect_value(t, legacy_replay.record_count, u64(1))
		testing.expect(t, mixed_virtual_replay_ok, "legacy replay payload should match")
		testing.expect_value(t, mixed_virtual_replay_count, 1)
		testing.expect(t, legacy_replay.last_hash == legacy_hash, "legacy replay should return legacy record hash")

		set_recovered_wal_state(&state, legacy_replay.last_hash, legacy_replay.record_count)
		current_record := make_test_record_buffer("current-two")
		defer delete(current_record)
		testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Update), current_record), "current XXH64 record should append after legacy record")
		force_fsync(&state)

		durable := virtual_wal_durable_bytes(file)
		expected_len := LEGACY_LOG_HEADER_SIZE + len("legacy-one") + LOG_HEADER_SIZE + len("current-two")
		testing.expect_value(t, len(durable), expected_len)
		testing.expect_value(t, durable[LEGACY_LOG_HEADER_SIZE + len("legacy-one") + 7], LOG_FLAG_CHECKSUM_XXH64)

		reset_mixed_virtual_apply_state()
		mixed_replay := replay_virtual_wal(file, TEST_MAGIC, TEST_THREAD_INDEX, mixed_virtual_apply_fn)
		testing.expect(t, mixed_replay.ok, "mixed legacy/current replay should succeed")
		testing.expect_value(t, mixed_replay.record_count, u64(2))
		testing.expect(t, mixed_virtual_replay_ok, "mixed replay payloads should match in order")
		testing.expect_value(t, mixed_virtual_replay_count, 2)
		testing.expect(t, mixed_replay.last_hash == state.last_hash, "mixed replay head should match append state")
	}

}

// ============================================================================
// Test W1 - Fail closed on CRC mismatch
// ============================================================================

@(test)
test_replay_rejects_crc_mismatch_without_truncation :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w1_crc.log")

	// Clean up
	os.remove(test_path)
	defer os.remove(test_path)

	// Ensure data dir exists
	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	// Write 3 valid records
	prev_hash: [32]byte

	hash1, size1, ok1 := write_test_record(test_path, .Create, "record one", &prev_hash)
	testing.expect(t, ok1, "should write record 1")

	hash2, size2, ok2 := write_test_record(test_path, .Update, "record two", &hash1)
	testing.expect(t, ok2, "should write record 2")

	_, _, ok3 := write_test_record(test_path, .Update, "record three", &hash2)
	testing.expect(t, ok3, "should write record 3")

	// Corrupt the CRC of record 2 (at offset size1 + 44)
	data, read_ok := test_read_file(test_path)
	testing.expect(t, read_ok, "should read file")
	defer delete(data)

	original_size := len(data)
	crc_offset := size1 + 44
	data[crc_offset] ~= 0xFF // Flip bits in CRC

	test_write_file(test_path, data)

	// A complete corrupt record is not an interrupted append. Fail without
	// destroying it so an operator can recover from an intact copy.
	result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)

	testing.expect(t, !result.ok, "replay should reject complete corruption")

	unchanged_data, _ := test_read_file(test_path)
	defer delete(unchanged_data)
	testing.expect_value(t, len(unchanged_data), original_size)

	_ = size2
}

// ============================================================================
// Test W2 - Fail closed on hash chain break
// ============================================================================

@(test)
test_replay_rejects_hash_chain_break_without_truncation :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w2_chain.log")

	// Clean up
	os.remove(test_path)
	defer os.remove(test_path)

	// Ensure data dir exists
	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	// Write record 1
	prev_hash: [32]byte

	hash1, size1, ok1 := write_test_record(test_path, .Create, "record one", &prev_hash)
	testing.expect(t, ok1, "should write record 1")

	// Write record 2 with WRONG prev_hash (break the chain)
	wrong_hash: [32]byte
	wrong_hash[0] = 0xFF // Different from hash1

	_, size2, ok2 := write_test_record(test_path, .Update, "record two", &wrong_hash)
	testing.expect(t, ok2, "should write record 2")

	// Write record 3 (would be valid if record 2 was valid)
	// But we need to use hash2 which we don't have since we used wrong_hash
	// Just write another record with some hash
	payload3 := "record three"
	_, _, ok3 := write_test_record(test_path, .Update, payload3, &wrong_hash)
	testing.expect(t, ok3, "should write record 3")

	original_size := size1 + size2 + LEGACY_LOG_HEADER_SIZE + len(payload3)
	_ = hash1

	// Replay must reject a complete broken chain without mutating evidence.
	result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)

	testing.expect(t, !result.ok, "replay should reject a broken hash chain")

	unchanged_data, _ := test_read_file(test_path)
	defer delete(unchanged_data)
	testing.expect_value(t, len(unchanged_data), original_size)
}

// ============================================================================
// Test W3 - Recover a bounded, chain-linked incomplete final record
// ============================================================================

@(test)
test_replay_recovers_bounded_chain_linked_incomplete_record :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w3_incomplete.log")

	// Clean up
	os.remove(test_path)
	defer os.remove(test_path)

	// Ensure data dir exists
	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	// Write 2 valid records
	prev_hash: [32]byte

	hash1, size1, ok1 := write_test_record(test_path, .Create, "record one", &prev_hash)
	testing.expect(t, ok1, "should write record 1")

	hash2, size2, ok2 := write_test_record(test_path, .Update, "record two", &hash1)
	testing.expect(t, ok2, "should write record 2")

	// Write an incomplete record (just the header, no payload)
	buf: [LEGACY_LOG_HEADER_SIZE]byte
	payload3 := "this will be truncated"
	endian.put_u32(buf[0:], .Big, TEST_MAGIC)
	endian.put_u16(buf[4:], .Big, TEST_VERSION)
	buf[6] = u8(Test_Op.Update)
	buf[7] = 0
	endian.put_u32(buf[8:], .Big, u32(len(payload3))) // Says payload is 22 bytes
	copy(buf[12:44], hash2[:])
	// CRC doesn't matter since we won't have full payload

	// Append incomplete record
	f, _ := os.open(test_path, {.Write, .Append})
	os.write(f, buf[:]) // Only header, no payload
	os.close(f)

	// A bounded header linked to the current chain is an interrupted final
	// append. Complete checksum failures remain non-recoverable corruption.
	result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)

	testing.expect(t, result.ok, "replay should recover a physically incomplete final append")
	testing.expect_value(t, result.record_count, u64(2))

	recovered_data, _ := test_read_file(test_path)
	defer delete(recovered_data)
	testing.expect_value(t, len(recovered_data), size1 + size2)
}

// ============================================================================
// Test W4 - Fail closed on invalid magic number
// ============================================================================

@(test)
test_replay_rejects_invalid_magic_without_truncation :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w4_magic.log")

	// Clean up
	os.remove(test_path)
	defer os.remove(test_path)

	// Ensure data dir exists
	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	// Write 2 valid records
	prev_hash: [32]byte

	hash1, size1, ok1 := write_test_record(test_path, .Create, "record one", &prev_hash)
	testing.expect(t, ok1, "should write record 1")

	_, size2, ok2 := write_test_record(test_path, .Update, "record two", &hash1)
	testing.expect(t, ok2, "should write record 2")

	// Corrupt the magic number of record 2
	data, read_ok := test_read_file(test_path)
	testing.expect(t, read_ok, "should read file")
	defer delete(data)

	original_size := len(data)

	// Corrupt magic at start of record 2
	data[size1] = 0xBA
	data[size1 + 1] = 0xAD

	test_write_file(test_path, data)

	// Replay must reject a complete invalid record without mutating evidence.
	result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)

	testing.expect(t, !result.ok, "replay should reject invalid magic")

	unchanged_data, _ := test_read_file(test_path)
	defer delete(unchanged_data)
	testing.expect_value(t, len(unchanged_data), original_size)

	_ = size2
}

// ============================================================================
// Test W5 - Replay with non-zero initial hash
// ============================================================================

@(test)
test_replay_with_initial_hash :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w5_initial_hash.log")

	cleanup_wal_file(test_path)
	defer cleanup_wal_file(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	initial_hash: [32]byte
	initial_hash[0] = 0xAB

	hash1, _, ok1 := write_test_record(test_path, .Create, "record one", &initial_hash)
	testing.expect(t, ok1, "should write record with non-zero initial hash")

	result := replay_wal_with_initial_hash(test_path, TEST_MAGIC, TEST_THREAD_INDEX, initial_hash, test_apply_fn)
	testing.expect(t, result.ok, "replay with initial hash should succeed")
	testing.expect_value(t, result.record_count, u64(1))
	testing.expect(t, result.last_hash == hash1, "last hash should match record hash")
}

// ============================================================================
// Test W13 - Short write poisons WAL and replay truncates trailing bytes
// ============================================================================

@(test)
test_short_write_poisons_wal_and_replay_truncates_trailing_bytes :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w13_short_write.log")

	os.remove(test_path)
	defer os.remove(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	reset_test_wal_clock()
	clear_wal_write_fault_for_test()
	defer clear_wal_write_fault_for_test()
	state: WAL_State
	init_ok := init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)
	testing.expect(t, init_ok, "init_wal should succeed")
	if !init_ok {
		return
	}
	defer shutdown_wal(&state)

	record_one := make_test_record_buffer("record-one")
	defer delete(record_one)
	record_two := make_test_record_buffer("record-two")
	defer delete(record_two)

	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), record_one), "first record should stage successfully")
	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Update), record_two), "second record should stage successfully")

	first_record_size := LOG_HEADER_SIZE + len("record-one")
	set_wal_short_write_for_test(first_record_size + 3)

	previous_logger := context.logger
	context.logger = log.nil_logger()
	flush_ok := flush_write_batch(&state)
	context.logger = previous_logger
	testing.expect(t, !flush_ok, "flush should fail on injected short write")
	testing.expect(t, wal_write_fault_triggered_for_test(), "short write fault should trigger")
	testing.expect(t, !state.enabled, "WAL should be poisoned after ambiguous append")
	testing.expect_value(t, state.write_offset, 0)
	testing.expect_value(t, state.buffered_record_count, u64(0))
	testing.expect_value(t, state.record_count, u64(0))
	testing.expect_value(t, state.durable_record_count, u64(0))

	replay_result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	testing.expect(t, replay_result.ok, "replay after short write should succeed")
	testing.expect_value(t, replay_result.record_count, u64(1))

	truncated_data, read_ok := test_read_file(test_path)
	testing.expect(t, read_ok, "should read truncated WAL")
	defer delete(truncated_data)
	testing.expect_value(t, len(truncated_data), first_record_size)
}

// ============================================================================
// Test W14 - Durability contract separates written from fsynced state
// ============================================================================

@(test)
test_wal_durability_contract_tracks_written_vs_fsynced_state :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w14_durability_contract.log")

	os.remove(test_path)
	defer os.remove(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	reset_test_wal_clock()
	clear_wal_write_fault_for_test()
	defer clear_wal_write_fault_for_test()

	state: WAL_State
	init_ok := init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)
	testing.expect(t, init_ok, "init_wal should succeed")
	if !init_ok {
		return
	}
	defer shutdown_wal(&state)

	record := make_test_record_buffer("durable")
	defer delete(record)

	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), record), "record should stage successfully")
	testing.expect_value(t, state.buffered_record_count, u64(1))
	testing.expect_value(t, state.record_count, u64(0))
	testing.expect_value(t, state.durable_record_count, u64(0))

	testing.expect(t, flush_write_batch(&state), "flush should succeed")
	testing.expect_value(t, state.buffered_record_count, u64(0))
	testing.expect_value(t, state.record_count, u64(1))
	testing.expect_value(t, state.durable_record_count, u64(0))
	testing.expect(t, state.last_hash != [32]byte{}, "written state should advance after successful write")
	testing.expect(t, state.durable_last_hash == [32]byte{}, "durable hash should not advance before fsync")
	testing.expect(t, state.pending_bytes > 0, "pending bytes should track written-not-fsynced data")

	force_fsync(&state)
	testing.expect_value(t, state.record_count, u64(1))
	testing.expect_value(t, state.durable_record_count, u64(1))
	testing.expect(t, state.durable_last_hash == state.last_hash, "durable hash should catch up after fsync")
	testing.expect_value(t, state.pending_bytes, u64(0))
}

@(test)
test_async_fsync_snapshot_does_not_cover_later_writes :: proc(t: ^testing.T) {
	test_path := test_wal_path("test-wal-async-fsync-snapshot.log")
	_ = os.remove(test_path)
	defer os.remove(test_path)
	reset_test_wal_clock()

	state: WAL_State
	testing.expect(t, init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now))
	defer shutdown_wal(&state)
	first := make_test_record_buffer("first")
	defer delete(first)
	second := make_test_record_buffer("second")
	defer delete(second)
	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), first))
	testing.expect(t, flush_write_batch_deferred_fsync(&state))
	state.pending_bytes = FSYNC_BYTE_THRESHOLD
	snapshot, due := prepare_async_fsync(&state)
	testing.expect(t, due)
	testing.expect_value(t, snapshot.record_count, u64(1))

	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Update), second))
	testing.expect(t, flush_write_batch_deferred_fsync(&state))
	latest_hash := state.last_hash
	later_pending_bytes := state.pending_bytes - snapshot.pending_bytes
	testing.expect(t, later_pending_bytes > 0)
	testing.expect(t, complete_async_fsync(&state, snapshot, 2 * time.Millisecond, .NONE))
	testing.expect_value(t, state.durable_record_count, u64(1))
	testing.expect(t, state.durable_last_hash == snapshot.last_hash)
	testing.expect_value(t, state.record_count, u64(2))
	testing.expect(t, state.last_hash == latest_hash && state.last_hash != state.durable_last_hash)
	testing.expect_value(t, state.pending_bytes, later_pending_bytes)
	testing.expect_value(t, state.fsync_count, u64(1))
	testing.expect_value(t, state.total_fsync_latency_ns, u64(2_000_000))
}

@(test)
test_async_fsync_failure_poisons_wal :: proc(t: ^testing.T) {
	state := WAL_State {
		enabled      = true,
		thread_index = TEST_THREAD_INDEX,
		get_time     = test_wal_time_now,
	}
	previous_logger := context.logger
	context.logger = log.nil_logger()
	completed := complete_async_fsync(&state, {}, time.Millisecond, .EIO)
	context.logger = previous_logger
	testing.expect(t, !completed)
	testing.expect(t, !state.enabled)
	testing.expect_value(t, state.write_failures, u64(1))
	testing.expect_value(t, state.fsync_count, u64(0))
}

@(test)
test_wal_flush_propagates_inline_fsync_failure :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w14_inline_fsync_failure.log")

	os.remove(test_path)
	defer os.remove(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	reset_test_wal_clock()
	clear_wal_write_fault_for_test()
	clear_wal_sync_failure_for_test()
	defer clear_wal_write_fault_for_test()
	defer clear_wal_sync_failure_for_test()
	state: WAL_State
	init_ok := init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)
	testing.expect(t, init_ok, "init_wal should succeed")
	if !init_ok {
		return
	}
	defer shutdown_wal(&state)

	record := make_test_record_buffer("fsync-fail")
	defer delete(record)

	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), record), "record should stage successfully")
	state.pending_bytes = FSYNC_BYTE_THRESHOLD
	set_wal_sync_failure_for_test()

	previous_logger := context.logger
	context.logger = log.nil_logger()
	flush_ok := flush_write_batch(&state)
	context.logger = previous_logger
	testing.expect(t, !flush_ok, "flush should propagate inline fsync failure")
	testing.expect(t, wal_sync_fault_triggered_for_test(), "sync failpoint should trigger")
	testing.expect(t, !state.enabled, "WAL should be poisoned after fsync failure")
	testing.expect_value(t, state.record_count, u64(1))
	testing.expect_value(t, state.durable_record_count, u64(0))
}

@(test)
test_shutdown_wal_propagates_final_fsync_failure :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_shutdown_fsync_failure.log")
	os.remove(test_path)
	defer os.remove(test_path)
	if !os.exists(DATA_DIR) do os.make_directory(DATA_DIR)

	reset_test_wal_clock()
	clear_wal_sync_failure_for_test()
	defer clear_wal_sync_failure_for_test()
	state: WAL_State
	testing.expect(t, init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now))
	record := make_test_record_buffer("shutdown-fsync-fail")
	defer delete(record)
	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), record))
	set_wal_sync_failure_for_test()
	previous_logger := context.logger
	context.logger = log.nil_logger()
	shutdown_ok := shutdown_wal(&state)
	context.logger = previous_logger
	testing.expect(t, !shutdown_ok, "final fsync failure must propagate through WAL shutdown")
	testing.expect(t, wal_sync_fault_triggered_for_test())
	testing.expect(t, state.file == nil && !state.enabled, "failed shutdown must still close the WAL")
}

@(test)
test_direct_wal_reader_completes_legal_short_reads :: proc(t: ^testing.T) {
	data: [8192]byte
	for i in 0 ..< len(data) do data[i] = byte(i % 251)
	direct_short_read_data = data[:]
	direct_short_read_calls = 0
	defer {
		direct_short_read_data = nil
		direct_short_read_calls = 0
	}

	source := Direct_WAL_Read_Source {
		fd        = 0,
		alignment = 4096,
		file_size = len(data),
		pread     = test_short_direct_pread,
	}
	defer {
		source.fd = -1
		close_direct_wal_read_source(&source)
	}

	read, ok := direct_wal_read_source(&source, 100, 6000)
	testing.expect(t, ok, "direct WAL reader should fill across short successful preads")
	testing.expect(t, direct_short_read_calls >= 7, "test seam should exercise repeated retries and aligned continuation")
	if ok do testing.expect(t, bytes.equal(read, data[100:6100]), "short-read fill returned incorrect bytes")
}

@(test)
test_direct_wal_reader_rejects_repeated_unaligned_short_reads :: proc(t: ^testing.T) {
	data: [8192]byte
	direct_short_read_data = data[:]
	direct_short_read_calls = 0
	defer {
		direct_short_read_data = nil
		direct_short_read_calls = 0
	}

	source := Direct_WAL_Read_Source {
		fd        = 0,
		alignment = 4096,
		file_size = len(data),
		pread     = test_no_progress_direct_pread,
	}
	defer {
		source.fd = -1
		close_direct_wal_read_source(&source)
	}

	_, ok := direct_wal_read_source(&source, 100, 6000)
	testing.expect(t, !ok, "direct WAL reader must reject a source that never makes aligned progress")
	testing.expect_value(t, direct_short_read_calls, MAX_DIRECT_WAL_NO_PROGRESS_READS)
	testing.expect_value(t, source.buffer_data_length, 0)
}

// ============================================================================
// Test W15 - Oversized record bypasses write batch buffer safely
// ============================================================================

@(test)
test_oversized_record_bypasses_batch_buffer :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w15_oversized_record.log")

	os.remove(test_path)
	defer os.remove(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	reset_test_wal_clock()
	clear_wal_write_fault_for_test()
	defer clear_wal_write_fault_for_test()

	state: WAL_State
	init_ok := init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)
	testing.expect(t, init_ok, "init_wal should succeed")
	if !init_ok {
		return
	}
	defer shutdown_wal(&state)

	record := make([]byte, WRITE_BATCH_MAX_BYTES + 1)
	defer delete(record)
	for i := LOG_HEADER_SIZE; i < len(record); i += 1 {
		record[i] = u8(i)
	}

	write_ok := finalize_and_write_record(&state, u8(Test_Op.Create), record)
	testing.expect(t, write_ok, "oversized record should write successfully")
	testing.expect_value(t, state.write_offset, 0)
	testing.expect_value(t, state.buffered_record_count, u64(0))
	testing.expect_value(t, state.record_count, u64(1))
	testing.expect(t, state.pending_bytes >= u64(len(record)), "oversized direct write should advance pending bytes")

	force_fsync(&state)
	replay_result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	testing.expect(t, replay_result.ok, "replay after oversized direct write should succeed")
	testing.expect_value(t, replay_result.record_count, u64(1))
}

@(test)
test_oversized_record_flushes_staged_batch_first :: proc(t: ^testing.T) {
	test_path := test_wal_path("test_wal_w15_oversized_after_batch.log")

	os.remove(test_path)
	defer os.remove(test_path)

	if !os.exists(DATA_DIR) {
		os.make_directory(DATA_DIR)
	}

	reset_test_wal_clock()
	clear_wal_write_fault_for_test()
	defer clear_wal_write_fault_for_test()

	state: WAL_State
	init_ok := init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)
	testing.expect(t, init_ok, "init_wal should succeed")
	if !init_ok {
		return
	}
	defer shutdown_wal(&state)

	small_record := make_test_record_buffer("small")
	defer delete(small_record)
	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Create), small_record), "small record should stage successfully")
	testing.expect_value(t, state.write_offset, len(small_record))
	testing.expect_value(t, state.buffered_record_count, u64(1))

	oversized_record := make([]byte, WRITE_BATCH_MAX_BYTES + 1)
	defer delete(oversized_record)
	for i := LOG_HEADER_SIZE; i < len(oversized_record); i += 1 {
		oversized_record[i] = u8(i)
	}

	testing.expect(t, finalize_and_write_record(&state, u8(Test_Op.Update), oversized_record), "oversized record should flush the batch and write directly")
	testing.expect_value(t, state.write_offset, 0)
	testing.expect_value(t, state.buffered_record_count, u64(0))
	testing.expect_value(t, state.record_count, u64(2))

	force_fsync(&state)
	replay_result := replay_wal(test_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	testing.expect(t, replay_result.ok, "replay after staged-plus-oversized write should succeed")
	testing.expect_value(t, replay_result.record_count, u64(2))
}

@(test)
test_in_place_staging_preserves_chain_without_flushing_full_batch :: proc(t: ^testing.T) {
	path := test_wal_path("in-place-staging.log")
	reference_path := test_wal_path("in-place-staging-reference.log")
	_ = os.remove(path); _ = os.remove(reference_path)
	defer os.remove(path); defer os.remove(reference_path)
	reset_test_wal_clock()
	state, reference: WAL_State
	if !testing.expect(t, init_wal(&state, path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)) do return
	defer shutdown_wal(&state)
	if !testing.expect(t, init_wal(&reference, reference_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now)) do return
	defer shutdown_wal(&reference)
	// Dirty headers detect dependence on the temporary record's former zeroing.
	for &b in state.write_buffer do b = 0xa7
	invalid_sizes := [3]int{-1, LOG_HEADER_SIZE - 1, WRITE_BATCH_MAX_BYTES + 1}
	for size in invalid_sizes {
		testing.expect(t, !stage_record_in_place(&state, u8(Test_Op.Create), size))
	}
	testing.expect_value(t, state.write_offset, 0)
	testing.expect_value(t, state.buffered_record_count, u64(0))
	record_sizes := [2]int{LOG_HEADER_SIZE + 13, WRITE_BATCH_MAX_BYTES - LOG_HEADER_SIZE - 13}
	for size, index in record_sizes {
		record := make([]byte, size)
		for i in LOG_HEADER_SIZE ..< size do record[i] = u8(i * 17 + index * 29)
		copy(state.write_buffer[state.write_offset + LOG_HEADER_SIZE:][:size - LOG_HEADER_SIZE], record[LOG_HEADER_SIZE:])
		op := index == 0 ? u8(Test_Op.Create) : u8(Test_Op.Update)
		testing.expect(t, stage_record_in_place(&state, op, size))
		testing.expect(t, finalize_and_write_record(&reference, op, record))
		delete(record)
	}
	testing.expect_value(t, state.write_offset, WRITE_BATCH_MAX_BYTES)
	testing.expect_value(t, state.buffered_record_count, u64(2))
	testing.expect_value(t, state.record_count, u64(0))
	testing.expect_value(t, state.write_count, u64(0))
	testing.expect_value(t, state.fsync_count, u64(0))
	testing.expect(t, !stage_record_in_place(&state, u8(Test_Op.Delete), LOG_HEADER_SIZE))
	testing.expect_value(t, state.write_offset, WRITE_BATCH_MAX_BYTES)
	testing.expect_value(t, state.buffered_record_count, u64(2))
	testing.expect(t, bytes.equal(state.write_buffer[:], reference.write_buffer[:]))
	testing.expect(t, state.buffered_last_hash == reference.last_hash)
	testing.expect(t, flush_write_batch_deferred_fsync(&state))
	testing.expect_value(t, state.record_count, u64(2))
	testing.expect_value(t, state.durable_record_count, u64(0))
	testing.expect_value(t, state.fsync_count, u64(0))
	inspection := inspect_wal_file_strict(path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	testing.expect(t, inspection.ok)
	testing.expect_value(t, inspection.record_count, u64(2))
}

@(test)
test_deferred_fsync_record_finalization_covers_batch_boundary_and_oversized_writes :: proc(t: ^testing.T) {
	record_sizes := [2]int{WRITE_BATCH_MAX_BYTES, WRITE_BATCH_MAX_BYTES + 1}
	for record_size in record_sizes {
		test_path := test_wal_path(fmt.tprintf("deferred-record-%d.log", record_size))
		_ = os.remove(test_path)
		reset_test_wal_clock()
		state: WAL_State
		testing.expect(t, init_wal(&state, test_path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, test_wal_time_now))
		record := make([]byte, record_size)
		for i := LOG_HEADER_SIZE; i < len(record); i += 1 do record[i] = u8(i)
		// Make time-based fsync due before finalization enters either the exact
		// full-batch flush or oversized direct-write branch.
		test_wal_time_counter += 2_000_000_000
		testing.expect(t, finalize_and_write_record_deferred_fsync(&state, u8(Test_Op.Create), record))
		testing.expect(t, flush_write_batch_deferred_fsync(&state))
		testing.expect_value(t, state.record_count, u64(1))
		testing.expect_value(t, state.durable_record_count, u64(0))
		testing.expect_value(t, state.fsync_count, u64(0))
		testing.expect(t, state.pending_bytes > 0)
		snapshot, due := prepare_async_fsync(&state)
		testing.expect(t, due && snapshot.record_count == 1)
		delete(record)
		testing.expect(t, shutdown_wal(&state))
		_ = os.remove(test_path)
	}
}

@(test)
benchmark_wal_write_throughput :: proc(t: ^testing.T) {
	enabled, found := os.lookup_env_alloc("BENCH_WAL_WRITE", context.allocator)
	defer delete(enabled)
	if !found || enabled == "0" || enabled == "false" do return

	payload_bytes := benchmark_wal_env_int("NRC_WAL_BENCH_PAYLOAD_BYTES", 1024)
	record_count := benchmark_wal_env_int("NRC_WAL_BENCH_RECORDS", 100_000)
	testing.expect(t, payload_bytes <= MAX_WAL_PAYLOAD_SIZE)
	if payload_bytes > MAX_WAL_PAYLOAD_SIZE do return

	path := test_wal_path("wal-write-throughput.log")
	_ = os.remove(path)
	defer os.remove(path)
	state: WAL_State
	testing.expect(t, init_wal(&state, path, TEST_MAGIC, TEST_VERSION, TEST_THREAD_INDEX, benchmark_wal_time_now))
	if !state.enabled do return

	record := make([]byte, LOG_HEADER_SIZE + payload_bytes)
	defer delete(record)
	for i := LOG_HEADER_SIZE; i < len(record); i += 1 do record[i] = byte('a' + i % 26)
	if !benchmark_wal_external_barrier("write-throughput") {
		testing.expect(t, false, "WAL benchmark profiler barrier failed")
		_ = shutdown_wal(&state)
		return
	}

	written := 0
	started := time.now()
	for _ in 0 ..< record_count {
		if !finalize_and_write_record(&state, u8(Test_Op.Create), record) do break
		written += 1
	}
	if written == record_count do testing.expect(t, flush_write_batch(&state))
	elapsed := time.since(started)
	testing.expect_value(t, written, record_count)
	testing.expect_value(t, state.record_count, u64(record_count))

	wal_bytes := u64(record_count * len(record))
	seconds := time.duration_seconds(elapsed)
	log.infof(
		"WAL_WRITE_RESULT payload_bytes=%d record_bytes=%d records=%d wal_bytes=%d elapsed_ns=%d messages_per_s=%.3f mib_per_s=%.3f write_calls=%d fsyncs=%d",
		payload_bytes,
		len(record),
		record_count,
		wal_bytes,
		time.duration_nanoseconds(elapsed),
		f64(record_count) / seconds,
		f64(wal_bytes) / (1024 * 1024) / seconds,
		state.write_count,
		state.fsync_count,
	)
	testing.expect(t, shutdown_wal(&state))
}

@(test)
test_file_builder_buffer_boundaries_and_chain :: proc(t: ^testing.T) {
	path := test_wal_path("builder-boundaries.log")
	_ = os.make_directory(DATA_DIR)
	_ = os.remove(path); defer os.remove(path)
	builder: WAL_File_Builder
	if !testing.expect(t, create_wal_file_builder(&builder, path, TEST_MAGIC, TEST_VERSION)) do return
	defer abort_wal_file_builder(&builder)
	expected: [dynamic]byte
	defer delete(expected)
	// Exact buffer fill, overflow, oversized bypass, and a final partial batch.
	sizes := [5]int{LOG_HEADER_SIZE + 5, WRITE_BATCH_MAX_BYTES - LOG_HEADER_SIZE - 5, LOG_HEADER_SIZE + 5, WRITE_BATCH_MAX_BYTES + 1, LOG_HEADER_SIZE + 5}
	for size, index in sizes {
		record := make([]byte, size)
		defer delete(record)
		for &value in record[LOG_HEADER_SIZE:] do value = u8(index + 1)
		testing.expect(t, append_wal_file_builder(&builder, u8(Test_Op.Create), record))
		append(&expected, ..record)
		testing.expect_value(t, builder.file_size, u64(len(expected)))
		testing.expect_value(t, builder.record_count, u64(index + 1))
		// Callers reuse their serialization buffers immediately after append.
		for &value in record do value = 0
		physical, ok := test_read_file(path)
		testing.expect(t, ok)
		testing.expect_value(t, len(physical), len(expected) - builder.write_offset)
		delete(physical)
		if index < 2 do testing.expect_value(t, builder.write_offset, len(expected))
	}
	testing.expect(t, finish_wal_file_builder(&builder))
	testing.expect(t, builder.file == nil && !builder.active && builder.write_offset == 0)
	actual, ok := test_read_file(path)
	defer delete(actual)
	testing.expect(t, ok && bytes.equal(actual, expected[:]))
	inspection := inspect_wal_file_strict(path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	testing.expect(t, inspection.ok)
	testing.expect_value(t, inspection.record_count, u64(len(sizes)))
	testing.expect_value(t, inspection.file_size, builder.file_size)
}

@(test)
test_file_builder_buffer_failure_and_abort :: proc(t: ^testing.T) {
	for fault in 0 ..< 6 {
		path := test_wal_path(fmt.tprintf("builder-failure-%d.log", fault))
		_ = os.make_directory(DATA_DIR)
		_ = os.remove(path); defer os.remove(path)
		clear_wal_write_fault_for_test(); defer clear_wal_write_fault_for_test()
		clear_wal_sync_failure_for_test(); defer clear_wal_sync_failure_for_test()
		builder: WAL_File_Builder
		if !testing.expect(t, create_wal_file_builder(&builder, path, TEST_MAGIC, TEST_VERSION)) do return
		defer abort_wal_file_builder(&builder)
		record := make_test_record_buffer("buffered")
		defer delete(record)
		testing.expect(t, append_wal_file_builder(&builder, u8(Test_Op.Create), record))
		switch fault {
		case 0:
			abort_wal_file_builder(&builder)
			data, ok := test_read_file(path)
			testing.expect(t, ok && len(data) == 0)
			delete(data)
		case 1, 2:
			if fault == 1 {
				set_wal_short_write_for_test(1)
			} else {
				set_wal_write_error_for_test(os.Platform_Error(linux.Errno.EIO))
			}
			testing.expect(t, !finish_wal_file_builder(&builder))
			testing.expect(t, wal_write_fault_triggered_for_test())
		case 3:
			set_wal_sync_failure_for_test()
			testing.expect(t, !finish_wal_file_builder(&builder))
			testing.expect(t, wal_sync_fault_triggered_for_test())
		case 4, 5:
			// Fail either the pending prefix flush or the oversized direct write.
			set_wal_short_write_after_for_test(1, fault - 3)
			large := make([]byte, WRITE_BATCH_MAX_BYTES + 1)
			defer delete(large)
			testing.expect(t, !append_wal_file_builder(&builder, u8(Test_Op.Create), large))
			testing.expect_value(t, builder.record_count, u64(1))
			testing.expect_value(t, builder.file_size, u64(len(record)))
			testing.expect(t, wal_write_fault_triggered_for_test())
		}
		testing.expect(t, builder.file == nil && !builder.active && builder.write_offset == 0)
		testing.expect(t, !append_wal_file_builder(&builder, u8(Test_Op.Create), record))
		testing.expect(t, !finish_wal_file_builder(&builder))
	}
}

@(test)
test_file_builder_verbatim_copy :: proc(t: ^testing.T) {
	source_path := test_wal_path("builder-copy-source.log")
	_ = os.make_directory(DATA_DIR)
	defer os.remove(source_path)
	original: WAL_File_Builder
	if !testing.expect(t, create_wal_file_builder(&original, source_path, TEST_MAGIC, TEST_VERSION)) do return
	defer abort_wal_file_builder(&original)
	record := make([]byte, WRITE_BATCH_MAX_BYTES + 17)
	defer delete(record)
	testing.expect(t, append_wal_file_builder(&original, u8(Test_Op.Create), record))
	testing.expect(t, finish_wal_file_builder(&original))
	inspection := inspect_wal_file_strict(source_path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
	if !testing.expect(t, inspection.ok) do return
	source, err := storage_io.open(storage_io.host_context(), source_path, {.Read})
	if !testing.expect_value(t, err, nil) do return
	defer storage_io.discard(source)
	for fault in 0 ..< 5 {
		path := test_wal_path(fmt.tprintf("builder-copy-%d.log", fault))
		defer os.remove(path)
		builder: WAL_File_Builder
		if !testing.expect(t, create_wal_file_builder(&builder, path, TEST_MAGIC, TEST_VERSION)) do return
		defer abort_wal_file_builder(&builder)
		clear_wal_write_fault_for_test(); defer clear_wal_write_fault_for_test()
		clear_wal_sync_failure_for_test(); defer clear_wal_sync_failure_for_test()
		expected := inspection
		switch fault {
		case 1:
			set_wal_short_write_after_for_test(1, 1)
		case 2:
			set_wal_write_error_for_test(os.Platform_Error(linux.Errno.EIO))
		case 3:
			expected.file_size += 1 // Truncated relative to the inspected extent.
		case 4:
			set_wal_sync_failure_for_test()
		}
		copied := copy_wal_file_builder(&builder, source, expected)
		if fault > 0 && fault < 4 {
			testing.expect(t, !copied && !builder.active && builder.file == nil)
			testing.expect(t, !finish_wal_file_builder(&builder))
			if fault < 3 do testing.expect(t, wal_write_fault_triggered_for_test())
			continue
		}
		testing.expect(t, copied)
		testing.expect_value(t, builder.last_hash, inspection.last_hash)
		testing.expect_value(t, builder.record_count, inspection.record_count)
		testing.expect(t, !copy_wal_file_builder(&builder, source, inspection))
		if fault == 4 {
			testing.expect(t, !finish_wal_file_builder(&builder))
			testing.expect(t, wal_sync_fault_triggered_for_test())
			continue
		}
		actual, ok := test_read_file(path)
		testing.expect(t, ok && bytes.equal(actual, record))
		delete(actual)
		// Appending after the copy must continue the preserved chain.
		testing.expect(t, append_wal_file_builder(&builder, u8(Test_Op.Create), record))
		testing.expect(t, finish_wal_file_builder(&builder))
		result := inspect_wal_file_strict(path, TEST_MAGIC, TEST_THREAD_INDEX, test_apply_fn)
		testing.expect(t, result.ok && result.record_count == 2)
	}
}
