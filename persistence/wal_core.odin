package persistence

import "core:crypto/sha2"
import "core:encoding/endian"
import "core:hash/xxhash"
import "core:log"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sys/linux"
import "core:sys/posix"
import "core:time"

import "../storage_io"

cleanup_init_wal_state :: proc(state: ^WAL_State) {
	if len(state.path) > 0 {
		delete(state.path)
		state.path = ""
	}
}

// init_wal initializes a WAL instance. Returns true if successful.
// Caller should replay after init_wal returns so startup recovery can run first.
init_wal :: proc {
	init_wal_host,
	init_wal_with_storage,
}

init_wal_host :: proc(state: ^WAL_State, path: string, magic: u32, version: u16, thread_index: int, get_time: proc "contextless" () -> time.Time) -> bool {
	return init_wal_with_storage(state, storage_io.host_context(), path, magic, version, thread_index, get_time)
}

init_wal_with_storage :: proc(
	state: ^WAL_State,
	storage: storage_io.Context,
	path: string,
	magic: u32,
	version: u16,
	thread_index: int,
	get_time: proc "contextless" () -> time.Time,
) -> bool {
	cloned_path, clone_err := strings.clone(path)
	if clone_err != nil {
		log.errorf("[T%d] Failed to clone path", thread_index)
		return false
	}
	state^ = WAL_State {
		storage      = storage,
		path         = cloned_path,
		magic        = magic,
		version      = version,
		thread_index = thread_index,
		get_time     = get_time,
	}

	// Create data directory if it doesn't exist
	data_exists, exists_err := storage_io.exists(storage, DATA_DIR)
	if exists_err != nil {
		cleanup_init_wal_state(state)
		return false
	}
	if !data_exists {
		mkdir_err := storage_io.make_directory(storage, DATA_DIR)
		// Another worker may create the shared directory after our existence check.
		now_exists, _ := storage_io.exists(storage, DATA_DIR)
		if mkdir_err != nil && !now_exists {
			log.errorf("[T%d] Failed to create data directory: %v", thread_index, mkdir_err)
			cleanup_init_wal_state(state)
			return false
		}
		if mkdir_err == nil {
			log.infof("[T%d] Created data directory: %s", thread_index, DATA_DIR)
		}
	}

	// Open the manifest-selected WAL for appending.
	handle, open_err := storage_io.open(storage, path, {.Write, .Create, .Append}, os.perm(0o644))
	if open_err != nil {
		log.errorf("[T%d] Failed to open WAL for writing: %v", thread_index, open_err)
		cleanup_init_wal_state(state)
		return false
	}

	state.file = handle
	state.enabled = true
	now := get_time()
	state.last_fsync = now
	if size, size_err := storage_io.file_size(handle); size_err == nil && size >= 0 {
		state.file_size_bytes = u64(size)
		state.cached_file_size = u64(size)
		state.last_file_size_update = now
	} else {
		storage_io.discard(handle)
		state.file = nil
		state.enabled = false
		cleanup_init_wal_state(state)
		return false
	}

	return true
}

// shutdown_wal cleanly shuts down a WAL instance
shutdown_wal :: proc(state: ^WAL_State) -> bool {
	ok := true
	if state.enabled {
		// Flush pending writes before the final fsync.
		if !flush_write_batch(state) {
			ok = false
			state.enabled = false
		}
		if state.enabled && state.pending_bytes > 0 {
			if sync_wal_target(state) {
				mark_wal_state_durable(state)
			} else {
				ok = false
			}
		}
	}

	if state.file != nil {
		if storage_io.close(state.file) != nil do ok = false
	}
	state.file = nil
	state.enabled = false

	if len(state.path) > 0 {
		delete(state.path)
		state.path = ""
	}
	return ok
}

simulate_wal_crash_for_test :: proc(state: ^WAL_State) {
	if state.file != nil {
		storage_io.discard(state.file)
	}
	when NRC_SIMULATION {
		if state.virtual_file != nil {
			virtual_wal_crash((^Virtual_WAL_File)(state.virtual_file))
		}
	}

	state.file = nil
	state.enabled = false
	reset_buffered_write_state(state)
}

reset_buffered_write_state :: proc(state: ^WAL_State) {
	state.write_offset = 0
	state.buffered_last_hash = [32]byte{}
	state.buffered_record_count = 0
}

set_recovered_wal_state :: proc(state: ^WAL_State, last_hash: [32]byte, record_count: u64) {
	state.last_hash = last_hash
	state.durable_last_hash = last_hash
	state.record_count = record_count
	state.durable_record_count = record_count
	state.pending_bytes = 0
	if size, size_err := storage_io.file_size(state.file); size_err == nil && size >= 0 {
		state.file_size_bytes = u64(size)
		state.cached_file_size = u64(size)
	}
	reset_buffered_write_state(state)
}

sync_wal_target :: proc(state: ^WAL_State) -> bool {
	when NRC_SIMULATION {
		if state.virtual_file != nil {
			virtual_wal_sync((^Virtual_WAL_File)(state.virtual_file))
			return true
		} else if state.file != nil {
			if wal_sync_fault_state.armed {
				wal_sync_fault_state.armed = false
				wal_sync_fault_state.triggered = true
				state.write_failures += 1
				state.enabled = false
				log.errorf("[T%d] WAL fsync failed: %v", state.thread_index, os.Platform_Error(posix.Errno.EIO))
				return false
			}
			if sync_err := storage_io.sync(state.file); sync_err != nil {
				state.write_failures += 1
				state.enabled = false
				log.errorf("[T%d] WAL fsync failed: %v", state.thread_index, sync_err)
				return false
			}
			return true
		}
	} else {
		if state.file != nil {
			if wal_sync_fault_state.armed {
				wal_sync_fault_state.armed = false
				wal_sync_fault_state.triggered = true
				state.write_failures += 1
				state.enabled = false
				log.errorf("[T%d] WAL fsync failed: %v", state.thread_index, os.Platform_Error(posix.Errno.EIO))
				return false
			}
			if sync_err := storage_io.sync(state.file); sync_err != nil {
				state.write_failures += 1
				state.enabled = false
				log.errorf("[T%d] WAL fsync failed: %v", state.thread_index, sync_err)
				return false
			}
			return true
		}
	}
	state.enabled = false
	return false
}

mark_wal_state_durable :: proc(state: ^WAL_State) {
	state.pending_bytes = 0
	state.durable_last_hash = state.last_hash
	state.durable_record_count = state.record_count
	state.last_fsync = state.get_time()
}

