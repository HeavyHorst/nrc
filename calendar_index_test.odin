package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:testing"
import pr "protocol"
import sql "sqlite"
import ws "websocket"
import db "workspace_db"

worker_db_test_calendar_page :: proc(t: ^testing.T, c: ^NRC_Connection, initial: pr.CalendarRequest, expected: []pr.CalendarRow) {
	req := initial
	position := 0
	for {
		buffer: [1024]byte; n := pr.serializeCalendarRequest(req, buffer[:]); assert(n > 0)
		process_protocol_payload(c, buffer[:n]); worker_db_test_pump(t)
		if !testing.expect_value(t, send_queue_len(c), 1) do return
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, header, _ := ws.readFrameHeader(frame)
		end := min(position + int(req.limit), len(expected))
		encoded: [8192]byte
		written := pr.serializeCalendarPage(expected[position:end], end < len(expected), req.correlation_id, encoded[:])
		if !testing.expect_value(t, string(frame[header:]), string(encoded[:written])) do return
		if end == len(expected) do break
		req.has_cursor = true; req.cursor = expected[end - 1].key; position = end
	}
}

worker_db_test_calendar :: proc(t: ^testing.T, c: ^NRC_Connection, path: cstring) {
	store, rc := db.open(path); if !testing.expect_value(t, rc, sql.OK) do return
	defer db.close(&store)
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	base := appointment_test_at(2026, 10, 19, 10)
	tasks := [?]pr.Task {
		calendar_test_task(max(u64), base + 20),
		calendar_test_task(2, base + 19),
		calendar_test_task(3, base + 40),
		calendar_test_task(4, base + 25, .Done),
		calendar_test_task(5, base + 25, .Note),
	}
	assets := [?]pr.Asset {
		calendar_test_appointment(10, base + 15, base + 25),
		calendar_test_reminder(11, base + 20, "team", virtual.arena_allocator(&arena)),
		calendar_test_appointment(12, base + 20, 0),
		calendar_test_appointment(16, base + 10, base + 20), // Ends at excluded boundary.
		calendar_test_reminder(13, base + 21, "mine", virtual.arena_allocator(&arena)),
		calendar_test_reminder(14, base + 22, "other", virtual.arena_allocator(&arena)),
	}
	for owner, id in ([2]string{"alice", "bob"}) {
		assets[4 + id].owner = transmute([]byte)owner
		assets[4 + id].preview = transmute([]byte)string(`{"visibility":"personal"}`)
	}
	series_start := base + 1000
	exceptions := fmt.tprintf(
		`[{{"at":"%d","cancelled":true}},{{"at":"%d","cancelled":false,"start_at":"%d","end_at":"","participants":["carol"]}}]`,
		series_start,
		series_start + APPOINTMENT_DAY,
		series_start + APPOINTMENT_DAY + 50,
	)
	preview := appointment_test_preview(series_start, "UTC", "daily", "[]", "", exceptions)
	_, valid_series := parse_appointment_preview(transmute([]byte)preview, context.temp_allocator)
	testing.expect(t, valid_series, preview)
	series := pr.Asset {
		asset_id   = 15,
		asset_type = .Appointment,
		owner      = transmute([]byte)string("organizer"),
		preview    = transmute([]byte)preview,
	}
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM edges; DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	for &task in tasks do testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
	for &asset in assets do testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &asset), sql.OK)
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &series), sql.OK)
	foreign_task := pr.Task {
		id     = 1,
		due_at = base + 20,
	}
	testing.expect_value(t, db.put_task(&store, "foreign-calendar", &foreign_task), sql.OK)
	testing.expect_value(t, db.commit(&store), sql.OK)
	req := pr.CalendarRequest {
		start          = base + 20,
		end            = base + 40,
		limit          = 2,
		correlation_id = 1201,
	}
	want := [5]pr.CalendarRow {
		{key = {base + 20, 0, max(u64)}, title = task_query_test_bytes("task")},
		{key = {base + 20, 1, 11}, title = task_query_test_bytes("team")},
		{
			key = {base + 20, 2, 10},
			title = task_query_test_bytes("meeting"),
			assignee = task_query_test_bytes("alice"),
			project = task_query_test_bytes("alpha"),
			actual_start_at = base + 15,
			end_at = base + 25,
		},
		{
			key = {base + 20, 2, 12},
			title = task_query_test_bytes("meeting"),
			assignee = task_query_test_bytes("alice"),
			project = task_query_test_bytes("alpha"),
			actual_start_at = base + 20,
		},
		{key = {base + 21, 1, 13}, title = task_query_test_bytes("mine")},
	}
	worker_db_test_calendar_page(t, c, req, want[:])
	req.assignee = task_query_test_bytes("alice"); req.project = task_query_test_bytes("alpha")
	worker_db_test_calendar_page(t, c, req, want[2:4])
	req.assignee = task_query_test_bytes("absent")
	worker_db_test_calendar_page(t, c, req, nil)
	req = pr.CalendarRequest {
		start          = series_start,
		end            = series_start + 2 * APPOINTMENT_DAY + 1,
		limit          = 1,
		correlation_id = 1202,
	}
	occurrences := [2]pr.CalendarRow {
		{
			key = {series_start + APPOINTMENT_DAY + 50, 3, 15},
			title = task_query_test_bytes("Series"),
			assignee = task_query_test_bytes("alice"),
			actual_start_at = series_start + APPOINTMENT_DAY + 50,
			occurrence_at = series_start + APPOINTMENT_DAY,
		},
		{
			key = {series_start + 2 * APPOINTMENT_DAY, 3, 15},
			title = task_query_test_bytes("Series"),
			assignee = task_query_test_bytes("alice"),
			actual_start_at = series_start + 2 * APPOINTMENT_DAY,
			end_at = series_start + 2 * APPOINTMENT_DAY + 3600000000000,
			occurrence_at = series_start + 2 * APPOINTMENT_DAY,
		},
	}
	worker_db_test_calendar_page(t, c, req, occurrences[:])
	req.assignee = task_query_test_bytes("carol")
	worker_db_test_calendar_page(t, c, req, occurrences[:1])
	req.assignee = task_query_test_bytes("bob")
	worker_db_test_calendar_page(t, c, req, occurrences[1:])
	// Late-discovered appointments must displace point rows in a full top-101.
	testing.expect_value(t, db.begin(&store), sql.OK)
	testing.expect_value(t, sql.exec(store.db, "DELETE FROM assets; DELETE FROM tasks", nil, nil, nil), sql.OK)
	large: [151]pr.CalendarRow
	large[0] = want[2]
	testing.expect_value(t, sqlite_put_asset(&store, c.workspace_id, &assets[0]), sql.OK)
	for i in 0 ..< 150 {
		task := pr.Task {
			id     = u64(i + 1),
			due_at = base + 30,
			title  = task_query_test_bytes("task"),
		}
		testing.expect_value(t, db.put_task(&store, c.workspace_id, &task), sql.OK)
		large[i + 1] = {
			key   = {base + 30, 0, task.id},
			title = task.title,
		}
	}
	testing.expect_value(t, db.commit(&store), sql.OK)
	req = pr.CalendarRequest {
		start          = base + 20,
		end            = base + 40,
		limit          = 100,
		correlation_id = 1203,
	}
	worker_db_test_calendar_page(t, c, req, large[:])
	// Byte budget: exactly one row fits, then none fits, then reuse succeeds.
	buffer: [1024]byte; n := pr.serializeCalendarRequest(req, buffer[:])
	request := db.Request {
		opcode    = .C_QueryCalendar,
		workspace = c.workspace_id,
		actor     = "alice",
		body      = buffer[2:n],
	}
	for budget in ([3]int{34 + pr.calendar_row_size(large[0]), 34, 8192}) {
		output := db.Command_Output {
			limit = budget + size_of(db.Command_Frame),
		}; defer db.destroy_command_output(&output)
		testing.expect_value(t, db.begin(&store), sql.OK)
		testing.expect_value(t, sqlite_execute_task_command(&store, &request, &output), budget == 34 ? sql.TOOBIG : sql.OK)
		testing.expect_value(t, db.rollback(&store), sql.OK)
		if budget == 34 {testing.expect_value(t, output.count, 0)} else if testing.expect_value(t, output.count, 1) {
			encoded: [8192]byte; count := budget == 8192 ? 100 : 1
			size := pr.serializeCalendarPage(large[:count], true, req.correlation_id, encoded[:])
			testing.expect_value(t, string(output.frames[0].payload), string(encoded[:size]))
		}
	}
	for text, mode in ([3]string{"Access denied", "Server too busy", "Failed to query calendar"}) {
		c.authenticated = mode != 0; td.database.stopping = mode == 1
		if mode == 2 do testing.expect_value(t, sql.exec(store.db, "ALTER TABLE appointment_metadata RENAME TO unavailable_appointments", nil, nil, nil), sql.OK)
		process_protocol_payload(c, buffer[:n])
		c.authenticated = true; td.database.stopping = false
		worker_db_test_pump(t)
		if mode == 2 do testing.expect_value(t, sql.exec(store.db, "ALTER TABLE unavailable_appointments RENAME TO appointment_metadata", nil, nil, nil), sql.OK)
		if !testing.expect_value(t, send_queue_len(c), 1) do continue
		item := send_queue_pop(c); defer frame_lease_dispose(&item.lease)
		frame := frame_lease_data(item.lease); _, header, _ := ws.readFrameHeader(frame)
		encoded: [256]byte
		size := pr.serializeErrorResponse(
			{origin_opcode = .C_QueryCalendar, error_msg = transmute([]byte)text, correlation_id = req.correlation_id},
			encoded[:],
		)
		testing.expect_value(t, string(frame[header:]), string(encoded[:size]))
	}
}

