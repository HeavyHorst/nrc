package main

import "core:encoding/endian"
import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import hgl "hegel"
import "persistence"
import pr "protocol"

when !NRC_SIMULATION {_ :: endian.get_u32; _ :: hgl.run}

// Compare the public page result with the scan path after real store mutations.
// Keeping the scan independent also protects the reader-specific unread rules.
ticket_index_test_equivalent :: proc(t: ^testing.T, conv: ^Conversation_State) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	read := make(map[pr.AssetID]pr.AssetID, a)
	users := [?]string{"alice", "bob", "Sam", "", "nobody"}
	watermarks := [?]pr.AssetID{0, 1, 12, 35, 999}
	for user in users {
		for watermark in watermarks {
			for id, asset in conv.assets do if asset.asset_type == .Ticket {read[id] = watermark}
			q := Ticket_Query {
				mode       = "attention",
				sort       = "id",
				descending = true,
				limit      = 2,
			}
			for {
				expected, want := collect_ticket_page(conv, q, user, a, read, now_ms = 1000)
				q.omit_total_count = true
				actual, got := collect_ticket_page(conv, q, user, a, read, now_ms = 1000)
				testing.expect(t, actual.total_count_omitted)
				testing.expect(t, !expected.total_count_omitted)
				testing.expect_value(t, actual.has_more, expected.has_more)
				testing.expect_value(t, actual.cursor, expected.cursor)
				testing.expect_value(t, len(got), len(want))
				if len(got) != len(want) do return
				for asset, i in got {
					testing.expect_value(t, asset.asset_id, want[i].asset_id)
					testing.expect_value(t, actual.activity[i], expected.activity[i])
				}
				if !expected.has_more do break
				q.cursor = expected.cursor
				q.omit_total_count = false
			}
		}
	}
}

@(test)
test_ticket_index_store_lifecycle :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(conv)
	defer destroy_conversation(conv)
	ws: Workspace_State
	ticket_index_test_equivalent(t, conv)
	// Deliberately out-of-order child IDs, before their parent exists.
	entry_ids := [?]int{35, 12, 30}
	for id in entry_ids {
		preview := transmute([]byte)string(`{"version":1,"kind":"customer_reply","author":"alice","title":"first","title":"second"}`)
		body := transmute([]byte)string("reply")
		testing.expect(t, validate_ticket_asset(.TicketEntry, .Asset, 1, .Plain, u32(len(body)), preview, body))
		entry := alloc_asset(nil, preview, body)
		entry.asset_id = pr.AssetID(id); entry.asset_type = .TicketEntry
		entry.parent_type = .Asset; entry.parent_id = 1; entry.created_at = i64(id)
		asset_store_put(&ws, "test", conv, entry)
	}
	for id in 1 ..< 7 {
		preview := fmt.aprintf(
			`{{"title":"T%d","assignee":"%s","status":"closed","follow_up_at":"%s"}}`,
			id,
			id % 3 == 0 ? "bob" : id % 3 == 1 ? "alice" : "",
			id % 2 == 0 ? "999" : "1001",
		)
		asset := alloc_asset(nil, transmute([]byte)preview, nil); delete(preview)
		asset.asset_id = pr.AssetID(id); asset.asset_type = .Ticket; asset.created_at = i64(id)
		asset_store_put(&ws, "test", conv, asset)
	}
	ticket_index_test_equivalent(t, conv)
	// Reclassify the last customer reply to public, then internal, then customer.
	kinds := [?]string{"public_reply", "internal_note", "customer_reply"}
	for kind in kinds {
		preview := fmt.aprintf(`{{"kind":"%s"}}`, kind)
		entry := alloc_asset(nil, transmute([]byte)preview, nil); delete(preview)
		entry.asset_id = 35; entry.asset_type = .TicketEntry; entry.parent_type = .Asset; entry.parent_id = 1; entry.created_at = 10
		asset_store_put(&ws, "test", conv, entry)
		ticket_index_test_equivalent(t, conv)
	}
	// A replacement changes decoded/escaped assignee storage and due state.
	asset := alloc_asset(nil, transmute([]byte)string(`{"title":"Renamed","assignee":"b\u006fb","status":"open","follow_up_at":"1000"}`), nil)
	asset.asset_id = 1; asset.asset_type = .Ticket; asset.created_at = 1
	asset_store_put(&ws, "test", conv, asset)
	ticket_index_test_equivalent(t, conv)
	// Remove the highest incoming ID and timestamp, then the parent before children.
	deletions := [?]pr.AssetID{35, 30, 1, 12, 2, 3, 4, 5, 6}
	for id in deletions {
		asset_store_remove(&ws, conv, id)
		ticket_index_test_equivalent(t, conv)
	}
}

