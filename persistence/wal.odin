// Generic hash-chained WAL append, replay, and checkpoint-building types.
// Shard-level checkpoint compaction is owned by the main package.
//
// WAL state is tracked in three explicit stages:
//
//   1. Buffered in memory:
//      - write_buffer, write_offset, buffered_last_hash, buffered_record_count
//      - Bytes staged for the next append syscall. Not yet written to kernel.
//
//   2. Written to kernel:
//      - last_hash, record_count, pending_bytes
//      - Bytes accepted by write(2), but not necessarily durable yet.
//
//   3. Covered by fsync:
//      - durable_last_hash, durable_record_count
//      - Safe durability boundary. A successful fsync moves written state here.
//
// This separation prevents the append path from advancing the WAL head before
// the batch is fully written, and makes it explicit that "written" is weaker
// than "durable".
//
package persistence

import "core:crypto/sha2"
import "core:hash/xxhash"
import "core:os"
import "core:time"

import "../storage_io"

NRC_SIMULATION :: #config(NRC_SIMULATION, false)

// ============================================================================
// Constants
// ============================================================================

LEGACY_LOG_HEADER_SIZE :: 48 // magic(4) + version(2) + op(1) + flags(1) + length(4) + prev_hash(32) + XXH32 record_hash(4)
LOG_HEADER_SIZE :: 52 // magic(4) + version(2) + op(1) + flags(1) + length(4) + prev_hash(32) + XXH64 record_hash(8)
LOG_FLAG_CHECKSUM_XXH64 :: u8(1 << 0)
LOG_SUPPORTED_FLAGS :: LOG_FLAG_CHECKSUM_XXH64

FSYNC_BYTE_THRESHOLD :: 100 * 1024 * 1024 // 100MB
FSYNC_TIME_THRESHOLD :: 1 * time.Second

DATA_DIR :: "data"

// Max CRC buffer size: 44 (header sans record_hash) + max payload
MAX_CRC_BUF_SIZE :: 16384 // 16KB to accommodate agenda content (8KB) + overhead
MAX_WAL_PAYLOAD_SIZE :: 16 * 1024 * 1024 // Largest supported outer record (shard transaction).

// Write batching threshold
WRITE_BATCH_MAX_BYTES :: 128 * 1024 // 128KB max batch size

// ============================================================================
// Types
// ============================================================================

// WAL_State holds the state for a single WAL instance
WAL_State :: struct {
	file:                   ^storage_io.File,
	storage:                storage_io.Context,
	path:                   string,
	pending_bytes:          u64,
	last_fsync:             time.Time,
	enabled:                bool,
	write_failures:         u64,
	last_hash:              [32]byte, // Last record accepted by write(2)
	durable_last_hash:      [32]byte, // Last record covered by a successful fsync
	record_count:           u64, // Records accepted by write(2)
	durable_record_count:   u64, // Records covered by a successful fsync
	magic:                  u32,
	version:                u16,
	thread_index:           int,
	get_time:               proc "contextless" () -> time.Time,

	// Metrics for observability
	fsync_count:            u64, // Total number of fsyncs performed
	total_fsync_latency_ns: u64, // Cumulative fsync latency in nanoseconds
	total_write_latency_ns: u64, // Cumulative write latency in nanoseconds
	write_count:            u64, // Total number of writes performed

	// Cached file size (updated at most once per second)
	cached_file_size:       u64,
	last_file_size_update:  time.Time,
	file_size_bytes:        u64,

	// Write batching
	write_buffer:           [WRITE_BATCH_MAX_BYTES]byte, // Contiguous buffer for pending records
	write_offset:           int, // Current offset in write_buffer
	buffered_last_hash:     [32]byte, // Last record staged in write_buffer
	buffered_record_count:  u64, // Records staged in write_buffer

	// Reusable hash states for hot path
	crc32_state:            xxhash.XXH32_state,
	crc64_state:            xxhash.XXH64_state,
	sha_state:              sha2.Context_256,

	// Simulation-only append target. Always rawptr so production builds do not need
	// the simulation file type; production code leaves this nil.
	virtual_file:           rawptr,
}

