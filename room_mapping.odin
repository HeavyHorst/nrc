package main

import "core:fmt"
import "core:hash/xxhash"
import "core:log"

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

index_room_mapping_asset :: proc(ws: ^Workspace_State, workspace_id: string, asset: ^pr.Asset) {
	if ws == nil || asset == nil || asset.asset_type != .RoomMapping || asset.conv_id != pr.WORKSPACE_DATA_ID {
		return
	}

	name_buf: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	normalized_name, ok := normalize_room_mapping_name(asset.preview, name_buf[:])
	if !ok {
		return
	}
	if _, is_builtin := builtin_room_id_for_name(normalized_name); is_builtin {
		return
	}

	key := intern_room_mapping_name(normalized_name)
	if _, exists := ws.room_mappings[key]; exists {
		return
	}

	ws.room_mappings[key] = Room_Mapping_State {
		conv_id  = make_room_mapping_conv_id(workspace_id, normalized_name),
		asset_id = asset.asset_id,
	}
}

remove_room_mapping_asset :: proc(ws: ^Workspace_State, asset: ^pr.Asset) {
	if ws == nil || asset == nil || asset.asset_type != .RoomMapping {
		return
	}

	name_buf: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	normalized_name, ok := normalize_room_mapping_name(asset.preview, name_buf[:])
	if !ok {
		return
	}

	key := intern_room_mapping_name(normalized_name)
	if existing, exists := ws.room_mappings[key]; exists && existing.asset_id == asset.asset_id {
		delete_key(&ws.room_mappings, key)
	}
}

handle_create_room_mapping_asset :: proc(c: ^NRC_Connection, req: pr.CreateAssetRequest) {
	if req.conv_id != pr.WORKSPACE_DATA_ID {
		send_error_response(c, .C_CreateAsset, "Room mappings require workspace scope", req.correlation_id)
		return
	}
	if req.parent_type != .None || req.parent_id != 0 {
		send_error_response(c, .C_CreateAsset, "Room mappings cannot have a parent", req.correlation_id)
		return
	}

	name_buf: [MAX_ROOM_MAPPING_NAME_LENGTH]byte
	normalized_name, ok := normalize_room_mapping_name(req.preview, name_buf[:])
	if !ok {
		send_error_response(c, .C_CreateAsset, "Invalid room name", req.correlation_id)
		return
	}
	if _, is_builtin := builtin_room_id_for_name(normalized_name); is_builtin {
		send_error_response(c, .C_CreateAsset, "Room name is reserved", req.correlation_id)
		return
	}

	workspace_id := c.workspace_id
	ws := get_or_create_connection_workspace(c)
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	conv_id := make_room_mapping_conv_id(workspace_id, normalized_name)
	key := intern_room_mapping_name(normalized_name)
	stale_mapping := false
	if existing, exists := ws.room_mappings[key]; exists {
		if asset := conv.assets[existing.asset_id]; asset != nil {
			send_asset_created(c, asset^, req.correlation_id)
			return
		}
		stale_mapping = true
	}

	payload := build_room_mapping_payload(normalized_name, conv_id)
	defer delete(payload)

	asset_id := pr.AssetID(td.asset_seq + 1)
	owner := get_connection_nickname(c)
	now := nrc_time_unix_nanos()

	new_asset := alloc_asset(transmute([]byte)owner, transmute([]byte)normalized_name, transmute([]byte)payload)
	if new_asset == nil {
		log.errorf("[T%d] Failed to allocate room mapping asset", td.thread_index)
		send_error_response(c, .C_CreateAsset, "Failed to allocate asset", req.correlation_id)
		return
	}

	new_asset.asset_type = .RoomMapping
	new_asset.asset_id = asset_id
	new_asset.parent_type = .None
	new_asset.parent_id = 0
	new_asset.created_at = now
	new_asset.updated_at = now
	new_asset.conv_id = pr.WORKSPACE_DATA_ID
	new_asset.payload_encoding = .Plain
	new_asset.payload_raw_len = u32(len(payload))

	if !persist_asset_created(workspace_id, new_asset) {
		persistent_mutation_failed("asset", "create", workspace_id)
		free_asset(new_asset)
		return
	}
	td.asset_seq = u64(asset_id)

	if stale_mapping do delete_key(&ws.room_mappings, key)
	asset_store_put(ws, workspace_id, conv, new_asset)
	send_asset_created(c, new_asset^, req.correlation_id)
	broadcast_asset_created(new_asset^, c.sock, ws)

	log.infof("[T%d] Created room mapping %s -> %d in workspace '%s'", td.thread_index, normalized_name, conv_id, workspace_id)
}
