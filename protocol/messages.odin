package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// SendMessage
// ============================================================================

_SMR_OFFSET_CONV_ID :: 0
_SMR_SIZE_CONV_ID :: size_of(ConversationID)
_SMR_OFFSET_REQ_ID :: _SMR_OFFSET_CONV_ID + _SMR_SIZE_CONV_ID
_SMR_SIZE_REQ_ID :: size_of(u32)
_SMR_OFFSET_TYPE :: _SMR_OFFSET_REQ_ID + _SMR_SIZE_REQ_ID
_SMR_SIZE_TYPE :: size_of(u8)
_SMR_OFFSET_LEN :: _SMR_OFFSET_TYPE + _SMR_SIZE_TYPE
_SMR_SIZE_LEN :: size_of(u16)
_SMR_OFFSET_CONTENT :: _SMR_OFFSET_LEN + _SMR_SIZE_LEN
_SMR_MIN_PAYLOAD_HEADER_SIZE :: _SMR_OFFSET_CONTENT

SendMessageRequest :: struct {
	conv_id:       ConversationID,
	client_req_id: u32,
	content_type:  MessageContentType,
	content:       []byte,
}

parseSendMessageRequest :: proc(data: []byte) -> (SendMessageRequest, ProtocolParseError) {
	result := SendMessageRequest{}

	if len(data) < _SMR_MIN_PAYLOAD_HEADER_SIZE {
		log.debugf("SendMessageRequest payload too short for header. Need %v, got %v", _SMR_MIN_PAYLOAD_HEADER_SIZE, len(data))
		return result, .TooShort
	}

	conv_id, _ := endian.get_u64(data[_SMR_OFFSET_CONV_ID:], .Big)
	client_req_id, _ := endian.get_u32(data[_SMR_OFFSET_REQ_ID:], .Big)
	content_type_byte := data[_SMR_OFFSET_TYPE]
	content_len_u16, _ := endian.get_u16(data[_SMR_OFFSET_LEN:], .Big)

	if content_len_u16 > MAX_ALLOWED_CONTENT_LENGTH {
		log.debugf("Declared content length %v exceeds maximum %v", content_len_u16, MAX_ALLOWED_CONTENT_LENGTH)
		return result, .ContentLengthExceedsMax
	}
	content_len := int(content_len_u16)

	required_total_len := _SMR_OFFSET_CONTENT + content_len
	if len(data) < required_total_len {
		log.debugf(
			"SendMessageRequest data too short for declared content. Have: %v, Need: %v (Header %v + Content %v)",
			len(data),
			required_total_len,
			_SMR_OFFSET_CONTENT,
			content_len,
		)
		return result, .ContentLengthMismatch
	}
	if len(data) != required_total_len {
		return result, .ContentLengthMismatch
	}

	content_slice := data[_SMR_OFFSET_CONTENT:required_total_len]

	result = SendMessageRequest {
		conv_id       = ConversationID(conv_id),
		client_req_id = client_req_id,
		content_type  = MessageContentType(content_type_byte),
		content       = content_slice,
	}

	return result, nil
}

// ============================================================================
// NewMessage
// ============================================================================

_NME_OFFSET_CONV_ID :: 0
_NME_SIZE_CONV_ID :: size_of(ConversationID)
_NME_OFFSET_SEQ :: _NME_OFFSET_CONV_ID + _NME_SIZE_CONV_ID
_NME_SIZE_SEQ :: size_of(MessageSeq)
_NME_OFFSET_USERNAME_LEN :: _NME_OFFSET_SEQ + _NME_SIZE_SEQ
_NME_SIZE_USERNAME_LEN :: size_of(u16)
_NME_OFFSET_USERNAME :: _NME_OFFSET_USERNAME_LEN + _NME_SIZE_USERNAME_LEN
_NME_FIXED_HEADER_SIZE :: _NME_OFFSET_USERNAME

NewMessageEvent :: struct {
	conv_id:         ConversationID,
	seq:             MessageSeq,
	author_username: []byte,
	timestamp:       i64,
	content_type:    MessageContentType,
	content:         []byte,
}

getSizeNewMessageEvent :: proc(msg: NewMessageEvent) -> int {
	// opcode(2) + conv_id(8) + seq(8) + username_len(2) + username + timestamp(8) + content_type(1) + content_len(2) + content
	return 2 + _NME_FIXED_HEADER_SIZE + len(msg.author_username) + 8 + 1 + 2 + len(msg.content)
}

