package main

import "core:encoding/json"
import "core:mem"
import "core:mem/virtual"
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
// This is the existing metadata contract, not a general JSON decoder: nesting
// is capped at 64 and every integer token (even ignored ones) must fit i64.
json_metadata_fields :: proc(
	data: []byte,
	names: [$N]string,
	allocator: mem.Allocator,
	strict := false,
) -> (
	fields: [N]json.Token,
	object: bool,
	valid: bool,
) {
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
				if strict && field < 0 do return
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
	version:                             int,
	timezone, repeat, until, conference: string,
	weekdays:                            []int,
	participants:                        []string,
	exceptions:                          []Appointment_Exception,
	title:                               []byte,
	start_at, end_at:                    i64,
	description, assignee, project, url: []byte,
}

// Appointment previews are authoritative records. Keep this parser shared by
// write validation and the calendar index so replay and live mutations agree.
parse_appointment_preview :: proc(data: []byte, allocator: mem.Allocator) -> (r: Appointment_Record, ok: bool) {
	names := [?]string{"version", "title", "start_at", "end_at", "description", "assignee", "project", "url"}
	v, _, _ := json_metadata_fields(data, [?]string{"version"}, allocator)
	if v[0].text == "2" do return parse_appointment_v2(data, allocator)
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
	r.version = 1
	return r, true
}

validate_appointment_asset :: proc(asset_type: pr.AssetType, encoding: pr.PayloadEncoding, raw_len: u32, preview, payload: []byte) -> bool {
	if asset_type != .Appointment do return true
	if encoding != .Plain || raw_len != 0 || len(payload) != 0 do return false
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false
	defer virtual.arena_destroy(&arena)
	_, ok := parse_appointment_preview(preview, virtual.arena_allocator(&arena))
	return ok
}

Ticket_Preview :: struct {
	// Explicit tags prevent the decoder from binding an empty extension key
	// to the first untagged field.
	title:          string `json:"title"`,
	status:         string `json:"status"`,
	assignee:       string `json:"assignee"`,
	company_id:     string `json:"company_id"`,
	contact_id:     string `json:"contact_id"`,
	requester:      string `json:"requester"`,
	requester_name: string `json:"requester_name"`,
}

Ticket_Entry_Preview :: struct {
	kind, author: string,
}

// Read compatibility deliberately retains the historical struct decoder. Only
// fields belonging to this asset type participate; unrelated extension fields
// must not hide a ticket or its replies. Strict mode preserves the write/replay
// contract. Strings may borrow data in strict mode or use allocator; callers
// must retain both input and allocator until they finish using the projection.
parse_ticket_preview :: proc(data: []byte, allocator: mem.Allocator, strict := false) -> (m: Ticket_Preview, ok: bool) {
	if !strict {
		ok = json.unmarshal(data, &m, allocator = allocator) == nil
		return
	}
	f, object, valid := json_metadata_fields(
		data,
		[?]string{"version", "title", "company_id", "contact_id", "requester", "requester_name", "status", "assignee"},
		allocator,
	)
	if !valid || !object || f[0].kind != .Integer || f[0].text != "1" do return
	limits := [?]int{256, 20, 20, 320, 256, 32, 64}
	outs := [?]^string{&m.title, &m.company_id, &m.contact_id, &m.requester, &m.requester_name, &m.status, &m.assignee}
	for token, i in f[1:] {
		if token.kind != .String do return
		outs[i]^ = json_metadata_string(token, allocator)
		if len(outs[i]^) > limits[i] do return
	}
	if len(strings.trim_space(m.title)) == 0 do return
	for id in ([?]string{m.company_id, m.contact_id}) {
		if id == "" do continue
		if id[0] == '0' do return
		n: u64
		for c in id {
			if c < '0' || c > '9' do return
			digit := u64(c - '0')
			if n > (max(u64) - digit) / 10 do return
			n = n * 10 + digit
		}
	}
	ok = m.status == "open" || m.status == "in_progress" || m.status == "waiting_customer" || m.status == "resolved" || m.status == "closed"
	return
}

parse_ticket_entry_preview :: proc(data: []byte, allocator: mem.Allocator, strict := false) -> (m: Ticket_Entry_Preview, ok: bool) {
	if strict {
		f, object, valid := json_metadata_fields(data, [?]string{"version", "kind", "author"}, allocator)
		if !valid || !object || f[0].kind != .Integer || f[0].text != "1" || f[1].kind != .String || f[2].kind != .String do return
		m.kind = json_metadata_string(f[1], allocator)
		m.author = json_metadata_string(f[2], allocator)
		ok = (m.kind == "customer_reply" || m.kind == "public_reply" || m.kind == "internal_note") && len(m.author) <= 256
		return
	}
	// Historical activity reads only interpreted kind, not author.
	legacy: struct {
		kind: string `json:"kind"`,
	}
	ok = json.unmarshal(data, &legacy, allocator = allocator) == nil
	m.kind = legacy.kind
	return
}

// Tickets keep their public/private classification in validated metadata, not
// in their body text. Use the same contract for live writes and WAL replay.
validate_ticket_asset :: proc(
	asset_type: pr.AssetType,
	parent_type: pr.ParentType,
	parent_id: u64,
	encoding: pr.PayloadEncoding,
	raw_len: u32,
	preview, payload: []byte,
) -> bool {
	if asset_type != .Ticket && asset_type != .TicketEntry do return true
	if raw_len > 32000 do return false
	decoded: [32000]byte
	body := payload
	switch encoding {
	case .Plain:
		if raw_len != u32(len(payload)) do return false
	case .Zstd:
		body = decoded[:int(raw_len)]
		size := ZSTD_decompress(raw_data(body), uintptr(len(body)), raw_data(payload), uintptr(len(payload)))
		if ZSTD_isError(size) != 0 || size != uintptr(raw_len) do return false
	case:
		return false
	}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return false
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	if asset_type == .TicketEntry {
		if parent_type != .Asset || parent_id == 0 || len(strings.trim_space(string(body))) == 0 do return false
		_, ok := parse_ticket_entry_preview(preview, a, strict = true)
		return ok
	}
	if parent_type != .None || parent_id != 0 do return false
	_, ok := parse_ticket_preview(preview, a, strict = true)
	return ok
}
