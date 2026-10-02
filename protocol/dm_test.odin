package protocol

import "core:testing"

@(test)
test_dm_conversation_id_symmetric :: proc(t: ^testing.T) {
	id1 := make_dm_conversation_id("alice", "bob")
	id2 := make_dm_conversation_id("bob", "alice")
	testing.expect(t, id1 == id2, "DM conversation ID should be the same regardless of user order")
}

@(test)
test_dm_conversation_id_has_flag :: proc(t: ^testing.T) {
	id := make_dm_conversation_id("alice", "bob")
	testing.expect(t, is_dm_conversation(id), "DM conversation ID should have DM flag set")
}

@(test)
test_dm_conversation_id_different_pairs :: proc(t: ^testing.T) {
	id1 := make_dm_conversation_id("alice", "bob")
	id2 := make_dm_conversation_id("alice", "charlie")
	testing.expect(t, id1 != id2, "Different user pairs should have different DM conversation IDs")
}

@(test)
test_regular_conversation_id_no_dm_flag :: proc(t: ^testing.T) {
	regular_id: ConversationID = 12345
	testing.expect(t, !is_dm_conversation(regular_id), "Regular conversation ID should not have DM flag")
}

@(test)
test_dm_conversation_id_null_separator :: proc(t: ^testing.T) {
	id1 := make_dm_conversation_id("ab", "c")
	id2 := make_dm_conversation_id("a", "bc")
	testing.expect(t, id1 != id2, "Null separator should prevent collisions between similar pairs")
}

@(test)
test_parse_start_dm_request :: proc(t: ^testing.T) {
	data: [14]u8
	data[0] = 0
	data[1] = 5
	alice :: "alice"
	copy(data[2:], alice)
	data[7] = 0x01
	data[8] = 0x02
	data[9] = 0x03
	data[10] = 0x04

	req, err := parseStartDMRequest(data[:11])
	testing.expect(t, err == nil, "Should parse valid StartDMRequest")
	testing.expect(t, req.username == "alice", "Username should be alice")
	testing.expect(t, req.correlation_id == 0x01020304, "Correlation should match")
}

@(test)
test_parse_start_dm_request_too_short :: proc(t: ^testing.T) {
	data: [1]u8
	_, err := parseStartDMRequest(data[:])
	testing.expect(t, err == .TooShort, "Should fail with TooShort for short data")
}

@(test)
test_parse_leave_dm_request :: proc(t: ^testing.T) {
	data: [12]u8
	data[0] = 0x80
	data[7] = 0x01
	data[8] = 0x11
	data[9] = 0x22
	data[10] = 0x33
	data[11] = 0x44

	req, err := parseLeaveDMRequest(data[:])
	testing.expect(t, err == nil, "Should parse valid LeaveDMRequest")
	testing.expect(t, is_dm_conversation(req.conv_id), "Parsed conv_id should be a DM conversation")
	testing.expect(t, req.correlation_id == 0x11223344, "Correlation should match")
}

@(test)
test_parse_list_dms_request_requires_correlation :: proc(t: ^testing.T) {
	_, err := parseListDMsRequest([]u8{})
	testing.expect(t, err == .TooShort, "ListDMs should require correlation_id")

	req, err_ok := parseListDMsRequest([]u8{0xAA, 0xBB, 0xCC, 0xDD})
	testing.expect(t, err_ok == nil, "ListDMs should parse with correlation_id")
	testing.expect(t, req.correlation_id == 0xAABBCCDD, "Correlation should match")
}

@(test)
test_dm_started_size :: proc(t: ^testing.T) {
	size := dm_started_size("alice")
	testing.expect(t, size == 2 + 8 + 2 + 5 + 1 + 1 + 1 + 4, "Size should match expected")
}

@(test)
test_dm_entry_size :: proc(t: ^testing.T) {
	size := dm_entry_size("bob")
	testing.expect(t, size == 8 + 2 + 3 + 1 + 1 + 8, "Size should match expected")
}

@(test)
test_write_dm_started :: proc(t: ^testing.T) {
	buf: [24]u8
	username := "bob"
	conv_id := make_dm_conversation_id("alice", "bob")

	write_dm_started(buf[:], conv_id, username, true, false, true)

	testing.expect(t, buf[0] == 0 && buf[1] == u8(Opcode.S_DMStarted), "Opcode should be S_DMStarted")
	testing.expect(t, buf[12 + len(username)] == 1, "Authenticated should be 1")
	testing.expect(t, buf[12 + len(username) + 1] == 0, "Online should be 0")
	testing.expect(t, buf[12 + len(username) + 2] == 1, "IsInitiator should be 1")
}
