package main

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"

import "persistence"
import "storage_io"

MESSAGE_MANIFEST_HEADER_SIZE :: 64
MESSAGE_MANIFEST_SEGMENT_SIZE :: 48
MESSAGE_MAX_INDEX_BYTES :: 160 * 1024 * 1024
MESSAGE_MAX_INDEX_RECORDS :: (MESSAGE_MAX_INDEX_BYTES - MESSAGE_INDEX_HEADER_SIZE) / (MESSAGE_INDEX_ENTRY_SIZE + MESSAGE_DEDUP_ENTRY_SIZE)

Message_Index_Record :: struct {
	workspace_hash:  u64,
	conversation_id: u64,
	principal_hash:  u64,
	client_id:       [16]byte,
	fingerprint:     u64,
	sequence:        u64,
	accepted_at_ns:  i64,
	offset:          u64,
	length:          u32,
}

Message_Scan_Mode :: enum {
	Recover_Active,
	Build_Index,
	Validate,
}
Message_Scan_Context :: struct {
	store:   ^Message_Store,
	mode:    Message_Scan_Mode,
	offset:  u64,
	records: [dynamic]Message_Index_Record,
}

@(thread_local)
message_scan_context: Message_Scan_Context

message_string_hash :: proc(value: string) -> u64 {
	hash: u64 = 1469598103934665603
	for b in transmute([]byte)value do hash = (hash ~ u64(b)) * 1099511628211
	return hash
}

message_dedup_key :: proc(workspace, principal: string, id: [16]byte, allocator := context.allocator) -> string {
	buf := make([]byte, 2 + len(workspace) + 2 + len(principal) + len(id), allocator)
	message_put_u16(buf, u16(len(workspace))); cursor := 2
	copy(buf[cursor:], workspace); cursor += len(workspace)
	message_put_u16(buf[cursor:], u16(len(principal))); cursor += 2
	copy(buf[cursor:], principal); cursor += len(principal)
	for value, i in id do buf[cursor + i] = value
	return transmute(string)buf
}

append_active_message_offset :: proc(store: ^Message_Store, workspace: string, conversation_id: u64, entry: Message_Offset_Entry) -> bool {
	key := Message_Conversation_Key{workspace, conversation_id}
	entries, present := store.active_offsets[key]
	if !present {
		allocator := virtual.arena_allocator(store.active_index_arena)
		entries = make([dynamic]Message_Offset_Entry, 0, 16, allocator = allocator)
	}
	if _, err := append(&entries, entry); err != nil do return false
	if !present {
		owned_workspace, clone_err := strings.clone(workspace, virtual.arena_allocator(store.active_index_arena))
		if clone_err != nil do return false
		key.workspace = owned_workspace
	}
	store.active_offsets[key] = entries
	return true
}

cache_active_message_payload :: proc(store: ^Message_Store, payload: []byte) -> []byte {
	if store == nil || len(payload) == 0 || store.active_cache_budget == nil do return nil
	budget := store.active_cache_budget
	size := u64(len(payload))
	if size > budget.limit_bytes || budget.used_bytes > budget.limit_bytes - size do return nil
	if !store.active_record_ready {
		if store.active_record_arena == nil do store.active_record_arena = new(virtual.Arena)
		if virtual.arena_init_growing(store.active_record_arena, MESSAGE_ACTIVE_RECORD_ARENA_BLOCK_BYTES) != nil do return nil
		store.active_record_ready = true
	}
	cached, err := mem.alloc_bytes_non_zeroed(len(payload), 1, virtual.arena_allocator(store.active_record_arena))
	if err != .None do return nil
	copy(cached, payload)
	budget.used_bytes += size
	store.active_cached_bytes += size
	return cached
}

release_active_message_cache :: proc(store: ^Message_Store, destroy: bool) {
	if store == nil do return
	if store.active_cache_budget != nil {
		assert(store.active_cache_budget.used_bytes >= store.active_cached_bytes)
		store.active_cache_budget.used_bytes -= store.active_cached_bytes
	}
	store.active_cached_bytes = 0
	if store.active_record_ready {
		if destroy {
			virtual.arena_destroy(store.active_record_arena)
			store.active_record_ready = false
		} else {
			virtual.arena_free_all(store.active_record_arena)
		}
	}
	if destroy {free(store.active_record_arena); store.active_record_arena = nil}
}

message_scan_record :: proc(op: u8, version: u16, payload: []byte) -> bool {
	c := &message_scan_context
	if op != 1 || version != MESSAGE_WAL_VERSION do return false
	// Fields borrow the inspection buffer only for this callback. Recovery
	// clones keys/cache payloads; index records contain only values and hashes.
	m, ok := decode_message_record_borrowed(payload)
	if !ok || m.sequence == 0 || m.fingerprint != message_fingerprint(&m) do return false
	length := u32(persistence.LOG_HEADER_SIZE + len(payload))
	offset := c.offset
	c.offset += u64(length)
	switch c.mode {
	case .Recover_Active:
		if c.store == nil || m.sequence <= c.store.high_water do return false
		if !c.store.active_arena_ready && !init_active_message_indexes(c.store) do return false
		c.store.high_water = m.sequence
		if c.store.active_first_seq == 0 do c.store.active_first_seq = m.sequence
		if c.store.active_min_time == 0 || m.accepted_at_ns < c.store.active_min_time do c.store.active_min_time = m.accepted_at_ns
		if m.accepted_at_ns > c.store.active_max_time do c.store.active_max_time = m.accepted_at_ns
		dedup_key := message_dedup_key(m.workspace, m.sender_principal, m.client_message_id)
		defer delete(dedup_key)
		_, dedup_key_present := c.store.active_dedup[dedup_key]
		stored_key := dedup_key
		if !dedup_key_present {
			owned_key, clone_err := strings.clone(dedup_key, virtual.arena_allocator(c.store.active_index_arena))
			if clone_err != nil do return false
			stored_key = owned_key
		}
		c.store.active_dedup[stored_key] = {
			fingerprint    = m.fingerprint,
			sequence       = m.sequence,
			accepted_at_ns = m.accepted_at_ns,
			offset         = offset,
			length         = length,
		}
		cached_payload := cache_active_message_payload(c.store, payload)
		offsets_ok := append_active_message_offset(
			c.store,
			m.workspace,
			m.conversation_id,
			Message_Offset_Entry{m.accepted_at_ns, offset, length, m.sequence, cached_payload},
		)
		if !offsets_ok do return false
	case .Build_Index:
		record := Message_Index_Record {
			workspace_hash  = message_string_hash(m.workspace),
			conversation_id = m.conversation_id,
			principal_hash  = message_string_hash(m.sender_principal),
			client_id       = m.client_message_id,
			fingerprint     = m.fingerprint,
			sequence        = m.sequence,
			accepted_at_ns  = m.accepted_at_ns,
			offset          = offset,
			length          = length,
		}
		if _, err := append(&c.records, record); err != nil do return false
	case .Validate:
	}
	return true
}

// Compare in place: the typed Boolean sort adapter copies two full records
// and may call its comparator twice to determine a three-way ordering.
message_index_record_cmp :: proc(lhs, rhs, _: rawptr) -> slice.Ordering {
	a, b := (^Message_Index_Record)(lhs), (^Message_Index_Record)(rhs)
	if a.workspace_hash != b.workspace_hash do return a.workspace_hash < b.workspace_hash ? .Less : .Greater
	if a.conversation_id != b.conversation_id do return a.conversation_id < b.conversation_id ? .Less : .Greater
	if a.sequence != b.sequence do return a.sequence < b.sequence ? .Less : .Greater
	return .Equal
}

