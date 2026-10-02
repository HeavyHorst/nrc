package protocol

// Conventional protocol parser/serializer tests for request and response payload
// formats. These cases complement the Hegel suites by pinning representative wire
// encodings, exact error behavior where useful, and compatibility details that are
// easier to read as explicit byte-level examples than generated properties.

import "base:runtime"
import "core:bytes"
import "core:encoding/endian"
import "core:log"
import "core:os"
import "core:testing"
import "core:time"

// ============================================================================
// Roundtrip Tests: Serialize -> Parse
// ============================================================================

@(test)
test_roundtrip_send_message_request :: proc(t: ^testing.T) {
	buf: [256]byte

	// Build a SendMessageRequest payload manually (simulating what client sends)
	offset := 0

	// conv_id (8 bytes)
	conv_id: ConversationID = 12345678
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	// client_req_id (4 bytes)
	client_req_id: u32 = 42
	endian.put_u32(buf[offset:], .Big, client_req_id)
	offset += 4

	// content_type (1 byte)
	content_type := MessageContentType.Markdown
	buf[offset] = u8(content_type)
	offset += 1

	// content_len (2 bytes) + content
	content := "Hello, World!"
	endian.put_u16(buf[offset:], .Big, u16(len(content)))
	offset += 2
	copy(buf[offset:], content)
	offset += len(content)

	// Parse
	parsed, err := parseSendMessageRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.client_req_id, client_req_id)
	testing.expect_value(t, parsed.content_type, content_type)
	testing.expect(t, string(parsed.content) == content, "content mismatch")
}

@(test)
test_roundtrip_authenticate_request :: proc(t: ^testing.T) {
	buf: [256]byte

	token := "jwt.token.here"
	endian.put_u16(buf[0:], .Big, u16(len(token)))
	copy(buf[2:], token)

	parsed, err := parseAuthenticateRequest(buf[:2 + len(token)])

	testing.expect_value(t, err, nil)
	testing.expect(t, string(parsed.token) == token, "token mismatch")
}

@(test)
test_roundtrip_stats_request :: proc(t: ^testing.T) {
	buf: [16]byte
	timestamp: i64 = 123456789

	written := serializeStatsRequest(timestamp, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeStatsRequest())

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.C_Stats)

	parsed, err := parseStatsRequest(buf[2:written])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.timestamp, timestamp)
}

@(test)
test_roundtrip_ping_request :: proc(t: ^testing.T) {
	buf: [16]byte
	timestamp: i64 = 987654321

	written := serializePingRequest(timestamp, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizePingRequest())

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.C_Ping)

	parsed, err := parsePingRequest(buf[2:written])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.timestamp, timestamp)
}

// ============================================================================
// Serialization Tests
// ============================================================================

@(test)
test_serialize_server_ready :: proc(t: ^testing.T) {
	msg := ServerReady {
		build_version    = transmute([]byte)string("v1.0.0"),
		protocol_version = 1,
		cpu_model        = transmute([]byte)string("AMD Ryzen"),
		username         = transmute([]byte)string("test-user"),
		is_authenticated = true,
	}

	buf: [64]byte
	written := serializeServerReady(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeServerReady(msg))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_ServerReady)
}

@(test)
test_serialize_ack_send_message :: proc(t: ^testing.T) {
	ack := AckSendMessage {
		client_req_id = 42,
		assigned_seq  = 100,
		timestamp     = 1234567890,
	}

	buf: [32]byte
	written := serializeAckSendMessage(ack, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeAckSendMessage(ack))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_AckSendMessage)
}

@(test)
test_serialize_new_message_event :: proc(t: ^testing.T) {
	msg := NewMessageEvent {
		conv_id         = 12345,
		seq             = 1,
		author_username = transmute([]byte)string("alice"),
		timestamp       = 1234567890,
		content_type    = .PlainText,
		content         = transmute([]byte)string("Hello!"),
	}

	buf: [128]byte
	written := serializeNewMessageEvent(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeNewMessageEvent(msg))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_NewMessage)
}

@(test)
test_serialize_stats_response :: proc(t: ^testing.T) {
	stats := StatsResponse {
		timestamp            = 1000,
		server_timestamp     = 1001,
		thread_id            = 1,
		total_threads        = 4,
		connections          = 100,
		memory_total_mb      = 512,
		buffer_pool_percent  = 75,
		io_pending           = 10,
		io_ring_depth        = 256,
		io_ring_available    = 200,
		io_sq_overflow       = 0,
		io_total_completions = 50000,
		io_total_latency_ns  = 1000000,
		io_latency_count     = 500,
		send_queue_depth     = 50,
		send_queue_limit     = 1000,
		send_backpressure    = false,
		send_dropped         = 0,
	}

	buf: [160]byte
	written := serializeStatsResponse(stats, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeStatsResponse(stats))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_StatsResponse)
}

@(test)
test_serialize_and_parse_stats_response_with_wal_details :: proc(t: ^testing.T) {
	wal_details: [PONG_WAL_DETAIL_SLOT_COUNT]PongWALDetail
	wal_details[0] = PongWALDetail {
		kind                 = .Task,
		enabled              = true,
		compaction_mode      = 1,
		compaction_bg_status = 2,
		generation           = 7,
		snapshot_end         = 111,
		compact_count        = 9,
		install_cursor       = 25,
		install_last_backlog = 64,
		install_budget_us    = 1500,
		file_size            = 512,
		pending_bytes        = 4,
		record_count         = 12,
		fsync_count          = 3,
		total_fsync_ns       = 2500,
		write_count          = 10,
		total_write_ns       = 5000,
	}
	wal_details[1] = PongWALDetail {
		kind = .Asset,
	}
	wal_details[2] = PongWALDetail {
		kind = .Edge,
	}

	stats := StatsResponse {
		timestamp = 42,
		server_timestamp = 43,
		thread_id = 1,
		total_threads = 4,
		connections = 5,
		memory_total_mb = 256,
		buffer_pool_percent = 10,
		io_pending = 0,
		io_ring_depth = 128,
		io_ring_available = 120,
		io_sq_overflow = 0,
		io_total_completions = 10,
		io_total_latency_ns = 100,
		io_latency_count = 2,
		send_queue_depth = 1,
		send_queue_limit = 128,
		send_backpressure = false,
		send_dropped = 0,
		wal_file_size = 2048,
		wal_pending_bytes = 32,
		wal_record_count = 99,
		wal_fsync_count = 10,
		wal_total_fsync_ns = 1000,
		wal_total_write_ns = 2000,
		wal_write_count = 30,
		wal_details_version = PONG_WAL_DETAIL_VERSION,
		wal_details_count = PONG_WAL_DETAIL_MAX_COUNT,
		wal_details = wal_details,
		shard_sweep_version = PONG_SHARD_SWEEP_VERSION,
		shard_sweep = {
			runs_total = 11,
			ordinary_runs_total = 7,
			raw_runs_total = 4,
			input_bytes_total = 1000,
			dirty_bytes_total = 200,
			prefix_read_bytes_total = 1,
			latest_read_bytes_total = 2,
			measure_read_bytes_total = 3,
			copy_read_bytes_total = 4,
			replay_read_bytes_total = 5,
			metadata_fallbacks_total = 6,
			metadata_written_bytes_total = 7,
		},
	}

	buf: [640]byte
	written := serializeStatsResponse(stats, buf[:])
	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeStatsResponse(stats))

	parsed, parse_err := parseStatsResponseMessage(buf[:written])
	testing.expect(t, parse_err == nil, "parse should succeed")
	testing.expect_value(t, parsed.wal_details_version, PONG_WAL_DETAIL_VERSION)
	testing.expect_value(t, parsed.wal_details_count, PONG_WAL_DETAIL_MAX_COUNT)
	testing.expect_value(t, parsed.wal_details[0].kind, PongWALKind.Task)
	testing.expect_value(t, parsed.wal_details[0].generation, u64(7))
	testing.expect_value(t, parsed.wal_details[0].install_budget_us, u32(1500))
	testing.expect_value(t, parsed.shard_sweep_version, PONG_SHARD_SWEEP_VERSION)
	testing.expect_value(t, parsed.shard_sweep.runs_total, u64(11))
	testing.expect_value(t, parsed.shard_sweep.replay_read_bytes_total, u64(5))
	testing.expect_value(t, parsed.shard_sweep.metadata_written_bytes_total, u64(7))
}

@(test)
test_serialize_and_parse_lightweight_pong_response :: proc(t: ^testing.T) {
	pong := PongResponse {
		timestamp        = 100,
		server_timestamp = 101,
	}

	buf: [64]byte
	written := serializePongResponse(pong, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizePongResponse(pong))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_Pong)

	parsed, parse_err := parsePongResponseMessage(buf[:written])
	testing.expect(t, parse_err == nil, "parse should succeed")
	testing.expect_value(t, parsed.timestamp, i64(100))
	testing.expect_value(t, parsed.server_timestamp, i64(101))
}

@(test)
test_serialize_room_presence_update :: proc(t: ^testing.T) {
	user_list := [][]byte{transmute([]byte)string("alice"), transmute([]byte)string("bob")}
	auth_flags := []bool{true, false}

	msg := RoomPresenceUpdate {
		conv_id          = 12345,
		event_type       = .UserListSync,
		sequence         = 1,
		username         = transmute([]byte)string(""),
		is_authenticated = false,
		old_username     = transmute([]byte)string(""),
		user_list        = user_list,
		user_auth_flags  = auth_flags,
	}

	buf: [256]byte
	written := serializeRoomPresenceUpdate(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeRoomPresenceUpdate(msg))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_RoomPresenceUpdate)

	parsed, parse_err := parseRoomPresenceUpdateMessage(buf[:written])
	testing.expect(t, parse_err == nil, "parse should succeed")
	defer if len(parsed.user_list) > 0 {
		delete(parsed.user_list)
		delete(parsed.user_auth_flags)
		delete(parsed.user_types)
	}
	testing.expect_value(t, parsed.conv_id, msg.conv_id)
	testing.expect_value(t, parsed.event_type, msg.event_type)
	testing.expect_value(t, parsed.sequence, msg.sequence)
	testing.expect_value(t, len(parsed.user_list), 2)
	testing.expect(t, bytes.equal(parsed.user_list[0], user_list[0]), "first user should roundtrip")
	testing.expect(t, bytes.equal(parsed.user_list[1], user_list[1]), "second user should roundtrip")
}

