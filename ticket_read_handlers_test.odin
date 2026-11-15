package main

import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_ticket_send :: proc(c: ^NRC_Connection, query: string, correlation: u32) {
	buffer: [65536]byte
	n := pr.serializeTicketQueryRequest(correlation, transmute([]byte)query, buffer[:]); assert(n > 0)
	process_protocol_payload(c, buffer[:n])
}

worker_db_test_ticket_error :: proc(t: ^testing.T, c: ^NRC_Connection, correlation: u32, text: string) {
	if !testing.expect_value(t, send_queue_len(c), 1) do return
	item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
	frame := frame_lease_data(item.lease); _, h, _ := ws.readFrameHeader(frame)
	expected: [256]byte
	n := pr.serializeErrorResponse({origin_opcode = .C_QueryTickets, correlation_id = correlation, error_msg = transmute([]byte)text}, expected[:])
	testing.expect_value(t, string(frame[h:]), string(expected[:n]))
}

// Expected facts for the fixed fixture below, independent of runtime indexes.
worker_db_test_ticket_fact :: proc(id: u64, q: Ticket_Query) -> (activity: Ticket_Activity, number: i64, text: string) {
	index := id == max(u64) ? 4 : int(id - 1)
	timestamps := [5]i64{90, 20, 30, 40, 50}
	latest := [5]string{"12", "2", "3", "4", "18446744073709551615"}
	times := [5]string{"90", "20", "30", "40", "50"}
	unread := [5]int{3, 0, 1, 1, 1}
	priorities := [5]i64{3, 1, 2, 0, 1}
	follow_ups := [5]i64{0, 1, max(i64), 0, 0}
	titles := [5]string{"äpfel", "beta", "beta", "delta", "omega"}
	statuses := [5]string{"open", "closed", "open", "waiting_customer", "open"}
	assignees := [5]string{"alice", "alice", "bob", "", ""}
	companies := [5]string{"zulu", "# 22", "# 999", "", ""}
	contacts := [5]string{"änne", "guest", "", "visitor@example.test", ""}
	if q.read_snapshot == 7 {unread[0] = 0; unread[3] = 0}
	activity = {
		unread        = unread[index],
		waiting       = index != 1 && index != 3,
		follow_up_due = index == 1,
		latest        = latest[index],
		timestamp     = times[index],
	}
	switch q.sort {
	case "id":
		number = i64(id)
	case "unread":
		number = i64(unread[index])
	case "priority":
		number = priorities[index]
	case "follow_up_at":
		number = follow_ups[index]
	case "title":
		text = titles[index]
	case "status":
		text = statuses[index]
	case "assignee":
		text = assignees[index]
	case "company_id":
		text = companies[index]
	case "contact_id":
		text = contacts[index]
	case:
		number = timestamps[index]
	}
	return
}

worker_db_test_ticket_pages :: proc(t: ^testing.T, c: ^NRC_Connection, fixtures: []pr.Asset, initial: Ticket_Query, ids: []u64) {
	q := initial
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	start := 0
	for {
		query, _ := json.marshal(q, allocator = a)
		worker_db_test_ticket_send(c, string(query), 1300); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do return
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, h, _ := ws.readFrameHeader(frame)
		end := min(start + q.limit, len(ids))
		page := Ticket_Page_Metadata {
			has_more            = end < len(ids),
			total_count         = q.omit_total_count ? 0 : len(ids),
			total_count_omitted = q.omit_total_count,
		}
		if end > start do page.activity = make([dynamic]Ticket_Activity, 0, end - start, a)
		assets := make([]pr.Asset, end - start, a)
		for id, i in ids[start:end] {
			found := false
			for fixture in fixtures {
				if fixture.asset_id == id {assets[i] = fixture; found = true; break}
			}
			if !testing.expect(t, found) do return
			activity: Ticket_Activity
			number: i64
			text: string
			if q.mode == "entries" {number = assets[i].created_at} else {activity, number, text = worker_db_test_ticket_fact(id, q)}
			append(&page.activity, activity)
			page.cursor = {fmt.aprint(id, allocator = a), fmt.aprint(number, allocator = a), text}
		}
		metadata, _ := json.marshal(page, allocator = a)
		msg := pr.TicketPage {
			correlation_id = 1300,
			metadata       = metadata,
			assets         = assets[:],
			full_content   = q.mode == "entries",
		}
		expected := make([]byte, pr.getSizeTicketPage(msg), a)
		pr.serializeTicketPage(msg, expected)
		if !testing.expect_value(t, string(frame[h:]), string(expected)) do return
		if !page.has_more do break
		q.cursor = page.cursor
		start = end
	}
}