@(test)
test_ticket_metadata_allocation_failure :: proc(t: ^testing.T) {
	testing.expect_assert(t, "failed to allocate ticket metadata")
	m: Ticket_Metadata
	_ = ticket_metadata_read(transmute([]byte)string(`{"title":"Ticket"}`), &m, mem.Allocator{procedure = json_metadata_failing_allocator})
	testing.expect(t, false, "post-WAL index publication must fail-stop")
}

@(test)
test_ticket_reply_allocation_failure :: proc(t: ^testing.T) {
	testing.expect_assert(t, "failed to grow ticket reply index")
	row: Ticket_Index_Row
	row.customers.allocator = mem.Allocator {
		procedure = json_metadata_failing_allocator,
	}
	entry := pr.Asset {
		asset_id = 42,
		preview  = transmute([]byte)string(`{"kind":"customer_reply"}`),
	}
	ticket_index_add_entry(&row, &entry)
	testing.expect(t, false, "post-WAL index publication must fail-stop")
}

@(test)
test_ticket_scratch_bookkeeping_allocation_failure :: proc(t: ^testing.T) {
	testing.expect_assert(t, "failed to allocate ticket scratch bookkeeping")
	buffer: [8192]byte
	blocks: mem.Arena
	mem.arena_init(&blocks, buffer[:])
	failing := mem.Allocator {
		procedure = json_metadata_failing_allocator,
	}
	scratch: mem.Dynamic_Arena
	mem.dynamic_arena_init(
		&scratch,
		block_allocator = mem.arena_allocator(&blocks),
		array_allocator = mem.Allocator{procedure = ticket_scratch_array_allocator, data = &failing},
		block_size = 4096,
		out_band_size = 4096,
	)
	m: Ticket_Metadata
	testing.expect(t, ticket_metadata_read(transmute([]byte)string(`{"kind":"public_reply"}`), &m, mem.dynamic_arena_allocator(&scratch)))
	// The block decode succeeded. The tracking-array allocation on destruction
	// must fail-stop rather than silently lose the block pointer.
	mem.dynamic_arena_destroy(&scratch)
	testing.expect(t, false, "scratch bookkeeping failure must not return")
}

