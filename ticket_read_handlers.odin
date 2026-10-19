package main

import "byte_pool"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:slice"
import "core:strconv"
import "core:strings"
import pr "protocol"

Ticket_Cursor :: struct {
	id, number, text: string,
}
Ticket_Query :: struct {
	mode, status, assignee, company, parent, sort, search: string,
	descending:                                            bool,
	limit:                                                 int,
	cursor:                                                Ticket_Cursor,
	read:                                                  map[string]string,
	ids:                                                   []string,
	search_results:                                        bool,
	read_snapshot:                                         u32,
	read_start, read_end:                                  bool,
}
Ticket_Metadata :: struct {
	title, status, assignee, company_id, contact_id, requester, requester_name, kind: string,
}
Ticket_Activity :: struct {
	unread:            int,
	waiting:           bool,
	latest, timestamp: string,
}
Ticket_Page_Metadata :: struct {
	has_more:    bool,
	total_count: int,
	cursor:      Ticket_Cursor,
	activity:    [dynamic]Ticket_Activity,
}
Ticket_Candidate :: struct {
	asset:             ^pr.Asset,
	metadata:          Ticket_Metadata,
	activity:          Ticket_Activity,
	latest, reply:     pr.AssetID,
	timestamp, number: i64,
	text:              string,
	matches_search:    bool,
}

ticket_body_matches :: proc(asset: ^pr.Asset, query: string) -> bool {
	if query == "" do return true
	decoded: [32000]byte
	body := asset.payload
	if asset.payload_encoding == .Zstd {
		if asset.payload_raw_len > len(decoded) do return false
		body = decoded[:int(asset.payload_raw_len)]
		size := ZSTD_decompress(raw_data(body), uintptr(len(body)), raw_data(asset.payload), uintptr(len(asset.payload)))
		if ZSTD_isError(size) != 0 || size != uintptr(len(body)) do return false
	}
	lower := strings.to_lower(string(body)); defer delete(lower)
	return strings.contains(lower, query)
}

ticket_candidate_compare :: proc(a, b: Ticket_Candidate, descending: bool) -> bool {
	if a.number != b.number do return descending ? a.number > b.number : a.number < b.number
	if a.text != b.text do return descending ? a.text > b.text : a.text < b.text
	return a.asset.asset_id > b.asset.asset_id
}

