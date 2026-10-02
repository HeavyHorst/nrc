package protocol

import "core:encoding/endian"
import "core:log"

// ============================================================================
// ServerReady - Initial handshake message
// ============================================================================

ServerReady :: struct {
	build_version:    []byte,
	protocol_version: u32,
	cpu_model:        []byte,
	username:         []byte,
	is_authenticated: bool,
}

getSizeServerReady :: proc(msg: ServerReady) -> int {
	// opcode(2) + build_ver_len(2) + build_ver + protocol_ver(4) + cpu_model_len(2) + cpu_model +
	// username_len(2) + username + is_authenticated(1)
	return 2 + 2 + len(msg.build_version) + 4 + 2 + len(msg.cpu_model) + 2 + len(msg.username) + 1
}

serializeServerReady :: proc(msg: ServerReady, buf: []byte) -> int {
	build_len := len(msg.build_version)
	cpu_len := len(msg.cpu_model)
	username_len := len(msg.username)

	if build_len > 65535 {
		log.errorf("Build version length %v exceeds maximum %v", build_len, 65535)
		return -1
	}
	if cpu_len > 65535 {
		log.errorf("CPU model length %v exceeds maximum %v", cpu_len, 65535)
		return -1
	}
	if username_len > MAX_USERNAME_LENGTH {
		log.errorf("Username length %v exceeds maximum %v", username_len, MAX_USERNAME_LENGTH)
		return -1
	}

	total_size := getSizeServerReady(msg)

	if len(buf) < total_size {
		log.errorf("Buffer too small for ServerReady. Need %v, got %v", total_size, len(buf))
		return -1
	}

	endian.put_u16(buf[0:2], .Big, u16(Opcode.S_ServerReady))

	payload := buf[2:]
	offset := 0

	endian.put_u16(payload[offset:], .Big, u16(build_len))
	offset += 2
	if build_len > 0 {
		copy(payload[offset:], msg.build_version)
		offset += build_len
	}

	endian.put_u32(payload[offset:], .Big, msg.protocol_version)
	offset += 4

	endian.put_u16(payload[offset:], .Big, u16(cpu_len))
	offset += 2
	if cpu_len > 0 {
		copy(payload[offset:], msg.cpu_model)
		offset += cpu_len
	}

	endian.put_u16(payload[offset:], .Big, u16(username_len))
	offset += 2
	if username_len > 0 {
		copy(payload[offset:], msg.username)
		offset += username_len
	}

	payload[offset] = msg.is_authenticated ? 1 : 0
	offset += 1

	return total_size
}

parseServerReadyMessage :: proc(data: []byte) -> (result: ServerReady, err: ProtocolParseError) {
	if len(data) < 2 {
		return {}, .TooShort
	}
	if get_opcode(data) != .S_ServerReady {
		return {}, .InvalidOpcode
	}

	payload := data[2:]
	offset := 0
	if len(payload) < offset + 2 {
		return {}, .TooShort
	}
	build_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	build_len := int(build_len_u16)
	offset += 2
	if len(payload) < offset + build_len + 4 + 2 {
		return {}, .ContentLengthMismatch
	}
	if build_len > 0 {
		result.build_version = payload[offset:offset + build_len]
	}
	offset += build_len

	result.protocol_version, _ = endian.get_u32(payload[offset:], .Big)
	offset += 4

	cpu_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	cpu_len := int(cpu_len_u16)
	offset += 2
	if len(payload) < offset + cpu_len + 2 {
		return {}, .ContentLengthMismatch
	}
	if cpu_len > 0 {
		result.cpu_model = payload[offset:offset + cpu_len]
	}
	offset += cpu_len

	username_len_u16, _ := endian.get_u16(payload[offset:], .Big)
	username_len := int(username_len_u16)
	if username_len > MAX_USERNAME_LENGTH {
		return {}, .ContentLengthExceedsMax
	}
	offset += 2
	if len(payload) < offset + username_len + 1 {
		return {}, .ContentLengthMismatch
	}
	if username_len > 0 {
		result.username = payload[offset:offset + username_len]
	}
	offset += username_len

	result.is_authenticated = payload[offset] == 1
	offset += 1
	if offset != len(payload) {
		return {}, .ContentLengthMismatch
	}

	return result, nil
}

// ============================================================================
// Opcode utilities
// ============================================================================

get_opcode :: proc(data: []byte) -> Opcode {
	if len(data) < 2 {
		return Opcode(0xFFFF)
	}
	status_code, _ := endian.get_u16(data, .Big)

	// Validate that the opcode is within known ranges
	// Client opcodes: 1-3, 8, 16-58
	// Server opcodes: 100, 102-111, 121-127, 130-147, 150-166
	if (status_code >= 1 && status_code <= 3) ||
	   status_code == 8 ||
	   (status_code >= 16 && status_code <= 19) ||
	   (status_code >= 20 && status_code <= 29) ||
	   (status_code >= 30 && status_code <= 39) ||
	   (status_code >= 40 && status_code <= 47) ||
	   (status_code >= 48 && status_code <= 58) ||
	   status_code == 100 ||
	   (status_code >= 102 && status_code <= 111) ||
	   (status_code >= 121 && status_code <= 127) ||
	   (status_code >= 130 && status_code <= 147) ||
	   (status_code >= 150 && status_code <= 166) {
		return Opcode(status_code)
	}

	return Opcode(0xFFFF)
}
