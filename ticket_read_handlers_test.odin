package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:mem/virtual"
import "core:testing"
import hgl "hegel"
import pr "protocol"

when !NRC_SIMULATION {_ :: endian.get_u32; _ :: hgl.run}

when NRC_SIMULATION {
	prop_ticket_paging_reference :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
		// Small domains deliberately generate ties and interleaved nonmatches.
		choices: [66]i64
		for &choice in choices {
			value, err := hgl.draw_i64(tc, 0, 5)
			if err == .Stop_Test do return hgl.abort()
			if err != nil do return hgl.interesting("ticket fixture draw failed")
			choice = value
		}
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 199)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "ticket-property", "alice")
		ctx.conns[1] = c
		if c == nil do return hgl.interesting("install ticket client")
		conv := get_or_create_conversation(c.workspace, 0)
		arena: virtual.Arena
		if virtual.arena_init_growing(&arena) != nil do return hgl.interesting("ticket arena")
		defer virtual.arena_destroy(&arena)
		a := virtual.arena_allocator(&arena)
		titles := [?]string{"alpha", "bravo", "charlie"}
		statuses := [?]string{"closed", "open"}
		owners := [?]string{"alice", "bob"}
		companies := [?]string{"42", "43"}
		sorts := [?]string{"id", "title", "activity", "status", "assignee", "company_id"}
		q := Ticket_Query {
			sort       = sorts[choices[0]],
			descending = choices[1] % 2 == 1,
			limit      = int(choices[2]) + 1,
		}
		if choices[3] < 2 do q.status = statuses[choices[3]]
		if choices[4] < 2 do q.assignee = owners[choices[4]]
		if choices[5] < 2 do q.company = companies[choices[5]]
		expected: [12]int
		keys: [12]i64
		assets: [12]^pr.Asset
		count := 0
		for i in 0 ..< 12 {
			title := choices[6 + i * 5] % 3
			status := choices[7 + i * 5] % 2
			owner := choices[8 + i * 5] % 2
			company := choices[9 + i * 5] % 2
			activity := choices[10 + i * 5] + 1
			metadata, err := json.marshal(
				Ticket_Metadata{title = titles[title], status = statuses[status], assignee = owners[owner], company_id = companies[company]},
				allocator = a,
			)
			if err != nil do return hgl.interesting("encode fixture")
			assets[i] = asset_query_test_install_asset(conv, 0, pr.AssetID(i + 1), .Ticket, string(metadata), "", activity)
			if assets[i] == nil do return hgl.interesting("install ticket fixture")
			assets[i].created_at = activity
			// Independent numeric ranks model lexical order of the fixed labels.
			keys[i] = ([6]i64{i64(i + 1), title, activity, status, owner, company})[choices[0]]
			if q.status != "" && q.status != statuses[status] || q.assignee != "" && q.assignee != owners[owner] || q.company != "" && q.company != companies[company] do continue
			expected[count] = i; count += 1
		}
		// Insertion sort, independent of the production candidate comparator.
		// Equal primary keys always use descending IDs, in either direction.
		for i in 1 ..< count {
			value := expected[i]
			j := i
			for j > 0 {
				previous := expected[j - 1]
				before := keys[value] < keys[previous]
				if q.descending do before = keys[value] > keys[previous]
				if keys[value] == keys[previous] do before = value > previous
				if !before do break
				expected[j] = previous; j -= 1
			}
			expected[j] = value
		}
		offset := 0
		for page_index in 0 ..< 13 {
			query, err := json.marshal(q, allocator = a)
			if err != nil do return hgl.interesting("encode ticket query")
			wire := make([]byte, 6 + len(query), a)
			endian.put_u16(wire, .Big, u16(pr.Opcode.C_QueryTickets))
			endian.put_u32(wire[2:], .Big, u32(page_index + 1))
			copy(wire[6:], query)
			nrc_sim_clear_inboxes(&ctx.sim)
			if !handler_equivalence_deliver_wire(&ctx.sim, c, wire, int(choices[4]), int(choices[5])) do return hgl.interesting("deliver ticket query")
			if nrc_sim_client_frame_count(&ctx.sim, c.sock) != 1 do return hgl.interesting("ticket response count")
			payload, ok := nrc_sim_frame_protocol_payload(nrc_sim_client_frame(&ctx.sim, c.sock, 0))
			if !ok || len(payload) < 13 do return hgl.interesting("ticket response frame")
			opcode, _ := endian.get_u16(payload, .Big)
			correlation, _ := endian.get_u32(payload[2:], .Big)
			length, _ := endian.get_u32(payload[6:], .Big)
			if opcode != u16(pr.Opcode.S_TicketPage) || correlation != u32(page_index + 1) || int(length) > len(payload) - 13 do return hgl.interesting("ticket response header")
			page: Ticket_Page_Metadata
			if json.unmarshal(payload[10:10 + int(length)], &page, allocator = a) != nil do return hgl.interesting("ticket metadata")
			n := min(q.limit, count - offset)
			if page.total_count != count || page.has_more != (offset + n < count) do return hgl.interesting("ticket total or continuation differs from model")
			pos := 10 + int(length)
			row_count, _ := endian.get_u16(payload[pos:], .Big)
			if int(row_count) != n || payload[pos + 2] != 0 do return hgl.interesting("ticket page size differs from model")
			pos += 3
			for index in expected[offset:offset + n] {
				asset := assets[index]^
				bytes := make([]byte, pr.getSizeAssetHeader(asset), a)
				if pr.serializeAssetHeader(asset, bytes) != len(bytes) || pos + len(bytes) > len(payload) do return hgl.interesting("ticket row encoding")
				for byte, k in bytes do if payload[pos + k] != byte do return hgl.interesting("ticket ordering or membership differs from model")
				pos += len(bytes)
			}
			if pos != len(payload) do return hgl.interesting("unexpected ticket rows")
			offset += n
			if !page.has_more do return hgl.valid()
			q.cursor = page.cursor
		}
		return hgl.interesting("ticket paging did not terminate")
	}
}