message_dedup_record_cmp :: proc(lhs, rhs, _: rawptr) -> slice.Ordering {
	a, b := (^Message_Index_Record)(lhs), (^Message_Index_Record)(rhs)
	if a.workspace_hash != b.workspace_hash do return a.workspace_hash < b.workspace_hash ? .Less : .Greater
	if a.principal_hash != b.principal_hash do return a.principal_hash < b.principal_hash ? .Less : .Greater
	for value, i in a.client_id {
		if value != b.client_id[i] do return value < b.client_id[i] ? .Less : .Greater
	}
	return .Equal
}

message_put_u16 :: proc(buf: []byte, value: u16) {endian.put_u16(buf, .Little, value)}
message_put_u32 :: proc(buf: []byte, value: u32) {endian.put_u32(buf, .Little, value)}
message_put_u64 :: proc(buf: []byte, value: u64) {endian.put_u64(buf, .Little, value)}
message_get_u16 :: proc(buf: []byte) -> u16 {value, _ := endian.get_u16(buf, .Little); return value}
message_get_u32 :: proc(buf: []byte) -> u32 {value, _ := endian.get_u32(buf, .Little); return value}
message_get_u64 :: proc(buf: []byte) -> u64 {value, _ := endian.get_u64(buf, .Little); return value}

message_dedup_filter_hashes :: proc(workspace_hash, principal_hash: u64, client_id: [16]byte) -> (u64, u64) {
	key: [40]byte
	message_put_u64(key[:], workspace_hash)
	message_put_u64(key[8:], principal_hash)
	for value, i in client_id do key[16 + i] = value
	first := xxhash.XXH64(key[:32])
	message_put_u64(key[32:], 0x9e3779b97f4a7c15)
	return first, xxhash.XXH64(key[:]) | 1
}

message_dedup_filter_add :: proc(filter: []u64, workspace_hash, principal_hash: u64, client_id: [16]byte) {
	if len(filter) == 0 do return
	first, step := message_dedup_filter_hashes(workspace_hash, principal_hash, client_id)
	bit_count := u64(len(filter) * 64)
	for i in 0 ..< MESSAGE_DEDUP_FILTER_HASH_COUNT {
		bit := (first + u64(i) * step) % bit_count
		filter[bit / 64] |= u64(1) << (bit % 64)
	}
}

message_dedup_filter_maybe_contains :: proc(filter: []u64, workspace, principal: string, client_id: [16]byte) -> bool {
	if len(filter) == 0 do return true
	first, step := message_dedup_filter_hashes(message_string_hash(workspace), message_string_hash(principal), client_id)
	bit_count := u64(len(filter) * 64)
	for i in 0 ..< MESSAGE_DEDUP_FILTER_HASH_COUNT {
		bit := (first + u64(i) * step) % bit_count
		if filter[bit / 64] & (u64(1) << (bit % 64)) == 0 do return false
	}
	return true
}

message_write_all :: proc(file: ^storage_io.File, data: []byte) -> bool {
	written := 0
	for written < len(data) {
		n, err := storage_io.write(file, data[written:])
		if err != nil || n <= 0 do return false
		written += n
	}
	return true
}

message_read_all_at :: proc(file: ^storage_io.File, data: []byte, offset: u64) -> bool {
	if offset > u64(max(int)) do return false
	read := 0
	for read < len(data) {
		if u64(read) > u64(max(int)) - offset do return false
		n, err := storage_io.read_at(file, data[read:], int(offset + u64(read)))
		if err != nil || n <= 0 do return false
		read += n
	}
	return true
}

cluster_message_segment_wal :: proc(store: ^Message_Store, source_generation, sealed_generation: u64) -> (u64, bool) {
	if store == nil || source_generation == sealed_generation do return 0, false
	source_path := message_store_path(store.directory, source_generation, "wal"); defer delete(source_path)
	sealed_path := message_store_path(store.directory, sealed_generation, "wal"); defer delete(sealed_path)
	sealed_index_path := message_store_path(store.directory, sealed_generation, "idx"); defer delete(sealed_index_path)
	_ = storage_io.remove(store.storage, sealed_path)
	_ = storage_io.remove(store.storage, sealed_index_path)

	message_scan_context = {
		mode = .Build_Index,
	}
	inspection := persistence.inspect_wal_file_strict_with_storage(store.storage, source_path, MESSAGE_WAL_MAGIC, store.shard, message_scan_record)
	records := message_scan_context.records
	indexed_bytes := message_scan_context.offset
	message_scan_context = {}
	defer delete(records)
	// The index assumes current-size headers, while strict inspection also
	// understands legacy headers. Never copy bytes with incompatible offsets.
	if !inspection.ok || len(records) == 0 || indexed_bytes != inspection.file_size do return 0, false
	ordered := true
	for i in 1 ..< len(records) {
		if message_index_record_cmp(&records[i], &records[i - 1], nil) == .Less {
			ordered = false
			break
		}
	}
	if !ordered do slice.sort_by_generic_cmp(records[:], message_index_record_cmp, nil)

	source, open_err := storage_io.open(store.storage, source_path, {.Read})
	if open_err != nil do return 0, false
	defer storage_io.discard(source)
	builder: persistence.WAL_File_Builder
	if !persistence.create_wal_file_builder_with_storage(&builder, store.storage, sealed_path, MESSAGE_WAL_MAGIC, MESSAGE_WAL_VERSION) do return 0, false
	finished := false
	defer if !finished {
		persistence.abort_wal_file_builder(&builder)
		_ = storage_io.remove(store.storage, sealed_path)
		_ = storage_io.remove(store.storage, sealed_index_path)
	}
	if ordered {
		// Rotation closed or froze the source writer before inspection. Preserve the
		// validated chain and offsets when physical order already matches.
		if !persistence.copy_wal_file_builder(&builder, source, inspection) do return 0, false
	} else {
		max_record_size := 0
		for record in records {
			if record.length < persistence.LOG_HEADER_SIZE do return 0, false
			max_record_size = max(max_record_size, int(record.length))
		}
		buffer := make([]byte, max(persistence.WRITE_BATCH_MAX_BYTES, max_record_size), context.allocator); defer delete(buffer)
		first := 0
		for first < len(records) {
			// Coalesce only physically adjacent records in output order. Reading
			// through gaps would amplify I/O for interleaved conversations.
			source_offset := records[first].offset
			read_bytes := int(records[first].length)
			end := first + 1
			for end < len(records) && records[end].offset == source_offset + u64(read_bytes) && int(records[end].length) <= len(buffer) - read_bytes {
				read_bytes += int(records[end].length)
				end += 1
			}
			if !message_read_all_at(source, buffer[:read_bytes], source_offset) do return 0, false
			cursor := 0
			for &record in records[first:end] {
				record.offset = builder.file_size
				length := int(record.length)
				if !persistence.append_wal_file_builder(&builder, 1, buffer[cursor:cursor + length]) do return 0, false
				cursor += length
			}
			first = end
		}
	}
	sealed_bytes := builder.file_size
	if sealed_bytes != inspection.file_size || builder.record_count != inspection.record_count do return 0, false
	if !persistence.finish_wal_file_builder(&builder) do return 0, false
	if storage_io.sync_directory(store.storage, store.directory) != nil do return 0, false
	if !write_message_segment_index(store, sealed_generation, sealed_bytes, records[:]) do return 0, false
	finished = true
	return sealed_bytes, true
}