wal_fsync_due :: proc(state: ^WAL_State) -> bool {
	if state == nil || !state.enabled || state.pending_bytes == 0 do return false
	now := state.get_time()
	return state.pending_bytes >= FSYNC_BYTE_THRESHOLD || time.diff(state.last_fsync, now) >= FSYNC_TIME_THRESHOLD
}

prepare_async_fsync :: proc(state: ^WAL_State) -> (WAL_Fsync_Snapshot, bool) {
	if !wal_fsync_due(state) || state.file == nil do return {}, false
	return WAL_Fsync_Snapshot{last_hash = state.last_hash, record_count = state.record_count, pending_bytes = state.pending_bytes}, true
}

complete_async_fsync :: proc(state: ^WAL_State, snapshot: WAL_Fsync_Snapshot, elapsed: time.Duration, err: linux.Errno) -> bool {
	if state == nil || !state.enabled do return false
	if err != .NONE {
		state.write_failures += 1
		state.enabled = false
		log.errorf("[T%d] WAL async fsync failed: %v", state.thread_index, os.Platform_Error(posix.Errno(err)))
		return false
	}
	state.total_fsync_latency_ns += u64(time.duration_nanoseconds(elapsed))
	state.fsync_count += 1
	state.durable_last_hash = snapshot.last_hash
	state.durable_record_count = snapshot.record_count
	state.pending_bytes -= min(state.pending_bytes, snapshot.pending_bytes)
	state.last_fsync = state.get_time()
	return true
}

wal_write_with_test_faults :: proc(file: ^storage_io.File, data: []byte) -> (written: int, err: os.Error) {
	if len(data) == 0 {
		return 0, nil
	}

	if wal_write_fault_state.mode == .Short_Write {
		wal_write_fault_state.hit_count += 1
		if wal_write_fault_state.hit_count < wal_write_fault_state.trigger_after {
			return storage_io.write(file, data)
		}

		short_write_bytes := wal_write_fault_state.short_write_bytes
		if short_write_bytes >= len(data) {
			short_write_bytes = len(data) - 1
		}
		if short_write_bytes < 0 {
			short_write_bytes = 0
		}

		wal_write_fault_state.triggered = true
		wal_write_fault_state.mode = .None

		if short_write_bytes == 0 {
			return 0, nil
		}

		return storage_io.write(file, data[:short_write_bytes])
	}
	if wal_write_fault_state.mode == .Error {
		wal_write_fault_state.hit_count += 1
		if wal_write_fault_state.hit_count < wal_write_fault_state.trigger_after do return storage_io.write(file, data)
		wal_write_fault_state.triggered = true
		wal_write_fault_state.mode = .None
		return 0, wal_write_fault_state.write_error
	}

	return storage_io.write(file, data)
}

poison_wal_after_ambiguous_write :: proc(state: ^WAL_State, written: int, attempted: int, write_err: os.Error) {
	state.write_failures += 1
	state.enabled = false
	reset_buffered_write_state(state)

	log.errorf("[T%d] WAL poisoned after ambiguous append: wrote %d/%d bytes, err=%v", state.thread_index, written, attempted, write_err)
}

write_record_direct :: proc(state: ^WAL_State, buf: []byte, sync_if_due: bool) -> bool {
	when NRC_SIMULATION {
		if state.virtual_file != nil {
			virtual_file := (^Virtual_WAL_File)(state.virtual_file)
			write_start := state.get_time()
			record_size := len(buf)
			if !virtual_wal_write(virtual_file, buf) {
				poison_wal_after_ambiguous_write(state, 0, record_size, nil)
				return false
			}
			write_elapsed := time.diff(write_start, state.get_time())

			state.total_write_latency_ns += u64(time.duration_nanoseconds(write_elapsed))
			state.write_count += 1
			state.pending_bytes += u64(record_size)
			state.file_size_bytes += u64(record_size)
			state.write_failures = 0

			compute_chain_hash(&state.sha_state, buf, state.last_hash[:])
			state.record_count += 1

			return maybe_fsync(state) if sync_if_due else true
		}
	}

	if state.file == nil {
		state.enabled = false
		return false
	}

	write_start := state.get_time()
	record_size := len(buf)
	written, write_err := wal_write_with_test_faults(state.file, buf)
	write_elapsed := time.diff(write_start, state.get_time())

	if write_err != nil || written != record_size {
		poison_wal_after_ambiguous_write(state, written, record_size, write_err)
		return false
	}

	state.total_write_latency_ns += u64(time.duration_nanoseconds(write_elapsed))
	state.write_count += 1
	state.pending_bytes += u64(record_size)
	state.file_size_bytes += u64(record_size)
	state.write_failures = 0

	compute_chain_hash(&state.sha_state, buf, state.last_hash[:])
	state.record_count += 1

	return maybe_fsync(state) if sync_if_due else true
}

// ============================================================================
// Write Path (with writev batching)
// ============================================================================

// finalize_and_write_record finalizes a pre-allocated buffer and adds it to the write batch.
// The buffer must be exactly LOG_HEADER_SIZE + payload_size bytes, with payload already
// written starting at buf[LOG_HEADER_SIZE:]. This function fills in the header, computes
// the XXH32 checksum, and batches for writing. Zero allocations.
finalize_and_write_record :: proc(state: ^WAL_State, op: u8, buf: []byte) -> bool {
	return finalize_and_write_record_internal(state, op, buf, true)
}

// Used by an owner that submits threshold-triggered fsync through its async I/O loop.
finalize_and_write_record_deferred_fsync :: proc(state: ^WAL_State, op: u8, buf: []byte) -> bool {
	return finalize_and_write_record_internal(state, op, buf, false)
}

// Finalize payload already encoded at write_buffer[write_offset+LOG_HEADER_SIZE:].
// Unlike finalize_and_write_record, this only stages: it never writes or fsyncs,
// even when the record exactly fills the batch. The owner controls publication
// and must finish consuming a flushed batch before reusing its storage.
stage_record_in_place :: proc(state: ^WAL_State, op: u8, record_size: int) -> bool {
	if !state.enabled || record_size < LOG_HEADER_SIZE || record_size > WRITE_BATCH_MAX_BYTES || state.write_offset + record_size > WRITE_BATCH_MAX_BYTES {
		return false
	}
	record := state.write_buffer[state.write_offset:][:record_size]
	previous_hash := state.last_hash
	if state.buffered_record_count > 0 do previous_hash = state.buffered_last_hash
	finalize_wal_record_buffer(state.magic, state.version, op, &previous_hash, record, &state.crc64_state)
	compute_chain_hash(&state.sha_state, record, state.buffered_last_hash[:])
	state.write_offset += record_size
	state.buffered_record_count += 1
	return true
}