@(test)
test_hegel_ticket_paging_reference :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		if !hgl.can_run() do return
		result, err := hgl.run(prop_ticket_paging_reference, nil, {test_cases = 128})
		testing.expectf(t, err == nil, "ticket paging reference failed: err=%v interesting=%v", err, result.interesting_test_cases)
	}
}

@(test)
test_ticket_read_snapshot_connection_lifecycle :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 198)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "ticket-read", "alice")
		ctx.conns[1] = c
		if c == nil do return
		conv := get_or_create_conversation(c.workspace, 0)
		arena: virtual.Arena
		testing.expect(t, virtual.arena_init_growing(&arena) == nil)
		defer virtual.arena_destroy(&arena)
		_ = asset_query_test_install_asset(conv, 0, 10, .Ticket, `{"title":"Read me","status":"open"}`, "", 1)
		queries := [?]string {
			`{"mode":"read","read_snapshot":7,"read_start":true,"read":{"10":"10"}}`,
			`{"read_snapshot":7}`,
			`{"mode":"read","read_snapshot":7,"read_end":true,"read":{"999":"999"}}`,
			`{"read_snapshot":7}`,
		}
		for query, i in queries {
			nrc_sim_clear_inboxes(&ctx.sim)
			wire := make([]byte, 6 + len(query)); defer delete(wire)
			endian.put_u16(wire, .Big, u16(pr.Opcode.C_QueryTickets))
			endian.put_u32(wire[2:], .Big, 321)
			copy(wire[6:], transmute([]byte)query)
			process_protocol_payload(c, wire)
			expected := i == 1 ? pr.Opcode.S_ErrorResponse : pr.Opcode.S_TicketPage
			payload, ok := customer_read_test_payload(t, &ctx, c, expected)
			if !ok do return
			if i == 3 {
				length, _ := endian.get_u32(payload[6:], .Big)
				page: Ticket_Page_Metadata
				testing.expect(t, json.unmarshal(payload[10:10 + int(length)], &page, allocator = virtual.arena_allocator(&arena)) == nil)
				testing.expect_value(t, page.total_count, 1)
				testing.expect_value(t, page.activity[0].unread, 0)
			}
		}
		// The snapshot must neither survive nor leak through a replaced connection.
		simulation_test_uninstall_client(c); ctx.conns[1] = nil
		c = simulation_test_install_client(&ctx.sim, 1, "ticket-read", "alice"); ctx.conns[1] = c
		nrc_sim_clear_inboxes(&ctx.sim)
		handle_query_tickets(c, {correlation_id = 322, query = transmute([]byte)string(`{"read_snapshot":7}`)})
		_, _ = customer_read_test_payload(t, &ctx, c, .S_ErrorResponse)
	}
}