foreign import calendar_test_zstd "system:zstd"
foreign calendar_test_zstd {
	ZSTD_compress :: proc(dst: rawptr, capacity: uintptr, src: rawptr, size: uintptr, level: i32) -> uintptr ---
}

@(test)
test_calendar_reminder_json_and_compression :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	// Use independently specified JSON, including a nanosecond that a float loses.
	json := `{"title":"Exact reminder","deadlineAt":"1790458200000000001"}`
	asset := pr.Asset {
		asset_type = .Reminder,
		payload    = transmute([]byte)json,
	}
	at, title := calendar_reminder(&asset, a)
	testing.expect_value(t, at, i64(1790458200000000001))
	testing.expect_value(t, string(title), "Exact reminder")
	compressed: [256]byte
	size := ZSTD_compress(raw_data(compressed[:]), 256, raw_data(asset.payload), uintptr(len(asset.payload)), 3)
	testing.expect_value(t, ZSTD_isError(size), u32(0))
	asset.payload = compressed[:int(size)]
	asset.payload_encoding = .Zstd
	asset.payload_raw_len = u32(len(json))
	at, title = calendar_reminder(&asset, a)
	testing.expect_value(t, at, i64(1790458200000000001))
	testing.expect_value(t, string(title), "Exact reminder")
	asset.payload_raw_len += 1
	at, _ = calendar_reminder(&asset, a)
	testing.expect(t, at == 0, "wrong decompressed size is rejected")
	asset.payload_encoding = .Plain
	asset.payload = transmute([]byte)string(`{"title":"Nested only","nested":{"deadline_at":"123"}}`)
	at, _ = calendar_reminder(&asset, a)
	testing.expect(t, at == 0, "nested keys are not deadlines")
}