serializeNewMessageEvent :: proc(msg: NewMessageEvent, buf: []byte) -> int {
	content_len := len(msg.content)
	username_len := len(msg.author_username)

	if content_len > MAX_ALLOWED_CONTENT_LENGTH {
		log.errorf("Content length %v exceeds maximum %v", content_len, MAX_ALLOWED_CONTENT_LENGTH)
		return -1
	}

	if username_len > MAX_USERNAME_LENGTH {
		log.errorf("Username length %v exceeds maximum %v", username_len, MAX_USERNAME_LENGTH)
		return -1
	}

	total_size := getSizeNewMessageEvent(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_NewMessage))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, u64(msg.conv_id))
	offset += 8

	endian.put_u64(payload[offset:], .Big, u64(msg.seq))
	offset += 8

	endian.put_u16(payload[offset:], .Big, u16(username_len))
	offset += 2
	if username_len > 0 {
		copy(payload[offset:], msg.author_username)
		offset += username_len
	}

	endian.put_u64(payload[offset:], .Big, cast(u64)msg.timestamp)
	offset += 8

	payload[offset] = u8(msg.content_type)
	offset += 1

	endian.put_u16(payload[offset:], .Big, u16(content_len))
	offset += 2

	if content_len > 0 {
		copy(payload[offset:], msg.content)
	}

	return total_size
}

parseNewMessageEventMessage :: proc(data: []byte) -> (result: NewMessageEvent, err: ProtocolParseError) {
	if len(data) < 2 + _NME_FIXED_HEADER_SIZE do return result, .TooShort
	if get_opcode(data) != .S_NewMessage do return result, .InvalidOpcode

	pos := 2
	conv_id, _ := endian.get_u64(data[pos:], .Big)
	result.conv_id = ConversationID(conv_id)
	pos += 8

	seq, _ := endian.get_u64(data[pos:], .Big)
	result.seq = MessageSeq(seq)
	pos += 8

	username_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2
	if username_len > MAX_USERNAME_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) < pos + int(username_len) + 8 + 1 + 2 do return result, .TooShort
	if username_len > 0 {
		result.author_username = data[pos:pos + int(username_len)]
		pos += int(username_len)
	}

	timestamp_u64, _ := endian.get_u64(data[pos:], .Big)
	result.timestamp = cast(i64)timestamp_u64
	pos += 8

	result.content_type = MessageContentType(data[pos])
	pos += 1

	content_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2
	if content_len > MAX_ALLOWED_CONTENT_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) < pos + int(content_len) do return result, .TooShort
	if content_len > 0 {
		result.content = data[pos:pos + int(content_len)]
		pos += int(content_len)
	}

	if pos != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

// ============================================================================
// AckSendMessage
// ============================================================================

_ASM_OFFSET_REQ_ID :: 0
_ASM_SIZE_REQ_ID :: size_of(u32)
_ASM_OFFSET_SEQ :: _ASM_OFFSET_REQ_ID + _ASM_SIZE_REQ_ID
_ASM_SIZE_SEQ :: size_of(MessageSeq)
_ASM_OFFSET_TIMESTAMP :: _ASM_OFFSET_SEQ + _ASM_SIZE_SEQ
_ASM_SIZE_TIMESTAMP :: size_of(i64)
_ASM_TOTAL_SIZE :: _ASM_OFFSET_TIMESTAMP + _ASM_SIZE_TIMESTAMP

AckSendMessage :: struct {
	client_req_id: u32,
	assigned_seq:  MessageSeq,
	timestamp:     i64,
}

getSizeAckSendMessage :: proc(msg: AckSendMessage) -> int {
	// opcode(2) + client_req_id(4) + assigned_seq(8) + timestamp(8)
	return 2 + _ASM_TOTAL_SIZE
}

