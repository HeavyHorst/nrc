package protocol

import "core:encoding/endian"
import "core:testing"

@(test)
test_list_history_request_scope_filter_and_limits :: proc(t: ^testing.T) {
	data: [31]byte
	write :: proc(data: []byte, scope: ConversationID, kind: u8, entity: u64, limit: u16, correlation: u32) {
		endian.put_u64(data[0:], .Big, u64(scope))
		data[8] = kind
		endian.put_u64(data[9:], .Big, entity)
		endian.put_u64(data[17:], .Big, 100)
		endian.put_u16(data[25:], .Big, limit)
		endian.put_u32(data[27:], .Big, correlation)
	}

	// Kind 0 selects every entity type and must not carry an entity id.
	write(data[:], WORKSPACE_DATA_ID, 0, 0, 1, 7)
	req, err := parseListHistoryRequest(data[:])
	testing.expect_value(t, err, ProtocolParseError.None)
	testing.expect_value(t, req.conv_id, WORKSPACE_DATA_ID)
	testing.expect_value(t, req.kind, u8(0))
	testing.expect_value(t, req.before, u64(100))
	testing.expect_value(t, req.limit, u16(1))
	testing.expect_value(t, req.correlation_id, u32(7))

	write(data[:], WORKSPACE_DATA_ID, MAX_HISTORY_KIND, 9, MAX_HISTORY_PAGE_SIZE, 8)
	_, err = parseListHistoryRequest(data[:])
	testing.expect_value(t, err, ProtocolParseError.None)

	// A scope other than the workspace-data id is a malformed request.
	write(data[:], WORKSPACE_DATA_ID + 1, 1, 9, 10, 11)
	req, err = parseListHistoryRequest(data[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)
	// The correlation id still comes back so the error response can echo it.
	testing.expect_value(t, req.correlation_id, u32(11))

	// Filter and limit bounds.
	invalid := [?]struct {
		kind:   u8,
		entity: u64,
		limit:  u16,
	} {
		{0, 1, 10}, // kind 0 with an entity id
		{1, 0, 10}, // kind without an entity id
		{MAX_HISTORY_KIND + 1, 9, 10},
		{1, 9, 0},
		{1, 9, MAX_HISTORY_PAGE_SIZE + 1},
	}
	for entry in invalid {
		write(data[:], WORKSPACE_DATA_ID, entry.kind, entry.entity, entry.limit, 12)
		_, err = parseListHistoryRequest(data[:])
		testing.expect_value(t, err, ProtocolParseError.InvalidValue)
	}

	// Length bounds. A short body cannot carry a correlation id.
	for n in 0 ..< LIST_HISTORY_REQUEST_SIZE {
		_, err = parseListHistoryRequest(data[:n])
		testing.expect_value(t, err, ProtocolParseError.TooShort)
	}
	extra: [32]byte
	copy(extra[:], data[:])
	_, err = parseListHistoryRequest(extra[:])
	testing.expect_value(t, err, ProtocolParseError.ContentLengthMismatch)

	buf: [2]byte
	endian.put_u16(buf[:], .Big, 62)
	testing.expect_value(t, get_opcode(buf[:]), Opcode.C_ListHistory)
}