// The caller owns a request arena. Nothing in this scan escapes into workspace
// state or asynchronous I/O. Predicates precede the cursor and page limit.
collect_ticket_page :: proc(
	conv: ^Conversation_State,
	q: Ticket_Query,
	username: string,
	allocator: mem.Allocator,
	read_cursors: map[pr.AssetID]pr.AssetID = nil,
) -> (
	page: Ticket_Page_Metadata,
	assets: [dynamic]pr.Asset,
) {
	context.allocator = allocator
	if conv == nil do return
	candidates := make([dynamic]Ticket_Candidate)
	by_id := make(map[pr.AssetID]int)
	parent, _ := strconv.parse_u64(q.parent)
	query := strings.to_lower(strings.trim_space(q.search))
	for id, asset in conv.assets {
		if !asset_visible_to(asset, username) do continue
		if q.mode == "entries" {
			if asset.asset_type == .TicketEntry && asset.parent_type == .Asset && asset.parent_id == parent {
				append(&candidates, Ticket_Candidate{asset = asset, number = asset.created_at})
			}
			continue
		}
		if asset.asset_type != .Ticket do continue
		m: Ticket_Metadata
		if json.unmarshal(asset.preview, &m) != nil do continue
		if q.status != "" && m.status != q.status || q.assignee != "" && m.assignee != q.assignee || q.company != "" && m.company_id != q.company do continue
		if q.mode == "attention" && m.assignee != "" && m.assignee != username do continue
		if q.search_results {
			found := false
			for value in q.ids {n, _ := strconv.parse_u64(value); if n == u64(id) {found = true; break}}
			if !found do continue
		}
		read := read_cursors[id]
		by_id[id] = len(candidates)
		searchable := strings.to_lower(fmt.aprint(m.title, "\n", m.requester, "\n", m.requester_name, "\n#", id))
		append(
			&candidates,
			Ticket_Candidate {
				asset = asset,
				metadata = m,
				latest = id,
				timestamp = asset.created_at,
				matches_search = query == "" || strings.contains(searchable, query) || ticket_body_matches(asset, query),
				activity = {unread = id > read && string(asset.owner) != username ? 1 : 0},
			},
		)
	}
	if q.mode != "entries" {
		for _, entry in conv.assets {
			if entry.asset_type != .TicketEntry || entry.parent_type != .Asset || !asset_visible_to(entry, username) do continue
			index, ok := by_id[pr.AssetID(entry.parent_id)]; if !ok do continue
			row := &candidates[index]
			if !row.matches_search do row.matches_search = ticket_body_matches(entry, query)
			row.timestamp = max(row.timestamp, entry.created_at)
			m: Ticket_Metadata
			if json.unmarshal(entry.preview, &m) != nil do continue
			if m.kind == "public_reply" do row.reply = max(row.reply, entry.asset_id)
			if m.kind == "customer_reply" {
				row.latest = max(row.latest, entry.asset_id)
				read := read_cursors[pr.AssetID(entry.parent_id)]
				if entry.asset_id > read do row.activity.unread += 1
			}
		}
		for &row in candidates {
			m := row.metadata
			paused := row.latest == row.asset.asset_id && (m.status == "waiting_customer" || m.status == "resolved" || m.status == "closed")
			row.activity.waiting = row.reply <= row.latest && !paused
			row.activity.latest = fmt.aprint(row.latest)
			row.activity.timestamp = fmt.aprint(row.timestamp)
			switch q.sort {
			case "id":
				row.number = i64(row.asset.asset_id)
			case "unread":
				row.number = i64(row.activity.unread)
			case "activity", "":
				row.number = row.timestamp
			case "title":
				row.text = m.title
			case "status":
				row.text = m.status
			case "assignee":
				row.text = m.assignee
			case "company_id", "contact_id":
				value := q.sort == "company_id" ? m.company_id : m.contact_id
				id, _ := strconv.parse_u64(value)
				linked := conv.assets[pr.AssetID(id)]
				name: Ticket_Metadata
				if linked != nil && asset_visible_to(linked, username) {_ = json.unmarshal(linked.preview, &name)}
				row.text = name.title
				if row.text == "" && value != "" do row.text = fmt.aprint("#", value)
				if q.sort == "contact_id" && value == "" do row.text = m.requester_name != "" ? m.requester_name : m.requester
			}
			row.text = strings.to_lower(row.text)
		}
	}
	if q.descending {slice.sort_by(candidates[:], proc(a, b: Ticket_Candidate) -> bool {return ticket_candidate_compare(a, b, true)})} else {slice.sort_by(candidates[:], proc(a, b: Ticket_Candidate) -> bool {return ticket_candidate_compare(a, b, false)})}
	cursor_id, _ := strconv.parse_u64(q.cursor.id)
	cursor_number, _ := strconv.parse_i64(q.cursor.number)
	cursor_asset := pr.Asset {
		asset_id = pr.AssetID(cursor_id),
	}
	cursor := Ticket_Candidate {
		asset  = &cursor_asset,
		number = cursor_number,
		text   = q.cursor.text,
	}
	limit := q.limit; if limit == 0 do limit = 50
	for row in candidates {
		if q.mode != "entries" && !row.matches_search do continue
		if q.mode == "attention" && !row.activity.waiting && row.activity.unread == 0 do continue
		page.total_count += 1
		if cursor_id != 0 && !ticket_candidate_compare(cursor, row, q.descending) do continue
		if len(assets) >= limit || page.has_more {page.has_more = true; continue}
		previous_cursor := page.cursor
		append(&assets, row.asset^)
		append(&page.activity, row.activity)
		page.cursor = {fmt.aprint(row.asset.asset_id), fmt.aprint(row.number), row.text}
		// Reserve enough digits for the eventual total count; it is finalized by
		// the scan, independently of the cursor and byte-bounded returned rows.
		probe := page; probe.total_count = len(candidates)
		metadata, _ := json.marshal(probe)
		size := pr.getSizeTicketPage({metadata = metadata, assets = assets[:], full_content = q.mode == "entries"})
		delete(metadata)
		if size > MAX_PROTOCOL_PAYLOAD_SIZE {
			pop(&assets); pop(&page.activity)
			page.cursor = previous_cursor; page.has_more = true
		}
	}
	return
}