serializeAckSendMessage :: proc(ack: AckSendMessage, buf: []byte) -> int {
	total_size := 2 + _ASM_TOTAL_SIZE
	if len(buf) < total_size {
		log.errorf("Buffer too small for AckSendMessage. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AckSendMessage))

	payload := buf[2:]
	endian.put_u32(payload[_ASM_OFFSET_REQ_ID:], .Big, ack.client_req_id)
	endian.put_u64(payload[_ASM_OFFSET_SEQ:], .Big, u64(ack.assigned_seq))
	endian.put_u64(payload[_ASM_OFFSET_TIMESTAMP:], .Big, cast(u64)ack.timestamp)

	return total_size
}

parseAckSendMessageMessage :: proc(data: []byte) -> (result: AckSendMessage, err: ProtocolParseError) {
	if len(data) < 2 + _ASM_TOTAL_SIZE do return result, .TooShort
	if get_opcode(data) != .S_AckSendMessage do return result, .InvalidOpcode
	if len(data) != 2 + _ASM_TOTAL_SIZE do return result, .ContentLengthMismatch

	pos := 2
	result.client_req_id, _ = endian.get_u32(data[pos:], .Big)
	pos += 4

	seq, _ := endian.get_u64(data[pos:], .Big)
	result.assigned_seq = MessageSeq(seq)
	pos += 8

	timestamp_u64, _ := endian.get_u64(data[pos:], .Big)
	result.timestamp = cast(i64)timestamp_u64

	return result, nil
}

// ============================================================================
// Subscribe/Unsubscribe
// ============================================================================

SubscribeConvsRequest :: struct {
	conv_ids: []ConversationID,
}

UnsubscribeConvsRequest :: struct {
	conv_ids:       []ConversationID,
	correlation_id: u32,
}

@(thread_local)
_subscribe_conv_ids_buf: [MAX_SUBSCRIBE_CONVS]ConversationID

parse_subscribe_convs_header :: proc(s: ^[]byte) -> (count: int, ok: bool) {
	if len(s^) < 2 {
		return
	}
	count_u16, _ := endian.get_u16(s^[0:2], .Big)
	count = int(count_u16)
	needed := 2 + count * size_of(ConversationID)
	if len(s^) < needed {
		return
	}
	s^ = s^[2:]
	ok = true
	return
}

conv_id_iterator :: proc(s: ^[]byte) -> (id: ConversationID, ok: bool) {
	if len(s^) < size_of(ConversationID) {
		return
	}

	val, _ := endian.get_u64(s^[0:], .Big)
	id = ConversationID(val)

	s^ = s^[size_of(ConversationID):]

	ok = true
	return
}

parseSubscribeConvsRequest :: proc(data: []byte) -> (SubscribeConvsRequest, ProtocolParseError) {
	result := SubscribeConvsRequest{}

	if len(data) < 2 {
		log.debugf("SubscribeConvsRequest payload too short for count. Need 2, got %v", len(data))
		return result, .TooShort
	}

	count_u16, _ := endian.get_u16(data[0:2], .Big)
	count := int(count_u16)

	if count > MAX_SUBSCRIBE_CONVS {
		log.debugf("SubscribeConvsRequest too many conv_ids: %v (max %v)", count, MAX_SUBSCRIBE_CONVS)
		return result, .TooMany
	}

	expected_len := 2 + count * size_of(ConversationID)

	if len(data) < expected_len {
		log.debugf("SubscribeConvsRequest data too short. Need %v, got %v", expected_len, len(data))
		return result, .TooShort
	}
	if len(data) != expected_len {
		return result, .ContentLengthMismatch
	}

	for i in 0 ..< count {
		offset := 2 + i * size_of(ConversationID)
		conv_id, _ := endian.get_u64(data[offset:], .Big)
		_subscribe_conv_ids_buf[i] = ConversationID(conv_id)
	}
	result.conv_ids = _subscribe_conv_ids_buf[:count]

	return result, nil
}

// ============================================================================
// AckUnsubscribeConvs
// ============================================================================

AckUnsubscribeConvs :: struct {
	correlation_id: u32,
}

getSizeAckUnsubscribeConvs :: proc(_: AckUnsubscribeConvs) -> int {
	return 2 + size_of(u32)
}

serializeAckUnsubscribeConvs :: proc(ack: AckUnsubscribeConvs, buf: []byte) -> int {
	total_size := getSizeAckUnsubscribeConvs(ack)
	if len(buf) < total_size do return -1
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AckUnsubscribeConvs))
	endian.put_u32(buf[2:], .Big, ack.correlation_id)
	return total_size
}

parseAckUnsubscribeConvs :: proc(data: []byte) -> (result: AckUnsubscribeConvs, err: ProtocolParseError) {
	if len(data) < size_of(u32) do return result, .TooShort
	if len(data) != size_of(u32) do return result, .ContentLengthMismatch
	result.correlation_id, _ = endian.get_u32(data, .Big)
	return result, nil
}

parseAckUnsubscribeConvsMessage :: proc(data: []byte) -> (result: AckUnsubscribeConvs, err: ProtocolParseError) {
	if len(data) < 2 do return result, .TooShort
	if get_opcode(data) != .S_AckUnsubscribeConvs do return result, .InvalidOpcode
	return parseAckUnsubscribeConvs(data[2:])
}