@(test)
test_ticket_filtered_pages_and_activity :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset); defer delete(conv.assets)
	open := transmute([]byte)string(`{"title":"same","status":"open","assignee":"alice","company_id":"42"}`)
	closed := transmute([]byte)string(`{"title":"first","status":"closed","assignee":"alice","company_id":"42"}`)
	other := transmute([]byte)string(`{"title":"other","status":"open","assignee":"bob","company_id":"43"}`)
	items := [?]pr.Asset {
		{asset_id = 1, asset_type = .Ticket, preview = closed},
		{asset_id = 2, asset_type = .Ticket, preview = open, created_at = 2},
		{asset_id = 3, asset_type = .Ticket, preview = other},
		{asset_id = 4, asset_type = .Ticket, preview = open, created_at = 4},
		{
			asset_id = 5,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 10,
			preview = transmute([]byte)string(`{"kind":"customer_reply"}`),
			payload = transmute([]byte)string("Needle in conversation"),
		},
		{
			asset_id = 6,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 11,
			preview = transmute([]byte)string(`{"kind":"internal_note"}`),
		},
	}
	for &item in items do conv.assets[item.asset_id] = &item
	q := Ticket_Query {
		status   = "open",
		assignee = "alice",
		company  = "42",
		sort     = "title",
		limit    = 1,
	}
	page, rows := collect_ticket_page(&conv, q, "alice", a)
	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(4))
	testing.expect(t, page.has_more)
	q.cursor = page.cursor
	// A value cursor still works if its source record disappears.
	delete_key(&conv.assets, 4)
	page, rows = collect_ticket_page(&conv, q, "alice", a)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(2))
	testing.expect(t, !page.has_more)
	conv.assets[4] = &items[3]
	directions := [?]bool{false, true}
	for descending in directions {
		page, rows = collect_ticket_page(&conv, {sort = "activity", descending = descending, limit = 1}, "alice", a)
		testing.expect_value(t, rows[0].asset_id, descending ? pr.AssetID(1) : pr.AssetID(3))
	}
	page, rows = collect_ticket_page(&conv, {search = "NEEDLE", limit = 1}, "alice", a)
	testing.expect_value(t, page.total_count, 1)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(1))
	testing.expect(t, page.activity[0].waiting, "closed ticket with a follow-up still needs a reply")
	testing.expect_value(t, page.activity[0].timestamp, "11")
	read := make(map[pr.AssetID]pr.AssetID); defer delete(read)
	read[1] = 5
	page, rows = collect_ticket_page(&conv, {mode = "attention", sort = "activity", descending = true}, "alice", a, read)
	testing.expect_value(t, len(rows), 3)
	testing.expect_value(t, page.activity[0].unread, 0)
	testing.expect(t, page.activity[0].waiting, "reading does not answer a customer")
	page, rows = collect_ticket_page(&conv, {mode = "entries", parent = "1", limit = 1}, "alice", a)
	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(5))
	testing.expect(t, page.has_more)
}

@(test)
test_ticket_entry_byte_pages :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset); defer delete(conv.assets)
	body := make([]byte, 32000); defer delete(body)
	items: [5]pr.Asset
	for &item, i in items {
		item = {
			asset_id        = pr.AssetID(i + 1),
			asset_type      = .TicketEntry,
			parent_type     = .Asset,
			parent_id       = 99,
			created_at      = i64(i),
			payload         = body,
			payload_raw_len = u32(len(body)),
		}
		conv.assets[item.asset_id] = &item
	}
	q := Ticket_Query {
		mode   = "entries",
		parent = "99",
		limit  = 50,
	}
	page, rows := collect_ticket_page(&conv, q, "alice", a)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, page.total_count, 5)
	testing.expect(t, page.has_more)
	metadata, err := json.marshal(page, allocator = a); testing.expect(t, err == nil)
	msg := pr.TicketPage {
		metadata     = metadata,
		assets       = rows[:],
		full_content = true,
	}
	size := pr.getSizeTicketPage(msg)
	testing.expect(t, size <= MAX_PROTOCOL_PAYLOAD_SIZE)
	buf := make([]byte, size, a)
	testing.expect_value(t, pr.serializeTicketPage(msg, buf), size)
	q.cursor = page.cursor
	page, rows = collect_ticket_page(&conv, q, "alice", a)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(5))
	testing.expect(t, !page.has_more)
}