@(test)
test_calendar_untrusted_json_boundaries :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	context.temp_allocator = a
	for levels in ([?]int{63, 64, 30000}) {
		data := make([]byte, 80 + 2 * levels, a)
		n := copy(data, transmute([]byte)string(`{"title":"deep","deadline_at":"123","extra":`))
		for _ in 0 ..< levels {data[n] = '['; n += 1}
		data[n] = '0'; n += 1
		for _ in 0 ..< levels {data[n] = ']'; n += 1}
		data[n] = '}'; n += 1
		payload := data[:n]
		compressed := make([]byte, len(payload) + 1024, a)
		size := ZSTD_compress(raw_data(compressed), uintptr(len(compressed)), raw_data(payload), uintptr(len(payload)), 3)
		testing.expect_value(t, ZSTD_isError(size), u32(0))
		for mode in 0 ..< 3 {
			asset := pr.Asset {
				asset_type = .Reminder,
				payload    = payload,
			}
			if mode == 1 {asset.payload = compressed[:int(size)]; asset.payload_encoding = .Zstd; asset.payload_raw_len = u32(len(payload))}
			if mode == 2 {asset.payload = nil; asset.preview = payload}
			at, _ := calendar_reminder(&asset, a)
			testing.expect_value(t, at, levels == 63 ? i64(123) : i64(0))
		}
	}
	// Quotes, escaped quotes and backslashes must not count as nesting.
	escaped := `{"title":"brackets [{ \\\" \\ } ]","deadline_at":"123"}`
	asset := pr.Asset {
		asset_type = .Reminder,
		payload    = transmute([]byte)escaped,
	}
	at, _ := calendar_reminder(&asset, a)
	testing.expect_value(t, at, i64(123))
	for token in ([?]string{`"123junk"`, `"9223372036854775808"`, `"18446744073709551739"`, `"-9223372036854775809"`, `9223372036854775808`, `18446744073709551739`, `-18446744073709551493`, `1e100`, `9.223372036854776e18`, `""`, `"+"`}) {
		asset.payload = transmute([]byte)fmt.tprintf("%s%s%s", `{"title":"bad","deadline_at":`, token, "}")
		at, _ = calendar_reminder(&asset, a)
		testing.expect(t, at == 0, token)
	}
	for token in ([?]string{`"9223372036854775807"`, `9223372036854775807`}) {
		asset.payload = transmute([]byte)fmt.tprintf("%s%s%s", `{"title":"max","deadline_at":`, token, "}")
		at, _ = calendar_reminder(&asset, a)
		testing.expect_value(t, at, max(i64))
	}
}

