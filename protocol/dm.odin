package protocol

import "core:encoding/endian"
import "core:hash/xxhash"

DM_CONV_FLAG :: 0x8000_0000_0000_0000

DM_Error_Code :: enum u8 {
	User_Not_Found    = 1,
	Cannot_DM_Self    = 2,
	DM_Not_Found      = 3,
	Not_Authenticated = 4,
}

StartDMRequest :: struct {
	username:       string,
	correlation_id: u32, // Client-generated, echoed in DM responses for request/response correlation
}

ListDMsRequest :: struct {
	correlation_id: u32, // Client-generated, echoed in S_DMList for request/response correlation
}

LeaveDMRequest :: struct {
	conv_id:        ConversationID,
	correlation_id: u32, // Client-generated, echoed in S_DMLeft/S_DMError for request/response correlation
}

DMEntry :: struct {
	conv_id:       ConversationID,
	username:      string,
	authenticated: bool,
	online:        bool,
	last_seen:     u64,
}

DMStartedMessage :: struct {
	conv_id:        ConversationID,
	username:       string,
	authenticated:  bool,
	online:         bool,
	is_initiator:   bool,
	correlation_id: u32,
}

DMListMessage :: struct {
	entries:        []DMEntry,
	correlation_id: u32,
}

DMErrorMessage :: struct {
	code:            DM_Error_Code,
	target_username: string,
	message:         string,
	correlation_id:  u32,
}

DMLeftMessage :: struct {
	conv_id:        ConversationID,
	correlation_id: u32,
}

DMPartnerStatusMessage :: struct {
	conv_id:   ConversationID,
	online:    bool,
	username:  string,
	last_seen: u64,
}

is_dm_conversation :: proc(conv_id: ConversationID) -> bool {
	return (conv_id & DM_CONV_FLAG) != 0
}

make_dm_conversation_id :: proc(user_a: string, user_b: string) -> ConversationID {
	a, b := user_a, user_b
	if a > b {
		a, b = b, a
	}

	key_len := len(a) + 1 + len(b)
	key_buf: [512]u8
	key := key_buf[:key_len]
	copy(key[:len(a)], transmute([]u8)a)
	key[len(a)] = 0
	copy(key[len(a) + 1:], transmute([]u8)b)

	h := xxhash.XXH64(key)
	return h | DM_CONV_FLAG
}

parseStartDMRequest :: proc(data: []byte) -> (StartDMRequest, ProtocolParseError) {
	if len(data) < 2 {
		return {}, .TooShort
	}
	username_len, ok := endian.get_u16(data[:2], .Big)
	if !ok {
		return {}, .TooShort
	}
	if len(data) < 2 + int(username_len) {
		return {}, .TooShort
	}
	if username_len > MAX_NICKNAME_LENGTH {
		return {}, .ContentLengthExceedsMax
	}
	result := StartDMRequest {
		username = string(data[2:2 + username_len]),
	}
	offset := 2 + int(username_len)
	if len(data) < offset + 4 {
		return {}, .TooShort
	}
	if len(data) != offset + 4 {
		return {}, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[offset:], .Big)
	return result, nil
}

parseListDMsRequest :: proc(data: []byte) -> (ListDMsRequest, ProtocolParseError) {
	result := ListDMsRequest{}
	if len(data) < 4 {
		return result, .TooShort
	}
	if len(data) != 4 {
		return result, .ContentLengthMismatch
	}
	result.correlation_id, _ = endian.get_u32(data[:4], .Big)
	return result, nil
}

parseLeaveDMRequest :: proc(data: []byte) -> (LeaveDMRequest, ProtocolParseError) {
	if len(data) < 8 {
		return {}, .TooShort
	}
	if len(data) != 12 {
		if len(data) < 12 {
			return {}, .TooShort
		}
		return {}, .ContentLengthMismatch
	}
	conv_id, ok := endian.get_u64(data[:8], .Big)
	if !ok {
		return {}, .TooShort
	}
	result := LeaveDMRequest {
		conv_id = conv_id,
	}
	result.correlation_id, _ = endian.get_u32(data[8:], .Big)
	return result, nil
}

dm_started_size :: proc(username: string) -> int {
	return 2 + 8 + 2 + len(username) + 1 + 1 + 1 + 4
}

write_dm_started :: proc(
	buf: []u8,
	conv_id: ConversationID,
	username: string,
	authenticated: bool,
	online: bool,
	is_initiator: bool,
	correlation_id: u32 = 0,
) {
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_DMStarted))
	endian.put_u64(buf[2:10], .Big, conv_id)
	endian.put_u16(buf[10:12], .Big, u16(len(username)))
	copy(buf[12:12 + len(username)], transmute([]u8)username)
	offset := 12 + len(username)
	buf[offset] = authenticated ? 1 : 0
	buf[offset + 1] = online ? 1 : 0
	buf[offset + 2] = is_initiator ? 1 : 0
	endian.put_u32(buf[offset + 3:offset + 7], .Big, correlation_id)
}

