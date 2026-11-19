package main

import "core:encoding/json"
import "core:mem"
import "core:strconv"
import "core:strings"
import pr "protocol"

Ticket_Cursor :: struct {
	id, number, text: string,
}
Ticket_Query :: struct {
	mode, status, assignee, company, parent, sort, search: string,
	priority, follow_up:                                   string,
	descending:                                            bool,
	limit:                                                 int,
	cursor:                                                Ticket_Cursor,
	read:                                                  map[string]string,
	ids:                                                   []string,
	search_results:                                        bool,
	read_snapshot:                                         u32,
	read_start, read_end:                                  bool,
	omit_total_count:                                      bool,
}
Ticket_Activity :: struct {
	unread:            int,
	waiting:           bool,
	follow_up_due:     bool,
	latest, timestamp: string,
}
Ticket_Page_Metadata :: struct {
	has_more:            bool,
	total_count:         int,
	total_count_omitted: bool `json:"total_count_omitted,omitempty"`,
	cursor:              Ticket_Cursor,
	activity:            [dynamic]Ticket_Activity,
}

ticket_search_body :: proc(asset: ^pr.Asset) -> string {
	decoded: [32000]byte
	body := asset.payload
	if asset.payload_encoding == .Zstd {
		if asset.payload_raw_len > len(decoded) do return ""
		body = decoded[:int(asset.payload_raw_len)]
		size := ZSTD_decompress(raw_data(body), uintptr(len(body)), raw_data(asset.payload), uintptr(len(asset.payload)))
		if ZSTD_isError(size) != 0 || size != uintptr(len(body)) do return ""
	}
	return strings.to_lower(string(body))
}

ticket_body_matches :: proc(asset: ^pr.Asset, query: string) -> bool {
	if query == "" do return true
	lower := ticket_search_body(asset); defer delete(lower)
	return strings.contains(lower, query)
}

parse_ticket_query :: proc(data: []byte, allocator: mem.Allocator) -> (q: Ticket_Query, error: string) {
	fields, object, valid := json_metadata_fields(data, [?]string{"priority", "follow_up"}, allocator)
	if !valid || !object {
		return {}, "Invalid ticket query"
	}
	for field in fields {
		if field.kind != .Invalid && field.kind != .String {
			return {}, "Invalid ticket query"
		}
	}
	if json.unmarshal(data, &q, allocator = allocator) != nil ||
	   q.limit < 0 ||
	   q.limit > 250 ||
	   len(q.ids) > 100 ||
	   (q.priority != "" && !ticket_priority_valid(q.priority)) ||
	   (q.follow_up != "" && q.follow_up != "all" && q.follow_up != "due") ||
	   (q.mode != "" && q.mode != "entries" && q.mode != "attention" && q.mode != "read") ||
	   (q.sort != "" &&
			   q.sort != "id" &&
			   q.sort != "activity" &&
			   q.sort != "unread" &&
			   q.sort != "priority" &&
			   q.sort != "follow_up_at" &&
			   q.sort != "title" &&
			   q.sort != "status" &&
			   q.sort != "assignee" &&
			   q.sort != "company_id" &&
			   q.sort != "contact_id") {
		return {}, "Invalid ticket query"
	}
	if q.cursor.id != "" {
		id, id_ok := strconv.parse_u64(q.cursor.id)
		_, number_ok := strconv.parse_i64(q.cursor.number)
		if !id_ok || id == 0 || !number_ok do return {}, "Invalid ticket cursor"
	}
	if q.mode == "entries" {
		id, ok := strconv.parse_u64(q.parent)
		if !ok || id == 0 do return {}, "Invalid ticket parent"
	}
	return q, ""
}