@(test)
test_ticket_index_transaction_and_replay :: proc(t: ^testing.T) {
	workspace := "ticket-index-replay"
	if !init_room_mapping_test_state("ticket_index_replay.log", workspace) {testing.expect(t, false); return}
	defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace)
	defer send_queue_destroy(&c)
	td.asset_seq = 0
	preview := `{"version":1,"title":"Login","company_id":"","contact_id":"","requester":"ada@example.test","requester_name":"Ada","status":"closed","assignee":"Sam","follow_up_at":"1000"}`
	asset_handler_test_create(&c, 0, .Ticket, .None, 0, preview, "Cannot sign in")
	asset_handler_test_create(&c, 0, .TicketEntry, .Asset, 1, `{"version":1,"kind":"customer_reply","author":"Ada"}`, "Still broken")
	asset_handler_test_create(&c, 0, .TicketEntry, .Asset, 1, `{"version":1,"kind":"public_reply","author":"Sam"}`, "Please retry")
	conv := get_conversation(get_workspace(workspace), 0)
	testing.expect(t, conv != nil && len(conv.assets) == 3)
	if conv == nil || len(conv.assets) != 3 do return
	ticket_index_test_equivalent(t, conv)
	patched := `{"version":1,"title":"Login fixed","company_id":"","contact_id":"","requester":"ada@example.test","requester_name":"Ada","status":"closed","assignee":"","follow_up_at":"1001"}`
	body := make([]byte, 31 + len(patched)); defer delete(body)
	endian.put_u64(body[:], .Big, 0)
	transaction_test_ref(body[8:], .Existing, .Asset, 1)
	endian.put_u64(body[20:], .Big, u64(conv.assets[1].updated_at))
	body[28] = pr.TRANSACTION_ASSET_PATCH_PREVIEW
	endian.put_u16(body[29:], .Big, u16(len(patched)))
	copy(body[31:], transmute([]byte)patched)
	ops := [1]pr.TransactionOperation{{op_type = .AssetPatch, body = body}}
	process_apply_transaction(&c, {operations = ops[:]})
	testing.expect_value(t, string(conv.assets[1].preview), patched)
	ticket_index_test_equivalent(t, conv)
	// Restore children first from serialized records, then release each record
	// buffer before querying; no cached metadata may borrow those buffers.
	for id in ([?]pr.AssetID{3, 2, 1}) {
		asset := conv.assets[id]
		record := make([]byte, persistence.LOG_HEADER_SIZE + calculate_asset_payload_size(workspace, asset))
		serialize_asset_to_record(record, workspace, asset)
		payload := record[persistence.LOG_HEADER_SIZE:]
		_, offset, prefix_ok := persistence.parse_workspace_prefix(payload)
		parsed, parse_ok := parse_asset_from_payload(payload, offset, ASSET_LOG_VERSION)
		testing.expect(t, prefix_ok && parse_ok)
		testing.expect(t, apply_persisted_asset("ticket-index-restored", &parsed))
		delete(record)
	}
	restored := get_conversation(get_workspace("ticket-index-restored"), 0)
	ticket_index_test_equivalent(t, restored)
	apply_persisted_asset_delete("ticket-index-restored", 0, 3)
	ticket_index_test_equivalent(t, restored)
}

@(test)
test_ticket_index_cursor_and_byte_pages :: proc(t: ^testing.T) {
	conv := new(Conversation_State)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_note_index(conv)
	defer destroy_conversation(conv)
	ws: Workspace_State
	padding := make([]byte, 3900); defer delete(padding)
	for &c in padding do c = 'x'
	ids: [40]pr.AssetID
	for &id, i in ids do id = pr.AssetID(i + 1)
	ids[36] = pr.AssetID(max(i64)) - 1; ids[37] = pr.AssetID(max(i64))
	ids[38] = pr.AssetID(max(i64)) + 1; ids[39] = max(pr.AssetID)
	for id, i in ids {
		preview := fmt.aprintf(`{{"assignee":"%s","status":"closed","follow_up_at":"1","extra":"%s"}}`, i % 2 == 0 ? "alice" : "", string(padding))
		asset := alloc_asset(nil, transmute([]byte)preview, nil); delete(preview)
		asset.asset_id = id; asset.asset_type = .Ticket
		asset_store_put(&ws, "test", conv, asset)
	}
	ticket_index_test_equivalent(t, conv)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	q := Ticket_Query {
		mode             = "attention",
		sort             = "id",
		descending       = true,
		limit            = 250,
		omit_total_count = true,
	}
	seen := make(map[pr.AssetID]bool, a)
	for {
		page, rows := collect_ticket_page(conv, q, "alice", a, now_ms = 1000)
		testing.expect(t, page.total_count_omitted && page.total_count == 0)
		testing.expect_value(t, len(rows), len(page.activity))
		metadata, _ := json.marshal(page, allocator = a)
		msg := pr.TicketPage {
			metadata = metadata,
			assets   = rows[:],
		}
		size := pr.getSizeTicketPage(msg)
		testing.expect(t, size <= MAX_PROTOCOL_PAYLOAD_SIZE)
		buf := make([]byte, size, a)
		testing.expect_value(t, pr.serializeTicketPage(msg, buf), size)
		for row in rows {testing.expect(t, !seen[row.asset_id]); seen[row.asset_id] = true}
		if !page.has_more do break
		testing.expect(t, len(rows) > 0 && page.cursor != q.cursor)
		q.cursor = page.cursor
		// Deleting the cursor record must not lose the following range.
		asset_store_remove(&ws, conv, rows[len(rows) - 1].asset_id)
	}
	testing.expect_value(t, len(seen), len(ids))
}