dm_list_header_size :: proc() -> int {
	return 2 + 2 + 4
}

dm_entry_size :: proc(username: string) -> int {
	return 8 + 2 + len(username) + 1 + 1 + 8
}

write_dm_list_header :: proc(buf: []u8, count: u16, correlation_id: u32 = 0) {
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_DMList))
	endian.put_u16(buf[2:4], .Big, count)
	endian.put_u32(buf[4:8], .Big, correlation_id)
}

write_dm_entry :: proc(buf: []u8, entry: DMEntry) -> int {
	endian.put_u64(buf[0:8], .Big, entry.conv_id)
	endian.put_u16(buf[8:10], .Big, u16(len(entry.username)))
	copy(buf[10:10 + len(entry.username)], transmute([]u8)entry.username)
	offset := 10 + len(entry.username)
	buf[offset] = entry.authenticated ? 1 : 0
	buf[offset + 1] = entry.online ? 1 : 0
	endian.put_u64(buf[offset + 2:offset + 10], .Big, entry.last_seen)
	return offset + 10
}

dm_error_size :: proc(target_username: string, message: string) -> int {
	return 2 + 1 + 2 + len(target_username) + 2 + len(message) + 4
}

write_dm_error :: proc(buf: []u8, code: DM_Error_Code, target_username: string, message: string, correlation_id: u32 = 0) {
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_DMError))
	buf[2] = u8(code)
	endian.put_u16(buf[3:5], .Big, u16(len(target_username)))
	copy(buf[5:5 + len(target_username)], transmute([]u8)target_username)
	offset := 5 + len(target_username)
	endian.put_u16(buf[offset:offset + 2], .Big, u16(len(message)))
	copy(buf[offset + 2:offset + 2 + len(message)], transmute([]u8)message)
	offset += 2 + len(message)
	endian.put_u32(buf[offset:offset + 4], .Big, correlation_id)
}

dm_left_size :: proc() -> int {
	return 2 + 8 + 4
}

write_dm_left :: proc(buf: []u8, conv_id: ConversationID, correlation_id: u32 = 0) {
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_DMLeft))
	endian.put_u64(buf[2:10], .Big, conv_id)
	endian.put_u32(buf[10:14], .Big, correlation_id)
}

dm_partner_status_size :: proc(username: string) -> int {
	return 2 + 8 + 1 + 2 + len(username) + 8
}

write_dm_partner_status :: proc(buf: []u8, conv_id: ConversationID, online: bool, username: string, last_seen: u64) {
	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_DMPartnerStatus))
	endian.put_u64(buf[2:10], .Big, conv_id)
	buf[10] = online ? 1 : 0
	endian.put_u16(buf[11:13], .Big, u16(len(username)))
	copy(buf[13:13 + len(username)], transmute([]u8)username)
	offset := 13 + len(username)
	endian.put_u64(buf[offset:offset + 8], .Big, last_seen)
}

parseDMStartedMessage :: proc(data: []byte) -> (result: DMStartedMessage, err: ProtocolParseError) {
	if len(data) < 2 + 8 + 2 do return result, .TooShort
	if get_opcode(data) != .S_DMStarted do return result, .InvalidOpcode

	conv_id, conv_ok := endian.get_u64(data[2:], .Big)
	username_len_raw, username_ok := endian.get_u16(data[10:], .Big)
	if !conv_ok || !username_ok do return result, .TooShort
	username_len := int(username_len_raw)
	if username_len > MAX_NICKNAME_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) < 12 + username_len + 1 + 1 + 1 + 4 do return result, .ContentLengthMismatch
	if len(data) != 12 + username_len + 1 + 1 + 1 + 4 do return result, .ContentLengthMismatch

	offset := 12 + username_len
	correlation_id, correlation_ok := endian.get_u32(data[offset + 3:], .Big)
	if !correlation_ok do return result, .TooShort
	result = DMStartedMessage {
		conv_id        = ConversationID(conv_id),
		username       = string(data[12:12 + username_len]),
		authenticated  = data[offset] == 1,
		online         = data[offset + 1] == 1,
		is_initiator   = data[offset + 2] == 1,
		correlation_id = correlation_id,
	}
	return result, nil
}

