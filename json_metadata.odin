package main

import "core:encoding/json"
import "core:mem"
import "core:strings"
import pr "protocol"

// Require the whole decimal and check before overflow.
json_metadata_integer :: proc(text: string) -> (value: i64, ok: bool) {
	s := strings.trim_space(text)
	if len(s) == 0 do return
	negative := s[0] == '-'
	if negative || s[0] == '+' do s = s[1:]
	if len(s) == 0 do return
	limit := u64(max(i64))
	if negative do limit += 1
	n: u64
	for c in s {
		if c < '0' || c > '9' do return
		digit := u64(c - '0')
		if n > (limit - digit) / 10 do return
		n = n * 10 + digit
	}
	if negative && n == u64(max(i64)) + 1 do return min(i64), true
	return negative ? -i64(n) : i64(n), true
}

JSON_Metadata_State :: enum {
	Root_Value,
	Root_Done,
	Object_Key_Or_End,
	Object_Key,
	Object_Colon,
	Object_Value,
	Object_Comma_Or_End,
	Array_Value_Or_End,
	Array_Value,
	Array_Comma_Or_End,
}

// Unescaped strings borrow the input. Escaped strings use the supplied allocator.
json_metadata_string :: proc(token: json.Token, allocator: mem.Allocator) -> string {
	if token.kind != .String do return ""
	if !strings.contains(token.text, "\\") do return token.text[1:len(token.text) - 1]
	decoded, err := json.unquote_string(token, .JSON, allocator)
	// Returning empty metadata here could leave stale indexes during removal.
	if err != nil do panic("failed to decode JSON metadata string")
	return decoded
}

// Validate the complete document without recursion or a JSON tree. Retain only
// selected top-level fields; container tokens include the entire validated span.
// Duplicate selected fields are rejected, ignored-field duplicates have no effect.
json_metadata_fields :: proc(data: []byte, names: [$N]string, allocator: mem.Allocator) -> (fields: [N]json.Token, object: bool, valid: bool) {
	tok := json.make_tokenizer(string(data), .JSON, true)
	stack: [65]JSON_Metadata_State
	depth, end, field := 0, 0, -1
	max_key_bytes := 0
	for name in names do max_key_bytes = max(max_key_bytes, len(name) * 6 + 2)
	for {
		token, err := json.get_token(&tok)
		// Tighten the tokenizer's permissive whitespace and NUL handling.
		for c in data[end:token.offset] {
			if c != ' ' && c != '\t' && c != '\r' && c != '\n' do return
		}
		end = token.offset + len(token.text)
		if token.kind == .EOF do return fields, object, token.offset == len(data) && depth == 0 && stack[0] == .Root_Done
		if err != nil do return
		if token.kind == .Integer {if _, ok := json_metadata_integer(token.text); !ok do return}
		if token.kind == .String {
			// Tighten permissive Unicode and apostrophe escapes.
			for i := 1; i < len(token.text) - 1; i += 1 {
				if token.text[i] != '\\' do continue
				i += 1
				if token.text[i] == '\'' do return
				if token.text[i] == 'u' {
					for _ in 0 ..< 4 {
						i += 1
						c := token.text[i]
						if !(c >= '0' && c <= '9' || c >= 'a' && c <= 'f' || c >= 'A' && c <= 'F') do return
					}
				}
			}
		}
		if depth == 2 && field >= 0 && (token.kind == .Close_Brace || token.kind == .Close_Bracket) {
			fields[field].text = string(data[fields[field].offset:end])
		}
		switch stack[depth] {
		case .Root_Done:
			return
		case .Object_Key_Or_End:
			if token.kind == .Close_Brace {depth -= 1; continue}
			fallthrough
		case .Object_Key:
			if token.kind != .String do return
			if depth == 1 {
				field = -1
				if len(token.text) <= max_key_bytes {
					key := json_metadata_string(token, allocator)
					for name, i in names {if key == name {field = i; break}}
					if strings.contains(token.text, "\\") do delete(key, allocator)
				}
			}
			stack[depth] = .Object_Colon
			continue
		case .Object_Colon:
			if token.kind != .Colon do return
			stack[depth] = .Object_Value
			continue
		case .Object_Comma_Or_End:
			if token.kind == .Comma {stack[depth] = .Object_Key; continue}
			if token.kind == .Close_Brace {depth -= 1; continue}
			return
		case .Array_Comma_Or_End:
			if token.kind == .Comma {stack[depth] = .Array_Value; continue}
			if token.kind == .Close_Bracket {depth -= 1; continue}
			return
		case .Array_Value_Or_End:
			if token.kind == .Close_Bracket {depth -= 1; continue}
			fallthrough
		case .Array_Value:
			stack[depth] = .Array_Comma_Or_End
		case .Object_Value:
			if depth == 1 && field >= 0 {
				if fields[field].kind != .Invalid do return
				fields[field] = token
			}
			stack[depth] = .Object_Comma_Or_End
		case .Root_Value:
			object = token.kind == .Open_Brace
			stack[0] = .Root_Done
		}
		#partial switch token.kind {
		case .Open_Brace, .Open_Bracket:
			if depth == 64 do return
			depth += 1
			stack[depth] = token.kind == .Open_Brace ? .Object_Key_Or_End : .Array_Value_Or_End
		case .String, .Integer, .Float, .True, .False, .Null:
		case:
			return
		}
	}
}