/// parseUnsubscribeConvsRequest parses the payload for a C_UnsubscribeConvs opcode.
/// Expects `data` to start *after* the initial opcode.
/// Uses thread-local stack buffer - zero allocations. Returns .TooMany if count exceeds MAX_SUBSCRIBE_CONVS.
parseUnsubscribeConvsRequest :: proc(data: []byte) -> (UnsubscribeConvsRequest, ProtocolParseError) {
	result := UnsubscribeConvsRequest{}

	// Check minimum length for count field
	if len(data) < 2 {
		log.debugf("UnsubscribeConvsRequest payload too short for count. Need 2, got %v", len(data))
		return result, .TooShort
	}

	// Read count of conversation IDs
	count_u16, _ := endian.get_u16(data[0:2], .Big)
	count := int(count_u16)

	// Reject if too many (client should batch into multiple requests)
	if count > MAX_SUBSCRIBE_CONVS {
		log.debugf("UnsubscribeConvsRequest too many conv_ids: %v (max %v)", count, MAX_SUBSCRIBE_CONVS)
		return result, .TooMany
	}

	expected_len := 2 + count * size_of(ConversationID) // 2 + count * 8

	// Check total length
	if len(data) < expected_len {
		log.debugf("UnsubscribeConvsRequest data too short. Need %v, got %v", expected_len, len(data))
		return result, .TooShort
	}
	if len(data) != expected_len && len(data) != expected_len + size_of(u32) {
		return result, .ContentLengthMismatch
	}

	// Parse conversation IDs into thread-local buffer (zero allocation)
	// Safe to reuse _subscribe_conv_ids_buf since parsing is synchronous
	for i in 0 ..< count {
		offset := 2 + i * size_of(ConversationID)
		conv_id, _ := endian.get_u64(data[offset:], .Big)
		_subscribe_conv_ids_buf[i] = ConversationID(conv_id)
	}
	result.conv_ids = _subscribe_conv_ids_buf[:count]
	if len(data) == expected_len + size_of(u32) {
		result.correlation_id, _ = endian.get_u32(data[expected_len:], .Big)
	}

	return result, nil
}

// ============================================================================
// Stats
// ============================================================================

StatsRequest :: struct {
	timestamp: i64,
}

PONG_WAL_DETAIL_SLOT_COUNT :: 3
PONG_WAL_DETAIL_MAX_COUNT :: u8(PONG_WAL_DETAIL_SLOT_COUNT)
PONG_WAL_DETAIL_VERSION :: u8(1)
PONG_SHARD_SWEEP_VERSION :: u8(1)

PongWALKind :: enum u8 {
	Task,
	Asset,
	Edge,
}

PongWALDetail :: struct {
	kind:                 PongWALKind,
	enabled:              bool,
	compaction_mode:      u8,
	compaction_bg_status: u8,
	generation:           u64,
	snapshot_end:         u64,
	compact_count:        u64,
	install_cursor:       u64,
	install_last_backlog: u64,
	install_budget_us:    u32,
	file_size:            u64,
	pending_bytes:        u64,
	record_count:         u64,
	fsync_count:          u64,
	total_fsync_ns:       u64,
	write_count:          u64,
	total_write_ns:       u64,
}

ShardSweepStats :: struct {
	runs_total:                   u64,
	ordinary_runs_total:          u64,
	raw_runs_total:               u64,
	input_bytes_total:            u64,
	dirty_bytes_total:            u64,
	prefix_read_bytes_total:      u64,
	latest_read_bytes_total:      u64,
	measure_read_bytes_total:     u64,
	copy_read_bytes_total:        u64,
	replay_read_bytes_total:      u64,
	metadata_fallbacks_total:     u64,
	metadata_written_bytes_total: u64,
}