parseDMListMessage :: proc(data: []byte, entries: []DMEntry) -> (result: DMListMessage, err: ProtocolParseError) {
	if len(data) < dm_list_header_size() do return result, .TooShort
	if get_opcode(data) != .S_DMList do return result, .InvalidOpcode

	count_raw, count_ok := endian.get_u16(data[2:], .Big)
	correlation_id, correlation_ok := endian.get_u32(data[4:], .Big)
	if !count_ok || !correlation_ok do return result, .TooShort
	if int(count_raw) > len(entries) do return result, .TooMany

	result.entries = entries[:count_raw]
	result.correlation_id = correlation_id
	offset := dm_list_header_size()
	for i := 0; i < int(count_raw); i += 1 {
		if len(data) < offset + 8 + 2 do return result, .ContentLengthMismatch
		conv_id, conv_ok := endian.get_u64(data[offset:], .Big)
		username_len_raw, username_ok := endian.get_u16(data[offset + 8:], .Big)
		if !conv_ok || !username_ok do return result, .TooShort
		username_len := int(username_len_raw)
		if username_len > MAX_NICKNAME_LENGTH do return result, .ContentLengthExceedsMax
		if len(data) < offset + 8 + 2 + username_len + 1 + 1 + 8 do return result, .ContentLengthMismatch
		field_offset := offset + 8 + 2 + username_len
		last_seen, last_seen_ok := endian.get_u64(data[field_offset + 2:], .Big)
		if !last_seen_ok do return result, .TooShort
		entries[i] = DMEntry {
			conv_id       = ConversationID(conv_id),
			username      = string(data[offset + 10:offset + 10 + username_len]),
			authenticated = data[field_offset] == 1,
			online        = data[field_offset + 1] == 1,
			last_seen     = last_seen,
		}
		offset = field_offset + 2 + 8
	}
	if offset != len(data) do return result, .ContentLengthMismatch
	return result, nil
}

parseDMErrorMessage :: proc(data: []byte) -> (result: DMErrorMessage, err: ProtocolParseError) {
	if len(data) < 2 + 1 + 2 do return result, .TooShort
	if get_opcode(data) != .S_DMError do return result, .InvalidOpcode

	target_len_raw, target_ok := endian.get_u16(data[3:], .Big)
	if !target_ok do return result, .TooShort
	target_len := int(target_len_raw)
	if target_len > MAX_NICKNAME_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) < 5 + target_len + 2 do return result, .ContentLengthMismatch
	message_len_raw, message_ok := endian.get_u16(data[5 + target_len:], .Big)
	if !message_ok do return result, .TooShort
	message_len := int(message_len_raw)
	offset := 5 + target_len + 2
	if len(data) < offset + message_len + 4 do return result, .ContentLengthMismatch
	if len(data) != offset + message_len + 4 do return result, .ContentLengthMismatch
	correlation_id, correlation_ok := endian.get_u32(data[offset + message_len:], .Big)
	if !correlation_ok do return result, .TooShort
	result = DMErrorMessage {
		code            = DM_Error_Code(data[2]),
		target_username = string(data[5:5 + target_len]),
		message         = string(data[offset:offset + message_len]),
		correlation_id  = correlation_id,
	}
	return result, nil
}

parseDMLeftMessage :: proc(data: []byte) -> (result: DMLeftMessage, err: ProtocolParseError) {
	if len(data) < dm_left_size() do return result, .TooShort
	if get_opcode(data) != .S_DMLeft do return result, .InvalidOpcode
	if len(data) != dm_left_size() do return result, .ContentLengthMismatch
	conv_id, conv_ok := endian.get_u64(data[2:], .Big)
	correlation_id, correlation_ok := endian.get_u32(data[10:], .Big)
	if !conv_ok || !correlation_ok do return result, .TooShort
	result = DMLeftMessage {
		conv_id        = ConversationID(conv_id),
		correlation_id = correlation_id,
	}
	return result, nil
}

parseDMPartnerStatusMessage :: proc(data: []byte) -> (result: DMPartnerStatusMessage, err: ProtocolParseError) {
	if len(data) < 2 + 8 + 1 + 2 do return result, .TooShort
	if get_opcode(data) != .S_DMPartnerStatus do return result, .InvalidOpcode
	conv_id, conv_ok := endian.get_u64(data[2:], .Big)
	username_len_raw, username_ok := endian.get_u16(data[11:], .Big)
	if !conv_ok || !username_ok do return result, .TooShort
	username_len := int(username_len_raw)
	if username_len > MAX_NICKNAME_LENGTH do return result, .ContentLengthExceedsMax
	if len(data) < 13 + username_len + 8 do return result, .ContentLengthMismatch
	if len(data) != 13 + username_len + 8 do return result, .ContentLengthMismatch
	last_seen, last_seen_ok := endian.get_u64(data[13 + username_len:], .Big)
	if !last_seen_ok do return result, .TooShort
	result = DMPartnerStatusMessage {
		conv_id   = ConversationID(conv_id),
		online    = data[10] == 1,
		username  = string(data[13:13 + username_len]),
		last_seen = last_seen,
	}
	return result, nil
}
