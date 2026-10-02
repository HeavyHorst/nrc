package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strconv"
import "core:testing"
import pr "protocol"

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

calendar_test_conversation :: proc() -> ^Conversation_State {
	conv := new(Conversation_State)
	conv.tasks = make(map[pr.TaskID]^pr.Task)
	conv.assets = make(map[pr.AssetID]^pr.Asset)
	init_task_index(conv)
	init_note_index(conv)
	return conv
}

calendar_test_task :: proc(id: pr.TaskID, due: i64, status := pr.TaskStatus.Todo, assignee := "", project := "") -> ^pr.Task {
	task := alloc_task(transmute([]byte)string("task"), nil, transmute([]byte)assignee, nil, nil, nil, transmute([]byte)project, nil)
	task.id = id
	task.due_at = due
	task.status = status
	return task
}

calendar_test_reminder :: proc(id: pr.AssetID, at: i64, title: string) -> ^pr.Asset {
	storage: [256]byte
	number: [32]byte
	at_text := strconv.write_int(number[:], at, 10)
	offset := copy(storage[:], transmute([]byte)string("{\"deadline_at\":\""))
	offset += copy(storage[offset:], transmute([]byte)at_text)
	offset += copy(storage[offset:], transmute([]byte)string("\",\"title\":\""))
	offset += copy(storage[offset:], transmute([]byte)title)
	offset += copy(storage[offset:], transmute([]byte)string("\"}"))
	asset := alloc_asset(nil, nil, storage[:offset])
	asset.asset_id = id
	asset.asset_type = .Reminder
	return asset
}

calendar_test_appointment :: proc(id: pr.AssetID, start, end: i64, title := "meeting", assignee := "alice", project := "alpha") -> ^pr.Asset {
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
	asset := alloc_asset(nil, transmute([]byte)preview, nil, nil)
	asset.asset_id = id
	asset.asset_type = .Appointment
	asset.payload_encoding = .Plain
	return asset
}

calendar_test_collect :: proc(conv: ^Conversation_State, req: pr.CalendarRequest) -> (rows: [dynamic]pr.CalendarRow, more: bool, visited: int) {
	rows = make([dynamic]pr.CalendarRow, 0, int(req.limit))
	more, visited = collect_calendar_page(conv, req, &rows, context.temp_allocator)
	return
}

@(test)
test_calendar_half_open_order_cursor_and_range_seek :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	tasks := [?]^pr.Task {
		calendar_test_task(90, 99),
		calendar_test_task(9, 100),
		calendar_test_task(3, 110),
		calendar_test_task(8, 110),
		calendar_test_task(91, 120),
	}
	for task in tasks do task_store_put(conv, task)
	ws := Workspace_State{}
	asset_store_put(&ws, "", conv, calendar_test_reminder(7, 110, "same instant"))
	// A large population before and after the range must not be visited.
	for id in 100 ..< 300 do task_store_put(conv, calendar_test_task(pr.TaskID(id), 1))
	for id in 300 ..< 500 do task_store_put(conv, calendar_test_task(pr.TaskID(id), 1000))

	rows, more, visited := calendar_test_collect(conv, pr.CalendarRequest{start = 100, end = 120, limit = 100})
	defer delete(rows)
	testing.expect(t, !more)
	testing.expect_value(t, visited, 4)
	testing.expect_value(t, len(rows), 4)
	if len(rows) == 4 {
		testing.expect_value(t, rows[0].key, pr.CalendarKey{100, 0, 9})
		testing.expect_value(t, rows[1].key, pr.CalendarKey{110, 0, 3})
		testing.expect_value(t, rows[2].key, pr.CalendarKey{110, 0, 8})
		testing.expect_value(t, rows[3].key, pr.CalendarKey{110, 1, 7})
	}
	page, page_more, _ := calendar_test_collect(conv, pr.CalendarRequest{start = 100, end = 120, limit = 2})
	defer delete(page)
	testing.expect(t, page_more)
	next, next_more, _ := calendar_test_collect(conv, pr.CalendarRequest{start = 100, end = 120, limit = 100, has_cursor = true, cursor = page[1].key})
	defer delete(next)
	testing.expect(t, !next_more)
	testing.expect_value(t, len(next), 2)
	if len(next) == 2 {
		testing.expect_value(t, next[0].key, pr.CalendarKey{110, 0, 8})
		testing.expect_value(t, next[1].key, pr.CalendarKey{110, 1, 7})
	}
}

