package main

// Retained messages are deliberately independent of the wire protocol. The
// owning worker serializes mutation, while async_readers pins segment snapshots
// across io_uring reads so rotation and deletion cannot invalidate them.

import "core:encoding/endian"
import "core:fmt"
import "core:hash/xxhash"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "persistence"
import "storage_io"

MESSAGE_WAL_MAGIC :: u32(0x4e52434d) // NRCM
MESSAGE_WAL_VERSION :: u16(1)
MESSAGE_SEGMENT_BYTES :: u64(#config(NRC_MESSAGE_SEGMENT_BYTES, 256 * 1024 * 1024))
MESSAGE_ACTIVE_INDEX_BUDGET :: 64 * 1024 * 1024
MESSAGE_ACTIVE_ARENA_BLOCK_BYTES :: 256 * 1024
MESSAGE_ACTIVE_RECORD_ARENA_BLOCK_BYTES :: 64 * 1024
DEFAULT_MESSAGE_ACTIVE_CACHE_BYTES :: u64(256 * 1024 * 1024)
DEFAULT_MESSAGE_SEALED_INDEX_CACHE_BYTES :: u64(128 * 1024 * 1024)
DEFAULT_MESSAGE_WRITE_BATCH_RECORDS :: 16
MAX_MESSAGE_WRITE_BATCH_RECORDS :: 1024
MESSAGE_MANIFEST_MAGIC :: u32(0x4d534731)
MESSAGE_MANIFEST_VERSION :: u16(3)
MESSAGE_MAX_SEGMENTS :: 4096
MESSAGE_INDEX_MAGIC :: u32(0x4e524349) // NRCI
MESSAGE_INDEX_VERSION :: u16(1)
MESSAGE_INDEX_HEADER_SIZE :: 80
MESSAGE_INDEX_ENTRY_SIZE :: 48
MESSAGE_DEDUP_ENTRY_SIZE :: 72
DEFAULT_MESSAGE_DEDUP_WINDOW :: 2 * time.Minute
MESSAGE_DEDUP_FILTER_BITS_PER_ENTRY :: 10
MESSAGE_DEDUP_FILTER_HASH_COUNT :: 7

Message_Store_Result :: enum u8 {
	Appended,
	Duplicate,
	Conflict,
	Lookup_Required,
	Disabled,
	Capacity,
	Poisoned,
	Invalid,
}

Retained_Message :: struct {
	workspace:         string,
	conversation_id:   u64,
	sequence:          u64,
	client_message_id: [16]byte,
	sender_name:       string,
	sender_principal:  string,
	accepted_at_ns:    i64,
	content_type:      u8,
	content:           []byte,
	fingerprint:       u64,
}

Message_History_Page :: struct {
	messages:   [dynamic]Retained_Message,
	high_water: u64,
	cutoff_ns:  i64,
}

Message_Conversation_Range :: struct {
	workspace_hash:  u64,
	conversation_id: u64,
	start:           u64,
	end:             u64,
}

Message_Segment_Descriptor :: struct {
	generation:           u64,
	first_seq:            u64,
	last_seq:             u64,
	min_time:             i64,
	max_time:             i64,
	bytes:                u64,
	dedup_filter:         []u64,
	conversation_ranges:  [dynamic]Message_Conversation_Range,
	cached_message_index: []byte,
	read_file:            ^storage_io.File,
	readers:              int,
}

Message_Offset_Entry :: struct {
	accepted_at_ns: i64,
	offset:         u64,
	length:         u32,
	sequence:       u64,
	cached_payload: []byte,
}

Message_Active_Cache_Budget :: struct {
	limit_bytes: u64,
	used_bytes:  u64,
}

Message_Sealed_Index_Cache_Entry :: struct {
	store:      ^Message_Store,
	generation: u64,
}

Message_Sealed_Index_Cache_Budget :: struct {
	limit_bytes: u64,
	used_bytes:  u64,
	entries:     [dynamic]Message_Sealed_Index_Cache_Entry,
}

MESSAGE_SEALED_WAL_CACHE_LIMIT :: 64

Message_Sealed_WAL_Cache_Entry :: struct {
	store:      ^Message_Store,
	generation: u64,
}

Message_Sealed_WAL_Cache :: struct {
	limit:   int,
	entries: [dynamic]Message_Sealed_WAL_Cache_Entry,
}

Message_Conversation_Key :: struct {
	workspace:       string,
	conversation_id: u64,
}

Message_Dedup_Value :: struct {
	fingerprint:    u64,
	sequence:       u64,
	accepted_at_ns: i64,
	offset:         u64,
	length:         u32,
}

Message_Read_Request :: struct {
	path:            string,
	offset:          u64,
	length:          u32,
	sequence:        u64,
	workspace:       string,
	conversation_id: u64,
}

Message_History_Plan :: struct {
	reads:      [dynamic]Message_Read_Request,
	high_water: u64,
	cutoff_ns:  i64,
}

Message_Store :: struct {
	enabled:             bool,
	poisoned:            bool,
	shard:               int,
	retention:           time.Duration,
	dedup_window:        time.Duration,
	previous_retention:  time.Duration,
	quota_bytes:         u64,
	directory:           string,
	storage:             storage_io.Context,
	wal:                 persistence.WAL_State,
	active_generation:   u64,
	active_started_hour: i64,
	active_first_seq:    u64,
	active_min_time:     i64,
	active_max_time:     i64,
	active_bytes:        u64,
	active_read_file:    ^storage_io.File,
	async_readers:       u32,
	high_water:          u64,
	purge_floor_ns:      i64,
	total_bytes:         u64,
	// Heap-stable arena controls: map allocators retain these pointers when a
	// generation's indexes transfer to the frozen holder.
	active_index_arena:  ^virtual.Arena,
	active_arena_ready:  bool,
	active_record_arena: ^virtual.Arena,
	active_record_ready: bool,
	active_cached_bytes: u64,
	active_cache_budget: ^Message_Active_Cache_Budget,
	sealed_index_cache:  ^Message_Sealed_Index_Cache_Budget,
	sealed_wal_cache:    ^Message_Sealed_WAL_Cache,
	active_dedup:        map[string]Message_Dedup_Value,
	active_offsets:      map[Message_Conversation_Key][dynamic]Message_Offset_Entry,
	segments:            [dynamic]Message_Segment_Descriptor,
	pending_appends:     [dynamic]Message_Pending_Append,
	pending_dedup:       map[string]int,
	deferred_appends:    [dynamic]Message_Deferred_Append,
	deferred_head:       int,
	deferred_dedup:      map[string]int,
	write_batch_pending: bool,
	rotation_pending:    bool,
	frozen:              ^Message_Store,
	frozen_published:    bool,
	seal_in_flight:      bool,
	seal_ready:          bool,
	seal_bytes:          u64,
	fsync_in_flight:     bool,
	fsync_snapshot:      persistence.WAL_Fsync_Snapshot,
	fsync_started:       time.Time,
	commit_pending:      bool,
	commit_started:      time.Time,
	durability_waiters:  [dynamic]Connection_Handle,
}

Message_Pending_Append :: struct {
	ctx:          rawptr,
	dedup_key:    string,
	offset:       u64,
	length:       u32,
	sequence:     u64,
	batch_offset: int,
	duplicate:    bool,
}

Message_Deferred_Append :: struct {
	ctx:       rawptr,
	dedup_key: string,
}

Message_Store_Registry :: struct {
	enabled:             bool,
	worker:              int,
	worker_count:        int,
	retention:           time.Duration,
	dedup_window:        time.Duration,
	quota_bytes:         u64,
	write_batch_records: int,
	active_cache:        Message_Active_Cache_Budget,
	sealed_index_cache:  Message_Sealed_Index_Cache_Budget,
	sealed_wal_cache:    Message_Sealed_WAL_Cache,
	stores:              [dynamic]Message_Store,
	store_index:         [LOGICAL_SHARD_COUNT]i16,
	pending_writes:      [LOGICAL_SHARD_COUNT]^Message_Store,
	pending_write_count: int,
}

parse_message_retention :: proc(value: string) -> (time.Duration, bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" || trimmed == "0" do return 0, true
	if len(trimmed) < 2 do return 0, false
	n, ok := strconv.parse_u64(trimmed[:len(trimmed) - 1])
	if !ok || n == 0 do return 0, false
	multiplier: u64
	switch trimmed[len(trimmed) - 1] {
	case 's':
		multiplier = u64(time.Second)
	case 'm':
		multiplier = u64(time.Minute)
	case 'h':
		multiplier = u64(time.Hour)
	case 'd':
		multiplier = u64(24 * time.Hour)
	case:
		return 0, false
	}
	if n > u64(max(i64)) / multiplier do return 0, false
	return time.Duration(n * multiplier), true
}

configured_message_retention :: proc() -> (time.Duration, bool) {
	value := os.get_env_alloc("NRC_MESSAGE_RETENTION", context.allocator)
	defer delete(value)
	return parse_message_retention(value)
}

parse_message_dedup_window :: proc(value: string) -> (time.Duration, bool) {
	if strings.trim_space(value) == "" do return DEFAULT_MESSAGE_DEDUP_WINDOW, true
	window, valid := parse_message_retention(value)
	return window, valid && window > 0
}

configured_message_dedup_window :: proc() -> (time.Duration, bool) {
	value := os.get_env_alloc("NRC_MESSAGE_DEDUP_WINDOW", context.allocator)
	defer delete(value)
	return parse_message_dedup_window(value)
}

configured_message_store_quota :: proc() -> u64 {
	value := os.get_env_alloc("NRC_MESSAGE_STORE_QUOTA_BYTES", context.allocator)
	defer delete(value)
	if value == "" do return 0
	n, ok := strconv.parse_u64(value)
	if !ok do return 0
	return n
}

parse_message_write_batch_records :: proc(value: string) -> (int, bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return DEFAULT_MESSAGE_WRITE_BATCH_RECORDS, true
	n, ok := strconv.parse_u64(trimmed)
	if !ok || n > u64(MAX_MESSAGE_WRITE_BATCH_RECORDS) do return 0, false
	return int(n), true
}

configured_message_write_batch_records :: proc() -> (int, bool) {
	value := os.get_env_alloc("NRC_MESSAGE_WRITE_BATCH_RECORDS", context.allocator)
	defer delete(value)
	return parse_message_write_batch_records(value)
}

parse_message_active_cache_bytes :: proc(value: string) -> (u64, bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return DEFAULT_MESSAGE_ACTIVE_CACHE_BYTES, true
	return strconv.parse_u64(trimmed)
}

configured_message_active_cache_bytes :: proc() -> (u64, bool) {
	value := os.get_env_alloc("NRC_MESSAGE_ACTIVE_CACHE_BYTES", context.allocator)
	defer delete(value)
	return parse_message_active_cache_bytes(value)
}

parse_message_sealed_index_cache_bytes :: proc(value: string) -> (u64, bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" do return DEFAULT_MESSAGE_SEALED_INDEX_CACHE_BYTES, true
	return strconv.parse_u64(trimmed)
}

configured_message_sealed_index_cache_bytes :: proc() -> (u64, bool) {
	value := os.get_env_alloc("NRC_MESSAGE_SEALED_INDEX_CACHE_BYTES", context.allocator)
	defer delete(value)
	return parse_message_sealed_index_cache_bytes(value)
}

message_store_enabled :: proc(store: ^Message_Store) -> bool {
	return store != nil && store.enabled && !store.poisoned
}

message_store_path :: proc(directory: string, generation: u64, suffix: string) -> string {
	return fmt.aprintf("%s/segment-%020d.%s", directory, generation, suffix)
}

message_store_manifest_path :: proc(directory: string) -> string {return fmt.aprintf("%s/manifest", directory)}

message_record_size :: proc(m: ^Retained_Message) -> (int, bool) {
	if m == nil || len(m.workspace) == 0 || len(m.workspace) > int(max(u16)) || len(m.sender_name) > int(max(u16)) || len(m.sender_principal) > int(max(u16)) || len(m.content) > int(max(u32)) do return 0, false
	return 2 + len(m.workspace) + 8 + 8 + 16 + 2 + len(m.sender_name) + 2 + len(m.sender_principal) + 8 + 1 + 4 + len(m.content) + 8, true
}

message_fingerprint :: proc(m: ^Retained_Message) -> u64 {
	_, ok := message_record_size(m)
	if !ok do return 0
	state: xxhash.XXH64_state
	_ = xxhash.XXH64_reset_state(&state, 0)
	length: [2]byte
	endian.put_u16(length[:], .Big, u16(len(m.workspace)))
	_ = xxhash.XXH64_update(&state, length[:])
	_ = xxhash.XXH64_update(&state, transmute([]byte)m.workspace)
	fixed: [34]byte
	endian.put_u64(fixed[:], .Big, m.conversation_id)
	_ = xxhash.XXH64_update(&state, fixed[:])
	endian.put_u16(length[:], .Big, u16(len(m.sender_principal)))
	_ = xxhash.XXH64_update(&state, length[:])
	_ = xxhash.XXH64_update(&state, transmute([]byte)m.sender_principal)
	suffix: [13]byte
	suffix[8] = m.content_type
	endian.put_u32(suffix[9:], .Big, u32(len(m.content)))
	_ = xxhash.XXH64_update(&state, suffix[:])
	_ = xxhash.XXH64_update(&state, m.content)
	return u64(xxhash.XXH64_digest(&state))
}

encode_message_record :: proc(m: ^Retained_Message, out: []byte, include_fingerprint := true) -> bool {
	size, ok := message_record_size(m); if !ok do return false
	needed := size; if !include_fingerprint do needed -= 8
	if len(out) != needed do return false
	o := 0
	endian.put_u16(out[o:], .Big, u16(len(m.workspace))); o += 2; copy(out[o:], m.workspace); o += len(m.workspace)
	endian.put_u64(out[o:], .Big, m.conversation_id); o += 8
	endian.put_u64(out[o:], .Big, m.sequence); o += 8; copy(out[o:], m.client_message_id[:]); o += 16
	endian.put_u16(out[o:], .Big, u16(len(m.sender_name))); o += 2; copy(out[o:], m.sender_name); o += len(m.sender_name)
	endian.put_u16(out[o:], .Big, u16(len(m.sender_principal))); o += 2; copy(out[o:], m.sender_principal); o += len(m.sender_principal)
	endian.put_u64(out[o:], .Big, u64(m.accepted_at_ns)); o += 8; out[o] = m.content_type; o += 1
	endian.put_u32(out[o:], .Big, u32(len(m.content))); o += 4; copy(out[o:], m.content); o += len(m.content)
	if include_fingerprint do endian.put_u64(out[o:], .Big, m.fingerprint)
	return true
}

decode_message_record_borrowed :: proc(payload: []byte) -> (m: Retained_Message, ok: bool) {
	o := 0
	read_string := proc(payload: []byte, offset: ^int) -> (string, bool) {
		if offset^ + 2 > len(payload) do return "", false
		n_raw, _ := endian.get_u16(payload[offset^:], .Big)
		n := int(n_raw); offset^ += 2
		if offset^ + n > len(payload) do return "", false
		s := transmute(string)payload[offset^:offset^ + n]; offset^ += n
		return s, true
	}
	m.workspace, ok = read_string(payload, &o); if !ok do return
	if o + 32 > len(payload) do return m, false
	m.conversation_id, _ = endian.get_u64(payload[o:], .Big); o += 8
	m.sequence, _ = endian.get_u64(payload[o:], .Big); o += 8; copy(m.client_message_id[:], payload[o:o + 16]); o += 16
	m.sender_name, ok = read_string(payload, &o); if !ok do return
	m.sender_principal, ok = read_string(payload, &o); if !ok do return
	if o + 13 > len(payload) do return m, false
	accepted_raw, _ := endian.get_u64(payload[o:], .Big); m.accepted_at_ns = i64(accepted_raw); o += 8; m.content_type = payload[o]; o += 1
	n_raw, _ := endian.get_u32(payload[o:], .Big); n := int(n_raw); o += 4
	if n < 0 || o + n + 8 != len(payload) do return m, false
	m.content = payload[o:o + n]; o += n
	m.fingerprint, _ = endian.get_u64(payload[o:], .Big)
	return m, true
}

decode_message_record :: proc(payload: []byte, allocator := context.allocator) -> (m: Retained_Message, ok: bool) {
	o := 0
	read_string := proc(payload: []byte, offset: ^int, allocator: mem.Allocator) -> (string, bool) {
		if offset^ + 2 > len(payload) do return "", false
		n_raw, _ := endian.get_u16(payload[offset^:], .Big)
		n := int(n_raw); offset^ += 2
		if offset^ + n > len(payload) do return "", false
		s, err := strings.clone(string(payload[offset^:offset^ + n]), allocator); offset^ += n
		return s, err == nil
	}
	m.workspace, ok = read_string(payload, &o, allocator); if !ok do return
	if o + 32 > len(payload) do return m, false
	m.conversation_id, _ = endian.get_u64(payload[o:], .Big); o += 8
	m.sequence, _ = endian.get_u64(payload[o:], .Big); o += 8; copy(m.client_message_id[:], payload[o:o + 16]); o += 16
	m.sender_name, ok = read_string(payload, &o, allocator); if !ok do return
	m.sender_principal, ok = read_string(payload, &o, allocator); if !ok do return
	if o + 13 > len(payload) do return m, false
	accepted_raw, _ := endian.get_u64(payload[o:], .Big); m.accepted_at_ns = i64(accepted_raw); o += 8; m.content_type = payload[o]; o += 1
	n_raw, _ := endian.get_u32(payload[o:], .Big); n := int(n_raw); o += 4
	if n < 0 || o + n + 8 != len(payload) do return m, false
	m.content = make([]byte, n, allocator); copy(m.content, payload[o:o + n]); o += n
	m.fingerprint, _ = endian.get_u64(payload[o:], .Big)
	return m, true
}

destroy_retained_message :: proc(m: ^Retained_Message) {
	if m == nil do return
	delete(m.workspace); delete(m.sender_name); delete(m.sender_principal); delete(m.content); m^ = {}
}

destroy_message_history_page :: proc(page: ^Message_History_Page) {if page == nil do return; for &m in page.messages do destroy_retained_message(&m); delete(
		page.messages,
	)
	page^ = {}}

destroy_message_history_plan :: proc(plan: ^Message_History_Plan) {
	if plan == nil do return
	for &read in plan.reads {
		delete(read.path)
		delete(read.workspace)
	}
	delete(plan.reads)
	plan^ = {}
}