Appointment_Record :: struct {
	title:                               []byte,
	start_at, end_at:                    i64,
	description, assignee, project, url: []byte,
}

// Appointment previews are authoritative records. Keep this parser shared by
// write validation and the calendar index so replay and live mutations agree.
parse_appointment_preview :: proc(data: []byte, allocator: mem.Allocator) -> (r: Appointment_Record, ok: bool) {
	names := [?]string{"version", "title", "start_at", "end_at", "description", "assignee", "project", "url"}
	f, object, valid := json_metadata_fields(data, names, allocator)
	if !valid || !object || f[0].kind != .Integer || f[0].text != "1" || f[1].kind != .String || f[2].kind != .String do return
	r.title = transmute([]byte)json_metadata_string(f[1], allocator)
	start_text := json_metadata_string(f[2], allocator)
	r.start_at, ok = json_metadata_integer(start_text)
	if !ok || r.start_at <= 0 || len(r.title) == 0 || len(r.title) > pr.MAX_TASK_TITLE_LENGTH do return r, false
	if f[3].kind != .Invalid {
		if f[3].kind != .String do return r, false
		end_text := json_metadata_string(f[3], allocator)
		if end_text != "" {
			r.end_at, ok = json_metadata_integer(end_text)
			if !ok || r.end_at <= r.start_at do return r, false
		}
	}
	limits := [?]int{pr.MAX_APPOINTMENT_DESCRIPTION_LENGTH, pr.MAX_ASSIGNEE_LENGTH, pr.MAX_PROJECT_LENGTH, pr.MAX_APPOINTMENT_URL_LENGTH}
	outs := [?]^[]byte{&r.description, &r.assignee, &r.project, &r.url}
	for token, i in f[4:] {
		if token.kind == .Invalid do continue
		if token.kind != .String do return r, false
		outs[i]^ = transmute([]byte)json_metadata_string(token, allocator)
		if len(outs[i]^) > limits[i] do return r, false
	}
	return r, true
}

validate_appointment_asset :: proc(
	asset_type: pr.AssetType,
	encoding: pr.PayloadEncoding,
	raw_len: u32,
	preview, payload: []byte,
	allocator: mem.Allocator,
) -> bool {
	if asset_type != .Appointment do return true
	if encoding != .Plain || raw_len != 0 || len(payload) != 0 do return false
	_, ok := parse_appointment_preview(preview, allocator)
	return ok
}