@(test)
test_serialize_and_parse_error_response :: proc(t: ^testing.T) {
	error_msg := transmute([]byte)string("bad request")
	msg := ErrorResponse {
		origin_opcode  = .C_SendMessage,
		error_msg      = error_msg,
		correlation_id = 0xAABBCCDD,
	}

	buf: [128]byte
	written := serializeErrorResponse(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeErrorResponse(msg))

	parsed, parse_err := parseErrorResponseMessage(buf[:written])
	testing.expect(t, parse_err == nil, "parse should succeed")
	testing.expect_value(t, parsed.origin_opcode, msg.origin_opcode)
	testing.expect(t, bytes.equal(parsed.error_msg, msg.error_msg), "error message should roundtrip")
	testing.expect_value(t, parsed.correlation_id, msg.correlation_id)
}

// ============================================================================
// Error Case Tests
// ============================================================================

@(test)
test_parse_send_message_too_short :: proc(t: ^testing.T) {
	buf: [10]byte // Too short for header
	_, err := parseSendMessageRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_stats_request_too_short :: proc(t: ^testing.T) {
	buf: [7]byte
	_, err := parseStatsRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_ping_request_too_short :: proc(t: ^testing.T) {
	buf: [7]byte
	_, err := parsePingRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_send_message_content_length_exceeds_max :: proc(t: ^testing.T) {
	buf: [32]byte

	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(12345)) // conv_id
	offset += 8
	endian.put_u32(buf[offset:], .Big, u32(1)) // client_req_id
	offset += 4
	buf[offset] = 0 // content_type
	offset += 1
	endian.put_u16(buf[offset:], .Big, u16(MAX_ALLOWED_CONTENT_LENGTH + 1)) // exceeds max
	offset += 2

	_, err := parseSendMessageRequest(buf[:offset])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthExceedsMax)
}

@(test)
test_parse_send_message_content_length_mismatch :: proc(t: ^testing.T) {
	buf: [32]byte

	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(12345)) // conv_id
	offset += 8
	endian.put_u32(buf[offset:], .Big, u32(1)) // client_req_id
	offset += 4
	buf[offset] = 0 // content_type
	offset += 1
	endian.put_u16(buf[offset:], .Big, u16(100)) // claims 100 bytes but we won't provide them
	offset += 2

	_, err := parseSendMessageRequest(buf[:offset])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
}

@(test)
test_parse_authenticate_too_short :: proc(t: ^testing.T) {
	buf: [1]byte // Too short
	_, err := parseAuthenticateRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_authenticate_token_exceeds_max :: proc(t: ^testing.T) {
	buf: [4]byte
	endian.put_u16(buf[0:], .Big, u16(MAX_TOKEN_LENGTH + 1)) // exceeds max
	_, err := parseAuthenticateRequest(buf[:2])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthExceedsMax)
}

@(test)
test_parse_authenticate_token_mismatch :: proc(t: ^testing.T) {
	buf: [4]byte
	endian.put_u16(buf[0:], .Big, u16(100)) // claims 100 bytes
	_, err := parseAuthenticateRequest(buf[:2]) // only 2 bytes provided
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
}

// ============================================================================
// get_opcode Tests
// ============================================================================

@(test)
test_get_opcode_valid_client_opcodes :: proc(t: ^testing.T) {
	buf: [2]byte

	// C_SendMessage = 1
	endian.put_u16(buf[:], .Big, 1)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_SendMessage)

	// C_Stats = 8
	endian.put_u16(buf[:], .Big, 8)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_Stats)

	// C_Ping = 19
	endian.put_u16(buf[:], .Big, 19)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_Ping)
}

@(test)
test_get_opcode_valid_server_opcodes :: proc(t: ^testing.T) {
	buf: [2]byte

	// S_ServerReady = 100
	endian.put_u16(buf[:], .Big, 100)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_ServerReady)

	// S_NewMessage = 102
	endian.put_u16(buf[:], .Big, 102)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_NewMessage)

	// S_StatsResponse = 110
	endian.put_u16(buf[:], .Big, 110)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_StatsResponse)

	// S_AuthResponse = 111
	endian.put_u16(buf[:], .Big, 111)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_AuthResponse)

	// S_Pong = 126
	endian.put_u16(buf[:], .Big, 126)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_Pong)

	// S_AckUnsubscribeConvs = 127
	endian.put_u16(buf[:], .Big, 127)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_AckUnsubscribeConvs)
}

@(test)
test_get_opcode_invalid :: proc(t: ^testing.T) {
	buf: [2]byte

	// Invalid opcode above the client range
	endian.put_u16(buf[:], .Big, 59)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	// Reserved client opcode 0 (formerly C_SetNickname)
	endian.put_u16(buf[:], .Big, 0)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	// Reserved client opcode 9 (formerly C_Authenticate)
	endian.put_u16(buf[:], .Big, 9)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	// Reserved server opcode 101 (formerly S_NicknameResponse)
	endian.put_u16(buf[:], .Big, 101)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	// Invalid opcode too high (200)
	endian.put_u16(buf[:], .Big, 200)
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))
}

@(test)
test_unsubscribe_wire_shapes_and_ack :: proc(t: ^testing.T) {
	legacy: [10]byte
	endian.put_u16(legacy[0:2], .Big, 1)
	endian.put_u64(legacy[2:10], .Big, 42)
	legacy_req, legacy_err := parseUnsubscribeConvsRequest(legacy[:])
	testing.expect(t, legacy_err == nil)
	testing.expect_value(t, legacy_req.correlation_id, u32(0))

	correlated: [14]byte
	copy(correlated[:10], legacy[:])
	endian.put_u32(correlated[10:14], .Big, 0x12345678)
	req, err := parseUnsubscribeConvsRequest(correlated[:])
	testing.expect(t, err == nil)
	testing.expect_value(t, req.correlation_id, u32(0x12345678))
	_, trailing_err := parseUnsubscribeConvsRequest(correlated[:13])
	testing.expect_value(t, trailing_err, ProtocolParseError.ContentLengthMismatch)

	ack_buf: [6]byte
	ack := AckUnsubscribeConvs {
		correlation_id = req.correlation_id,
	}
	testing.expect_value(t, serializeAckUnsubscribeConvs(ack, ack_buf[:]), 6)
	parsed_ack, ack_err := parseAckUnsubscribeConvsMessage(ack_buf[:])
	testing.expect(t, ack_err == nil)
	testing.expect_value(t, parsed_ack.correlation_id, req.correlation_id)
}

@(test)
test_get_opcode_insufficient_data :: proc(t: ^testing.T) {
	buf: [1]byte
	testing.expect_value(t, get_opcode(buf[:]), Opcode(0xFFFF))

	testing.expect_value(t, get_opcode([]byte{}), Opcode(0xFFFF))
}

// ============================================================================
// Edge Cases
// ============================================================================

@(test)
test_send_message_empty_content :: proc(t: ^testing.T) {
	buf: [32]byte

	offset := 0
	endian.put_u64(buf[offset:], .Big, u64(12345))
	offset += 8
	endian.put_u32(buf[offset:], .Big, u32(1))
	offset += 4
	buf[offset] = 0
	offset += 1
	endian.put_u16(buf[offset:], .Big, u16(0)) // Empty content
	offset += 2

	parsed, err := parseSendMessageRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(parsed.content), 0)
}

