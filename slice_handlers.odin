package main

import "byte_pool"
import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"
import pr "protocol"

Slice_Preview :: struct {
	version:   int,
	name:      string,
	owner:     string,
	outcome:   string,
	closed:    bool,
	closed_at: i64,
	closed_by: string,
}

strict_slice_json :: proc(preview: []byte) -> bool {
	if strings.has_prefix(string(preview), "\uFEFF") || !utf8.valid_string(string(preview)) || !json.is_valid(preview, .JSON, true) {
		return false
	}
	for c in preview do if c < ' ' && c != '\t' && c != '\n' && c != '\r' do return false
	// Odin's structural validator can accept invalid number and escape syntax.
	tok := json.make_tokenizer(string(preview), .JSON, true)
	depth := 0
	previous := json.Token_Kind.Invalid
	closure_key := false
	for {
		token, err := json.get_token(&tok)
		if token.kind == .EOF do return true
		if err != nil do return false
		if depth == 0 && previous != .Invalid do return false
		if depth == 1 && previous == .Colon && closure_key && token.kind != .Null {
			if token.kind != .Integer do return false
			if _, fits := strconv.parse_i64(token.text, 10); !fits do return false
		}
		#partial switch token.kind {
		case .String:
			// A token includes both quotes. Check every escape before unquoting.
			i := 1
			for i < len(token.text) - 1 {
				c := token.text[i]; i += 1
				if c != '\\' do continue
				if i >= len(token.text) - 1 do return false
				switch token.text[i] {
				case '"', '\\', '/', 'b', 'f', 'n', 'r', 't':
					i += 1
				case 'u':
					i += 1
					if i + 4 > len(token.text) - 1 do return false
					for h in transmute([]byte)token.text[i:i + 4] {
						if !(h >= '0' && h <= '9' || h >= 'a' && h <= 'f' || h >= 'A' && h <= 'F') do return false
					}
					i += 4
				case:
					return false
				}
			}
			if depth == 1 && (previous == .Open_Brace || previous == .Comma) {
				name, _ := json.unquote_string(token, .JSON)
				closure_key = name == "closed_at"
				delete(name)
			}
		case .Open_Brace, .Open_Bracket:
			depth += 1
		case .Close_Brace, .Close_Bracket:
			if previous == .Comma do return false
			depth -= 1
		}
		previous = token.kind
	}
}

// JSON5 legacy previews need normalization before they can be promoted. Only
// quote JSON syntax and controls, not otherwise valid UTF-8.
normalize_slice_preview :: proc(m: Slice_Preview) -> []byte {
	b := strings.builder_make()
	write_value :: proc(b: ^strings.Builder, key, value: string) {
		strings.write_string(b, key)
		strings.write_byte(b, '"')
		for c in transmute([]byte)value {
			switch c {
			case '"', '\\':
				strings.write_byte(b, '\\'); strings.write_byte(b, c)
			case '\b':
				strings.write_string(b, `\b`)
			case '\f':
				strings.write_string(b, `\f`)
			case '\n':
				strings.write_string(b, `\n`)
			case '\r':
				strings.write_string(b, `\r`)
			case '\t':
				strings.write_string(b, `\t`)
			case:
				if c < 32 {
					strings.write_string(b, `\u00`)
					strings.write_byte(b, strconv.digits[c >> 4])
					strings.write_byte(b, strconv.digits[c & 15])
				} else do strings.write_byte(b, c)
			}
		}
		strings.write_byte(b, '"')
	}
	strings.write_string(&b, `{"version":1`)
	write_value(&b, `,"name":`, m.name)
	if m.owner != "" do write_value(&b, `,"owner":`, m.owner)
	if m.outcome != "" do write_value(&b, `,"outcome":`, m.outcome)
	if m.closed do strings.write_string(&b, `,"closed":true`)
	if m.closed_at != 0 {
		buf: [32]byte
		strings.write_string(&b, `,"closed_at":`)
		strings.write_string(&b, strconv.write_int(buf[:], m.closed_at, 10))
	}
	if m.closed_by != "" do write_value(&b, `,"closed_by":`, m.closed_by)
	strings.write_byte(&b, '}')
	return transmute([]byte)strings.to_string(b)
}