@(test)
test_ticket_schedule_query_validation :: proc(t: ^testing.T) {
	when NRC_SIMULATION {
		ctx: Sim_Test_Context
		simulation_test_begin(&ctx, 197)
		defer simulation_test_end(&ctx)
		c := simulation_test_install_client(&ctx.sim, 1, "ticket-schedule", "alice")
		ctx.conns[1] = c
		if c == nil do return
		queries := [?]string {
			`{"priority":"invalid"}`,
			`{"follow_up":"tomorrow"}`,
			`{"priority":null}`,
			`{"follow_up":12}`,
			`{"follow_up":null}`,
			`{"priority":"low","priority":"high"}`,
			`{"priority":"normal","follow_up":"due","sort":"priority"}`,
			`{"follow_up":"all","sort":"follow_up_at"}`,
			`{"priority":"","follow_up":""}`,
		}
		for query, i in queries {
			nrc_sim_clear_inboxes(&ctx.sim)
			handle_query_tickets(c, {correlation_id = 333, query = transmute([]byte)query})
			_, _ = customer_read_test_payload(t, &ctx, c, i < 6 ? .S_ErrorResponse : .S_TicketPage)
		}
	}
}

@(test)
test_ticket_priority_follow_up_validation :: proc(t: ^testing.T) {
	base := `{"version":1,"title":"Ticket","company_id":"","contact_id":"","requester":"","requester_name":"","status":"open","assignee":""`
	valid := [?]string {
		"",
		`,"priority":"low"`,
		`,"priority":"normal"`,
		`,"priority":"high"`,
		`,"priority":"urgent"`,
		`,"follow_up_at":""`,
		`,"follow_up_at":"1"`,
		`,"follow_up_at":"9223372036854775807"`,
	}
	invalid := [?]string {
		`,"priority":""`,
		`,"priority":null`,
		`,"priority":1`,
		`,"priority":"HIGH"`,
		`,"follow_up_at":null`,
		`,"follow_up_at":1`,
		`,"follow_up_at":"0"`,
		`,"follow_up_at":"01"`,
		`,"follow_up_at":"-1"`,
		`,"follow_up_at":"+1"`,
		`,"follow_up_at":" 1"`,
		`,"follow_up_at":"1.0"`,
		`,"follow_up_at":"9223372036854775808"`,
		`,"priority":"low","priority":"high"`,
	}
	for suffix in valid {
		preview := fmt.aprint(base, suffix, "}"); defer delete(preview)
		testing.expectf(t, validate_ticket_asset(.Ticket, .None, 0, .Plain, 0, transmute([]byte)preview, nil), "valid suffix %s", suffix)
	}
	for suffix in invalid {
		preview := fmt.aprint(base, suffix, "}"); defer delete(preview)
		testing.expectf(t, !validate_ticket_asset(.Ticket, .None, 0, .Plain, 0, transmute([]byte)preview, nil), "invalid suffix %s", suffix)
	}
}