@(test)
test_calendar_token_reader_grammar_and_fields :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	a := virtual.arena_allocator(&arena)
	for data in ([?]string{`{"title":"t","deadline_at":123}`, ` { "extra": [null,true,false,{},[],{"title":"wrong","deadline_at":999}], "title":"t","deadline_at":123 } `, `{"deadlineAt":999,"deadline_at":123,"name":"wrong","title":"t"}`, `{"title":"","name":"t","deadline_at":null,"deadlineAt":"123"}`, `{"ti\u0074le":"\u0074","deadline_\u0061t":"\u003123"}`, `{"title":"t","deadline_at":1.239e2}`, `{"title":"t","deadline_at":123,"extra":{"x":1,"x":2}}`}) {
		asset := pr.Asset {
			asset_type = .Reminder,
			payload    = transmute([]byte)data,
		}
		at, title := calendar_reminder(&asset, a)
		testing.expect_value(t, at, i64(123))
		testing.expect_value(t, string(title), "t")
	}
	for data in ([?]string{`{"title":"t" "deadline_at":123}`, `{"title" "t","deadline_at":123}`, `{"title":"t","deadline_at":123,}`, `{"title":"t","deadline_at":123} garbage`, `{"title":"t","deadline_at":123} {}`, `{"x":[1,],"deadline_at":123}`, `{"x":[,1],"deadline_at":123}`, `{"x":[1 2],"deadline_at":123}`, `{"x":{,"y":1}}`, `{"x":{1:2}}`, `{"x":[1}}`, `{"x":{"y":1]}`, `{"x":01}`, `{"x":1.}`, `{"x":1e}`, `{"x":+1}`, `{"x":NaN}`, `{"x":"\uGGGG"}`, `{"x":"\q"}`, `{'x':1}`, `{"x":/*comment*/1}`, `{"title":"one","ti\u0074le":"two","deadline_at":123}`, `{"deadline_at":{},"deadline_at":123}`, "{}\x00", "{}\v"}) {
		_, _, valid := json_metadata_fields(transmute([]byte)data, [?]string{"deadline_at", "deadlineAt", "title", "name"}, a)
		testing.expect(t, !valid, data)
	}
	_, _, apostrophe_valid := json_metadata_fields(transmute([]byte)string(`{"x":"\'"}`), [?]string{"title"}, a)
	testing.expect(t, !apostrophe_valid)
	complete := `{"extra":[{"x":"\\\"\uD83D\uDE00"}],"title":"t","deadline_at":123}`
	for n in 0 ..< len(complete) {
		_, _, valid := json_metadata_fields(transmute([]byte)complete[:n], [?]string{"title"}, a)
		testing.expect(t, !valid, "every truncation must be rejected")
	}
	asset := pr.Asset {
		asset_type = .Reminder,
		payload    = transmute([]byte)string(`{"title":"Call \"A\" \\ \uD83D\uDE00","deadline_at":123}`),
	}
	at, title := calendar_reminder(&asset, a)
	testing.expect_value(t, at, i64(123))
	testing.expect_value(t, string(title), "Call \"A\" \\ 😀")
	asset.preview = transmute([]byte)string(`{"title":"fallback","deadline_at":456}`)
	asset.payload = transmute([]byte)string(`{"title":"broken",`)
	at, title = calendar_reminder(&asset, a)
	testing.expect_value(t, at, i64(456))
	testing.expect_value(t, string(title), "fallback")
	for data in ([?]string{`null`, `[]`, `{"title":"no deadline"}`, `{"title":"t","deadline_at":false,"deadlineAt":123}`}) {
		asset.payload = transmute([]byte)data
		at, _ = calendar_reminder(&asset, a)
		testing.expect(t, at == 0, "valid payload wins over preview even without a valid deadline")
	}
}