// Rewrite an already validated preview without re-escaping user strings. Copy
// only the original fields: legacy extras may contain conflicting group keys.
rewrite_slice_preview :: proc(preview: []byte, group: string) -> []byte {
	tok := json.make_tokenizer(string(preview), .JSON)
	_, _ = json.get_token(&tok) // opening brace
	extra := len(`,"group_id":""`) + len(group)
	result := make([]byte, len(preview) + (group == "" ? 0 : extra))
	n := copy(result, "{")
	for {
		key, _ := json.get_token(&tok)
		if key.kind == .Close_Brace do break
		name, _ := json.unquote_string(key, tok.spec)
		_, _ = json.get_token(&tok) // colon
		value, _ := json.get_token(&tok)
		switch name {
		case "version", "name", "owner", "outcome", "closed", "closed_at", "closed_by":
			if n > 1 {result[n] = ','; n += 1}
			n += copy(result[n:], key.text)
			result[n] = ':'; n += 1
			text := name == "version" ? (group == "" ? "1" : "2") : value.text
			n += copy(result[n:], text)
		case:
			depth := 0
			for {
				#partial switch value.kind {
				case .Open_Brace, .Open_Bracket:
					depth += 1
				case .Close_Brace, .Close_Bracket:
					depth -= 1
				}
				if depth == 0 do break
				value, _ = json.get_token(&tok)
			}
		}
		end, _ := json.get_token(&tok)
		if end.kind == .Close_Brace do break
	}
	if group != "" {
		n += copy(result[n:], `,"group_id":"`)
		n += copy(result[n:], group)
		result[n] = '"'; n += 1
	}
	result[n] = '}'
	return result[:n + 1]
}

valid_slice_group :: proc(a: ^pr.Asset) -> bool {
	name := string(a.preview)
	return(
		a.parent_type == .None &&
		a.parent_id == 0 &&
		len(a.attachments) == 0 &&
		len(a.payload) == 0 &&
		a.payload_encoding == .Plain &&
		a.payload_raw_len == 0 &&
		len(name) > 0 &&
		len(name) <= pr.MAX_PROJECT_LENGTH &&
		utf8.valid_string(name) &&
		strings.trim_space(name) == name \
	)
}

slice_preview :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (m: Slice_Preview, group: string, ok: bool) {
	if asset == nil do return
	return decode_slice_preview(asset.preview, allocator)
}

// Keep the JSON decoder and its default semantics identical for reads and writes.
decode_slice_preview :: proc(preview: []byte, allocator: mem.Allocator) -> (m: Slice_Preview, group: string, ok: bool) {
	if json.unmarshal(preview, &m, allocator = allocator) != nil do return
	// v1 accepted arbitrary extra fields; only v2 can give group_id meaning.
	if (m.version != 1 && m.version != 2) || len(m.name) == 0 || len(m.name) > pr.MAX_PROJECT_LENGTH do return
	if m.version == 2 {
		if !strict_slice_json(preview) do return
		fields: struct {
			group_id: json.Value,
		}
		if json.unmarshal(preview, &fields, .JSON, allocator = allocator) != nil do return
		if fields.group_id == nil do return m, "", true
		value, is_string := fields.group_id.(json.String)
		if !is_string || value == "" do return
		group = value
		for c in transmute([]byte)group do if c < '0' || c > '9' do return m, "", false
		_, valid := strconv.parse_u64(group, 10)
		if !valid || len(group) > 1 && group[0] == '0' do return m, "", false
	}
	return m, group, true
}

