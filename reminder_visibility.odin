package main

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
