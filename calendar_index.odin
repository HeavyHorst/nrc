package main

import "core:mem"
import "core:strconv"
import "core:strings"
import pr "protocol"

foreign import calendar_zstd "system:zstd"
foreign calendar_zstd {
	ZSTD_decompress :: proc(dst: rawptr, capacity: uintptr, src: rawptr, size: uintptr) -> uintptr ---
	ZSTD_isError :: proc(code: uintptr) -> u32 ---
}

Appointment_Index_Key :: struct {
	bucket:           u8,
	slot:             i64,
	end_at, start_at: i64,
	id:               pr.AssetID,
}

// SQLite stores the smallest power-of-two bucket containing the interval.
appointment_index_key :: proc(start, end: i64, id: pr.AssetID) -> Appointment_Index_Key {
	last := end == 0 ? start : end - 1
	bucket: u8
	for different := start ~ last; different != 0; different >>= 1 do bucket += 1
	return {bucket, start >> bucket, end, start, id}
}

calendar_key_compare :: proc(a, b: pr.CalendarKey) -> int {
	if a.at != b.at do return a.at < b.at ? -1 : 1
	if a.kind != b.kind do return a.kind < b.kind ? -1 : 1
	if a.id != b.id do return a.id < b.id ? -1 : 1
	return 0
}

// Payload wins over preview, including legacy camelCase fields. Parse real JSON
// so nested fields or quoted field names in a title cannot invent deadlines.
// Compatibility: only metadata-parser rejection falls back. A parsed payload
// with a missing/unusable deadline suppresses the preview. This projection
// is independent of the preview visibility contract in reminder_visibility.
calendar_reminder :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (at: i64, title: []byte) {
	if asset == nil || asset.asset_type != .Reminder do return
	payload := asset.payload
	if asset.payload_encoding == .Zstd {
		payload = nil
		if asset.payload_raw_len > 0 && asset.payload_raw_len <= pr.MAX_PAYLOAD_LENGTH {
			decoded := make([]byte, int(asset.payload_raw_len), allocator)
			size := ZSTD_decompress(raw_data(decoded), uintptr(len(decoded)), raw_data(asset.payload), uintptr(len(asset.payload)))
			if ZSTD_isError(size) == 0 && size == uintptr(len(decoded)) do payload = decoded
		}
	}
	for data in ([?][]byte{payload, asset.preview}) {
		fields, object, valid := json_metadata_fields(data, [?]string{"deadline_at", "deadlineAt", "title", "name"}, allocator)
		if !valid do continue
		if !object do return
		deadline := fields[0]
		if deadline.kind == .Invalid || deadline.kind == .Null do deadline = fields[1]
		#partial switch deadline.kind {
		case .String, .Integer:
			text := deadline.kind == .String ? json_metadata_string(deadline, allocator) : deadline.text
			parsed, ok := json_metadata_integer(text)
			if ok do at = parsed
		case .Float:
			v, ok := strconv.parse_f64(deadline.text)
			if ok && v > 0 && v < 9223372036854775808.0 do at = i64(v)
		}
		name := json_metadata_string(fields[2], allocator)
		if name == "" do name = json_metadata_string(fields[3], allocator)
		if name == "" do name = string(asset.preview)
		name = strings.trim_space(name)
		if at <= 0 || name == "" do return 0, nil
		return at, transmute([]byte)name
	}
	return
}