worker_db_test_tickets :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	fixtures := [?]pr.Asset {
		{
			asset_id = 1,
			asset_type = .Ticket,
			created_at = 10,
			preview = task_query_test_bytes(`{"title":"Äpfel","status":"open","assignee":"alice","priority":"urgent","company_id":"20","contact_id":"21"}`),
			payload = task_query_test_bytes("alpha body"),
		},
		{
			asset_id = 2,
			asset_type = .Ticket,
			owner = task_query_test_bytes("alice"),
			created_at = 20,
			preview = task_query_test_bytes(
				`{"title":"beta","status":"closed","assignee":"alice","follow_up_at":"1","company_id":"22","requester_name":"Guest"}`,
			),
		},
		{
			asset_id = 3,
			asset_type = .Ticket,
			created_at = 30,
			preview = task_query_test_bytes(
				`{"title":"beta","status":"open","assignee":"bob","priority":"high","follow_up_at":"9223372036854775807","company_id":"999"}`,
			),
		},
		{
			asset_id = 4,
			asset_type = .Ticket,
			created_at = 40,
			preview = task_query_test_bytes(`{"title":"delta","status":"waiting_customer","priority":"low","requester":"visitor@example.test"}`),
		},
		{asset_id = max(u64), asset_type = .Ticket, created_at = 50, preview = task_query_test_bytes(`{"title":"omega","status":"open"}`)},
		{asset_id = 6, asset_type = .Ticket, preview = task_query_test_bytes("invalid")},
		{
			asset_id = 10,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 80,
			preview = task_query_test_bytes(`{"kind":"customer_reply"}`),
			payload = task_query_test_bytes("reply needle"),
		},
		{
			asset_id = 11,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 60,
			preview = task_query_test_bytes(`{"kind":"public_reply"}`),
		},
		{
			asset_id = 12,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 70,
			preview = task_query_test_bytes(`{"kind":"customer_reply"}`),
		},
		{
			asset_id = 13,
			asset_type = .TicketEntry,
			parent_type = .Asset,
			parent_id = 1,
			created_at = 90,
			preview = task_query_test_bytes("invalid"),
			payload = task_query_test_bytes("malformed needle"),
		},
		{
			asset_id = 14,
			asset_type = .TicketEntry,
			parent_type = .Task,
			parent_id = 1,
			created_at = 999,
			preview = task_query_test_bytes(`{"kind":"customer_reply"}`),
		},
		{asset_id = 20, asset_type = .Note, preview = task_query_test_bytes(`{"title":"ZULU"}`)},
		{asset_id = 21, asset_type = .Note, preview = task_query_test_bytes(`{"title":"Änne"}`)},
		{
			asset_id = 22,
			asset_type = .Reminder,
			owner = task_query_test_bytes("bob"),
			preview = task_query_test_bytes(`{"visibility":"personal","title":"secret"}`),
		},
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	for &fixture in fixtures {
		fixture.payload_raw_len = u32(len(fixture.payload))
		testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &fixture), sql.OK)
	}
	testing.expect_value(t, sqlite_put_asset(&store, "foreign-tickets", &fixtures[0]), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	M :: max(u64)
	for f in ([?]struct {
			sort:                  string,
			ascending, descending: [5]u64,
		}{{"id", {M, 1, 2, 3, 4}, {4, 3, 2, 1, M}}, {"activity", {2, 3, 4, M, 1}, {1, M, 4, 3, 2}}, {"unread", {2, M, 4, 3, 1}, {1, M, 4, 3, 2}}, {"priority", {4, M, 2, 3, 1}, {1, 3, M, 2, 4}}, {"follow_up_at", {M, 4, 1, 2, 3}, {3, 2, M, 4, 1}}, {"title", {3, 2, 4, M, 1}, {1, M, 4, 3, 2}}, {"status", {2, M, 3, 1, 4}, {4, M, 3, 1, 2}}, {"assignee", {M, 4, 2, 1, 3}, {3, 2, 1, M, 4}}, {"company_id", {M, 4, 2, 3, 1}, {1, 3, 2, M, 4}}, {"contact_id", {M, 3, 2, 4, 1}, {1, 4, 2, M, 3}}}) {
		ascending, descending := f.ascending, f.descending
		worker_db_test_ticket_pages(t, c, fixtures[:], {sort = f.sort, limit = 2}, ascending[:])
		worker_db_test_ticket_pages(t, c, fixtures[:], {sort = f.sort, descending = true, limit = 2}, descending[:])
	}
	for f in ([?]struct {
			query: Ticket_Query,
			ids:   []u64,
		}{{{mode = "entries", parent = "1", limit = 2}, {11, 12, 10, 13}}, {{mode = "entries", parent = "999", limit = 2}, {}}, {{mode = "attention", sort = "id", descending = true, limit = 1}, {4, 2, 1, M}}, {{mode = "attention", sort = "id", descending = true, limit = 1, omit_total_count = true}, {4, 2, 1, M}}, {{search = "NEEDLE", limit = 2}, {1}}, {{search = "malformed needle", limit = 2}, {1}}, {{search = "äPFEL", limit = 2}, {1}}, {{search = "absent", limit = 2}, {}}, {{priority = "normal", limit = 1}, {2, M}}, {{follow_up = "due", limit = 1}, {2}}, {{status = "open", assignee = "alice", company = "20", limit = 1}, {1}}, {{search_results = true, ids = {"1", "4", "999"}, limit = 1}, {4, 1}}}) {worker_db_test_ticket_pages(t, c, fixtures[:], f.query, f.ids)}
	worker_db_test_ticket_send(
		c,
		`{"mode":"read","read_snapshot":7,"read_start":true,"read_end":true,"read":{"1":"12","4":"4","6":"99","999":"99","20":"99"}}`,
		1301,
	)
	worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 1) {item := send_queue_pop(c); frame_lease_dispose(&item.lease)}
	testing.expect_value(t, c.ticket_read_snapshot, u32(7)); testing.expect_value(t, len(c.ticket_read_cursors), 3)
	testing.expect_value(t, c.ticket_read_cursors[1], pr.AssetID(12))
	worker_db_test_ticket_pages(
		t,
		c,
		fixtures[:],
		{mode = "attention", sort = "id", descending = true, limit = 1, omit_total_count = true, read_snapshot = 7},
		{2, 1, M},
	)
	worker_db_test_ticket_pages(t, c, fixtures[:], {sort = "unread", limit = 2, read_snapshot = 7}, {4, 2, 1, M, 3})
	// Queue ownership: overwrite the connection map after submission, not the snapshot.
	worker_db_test_ticket_send(c, `{"mode":"read","read_snapshot":8,"read_start":true,"read_end":true,"read":{"1":"10"}}`, 1302)
	worker_db_test_ticket_send(c, `{"mode":"read","read_snapshot":8,"read_start":true,"read_end":true,"read":{"2":"2"}}`, 1303)
	worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 2) {
		item := send_queue_pop(c); data := frame_lease_data(item.lease); _, h, _ := ws.readFrameHeader(data)
		encoded: [256]byte; n := pr.serializeErrorResponse({origin_opcode = .C_QueryTickets, correlation_id = 1302, error_msg = task_query_test_bytes("Ticket read upload superseded")}, encoded[:])
		testing.expect_value(t, string(data[h:]), string(encoded[:n])); frame_lease_dispose(&item.lease)
		item = send_queue_pop(c); frame_lease_dispose(&item.lease)
	}
	testing.expect_value(t, c.ticket_read_snapshot, u32(8)); testing.expect_value(t, len(c.ticket_read_cursors), 1)
	testing.expect_value(t, c.ticket_read_cursors[2], pr.AssetID(2))
	errors := [3]string{"Ticket read snapshot unavailable", "Invalid ticket read upload", "Invalid ticket query"}
	for query, i in ([3]string{`{"read_snapshot":7}`, `{"mode":"read","read_snapshot":8,"read":{"1":"5"}}`, `{"priority":null}`}) {
		worker_db_test_ticket_send(c, query, u32(1310 + i)); worker_db_test_pump(t)
		worker_db_test_ticket_error(t, c, u32(1310 + i), errors[i])
	}
	// A failed upload chunk must prevent a queued end from certifying it.
	testing.expect_value(t, sql.exec(store.db, "ALTER TABLE assets RENAME TO unavailable_assets", nil, nil, nil), sql.OK)
	worker_db_test_ticket_send(c, `{"mode":"read","read_snapshot":9,"read_start":true,"read":{"1":"12"}}`, 1320)
	worker_db_test_ticket_send(c, `{"mode":"read","read_snapshot":9,"read_end":true}`, 1321)
	worker_db_test_pump(t)
	if testing.expect_value(t, send_queue_len(c), 2) {
		item := send_queue_pop(c); data := frame_lease_data(item.lease); _, h, _ := ws.readFrameHeader(data)
		encoded: [256]byte
		n := pr.serializeErrorResponse(
			{origin_opcode = .C_QueryTickets, correlation_id = 1320, error_msg = task_query_test_bytes("Failed to query tickets")},
			encoded[:],
		)
		testing.expect_value(t, string(data[h:]), string(encoded[:n])); frame_lease_dispose(&item.lease)
		worker_db_test_ticket_error(t, c, 1321, "Ticket read upload superseded")
	}
	testing.expect_value(t, c.ticket_read_snapshot, u32(0))
	testing.expect_value(t, c.ticket_read_upload, u32(0))
	testing.expect_value(t, sql.exec(store.db, "ALTER TABLE unavailable_assets RENAME TO assets", nil, nil, nil), sql.OK)

	// A single entry larger than the admitted result cannot produce a looping
	// empty page; the next successful query also proves temporary-table cleanup.
	large: [5000]byte
	oversized := pr.Asset {
		asset_id        = 30,
		asset_type      = .TicketEntry,
		parent_type     = .Asset,
		parent_id       = 30,
		payload         = large[:],
		payload_raw_len = len(large),
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &oversized), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	worker_db_test_ticket_send(c, `{"mode":"entries","parent":"30"}`, 1322); worker_db_test_pump(t)
	worker_db_test_ticket_error(t, c, 1322, "Ticket exceeds page byte limit")
	worker_db_test_ticket_pages(t, c, fixtures[:], {sort = "title", limit = 2}, {3, 2, 4, M, 1})
	testing.expect(t, td.database.port.in_flight == 0 && td.database.port.charged_bytes == 0)
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