StatsResponse :: struct {
	timestamp:            i64,
	server_timestamp:     i64,
	thread_id:            u32,
	total_threads:        u32,
	connections:          u32,
	memory_total_mb:      u32,
	buffer_pool_percent:  u32,
	io_pending:           u32,
	io_ring_depth:        u32,
	io_ring_available:    u32,
	io_sq_overflow:       u32,
	io_total_completions: u64,
	io_total_latency_ns:  u64,
	io_latency_count:     u64,
	send_queue_depth:     u32,
	send_queue_limit:     u32,
	send_backpressure:    bool,
	send_dropped:         u32,

	// Aggregate WAL metrics (task + asset + edge WALs for this thread)
	wal_file_size:        u64, // Combined file size in bytes
	wal_pending_bytes:    u64, // Combined pending bytes awaiting fsync
	wal_record_count:     u64, // Combined total records written
	wal_fsync_count:      u64, // Combined total fsyncs performed
	wal_total_fsync_ns:   u64, // Combined cumulative fsync latency in nanoseconds
	wal_total_write_ns:   u64, // Combined cumulative write latency in nanoseconds
	wal_write_count:      u64, // Combined total writes performed

	// Optional per-WAL detail extension
	wal_details_version:  u8,
	wal_details_count:    u8,
	wal_details:          [PONG_WAL_DETAIL_SLOT_COUNT]PongWALDetail,
	shard_sweep_version:  u8,
	shard_sweep:          ShardSweepStats,
}

_STATS_REQUEST_SIZE :: size_of(i64)

parseStatsRequest :: proc(data: []byte) -> (StatsRequest, ProtocolParseError) {
	result := StatsRequest{}

	if len(data) < _STATS_REQUEST_SIZE {
		log.debugf("StatsRequest payload too short. Need %v, got %v", _STATS_REQUEST_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != _STATS_REQUEST_SIZE {
		return result, .ContentLengthMismatch
	}

	timestamp, _ := endian.get_u64(data[0:], .Big)
	result.timestamp = cast(i64)timestamp

	return result, nil
}

// opcode(2) + timestamp(8) + server_timestamp(8) + thread_id(4) + total_threads(4) + connections(4) +
// memory_total_mb(4) + buffer_pool_percent(4) + io_pending(4) + io_ring_depth(4) + io_ring_available(4) +
// io_sq_overflow(4) + io_total_completions(8) + io_total_latency_ns(8) + io_latency_count(8) +
// send_queue_depth(4) + send_queue_limit(4) + send_backpressure(1) + send_dropped(4) +
// wal_file_size(8) + wal_pending_bytes(8) + wal_record_count(8) + wal_fsync_count(8) +
// wal_total_fsync_ns(8) + wal_total_write_ns(8) + wal_write_count(8)

_STATS_RESPONSE_BASE_SIZE :: 2 + 8 + 8 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 4 + 8 + 8 + 8 + 4 + 4 + 1 + 4 + 8 + 8 + 8 + 8 + 8 + 8 + 8

// kind(1) + enabled(1) + compaction_mode(1) + compaction_bg_status(1) +
// generation(8) + snapshot_end(8) + compact_count(8) + install_cursor(8) + install_last_backlog(8) +
// install_budget_us(4) + file_size(8) + pending_bytes(8) + record_count(8) +
// fsync_count(8) + total_fsync_ns(8) + write_count(8) + total_write_ns(8)
_PONG_WAL_DETAIL_SIZE :: 104
_PONG_WAL_DETAIL_HEADER_SIZE :: 2 // version(1) + count(1)
_PONG_SHARD_SWEEP_SIZE :: 1 + 12 * 8

getSizeStatsResponse :: proc(msg: StatsResponse) -> int {
	total_size := _STATS_RESPONSE_BASE_SIZE

	details_count := int(msg.wal_details_count)
	if details_count > PONG_WAL_DETAIL_SLOT_COUNT {
		details_count = PONG_WAL_DETAIL_SLOT_COUNT
	}

	if details_count > 0 {
		total_size += _PONG_WAL_DETAIL_HEADER_SIZE + details_count * _PONG_WAL_DETAIL_SIZE
		if msg.shard_sweep_version > 0 do total_size += _PONG_SHARD_SWEEP_SIZE
	}

	return total_size
}

serializeStatsResponse :: proc(msg: StatsResponse, buf: []byte) -> int {
	total_size := getSizeStatsResponse(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for StatsResponse. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_StatsResponse))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, cast(u64)msg.timestamp)
	offset += 8
	endian.put_u64(payload[offset:], .Big, cast(u64)msg.server_timestamp)
	offset += 8
	endian.put_u32(payload[offset:], .Big, msg.thread_id)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.total_threads)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.connections)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.memory_total_mb)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.buffer_pool_percent)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.io_pending)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.io_ring_depth)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.io_ring_available)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.io_sq_overflow)
	offset += 4
	endian.put_u64(payload[offset:], .Big, msg.io_total_completions)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.io_total_latency_ns)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.io_latency_count)
	offset += 8
	endian.put_u32(payload[offset:], .Big, msg.send_queue_depth)
	offset += 4
	endian.put_u32(payload[offset:], .Big, msg.send_queue_limit)
	offset += 4
	payload[offset] = msg.send_backpressure ? 1 : 0
	offset += 1
	endian.put_u32(payload[offset:], .Big, msg.send_dropped)
	offset += 4

	// WAL metrics
	endian.put_u64(payload[offset:], .Big, msg.wal_file_size)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_pending_bytes)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_record_count)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_fsync_count)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_total_fsync_ns)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_total_write_ns)
	offset += 8
	endian.put_u64(payload[offset:], .Big, msg.wal_write_count)
	offset += 8

	details_count := int(msg.wal_details_count)
	if details_count > PONG_WAL_DETAIL_SLOT_COUNT {
		details_count = PONG_WAL_DETAIL_SLOT_COUNT
	}

	if details_count > 0 {
		payload[offset] = msg.wal_details_version
		offset += 1
		payload[offset] = u8(details_count)
		offset += 1

		for i := 0; i < details_count; i += 1 {
			detail := msg.wal_details[i]
			payload[offset] = u8(detail.kind)
			offset += 1
			payload[offset] = detail.enabled ? 1 : 0
			offset += 1
			payload[offset] = detail.compaction_mode
			offset += 1
			payload[offset] = detail.compaction_bg_status
			offset += 1

			endian.put_u64(payload[offset:], .Big, detail.generation)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.snapshot_end)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.compact_count)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.install_cursor)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.install_last_backlog)
			offset += 8
			endian.put_u32(payload[offset:], .Big, detail.install_budget_us)
			offset += 4

			endian.put_u64(payload[offset:], .Big, detail.file_size)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.pending_bytes)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.record_count)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.fsync_count)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.total_fsync_ns)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.write_count)
			offset += 8
			endian.put_u64(payload[offset:], .Big, detail.total_write_ns)
			offset += 8
		}

		if msg.shard_sweep_version > 0 {
			payload[offset] = msg.shard_sweep_version
			offset += 1
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.runs_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.ordinary_runs_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.raw_runs_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.input_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.dirty_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.prefix_read_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.latest_read_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.measure_read_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.copy_read_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.replay_read_bytes_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.metadata_fallbacks_total); offset += 8
			endian.put_u64(payload[offset:], .Big, msg.shard_sweep.metadata_written_bytes_total); offset += 8
		}
	}

	return total_size
}

