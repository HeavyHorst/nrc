package main

import "btree"
import "core:strings"
import pr "protocol"

// Visibility lives in the existing reminder JSON, avoiding a wire/WAL migration.
// Opaque legacy records and records without visibility remain team reminders.
reminder_visibility :: proc(data: []byte) -> (personal, valid: bool) {
	fields, object, parsed := json_metadata_fields(data, [?]string{"visibility"}, context.allocator)
	if !parsed {
		text := strings.trim_space(string(data))
		return false, !strings.has_prefix(text, "{")
	}
	if !object || fields[0].kind == .Invalid do return false, true
	if fields[0].kind != .String do return false, false
	value := json_metadata_string(fields[0], context.allocator)
	defer if strings.contains(fields[0].text, "\\") do delete(value)
	return value == "personal", value == "personal" || value == "team"
}

reminder_is_personal :: proc(asset: ^pr.Asset) -> bool {
	if asset == nil || asset.asset_type != .Reminder do return false
	personal, _ := reminder_visibility(asset.preview)
	return personal
}

asset_visible_to :: proc(asset: ^pr.Asset, username: string) -> bool {
	return asset != nil && (!reminder_is_personal(asset) || (username != "" && string(asset.owner) == username))
}

// Shared graph/ownership links and attachments have workspace-wide access.
// Personal reminders must remain standalone until those surfaces support ACLs.
validate_reminder_asset :: proc(asset: ^pr.Asset) -> bool {
	if asset.asset_type != .Reminder do return true
	if asset.payload_raw_len > pr.MAX_PAYLOAD_LENGTH do return false
	personal, valid := reminder_visibility(asset.preview)
	if !valid do return false
	payload := asset.payload
	decoded: []byte
	defer delete(decoded)
	if asset.payload_encoding == .Zstd {
		decoded = make([]byte, int(asset.payload_raw_len))
		payload = decoded
		size := ZSTD_decompress(raw_data(payload), uintptr(len(payload)), raw_data(asset.payload), uintptr(len(asset.payload)))
		if ZSTD_isError(size) != 0 || size != uintptr(len(payload)) do return false
	}
	payload_personal, payload_valid := reminder_visibility(payload)
	if !payload_valid || personal != payload_personal do return false
	return !personal || (len(asset.owner) > 0 && asset.parent_type == .None && len(asset.attachments) == 0)
}

entity_is_personal_reminder :: proc(conv: ^Conversation_State, typ: pr.TargetType, id: u64) -> bool {
	return conv != nil && typ == .Asset && reminder_is_personal(conv.assets[pr.AssetID(id)])
}

// A persisted dangling parent reference must not turn into a public child of a
// newly allocated private record, even if it predates parent-existence checks.
asset_has_children :: proc(conv: ^Conversation_State, id: pr.AssetID) -> bool {
	if conv == nil do return false
	it := btree.iter(&conv.asset_parents)
	defer btree.iter_destroy(&it)
	pivot := Entity_Reference_Key {
		kind      = u8(pr.ParentType.Asset),
		parent_id = u64(id),
	}
	if !btree.iter_seek(&it, pivot) do return false
	key := btree.item(&it)
	return key.kind == pivot.kind && key.parent_id == pivot.parent_id
}