finalize_and_write_record_internal :: proc(state: ^WAL_State, op: u8, buf: []byte, sync_if_due: bool) -> bool {
	if !state.enabled {
		return false
	}

	payload_size := len(buf) - LOG_HEADER_SIZE
	record_size := len(buf)
	if payload_size < 0 || payload_size > MAX_WAL_PAYLOAD_SIZE {
		return false
	}

	// Check if we need to flush before adding this record
	if state.write_offset + record_size > WRITE_BATCH_MAX_BYTES {
		if !flush_write_batch_internal(state, sync_if_due) {
			return false
		}
	}

	// Build and checksum the record against the current append tail.
	previous_hash := state.last_hash
	if state.buffered_record_count > 0 do previous_hash = state.buffered_last_hash
	finalize_wal_record_buffer(state.magic, state.version, op, &previous_hash, buf, &state.crc64_state)

	if record_size > WRITE_BATCH_MAX_BYTES {
		// Oversized records bypass the batch buffer after draining any staged writes.
		return write_record_direct(state, buf, sync_if_due)
	}

	// Copy record to write buffer
	dest := state.write_buffer[state.write_offset:][:record_size]
	copy(dest, buf)

	// Track the staged hash chain independently from the written WAL head.
	compute_chain_hash(&state.sha_state, buf, state.buffered_last_hash[:])

	state.write_offset += record_size
	state.buffered_record_count += 1

	// Check if we should flush (size threshold)
	if state.write_offset >= WRITE_BATCH_MAX_BYTES {
		return flush_write_batch_internal(state, sync_if_due)
	}

	return true
}

// create_wal_file_builder creates one new file exclusively. It never recovers or
// opens an existing WAL, so callers can safely discard the containing staging tree.
create_wal_file_builder :: proc {
	create_wal_file_builder_host,
	create_wal_file_builder_with_storage,
}

create_wal_file_builder_host :: proc(builder: ^WAL_File_Builder, path: string, magic: u32, version: u16) -> bool {
	return create_wal_file_builder_with_storage(builder, storage_io.host_context(), path, magic, version)
}

create_wal_file_builder_with_storage :: proc(builder: ^WAL_File_Builder, storage: storage_io.Context, path: string, magic: u32, version: u16) -> bool {
	if builder.active || builder.file != nil do return false
	file, open_err := storage_io.open(storage, path, {.Write, .Create, .Excl}, os.perm(0o644))
	if open_err != nil do return false
	builder^ = {
		file    = file,
		storage = storage,
		magic   = magic,
		version = version,
		active  = true,
	}
	return true
}

append_wal_file_builder :: proc(builder: ^WAL_File_Builder, op: u8, record: []byte) -> bool {
	if !builder.active || builder.file == nil do return false
	payload_size := len(record) - LOG_HEADER_SIZE
	if payload_size < 0 || payload_size > MAX_WAL_PAYLOAD_SIZE do return false
	if len(record) > len(builder.write_buffer) - builder.write_offset {
		if !flush_wal_file_builder(builder) do return false
	}
	finalize_wal_record_buffer(builder.magic, builder.version, op, &builder.last_hash, record, &builder.crc64_state)
	next_hash: [32]byte
	compute_chain_hash(&builder.sha_state, record, next_hash[:])
	if len(record) > len(builder.write_buffer) {
		// Oversized records bypass the buffer only after its prefix is written.
		written, write_err := wal_write_with_test_faults(builder.file, record)
		if write_err != nil || written != len(record) {
			abort_wal_file_builder(builder)
			return false
		}
	} else {
		copy(builder.write_buffer[builder.write_offset:], record)
		builder.write_offset += len(record)
	}
	builder.last_hash = next_hash
	builder.record_count += 1
	builder.file_size += u64(len(record))
	return true
}

// Copy a closed, append-only source corresponding to a successful strict
// inspection. Buffered reads rely on that provenance: no overwritten prefix
// may differ between the inspected durable image and the page cache.
// The empty builder must use the source's magic/version. Preserve its exact
// bytes and hash chain; finish_wal_file_builder still owns fsync and close.
copy_wal_file_builder :: proc(builder: ^WAL_File_Builder, source: ^storage_io.File, inspection: Strict_WAL_Inspection) -> bool {
	if !builder.active ||
	   builder.file == nil ||
	   !inspection.ok ||
	   builder.file_size != 0 ||
	   builder.record_count != 0 ||
	   builder.write_offset != 0 ||
	   inspection.file_size > u64(max(int)) {
		return false
	}
	for builder.file_size < inspection.file_size {
		length := int(min(u64(len(builder.write_buffer)), inspection.file_size - builder.file_size))
		n, read_err := storage_io.read_at(source, builder.write_buffer[:length], int(builder.file_size))
		if read_err != nil || n <= 0 {
			abort_wal_file_builder(builder)
			return false
		}
		written, write_err := wal_write_with_test_faults(builder.file, builder.write_buffer[:n])
		if write_err != nil || written != n {
			abort_wal_file_builder(builder)
			return false
		}
		builder.file_size += u64(n)
	}
	builder.record_count = inspection.record_count
	builder.last_hash = inspection.last_hash
	return true
}

flush_wal_file_builder :: proc(builder: ^WAL_File_Builder) -> bool {
	if !builder.active || builder.file == nil do return false
	if builder.write_offset == 0 do return true
	written, write_err := wal_write_with_test_faults(builder.file, builder.write_buffer[:builder.write_offset])
	if write_err != nil || written != builder.write_offset {
		abort_wal_file_builder(builder)
		return false
	}
	builder.write_offset = 0
	return true
}

finish_wal_file_builder :: proc(builder: ^WAL_File_Builder) -> bool {
	if !builder.active || builder.file == nil do return false
	if !flush_wal_file_builder(builder) do return false
	sync_err: os.Error
	if wal_sync_fault_state.armed {
		wal_sync_fault_state.armed = false
		wal_sync_fault_state.triggered = true
		sync_err = os.Platform_Error(posix.Errno.EIO)
	} else {
		sync_err = storage_io.sync(builder.file)
	}
	close_err := storage_io.close(builder.file)
	builder.file = nil
	builder.active = false
	return sync_err == nil && close_err == nil
}