parseStatsResponseMessage :: proc(data: []byte) -> (result: StatsResponse, err: ProtocolParseError) {
	if len(data) < _STATS_RESPONSE_BASE_SIZE do return result, .TooShort
	if get_opcode(data) != .S_StatsResponse do return result, .InvalidOpcode

	if len(data) == _STATS_RESPONSE_BASE_SIZE {
		return parseStatsResponse(data[2:])
	}

	if len(data) < _STATS_RESPONSE_BASE_SIZE + _PONG_WAL_DETAIL_HEADER_SIZE do return result, .TooShort
	reported_count := int(data[_STATS_RESPONSE_BASE_SIZE + 1])
	expected_size := _STATS_RESPONSE_BASE_SIZE + _PONG_WAL_DETAIL_HEADER_SIZE + reported_count * _PONG_WAL_DETAIL_SIZE
	if len(data) < expected_size do return result, .TooShort
	if len(data) != expected_size && len(data) != expected_size + _PONG_SHARD_SWEEP_SIZE do return result, .ContentLengthMismatch

	return parseStatsResponse(data[2:])
}

// ============================================================================
// Ping/Pong (lightweight, no stats payload)
// ============================================================================

PingRequest :: struct {
	timestamp: i64,
}

PongResponse :: struct {
	timestamp:        i64,
	server_timestamp: i64,
}

_PING_REQUEST_SIZE :: size_of(i64)
_PONG_RESPONSE_SIZE :: 2 + 8 + 8 // opcode + client timestamp + server timestamp

parsePingRequest :: proc(data: []byte) -> (PingRequest, ProtocolParseError) {
	result := PingRequest{}

	if len(data) < _PING_REQUEST_SIZE {
		log.debugf("PingRequest payload too short. Need %v, got %v", _PING_REQUEST_SIZE, len(data))
		return result, .TooShort
	}
	if len(data) != _PING_REQUEST_SIZE {
		return result, .ContentLengthMismatch
	}

	timestamp, _ := endian.get_u64(data[0:], .Big)
	result.timestamp = cast(i64)timestamp

	return result, nil
}

