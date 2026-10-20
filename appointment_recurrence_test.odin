package main

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"
import pr "protocol"

appointment_test_at :: proc(year, month, day, hour: int, minute := 0) -> i64 {
	tm, _ := time.datetime_to_time(year, month, day, hour, minute, 0)
	return time.to_unix_nanoseconds(tm)
}

appointment_test_preview :: proc(start: i64, zone, repeat: string, weekdays := "[]", until := "", exceptions := "[]") -> string {
	return fmt.tprintf(
		`{{"version":2,"title":"Series","start_at":"%d","end_at":"%d","timezone":"%s","repeat":"%s","weekdays":%s,"until":"%s","participants":["bob"],"conference":"nrc","exceptions":%s,"assignee":"alice"}}`,
		start,
		start + 3600000000000,
		zone,
		repeat,
		weekdays,
		until,
		exceptions,
	)
}

@(test)
test_recurring_calendar_wall_time_and_month_skip :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	for year in ([?]int{2026, 2050}) {
		// US DST starts March 8 in 2026, March 13 in 2050.
		day := year == 2026 ? 7 : 12
		start := appointment_test_at(year, 3, day, 7, 30) // 02:30 EST
		preview := appointment_test_preview(start, "America/New_York", "daily")
		conv := calendar_test_conversation(); ws := Workspace_State{}
		asset := alloc_asset(transmute([]byte)string("organizer"), transmute([]byte)preview, nil, nil); asset.asset_id = 1; asset.asset_type = .Appointment
		asset_store_put(&ws, "", conv, asset)
		rows, _, _ := calendar_test_collect(conv, pr.CalendarRequest{start = start, end = start + 3 * APPOINTMENT_DAY, limit = 100})
		testing.expect_value(t, len(rows), 3)
		if len(rows) >=
		   2 {testing.expect_value(t, rows[0].occurrence_at, start); testing.expect_value(t, rows[1].actual_start_at, start + 2 * APPOINTMENT_DAY - 3600000000000)}
		for row in rows {testing.expect_value(t, row.key.kind, u8(3)); testing.expect_value(t, row.end_at - row.actual_start_at, i64(3600000000000))}
		delete(rows); destroy_conversation(conv)
	}
	conv := calendar_test_conversation(); defer destroy_conversation(conv); ws := Workspace_State{}
	start := appointment_test_at(2026, 1, 31, 10)
	preview := appointment_test_preview(start, "UTC", "monthly")
	asset := alloc_asset(nil, transmute([]byte)preview, nil, nil); asset.asset_id = 1; asset.asset_type = .Appointment; asset_store_put(&ws, "", conv, asset)
	rows, _, _ := calendar_test_collect(
		conv,
		pr.CalendarRequest{start = appointment_test_at(2026, 2, 1, 0), end = appointment_test_at(2026, 4, 1, 0), limit = 100},
	)
	defer delete(rows); testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 do testing.expect_value(t, rows[0].occurrence_at, appointment_test_at(2026, 3, 31, 10))
}

@(test)
test_recurring_calendar_exceptions_people_cursor_and_authorization :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	start := appointment_test_at(2026, 10, 19, 10)
	exceptions := fmt.tprintf(
		`[{{"at":"%d","cancelled":true}},{{"at":"%d","cancelled":false,"start_at":"%d","end_at":"","participants":["carol"]}}]`,
		start,
		start + APPOINTMENT_DAY,
		start + APPOINTMENT_DAY + 7200000000000,
	)
	preview := appointment_test_preview(start, "UTC", "daily", "[]", "2026-10-21", exceptions)
	testing.expect(t, validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)preview, nil))
	conv := calendar_test_conversation(); defer destroy_conversation(conv); ws := Workspace_State{}
	asset := alloc_asset(
		transmute([]byte)string("organizer"),
		transmute([]byte)preview,
		nil,
		nil,
	); asset.asset_id = 7; asset.asset_type = .Appointment; asset_store_put(&ws, "", conv, asset)
	testing.expect(t, !appointment_mutation_allowed(asset, nil, "bob")); testing.expect(t, appointment_mutation_allowed(asset, nil, "organizer"))
	for person in ([?]string{"alice", "organizer", "bob", "carol"}) {
		rows, _, _ := calendar_test_collect(
			conv,
			pr.CalendarRequest{start = start, end = start + 4 * APPOINTMENT_DAY, limit = 100, assignee = transmute([]byte)person},
		)
		testing.expect_value(t, len(rows), person == "bob" || person == "carol" ? 1 : 2)
		for row in rows do testing.expect_value(t, string(row.assignee), "alice")
		if person == "carol" && len(rows) == 1 {
			testing.expect_value(t, rows[0].occurrence_at, start + APPOINTMENT_DAY)
			testing.expect_value(t, rows[0].end_at, i64(0))
		}
		delete(rows)
	}
	req := pr.CalendarRequest {
		start = start,
		end   = start + 4 * APPOINTMENT_DAY,
		limit = 1,
	}
	rows, more, _ := calendar_test_collect(conv, req); testing.expect(t, more); testing.expect_value(t, len(rows), 1)
	if len(rows) > 0 {req.has_cursor = true; req.cursor = rows[0].key}; delete(rows)
	rows, more, _ = calendar_test_collect(conv, req); testing.expect(t, !more); testing.expect_value(t, len(rows), 1); delete(rows)
}