abort_wal_file_builder :: proc(builder: ^WAL_File_Builder) {
	if builder.file != nil do storage_io.discard(builder.file)
	builder.file = nil
	builder.active = false
	builder.write_offset = 0
}

// flush_write_batch writes all pending records with a single write() syscall.
flush_write_batch :: proc(state: ^WAL_State) -> bool {
	return flush_write_batch_internal(state, true)
}

// Used by an owner that submits threshold-triggered fsync through its async I/O loop.
flush_write_batch_deferred_fsync :: proc(state: ^WAL_State) -> bool {
	return flush_write_batch_internal(state, false)
}

flush_write_batch_internal :: proc(state: ^WAL_State, sync_if_due: bool) -> bool {
	if !state.enabled {
		return false
	}
	if state.write_offset == 0 {
		return true
	}
	when NRC_SIMULATION {
		if state.virtual_file != nil {
			virtual_file := (^Virtual_WAL_File)(state.virtual_file)
			write_start := state.get_time()
			batch_bytes := state.write_offset
			batch_records := state.buffered_record_count
			batch_last_hash := state.buffered_last_hash

			if !virtual_wal_write(virtual_file, state.write_buffer[:state.write_offset]) {
				poison_wal_after_ambiguous_write(state, 0, batch_bytes, nil)
				return false
			}

			write_elapsed := time.diff(write_start, state.get_time())
			state.total_write_latency_ns += u64(time.duration_nanoseconds(write_elapsed))
			state.write_count += 1
			state.pending_bytes += u64(batch_bytes)
			state.file_size_bytes += u64(batch_bytes)
			state.write_failures = 0
			state.last_hash = batch_last_hash
			state.record_count += batch_records
			reset_buffered_write_state(state)

			return maybe_fsync(state) if sync_if_due else true
		}
	}
	if state.file == nil {
		state.enabled = false
		return false
	}

	write_start := state.get_time()

	// Single syscall for all pending records
	written, write_err := wal_write_with_test_faults(state.file, state.write_buffer[:state.write_offset])

	write_elapsed := time.diff(write_start, state.get_time())
	if !complete_deferred_write(state, written, write_err, write_elapsed) do return false
	return maybe_fsync(state) if sync_if_due else true
}

// The caller leases all buffered bytes and metadata until completion.
complete_deferred_write :: proc(state: ^WAL_State, written: int, write_err: os.Error, elapsed: time.Duration) -> bool {
	if !state.enabled || write_err != nil || written != state.write_offset {
		poison_wal_after_ambiguous_write(state, written, state.write_offset, write_err)
		return false
	}

	// Track metrics
	state.total_write_latency_ns += u64(time.duration_nanoseconds(elapsed))
	state.write_count += 1 // Counts batches, not individual records
	state.pending_bytes += u64(state.write_offset)
	state.file_size_bytes += u64(state.write_offset)
	state.write_failures = 0

	// Advance written-to-kernel state only after the entire batch succeeds.
	state.last_hash = state.buffered_last_hash
	state.record_count += state.buffered_record_count
	reset_buffered_write_state(state)
	return true
}

// finalize_wal_record_buffer fills a current-format header and checksum using an
// explicit chain predecessor. The caller has already bounded the payload length.
finalize_wal_record_buffer :: proc(magic: u32, version: u16, op: u8, previous_hash: ^[32]byte, buf: []byte, crc64_state: ^xxhash.XXH64_state) {
	endian.put_u32(buf[0:], .Big, magic)
	endian.put_u16(buf[4:], .Big, version)
	buf[6] = op
	buf[7] = LOG_FLAG_CHECKSUM_XXH64
	payload_size := len(buf) - LOG_HEADER_SIZE
	endian.put_u32(buf[8:], .Big, u32(payload_size))
	copy(buf[12:44], previous_hash[:])
	record_crc := compute_record_crc64(crc64_state, buf, payload_size)
	endian.put_u64(buf[44:], .Big, record_crc)
}

record_header_size_from_flags :: proc(flags: u8) -> (int, bool) {
	if flags & ~LOG_SUPPORTED_FLAGS != 0 {
		return 0, false
	}
	if flags & LOG_FLAG_CHECKSUM_XXH64 != 0 {
		return LOG_HEADER_SIZE, true
	}
	return LEGACY_LOG_HEADER_SIZE, true
}

// compute_record_crc computes the legacy XXH32 checksum over header[0:44] + payload using incremental hashing (no copy)
compute_record_crc :: proc {
	compute_record_crc_with_state,
	compute_record_crc_alloc,
}

// Hot path version: reuses caller-provided state
compute_record_crc_with_state :: proc(state: ^xxhash.XXH32_state, buf: []byte, payload_size: int) -> u32 {
	xxhash.XXH32_reset_state(state, 0)
	xxhash.XXH32_update(state, buf[0:44])
	header_size, ok := record_header_size_from_flags(buf[7])
	if !ok {
		return 0
	}
	xxhash.XXH32_update(state, buf[header_size:][:payload_size])
	return xxhash.XXH32_digest(state)
}

// Non-hot path version: allocates state on stack (for tests)
compute_record_crc_alloc :: proc(buf: []byte, payload_size: int) -> u32 {
	state: xxhash.XXH32_state
	return compute_record_crc_with_state(&state, buf, payload_size)
}

compute_record_crc64 :: proc {
	compute_record_crc64_with_state,
	compute_record_crc64_alloc,
}

compute_record_crc64_with_state :: proc(state: ^xxhash.XXH64_state, buf: []byte, payload_size: int) -> u64 {
	xxhash.XXH64_reset_state(state, 0)
	xxhash.XXH64_update(state, buf[0:44])
	header_size, ok := record_header_size_from_flags(buf[7])
	if !ok {
		return 0
	}
	xxhash.XXH64_update(state, buf[header_size:][:payload_size])
	return xxhash.XXH64_digest(state)
}

compute_record_crc64_alloc :: proc(buf: []byte, payload_size: int) -> u64 {
	state: xxhash.XXH64_state
	return compute_record_crc64_with_state(&state, buf, payload_size)
}