getSizePongResponse :: proc(_: PongResponse) -> int {
	return _PONG_RESPONSE_SIZE
}

serializePongResponse :: proc(msg: PongResponse, buf: []byte) -> int {
	total_size := getSizePongResponse(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for PongResponse. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_Pong))

	payload := buf[2:]
	endian.put_u64(payload[0:], .Big, cast(u64)msg.timestamp)
	endian.put_u64(payload[8:], .Big, cast(u64)msg.server_timestamp)

	return total_size
}

parsePongResponseMessage :: proc(data: []byte) -> (result: PongResponse, err: ProtocolParseError) {
	if len(data) < _PONG_RESPONSE_SIZE do return result, .TooShort
	if get_opcode(data) != .S_Pong do return result, .InvalidOpcode
	if len(data) != _PONG_RESPONSE_SIZE do return result, .ContentLengthMismatch

	return parsePongResponse(data[2:])
}

// ============================================================================
// RoomPresence
// ============================================================================

RoomPresenceUpdate :: struct {
	conv_id:          ConversationID,
	event_type:       PresenceEventType,
	sequence:         u64,
	username:         []byte,
	is_authenticated: bool,
	user_type:        User_Type,
	old_username:     []byte,
	user_list:        [][]byte,
	user_auth_flags:  []bool,
	user_types:       []User_Type,
}

getSizeRoomPresenceUpdate :: proc(msg: RoomPresenceUpdate) -> int {
	// opcode(2) + conv_id(8) + event_type(1) + sequence(8) + username_len(2) + username +
	// is_authenticated(1) + user_type(1) + old_username_len(2) + old_username + user_count(2) + users
	// each user: user_len(2) + user + auth_flag(1) + user_type(1)
	size := 2 + 8 + 1 + 8 + 2 + len(msg.username) + 1 + 1 + 2 + len(msg.old_username) + 2
	for user in msg.user_list {
		size += 2 + len(user) + 1 + 1
	}
	return size
}

serializeRoomPresenceUpdate :: proc(msg: RoomPresenceUpdate, buf: []byte) -> int {
	if len(msg.username) > MAX_USERNAME_LENGTH {
		log.errorf("Presence username length %v exceeds maximum %v", len(msg.username), MAX_USERNAME_LENGTH)
		return -1
	}
	if len(msg.old_username) > MAX_USERNAME_LENGTH {
		log.errorf("Presence old_username length %v exceeds maximum %v", len(msg.old_username), MAX_USERNAME_LENGTH)
		return -1
	}
	if len(msg.user_list) > 65535 {
		log.errorf("Presence user count %v exceeds maximum %v", len(msg.user_list), 65535)
		return -1
	}
	for user in msg.user_list {
		if len(user) > MAX_USERNAME_LENGTH {
			log.errorf("Presence listed username length %v exceeds maximum %v", len(user), MAX_USERNAME_LENGTH)
			return -1
		}
	}

	total_size := getSizeRoomPresenceUpdate(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for RoomPresenceUpdate. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_RoomPresenceUpdate))

	payload := buf[2:]
	offset := 0

	endian.put_u64(payload[offset:], .Big, u64(msg.conv_id))
	offset += 8

	payload[offset] = u8(msg.event_type)
	offset += 1

	endian.put_u64(payload[offset:], .Big, msg.sequence)
	offset += 8

	username_len := len(msg.username)
	endian.put_u16(payload[offset:], .Big, u16(username_len))
	offset += 2
	if username_len > 0 {
		copy(payload[offset:], msg.username)
		offset += username_len
	}

	payload[offset] = msg.is_authenticated ? 1 : 0
	offset += 1

	payload[offset] = u8(msg.user_type)
	offset += 1

	old_username_len := len(msg.old_username)
	endian.put_u16(payload[offset:], .Big, u16(old_username_len))
	offset += 2
	if old_username_len > 0 {
		copy(payload[offset:], msg.old_username)
		offset += old_username_len
	}

	user_count := len(msg.user_list)
	endian.put_u16(payload[offset:], .Big, u16(user_count))
	offset += 2
	for i in 0 ..< user_count {
		user := msg.user_list[i]
		user_len := len(user)
		endian.put_u16(payload[offset:], .Big, u16(user_len))
		offset += 2
		if user_len > 0 {
			copy(payload[offset:], user)
			offset += user_len
		}
		auth_flag: u8 = 0
		if i < len(msg.user_auth_flags) && msg.user_auth_flags[i] {
			auth_flag = 1
		}
		payload[offset] = auth_flag
		offset += 1
		user_type_val: u8 = u8(User_Type.User)
		if i < len(msg.user_types) {
			user_type_val = u8(msg.user_types[i])
		}
		payload[offset] = user_type_val
		offset += 1
	}

	return total_size
}