@(test)
test_ticket_priority_follow_up_pages :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset); defer delete(conv.assets)
	previews := [?]string {
		`{"status":"closed","priority":"urgent","follow_up_at":"1000"}`,
		`{"status":"resolved","priority":"low","follow_up_at":"999"}`,
		`{"status":"open","follow_up_at":"1001"}`,
		`{"status":"waiting_customer","priority":"high","follow_up_at":""}`,
		`{"status":"open","priority":"normal"}`,
	}
	items: [5]pr.Asset
	for &item, i in items {
		item = {
			asset_id   = pr.AssetID(i + 1),
			asset_type = .Ticket,
			preview    = transmute([]byte)previews[i],
		}
		conv.assets[item.asset_id] = &item
	}
	directions := [?]bool{false, true}
	for descending in directions {
		expected := descending ? [5]int{1, 4, 5, 3, 2} : [5]int{2, 5, 3, 4, 1}
		q := Ticket_Query {
			sort       = "priority",
			descending = descending,
			limit      = 1,
		}
		for id, i in expected {
			page, rows := collect_ticket_page(&conv, q, "alice", a, now_ms = 1000)
			testing.expect_value(t, page.total_count, 5)
			testing.expect_value(t, len(rows), 1)
			testing.expect_value(t, rows[0].asset_id, pr.AssetID(id))
			testing.expect_value(t, page.has_more, i < 4)
			q.cursor = page.cursor
		}
	}
	page, rows := collect_ticket_page(&conv, {priority = "normal"}, "alice", a, now_ms = 1000)
	testing.expect_value(t, page.total_count, 2)
	page, rows = collect_ticket_page(&conv, {follow_up = "due", sort = "follow_up_at", limit = 1}, "alice", a, now_ms = 1000)
	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(2))
	testing.expect(t, page.has_more)
	page, rows = collect_ticket_page(&conv, {follow_up = "due", sort = "follow_up_at", cursor = page.cursor, limit = 1}, "alice", a, now_ms = 1000)
	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(1))
	testing.expect(t, !page.has_more)
	testing.expect(t, !page.activity[0].waiting, "staff follow-up does not create reply debt")
	for descending in directions {
		page, rows = collect_ticket_page(&conv, {sort = "follow_up_at", descending = descending}, "alice", a, now_ms = 1000)
		expected := descending ? [5]int{3, 1, 2, 5, 4} : [5]int{5, 4, 2, 1, 3}
		for row, i in rows do testing.expect_value(t, row.asset_id, pr.AssetID(expected[i]))
	}
}

@(test)
test_ticket_attention_follow_up :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset); defer delete(conv.assets)
	read := make(map[pr.AssetID]pr.AssetID); defer delete(read)
	previews := [?]string {
		`{"status":"closed","assignee":"alice","follow_up_at":"1000"}`,
		`{"status":"waiting_customer","assignee":"","follow_up_at":"999"}`,
		`{"status":"resolved","assignee":"alice","follow_up_at":"1001"}`,
		`{"status":"closed","assignee":"bob","follow_up_at":"999"}`,
		`{"status":"closed","assignee":"alice","follow_up_at":""}`,
	}
	items: [5]pr.Asset
	for &item, i in items {
		item = {
			asset_id   = pr.AssetID(i + 1),
			asset_type = .Ticket,
			preview    = transmute([]byte)previews[i],
		}
		conv.assets[item.asset_id] = &item
		read[item.asset_id] = item.asset_id
	}
	q := Ticket_Query {
		mode  = "attention",
		sort  = "id",
		limit = 1,
	}
	page, rows := collect_ticket_page(&conv, q, "alice", a, read, now_ms = 1000)
	testing.expect_value(t, page.total_count, 2)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(1))
	testing.expect(t, page.activity[0].follow_up_due && !page.activity[0].waiting && page.activity[0].unread == 0)
	q.cursor = page.cursor
	page, rows = collect_ticket_page(&conv, q, "alice", a, read, now_ms = 1000)
	testing.expect_value(t, rows[0].asset_id, pr.AssetID(2))
	testing.expect(t, !page.has_more)
	// Time alone brings the future ticket in, while read cursors stay unchanged.
	page, rows = collect_ticket_page(&conv, {mode = "attention"}, "alice", a, read, now_ms = 1001)
	testing.expect_value(t, page.total_count, 3)
	// Removing/rescheduling the two due dates removes those reasons.
	items[0].preview = transmute([]byte)string(`{"status":"closed","assignee":"alice","follow_up_at":""}`)
	items[1].preview = transmute([]byte)string(`{"status":"waiting_customer","assignee":"","follow_up_at":"2000"}`)
	page, rows = collect_ticket_page(&conv, {mode = "attention"}, "alice", a, read, now_ms = 1000)
	testing.expect_value(t, page.total_count, 0)
}

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
				Ticket_Preview{title = titles[title], status = statuses[status], assignee = owners[owner], company_id = companies[company]},
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