WAL_Fsync_Snapshot :: struct {
	last_hash:     [32]byte,
	record_count:  u64,
	pending_bytes: u64,
}

// WAL_File_Builder is a bounded offline writer for a new WAL file. It deliberately
// omits recovery, compaction, and periodic fsync state. Appends are buffered;
// only a successful finish makes the complete file durable.
WAL_File_Builder :: struct {
	file:         ^storage_io.File,
	storage:      storage_io.Context,
	magic:        u32,
	version:      u16,
	last_hash:    [32]byte,
	record_count: u64,
	file_size:    u64, // Logical size including buffered records, for caller offsets.
	write_buffer: [WRITE_BATCH_MAX_BYTES]byte,
	write_offset: int,
	crc64_state:  xxhash.XXH64_state,
	sha_state:    sha2.Context_256,
	active:       bool,
}

// Record_Header is the hash-chained record header for tamper evidence
Record_Header :: struct #packed {
	magic:       u32, // Entity-specific magic number
	version:     u16, // Log format version
	op:          u8, // Operation type (entity-specific enum)
	flags:       u8, // Reserved for future use
	length:      u32, // Payload length in bytes
	prev_hash:   [32]byte, // SHA-256 hash of previous record
	record_hash: u64, // XXH64 of (header sans record_hash + payload)
}

Legacy_Record_Header :: struct #packed {
	magic:       u32,
	version:     u16,
	op:          u8,
	flags:       u8,
	length:      u32,
	prev_hash:   [32]byte,
	record_hash: u32, // XXH32 of (header sans record_hash + payload)
}

// Replay_Result holds the result of a replay operation
Replay_Result :: struct {
	record_count: u64,
	last_hash:    [32]byte,
	ok:           bool,
}

Strict_WAL_Inspection :: struct {
	file_size:    u64,
	record_count: u64,
	last_hash:    [32]byte,
	ok:           bool,
}

WAL_Write_Fault_Mode :: enum {
	None,
	Short_Write,
	Error,
}

WAL_Write_Fault_State :: struct {
	mode:              WAL_Write_Fault_Mode,
	short_write_bytes: int,
	write_error:       os.Error,
	trigger_after:     int,
	hit_count:         int,
	triggered:         bool,
}

@(thread_local)
wal_write_fault_state: WAL_Write_Fault_State

WAL_Sync_Fault_State :: struct {
	armed:     bool,
	triggered: bool,
}

@(thread_local)
wal_sync_fault_state: WAL_Sync_Fault_State

set_wal_short_write_for_test :: proc(short_write_bytes: int) {
	set_wal_short_write_after_for_test(short_write_bytes, 1)
}

set_wal_short_write_after_for_test :: proc(short_write_bytes: int, trigger_after := 1) {
	bytes := short_write_bytes
	if bytes < 0 {
		bytes = 0
	}
	after := trigger_after
	if after < 1 {
		after = 1
	}

	wal_write_fault_state = WAL_Write_Fault_State {
		mode              = .Short_Write,
		short_write_bytes = bytes,
		trigger_after     = after,
	}
}

set_wal_write_error_for_test :: proc(write_error: os.Error) {
	wal_write_fault_state = WAL_Write_Fault_State {
		mode          = .Error,
		write_error   = write_error,
		trigger_after = 1,
	}
}

clear_wal_write_fault_for_test :: proc() {
	wal_write_fault_state = WAL_Write_Fault_State{}
}

wal_write_fault_triggered_for_test :: proc() -> bool {
	return wal_write_fault_state.triggered
}

set_wal_sync_failure_for_test :: proc() {
	wal_sync_fault_state = WAL_Sync_Fault_State {
		armed = true,
	}
}

clear_wal_sync_failure_for_test :: proc() {
	wal_sync_fault_state = WAL_Sync_Fault_State{}
}

wal_sync_fault_triggered_for_test :: proc() -> bool {
	return wal_sync_fault_state.triggered
}