@(test)
test_calendar_filters_active_dated_tasks_and_reminder_exclusion :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	ws := Workspace_State{}
	task_store_put(conv, calendar_test_task(1, 10, .Backlog, "alice", "alpha"))
	task_store_put(conv, calendar_test_task(2, 11, .Todo, "alice", "beta"))
	task_store_put(conv, calendar_test_task(3, 12, .InProgress, "bob", "alpha"))
	task_store_put(conv, calendar_test_task(4, 13, .Done, "alice", "alpha"))
	task_store_put(conv, calendar_test_task(5, 14, .Note, "alice", "alpha"))
	task_store_put(conv, calendar_test_task(6, 0, .Todo, "alice", "alpha"))
	asset_store_put(&ws, "", conv, calendar_test_reminder(20, 15, "reminder"))
	rows, _, visited := calendar_test_collect(
		conv,
		pr.CalendarRequest{start = 1, end = 20, limit = 100, assignee = transmute([]byte)string("alice"), project = transmute([]byte)string("alpha")},
	)
	defer delete(rows)
	testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, visited, 4) // three active dated tasks plus reminder; filters intersect after range seek
	if len(rows) == 1 do testing.expect_value(t, rows[0].key.id, u64(1))
}

@(test)
test_calendar_mutations_and_lazy_rebuild :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	ws := Workspace_State{}
	task_store_put(conv, calendar_test_task(1, 10))
	asset_store_put(&ws, "", conv, calendar_test_reminder(2, 20, "old"))
	rows, _, _ := calendar_test_collect(conv, pr.CalendarRequest{start = 1, end = 100, limit = 100})
	delete(rows)
	testing.expect(t, conv.calendar_ready)
	// Replacement must remove old keys and add new keys while materialized.
	task_store_put(conv, calendar_test_task(1, 30))
	asset_store_put(&ws, "", conv, calendar_test_reminder(2, 40, "new"))
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = 1, end = 100, limit = 100})
	testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 {testing.expect_value(t, rows[0].key.at, i64(30)); testing.expect_value(t, rows[1].key.at, i64(40))}
	delete(rows)
	task_store_put(conv, calendar_test_task(1, 30, .Done))
	asset_store_remove(&ws, conv, 2)
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = 1, end = 100, limit = 100})
	testing.expect_value(t, len(rows), 0)
	delete(rows)

	calendar_index_destroy(conv)
	testing.expect(t, !conv.calendar_ready)
	task_store_put(conv, calendar_test_task(3, 50)) // no eager tree exists
	asset_store_put(&ws, "", conv, calendar_test_reminder(4, 60, "rebuilt"))
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = 1, end = 100, limit = 100})
	defer delete(rows)
	testing.expect(t, conv.calendar_ready)
	testing.expect_value(t, len(rows), 2)
}

@(test)
test_calendar_appointment_overlap_cursor_filters_and_mutation :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	ws := Workspace_State{}
	first := calendar_test_appointment(1, 10, 20)
	_, first_valid := parse_appointment_preview(first.preview, context.temp_allocator)
	testing.expect(t, first_valid, string(first.preview))
	asset_store_put(&ws, "", conv, first) // ends at boundary: excluded
	asset_store_put(&ws, "", conv, calendar_test_appointment(2, 15, 25)) // overlaps into range
	asset_store_put(&ws, "", conv, calendar_test_appointment(3, 20, 0)) // point at boundary: included
	asset_store_put(&ws, "", conv, calendar_test_appointment(4, 30, 40)) // starts at end: excluded
	rows, more, _ := calendar_test_collect(
		conv,
		pr.CalendarRequest{start = 20, end = 30, limit = 1, assignee = transmute([]byte)string("alice"), project = transmute([]byte)string("alpha")},
	)
	testing.expect(t, more); testing.expect_value(t, len(rows), 1)
	testing.expect_value(t, rows[0].key, pr.CalendarKey{20, 2, 2})
	testing.expect_value(t, rows[0].actual_start_at, i64(15)); testing.expect_value(t, rows[0].end_at, i64(25))
	cursor := rows[0].key; delete(rows)
	rows, more, _ = calendar_test_collect(conv, pr.CalendarRequest{start = 20, end = 30, limit = 10, has_cursor = true, cursor = cursor})
	testing.expect(t, !more); testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].key.id, u64(3))
	delete(rows)
	asset_store_put(&ws, "", conv, calendar_test_appointment(2, 50, 60))
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = 20, end = 30, limit = 10})
	testing.expect_value(t, len(rows), 1)
	delete(rows)
}