@(test)
test_recurring_calendar_strict_schema :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	base := appointment_test_preview(appointment_test_at(2026, 10, 19, 10), "UTC", "weekly", "[1,3]")
	testing.expect(t, validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)base, nil))
	for pair in ([?][2]string{{`"version":2`, `"version":3`}, {`"UTC"`, `"../etc/passwd"`}, {`"UTC"`, `"Mars/Olympus"`}, {`"weekdays":[1,3]`, `"weekdays":[1,1]`}, {`"weekdays":[1,3]`, `"weekdays":[0]`}, {`"participants":["bob"]`, `"participants":["bob","bob"]`}, {`"exceptions":[]`, `"exceptions":[1]`}, {`"conference":"nrc"`, `"conference":"other"`}, {`"until":""`, `"until":"2026-02-30"`}, {`"title":"Series"`, `"title":"Series","unknown":1`}}) {
		bad, _ := strings.replace_all(base, pair[0], pair[1], context.temp_allocator)
		testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)bad, nil), bad)
	}
	start := appointment_test_at(2026, 10, 19, 10)
	people: [65]string
	for &person, i in people do person = fmt.tprintf(`"person%d"`, i)
	joined := strings.join(people[:], ",", context.temp_allocator)
	bad, _ := strings.replace_all(base, `["bob"]`, fmt.tprintf("[%s]", joined), context.temp_allocator)
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)bad, nil))
	exceptions: [33]string
	for &exception, i in exceptions do exception = fmt.tprintf(`{{"at":"%d","cancelled":true}}`, start + i64(i) * APPOINTMENT_DAY)
	joined = strings.join(exceptions[:], ",", context.temp_allocator)
	bad = appointment_test_preview(start, "UTC", "daily", "[]", "", fmt.tprintf("[%s]", joined))
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)bad, nil))
}

@(test)
test_recurring_calendar_duration_bound_and_standalone_v2 :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	start := appointment_test_at(2026, 1, 1, 10)
	base := appointment_test_preview(start, "America/New_York", "daily")
	long, _ := strings.replace_all(
		base,
		fmt.tprintf(`"end_at":"%d"`, start + 3600000000000),
		fmt.tprintf(`"end_at":"%d"`, start + APPOINTMENT_DAY + 1),
		context.temp_allocator,
	)
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)long, nil))
	// A full 24h daily series in a DST zone would duplicate clamped cursor keys.
	long, _ = strings.replace_all(
		base,
		fmt.tprintf(`"end_at":"%d"`, start + 3600000000000),
		fmt.tprintf(`"end_at":"%d"`, start + APPOINTMENT_DAY),
		context.temp_allocator,
	)
	testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)long, nil))
	preview := appointment_test_preview(start, "UTC", "")
	testing.expect(t, validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)preview, nil))
	conv := calendar_test_conversation(); defer destroy_conversation(conv); ws := Workspace_State{}
	asset := alloc_asset(nil, transmute([]byte)preview, nil, nil); asset.asset_id = 1; asset.asset_type = .Appointment; asset_store_put(&ws, "", conv, asset)
	rows, _, _ := calendar_test_collect(
		conv,
		pr.CalendarRequest{start = start, end = start + APPOINTMENT_DAY, limit = 100, assignee = transmute([]byte)string("bob")},
	)
	defer delete(rows); testing.expect_value(t, len(rows), 1)
	if len(rows) == 1 {testing.expect_value(t, rows[0].key.kind, u8(2)); testing.expect_value(t, rows[0].occurrence_at, i64(0))}
}