slice_has_flag :: proc(slice: pr.TaskSlice, flag: pr.TaskSliceFlags) -> bool {
	return flag <= slice.flags
}

// Names need not be unique; the asset ID is the slice's identity.
slice_preview_name :: proc(preview: []byte, allocator: mem.Allocator) -> (name: string, ok: bool) {
	m, _, valid := decode_slice_preview(preview, allocator)
	if !valid do return
	return m.name, true
}

// A retired task is not work; Done members do not hold the active age back.
fold_task_member :: proc(entry: ^pr.TaskSlice, task: ^pr.Task, overflow: ^bool = nil) -> bool {
	if task == nil || task.status == .Note do return false
	switch task.status {
	case .Backlog:
		slice_increment_count(&entry.backlog, overflow)
	case .Todo:
		slice_increment_count(&entry.todo, overflow)
	case .InProgress:
		slice_increment_count(&entry.in_progress, overflow)
	case .Done:
		slice_increment_count(&entry.done, overflow)
	case .Note:
		return false
	}
	if task.blocked_by != 0 do slice_increment_count(&entry.blocked, overflow)
	if task.status != .Done && task.created_at != 0 && (entry.oldest_active_at == 0 || task.created_at < entry.oldest_active_at) {
		entry.oldest_active_at = task.created_at
	}
	if task.updated_at > entry.last_moved_at do entry.last_moved_at = task.updated_at
	return true
}

fold_asset_member :: proc(entry: ^pr.TaskSlice, asset: ^pr.Asset, overflow: ^bool = nil) {
	if asset == nil do return
	#partial switch asset.asset_type {
	case .Note:
		slice_increment_count(&entry.notes, overflow)
	case .File:
		slice_increment_count(&entry.files, overflow)
	case .Ticket:
		slice_increment_count(&entry.tickets, overflow)
	case:
		return
	}
	if asset.updated_at > entry.last_moved_at do entry.last_moved_at = asset.updated_at
}

// Wire counters are independent u16 categories, not a bound on total members.
slice_increment_count :: proc(count: ^u16, overflow: ^bool) {
	if count^ == max(u16) {
		if overflow != nil do overflow^ = true
		return
	}
	count^ += 1
}

Slice_Cursor :: struct {
	closed:   bool,
	sort_at:  i64,
	slice_id: pr.AssetID,
}

Slice_Page :: struct {
	total_count:      u32,
	has_more:         bool,
	next_cursor:      Slice_Cursor,
	assigned_tasks:   u32,
	unassigned_tasks: u32,
	error:            string,
}

send_task_slice_list :: proc(
	c: ^NRC_Connection,
	conv_id: pr.ConversationID,
	slices: []pr.TaskSlice,
	page: Slice_Page,
	error_msg: string,
	correlation_id: u32,
) {
	msg := pr.TaskSliceList {
		conv_id              = conv_id,
		success              = error_msg == "",
		slices               = slices,
		has_more             = page.has_more,
		next_cursor_closed   = page.next_cursor.closed,
		next_cursor_sort_at  = page.next_cursor.sort_at,
		next_cursor_slice_id = page.next_cursor.slice_id,
		total_count          = page.total_count,
		assigned_tasks       = page.assigned_tasks,
		unassigned_tasks     = page.unassigned_tasks,
		error                = transmute([]byte)error_msg,
		correlation_id       = correlation_id,
	}
	write_task_slice_list(c, msg)
}

write_task_slice_list :: proc(c: ^NRC_Connection, msg: pr.TaskSliceList) -> bool {
	size := pr.getSizeTaskSliceList(msg)
	buf, header_len := allocate_websocket_frame_buffer(size, "task slice list")
	if buf == nil do return false
	written := pr.serializeTaskSliceList(msg, buf[header_len:])
	if written <= 0 {
		byte_pool.release(td.spool, buf)
		return false
	}
	return send_pooled_buffer(c, buf[:header_len + written])
}
