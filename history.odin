package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:mem"
import "core:strings"
import pr "protocol"
import db "workspace_db"

history_kind_name :: proc(kind: u8) -> string {
	switch kind {
	case 1:
		return "task"
	case 2:
		return "asset"
	case 3:
		return "edge"
	}
	return ""
}

history_asset_label :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (label: string, asset_type: u16) {
	asset_type = u16(asset.asset_type)
	// Never use document bodies, teasers, descriptions or arbitrary JSON as names.
	if asset.asset_type == .Comment do return
	key := asset.asset_type == .Slice ? "name" : "title"
	fields, object, valid := json_metadata_fields(asset.preview, [2]string{key, "filename"}, allocator)
	if valid && object {
		value := json_metadata_string(fields[0], allocator)
		if value == "" && asset.asset_type == .File do value = json_metadata_string(fields[1], allocator)
		return pr.history_short_label(value, allocator), asset_type
	}
	// Metadata extraction also rejects otherwise valid JSON outside its depth or
	// integer bounds. Never mistake JSON-shaped content for a legacy plain title.
	if valid || asset.asset_type != .Note do return
	text := strings.trim_space(string(asset.preview))
	if len(text) == 0 do return
	first := text[0]
	if first == '{' || first == '[' || first == '"' || first == '-' || first >= '0' && first <= '9' do return
	label = pr.history_short_label(text, allocator)
	return
}

history_attachment_equal :: proc(a, b: []pr.Attachment) -> bool {
	if len(a) != len(b) do return false
	for x, i in a {
		y := b[i]
		if string(x.file_id) != string(y.file_id) || string(x.filename) != string(y.filename) || x.size != y.size || string(x.mime_type) != string(y.mime_type) || x.uploaded_at != y.uploaded_at do return false
	}
	return true
}

process_list_history :: proc(c: ^NRC_Connection, body: []byte) {
	request, parse_err := pr.parseListHistoryRequest(body)
	correlation := request.correlation_id
	// A structurally invalid body reports the request error, a valid one still
	// answers "Authentication required" before the filter is judged.
	authorized := c.authenticated
	error := ""
	switch {
	case parse_err != nil && parse_err != .InvalidValue:
		error = "Invalid history request"
	case !authorized:
		error = "Authentication required"
	case parse_err == .InvalidValue:
		error = "Invalid history filter or limit"
	}
	if error == "" {
		job := db.Request {
			operation = .Command,
			shard     = int(shard_for_workspace(transmute([]byte)c.workspace_id)),
			opcode    = .C_ListHistory,
			body      = body,
		}
		admission_error: string
		if !worker_db_submit(c, job, correlation, worker_db_complete_command, &admission_error) do send_history_error(c, correlation, admission_error)
		return
	}
	send_history_error(c, correlation, error)
}

send_history_error :: proc(c: ^NRC_Connection, correlation: u32, error: string) {
	payload, _ := json.marshal(struct {
		events:      [0]int,
		next_before: string `json:"nextBefore"`,
		error:       string,
	}{{}, "0", error})
	defer delete(payload)
	send_history_page(c, correlation, payload)
}

send_history_page :: proc(c: ^NRC_Connection, correlation: u32, payload: []byte) {
	buf, header := allocate_websocket_frame_buffer(6 + len(payload), "history page")
	if buf == nil do return
	endian.put_u16(buf[header:], .Big, u16(pr.Opcode.S_HistoryPage)); endian.put_u32(buf[header + 2:], .Big, correlation)
	copy(buf[header + 6:], payload)
	send_pooled_buffer(c, buf)
}
