package main

import "btree"
import "byte_pool"
import "clock"
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
Ticket_Metadata :: Ticket_Preview
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
Ticket_Candidate :: struct {
	asset:             ^pr.Asset,
	metadata:          Ticket_Preview,
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
	now_ms: i64 = -1,
) -> (
	page: Ticket_Page_Metadata,
	assets: [dynamic]pr.Asset,
) {
	context.allocator = allocator
	page.total_count_omitted = q.omit_total_count
	if conv == nil do return
	current_ms := now_ms
	if current_ms < 0 do current_ms = clock.now()._nsec / 1_000_000
	// The polling client needs neither a full count nor other sort orders. Other
	// queries retain their existing counting, search and ordering contracts.
	if q.omit_total_count && q.mode == "attention" && q.sort == "id" && q.descending && q.search == "" {
		return collect_ticket_attention_indexed(conv, q, username, read_cursors, current_ms)
	}
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
		m, valid := parse_ticket_preview(asset.preview, allocator)
		if !valid do continue
		if m.priority == "" do m.priority = "normal"
		if q.priority != "" && m.priority != q.priority do continue
		follow_up, valid_follow_up := ticket_follow_up_time(m.follow_up_at)
		if q.follow_up == "due" && (!valid_follow_up || follow_up <= 0 || follow_up > current_ms) do continue
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
			m, valid := parse_ticket_entry_preview(entry.preview, allocator)
			if !valid do continue
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
			follow_up, valid := ticket_follow_up_time(m.follow_up_at)
			row.activity.follow_up_due = valid && follow_up > 0 && follow_up <= current_ms
			row.activity.latest = fmt.aprint(row.latest)
			row.activity.timestamp = fmt.aprint(row.timestamp)
			switch q.sort {
			case "id":
				row.number = i64(row.asset.asset_id)
			case "unread":
				row.number = i64(row.activity.unread)
			case "priority":
				switch m.priority {
				case "low":
					row.number = 0
				case "normal":
					row.number = 1
				case "high":
					row.number = 2
				case "urgent":
					row.number = 3
				}
			case "follow_up_at":
				// Unscheduled uses zero: first ascending, last descending.
				// Keep the existing numeric value cursor and binary protocol intact.
				row.number, _ = ticket_follow_up_time(m.follow_up_at)
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
				name: struct {
					title: string,
				}
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
		if q.mode == "attention" && !row.activity.waiting && row.activity.unread == 0 && !row.activity.follow_up_due do continue
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
	if q.omit_total_count do page.total_count = 0
	return
}

// Two exact-assignee ranges, merged by descending ID. Each request owns its
// iterators; the value cursor remains usable after deletion or reassignment.
collect_ticket_attention_indexed :: proc(
	conv: ^Conversation_State,
	q: Ticket_Query,
	username: string,
	reads: map[pr.AssetID]pr.AssetID,
	now_ms: i64,
) -> (
	page: Ticket_Page_Metadata,
	assets: [dynamic]pr.Asset,
) {
	page.total_count_omitted = true
	if conv.ticket_index == nil do return
	owners := [2]string{username, ""}
	its := [2]btree.IterG(Ticket_Assignee_Key, Ticket_Assignee_Order){btree.iter(&conv.ticket_assignees), btree.iter(&conv.ticket_assignees)}
	defer for &it in its do btree.iter_destroy(&it)
	active: [2]bool
	cursor, _ := strconv.parse_u64(q.cursor.id)
	for &it, i in its {
		if i == 1 && username == "" do continue
		key := Ticket_Assignee_Key{owners[i], cursor == 0 ? pr.AssetID(max(i64)) : pr.AssetID(cursor)}
		ok := btree.iter_seek(&it, key)
		if !ok {ok = btree.iter_last(&it)} else if ticket_assignee_compare(btree.item(&it), key) > 0 || cursor != 0 {
			ok = btree.iter_prev(&it)
		}
		active[i] = ok && btree.item(&it).assignee == owners[i]
	}
	limit := q.limit == 0 ? 50 : q.limit
	for active[0] || active[1] {
		i := 0
		if !active[0] || active[1] && i64(btree.item(&its[1]).id) > i64(btree.item(&its[0]).id) do i = 1
		id := btree.item(&its[i]).id
		active[i] = btree.iter_prev(&its[i]) && btree.item(&its[i]).assignee == owners[i]
		asset := conv.assets[id]
		row := conv.ticket_index[id]
		m := row.metadata
		if q.status != "" && m.status != q.status || q.assignee != "" && m.assignee != q.assignee || q.company != "" && m.company_id != q.company do continue
		priority := m.priority == "" ? "normal" : m.priority
		if q.priority != "" && q.priority != priority do continue
		if q.search_results {
			found := false
			for value in q.ids {n, _ := strconv.parse_u64(value); if n == u64(id) {found = true; break}}
			if !found do continue
		}
		activity, latest := ticket_index_activity(row, asset, username, reads[id], now_ms)
		if q.follow_up == "due" && !activity.follow_up_due do continue
		if !activity.waiting && activity.unread == 0 && !activity.follow_up_due do continue
		if len(assets) >= limit {page.has_more = true; break}
		activity.latest = fmt.aprint(latest)
		activity.timestamp = fmt.aprint(row.timestamp)
		previous := page.cursor
		append(&assets, asset^); append(&page.activity, activity)
		page.cursor = {fmt.aprint(id), fmt.aprint(i64(id)), ""}
		metadata, _ := json.marshal(page)
		size := pr.getSizeTicketPage({metadata = metadata, assets = assets[:]})
		delete(metadata)
		if size > MAX_PROTOCOL_PAYLOAD_SIZE {
			pop(&assets); pop(&page.activity)
			page.cursor = previous; page.has_more = true; break
		}
	}
	return
}

handle_query_tickets :: proc(c: ^NRC_Connection, req: pr.TicketQueryRequest) {
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {send_error_response(c, .C_QueryTickets, "Ticket query allocation failed", req.correlation_id); return}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	fields, object, valid := json_metadata_fields(req.query, [?]string{"priority", "follow_up"}, allocator)
	if !valid || !object {
		send_error_response(c, .C_QueryTickets, "Invalid ticket query", req.correlation_id); return
	}
	for field in fields {
		if field.kind != .Invalid && field.kind != .String {
			send_error_response(c, .C_QueryTickets, "Invalid ticket query", req.correlation_id); return
		}
	}
	q: Ticket_Query
	if json.unmarshal(req.query, &q, allocator = allocator) != nil ||
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