@(test)
test_authenticate_empty_token :: proc(t: ^testing.T) {
	buf: [2]byte
	endian.put_u16(buf[0:], .Big, u16(0)) // Empty token

	parsed, err := parseAuthenticateRequest(buf[:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(parsed.token), 0)
}

@(test)
test_serialize_room_presence_empty_user_list :: proc(t: ^testing.T) {
	msg := RoomPresenceUpdate {
		conv_id          = 12345,
		event_type       = .UserJoined,
		sequence         = 1,
		username         = transmute([]byte)string("alice"),
		is_authenticated = true,
		old_username     = nil,
		user_list        = nil,
		user_auth_flags  = nil,
	}

	buf: [64]byte
	written := serializeRoomPresenceUpdate(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeRoomPresenceUpdate(msg))

	parsed, parse_err := parseRoomPresenceUpdateMessage(buf[:written])
	testing.expect(t, parse_err == nil, "parse should succeed")
	testing.expect_value(t, parsed.conv_id, msg.conv_id)
	testing.expect_value(t, parsed.event_type, msg.event_type)
	testing.expect(t, bytes.equal(parsed.username, msg.username), "username should roundtrip")
}

// ============================================================================
// Task Protocol Tests
// ============================================================================

@(test)
test_roundtrip_create_task_request :: proc(t: ^testing.T) {
	buf: [512]byte

	offset := 0

	conv_id: ConversationID = 12345678
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	title := "Implement kanban board"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	description := "Add drag-drop support for task cards"
	endian.put_u16(buf[offset:], .Big, u16(len(description)))
	offset += 2
	copy(buf[offset:], description)
	offset += len(description)

	priority: u8 = 128
	buf[offset] = priority
	offset += 1

	color := TaskColor.Cyan
	buf[offset] = u8(color)
	offset += 1

	external_ref := "https://zoho.com/ticket/123"
	endian.put_u16(buf[offset:], .Big, u16(len(external_ref)))
	offset += 2
	copy(buf[offset:], external_ref)
	offset += len(external_ref)

	due_at: i64 = 1735689600000000000 // 2025-01-01 00:00:00 UTC in nanoseconds
	endian.put_u64(buf[offset:], .Big, cast(u64)due_at)
	offset += 8

	// No attachments in this test (count = 0)
	endian.put_u16(buf[offset:], .Big, u16(0))
	offset += 2

	buf[offset] = u8(TaskStatus.Backlog)
	offset += 1

	correlation_id: u32 = 0x10101010
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	attachments: [MAX_ATTACHMENTS_PER_TASK]Attachment
	parsed, err := parseCreateTaskRequest(buf[:offset], attachments[:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect(t, string(parsed.title) == title, "title mismatch")
	testing.expect(t, string(parsed.description) == description, "description mismatch")
	testing.expect_value(t, parsed.priority, priority)
	testing.expect_value(t, parsed.color, color)
	testing.expect(t, string(parsed.external_ref) == external_ref, "external_ref mismatch")
	testing.expect_value(t, parsed.due_at, due_at)
	testing.expect_value(t, len(parsed.attachments), 0)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_roundtrip_update_task_request :: proc(t: ^testing.T) {
	buf: [512]byte

	offset := 0

	conv_id: ConversationID = 12345678
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	task_id: TaskID = 42
	endian.put_u64(buf[offset:], .Big, u64(task_id))
	offset += 8

	title := "Updated title"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	description := "Updated description"
	endian.put_u16(buf[offset:], .Big, u16(len(description)))
	offset += 2
	copy(buf[offset:], description)
	offset += len(description)

	status := TaskStatus.InProgress
	buf[offset] = u8(status)
	offset += 1

	assignee := "alice"
	endian.put_u16(buf[offset:], .Big, u16(len(assignee)))
	offset += 2
	copy(buf[offset:], assignee)
	offset += len(assignee)

	priority: u8 = 200
	buf[offset] = priority
	offset += 1

	color := TaskColor.Red
	buf[offset] = u8(color)
	offset += 1

	external_ref := "MANTIS-456"
	endian.put_u16(buf[offset:], .Big, u16(len(external_ref)))
	offset += 2
	copy(buf[offset:], external_ref)
	offset += len(external_ref)

	due_at: i64 = 1735776000000000000 // 2025-01-02 00:00:00 UTC in nanoseconds
	endian.put_u64(buf[offset:], .Big, cast(u64)due_at)
	offset += 8

	blocked_by: TaskID = 99
	endian.put_u64(buf[offset:], .Big, u64(blocked_by))
	offset += 8

	// No attachments in this test (count = 0)
	endian.put_u16(buf[offset:], .Big, u16(0))
	offset += 2

	correlation_id: u32 = 0x20202020
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseUpdateTaskRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.task_id, task_id)
	testing.expect(t, string(parsed.title) == title, "title mismatch")
	testing.expect(t, string(parsed.description) == description, "description mismatch")
	testing.expect_value(t, parsed.status, status)
	testing.expect(t, string(parsed.assignee) == assignee, "assignee mismatch")
	testing.expect_value(t, parsed.priority, priority)
	testing.expect_value(t, parsed.color, color)
	testing.expect(t, string(parsed.external_ref) == external_ref, "external_ref mismatch")
	testing.expect_value(t, parsed.due_at, due_at)
	testing.expect_value(t, parsed.blocked_by, blocked_by)
	testing.expect_value(t, len(parsed.attachments), 0)
	testing.expect(t, !parsed.preserve_attachments, "zero attachment count should replace with an empty list")
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_update_task_preserves_attachments_for_sentinel :: proc(t: ^testing.T) {
	buf: [128]byte
	offset := 0

	endian.put_u64(buf[offset:], .Big, 42); offset += 8
	endian.put_u64(buf[offset:], .Big, 7); offset += 8
	endian.put_u16(buf[offset:], .Big, 0); offset += 2 // title
	endian.put_u16(buf[offset:], .Big, 0); offset += 2 // description
	buf[offset] = 255; offset += 1 // status
	endian.put_u16(buf[offset:], .Big, 0); offset += 2 // assignee
	buf[offset] = 255; offset += 1 // priority
	buf[offset] = 255; offset += 1 // color
	endian.put_u16(buf[offset:], .Big, 0); offset += 2 // external ref
	endian.put_u64(buf[offset:], .Big, 0); offset += 8 // due at
	endian.put_u64(buf[offset:], .Big, 0); offset += 8 // blocked by
	endian.put_u16(buf[offset:], .Big, max(u16)); offset += 2
	endian.put_u32(buf[offset:], .Big, 99); offset += 4
	endian.put_u16(buf[offset:], .Big, 0); offset += 2 // project

	parsed, err := parseUpdateTaskRequest(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect(t, parsed.preserve_attachments, "max_u16 attachment count should preserve attachments")
	testing.expect_value(t, len(parsed.attachments), 0)
	testing.expect_value(t, parsed.correlation_id, 99)
}

@(test)
test_roundtrip_update_task_preserves_attachments :: proc(t: ^testing.T) {
	req := UpdateTaskRequest {
		conv_id              = 42,
		task_id              = 7,
		description          = transmute([]byte)string("- [x] done"),
		status               = TaskStatus(255),
		priority             = 255,
		color                = TaskColor(255),
		preserve_attachments = true,
		correlation_id       = 99,
	}
	buf: [256]byte
	written := serializeUpdateTaskRequest(req, buf[:])
	testing.expect_value(t, written, getSizeUpdateTaskRequest(req))

	parsed, err := parseUpdateTaskRequest(buf[2:written])
	testing.expect_value(t, err, nil)
	testing.expect(t, parsed.preserve_attachments, "serialized sentinel should preserve attachments")
	testing.expect(t, string(parsed.description) == "- [x] done", "description mismatch")
	testing.expect_value(t, parsed.correlation_id, req.correlation_id)
}

@(test)
test_roundtrip_delete_task_request :: proc(t: ^testing.T) {
	buf: [32]byte

	conv_id: ConversationID = 12345678
	endian.put_u64(buf[0:], .Big, u64(conv_id))

	task_id: TaskID = 999888777
	endian.put_u64(buf[8:], .Big, u64(task_id))

	correlation_id: u32 = 0x30303030
	endian.put_u32(buf[16:], .Big, correlation_id)

	parsed, err := parseDeleteTaskRequest(buf[:20])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.task_id, task_id)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_roundtrip_move_task_request :: proc(t: ^testing.T) {
	buf: [32]byte

	offset := 0

	conv_id: ConversationID = 12345678
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	task_id: TaskID = 123456
	endian.put_u64(buf[offset:], .Big, u64(task_id))
	offset += 8

	status := TaskStatus.Done
	buf[offset] = u8(status)
	offset += 1

	flags := MoveTaskFlag_APPEND
	buf[offset] = transmute(u8)flags
	offset += 1

	order_index: u16 = 5
	endian.put_u16(buf[offset:], .Big, order_index)
	offset += 2

	correlation_id: u32 = 0x40404040
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseMoveTaskRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.task_id, task_id)
	testing.expect_value(t, parsed.status, status)
	testing.expect_value(t, parsed.flags, flags)
	testing.expect_value(t, parsed.order_index, order_index)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_roundtrip_get_tasks_request :: proc(t: ^testing.T) {
	buf: [16]byte

	conv_id: ConversationID = 555666777
	endian.put_u64(buf[0:], .Big, u64(conv_id))

	correlation_id: u32 = 0x50505050
	endian.put_u32(buf[8:], .Big, correlation_id)

	parsed, err := parseGetTasksRequest(buf[:12])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_serialize_get_tasks_request :: proc(t: ^testing.T) {
	req := GetTasksRequest {
		conv_id        = 555666777,
		correlation_id = 0x50505050,
	}
	buf: [32]byte
	written := serializeGetTasksRequest(req, buf[:])

	testing.expect_value(t, written, getSizeGetTasksRequest())
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GetTasks)

	parsed, err := parseGetTasksRequest(buf[2:written])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, req.conv_id)
	testing.expect_value(t, parsed.correlation_id, req.correlation_id)
}

@(test)
test_serialize_task_created :: proc(t: ^testing.T) {
	task := Task {
		id          = 42,
		conv_id     = 12345,
		title       = transmute([]byte)string("Test task"),
		description = transmute([]byte)string("Task description"),
		status      = .Todo,
		order_index = 1,
		assignee    = transmute([]byte)string("bob"),
		priority    = 100,
		created_by  = transmute([]byte)string("alice"),
		created_at  = 1234567890,
		updated_at  = 1234567890,
	}

	msg := TaskCreated {
		task = task,
	}

	buf: [256]byte
	written := serializeTaskCreated(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskCreated(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskCreated)
}

@(test)
test_serialize_task_updated :: proc(t: ^testing.T) {
	task := Task {
		id          = 42,
		conv_id     = 12345,
		title       = transmute([]byte)string("Updated task"),
		description = transmute([]byte)string("Updated description"),
		status      = .InProgress,
		order_index = 2,
		assignee    = transmute([]byte)string("charlie"),
		priority    = 150,
		created_by  = transmute([]byte)string("alice"),
		created_at  = 1234567890,
		updated_at  = 1234567999,
	}

	msg := TaskUpdated {
		task = task,
	}

	buf: [256]byte
	written := serializeTaskUpdated(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskUpdated(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskUpdated)
}

@(test)
test_serialize_task_deleted :: proc(t: ^testing.T) {
	msg := TaskDeleted {
		task_id = 42,
		conv_id = 12345,
	}

	buf: [32]byte
	written := serializeTaskDeleted(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskDeleted(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskDeleted)
}

@(test)
test_serialize_task_moved :: proc(t: ^testing.T) {
	msg := TaskMoved {
		task_id      = 42,
		conv_id      = 12345,
		status       = .Done,
		order_index  = 3,
		completed_at = 1234567890,
		completed_by = transmute([]byte)string("bob"),
	}

	buf: [64]byte
	written := serializeTaskMoved(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskMoved(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskMoved)
}

@(test)
test_serialize_task_list_response :: proc(t: ^testing.T) {
	tasks := []Task {
		{
			id = 1,
			conv_id = 12345,
			title = transmute([]byte)string("Task 1"),
			description = transmute([]byte)string("Desc 1"),
			status = .Backlog,
			order_index = 0,
			assignee = nil,
			priority = 50,
			created_by = transmute([]byte)string("alice"),
			created_at = 1234567890,
			updated_at = 1234567890,
		},
		{
			id = 2,
			conv_id = 12345,
			title = transmute([]byte)string("Task 2"),
			description = transmute([]byte)string("Desc 2"),
			status = .Todo,
			order_index = 1,
			assignee = transmute([]byte)string("bob"),
			priority = 100,
			created_by = transmute([]byte)string("alice"),
			created_at = 1234567891,
			updated_at = 1234567891,
		},
	}

	msg := TaskListResponse {
		conv_id = 12345,
		success = true,
		tasks   = tasks,
		error   = nil,
	}

	buf: [512]byte
	written := serializeTaskListResponse(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskListResponse(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskListResponse)
}

@(test)
test_serialize_task_list_response_empty :: proc(t: ^testing.T) {
	msg := TaskListResponse {
		conv_id = 12345,
		success = true,
		tasks   = nil,
		error   = nil,
	}

	buf: [64]byte
	written := serializeTaskListResponse(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskListResponse(msg))
}

@(test)
test_serialize_task_list_response_error :: proc(t: ^testing.T) {
	msg := TaskListResponse {
		conv_id = 12345,
		success = false,
		tasks   = nil,
		error   = transmute([]byte)string("Conversation not found"),
	}

	buf: [64]byte
	written := serializeTaskListResponse(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskListResponse(msg))
}

@(test)
test_roundtrip_create_task_request_with_attachments :: proc(t: ^testing.T) {
	buf: [1024]byte

	offset := 0

	conv_id: ConversationID = 12345678
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	title := "Task with files"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	description := "Task with two attachments"
	endian.put_u16(buf[offset:], .Big, u16(len(description)))
	offset += 2
	copy(buf[offset:], description)
	offset += len(description)

	priority: u8 = 50
	buf[offset] = priority
	offset += 1

	color := TaskColor.Cyan
	buf[offset] = u8(color)
	offset += 1

	external_ref := ""
	endian.put_u16(buf[offset:], .Big, u16(len(external_ref)))
	offset += 2

	due_at: i64 = 0
	endian.put_u64(buf[offset:], .Big, cast(u64)due_at)
	offset += 8

	// Two attachments
	endian.put_u16(buf[offset:], .Big, u16(2))
	offset += 2

	// First attachment
	file_id_1 := "01ARZ3NDEKTSV4RRFFQ69G5FAV"
	endian.put_u16(buf[offset:], .Big, u16(len(file_id_1)))
	offset += 2
	copy(buf[offset:], file_id_1)
	offset += len(file_id_1)

	filename_1 := "screenshot.png"
	endian.put_u16(buf[offset:], .Big, u16(len(filename_1)))
	offset += 2
	copy(buf[offset:], filename_1)
	offset += len(filename_1)

	size_1: u64 = 245120
	endian.put_u64(buf[offset:], .Big, size_1)
	offset += 8

	mime_1 := "image/png"
	endian.put_u16(buf[offset:], .Big, u16(len(mime_1)))
	offset += 2
	copy(buf[offset:], mime_1)
	offset += len(mime_1)

	uploaded_at_1: i64 = 1735689600000000000
	endian.put_u64(buf[offset:], .Big, cast(u64)uploaded_at_1)
	offset += 8

	// Second attachment
	file_id_2 := "01ARZ3NDEKTSV4RRFFQ69G5FBW"
	endian.put_u16(buf[offset:], .Big, u16(len(file_id_2)))
	offset += 2
	copy(buf[offset:], file_id_2)
	offset += len(file_id_2)

	filename_2 := "document.pdf"
	endian.put_u16(buf[offset:], .Big, u16(len(filename_2)))
	offset += 2
	copy(buf[offset:], filename_2)
	offset += len(filename_2)

	size_2: u64 = 512000
	endian.put_u64(buf[offset:], .Big, size_2)
	offset += 8

	mime_2 := "application/pdf"
	endian.put_u16(buf[offset:], .Big, u16(len(mime_2)))
	offset += 2
	copy(buf[offset:], mime_2)
	offset += len(mime_2)

	uploaded_at_2: i64 = 1735689700000000000
	endian.put_u64(buf[offset:], .Big, cast(u64)uploaded_at_2)
	offset += 8

	buf[offset] = u8(TaskStatus.Backlog)
	offset += 1

	correlation_id: u32 = 0x60606060
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed_attachments: [MAX_ATTACHMENTS_PER_TASK]Attachment
	parsed, err := parseCreateTaskRequest(buf[:offset], parsed_attachments[:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect(t, string(parsed.title) == title, "title mismatch")
	testing.expect(t, string(parsed.description) == description, "description mismatch")
	testing.expect_value(t, parsed.priority, priority)
	testing.expect_value(t, parsed.color, color)
	testing.expect_value(t, len(parsed.attachments), 2)

	// Check first attachment
	testing.expect(t, string(parsed.attachments[0].file_id) == file_id_1, "file_id_1 mismatch")
	testing.expect(t, string(parsed.attachments[0].filename) == filename_1, "filename_1 mismatch")
	testing.expect_value(t, parsed.attachments[0].size, size_1)
	testing.expect(t, string(parsed.attachments[0].mime_type) == mime_1, "mime_1 mismatch")
	testing.expect_value(t, parsed.attachments[0].uploaded_at, uploaded_at_1)

	// Check second attachment
	testing.expect(t, string(parsed.attachments[1].file_id) == file_id_2, "file_id_2 mismatch")
	testing.expect(t, string(parsed.attachments[1].filename) == filename_2, "filename_2 mismatch")
	testing.expect_value(t, parsed.attachments[1].size, size_2)
	testing.expect(t, string(parsed.attachments[1].mime_type) == mime_2, "mime_2 mismatch")
	testing.expect_value(t, parsed.attachments[1].uploaded_at, uploaded_at_2)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_serialize_task_with_attachments :: proc(t: ^testing.T) {
	attachments := []Attachment {
		{
			file_id = transmute([]byte)string("01ARZ3NDEKTSV4RRFFQ69G5FAV"),
			filename = transmute([]byte)string("screenshot.png"),
			size = 245120,
			mime_type = transmute([]byte)string("image/png"),
			uploaded_at = 1735689600000000000,
		},
		{
			file_id = transmute([]byte)string("01ARZ3NDEKTSV4RRFFQ69G5FBW"),
			filename = transmute([]byte)string("document.pdf"),
			size = 512000,
			mime_type = transmute([]byte)string("application/pdf"),
			uploaded_at = 1735689700000000000,
		},
	}

	task := Task {
		id          = 42,
		conv_id     = 12345,
		title       = transmute([]byte)string("Task with attachments"),
		description = transmute([]byte)string("Has files"),
		status      = .Todo,
		order_index = 1,
		assignee    = transmute([]byte)string("alice"),
		priority    = 100,
		created_by  = transmute([]byte)string("bob"),
		created_at  = 1234567890,
		updated_at  = 1234567890,
		attachments = attachments,
	}

	msg := TaskCreated {
		task = task,
	}

	buf: [512]byte
	written := serializeTaskCreated(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskCreated(msg))

	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskCreated)
}

// ============================================================================
// Correlation ID Tests
// ============================================================================

@(test)
test_create_asset_request_with_correlation_id :: proc(t: ^testing.T) {
	buf: [256]byte
	offset := 0

	conv_id: ConversationID = 42
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2

	endian.put_u16(buf[offset:], .Big, u16(ParentType.None))
	offset += 2

	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8

	buf[offset] = u8(PayloadEncoding.Plain)
	offset += 1

	payload := "test payload"
	endian.put_u32(buf[offset:], .Big, u32(len(payload)))
	offset += 4

	preview := "test preview"
	endian.put_u16(buf[offset:], .Big, u16(len(preview)))
	offset += 2
	copy(buf[offset:], preview)
	offset += len(preview)

	endian.put_u16(buf[offset:], .Big, u16(len(payload)))
	offset += 2
	copy(buf[offset:], payload)
	offset += len(payload)

	endian.put_u16(buf[offset:], .Big, 0) // no attachments
	offset += 2

	// Append correlation_id
	corr_id: u32 = 12345
	endian.put_u32(buf[offset:], .Big, corr_id)
	offset += 4

	parsed, err := parseCreateAssetRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.asset_type, AssetType.Note)
	testing.expect_value(t, parsed.payload_encoding, PayloadEncoding.Plain)
	testing.expect_value(t, parsed.payload_raw_len, u32(len(payload)))
	testing.expect(t, string(parsed.preview) == preview, "preview mismatch")
	testing.expect(t, string(parsed.payload) == payload, "payload mismatch")
	testing.expect_value(t, parsed.correlation_id, corr_id)
}

@(test)
test_roundtrip_create_asset_request_with_attachments :: proc(t: ^testing.T) {
	file_id := "att_note_1"
	filename := "diagram.png"
	mime_type := "image/png"
	attachments := []Attachment {
		{
			file_id = transmute([]byte)file_id,
			filename = transmute([]byte)filename,
			size = 12345,
			mime_type = transmute([]byte)mime_type,
			uploaded_at = 987654321,
		},
	}
	req := CreateAssetRequest {
		conv_id          = 42,
		asset_type       = .Note,
		parent_type      = .None,
		payload_encoding = .Plain,
		payload_raw_len  = 7,
		preview          = transmute([]byte)string("preview"),
		payload          = transmute([]byte)string("payload"),
		attachments      = attachments,
		correlation_id   = 0x01020304,
	}

	buf := make([]byte, getSizeCreateAssetRequest(req))
	defer delete(buf)
	written := serializeCreateAssetRequest(req, buf)
	testing.expect_value(t, written, len(buf))
	parsed, err := parseCreateAssetRequest(buf[2:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, req.conv_id)
	testing.expect_value(t, parsed.asset_type, req.asset_type)
	testing.expect_value(t, parsed.correlation_id, req.correlation_id)
	testing.expect_value(t, len(parsed.attachments), 1)
	testing.expect(t, test_attachment_equal(parsed.attachments[0], attachments[0]), "create asset attachment mismatch")
}

@(test)
test_create_asset_payload_respects_u16_wire_limit :: proc(t: ^testing.T) {
	max_payload := make([]byte, MAX_PAYLOAD_LENGTH)
	defer delete(max_payload)
	max_req := CreateAssetRequest {
		asset_type       = .Note,
		parent_type      = .None,
		payload_encoding = .Plain,
		payload_raw_len  = u32(len(max_payload)),
		payload          = max_payload,
	}
	max_buf := make([]byte, getSizeCreateAssetRequest(max_req))
	defer delete(max_buf)
	max_written := serializeCreateAssetRequest(max_req, max_buf)
	testing.expect_value(t, max_written, len(max_buf))
	parsed, err := parseCreateAssetRequest(max_buf[2:max_written])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(parsed.payload), MAX_PAYLOAD_LENGTH)

	oversized_payload := make([]byte, MAX_PAYLOAD_LENGTH + 1)
	defer delete(oversized_payload)
	oversized_req := CreateAssetRequest {
		asset_type       = .Note,
		parent_type      = .None,
		payload_encoding = .Plain,
		payload_raw_len  = u32(len(oversized_payload)),
		payload          = oversized_payload,
	}
	oversized_buf := make([]byte, getSizeCreateAssetRequest(oversized_req))
	defer delete(oversized_buf)
	testing.expect_value(t, serializeCreateAssetRequest(oversized_req, oversized_buf), -1)
}

@(test)
test_roundtrip_update_asset_request_with_attachments :: proc(t: ^testing.T) {
	file_id := "att_note_2"
	filename := "notes.pdf"
	mime_type := "application/pdf"
	attachments := []Attachment {
		{file_id = transmute([]byte)file_id, filename = transmute([]byte)filename, size = 222, mime_type = transmute([]byte)mime_type, uploaded_at = 333},
	}
	req := UpdateAssetRequest {
		conv_id          = 42,
		asset_id         = 99,
		payload_encoding = .Plain,
		payload_raw_len  = 7,
		preview          = transmute([]byte)string("preview"),
		payload          = transmute([]byte)string("payload"),
		attachments      = attachments,
		correlation_id   = 0x05060708,
	}

	buf := make([]byte, getSizeUpdateAssetRequest(req))
	defer delete(buf)
	written := serializeUpdateAssetRequest(req, buf)
	testing.expect_value(t, written, len(buf))
	parsed, err := parseUpdateAssetRequest(buf[2:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, req.conv_id)
	testing.expect_value(t, parsed.asset_id, req.asset_id)
	testing.expect_value(t, parsed.correlation_id, req.correlation_id)
	testing.expect_value(t, len(parsed.attachments), 1)
	testing.expect(t, test_attachment_equal(parsed.attachments[0], attachments[0]), "update asset attachment mismatch")
}

test_write_asset_attachment_field :: proc(buf: []byte, offset: int, field_len: int, fill: byte) -> int {
	pos := offset
	endian.put_u16(buf[pos:], .Big, u16(field_len))
	pos += 2
	for i in 0 ..< field_len {
		buf[pos + i] = fill
	}
	return pos + field_len
}

test_build_create_asset_request_with_attachment_lengths :: proc(
	buf: []byte,
	attachment_count: int,
	file_id_len: int,
	filename_len: int,
	mime_type_len: int,
	include_correlation := true,
) -> int {
	offset := 0
	endian.put_u64(buf[offset:], .Big, 42)
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2
	endian.put_u16(buf[offset:], .Big, u16(ParentType.None))
	offset += 2
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8
	buf[offset] = u8(PayloadEncoding.Plain)
	offset += 1
	endian.put_u32(buf[offset:], .Big, 0)
	offset += 4
	endian.put_u16(buf[offset:], .Big, 0)
	offset += 2
	endian.put_u16(buf[offset:], .Big, 0)
	offset += 2
	endian.put_u16(buf[offset:], .Big, u16(attachment_count))
	offset += 2
	for _ in 0 ..< attachment_count {
		offset = test_write_asset_attachment_field(buf, offset, file_id_len, 'f')
		offset = test_write_asset_attachment_field(buf, offset, filename_len, 'n')
		endian.put_u64(buf[offset:], .Big, 1)
		offset += 8
		offset = test_write_asset_attachment_field(buf, offset, mime_type_len, 'm')
		endian.put_u64(buf[offset:], .Big, 2)
		offset += 8
	}
	if include_correlation {
		endian.put_u32(buf[offset:], .Big, 99)
		offset += 4
	}
	return offset
}

@(test)
test_parse_create_asset_request_rejects_invalid_attachment_metadata :: proc(t: ^testing.T) {
	buf := make([]byte, 4096)
	defer delete(buf)

	too_many_len := test_build_create_asset_request_with_attachment_lengths(buf, MAX_ATTACHMENTS_PER_TASK + 1, 0, 0, 0)
	_, err := parseCreateAssetRequest(buf[:too_many_len])
	testing.expect_value(t, err, ProtocolParseError.TooMany)

	file_id_len := test_build_create_asset_request_with_attachment_lengths(buf, 1, MAX_FILE_ID_LENGTH + 1, 0, 0)
	_, err = parseCreateAssetRequest(buf[:file_id_len])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthExceedsMax)

	filename_len := test_build_create_asset_request_with_attachment_lengths(buf, 1, MAX_FILE_ID_LENGTH, MAX_FILENAME_LENGTH + 1, 0)
	_, err = parseCreateAssetRequest(buf[:filename_len])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthExceedsMax)

	mime_len := test_build_create_asset_request_with_attachment_lengths(buf, 1, MAX_FILE_ID_LENGTH, 0, MAX_MIME_TYPE_LENGTH + 1)
	_, err = parseCreateAssetRequest(buf[:mime_len])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthExceedsMax)
}

@(test)
test_parse_create_asset_request_rejects_attachment_trailing_and_missing_bytes :: proc(t: ^testing.T) {
	buf := make([]byte, 512)
	defer delete(buf)

	valid_len := test_build_create_asset_request_with_attachment_lengths(buf, 1, 1, 1, 1)
	buf[valid_len] = 0xEE
	_, err := parseCreateAssetRequest(buf[:valid_len + 1])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	missing_corr_len := test_build_create_asset_request_with_attachment_lengths(buf, 1, 1, 1, 1, false)
	_, err = parseCreateAssetRequest(buf[:missing_corr_len])
	testing.expect_value(t, err, ProtocolParseError.TooShort)

	_, err = parseCreateAssetRequest(buf[:valid_len - 1])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_create_asset_request_without_correlation_id :: proc(t: ^testing.T) {
	buf: [256]byte
	offset := 0

	endian.put_u64(buf[offset:], .Big, u64(42))
	offset += 8
	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2
	endian.put_u16(buf[offset:], .Big, u16(ParentType.None))
	offset += 2
	endian.put_u64(buf[offset:], .Big, 0)
	offset += 8

	buf[offset] = u8(PayloadEncoding.Plain)
	offset += 1

	endian.put_u32(buf[offset:], .Big, 0)
	offset += 4

	preview := "p"
	endian.put_u16(buf[offset:], .Big, u16(len(preview)))
	offset += 2
	copy(buf[offset:], preview)
	offset += len(preview)

	endian.put_u16(buf[offset:], .Big, 0) // empty payload
	offset += 2

	_, err := parseCreateAssetRequest(buf[:offset])

	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_list_assets_paged_request_without_cursor :: proc(t: ^testing.T) {
	buf: [32]byte
	offset := 0

	conv_id: ConversationID = 42
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2

	buf[offset] = 0 // full_content
	offset += 1

	limit: u16 = 25
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2

	buf[offset] = 0 // has_cursor
	offset += 1

	correlation_id: u32 = 99
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseListAssetsPagedRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.asset_type, AssetType.Note)
	testing.expect_value(t, parsed.full_content, false)
	testing.expect_value(t, parsed.limit, limit)
	testing.expect_value(t, parsed.has_cursor, false)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_list_assets_paged_by_project_request :: proc(t: ^testing.T) {
	buf: [128]byte
	offset := 0

	conv_id: ConversationID = 42
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2

	buf[offset] = 1 // full_content
	offset += 1

	limit: u16 = 25
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2

	buf[offset] = 1 // has_cursor
	offset += 1

	cursor_updated_at: i64 = 123456789
	endian.put_u64(buf[offset:], .Big, u64(cursor_updated_at))
	offset += 8

	cursor_asset_id: AssetID = 987654321
	endian.put_u64(buf[offset:], .Big, u64(cursor_asset_id))
	offset += 8

	project := "nrc"
	endian.put_u16(buf[offset:], .Big, u16(len(project)))
	offset += 2
	copy(buf[offset:], project)
	offset += len(project)

	correlation_id: u32 = 77
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseListAssetsPagedByProjectRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.asset_type, AssetType.Note)
	testing.expect_value(t, parsed.full_content, true)
	testing.expect_value(t, parsed.limit, limit)
	testing.expect_value(t, parsed.has_cursor, true)
	testing.expect_value(t, parsed.cursor_updated_at, cursor_updated_at)
	testing.expect_value(t, parsed.cursor_asset_id, cursor_asset_id)
	testing.expect(t, parsed.project == project, "project mismatch")
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_list_assets_paged_by_tag_request_without_cursor :: proc(t: ^testing.T) {
	buf: [128]byte
	offset := 0

	conv_id: ConversationID = 43
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	endian.put_u16(buf[offset:], .Big, u16(AssetType.Note))
	offset += 2

	buf[offset] = 0 // full_content
	offset += 1

	limit: u16 = 50
	endian.put_u16(buf[offset:], .Big, limit)
	offset += 2

	buf[offset] = 0 // has_cursor
	offset += 1

	tag := "protocol"
	endian.put_u16(buf[offset:], .Big, u16(len(tag)))
	offset += 2
	copy(buf[offset:], tag)
	offset += len(tag)

	correlation_id: u32 = 78
	endian.put_u32(buf[offset:], .Big, correlation_id)
	offset += 4

	parsed, err := parseListAssetsPagedByTagRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.asset_type, AssetType.Note)
	testing.expect_value(t, parsed.full_content, false)
	testing.expect_value(t, parsed.limit, limit)
	testing.expect_value(t, parsed.has_cursor, false)
	testing.expect(t, parsed.tag == tag, "tag mismatch")
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_list_note_projects_request :: proc(t: ^testing.T) {
	buf: [12]byte
	conv_id: ConversationID = 44
	correlation_id: u32 = 79

	endian.put_u64(buf[0:], .Big, u64(conv_id))
	endian.put_u32(buf[8:], .Big, correlation_id)

	parsed, err := parseListNoteProjectsRequest(buf[:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_list_note_tags_request :: proc(t: ^testing.T) {
	buf: [12]byte
	conv_id: ConversationID = 45
	correlation_id: u32 = 80

	endian.put_u64(buf[0:], .Big, u64(conv_id))
	endian.put_u32(buf[8:], .Big, correlation_id)

	parsed, err := parseListNoteTagsRequest(buf[:])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect_value(t, parsed.correlation_id, correlation_id)
}

@(test)
test_parse_note_asset_list_requests_too_short :: proc(t: ^testing.T) {
	_, project_err := parseListAssetsPagedByProjectRequest([]byte{})
	testing.expect_value(t, project_err, ProtocolParseError.TooShort)

	_, tag_err := parseListAssetsPagedByTagRequest([]byte{})
	testing.expect_value(t, tag_err, ProtocolParseError.TooShort)

	_, projects_err := parseListNoteProjectsRequest([]byte{})
	testing.expect_value(t, projects_err, ProtocolParseError.TooShort)

	_, tags_err := parseListNoteTagsRequest([]byte{})
	testing.expect_value(t, tags_err, ProtocolParseError.TooShort)
}

@(test)
test_create_task_request_with_correlation_id :: proc(t: ^testing.T) {
	buf: [256]byte
	offset := 0

	conv_id: ConversationID = 99
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	title := "Fix bug"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	endian.put_u16(buf[offset:], .Big, 0) // empty desc
	offset += 2

	buf[offset] = 2 // priority
	offset += 1
	buf[offset] = u8(TaskColor.Red) // color
	offset += 1

	endian.put_u16(buf[offset:], .Big, 0) // empty ext ref
	offset += 2

	endian.put_u64(buf[offset:], .Big, 0) // due_at
	offset += 8

	endian.put_u16(buf[offset:], .Big, 0) // no attachments
	offset += 2

	buf[offset] = u8(TaskStatus.Todo) // status
	offset += 1

	// Append correlation_id
	corr_id: u32 = 67890
	endian.put_u32(buf[offset:], .Big, corr_id)
	offset += 4

	parsed, err := parseCreateTaskRequest(buf[:offset])

	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, conv_id)
	testing.expect(t, string(parsed.title) == title, "title mismatch")
	testing.expect_value(t, parsed.status, TaskStatus.Todo)
	testing.expect_value(t, parsed.correlation_id, corr_id)
}

@(test)
test_asset_created_message_roundtrip :: proc(t: ^testing.T) {
	asset := Asset {
		asset_type       = .Note,
		asset_id         = 777,
		parent_type      = .None,
		parent_id        = 0,
		owner            = transmute([]byte)string("alice"),
		created_at       = 1000,
		updated_at       = 1000,
		conv_id          = 42,
		payload_encoding = .Plain,
		payload_raw_len  = 4,
		preview          = transmute([]byte)string("prev"),
		payload          = transmute([]byte)string("data"),
	}

	msg := AssetCreatedMessage {
		asset          = asset,
		correlation_id = 55555,
	}

	buf: [256]byte
	written := serializeAssetCreatedMessage(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeAssetCreatedMessage(msg))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_AssetCreated)

	// Verify trailing correlation_id
	corr_id, _ := endian.get_u32(buf[written - 4:], .Big)
	testing.expect_value(t, corr_id, u32(55555))
}

@(test)
test_task_created_message_roundtrip :: proc(t: ^testing.T) {
	task := Task {
		id          = 42,
		conv_id     = 12345,
		title       = transmute([]byte)string("Test task"),
		description = transmute([]byte)string("Desc"),
		status      = .Todo,
		order_index = 1,
		priority    = 2,
		created_by  = transmute([]byte)string("bob"),
		created_at  = 1234567890,
		updated_at  = 1234567890,
	}

	msg := TaskCreated {
		task           = task,
		correlation_id = 99999,
	}

	buf: [512]byte
	written := serializeTaskCreated(msg, buf[:])

	testing.expect(t, written > 0, "serialization failed")
	testing.expect_value(t, written, getSizeTaskCreated(msg))

	// Verify opcode
	opcode_val, _ := endian.get_u16(buf[0:], .Big)
	testing.expect_value(t, Opcode(opcode_val), Opcode.S_TaskCreated)

	// Verify trailing correlation_id
	corr_id, _ := endian.get_u32(buf[written - 4:], .Big)
	testing.expect_value(t, corr_id, u32(99999))
}

@(test)
test_parse_create_task_too_short :: proc(t: ^testing.T) {
	buf: [5]byte
	_, err := parseCreateTaskRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_delete_task_too_short :: proc(t: ^testing.T) {
	buf: [4]byte
	_, err := parseDeleteTaskRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_move_task_too_short :: proc(t: ^testing.T) {
	buf: [8]byte
	_, err := parseMoveTaskRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_parse_move_task_refuses_unknown_flags :: proc(t: ^testing.T) {
	buf: [24]byte
	endian.put_u64(buf[0:], .Big, 1)
	endian.put_u64(buf[8:], .Big, 2)
	buf[16] = u8(TaskStatus.Todo)
	endian.put_u16(buf[18:], .Big, 4)
	endian.put_u32(buf[20:], .Big, 9)

	// A bit this build does not define: the move must not read as a named position
	// behind the server's back.
	buf[17] = 0x02
	_, unknown_err := parseMoveTaskRequest(buf[:])
	testing.expect_value(t, unknown_err, ProtocolParseError.InvalidValue)

	// The flag this build defines parses, and so does a named position.
	buf[17] = transmute(u8)MoveTaskFlag_APPEND
	append_req, append_err := parseMoveTaskRequest(buf[:])
	testing.expect(t, append_err == nil, "the append flag should parse")
	testing.expect(t, .Append in append_req.flags, "the append flag should survive the parse")
	testing.expect_value(t, append_req.order_index, u16(4))

	buf[17] = 0
	named_req, named_err := parseMoveTaskRequest(buf[:])
	testing.expect(t, named_err == nil, "a named position should parse")
	testing.expect(t, named_req.flags == MoveTaskFlags{}, "a named position carries no flags")
	testing.expect_value(t, named_req.order_index, u16(4))
}

@(test)
test_parse_get_tasks_too_short :: proc(t: ^testing.T) {
	buf: [4]byte
	_, err := parseGetTasksRequest(buf[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
}

@(test)
test_get_opcode_task_opcodes :: proc(t: ^testing.T) {
	buf: [2]byte

	endian.put_u16(buf[:], .Big, 20)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_CreateTask)

	endian.put_u16(buf[:], .Big, 21)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_UpdateTask)

	endian.put_u16(buf[:], .Big, 22)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_DeleteTask)

	endian.put_u16(buf[:], .Big, 23)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_MoveTask)

	endian.put_u16(buf[:], .Big, 24)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_GetTasks)

	endian.put_u16(buf[:], .Big, 130)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_TaskCreated)

	endian.put_u16(buf[:], .Big, 131)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_TaskUpdated)

	endian.put_u16(buf[:], .Big, 132)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_TaskDeleted)

	endian.put_u16(buf[:], .Big, 133)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_TaskMoved)

	endian.put_u16(buf[:], .Big, 134)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.S_TaskListResponse)
}

@(test)
test_parse_create_task_truncated_attachment_fails :: proc(t: ^testing.T) {
	buf: [128]byte
	offset := 0

	conv_id: ConversationID = 1
	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8

	title := "x"
	endian.put_u16(buf[offset:], .Big, u16(len(title)))
	offset += 2
	copy(buf[offset:], title)
	offset += len(title)

	endian.put_u16(buf[offset:], .Big, 0) // empty description
	offset += 2

	buf[offset] = 1 // priority
	offset += 1

	buf[offset] = u8(TaskColor.None)
	offset += 1

	endian.put_u16(buf[offset:], .Big, 0) // empty external_ref
	offset += 2

	endian.put_u64(buf[offset:], .Big, 0) // due_at
	offset += 8

	endian.put_u16(buf[offset:], .Big, 1) // one attachment
	offset += 2

	endian.put_u16(buf[offset:], .Big, 4) // file_id_len, but payload is truncated
	offset += 2
	copy(buf[offset:], "ab")
	offset += 2

	attachments: [MAX_ATTACHMENTS_PER_TASK]Attachment
	_, err := parseCreateTaskRequest(buf[:offset], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
}

@(test)
test_parse_server_ready_reads_username_and_auth_flag :: proc(t: ^testing.T) {
	buf: [256]byte
	offset := 0

	build := "dev-2026-03:abc1234"
	endian.put_u16(buf[offset:], .Big, u16(len(build)))
	offset += 2
	copy(buf[offset:], build)
	offset += len(build)

	endian.put_u32(buf[offset:], .Big, 1)
	offset += 4

	cpu := "cpu-x"
	endian.put_u16(buf[offset:], .Big, u16(len(cpu)))
	offset += 2
	copy(buf[offset:], cpu)
	offset += len(cpu)

	username := "rene"
	endian.put_u16(buf[offset:], .Big, u16(len(username)))
	offset += 2
	copy(buf[offset:], username)
	offset += len(username)

	buf[offset] = 1
	offset += 1

	parsed, err := parseServerReady(buf[:offset])
	testing.expect_value(t, err, nil)
	testing.expect(t, string(parsed.build_version) == build, "build_version mismatch")
	testing.expect(t, string(parsed.cpu_model) == cpu, "cpu_model mismatch")
	testing.expect(t, string(parsed.username) == username, "username mismatch")
	testing.expect_value(t, parsed.is_authenticated, true)
}

Protocol_Parse_Benchmark_State :: struct {
	payload:  []byte,
	conv_id:  ConversationID,
	checksum: u64,
	valid:    bool,
}

benchmark_protocol_parse_callback :: proc(options: ^time.Benchmark_Options, _: runtime.Allocator) -> time.Benchmark_Error {
	state := cast(^Protocol_Parse_Benchmark_State)options.user_data
	state.valid = true
	for i in 0 ..< options.rounds {
		endian.put_u32(state.payload[8:], .Big, u32(i))
		parsed, err := parseSendMessageRequest(state.payload)
		state.valid = state.valid && err == nil
		if err == nil {
			state.checksum += u64(parsed.client_req_id) + u64(parsed.conv_id) + u64(len(parsed.content))
		}
	}
	options.count = options.rounds
	options.processed = options.rounds * len(state.payload)
	options.hash = u128(state.checksum)
	return .Okay
}

@(test)
benchmark_parse_send_message_request :: proc(t: ^testing.T) {
	garbage, enabled := os.lookup_env_alloc("BENCH_PROTOCOL_PARSE", context.allocator)
	defer delete(garbage)
	if !enabled {
		return
	}

	buf: [1024]byte
	offset := 0
	conv_id: ConversationID = 12345678
	client_req_id: u32 = 42
	content_type := MessageContentType.Markdown
	content := "Protocol parse throughput benchmark payload"

	endian.put_u64(buf[offset:], .Big, u64(conv_id))
	offset += 8
	endian.put_u32(buf[offset:], .Big, client_req_id)
	offset += 4
	buf[offset] = u8(content_type)
	offset += 1
	endian.put_u16(buf[offset:], .Big, u16(len(content)))
	offset += 2
	copy(buf[offset:], content)
	offset += len(content)

	payload := buf[:offset]
	iterations := 125_000_000
	state := Protocol_Parse_Benchmark_State {
		payload = payload,
		conv_id = conv_id,
	}
	options := time.Benchmark_Options {
		bench     = benchmark_protocol_parse_callback,
		rounds    = iterations,
		user_data = &state,
	}
	bench_err := time.benchmark(&options)
	expected_checksum := u64(conv_id) * u64(iterations) + u64((iterations - 1) * iterations) / 2 + u64(len(content)) * u64(iterations)
	testing.expect_value(t, bench_err, time.Benchmark_Error.Okay)
	testing.expect(t, state.valid, "all parse operations must succeed")
	testing.expect_value(t, state.checksum, expected_checksum)
	ns_per_op := f64(time.duration_nanoseconds(options.duration)) / f64(options.count)
	log.infof("Parse SendMessage Request: %.2f ns/op, %.2f ops/s, %.2f MiB/s", ns_per_op, options.rounds_per_second, options.megabytes_per_second)
}

test_attachment_equal :: proc(a, b: Attachment) -> bool {
	return(
		bytes.equal(a.file_id, b.file_id) &&
		bytes.equal(a.filename, b.filename) &&
		a.size == b.size &&
		bytes.equal(a.mime_type, b.mime_type) &&
		a.uploaded_at == b.uploaded_at \
	)
}

test_task_equal :: proc(a, b: Task) -> bool {
	if !(a.id == b.id &&
		   a.conv_id == b.conv_id &&
		   bytes.equal(a.title, b.title) &&
		   bytes.equal(a.description, b.description) &&
		   a.status == b.status &&
		   a.order_index == b.order_index &&
		   bytes.equal(a.assignee, b.assignee) &&
		   a.priority == b.priority &&
		   a.color == b.color &&
		   bytes.equal(a.created_by, b.created_by) &&
		   a.created_at == b.created_at &&
		   a.updated_at == b.updated_at &&
		   bytes.equal(a.external_ref, b.external_ref) &&
		   a.due_at == b.due_at &&
		   a.blocked_by == b.blocked_by &&
		   a.completed_at == b.completed_at &&
		   bytes.equal(a.completed_by, b.completed_by) &&
		   len(a.attachments) == len(b.attachments)) {
		return false
	}
	for att, i in a.attachments {
		if !test_attachment_equal(att, b.attachments[i]) do return false
	}
	return true
}

test_edge_equal :: proc(a, b: Edge) -> bool {
	return(
		a.edge_id == b.edge_id &&
		a.conv_id == b.conv_id &&
		a.source_type == b.source_type &&
		a.source_id == b.source_id &&
		a.target_type == b.target_type &&
		a.target_id == b.target_id &&
		a.relation == b.relation &&
		a.created_at == b.created_at &&
		bytes.equal(a.created_by, b.created_by) \
	)
}

@(test)
test_parse_task_list_response_roundtrip_exact :: proc(t: ^testing.T) {
	att_file_id := [?]byte{'f', 'i', 'l', 'e', '-', '1'}
	att_filename := [?]byte{'d', 'e', 's', 'i', 'g', 'n', '.', 'p', 'n', 'g'}
	att_mime := [?]byte{'i', 'm', 'a', 'g', 'e', '/', 'p', 'n', 'g'}
	attachments := []Attachment{{file_id = att_file_id[:], filename = att_filename[:], size = 12345, mime_type = att_mime[:], uploaded_at = 987654321}}

	title_1 := [?]byte{'f', 'i', 'r', 's', 't'}
	desc_1 := [?]byte{'d', 'e', 's', 'c', '-', '1'}
	assignee_1 := [?]byte{'a', 'l', 'i', 'c', 'e'}
	created_by_1 := [?]byte{'b', 'o', 'b'}
	external_ref_1 := [?]byte{'N', 'R', 'C', '-', '1'}
	completed_by_1 := [?]byte{'c', 'a', 'r', 'o', 'l'}
	title_2 := [?]byte{'s', 'e', 'c', 'o', 'n', 'd'}
	desc_2 := [?]byte{'d', 'e', 's', 'c', '-', '2'}
	assignee_2 := [?]byte{'d', 'a', 'v', 'e'}
	created_by_2 := [?]byte{'e', 'r', 'i', 'n'}
	tasks := []Task {
		{
			id = 11,
			conv_id = 777,
			title = title_1[:],
			description = desc_1[:],
			status = .Done,
			order_index = 2,
			assignee = assignee_1[:],
			priority = 200,
			color = .Gold,
			created_by = created_by_1[:],
			created_at = 1001,
			updated_at = 1002,
			external_ref = external_ref_1[:],
			due_at = 2001,
			blocked_by = 9,
			completed_at = 3001,
			completed_by = completed_by_1[:],
			attachments = attachments,
		},
		{
			id = 12,
			conv_id = 777,
			title = title_2[:],
			description = desc_2[:],
			status = .InProgress,
			order_index = 3,
			assignee = assignee_2[:],
			priority = 100,
			color = .Cyan,
			created_by = created_by_2[:],
			created_at = 4001,
			updated_at = 4002,
		},
	}
	error_text := [?]byte{'w', 'a', 'r', 'n'}
	msg := TaskListResponse {
		conv_id        = 777,
		success        = true,
		tasks          = tasks,
		error          = error_text[:],
		correlation_id = 0xAABBCCDD,
	}

	buf: [1024]byte
	written := serializeTaskListResponse(msg, buf[:])
	testing.expect_value(t, written, getSizeTaskListResponse(msg))

	decoded_tasks: [2]Task
	decoded_attachments: [1]Attachment
	parsed, err := parseTaskListResponse(buf[:written], decoded_tasks[:], decoded_attachments[:])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, parsed.conv_id, msg.conv_id)
	testing.expect_value(t, parsed.success, msg.success)
	testing.expect(t, bytes.equal(parsed.error, msg.error), "task list error mismatch")
	testing.expect_value(t, parsed.correlation_id, msg.correlation_id)
	testing.expect_value(t, len(parsed.tasks), len(tasks))
	for task, i in parsed.tasks {
		testing.expectf(t, test_task_equal(task, tasks[i]), "task %d mismatch", i)
	}
}

@(test)
test_parse_edge_list_responses_roundtrip_exact :: proc(t: ^testing.T) {
	created_by_1 := [?]byte{'a', 'l', 'i', 'c', 'e'}
	created_by_2 := [?]byte{'b', 'o', 'b'}
	edges := []Edge {
		{
			edge_id = 1,
			conv_id = 88,
			source_type = .Task,
			source_id = 10,
			target_type = .Asset,
			target_id = 20,
			relation = .References,
			created_at = 100,
			created_by = created_by_1[:],
		},
		{
			edge_id = 2,
			conv_id = 88,
			source_type = .Asset,
			source_id = 30,
			target_type = .Task,
			target_id = 40,
			relation = .Blocks,
			created_at = 200,
			created_by = created_by_2[:],
		},
	}

	edge_list_msg := EdgeListMessage {
		conv_id        = 88,
		target_type    = .Task,
		target_id      = 10,
		edges          = edges,
		correlation_id = 55,
	}
	edge_buf: [512]byte
	edge_written := serializeEdgeListMessage(edge_list_msg, edge_buf[:])
	testing.expect_value(t, edge_written, getSizeEdgeListMessage(edge_list_msg))
	decoded_edges: [2]Edge
	parsed_edge_list, edge_err := parseEdgeListMessage(edge_buf[:edge_written], decoded_edges[:])
	testing.expect_value(t, edge_err, nil)
	testing.expect_value(t, parsed_edge_list.conv_id, edge_list_msg.conv_id)
	testing.expect_value(t, parsed_edge_list.target_type, edge_list_msg.target_type)
	testing.expect_value(t, parsed_edge_list.target_id, edge_list_msg.target_id)
	testing.expect_value(t, parsed_edge_list.correlation_id, edge_list_msg.correlation_id)
	testing.expect_value(t, len(parsed_edge_list.edges), len(edges))
	for edge, i in parsed_edge_list.edges {
		testing.expectf(t, test_edge_equal(edge, edges[i]), "edge list edge %d mismatch", i)
	}

	all_edge_msg := AllEdgeListMessage {
		conv_id        = 88,
		edges          = edges,
		correlation_id = 56,
	}
	all_edge_buf: [512]byte
	all_edge_written := serializeAllEdgeListMessage(all_edge_msg, all_edge_buf[:])
	testing.expect_value(t, all_edge_written, getSizeAllEdgeListMessage(all_edge_msg))
	parsed_all_edges, all_edge_err := parseAllEdgeListMessage(all_edge_buf[:all_edge_written], decoded_edges[:])
	testing.expect_value(t, all_edge_err, nil)
	testing.expect_value(t, parsed_all_edges.conv_id, all_edge_msg.conv_id)
	testing.expect_value(t, parsed_all_edges.correlation_id, all_edge_msg.correlation_id)
	testing.expect_value(t, len(parsed_all_edges.edges), len(edges))
	for edge, i in parsed_all_edges.edges {
		testing.expectf(t, test_edge_equal(edge, edges[i]), "all-edge list edge %d mismatch", i)
	}
}

@(test)
test_parse_promoted_response_parsers_malformed :: proc(t: ^testing.T) {
	tasks: [2]Task
	attachments: [2]Attachment
	edges: [2]Edge
	query_nodes: [2]GraphQueryNode
	path_nodes: [2]GraphPathNode
	degree_entries: [2]GraphDegreeEntry

	// Too short / wrong opcode both reject before payload decoding with distinct errors.
	_, err := parseTaskListResponse([]byte{}, tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.TooShort)
	wrong_task_opcode: [17]byte
	endian.put_u16(wrong_task_opcode[0:], .Big, u16(Opcode.S_EdgeList))
	_, err = parseTaskListResponse(wrong_task_opcode[:], tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)

	// Task count exceeds caller buffer.
	task_count_too_large: [17]byte
	endian.put_u16(task_count_too_large[0:], .Big, u16(Opcode.S_TaskListResponse))
	endian.put_u16(task_count_too_large[11:], .Big, 3)
	_, err = parseTaskListResponse(task_count_too_large[:], tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)

	// Missing correlation ID / trailing bytes are length mismatches after the variable fields.
	task_msg := TaskListResponse {
		conv_id        = 7,
		success        = true,
		tasks          = nil,
		error          = nil,
		correlation_id = 123,
	}
	task_buf: [32]byte
	task_len := serializeTaskListResponse(task_msg, task_buf[:])
	_, err = parseTaskListResponse(task_buf[:task_len - 1], tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	_, err = parseTaskListResponse(task_buf[:task_len + 1], tasks[:], attachments[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	edge_created_by := [?]byte{'u'}
	edge := Edge {
		edge_id     = 1,
		conv_id     = 7,
		source_type = .Task,
		source_id   = 11,
		target_type = .Asset,
		target_id   = 22,
		relation    = .References,
		created_at  = 33,
		created_by  = edge_created_by[:],
	}
	edge_msg := EdgeListMessage {
		conv_id        = 7,
		target_type    = .Task,
		target_id      = 11,
		edges          = []Edge{edge},
		correlation_id = 44,
	}
	edge_buf: [128]byte
	edge_len := serializeEdgeListMessage(edge_msg, edge_buf[:])
	wrong_edge_opcode := edge_buf
	endian.put_u16(wrong_edge_opcode[0:], .Big, u16(Opcode.S_TaskListResponse))
	_, err = parseEdgeListMessage(wrong_edge_opcode[:edge_len], edges[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)

	// Edge count exceeds caller buffer.
	_, err = parseEdgeListMessage(edge_buf[:edge_len], edges[:0])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	// Short edge payload / missing correlation ID.
	edge_payload_too_short: [30]byte
	endian.put_u16(edge_payload_too_short[0:], .Big, u16(Opcode.S_EdgeList))
	endian.put_u16(edge_payload_too_short[20:], .Big, 1)
	_, err = parseEdgeListMessage(edge_payload_too_short[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	_, err = parseEdgeListMessage(edge_buf[:edge_len - 3], edges[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	_, err = parseEdgeListMessage(edge_buf[:edge_len + 1], edges[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	all_edge_msg := AllEdgeListMessage {
		conv_id        = 7,
		edges          = []Edge{edge},
		correlation_id = 45,
	}
	all_edge_buf: [128]byte
	all_edge_len := serializeAllEdgeListMessage(all_edge_msg, all_edge_buf[:])
	wrong_all_edge_opcode := all_edge_buf
	endian.put_u16(wrong_all_edge_opcode[0:], .Big, u16(Opcode.S_EdgeList))
	_, err = parseAllEdgeListMessage(wrong_all_edge_opcode[:all_edge_len], edges[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)
	_, err = parseAllEdgeListMessage(all_edge_buf[:all_edge_len], edges[:0])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	_, err = parseAllEdgeListMessage(all_edge_buf[:all_edge_len - 3], edges[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	// Graph response buffers reject oversized counts before walking variable payloads.
	graph_count_too_large: [29]byte
	endian.put_u16(graph_count_too_large[0:], .Big, u16(Opcode.S_GraphQueryResult))
	endian.put_u16(graph_count_too_large[21:], .Big, 3)
	_, err = parseGraphQueryResult(graph_count_too_large[:], query_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	endian.put_u16(graph_count_too_large[0:], .Big, u16(Opcode.S_GraphDegreeResult))
	_, err = parseGraphQueryResult(graph_count_too_large[:], query_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)

	shortest_count_too_large: [40]byte
	endian.put_u16(shortest_count_too_large[0:], .Big, u16(Opcode.S_GraphShortestPathResult))
	endian.put_u16(shortest_count_too_large[32:], .Big, 3)
	_, err = parseGraphShortestPathResult(shortest_count_too_large[:], path_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	endian.put_u16(shortest_count_too_large[0:], .Big, u16(Opcode.S_GraphQueryResult))
	_, err = parseGraphShortestPathResult(shortest_count_too_large[:], path_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)

	degree_count_too_large: [16]byte
	endian.put_u16(degree_count_too_large[0:], .Big, u16(Opcode.S_GraphDegreeResult))
	endian.put_u16(degree_count_too_large[10:], .Big, 3)
	_, err = parseGraphDegreeResult(degree_count_too_large[:], degree_entries[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	endian.put_u16(degree_count_too_large[0:], .Big, u16(Opcode.S_GraphQueryResult))
	_, err = parseGraphDegreeResult(degree_count_too_large[:], degree_entries[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)

	common_count_too_large: [38]byte
	endian.put_u16(common_count_too_large[0:], .Big, u16(Opcode.S_GraphCommonNeighborsResult))
	endian.put_u16(common_count_too_large[30:], .Big, 3)
	_, err = parseGraphCommonNeighborsResult(common_count_too_large[:], path_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.TooMany)
	endian.put_u16(common_count_too_large[0:], .Big, u16(Opcode.S_GraphQueryResult))
	_, err = parseGraphCommonNeighborsResult(common_count_too_large[:], path_nodes[:], edges[:])
	testing.expect_value(t, err, ProtocolParseError.InvalidOpcode)
}