validate_record_checksum :: proc(crc32_state: ^xxhash.XXH32_state, crc64_state: ^xxhash.XXH64_state, record_data: []byte, payload_size: int) -> bool {
	if len(record_data) < LEGACY_LOG_HEADER_SIZE || payload_size < 0 {
		return false
	}
	header_size, ok := record_header_size_from_flags(record_data[7])
	if !ok || len(record_data) < header_size + payload_size {
		return false
	}

	flags := record_data[7]
	if flags & LOG_FLAG_CHECKSUM_XXH64 != 0 {
		stored_crc, _ := endian.get_u64(record_data[44:], .Big)
		computed_crc := compute_record_crc64(crc64_state, record_data, payload_size)
		return computed_crc == stored_crc
	}
	stored_crc, _ := endian.get_u32(record_data[44:], .Big)
	computed_crc := compute_record_crc(crc32_state, record_data, payload_size)
	return computed_crc == stored_crc
}

validate_record_checksum_alloc :: proc(record_data: []byte, payload_size: int) -> bool {
	crc32_state: xxhash.XXH32_state
	crc64_state: xxhash.XXH64_state
	return validate_record_checksum(&crc32_state, &crc64_state, record_data, payload_size)
}

// compute_chain_hash computes SHA-256 hash for chain linking using reusable context
compute_chain_hash :: proc {
	compute_chain_hash_with_state,
	compute_chain_hash_alloc,
}

// Hot path version: reuses caller-provided SHA-256 context
// Note: sha2.final() clears is_initialized, so we must re-init each time
compute_chain_hash_with_state :: proc(ctx: ^sha2.Context_256, data: []byte, out: []byte) {
	sha2.init_256(ctx)
	sha2.update(ctx, data)
	sha2.final(ctx, out)
}

// Non-hot path version: allocates context on stack (for tests)
compute_chain_hash_alloc :: proc(data: []byte, out: []byte) {
	ctx: sha2.Context_256
	compute_chain_hash_with_state(&ctx, data, out)
}

// maybe_fsync performs an fsync if thresholds are exceeded.
// Returns false if the fsync path poisoned the WAL.
maybe_fsync :: proc(state: ^WAL_State) -> bool {
	now := state.get_time()
	time_since_fsync := time.diff(state.last_fsync, now)

	should_fsync := state.pending_bytes >= FSYNC_BYTE_THRESHOLD || time_since_fsync >= FSYNC_TIME_THRESHOLD

	if should_fsync {
		fsync_start := state.get_time()
		if !sync_wal_target(state) {
			return false
		}
		fsync_elapsed := time.diff(fsync_start, state.get_time())

		// Track fsync latency
		state.total_fsync_latency_ns += u64(time.duration_nanoseconds(fsync_elapsed))
		state.fsync_count += 1

		mark_wal_state_durable(state)
	}
	return true
}

// force_fsync flushes any pending batch and forces an immediate fsync
force_fsync :: proc(state: ^WAL_State) {
	if !state.enabled {
		return
	}

	// First flush any pending batched writes
	if !flush_write_batch(state) {
		return
	}
	if !state.enabled {
		return
	}

	// Then fsync if there are pending bytes
	if state.pending_bytes > 0 {
		fsync_start := state.get_time()
		if !sync_wal_target(state) {
			return
		}
		fsync_elapsed := time.diff(fsync_start, state.get_time())

		// Track fsync latency
		state.total_fsync_latency_ns += u64(time.duration_nanoseconds(fsync_elapsed))
		state.fsync_count += 1

		mark_wal_state_durable(state)
	}
}

// ============================================================================
// Metrics
// ============================================================================

FILE_SIZE_CACHE_TTL :: time.Second

// get_file_size returns exact accepted bytes, including records still staged in
// the write batch. Rotation decisions therefore do not depend on stat cache age.
get_file_size :: proc(state: ^WAL_State) -> u64 {
	when NRC_SIMULATION {
		if state.enabled && state.virtual_file != nil {
			virtual_file := (^Virtual_WAL_File)(state.virtual_file)
			return u64(len(virtual_file.stable) + len(virtual_file.pending))
		}
	}
	if !state.enabled || state.file == nil do return 0
	return state.file_size_bytes + u64(state.write_offset)
}

// ============================================================================
// Read Path (Replay)
// ============================================================================

// Apply_Record_Proc is the callback type for replay_wal
// Parameters: op (u8), version (u16), payload ([]byte)
// Returns: true to continue replay, false to stop
Apply_Record_Proc :: #type proc(op: u8, version: u16, payload: []byte) -> bool
Apply_Record_Sized_Proc :: #type proc(op: u8, version: u16, payload: []byte, record_size: int) -> bool