// Records are caller-owned scratch, already in conversation/sequence order.
// After encoding that index, reuse the records for the dedup sort in place.
write_message_segment_index :: proc(store: ^Message_Store, generation, wal_bytes: u64, records: []Message_Index_Record) -> bool {
	if store == nil || len(records) == 0 do return false
	idx_path := message_store_path(store.directory, generation, "idx"); defer delete(idx_path)
	tmp_path := fmt.aprintf("%s.tmp", idx_path); defer delete(tmp_path)
	_ = storage_io.remove(store.storage, tmp_path)

	dedup_offset := MESSAGE_INDEX_HEADER_SIZE + len(records) * MESSAGE_INDEX_ENTRY_SIZE
	total_size := dedup_offset + len(records) * MESSAGE_DEDUP_ENTRY_SIZE
	if total_size > MESSAGE_MAX_INDEX_BYTES do return false
	data := make([]byte, total_size, context.allocator); defer delete(data)
	message_put_u32(data[0:], MESSAGE_INDEX_MAGIC); message_put_u16(data[4:], MESSAGE_INDEX_VERSION)
	message_put_u16(data[6:], u16(store.shard)); message_put_u64(data[8:], generation)
	message_put_u64(data[16:], wal_bytes); message_put_u64(data[24:], u64(len(records)))
	message_put_u64(data[32:], MESSAGE_INDEX_HEADER_SIZE); message_put_u64(data[40:], u64(dedup_offset))
	message_put_u64(data[48:], u64(total_size)); message_put_u64(data[64:], records[0].sequence)
	message_put_u64(data[72:], records[len(records) - 1].sequence)
	cursor := MESSAGE_INDEX_HEADER_SIZE
	for record in records {
		message_put_u64(data[cursor:], record.workspace_hash); message_put_u64(data[cursor + 8:], record.conversation_id)
		message_put_u64(data[cursor + 16:], record.sequence); message_put_u64(data[cursor + 24:], u64(record.accepted_at_ns))
		message_put_u64(data[cursor + 32:], record.offset); message_put_u32(data[cursor + 40:], record.length)
		cursor += MESSAGE_INDEX_ENTRY_SIZE
	}
	slice.sort_by_generic_cmp(records, message_dedup_record_cmp, nil)
	for record in records {
		message_put_u64(data[cursor:], record.workspace_hash); message_put_u64(data[cursor + 8:], record.principal_hash)
		for value, i in record.client_id do data[cursor + 16 + i] = value
		message_put_u64(data[cursor + 32:], record.fingerprint)
		message_put_u64(data[cursor + 40:], record.sequence); message_put_u64(data[cursor + 48:], record.offset)
		message_put_u32(data[cursor + 56:], record.length); cursor += MESSAGE_DEDUP_ENTRY_SIZE
	}
	message_put_u64(data[56:], xxhash.XXH64(data))
	file, open_err := storage_io.open(store.storage, tmp_path, {.Write, .Create, .Excl}, os.perm(0o644)); if open_err != nil do return false
	written := message_write_all(file, data); synced := written && storage_io.sync(file) == nil; closed := storage_io.close(file) == nil
	if !synced || !closed {_ = storage_io.remove(store.storage, tmp_path); return false}
	if storage_io.rename(store.storage, tmp_path, idx_path) != nil do return false
	return storage_io.sync_directory(store.storage, store.directory) == nil
}

build_message_segment_index :: proc(store: ^Message_Store, generation: u64) -> bool {
	wal_path := message_store_path(store.directory, generation, "wal"); defer delete(wal_path)
	message_scan_context = {
		mode = .Build_Index,
	}
	inspection := persistence.inspect_wal_file_strict_with_storage(store.storage, wal_path, MESSAGE_WAL_MAGIC, store.shard, message_scan_record)
	records := message_scan_context.records
	message_scan_context = {}
	defer delete(records)
	if !inspection.ok do return false
	slice.sort_by_generic_cmp(records[:], message_index_record_cmp, nil)
	return write_message_segment_index(store, generation, inspection.file_size, records[:])
}

validate_message_segment_index :: proc(store: ^Message_Store, segment: Message_Segment_Descriptor) -> bool {
	data := read_validated_message_segment_index(store, segment)
	defer delete(data)
	return data != nil
}

// Returns owned, validated file bytes, or nil on read/validation failure.
read_validated_message_segment_index :: proc(store: ^Message_Store, segment: Message_Segment_Descriptor) -> []byte {
	path := message_store_path(store.directory, segment.generation, "idx"); defer delete(path)
	data, err := storage_io.read_entire_file(store.storage, path, context.allocator)
	if err != nil || !validate_message_segment_index_data(store, segment, data) {
		delete(data)
		return nil
	}
	return data
}

validate_message_segment_index_data :: proc(store: ^Message_Store, segment: Message_Segment_Descriptor, data: []byte) -> bool {
	if len(data) < MESSAGE_INDEX_HEADER_SIZE || len(data) > MESSAGE_MAX_INDEX_BYTES do return false
	if message_get_u32(data) != MESSAGE_INDEX_MAGIC || message_get_u16(data[4:]) != MESSAGE_INDEX_VERSION || int(message_get_u16(data[6:])) != store.shard do return false
	if message_get_u64(data[8:]) != segment.generation || message_get_u64(data[16:]) != segment.bytes || message_get_u64(data[48:]) != u64(len(data)) do return false
	checksum := message_get_u64(data[56:]); message_put_u64(data[56:], 0)
	computed_checksum := xxhash.XXH64(data)
	message_put_u64(data[56:], checksum)
	if checksum != computed_checksum do return false
	count := message_get_u64(data[24:]); dedup_offset := message_get_u64(data[40:])
	if dedup_offset != MESSAGE_INDEX_HEADER_SIZE + count * MESSAGE_INDEX_ENTRY_SIZE || u64(len(data)) != dedup_offset + count * MESSAGE_DEDUP_ENTRY_SIZE {
		return false
	}
	expected_offset: u64
	previous_workspace, previous_conversation, previous_sequence: u64
	for i in 0 ..< int(count) {
		entry := data[MESSAGE_INDEX_HEADER_SIZE + i * MESSAGE_INDEX_ENTRY_SIZE:]
		workspace_hash := message_get_u64(entry)
		conversation_id := message_get_u64(entry[8:])
		sequence := message_get_u64(entry[16:])
		offset := message_get_u64(entry[32:])
		length := message_get_u32(entry[40:])
		if length < persistence.LOG_HEADER_SIZE || offset != expected_offset do return false
		if i > 0 &&
		   !(workspace_hash > previous_workspace ||
				   workspace_hash == previous_workspace &&
					   (conversation_id > previous_conversation || conversation_id == previous_conversation && sequence > previous_sequence)) {
			return false
		}
		expected_offset += u64(length)
		if expected_offset < offset do return false
		previous_workspace, previous_conversation, previous_sequence = workspace_hash, conversation_id, sequence
	}
	return expected_offset == segment.bytes
}

