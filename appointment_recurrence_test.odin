package main

import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:testing"
import "core:time"

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
}