// replay_wal replays a WAL file and calls apply_fn for each valid record.
// Chain verification starts from the zero hash.
replay_wal :: proc(path: string, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> Replay_Result {
	return replay_wal_with_initial_hash(path, magic, thread_index, [32]byte{}, apply_fn)
}

// replay_wal_data replays a WAL byte slice and calls apply_fn for each valid record.
// This is used by deterministic simulation tests where the WAL lives on a virtual
// in-memory block device instead of an OS file.
replay_wal_data :: proc(data: []byte, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> Replay_Result {
	return replay_wal_data_with_initial_hash(data, magic, thread_index, [32]byte{}, apply_fn)
}

replay_wal_data_with_initial_hash :: proc(
	data: []byte,
	magic: u32,
	thread_index: int,
	initial_prev_hash: [32]byte,
	apply_fn: Apply_Record_Proc,
) -> Replay_Result {
	start_time := time.now()
	parsed := parse_wal_data(data, magic, thread_index, initial_prev_hash, apply_fn)

	elapsed := time.diff(start_time, time.now())
	log.infof("[T%d] Replayed %d records from virtual WAL in %v (chain verified)", thread_index, parsed.result.record_count, elapsed)
	return parsed.result
}

Parsed_WAL_Data :: struct {
	result:           Replay_Result,
	offset:           int,
	stopped_by_apply: bool,
	invalid_tail:     bool,
	recoverable_tail: bool,
}

WAL_Read_Source_Proc :: proc(data: rawptr, offset, length: int) -> ([]byte, bool)

Memory_WAL_Read_Source :: struct {
	data: []byte,
}

memory_wal_read_source :: proc(data: rawptr, offset, length: int) -> ([]byte, bool) {
	source := (^Memory_WAL_Read_Source)(data)
	if source == nil || offset < 0 || length < 0 || offset > len(source.data) - length do return nil, false
	return source.data[offset:offset + length], true
}

parse_wal_source :: proc(
	source_data: rawptr,
	read_source: WAL_Read_Source_Proc,
	data_length: int,
	magic: u32,
	thread_index: int,
	initial_prev_hash: [32]byte,
	apply_fn: Apply_Record_Proc,
	apply_sized_fn: Apply_Record_Sized_Proc = nil,
) -> Parsed_WAL_Data {
	parsed := Parsed_WAL_Data{}

	if data_length == 0 {
		parsed.result.ok = true
		return parsed
	}

	offset := 0
	record_count := 0
	expected_prev_hash := initial_prev_hash
	crc32_state: xxhash.XXH32_state
	crc64_state: xxhash.XXH64_state
	sha_state: sha2.Context_256

	for offset + LEGACY_LOG_HEADER_SIZE <= data_length {
		header_data, header_read_ok := read_source(source_data, offset, LEGACY_LOG_HEADER_SIZE)
		if !header_read_ok do return parsed

		file_magic, _ := endian.get_u32(header_data[0:], .Big)
		if file_magic != magic {
			log.warnf("[T%d] Invalid magic at WAL offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			break
		}

		version, _ := endian.get_u16(header_data[4:], .Big)
		op := header_data[6]
		length, _ := endian.get_u32(header_data[8:], .Big)

		prev_hash: [32]byte
		copy(prev_hash[:], header_data[12:44])

		header_size, header_ok := record_header_size_from_flags(header_data[7])
		if !header_ok {
			log.warnf("[T%d] Unsupported WAL record flags at offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			break
		}
		if length > MAX_WAL_PAYLOAD_SIZE {
			log.warnf("[T%d] Oversized WAL record at offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			break
		}

		if prev_hash != expected_prev_hash {
			log.warnf("[T%d] Hash chain broken at WAL offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			break
		}

		if header_size > len(header_data) {
			header_data, header_read_ok = read_source(source_data, offset, header_size)
			if !header_read_ok {
				log.warnf("[T%d] Incomplete WAL header at offset %d, stopping replay", thread_index, offset)
				parsed.invalid_tail = true
				parsed.recoverable_tail = true
				break
			}
		}

		record_size := header_size + int(length)
		if offset + record_size > data_length {
			// A bounded header linked to the current chain followed by EOF is the
			// physically incomplete final append that startup is allowed to remove.
			// Complete checksum failures and semantic callback rejection remain fatal.
			log.warnf("[T%d] Incomplete WAL record at offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			parsed.recoverable_tail = true
			break
		}

		record_data, record_read_ok := read_source(source_data, offset, record_size)
		if !record_read_ok do return parsed
		if !validate_record_checksum(&crc32_state, &crc64_state, record_data, int(length)) {
			log.warnf("[T%d] CRC mismatch at WAL offset %d, stopping replay", thread_index, offset)
			parsed.invalid_tail = true
			break
		}

		payload := record_data[header_size:][:length]
		applied := apply_sized_fn != nil ? apply_sized_fn(op, version, payload, record_size) : apply_fn(op, version, payload)
		if !applied {
			parsed.stopped_by_apply = true
			break
		}

		compute_chain_hash(&sha_state, record_data, expected_prev_hash[:])
		record_count += 1
		offset += record_size
	}

	if !parsed.stopped_by_apply && !parsed.invalid_tail && offset < data_length {
		log.warnf("[T%d] Trailing bytes at WAL offset %d, stopping replay", thread_index, offset)
		parsed.invalid_tail = true
		parsed.recoverable_tail = true
	}

	parsed.offset = offset
	parsed.result.record_count = u64(record_count)
	parsed.result.last_hash = expected_prev_hash
	parsed.result.ok = true
	return parsed
}

parse_wal_data :: proc(data: []byte, magic: u32, thread_index: int, initial_prev_hash: [32]byte, apply_fn: Apply_Record_Proc) -> Parsed_WAL_Data {
	source := Memory_WAL_Read_Source{data}
	return parse_wal_source(&source, memory_wal_read_source, len(data), magic, thread_index, initial_prev_hash, apply_fn)
}

Storage_WAL_Read_Source :: struct {
	file:   ^storage_io.File,
	buffer: [dynamic]byte,
}

storage_wal_read_source :: proc(data: rawptr, offset, length: int) -> ([]byte, bool) {
	source := (^Storage_WAL_Read_Source)(data)
	if source == nil || source.file == nil || offset < 0 || length < 0 do return nil, false
	resize(&source.buffer, length)
	read := 0
	for read < length {
		count, read_err := storage_io.read_at(source.file, source.buffer[read:length], offset + read)
		if read_err != nil || count <= 0 do return nil, false
		read += count
	}
	return source.buffer[:length], true
}

Direct_WAL_Read_Source :: struct {
	fd:                 linux.Fd,
	alignment:          int,
	file_size:          int,
	buffer:             []byte,
	buffer_file_offset: int,
	buffer_data_length: int,
	pread:              Direct_WAL_Pread_Proc,
}

DIRECT_WAL_READ_AHEAD_SIZE :: 1024 * 1024
MAX_DIRECT_WAL_ALIGNMENT :: DIRECT_WAL_READ_AHEAD_SIZE
MAX_DIRECT_WAL_NO_PROGRESS_READS :: 8
Direct_WAL_Pread_Proc :: proc "contextless" (fd: linux.Fd, buf: []byte, offset: i64) -> (int, linux.Errno)

close_direct_wal_read_source :: proc(source: ^Direct_WAL_Read_Source) {
	if len(source.buffer) > 0 {
		_ = mem.free_bytes(source.buffer)
		source.buffer = nil
	}
	if source.fd >= 0 {
		_ = linux.close(source.fd)
		source.fd = -1
	}
}

direct_wal_read_source :: proc(data: rawptr, offset, length: int) -> ([]byte, bool) {
	source := (^Direct_WAL_Read_Source)(data)
	if source == nil || source.fd < 0 || source.pread == nil || offset < 0 || length < 0 || offset > source.file_size - length || source.alignment <= 0 do return nil, false
	if offset >= source.buffer_file_offset && offset + length <= source.buffer_file_offset + source.buffer_data_length {
		buffer_offset := offset - source.buffer_file_offset
		return source.buffer[buffer_offset:buffer_offset + length], true
	}
	// A failed refill may have overwritten the allocation. Invalidate the old
	// cache range before issuing I/O so no later call can return those bytes.
	source.buffer_data_length = 0
	aligned_offset := offset / source.alignment * source.alignment
	prefix := offset - aligned_offset
	needed := prefix + length
	read_size := max(needed, DIRECT_WAL_READ_AHEAD_SIZE)
	read_size = (read_size + source.alignment - 1) / source.alignment * source.alignment
	if len(source.buffer) < read_size {
		if len(source.buffer) > 0 {
			_ = mem.free_bytes(source.buffer)
		}
		buffer, alloc_err := mem.alloc_bytes(read_size, source.alignment)
		if alloc_err != nil {
			source.buffer = nil
			return nil, false
		}
		source.buffer = buffer
	}

	filled := 0
	no_progress_reads := 0
	for filled < needed {
		read, read_err := source.pread(source.fd, source.buffer[filled:read_size], i64(aligned_offset + filled))
		if read_err == .EINTR do continue
		if read_err != .NONE || read <= 0 do return nil, false
		available := filled + read
		if available >= needed {
			filled = available
			break
		}
		if aligned_offset + available >= source.file_size do return nil, false
		aligned_progress := read / source.alignment * source.alignment
		if aligned_progress == 0 {
			no_progress_reads += 1
			if no_progress_reads >= MAX_DIRECT_WAL_NO_PROGRESS_READS do return nil, false
			continue
		}
		filled += aligned_progress
		no_progress_reads = 0
	}
	source.buffer_file_offset = aligned_offset
	source.buffer_data_length = filled
	return source.buffer[prefix:prefix + length], true
}

open_direct_wal_read_source :: proc(path: string, thread_index: int) -> (source: Direct_WAL_Read_Source, file_size: int, ok: bool) {
	source.fd = -1
	path_cstr := strings.clone_to_cstring(path, context.temp_allocator)
	if path_cstr == nil do return
	fd, open_err := linux.open(path_cstr, {.DIRECT, .CLOEXEC})
	if open_err != .NONE {
		log.errorf("[T%d] Failed to open WAL with O_DIRECT: %s (%v)", thread_index, path, open_err)
		return
	}
	source.fd = fd

	file_stat: linux.Stat
	stat_err := linux.fstat(fd, &file_stat)
	if stat_err != .NONE || file_stat.size < 0 || u64(file_stat.size) > u64(max(int)) {
		log.errorf("[T%d] Failed to stat direct WAL file: %s (%v)", thread_index, path, stat_err)
		close_direct_wal_read_source(&source)
		return
	}
	file_size = int(file_stat.size)
	source.file_size = file_size
	source.pread = linux.pread
	memory_alignment := 4096
	offset_alignment := 4096
	direct_stat: linux.Statx
	if linux.statx(fd, "", {.EMPTY_PATH}, {.DIOALIGN}, &direct_stat) == .NONE && .DIOALIGN in direct_stat.mask {
		if (direct_stat.dio_mem_align == 0) != (direct_stat.dio_offset_align == 0) {
			log.errorf("[T%d] Incomplete WAL direct-I/O alignment for file: %s", thread_index, path)
			close_direct_wal_read_source(&source)
			return
		}
		// Some filesystems report the DIOALIGN mask with both fields zero even
		// though aligned O_DIRECT reads are supported. Keep the conservative
		// 4096-byte fallback when no concrete requirements are reported.
		if direct_stat.dio_mem_align > 0 {
			memory_alignment = int(direct_stat.dio_mem_align)
			offset_alignment = int(direct_stat.dio_offset_align)
		}
	}
	if memory_alignment & (memory_alignment - 1) != 0 ||
	   offset_alignment & (offset_alignment - 1) != 0 ||
	   memory_alignment > MAX_DIRECT_WAL_ALIGNMENT ||
	   offset_alignment > MAX_DIRECT_WAL_ALIGNMENT {
		log.errorf("[T%d] Unsupported WAL direct-I/O alignment memory=%d offset=%d: %s", thread_index, memory_alignment, offset_alignment, path)
		close_direct_wal_read_source(&source)
		return
	}
	// Both validated requirements are powers of two, so their maximum is a
	// multiple of each and is valid for buffer addresses, offsets, and lengths.
	source.alignment = max(memory_alignment, offset_alignment)
	return source, file_size, true
}

parse_wal_file_direct :: proc(
	path: string,
	magic: u32,
	thread_index: int,
	initial_prev_hash: [32]byte,
	apply_fn: Apply_Record_Proc,
	apply_sized_fn: Apply_Record_Sized_Proc = nil,
) -> (
	parsed: Parsed_WAL_Data,
	file_size: int,
	ok: bool,
) {
	source, direct_file_size, open_ok := open_direct_wal_read_source(path, thread_index)
	if !open_ok do return
	defer close_direct_wal_read_source(&source)
	parsed = parse_wal_source(&source, direct_wal_read_source, direct_file_size, magic, thread_index, initial_prev_hash, apply_fn, apply_sized_fn)
	return parsed, direct_file_size, parsed.result.ok
}

parse_wal_file_with_storage :: proc(
	storage: storage_io.Context,
	path: string,
	magic: u32,
	thread_index: int,
	initial_prev_hash: [32]byte,
	apply_fn: Apply_Record_Proc,
	apply_sized_fn: Apply_Record_Sized_Proc = nil,
) -> (
	parsed: Parsed_WAL_Data,
	file_size: int,
	ok: bool,
) {
	if storage_io.context_is_host(storage) {
		return parse_wal_file_direct(path, magic, thread_index, initial_prev_hash, apply_fn, apply_sized_fn)
	}
	file, open_err := storage_io.open(storage, path, {.Read})
	if open_err != nil do return
	defer storage_io.discard(file)
	size, size_err := storage_io.file_size(file)
	if size_err != nil || size < 0 || u64(size) > u64(max(int)) do return
	file_size = int(size)
	source := Storage_WAL_Read_Source {
		file   = file,
		buffer = make([dynamic]byte),
	}
	defer delete(source.buffer)
	parsed = parse_wal_source(&source, storage_wal_read_source, file_size, magic, thread_index, initial_prev_hash, apply_fn, apply_sized_fn)
	return parsed, file_size, parsed.result.ok
}

// inspect_wal_file_strict verifies a complete WAL without recovery, truncation, or
// any other mutation. Direct I/O prevents recovery from trusting clean page-cache
// data left behind by a failed fsync. Callback payloads borrow the read buffer.
inspect_wal_file_strict :: proc {
	inspect_wal_file_strict_host,
	inspect_wal_file_strict_with_storage,
}

inspect_wal_file_strict_host :: proc(path: string, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> Strict_WAL_Inspection {
	return inspect_wal_file_strict_with_storage(storage_io.host_context(), path, magic, thread_index, apply_fn)
}

inspect_wal_file_strict_with_storage :: proc(
	storage: storage_io.Context,
	path: string,
	magic: u32,
	thread_index: int,
	apply_fn: Apply_Record_Proc,
) -> (
	inspection: Strict_WAL_Inspection,
) {
	parsed, file_size, read_ok := parse_wal_file_with_storage(storage, path, magic, thread_index, [32]byte{}, apply_fn)
	inspection.file_size = u64(file_size)
	if !read_ok || parsed.invalid_tail || parsed.stopped_by_apply || parsed.offset != file_size do return
	inspection.record_count = parsed.result.record_count
	inspection.last_hash = parsed.result.last_hash
	inspection.ok = true
	return
}

inspect_wal_file_strict_sized :: proc(
	storage: storage_io.Context,
	path: string,
	magic: u32,
	thread_index: int,
	apply_fn: Apply_Record_Sized_Proc,
) -> (
	inspection: Strict_WAL_Inspection,
) {
	parsed, file_size, read_ok := parse_wal_file_with_storage(storage, path, magic, thread_index, [32]byte{}, nil, apply_fn)
	inspection.file_size = u64(file_size)
	if !read_ok || parsed.invalid_tail || parsed.stopped_by_apply || parsed.offset != file_size do return
	inspection.record_count = parsed.result.record_count
	inspection.last_hash = parsed.result.last_hash
	inspection.ok = true
	return
}

// inspect_wal_file_with_tail_recovery validates semantic records exactly like
// strict inspection, but truncates a physically invalid final WAL suffix to the
// last complete, checksum-valid record. Callback rejection is never truncated.
inspect_wal_file_with_tail_recovery :: proc {
	inspect_wal_file_with_tail_recovery_host,
	inspect_wal_file_with_tail_recovery_with_storage,
}

inspect_wal_file_with_tail_recovery_host :: proc(path: string, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> Strict_WAL_Inspection {
	return inspect_wal_file_with_tail_recovery_with_storage(storage_io.host_context(), path, magic, thread_index, apply_fn)
}

inspect_wal_file_with_tail_recovery_with_storage :: proc(
	storage: storage_io.Context,
	path: string,
	magic: u32,
	thread_index: int,
	apply_fn: Apply_Record_Proc,
) -> (
	inspection: Strict_WAL_Inspection,
) {
	parsed, file_size, read_ok := parse_wal_file_with_storage(storage, path, magic, thread_index, [32]byte{}, apply_fn)
	if !read_ok || parsed.stopped_by_apply || parsed.invalid_tail && !parsed.recoverable_tail do return
	if parsed.recoverable_tail {
		if !truncate_wal_at(storage, path, parsed.offset, thread_index) do return
	} else if parsed.offset != file_size {
		return
	}
	inspection.file_size = u64(parsed.offset)
	inspection.record_count = parsed.result.record_count
	inspection.last_hash = parsed.result.last_hash
	inspection.ok = true
	return
}

// audit_wal_file_strict is the boolean compatibility wrapper for strict inspection.
audit_wal_file_strict :: proc(path: string, magic: u32, thread_index: int, apply_fn: Apply_Record_Proc) -> bool {
	return inspect_wal_file_strict(path, magic, thread_index, apply_fn).ok
}

// replay_wal_with_initial_hash replays a WAL file and verifies that the first record links
// to initial_prev_hash. This is used for chained replay across split log files.
replay_wal_with_initial_hash :: proc(path: string, magic: u32, thread_index: int, initial_prev_hash: [32]byte, apply_fn: Apply_Record_Proc) -> Replay_Result {
	result := Replay_Result{}
	start_time := time.now()

	parsed, _, read_ok := parse_wal_file_direct(path, magic, thread_index, initial_prev_hash, apply_fn)
	if !read_ok do return result
	if parsed.invalid_tail {
		if !parsed.recoverable_tail || !truncate_wal_at(path, parsed.offset, thread_index) {
			return result
		}
	}

	result = parsed.result

	elapsed := time.diff(start_time, time.now())
	log.infof("[T%d] Replayed %d records from WAL in %v (chain verified)", thread_index, result.record_count, elapsed)
	return result
}

// truncate_wal_at truncates the WAL file at the given offset
truncate_wal_at :: proc {
	truncate_wal_at_host,
	truncate_wal_at_with_storage,
}

truncate_wal_at_host :: proc(path: string, offset: int, thread_index: int) -> bool {
	return truncate_wal_at_with_storage(storage_io.host_context(), path, offset, thread_index)
}

truncate_wal_at_with_storage :: proc(storage: storage_io.Context, path: string, offset: int, thread_index: int) -> bool {
	f, open_err := storage_io.open(storage, path, {.Write})
	if open_err != nil {
		log.errorf("[T%d] Failed to open WAL for truncation at offset %d: %v", thread_index, offset, open_err)
		return false
	}
	defer storage_io.discard(f)

	if wal_recovery_fault_for_test == .Truncate {
		wal_recovery_fault_for_test = .None
		return false
	}
	trunc_err := storage_io.truncate(f, offset)
	if trunc_err != nil {
		log.errorf("[T%d] Failed to truncate WAL at offset %d: %v", thread_index, offset, trunc_err)
		return false
	} else {
		if wal_recovery_fault_for_test == .Sync {
			wal_recovery_fault_for_test = .None
			return false
		}
		if storage_io.sync(f) != nil do return false
		log.infof("[T%d] Truncated WAL at offset %d", thread_index, offset)
	}
	return true
}

// ============================================================================
// Payload Helpers (for building payloads)
// ============================================================================

// write_workspace_prefix writes a length-prefixed workspace ID to a buffer
// Returns the number of bytes written
write_workspace_prefix :: proc(buf: []byte, workspace_id: string) -> int {
	endian.put_u16(buf[0:], .Big, u16(len(workspace_id)))
	copy(buf[2:], workspace_id)
	return 2 + len(workspace_id)
}

// parse_workspace_prefix parses a length-prefixed workspace ID from payload
// Returns the workspace_id string and offset after it, or empty string and 0 on error
parse_workspace_prefix :: proc(payload: []byte) -> (workspace_id: string, offset: int, ok: bool) {
	if len(payload) < 2 {
		return "", 0, false
	}
	ws_len, _ := endian.get_u16(payload[0:], .Big)
	offset = 2

	if len(payload) < offset + int(ws_len) {
		return "", 0, false
	}
	workspace_id = string(payload[offset:][:ws_len])
	offset += int(ws_len)

	return workspace_id, offset, true
}
