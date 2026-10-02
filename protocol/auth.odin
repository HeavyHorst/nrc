package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// Authentication
// ============================================================================

_AUTH_OFFSET_TOKEN_LEN :: 0
_AUTH_SIZE_TOKEN_LEN :: size_of(u16)
_AUTH_OFFSET_TOKEN :: _AUTH_OFFSET_TOKEN_LEN + _AUTH_SIZE_TOKEN_LEN
_AUTH_MIN_HEADER_SIZE :: _AUTH_OFFSET_TOKEN

AuthenticateRequest :: struct {
	token: []byte,
}

AuthenticateResponse :: struct {
	success:   bool,
	user_id:   []byte,
	nickname:  []byte,
	error_msg: []byte,
}

parseAuthenticateRequest :: proc(data: []byte) -> (AuthenticateRequest, ProtocolParseError) {
	result := AuthenticateRequest{}

	if len(data) < _AUTH_MIN_HEADER_SIZE {
		log.debugf("AuthenticateRequest payload too short for header. Need %v, got %v", _AUTH_MIN_HEADER_SIZE, len(data))
		return result, .TooShort
	}

	token_len_u16, _ := endian.get_u16(data[_AUTH_OFFSET_TOKEN_LEN:], .Big)
	token_len := int(token_len_u16)

	if token_len > MAX_TOKEN_LENGTH {
		log.debugf("Token length %v exceeds maximum %v", token_len, MAX_TOKEN_LENGTH)
		return result, .ContentLengthExceedsMax
	}

	required_total_len := _AUTH_OFFSET_TOKEN + token_len
	if len(data) < required_total_len {
		log.debugf("AuthenticateRequest payload too short for token. Need %v, got %v", required_total_len, len(data))
		return result, .ContentLengthMismatch
	}

	if token_len > 0 {
		result.token = data[_AUTH_OFFSET_TOKEN:_AUTH_OFFSET_TOKEN + token_len]
	}

	return result, nil
}

getSizeAuthenticateResponse :: proc(msg: AuthenticateResponse) -> int {
	// opcode(2) + success(1) + user_id_len(2) + user_id + nickname_len(2) + nickname + error_msg_len(2) + error_msg
	return 2 + 1 + 2 + len(msg.user_id) + 2 + len(msg.nickname) + 2 + len(msg.error_msg)
}


serializeAuthenticateResponse :: proc(msg: AuthenticateResponse, buf: []byte) -> int {
	user_id_len := len(msg.user_id)
	nickname_len := len(msg.nickname)
	error_msg_len := len(msg.error_msg)

	if user_id_len > MAX_USER_ID_LENGTH {
		log.errorf("User ID length %v exceeds maximum %v", user_id_len, MAX_USER_ID_LENGTH)
		return -1
	}
	if nickname_len > MAX_NICKNAME_LENGTH {
		log.errorf("Nickname length %v exceeds maximum %v", nickname_len, MAX_NICKNAME_LENGTH)
		return -1
	}

	total_size := getSizeAuthenticateResponse(msg)

	if len(buf) < total_size {
		log.errorf("Buffer too small for AuthenticateResponse. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_AuthResponse))

	payload := buf[2:]
	offset := 0

	payload[offset] = msg.success ? 1 : 0
	offset += 1

	endian.put_u16(payload[offset:], .Big, u16(user_id_len))
	offset += 2
	if user_id_len > 0 {
		copy(payload[offset:], msg.user_id)
		offset += user_id_len
	}

	endian.put_u16(payload[offset:], .Big, u16(nickname_len))
	offset += 2
	if nickname_len > 0 {
		copy(payload[offset:], msg.nickname)
		offset += nickname_len
	}

	endian.put_u16(payload[offset:], .Big, u16(error_msg_len))
	offset += 2
	if error_msg_len > 0 {
		copy(payload[offset:], msg.error_msg)
		offset += error_msg_len
	}

	return total_size
}

parseAuthenticateResponseMessage :: proc(data: []byte) -> (result: AuthenticateResponse, err: ProtocolParseError) {
	if len(data) < 2 {
		return {}, .TooShort
	}
	if get_opcode(data) != .S_AuthResponse {
		return {}, .InvalidOpcode
	}

	payload := data[2:]
	offset := 0
	if len(payload) < offset + 1 + 2 {
		return {}, .TooShort
	}
	result.success = payload[offset] == 1
	offset += 1

	user_id_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	user_id_len := int(user_id_len_u16)
	if user_id_len > MAX_USER_ID_LENGTH {
		return {}, .ContentLengthExceedsMax
	}
	offset += 2
	if len(payload) < offset + user_id_len + 2 {
		return {}, .ContentLengthMismatch
	}
	if user_id_len > 0 {
		result.user_id = payload[offset:offset + user_id_len]
	}
	offset += user_id_len

	nickname_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	nickname_len := int(nickname_len_u16)
	if nickname_len > MAX_NICKNAME_LENGTH {
		return {}, .ContentLengthExceedsMax
	}
	offset += 2
	if len(payload) < offset + nickname_len + 2 {
		return {}, .ContentLengthMismatch
	}
	if nickname_len > 0 {
		result.nickname = payload[offset:offset + nickname_len]
	}
	offset += nickname_len

	error_msg_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	error_msg_len := int(error_msg_len_u16)
	offset += 2
	if len(payload) < offset + error_msg_len {
		return {}, .ContentLengthMismatch
	}
	if error_msg_len > 0 {
		result.error_msg = payload[offset:offset + error_msg_len]
	}
	offset += error_msg_len
	if offset != len(payload) {
		return {}, .ContentLengthMismatch
	}

	return result, nil
}
