package main

import "core:fmt"
import "core:hash/xxhash"

import pr "protocol"

DEFAULT_ROOM_ID :: pr.ConversationID(2)
ENGINEERING_ROOM_ID :: pr.ConversationID(2)
OPERATIONS_ROOM_ID :: pr.ConversationID(3)
SYSTEM_ROOM_ID :: pr.ConversationID(7)
MAX_ROOM_MAPPING_NAME_LENGTH :: 32

normalize_room_mapping_name :: proc(raw: []byte, out: []byte) -> (name: string, ok: bool) {
	if len(out) < MAX_ROOM_MAPPING_NAME_LENGTH {
		return "", false
	}

	start := 0
	end := len(raw)
	for start < end && raw[start] <= ' ' {
		start += 1
	}
	for end > start && raw[end - 1] <= ' ' {
		end -= 1
	}
	if start < end && raw[start] == '#' {
		start += 1
	}

	count := 0
	for i in start ..< end {
		b := raw[i]
		if b >= 'a' && b <= 'z' {
			b -= 'a' - 'A'
		}

		is_valid := (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9') || b == '_' || b == '-'
		if !is_valid {
			return "", false
		}
		if count >= MAX_ROOM_MAPPING_NAME_LENGTH {
			return "", false
		}

		out[count] = b
		count += 1
	}

	if count == 0 {
		return "", false
	}

	return string(out[:count]), true
}

builtin_room_id_for_name :: proc(name: string) -> (pr.ConversationID, bool) {
	switch name {
	case "ENGINEERING":
		return ENGINEERING_ROOM_ID, true
	case "OPERATIONS":
		return OPERATIONS_ROOM_ID, true
	case "SYSTEM":
		return SYSTEM_ROOM_ID, true
	}

	return 0, false
}

is_reserved_room_id :: proc(conv_id: pr.ConversationID) -> bool {
	return conv_id == 0 || conv_id == ENGINEERING_ROOM_ID || conv_id == OPERATIONS_ROOM_ID || conv_id == SYSTEM_ROOM_ID || pr.is_dm_conversation(conv_id)
}

make_room_mapping_conv_id :: proc(workspace_id: string, normalized_name: string) -> pr.ConversationID {
	key_len := len(workspace_id) + 1 + len(normalized_name)
	key_buf: [256]byte
	if key_len > len(key_buf) {
		key_len = len(key_buf)
	}

	key := key_buf[:key_len]
	offset := 0
	workspace_bytes := transmute([]byte)workspace_id
	workspace_len := min(len(workspace_bytes), len(key))
	copy(key[offset:], workspace_bytes[:workspace_len])
	offset += workspace_len
	if offset < len(key) {
		key[offset] = 0
		offset += 1
	}
	name_bytes := transmute([]byte)normalized_name
	if offset < len(key) {
		copy(key[offset:], name_bytes[:min(len(name_bytes), len(key) - offset)])
	}

	h := xxhash.XXH64(key) & ~u64(pr.DM_CONV_FLAG)
	conv_id := pr.ConversationID(h)
	for is_reserved_room_id(conv_id) {
		h = (h + 1) & ~u64(pr.DM_CONV_FLAG)
		conv_id = pr.ConversationID(h)
	}

	return conv_id
}

build_room_mapping_payload :: proc(normalized_name: string, conv_id: pr.ConversationID) -> string {
	return fmt.aprintf(
		"{{\"version\":1,\"normalized_name\":\"%s\",\"display_name\":\"%s\",\"conv_id\":\"%d\"}}",
		normalized_name,
		normalized_name,
		u64(conv_id),
	)
}