parseRoomPresenceUpdateMessage :: proc(data: []byte, allocator := context.allocator) -> (result: RoomPresenceUpdate, err: ProtocolParseError) {
	if len(data) < 2 + 19 do return result, .TooShort
	if get_opcode(data) != .S_RoomPresenceUpdate do return result, .InvalidOpcode

	result, err = parseRoomPresenceUpdate(data[2:], allocator)
	if err != nil do return result, err
	if len(result.username) > MAX_USERNAME_LENGTH do return result, .ContentLengthExceedsMax
	if len(result.old_username) > MAX_USERNAME_LENGTH do return result, .ContentLengthExceedsMax
	for user in result.user_list {
		if len(user) > MAX_USERNAME_LENGTH do return result, .ContentLengthExceedsMax
	}
	if getSizeRoomPresenceUpdate(result) != len(data) do return result, .ContentLengthMismatch

	return result, nil
}

// ============================================================================
// ErrorResponse
// ============================================================================

_ERR_OFFSET_ORIGIN_OPCODE :: 0
_ERR_SIZE_ORIGIN_OPCODE :: size_of(u16)
_ERR_OFFSET_ERROR_MSG_LEN :: _ERR_OFFSET_ORIGIN_OPCODE + _ERR_SIZE_ORIGIN_OPCODE
_ERR_SIZE_ERROR_MSG_LEN :: size_of(u16)
_ERR_OFFSET_ERROR_MSG :: _ERR_OFFSET_ERROR_MSG_LEN + _ERR_SIZE_ERROR_MSG_LEN
_ERR_FIXED_HEADER_SIZE :: _ERR_OFFSET_ERROR_MSG

ErrorResponse :: struct {
	origin_opcode:  Opcode,
	error_msg:      []byte,
	correlation_id: u32, // Echoed from client request when available
}

getSizeErrorResponse :: proc(msg: ErrorResponse) -> int {
	// opcode(2) + origin_opcode(2) + error_msg_len(2) + error_msg + correlation_id(4)
	return 2 + _ERR_FIXED_HEADER_SIZE + len(msg.error_msg) + 4
}

serializeErrorResponse :: proc(msg: ErrorResponse, buf: []byte) -> int {
	error_msg_len := len(msg.error_msg)
	if error_msg_len > 65535 {
		log.errorf("Error response text length %v exceeds maximum %v", error_msg_len, 65535)
		return -1
	}

	total_size := getSizeErrorResponse(msg)
	if len(buf) < total_size {
		log.errorf("Buffer too small for ErrorResponse. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_ErrorResponse))

	payload := buf[2:]
	offset := 0

	endian.put_u16(payload[offset:], .Big, u16(msg.origin_opcode))
	offset += 2

	endian.put_u16(payload[offset:], .Big, u16(error_msg_len))
	offset += 2

	if error_msg_len > 0 {
		copy(payload[offset:], msg.error_msg)
		offset += error_msg_len
	}

	endian.put_u32(payload[offset:], .Big, msg.correlation_id)

	return total_size
}

parseErrorResponseMessage :: proc(data: []byte) -> (result: ErrorResponse, err: ProtocolParseError) {
	if len(data) < 2 + _ERR_FIXED_HEADER_SIZE + 4 do return result, .TooShort
	if get_opcode(data) != .S_ErrorResponse do return result, .InvalidOpcode

	pos := 2
	origin_opcode, _ := endian.get_u16(data[pos:], .Big)
	result.origin_opcode = Opcode(origin_opcode)
	pos += 2

	error_msg_len, _ := endian.get_u16(data[pos:], .Big)
	pos += 2
	if len(data) < pos + int(error_msg_len) + 4 do return result, .TooShort
	if error_msg_len > 0 {
		result.error_msg = data[pos:pos + int(error_msg_len)]
		pos += int(error_msg_len)
	}

	result.correlation_id, _ = endian.get_u32(data[pos:], .Big)
	pos += 4
	if pos != len(data) do return result, .ContentLengthMismatch

	return result, nil
}