// Borrows bytes returned by read_validated_message_segment_index. Cached entries
// and metadata own their storage; the caller can release data after this call.
load_message_segment_index_metadata :: proc(store: ^Message_Store, segment: ^Message_Segment_Descriptor, load_dedup: bool, data: []byte) -> bool {
	if store == nil || segment == nil do return false
	count := int(message_get_u64(data[24:])); dedup_offset := int(message_get_u64(data[40:]))
	if count <= 0 || dedup_offset != MESSAGE_INDEX_HEADER_SIZE + count * MESSAGE_INDEX_ENTRY_SIZE || len(data) != dedup_offset + count * MESSAGE_DEDUP_ENTRY_SIZE do return false
	ranges: [dynamic]Message_Conversation_Range
	defer if ranges != nil do delete(ranges)
	for i in 0 ..< count {
		entry := data[MESSAGE_INDEX_HEADER_SIZE + i * MESSAGE_INDEX_ENTRY_SIZE:]
		workspace_hash := message_get_u64(entry)
		conversation_id := message_get_u64(entry[8:])
		if len(ranges) == 0 || ranges[len(ranges) - 1].workspace_hash != workspace_hash || ranges[len(ranges) - 1].conversation_id != conversation_id {
			if _, append_err := append(&ranges, Message_Conversation_Range{workspace_hash = workspace_hash, conversation_id = conversation_id, start = u64(i), end = u64(i + 1)}); append_err != nil do return false
		} else {
			ranges[len(ranges) - 1].end = u64(i + 1)
		}
	}
	filter: []u64
	if load_dedup do filter = make([]u64, (count * MESSAGE_DEDUP_FILTER_BITS_PER_ENTRY + 63) / 64, context.allocator)
	for i in 0 ..< count {
		if !load_dedup do break
		entry := data[dedup_offset + i * MESSAGE_DEDUP_ENTRY_SIZE:]
		client_id: [16]byte; copy(client_id[:], entry[16:32])
		message_dedup_filter_add(filter, message_get_u64(entry), message_get_u64(entry[8:]), client_id)
	}
	delete(segment.dedup_filter)
	delete(segment.conversation_ranges)
	segment.dedup_filter = filter
	segment.conversation_ranges = ranges
	ranges = nil
	cache_message_segment_index(store, segment, data[MESSAGE_INDEX_HEADER_SIZE:dedup_offset])
	return true
}

release_message_segment_index_cache :: proc(store: ^Message_Store, segment: ^Message_Segment_Descriptor) {
	if store == nil || segment == nil || len(segment.cached_message_index) == 0 do return
	if store.sealed_index_cache != nil {
		budget := store.sealed_index_cache
		assert(budget.used_bytes >= u64(len(segment.cached_message_index)))
		budget.used_bytes -= u64(len(segment.cached_message_index))
		for entry, i in budget.entries {
			if entry.store == store && entry.generation == segment.generation {
				copy(budget.entries[i:], budget.entries[i + 1:])
				resize(&budget.entries, len(budget.entries) - 1)
				break
			}
		}
	}
	delete(segment.cached_message_index)
	segment.cached_message_index = nil
}

release_message_segment_read_file :: proc(store: ^Message_Store, segment: ^Message_Segment_Descriptor) {
	if store == nil || segment == nil || segment.read_file == nil do return
	assert(segment.readers == 0, "cannot close a borrowed sealed message WAL descriptor")
	storage_io.discard(segment.read_file)
	segment.read_file = nil
	if store.sealed_wal_cache == nil do return
	for entry, i in store.sealed_wal_cache.entries {
		if entry.store == store && entry.generation == segment.generation {
			copy(store.sealed_wal_cache.entries[i:], store.sealed_wal_cache.entries[i + 1:])
			resize(&store.sealed_wal_cache.entries, len(store.sealed_wal_cache.entries) - 1)
			return
		}
	}
}

evict_message_segment_read_file :: proc(cache: ^Message_Sealed_WAL_Cache) -> bool {
	if cache == nil do return false
	for entry, i in cache.entries {
		if entry.store == nil do continue
		found := false
		for &segment in entry.store.segments {
			if segment.generation == entry.generation && segment.read_file != nil {
				found = true
				if segment.readers == 0 {
					release_message_segment_read_file(entry.store, &segment)
					return true
				}
				break
			}
		}
		if found do continue
		copy(cache.entries[i:], cache.entries[i + 1:])
		resize(&cache.entries, len(cache.entries) - 1)
		return true
	}
	return false
}

open_message_segment_read_file :: proc(
	store: ^Message_Store,
	segment: ^Message_Segment_Descriptor,
	path: string,
) -> (
	file: ^storage_io.File,
	owned, capacity: bool,
) {
	if store == nil || segment == nil do return nil, false, false
	if segment.read_file != nil {
		segment.readers += 1
		return segment.read_file, false, false
	}
	cache := store.sealed_wal_cache
	if cache != nil && cache.limit > 0 {
		for len(cache.entries) >= cache.limit do if !evict_message_segment_read_file(cache) do break
		if len(cache.entries) >= cache.limit do return nil, false, true
	}
	file, _ = storage_io.open(store.storage, path, {.Read})
	if file == nil do return nil, false, false
	if cache != nil && len(cache.entries) < cache.limit {
		if _, err := append(&cache.entries, Message_Sealed_WAL_Cache_Entry{store, segment.generation}); err == nil {
			segment.read_file = file
			segment.readers += 1
			return file, false, false
		}
		storage_io.discard(file)
		return nil, false, true
	}
	return file, true, false
}

release_message_segment_read_borrow :: proc(segment: ^Message_Segment_Descriptor) {
	if segment == nil do return
	assert(segment.readers > 0)
	segment.readers -= 1
}

cache_message_segment_index :: proc(store: ^Message_Store, segment: ^Message_Segment_Descriptor, entries: []byte) {
	if store == nil || segment == nil || len(entries) == 0 || store.sealed_index_cache == nil do return
	release_message_segment_index_cache(store, segment)
	budget := store.sealed_index_cache
	size := u64(len(entries))
	if size > budget.limit_bytes do return
	for budget.used_bytes > budget.limit_bytes - size {
		evicted := false
		for cache_entry in budget.entries {
			if cache_entry.store == nil || cache_entry.store.async_readers > 0 do continue
			for &candidate in cache_entry.store.segments {
				if candidate.generation == cache_entry.generation && len(candidate.cached_message_index) > 0 {
					release_message_segment_index_cache(cache_entry.store, &candidate)
					evicted = true
					break
				}
			}
			if evicted do break
		}
		if !evicted do return
	}
	cached, err := make([]byte, len(entries), context.allocator)
	if err != nil do return
	copy(cached, entries)
	if _, append_err := append(&budget.entries, Message_Sealed_Index_Cache_Entry{store, segment.generation}); append_err != nil {
		delete(cached)
		return
	}
	segment.cached_message_index = cached
	budget.used_bytes += size
}

destroy_message_segment_metadata :: proc(store: ^Message_Store, segments: []Message_Segment_Descriptor) {
	for &segment in segments {
		assert(segment.readers == 0, "sealed message WAL destruction requires drained readers")
		release_message_segment_index_cache(store, &segment)
		release_message_segment_read_file(store, &segment)
		delete(segment.dedup_filter)
		delete(segment.conversation_ranges)
		segment.dedup_filter = nil
		segment.conversation_ranges = nil
	}
}