@(test)
test_appointment_record_validation :: proc(t: ^testing.T) {
	valid := transmute([]byte)string(`{"version":1,"title":"Review","start_at":"123","description":"d","url":"https://example.test"}`)
	testing.expect(t, validate_appointment_asset(.Appointment, .Plain, 0, valid, nil, context.temp_allocator))
	for text in ([?]string{`{"version":1,"title":"","start_at":"123"}`, `{"version":1,"title":"x","start_at":"0"}`, `{"version":1,"title":"x","start_at":"123","end_at":"123"}`, `{"version":2,"title":"x","start_at":"123"}`, `{"version":1,"title":"x","start_at":123}`}) {
		testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)text, nil, context.temp_allocator))
	}
	testing.expect(t, !validate_appointment_asset(.Appointment, .Zstd, 0, valid, nil, context.temp_allocator))
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 1, valid, transmute([]byte)string("x"), context.temp_allocator))
}

@(test)
test_calendar_appointment_bucket_boundaries_and_rebuild :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	ws := Workspace_State{}
	// Exercise every small power-of-two bucket boundary with points and ranges.
	for start: i64 = 1; start < 80; start += 1 {
		for duration: i64 = 0; duration < 12; duration += 1 {
			id := pr.AssetID(start * 12 + duration)
			asset_store_put(&ws, "", conv, calendar_test_appointment(id, start, duration == 0 ? 0 : start + duration))
		}
	}
	for query_start: i64 = 1; query_start < 90; query_start += 7 {
		query_end := query_start + 5
		expected := make(map[u64]bool)
		for start: i64 = 1; start < 80; start += 1 {
			for duration: i64 = 0; duration < 12; duration += 1 {
				if start < query_end && (duration == 0 ? start >= query_start : start + duration > query_start) {
					expected[u64(start * 12 + duration)] = true
				}
			}
		}
		req := pr.CalendarRequest {
			start = query_start,
			end   = query_end,
			limit = 7,
		}
		for page in 0 ..< 200 {
			rows, more, _ := calendar_test_collect(conv, req)
			for row in rows {
				testing.expect(t, row.key.id in expected, "no duplicate or non-overlapping appointment")
				delete_key(&expected, row.key.id)
				if req.has_cursor do testing.expect(t, row.key.at > req.cursor.at || row.key.at == req.cursor.at && row.key.id > req.cursor.id)
				req.cursor = row.key; req.has_cursor = true
			}
			delete(rows)
			if !more do break
			testing.expect(t, page < 199, "cursor must terminate")
		}
		testing.expect_value(t, len(expected), 0)
		delete(expected)
	}
	asset_store_put(&ws, "", conv, calendar_test_appointment(9999, 1, max(i64)))
	calendar_index_destroy(conv)
	rows, _, _ := calendar_test_collect(conv, pr.CalendarRequest{start = max(i64) - 2, end = max(i64), limit = 100})
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].key.id, u64(9999))
	delete(rows)
	asset_store_remove(&ws, conv, 9999)
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = max(i64) - 2, end = max(i64), limit = 100})
	testing.expect_value(t, len(rows), 0)
	delete(rows)
}

@(test)
test_calendar_appointment_seeks_past_unrelated_dates :: proc(t: ^testing.T) {
	arena: virtual.Arena
	testing.expect(t, virtual.arena_init_growing(&arena) == nil)
	defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	conv := calendar_test_conversation(); defer destroy_conversation(conv)
	ws := Workspace_State{}
	for i: i64 = 1; i <= 1000; i += 1 {
		asset_store_put(&ws, "", conv, calendar_test_appointment(pr.AssetID(i), i * 1000, i * 1000 + 10))
	}
	rows, more, visited := calendar_test_collect(conv, pr.CalendarRequest{start = 500005, end = 500006, limit = 100})
	defer delete(rows)
	testing.expect(t, !more)
	testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].key.id, u64(500))
	testing.expect(t, visited < 10, "must skip both historical and future appointments")
}