@(test)
test_calendar_token_reader_plain_payload_allocates_nothing :: proc(t: ^testing.T) {
	tracker: mem.Tracking_Allocator
	mem.tracking_allocator_init(&tracker, context.allocator)
	defer mem.tracking_allocator_destroy(&tracker)
	asset := pr.Asset {
		asset_type = .Reminder,
		payload    = transmute([]byte)string(`{"extra":[{"deep":[1,2,3],"text":"ignored \u0061"}],"title":"plain","deadline_at":"1790458200000000001"}`),
	}
	at, title := calendar_reminder(&asset, mem.tracking_allocator(&tracker))
	testing.expect_value(t, at, i64(1790458200000000001))
	testing.expect_value(t, string(title), "plain")
	testing.expect_value(t, tracker.total_allocation_count, i64(0))
}

calendar_test_task :: proc(id: pr.TaskID, due: i64, status := pr.TaskStatus.Todo) -> pr.Task {
	return {id = id, due_at = due, status = status, title = transmute([]byte)string("task")}
}

calendar_test_reminder :: proc(id: pr.AssetID, at: i64, title: string, allocator: mem.Allocator) -> pr.Asset {
	storage: [256]byte
	number: [32]byte
	at_text := strconv.write_int(number[:], at, 10)
	offset := copy(storage[:], transmute([]byte)string("{\"deadline_at\":\""))
	offset += copy(storage[offset:], transmute([]byte)at_text)
	offset += copy(storage[offset:], transmute([]byte)string("\",\"title\":\""))
	offset += copy(storage[offset:], transmute([]byte)title)
	offset += copy(storage[offset:], transmute([]byte)string("\"}"))
	payload := make([]byte, offset, allocator)
	copy(payload, storage[:offset])
	return {asset_id = id, asset_type = .Reminder, payload = payload}
}

// The caller binds temp_allocator to its fixture arena, which owns this preview.
calendar_test_appointment :: proc(id: pr.AssetID, start, end: i64, title := "meeting", assignee := "alice", project := "alpha") -> pr.Asset {
	preview := fmt.tprintf(`{{"version":1,"title":"%s","start_at":"%d","end_at":"","assignee":"%s","project":"%s"}}`, title, start, assignee, project)
	if end != 0 {
		preview = fmt.tprintf(
			`{{"version":1,"title":"%s","start_at":"%d","end_at":"%d","assignee":"%s","project":"%s"}}`,
			title,
			start,
			end,
			assignee,
			project,
		)
	}
	return {asset_id = id, asset_type = .Appointment, preview = transmute([]byte)preview, payload_encoding = .Plain}
}

@(test)
test_appointment_record_validation :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`{"version":1,"title":"Review","start_at":"123","description":"d","url":"https://example.test"}`)
	testing.expect(t, validate_appointment_asset(.Appointment, .Plain, 0, valid, nil))
	for text in ([?]string{`{"version":1,"title":"","start_at":"123"}`, `{"version":1,"title":"x","start_at":"0"}`, `{"version":1,"title":"x","start_at":"123","end_at":"123"}`, `{"version":2,"title":"x","start_at":"123"}`, `{"version":1,"title":"x","start_at":123}`}) {
		testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)text, nil))
	}
	testing.expect(t, !validate_appointment_asset(.Appointment, .Zstd, 0, valid, nil))
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 1, valid, transmute([]byte)string("x")))
}