write_message_manifest :: proc(store: ^Message_Store) -> bool {
	if store == nil || len(store.segments) > MESSAGE_MAX_SEGMENTS do return false
	frozen_count := store.frozen != nil && !store.frozen_published ? 1 : 0
	data := make([]byte, MESSAGE_MANIFEST_HEADER_SIZE + (len(store.segments) + frozen_count) * MESSAGE_MANIFEST_SEGMENT_SIZE, context.allocator)
	defer delete(data)
	message_put_u32(data, MESSAGE_MANIFEST_MAGIC); message_put_u16(data[4:], MESSAGE_MANIFEST_VERSION)
	message_put_u16(data[6:], u16(store.shard)); message_put_u64(data[8:], store.active_generation)
	message_put_u64(data[16:], store.high_water); message_put_u64(data[24:], u64(store.purge_floor_ns))
	message_put_u64(data[32:], store.total_bytes); message_put_u32(data[40:], u32(len(store.segments)))
	message_put_u32(data[44:], u32(frozen_count))
	message_put_u64(data[48:], u64(store.retention))
	cursor := MESSAGE_MANIFEST_HEADER_SIZE
	for i in 0 ..< len(store.segments) + frozen_count {
		segment := i < len(store.segments) ? store.segments[i] : frozen_message_descriptor(store.frozen)
		message_put_u64(data[cursor:], segment.generation); message_put_u64(data[cursor + 8:], segment.first_seq)
		message_put_u64(data[cursor + 16:], segment.last_seq); message_put_u64(data[cursor + 24:], u64(segment.min_time))
		message_put_u64(data[cursor + 32:], u64(segment.max_time)); message_put_u64(data[cursor + 40:], segment.bytes)
		cursor += MESSAGE_MANIFEST_SEGMENT_SIZE
	}
	message_put_u64(data[56:], xxhash.XXH64(data))
	tmp_path := fmt.aprintf("%s/manifest.tmp", store.directory); defer delete(tmp_path)
	path := message_store_manifest_path(store.directory); defer delete(path); _ = storage_io.remove(store.storage, tmp_path)
	file, err := storage_io.open(store.storage, tmp_path, {.Write, .Create, .Excl}, os.perm(0o644)); if err != nil do return false
	written := 0
	for written < len(data) {
		n, write_err := storage_io.write(file, data[written:])
		if write_err != nil || n <= 0 do break
		written += n
	}
	synced := written == len(data) && storage_io.sync(file) == nil
	closed := storage_io.close(file) == nil
	if !synced || !closed {_ = storage_io.remove(store.storage, tmp_path); return false}
	if storage_io.rename(store.storage, tmp_path, path) != nil do return false
	return storage_io.sync_directory(store.storage, store.directory) == nil
}

load_message_manifest :: proc(store: ^Message_Store) -> (found, ok: bool) {
	path := message_store_manifest_path(store.directory); defer delete(path)
	exists, exists_err := storage_io.exists(store.storage, path)
	if exists_err != nil do return false, false
	if !exists do return false, true
	data, err := storage_io.read_entire_file(store.storage, path, context.allocator)
	defer delete(data)
	if err != nil || len(data) < MESSAGE_MANIFEST_HEADER_SIZE do return true, false
	version := message_get_u16(data[4:])
	if message_get_u32(data) != MESSAGE_MANIFEST_MAGIC || (version != 2 && version != MESSAGE_MANIFEST_VERSION) || int(message_get_u16(data[6:])) != store.shard do return true, false
	checksum := message_get_u64(data[56:]); message_put_u64(data[56:], 0); if checksum != xxhash.XXH64(data) do return true, false
	frozen_count := version == 3 ? int(message_get_u32(data[44:])) : 0
	count := int(
		message_get_u32(data[40:]),
	); if count > MESSAGE_MAX_SEGMENTS || frozen_count > 1 || len(data) != MESSAGE_MANIFEST_HEADER_SIZE + (count + frozen_count) * MESSAGE_MANIFEST_SEGMENT_SIZE do return true, false
	store.active_generation = message_get_u64(data[8:]); store.high_water = message_get_u64(data[16:])
	store.purge_floor_ns = i64(message_get_u64(data[24:])); store.total_bytes = message_get_u64(data[32:])
	store.previous_retention = time.Duration(message_get_u64(data[48:]))
	cursor := MESSAGE_MANIFEST_HEADER_SIZE; previous_generation, previous_sequence: u64
	for i in 0 ..< count + frozen_count {
		segment := Message_Segment_Descriptor {
			generation = message_get_u64(data[cursor:]),
			first_seq  = message_get_u64(data[cursor + 8:]),
			last_seq   = message_get_u64(data[cursor + 16:]),
			min_time   = i64(message_get_u64(data[cursor + 24:])),
			max_time   = i64(message_get_u64(data[cursor + 32:])),
			bytes      = message_get_u64(data[cursor + 40:]),
		}
		if segment.generation <= previous_generation || segment.first_seq == 0 || segment.first_seq > segment.last_seq || segment.first_seq <= previous_sequence || segment.min_time > segment.max_time do return true, false
		if i == count {
			if segment.generation > max(u64) - 2 || store.active_generation != segment.generation + 2 || segment.last_seq > store.high_water do return true, false
			store.frozen = new(Message_Store)
			store.frozen^ = {
				active_generation = segment.generation,
				active_first_seq  = segment.first_seq,
				high_water        = segment.last_seq,
				active_min_time   = segment.min_time,
				active_max_time   = segment.max_time,
				active_bytes      = segment.bytes,
			}
		} else {
			if _, append_err := append(&store.segments, segment); append_err != nil do return true, false
		}
		previous_generation, previous_sequence = segment.generation, segment.last_seq; cursor += MESSAGE_MANIFEST_SEGMENT_SIZE
	}
	return true, true
}

mark_message_store_disabled :: proc(shard_dir: string, shard: int, now_ns: i64) -> bool {
	return mark_message_store_disabled_with_storage(storage_io.host_context(), shard_dir, shard, now_ns)
}

mark_message_store_disabled_with_storage :: proc(storage: storage_io.Context, shard_dir: string, shard: int, now_ns: i64) -> bool {
	directory := fmt.aprintf("%s/messages", shard_dir); defer delete(directory)
	manifest_path := message_store_manifest_path(directory); defer delete(manifest_path)
	exists, exists_err := storage_io.exists(storage, manifest_path)
	if exists_err != nil do return false
	if !exists do return true
	store := Message_Store {
		shard     = shard,
		directory = directory,
		storage   = storage,
	}
	found, ok := load_message_manifest(&store)
	defer destroy_frozen_message_store(&store, false)
	if !found || !ok {delete(store.segments); return false}
	store.retention = 0; store.previous_retention = 0; store.purge_floor_ns = max(store.purge_floor_ns, now_ns)
	written := write_message_manifest(&store); delete(store.segments)
	return written
}

create_empty_message_wal :: proc(path: string) -> bool {
	return create_empty_message_wal_with_storage(storage_io.host_context(), path)
}

create_empty_message_wal_with_storage :: proc(storage: storage_io.Context, path: string) -> bool {
	builder: persistence.WAL_File_Builder
	return(
		persistence.create_wal_file_builder_with_storage(&builder, storage, path, MESSAGE_WAL_MAGIC, MESSAGE_WAL_VERSION) &&
		persistence.finish_wal_file_builder(&builder) \
	)
}

init_active_message_indexes :: proc(store: ^Message_Store, dedup_capacity := 256, conversation_capacity := 32) -> bool {
	if store == nil do return false
	if !store.active_arena_ready {
		if store.active_index_arena == nil do store.active_index_arena = new(virtual.Arena)
		if virtual.arena_init_growing(store.active_index_arena, MESSAGE_ACTIVE_ARENA_BLOCK_BYTES) != nil do return false
		store.active_arena_ready = true
	}
	allocator := virtual.arena_allocator(store.active_index_arena)
	dedup, dedup_err := make(map[string]Message_Dedup_Value, max(dedup_capacity, 1), allocator = allocator)
	if dedup_err != nil do return false
	offsets, offsets_err := make(map[Message_Conversation_Key][dynamic]Message_Offset_Entry, max(conversation_capacity, 1), allocator = allocator)
	if offsets_err != nil do return false
	store.active_dedup = dedup
	store.active_offsets = offsets
	return true
}