// Accepted extension fields must not make a ticket disappear or suppress reply
// activity. Generate values that conflict with the other asset type's schema.
prop_ticket_metadata_extensions :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	value, err := hgl.draw_i64(tc, 0, 5)
	if err == .Stop_Test do return hgl.abort()
	if err != nil do return hgl.interesting("extension draw")
	kind_index, kind_err := hgl.draw_i64(tc, 0, 2)
	if kind_err == .Stop_Test do return hgl.abort()
	if kind_err != nil do return hgl.interesting("kind draw")
	empty_key, key_err := hgl.draw_i64(tc, 0, 1)
	if key_err == .Stop_Test do return hgl.abort()
	if key_err != nil do return hgl.interesting("key draw")
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil do return hgl.interesting("arena")
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	values := [?]string{"42", "false", "[]", `{"nested":1}`, `"extension"`, "null"}
	kinds := [?]string{"customer_reply", "public_reply", "internal_note"}
	ticket := strings.concatenate(
		{
			`{"version":1,"title":"T","status":"open","assignee":"","company_id":"","contact_id":"","requester":"","requester_name":"","`,
			empty_key == 1 ? "" : "kind",
			`":`,
			values[value],
			`}`,
		},
		allocator = a,
	)
	entry := strings.concatenate(
		{`{"version":1,"kind":"`, kinds[kind_index], `","author":"bob","`, empty_key == 1 ? "" : "title", `":`, values[value], `}`},
		allocator = a,
	)
	preview := transmute([]byte)ticket
	reply := transmute([]byte)entry
	body := transmute([]byte)string("reply")
	if !validate_ticket_asset(.Ticket, .None, 0, .Plain, 0, preview, nil) || !validate_ticket_asset(.TicketEntry, .Asset, 1, .Plain, 5, reply, body) do return hgl.interesting("valid extension rejected")
	m, valid := parse_ticket_preview(preview, a)
	if !valid || m.title != "T" do return hgl.interesting("extension changed title")
	conv: Conversation_State
	conv.assets = make(map[pr.AssetID]^pr.Asset, a)
	items := [?]pr.Asset {
		{asset_id = 1, asset_type = .Ticket, owner = transmute([]byte)string("alice"), preview = preview},
		{asset_id = 2, asset_type = .TicketEntry, parent_type = .Asset, parent_id = 1, preview = reply, payload = body, created_at = 7},
	}
	for &item in items do conv.assets[item.asset_id] = &item
	page, rows := collect_ticket_page(&conv, {limit = 10}, "alice", a)
	if page.total_count != 1 || len(rows) != 1 || rows[0].asset_id != 1 do return hgl.interesting("accepted ticket disappeared")
	if len(page.activity) != 1 do return hgl.interesting("missing activity")
	activity := page.activity[0]
	if activity.unread != (kind_index == 0 ? 1 : 0) || activity.waiting != (kind_index != 1) || activity.latest != (kind_index == 0 ? "2" : "1") do return hgl.interesting("extension changed reply activity")
	if string(rows[0].preview) != ticket do return hgl.interesting("original bytes changed")
	return hgl.valid()
}

@(test)
test_hegel_ticket_metadata_extensions :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_ticket_metadata_extensions, nil, {test_cases = 64})
	testing.expectf(t, err == nil, "metadata extensions: err=%v interesting=%v", err, result.interesting_test_cases)
}
