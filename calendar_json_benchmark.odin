package main

import "core:encoding/json"
import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"
import pr "protocol"

// Valid-fixture baseline: the former JSON tree extraction, without its separate
// safety preflight. This deliberately gives the tree reader the cheaper case.
calendar_bench_tree :: proc(asset: ^pr.Asset, allocator: mem.Allocator) -> (at: i64, title: []byte) {
	value: json.Value
	if json.unmarshal(asset.payload, &value, spec = .JSON, allocator = allocator) != nil do return
	object, ok := value.(json.Object); if !ok do return
	deadline := object["deadline_at"]
	if _, null := deadline.(json.Null); deadline == nil || null do deadline = object["deadlineAt"]
	#partial switch v in deadline {
	case string:
		at, _ = json_metadata_integer(v)
	case i64:
		at = v
	case f64:
		if v > 0 && v < 9223372036854775808.0 do at = i64(v)
	}
	name, _ := object["title"].(string)
	if name == "" do name, _ = object["name"].(string)
	if name == "" do name = string(asset.preview)
	name = strings.trim_space(name)
	if at <= 0 || name == "" do return 0, nil
	return at, transmute([]byte)name
}

Calendar_Bench_State :: struct {
	asset:    pr.Asset,
	arena:    ^virtual.Arena,
	reader:   proc(_: ^pr.Asset, _: mem.Allocator) -> (i64, []byte),
	checksum: u64,
}

calendar_bench_callback :: proc(options: ^time.Benchmark_Options, _: mem.Allocator) -> time.Benchmark_Error {
	s := cast(^Calendar_Bench_State)options.user_data
	a := virtual.arena_allocator(s.arena)
	for _ in 0 ..< options.rounds {
		at, title := s.reader(&s.asset, a)
		s.checksum += u64(at) + u64(len(title))
		virtual.arena_free_all(s.arena)
	}
	options.count = options.rounds
	options.processed = options.rounds * len(s.asset.payload)
	options.hash = u128(s.checksum)
	return .Okay
}

@(test)
benchmark_calendar_json :: proc(t: ^testing.T) {
	env, enabled := os.lookup_env_alloc("BENCH_CALENDAR_JSON", context.allocator)
	defer delete(env)
	if !enabled do return
	alloc_env, allocations := os.lookup_env_alloc("BENCH_CALENDAR_JSON_ALLOC", context.allocator)
	defer delete(alloc_env)
	// Construct runtime fixtures before timing, identical for both readers.
	extra := make([dynamic]byte)
	defer delete(extra)
	append(&extra, ..transmute([]byte)string(`{"title":"Call Alex","deadline_at":"123","extra":[`))
	for i in 0 ..< 64 {
		if i > 0 do append(&extra, ',')
		append(&extra, ..transmute([]byte)string(`{"numbers":[1,2,3],"text":"ignored metadata","enabled":true}`))
	}
	append(&extra, ']', '}')
	fixtures := [?]string {
		`{"title":"Call Alex","deadline_at":"123","urgency_days":3,"note_asset_id":"0","window_start_at":"0"}`,
		`{"title":"Call \u0041lex","deadline_at":"123","urgency_days":3,"note_asset_id":"0","window_start_at":"0"}`,
		string(extra[:]),
	}
	for payload, fixture in fixtures {
		for reader, implementation in ([?]proc(_: ^pr.Asset, _: mem.Allocator) -> (i64, []byte){calendar_bench_tree, calendar_reminder}) {
			arena: virtual.Arena
			testing.expect(t, virtual.arena_init_growing(&arena) == nil)
			defer virtual.arena_destroy(&arena)
			s := Calendar_Bench_State {
				asset = {asset_type = .Reminder, payload = transmute([]byte)payload},
				arena = &arena,
				reader = reader,
			}
			if allocations {
				tracker: mem.Tracking_Allocator
				mem.tracking_allocator_init(&tracker, virtual.arena_allocator(&arena))
				defer mem.tracking_allocator_destroy(&tracker)
				at, title := reader(&s.asset, mem.tracking_allocator(&tracker))
				testing.expect_value(t, at, i64(123))
				testing.expect_value(t, string(title), "Call Alex")
				fmt.printf(
					"CALENDAR_ALLOC fixture=%d reader=%d allocations=%d bytes=%d\n",
					fixture,
					implementation,
					tracker.total_allocation_count,
					tracker.total_memory_allocated,
				)
				continue
			}
			warm := time.Benchmark_Options {
				bench     = calendar_bench_callback,
				rounds    = 1000,
				user_data = &s,
			}
			testing.expect_value(t, time.benchmark(&warm), time.Benchmark_Error.Okay)
			s.checksum = 0
			rounds := implementation == 0 ? 250000 : 500000
			if fixture == 2 do rounds = implementation == 0 ? 5000 : 15000
			options := time.Benchmark_Options {
				bench     = calendar_bench_callback,
				rounds    = rounds,
				user_data = &s,
			}
			testing.expect_value(t, time.benchmark(&options), time.Benchmark_Error.Okay)
			testing.expect_value(t, s.checksum, u64(options.rounds) * 132)
			fmt.printf(
				"CALENDAR_TIME fixture=%d reader=%d count=%d ns_per_op=%.2f seconds=%.3f\n",
				fixture,
				implementation,
				options.count,
				f64(time.duration_nanoseconds(options.duration)) / f64(options.count),
				time.duration_seconds(options.duration),
			)
		}
	}
}