reset_active_message_indexes :: proc(store: ^Message_Store) -> bool {
	if store == nil || !store.active_arena_ready || store.async_readers != 0 do return false
	dedup_capacity := clamp(len(store.active_dedup), 256, 1_000_000)
	conversation_capacity := clamp(len(store.active_offsets), 32, 65_536)
	store.active_dedup = nil
	store.active_offsets = nil
	virtual.arena_free_all(store.active_index_arena)
	release_active_message_cache(store, false)
	return init_active_message_indexes(store, dedup_capacity, conversation_capacity)
}

destroy_active_message_indexes :: proc(store: ^Message_Store) {
	if store == nil do return
	store.active_dedup = nil
	store.active_offsets = nil
	if store.active_arena_ready do virtual.arena_destroy(store.active_index_arena)
	free(store.active_index_arena)
	store.active_index_arena = nil
	store.active_arena_ready = false
	release_active_message_cache(store, true)
}

init_message_store :: proc(
	store: ^Message_Store,
	shard_dir: string,
	shard: int,
	retention: time.Duration,
	quota: u64,
	dedup_window := DEFAULT_MESSAGE_DEDUP_WINDOW,
	active_cache_budget: ^Message_Active_Cache_Budget = nil,
	sealed_index_cache: ^Message_Sealed_Index_Cache_Budget = nil,
	sealed_wal_cache: ^Message_Sealed_WAL_Cache = nil,
) -> bool {
	return init_message_store_with_storage(
		store,
		storage_io.host_context(),
		shard_dir,
		shard,
		retention,
		quota,
		dedup_window,
		active_cache_budget,
		sealed_index_cache,
		sealed_wal_cache,
	)
}

init_message_store_with_storage :: proc(
	store: ^Message_Store,
	storage: storage_io.Context,
	shard_dir: string,
	shard: int,
	retention: time.Duration,
	quota: u64,
	dedup_window := DEFAULT_MESSAGE_DEDUP_WINDOW,
	active_cache_budget: ^Message_Active_Cache_Budget = nil,
	sealed_index_cache: ^Message_Sealed_Index_Cache_Budget = nil,
	sealed_wal_cache: ^Message_Sealed_WAL_Cache = nil,
) -> bool {
	if store == nil || retention <= 0 || dedup_window <= 0 || dedup_window > retention do return false
	if store.enabled || store.directory != "" || store.wal.file != nil || len(store.segments) != 0 do return false
	directory := fmt.aprintf("%s/messages", shard_dir)
	directory_exists, exists_err := storage_io.exists(storage, directory)
	if exists_err != nil {delete(directory); return false}
	if !directory_exists {
		if storage_io.make_directory(storage, directory) != nil {delete(directory); return false}
	}
	if storage_io.sync_directory(storage, shard_dir) != nil {delete(directory); return false}
	store^ = {
		shard               = shard,
		retention           = retention,
		dedup_window        = dedup_window,
		quota_bytes         = quota,
		directory           = directory,
		storage             = storage,
		active_cache_budget = active_cache_budget,
		sealed_index_cache  = sealed_index_cache,
		sealed_wal_cache    = sealed_wal_cache,
	}
	initialized := false
	defer if !initialized {
		if store.wal.file != nil || store.wal.path != "" do _ = persistence.shutdown_wal(&store.wal)
		destroy_frozen_message_store(store, false)
		destroy_active_message_indexes(store)
		destroy_message_segment_metadata(store, store.segments[:])
		delete(store.segments)
		delete(store.pending_appends)
		delete(store.pending_dedup)
		delete(store.deferred_appends)
		delete(store.deferred_dedup)
		delete(store.directory)
		store^ = {}
	}
	found, manifest_ok := load_message_manifest(store); if !manifest_ok do return false
	now := nrc_time_unix_nanos()
	if !found {
		store.active_generation = 1; store.purge_floor_ns = now; store.previous_retention = retention
		if !write_message_manifest(store) do return false
	} else {
		if store.previous_retention == 0 do store.purge_floor_ns = max(store.purge_floor_ns, now)
		if retention > store.previous_retention && store.previous_retention > 0 do store.purge_floor_ns = max(store.purge_floor_ns, now - i64(store.previous_retention))
		store.previous_retention = retention
	}
	if !recover_frozen_message_seal(store) do return false
	dedup_cutoff := message_store_dedup_cutoff(store, now)
	for &segment in store.segments {
		wal_path := message_store_path(directory, segment.generation, "wal")
		message_scan_context = {
			mode = .Validate,
		}
		inspection := persistence.inspect_wal_file_strict_with_storage(
			storage,
			wal_path,
			MESSAGE_WAL_MAGIC,
			shard,
			message_scan_record,
		); message_scan_context = {}; delete(wal_path)
		if !inspection.ok || inspection.file_size != segment.bytes do return false
		data := read_validated_message_segment_index(store, segment)
		if data == nil {
			if !build_message_segment_index(store, segment.generation) do return false
			data = read_validated_message_segment_index(store, segment)
			if data == nil do return false
		}
		defer delete(data)
		if !load_message_segment_index_metadata(store, &segment, segment.max_time >= dedup_cutoff, data) do return false
	}
	active_path := message_store_path(directory, store.active_generation, "wal"); defer delete(active_path)
	active_exists, active_exists_err := storage_io.exists(storage, active_path)
	if active_exists_err != nil do return false
	if !active_exists && !create_empty_message_wal_with_storage(storage, active_path) do return false
	if !persistence.init_wal_with_storage(&store.wal, storage, active_path, MESSAGE_WAL_MAGIC, MESSAGE_WAL_VERSION, shard, nrc_wal_time_now) do return false
	manifest_high := store.high_water
	store.high_water = len(store.segments) > 0 ? store.segments[len(store.segments) - 1].last_seq : 0
	message_scan_context = {
		store = store,
		mode  = .Recover_Active,
	}
	inspection := persistence.inspect_wal_file_with_tail_recovery_with_storage(storage, active_path, MESSAGE_WAL_MAGIC, shard, message_scan_record)
	message_scan_context = {}
	if !inspection.ok {persistence.shutdown_wal(&store.wal); return false}
	if store.high_water < manifest_high do store.high_water = manifest_high
	// A process-only restart can recover complete records still in the OS
	// cache. Make them durable before duplicate ACKs may trust recovered counts.
	if storage_io.sync(store.wal.file) != nil {persistence.shutdown_wal(&store.wal); return false}
	persistence.set_recovered_wal_state(&store.wal, inspection.last_hash, inspection.record_count)
	store.active_bytes = inspection.file_size
	store.total_bytes = inspection.file_size; for segment in store.segments do store.total_bytes += segment.bytes
	store.active_started_hour = inspection.record_count > 0 ? store.active_max_time / i64(time.Hour) : now / i64(time.Hour); store.enabled = true
	written := write_message_manifest(store)
	if !written {
		_ = persistence.shutdown_wal(&store.wal)
	}
	initialized = written
	return written
}