@(test)
test_recurring_calendar_fold_weekly_and_invalid_exceptions :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	start := appointment_test_at(2026, 10, 31, 5, 30) // 01:30 EDT before fold
	preview := appointment_test_preview(start, "America/New_York", "daily", "[]", "2026-11-02")
	conv := calendar_test_conversation(); defer destroy_conversation(conv); ws := Workspace_State{}
	asset := alloc_asset(nil, transmute([]byte)preview, nil, nil); asset.asset_id = 1; asset.asset_type = .Appointment; asset_store_put(&ws, "", conv, asset)
	rows, _, _ := calendar_test_collect(conv, pr.CalendarRequest{start = start, end = start + 4 * APPOINTMENT_DAY, limit = 100})
	testing.expect_value(t, len(rows), 3)
	if len(rows) ==
	   3 {testing.expect_value(t, rows[1].occurrence_at, appointment_test_at(2026, 11, 1, 5, 30)); testing.expect_value(t, rows[2].occurrence_at, appointment_test_at(2026, 11, 2, 6, 30))}
	delete(rows)
	start = appointment_test_at(2026, 10, 19, 10)
	for exceptions in ([?]string{fmt.tprintf(`[{{"at":"%d","cancelled":false,"start_at":"%d"}}]`, start, start + APPOINTMENT_DAY), fmt.tprintf(`[{{"at":"%d","cancelled":true,"title":"forbidden"}}]`, start), fmt.tprintf(`[{{"at":"%d","cancelled":true}}]`, start + 1), fmt.tprintf(`[{{"at":"%d","cancelled":true}},{{"at":"%d","cancelled":true}}]`, start, start), fmt.tprintf(`[{{"at":"%d","cancelled":true,"participants":[]}}]`, start)}) {
		bad := appointment_test_preview(start, "UTC", "daily", "[]", "", exceptions)
		testing.expect(t, !validate_appointment_asset(.Appointment, .Plain, 0, transmute([]byte)bad, nil), bad)
	}
	preview = appointment_test_preview(start, "UTC", "weekly", "[1,3]", "2026-10-25")
	asset = alloc_asset(nil, transmute([]byte)preview, nil, nil); asset.asset_id = 1; asset.asset_type = .Appointment; asset_store_put(&ws, "", conv, asset)
	rows, _, _ = calendar_test_collect(conv, pr.CalendarRequest{start = start, end = start + 10 * APPOINTMENT_DAY, limit = 100})
	defer delete(rows); testing.expect_value(t, len(rows), 2)
	if len(rows) == 2 do testing.expect_value(t, rows[1].occurrence_at, start + 2 * APPOINTMENT_DAY)
}

@(test)
test_recurring_calendar_handlers_enforce_organizer_in_transactions :: proc(t: ^testing.T) {
	arena: virtual.Arena; testing.expect(t, virtual.arena_init_growing(&arena) == nil); defer virtual.arena_destroy(&arena)
	context.temp_allocator = virtual.arena_allocator(&arena)
	workspace := "recurrence-authorization"
	testing.expect(t, init_room_mapping_test_state("recurrence_authorization.log", workspace)); defer cleanup_room_mapping_test_state()
	c := make_room_mapping_test_connection(workspace); defer send_queue_destroy(&c)
	ws := get_or_create_connection_workspace(&c); conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	preview := appointment_test_preview(appointment_test_at(2026, 10, 19, 10), "UTC", "daily")
	for version in ([?]int{1, 2}) {
		old_preview := version == 1 ? `{"version":1,"title":"legacy","start_at":"100"}` : preview
		asset := alloc_asset(
			transmute([]byte)string("organizer"),
			transmute([]byte)old_preview,
			nil,
			nil,
		); asset.asset_id = 1; asset.conv_id = pr.WORKSPACE_DATA_ID; asset.asset_type = .Appointment
		asset_store_put(ws, workspace, conv, asset)
		handle_update_asset(&c, pr.UpdateAssetRequest{conv_id = pr.WORKSPACE_DATA_ID, asset_id = 1, preview = transmute([]byte)preview})
		testing.expect(t, conv.assets[1] == asset, "non-organizer cannot upgrade or edit v2")
		body := transaction_delta_asset_preview_patch_body(pr.WORKSPACE_DATA_ID, 1, preview)
		ops := [1]pr.TransactionOperation{{op_type = .AssetPatch, body = body[:31 + len(preview)]}}
		process_apply_transaction(&c, pr.ApplyTransactionRequest{operations = ops[:]})
		testing.expect(t, conv.assets[1] == asset, "transaction must enforce the same organizer rule")
		if version == 2 {
			handle_delete_asset(&c, pr.DeleteAssetRequest{conv_id = pr.WORKSPACE_DATA_ID, asset_id = 1})
			testing.expect(t, conv.assets[1] == asset)
			deletion := transaction_test_delete_body(pr.WORKSPACE_DATA_ID, .Asset, 1)
			ops[0] = pr.TransactionOperation {
				op_type = .AssetDelete,
				body    = deletion[:],
			}
			process_apply_transaction(&c, pr.ApplyTransactionRequest{operations = ops[:]})
			testing.expect(t, conv.assets[1] == asset)
		}
		testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(0))
	}
	c.verified_username = "organizer"
	handle_update_asset(&c, pr.UpdateAssetRequest{conv_id = pr.WORKSPACE_DATA_ID, asset_id = 1, preview = transmute([]byte)preview})
	testing.expect(t, string(conv.assets[1].preview) == preview)
	testing.expect_value(t, td.shard_writers.writers[0].wal.record_count, u64(1))
}