handle_query_tickets :: proc(c: ^NRC_Connection, req: pr.TicketQueryRequest) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {send_error_response(c, .C_QueryTickets, "Ticket query allocation failed", req.correlation_id); return}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	q: Ticket_Query
	if json.unmarshal(req.query, &q, allocator = allocator) != nil ||
	   q.limit < 0 ||
	   q.limit > 250 ||
	   len(q.ids) > 100 ||
	   (q.mode != "" && q.mode != "entries" && q.mode != "attention" && q.mode != "read") ||
	   (q.sort != "" &&
			   q.sort != "id" &&
			   q.sort != "activity" &&
			   q.sort != "unread" &&
			   q.sort != "title" &&
			   q.sort != "status" &&
			   q.sort != "assignee" &&
			   q.sort != "company_id" &&
			   q.sort != "contact_id") {
		send_error_response(c, .C_QueryTickets, "Invalid ticket query", req.correlation_id); return
	}
	if q.cursor.id != "" {
		id, id_ok := strconv.parse_u64(q.cursor.id)
		_, number_ok := strconv.parse_i64(q.cursor.number)
		if !id_ok || id == 0 || !number_ok {send_error_response(c, .C_QueryTickets, "Invalid ticket cursor", req.correlation_id); return}
	}
	if q.mode == "entries" {
		id, ok := strconv.parse_u64(q.parent)
		if !ok || id == 0 {send_error_response(c, .C_QueryTickets, "Invalid ticket parent", req.correlation_id); return}
	}
	conv := get_conversation(get_connection_workspace(c), 0)
	if q.mode == "read" {
		if q.read_snapshot == 0 || (!q.read_start && c.ticket_read_upload != q.read_snapshot) {
			send_error_response(c, .C_QueryTickets, "Invalid ticket read upload", req.correlation_id); return
		}
		if q.read_start {
			if c.ticket_read_cursors == nil do c.ticket_read_cursors = make(map[pr.AssetID]pr.AssetID)
			clear(&c.ticket_read_cursors)
			c.ticket_read_snapshot = 0; c.ticket_read_upload = q.read_snapshot
		}
		for key, value in q.read {
			id, id_ok := strconv.parse_u64(key); through, through_ok := strconv.parse_u64(value)
			if !id_ok || !through_ok {send_error_response(c, .C_QueryTickets, "Invalid ticket read cursor", req.correlation_id); return}
			// Historical/deleted IDs need not consume connection memory.
			if conv != nil {
				asset := conv.assets[pr.AssetID(id)]
				if asset != nil && asset.asset_type == .Ticket do c.ticket_read_cursors[pr.AssetID(id)] = pr.AssetID(through)
			}
		}
		if q.read_end {c.ticket_read_snapshot = q.read_snapshot; c.ticket_read_upload = 0}
	} else if q.read_snapshot != 0 && q.read_snapshot != c.ticket_read_snapshot {
		send_error_response(c, .C_QueryTickets, "Ticket read snapshot unavailable", req.correlation_id); return
	}
	page: Ticket_Page_Metadata
	assets: [dynamic]pr.Asset
	if q.mode != "read" {
		reads: map[pr.AssetID]pr.AssetID
		if q.read_snapshot != 0 do reads = c.ticket_read_cursors
		page, assets = collect_ticket_page(conv, q, get_connection_nickname(c), allocator, reads)
	}
	if page.has_more && len(assets) == 0 {send_error_response(c, .C_QueryTickets, "Ticket exceeds page byte limit", req.correlation_id); return}
	metadata, err := json.marshal(page, allocator = allocator)
	if err != nil {send_error_response(c, .C_QueryTickets, "Ticket page encoding failed", req.correlation_id); return}
	msg := pr.TicketPage {
		correlation_id = req.correlation_id,
		metadata       = metadata,
		assets         = assets[:],
		full_content   = q.mode == "entries",
	}
	buf, h := allocate_websocket_frame_buffer(pr.getSizeTicketPage(msg), "ticket page"); if buf == nil do return
	n := pr.serializeTicketPage(msg, buf[h:]); if n < 0 {byte_pool.release(td.spool, buf); return}
	_ = send_pooled_buffer(c, buf[:h + n])
}