rotate_message_store :: proc(store: ^Message_Store, now_ns: i64) -> bool {
	if !message_store_enabled(store) do return false
	if store.frozen != nil do return false
	if store.async_readers != 0 || store.fsync_in_flight || len(store.pending_appends) != 0 || store.write_batch_pending || store.wal.write_offset != 0 do return false
	if store.wal.record_count == 0 do return true
	if store.active_read_file != nil {
		storage_io.discard(store.active_read_file)
		store.active_read_file = nil
	}
	if !persistence.shutdown_wal(&store.wal) {store.poisoned = true; return false}
	source_generation := store.active_generation
	if source_generation > max(u64) - 2 {store.poisoned = true; return false}
	sealed_generation := source_generation + 1
	sealed_bytes, clustered := cluster_message_segment_wal(store, source_generation, sealed_generation)
	if !clustered {store.poisoned = true; return false}
	return publish_message_seal(store, now_ns, sealed_bytes)
}

// Owner-only publication. The source remains authoritative until the manifest
// is durable, and readers must release all offsets into the old active indexes.
publish_message_seal :: proc(store: ^Message_Store, now_ns: i64, sealed_bytes: u64) -> bool {
	if !message_store_enabled(store) do return false
	assert(store.async_readers == 0)
	if store.active_read_file != nil {
		storage_io.discard(store.active_read_file)
		store.active_read_file = nil
	}
	if store.wal.file != nil && !persistence.shutdown_wal(&store.wal) {store.poisoned = true; return false}
	source_generation := store.active_generation
	sealed_generation := source_generation + 1
	descriptor := Message_Segment_Descriptor {
		generation = sealed_generation,
		first_seq  = store.active_first_seq,
		last_seq   = store.high_water,
		min_time   = store.active_min_time,
		max_time   = store.active_max_time,
		bytes      = sealed_bytes,
	}
	data := read_validated_message_segment_index(store, descriptor)
	defer delete(data)
	if data == nil || !load_message_segment_index_metadata(store, &descriptor, true, data) {store.poisoned = true; return false}
	if _, err := append(&store.segments, descriptor); err != nil {
		release_message_segment_index_cache(store, &descriptor)
		delete(descriptor.dedup_filter)
		delete(descriptor.conversation_ranges)
		store.poisoned = true
		return false
	}
	store.active_generation = sealed_generation + 1
	new_path := message_store_path(store.directory, store.active_generation, "wal"); defer delete(new_path)
	// A crash before manifest publication leaves the original active WAL authoritative.
	_ = storage_io.remove(store.storage, new_path)
	if !create_empty_message_wal_with_storage(store.storage, new_path) {store.poisoned = true; return false}
	if !write_message_manifest(store) {store.poisoned = true; return false}
	if !persistence.init_wal_with_storage(
		&store.wal,
		store.storage,
		new_path,
		MESSAGE_WAL_MAGIC,
		MESSAGE_WAL_VERSION,
		store.shard,
		nrc_wal_time_now,
	) {store.poisoned = true; return false}
	old_path := message_store_path(store.directory, source_generation, "wal")
	old_index_path := message_store_path(store.directory, source_generation, "idx")
	_ = storage_io.remove(store.storage, old_path)
	_ = storage_io.remove(store.storage, old_index_path)
	delete(old_path)
	delete(old_index_path)
	_ = storage_io.sync_directory(store.storage, store.directory)
	if !reset_active_message_indexes(store) {store.poisoned = true; return false}
	store.active_first_seq = 0; store.active_min_time = 0; store.active_max_time = 0; store.active_bytes = 0
	store.active_started_hour = now_ns / i64(time.Hour)
	store.commit_pending = false
	resume_durable_outboxes(&store.durability_waiters)
	return true
}

message_store_active_dedup :: proc(
	store: ^Message_Store,
	message: ^Retained_Message,
	key: string,
) -> (
	result: Message_Store_Result,
	sequence: u64,
	found: bool,
) {
	existing, present := store.active_dedup[key]
	if !present && store.frozen != nil && !store.frozen_published do existing, present = store.frozen.active_dedup[key]
	if present {
		cutoff := message_store_dedup_cutoff(store, message.accepted_at_ns)
		if existing.accepted_at_ns < cutoff do return .Invalid, 0, false
		if existing.fingerprint != message.fingerprint do return .Conflict, 0, true
		message.accepted_at_ns = existing.accepted_at_ns
		return .Duplicate, existing.sequence, true
	}
	return .Invalid, 0, false
}

message_store_dedup_cutoff :: proc(store: ^Message_Store, now_ns: i64 = 0) -> i64 {
	if store == nil do return 0
	now := now_ns; if now == 0 do now = nrc_time_unix_nanos()
	return max(store.purge_floor_ns, now - i64(store.dedup_window))
}

message_store_next_dedup_segment :: proc(store: ^Message_Store, start: int, cutoff_ns: i64, message: ^Retained_Message = nil) -> int {
	if store == nil do return -1
	i := min(start, len(store.segments) - 1)
	for i >= 0 {
		segment := &store.segments[i]
		if segment.max_time >= cutoff_ns &&
		   (message == nil ||
				   message_dedup_filter_maybe_contains(segment.dedup_filter, message.workspace, message.sender_principal, message.client_message_id)) {
			return i
		}
		i -= 1
	}
	return -1
}

publish_staged_message :: proc(store: ^Message_Store, message: ^Retained_Message, dedup_key: string, offset: u64, length: u32, payload: []byte) -> bool {
	if store == nil || message == nil || len(dedup_key) == 0 do return false
	_, key_present := store.active_dedup[dedup_key]
	stored_key := dedup_key
	if !key_present {
		owned_key, clone_err := strings.clone(dedup_key, virtual.arena_allocator(store.active_index_arena))
		if clone_err != nil do return false
		stored_key = owned_key
	}
	store.active_dedup[stored_key] = {
		fingerprint    = message.fingerprint,
		sequence       = message.sequence,
		accepted_at_ns = message.accepted_at_ns,
		offset         = offset,
		length         = length,
	}
	cached_payload := cache_active_message_payload(store, payload)
	if !append_active_message_offset(
		store,
		message.workspace,
		message.conversation_id,
		Message_Offset_Entry{message.accepted_at_ns, offset, length, message.sequence, cached_payload},
	) {
		return false
	}
	record_bytes := u64(length)
	store.high_water = message.sequence
	store.active_bytes += record_bytes
	store.total_bytes += record_bytes
	if store.active_first_seq == 0 do store.active_first_seq = message.sequence
	if store.active_min_time == 0 || message.accepted_at_ns < store.active_min_time do store.active_min_time = message.accepted_at_ns
	if message.accepted_at_ns > store.active_max_time do store.active_max_time = message.accepted_at_ns
	return true
}

append_new_message :: proc(store: ^Message_Store, message: ^Retained_Message, dedup_key: string) -> (Message_Store_Result, u64) {
	defer delete(dedup_key)
	if store.rotation_pending do return .Capacity, 0
	if len(store.pending_appends) != 0 || len(store.deferred_appends) != 0 || store.write_batch_pending || store.wal.write_offset != 0 do return .Poisoned, 0
	size, valid := message_record_size(message)
	if !valid || int(shard_for_workspace(transmute([]byte)message.workspace)) != store.shard do return .Invalid, 0
	record_bytes := u64(persistence.LOG_HEADER_SIZE + size)
	if store.quota_bytes > 0 && store.total_bytes + record_bytes > store.quota_bytes do return .Capacity, 0
	now_hour := message.accepted_at_ns / i64(time.Hour)
	requires_rotation :=
		store.wal.record_count + 1 > MESSAGE_MAX_INDEX_RECORDS ||
		store.wal.record_count > 0 &&
			(store.active_bytes + record_bytes >= MESSAGE_SEGMENT_BYTES ||
					now_hour != store.active_started_hour ||
					store.active_index_arena.total_used >= MESSAGE_ACTIVE_INDEX_BUDGET)
	if requires_rotation {
		if store.frozen != nil || store.async_readers != 0 do return .Capacity, 0
		if !rotate_message_store(store, message.accepted_at_ns) do return .Poisoned, 0
	}
	if !store.active_arena_ready && !init_active_message_indexes(store) {store.poisoned = true; return .Poisoned, 0}
	message.sequence = store.high_water + 1
	record := make([]byte, persistence.LOG_HEADER_SIZE + size, context.allocator)
	defer delete(record)
	if !encode_message_record(message, record[persistence.LOG_HEADER_SIZE:]) do return .Invalid, 0
	offset := store.active_bytes
	if !persistence.finalize_and_write_record(&store.wal, 1, record) || !persistence.flush_write_batch(&store.wal) {store.poisoned = true; return .Poisoned, 0}
	_, key_present := store.active_dedup[dedup_key]
	stored_key := dedup_key
	if !key_present {
		owned_key, clone_err := strings.clone(dedup_key, virtual.arena_allocator(store.active_index_arena))
		if clone_err != nil {store.poisoned = true; return .Poisoned, 0}
		stored_key = owned_key
	}
	store.active_dedup[stored_key] = {
		fingerprint    = message.fingerprint,
		sequence       = message.sequence,
		accepted_at_ns = message.accepted_at_ns,
		offset         = offset,
		length         = u32(record_bytes),
	}
	cached_payload := cache_active_message_payload(store, record[persistence.LOG_HEADER_SIZE:])
	offsets_ok := append_active_message_offset(
		store,
		message.workspace,
		message.conversation_id,
		Message_Offset_Entry{message.accepted_at_ns, offset, u32(record_bytes), message.sequence, cached_payload},
	)
	if !offsets_ok {store.poisoned = true; return .Poisoned, 0}
	store.high_water = message.sequence; store.active_bytes += record_bytes; store.total_bytes += record_bytes
	if store.active_first_seq == 0 do store.active_first_seq = message.sequence
	if store.active_min_time == 0 || message.accepted_at_ns < store.active_min_time do store.active_min_time = message.accepted_at_ns
	if message.accepted_at_ns > store.active_max_time do store.active_max_time = message.accepted_at_ns
	return .Appended, message.sequence
}

append_or_deduplicate_message :: proc(store: ^Message_Store, message: ^Retained_Message) -> (Message_Store_Result, u64) {
	if store == nil || !store.enabled do return .Disabled, 0
	if store.poisoned do return .Poisoned, 0
	message.fingerprint = message_fingerprint(message); if message.fingerprint == 0 do return .Invalid, 0
	key := message_dedup_key(message.workspace, message.sender_principal, message.client_message_id)
	if result, sequence, found := message_store_active_dedup(store, message, key); found {delete(key); return result, sequence}
	if message_store_next_dedup_segment(store, len(store.segments) - 1, message_store_dedup_cutoff(store, message.accepted_at_ns), message) >=
	   0 {delete(key); return .Lookup_Required, 0}
	return append_new_message(store, message, key)
}

append_message_after_sealed_lookup :: proc(store: ^Message_Store, message: ^Retained_Message) -> (Message_Store_Result, u64) {
	if !message_store_enabled(store) do return .Poisoned, 0
	key := message_dedup_key(message.workspace, message.sender_principal, message.client_message_id)
	if result, sequence, found := message_store_active_dedup(store, message, key); found {delete(key); return result, sequence}
	return append_new_message(store, message, key)
}

message_store_high_water_cutoff :: proc(store: ^Message_Store, now_ns: i64 = 0) -> (u64, i64, bool) {
	if !message_store_enabled(store) do return 0, 0, false
	now := now_ns; if now == 0 do now = nrc_time_unix_nanos()
	return store.high_water, max(store.purge_floor_ns, now - i64(store.retention)), true
}

maintain_message_store :: proc(store: ^Message_Store, now_ns: i64 = 0, sync_wal := true) -> bool {
	if !message_store_enabled(store) do return true
	if store.frozen != nil do return true
	if store.write_batch_pending || store.rotation_pending || len(store.pending_appends) != 0 || len(store.deferred_appends) != 0 || store.wal.write_offset != 0 do return true
	if sync_wal && !persistence.maybe_fsync(&store.wal) {store.poisoned = true; return false}
	now := now_ns; if now == 0 do now = nrc_time_unix_nanos()
	cutoff := max(store.purge_floor_ns, now - i64(store.retention)); store.purge_floor_ns = cutoff
	dedup_cutoff := message_store_dedup_cutoff(store, now)
	for &segment in store.segments {
		if segment.max_time < dedup_cutoff && len(segment.dedup_filter) > 0 {delete(segment.dedup_filter); segment.dedup_filter = nil}
	}
	remove_count := 0
	for segment in store.segments {if segment.max_time >= cutoff do break; remove_count += 1}
	if remove_count == 0 do return true
	if store.async_readers > 0 do return true
	removed := make([]Message_Segment_Descriptor, remove_count, context.allocator)
	defer delete(removed)
	copy(removed, store.segments[:remove_count])
	for segment in removed do store.total_bytes -= min(store.total_bytes, segment.bytes)
	copy(store.segments[:], store.segments[remove_count:]); resize(&store.segments, len(store.segments) - remove_count)
	if !write_message_manifest(store) {
		destroy_message_segment_metadata(store, removed)
		store.poisoned = true
		return false
	}
	for segment in removed {
		wal_path := message_store_path(
			store.directory,
			segment.generation,
			"wal",
		); index_path := message_store_path(store.directory, segment.generation, "idx")
		_ = storage_io.remove(store.storage, wal_path); _ = storage_io.remove(store.storage, index_path); delete(wal_path); delete(index_path)
	}
	destroy_message_segment_metadata(store, removed)
	return true
}

shutdown_message_store :: proc(store: ^Message_Store) -> bool {
	if store == nil do return true
	assert(store.async_readers == 0, "message store shutdown requires drained async readers")
	assert(!store.fsync_in_flight, "message store shutdown requires drained async fsync")
	assert(
		!store.write_batch_pending &&
		!store.rotation_pending &&
		len(store.pending_appends) == 0 &&
		len(store.deferred_appends) == 0 &&
		store.wal.write_offset == 0,
		"message store shutdown requires a flushed write batch",
	)
	ok := true
	if store.active_read_file != nil {
		storage_io.discard(store.active_read_file)
		store.active_read_file = nil
	}
	if store.enabled {
		ok = persistence.shutdown_wal(&store.wal)
		// A failed publication may have changed the in-memory descriptor. Never
		// replace the last authoritative manifest during fatal shutdown.
		if !store.poisoned do ok = ok && write_message_manifest(store)
	}
	delete(store.durability_waiters)
	destroy_frozen_message_store(store, false)
	destroy_active_message_indexes(
		store,
	); destroy_message_segment_metadata(store, store.segments[:]); delete(store.segments); delete(store.pending_appends); delete(store.pending_dedup); delete(store.deferred_appends); delete(store.deferred_dedup); delete(store.directory); store^ = {}
	return ok
}
