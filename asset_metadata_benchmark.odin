package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

Metadata_Bench_Reader :: enum {
	Ticket_Read,
	Ticket_Strict,
	Entry_Read,
	Entry_Strict,
	Slice,
}

Metadata_Bench_State :: struct {
	data:     []byte,
	arena:    ^virtual.Arena,
	reader:   Metadata_Bench_Reader,
	checksum: u64,
}

// The checksum consumes the fields each contract actually returns. Full values
// are checked before timing; strict validation is not equivalent to a read.
metadata_bench_read :: proc(s: ^Metadata_Bench_State, a: mem.Allocator, t: ^testing.T = nil) -> u64 {
	switch s.reader {
	case .Ticket_Read, .Ticket_Strict:
		m, ok := parse_ticket_preview(s.data, a, strict = s.reader == .Ticket_Strict)
		if t != nil {
			testing.expect(t, ok)
			testing.expect_value(t, m.title, "Call Alex")
			testing.expect_value(t, m.status, "open")
			testing.expect_value(t, m.assignee, "alice")
			testing.expect_value(t, m.company_id, "42")
			testing.expect_value(t, m.contact_id, "73")
			testing.expect_value(t, m.requester, "a@example.org")
			testing.expect_value(t, m.requester_name, "Alex")
		}
		if !ok do return 0
		return u64(len(m.title) + len(m.status) + len(m.assignee) + len(m.company_id) + len(m.contact_id) + len(m.requester) + len(m.requester_name))
	case .Entry_Read, .Entry_Strict:
		m, ok := parse_ticket_entry_preview(s.data, a, strict = s.reader == .Entry_Strict)
		if t != nil {
			testing.expect(t, ok)
			testing.expect_value(t, m.kind, "customer_reply")
			testing.expect_value(t, m.author, s.reader == .Entry_Strict ? "Alex" : "")
		}
		if !ok do return 0
		return u64(len(m.kind) + len(m.author))
	case .Slice:
		m, ok := decode_slice_preview(s.data, a)
		if t != nil {
			testing.expect(t, ok)
			testing.expect_value(t, m.version, 1)
			testing.expect_value(t, m.name, "Call Alex")
			testing.expect_value(t, m.owner, "alice")
			testing.expect_value(t, m.outcome, "done")
			testing.expect(t, m.closed)
			testing.expect_value(t, m.closed_at, i64(123))
			testing.expect_value(t, m.closed_by, "bob")
		}
		if !ok do return 0
		return u64(len(m.name) + len(m.owner) + len(m.outcome) + len(m.closed_by) + int(m.closed_at))
	}
	return 0
}

metadata_bench_callback :: proc(options: ^time.Benchmark_Options, _: mem.Allocator) -> time.Benchmark_Error {
	s := cast(^Metadata_Bench_State)options.user_data
	a := virtual.arena_allocator(s.arena)
	for _ in 0 ..< options.rounds {
		s.checksum += metadata_bench_read(s, a)
		virtual.arena_free_all(s.arena)
	}
	options.count = options.rounds
	options.processed = options.rounds * len(s.data)
	options.hash = u128(s.checksum)
	return .Okay
}

@(test)
benchmark_asset_metadata :: proc(t: ^testing.T) {
	env, enabled := os.lookup_env_alloc("BENCH_ASSET_METADATA", context.allocator)
	defer delete(env)
	if !enabled do return
	alloc_env, allocations := os.lookup_env_alloc("BENCH_ASSET_METADATA_ALLOC", context.allocator)
	defer delete(alloc_env)
	// Runtime-built, valid version-1 previews: ordinary, escaped, and 64 ignored
	// nested records. All stay within the 4096-byte preview limit.
	fixtures := [?]string {
		`{"version":1,"title":"Call Alex","status":"open","assignee":"alice","company_id":"42","contact_id":"73","requester":"a@example.org","requester_name":"Alex"}`,
		`{"version":1,"kind":"customer_reply","author":"Alex"}`,
		`{"version":1,"name":"Call Alex","owner":"alice","outcome":"done","closed":true,"closed_at":123,"closed_by":"bob"}`,
	}
	// Independent expected sums of output lengths, plus the slice timestamp.
	expected := [Metadata_Bench_Reader]u64 {
		.Ticket_Read   = 39,
		.Ticket_Strict = 39,
		.Entry_Read    = 14,
		.Entry_Strict  = 18,
		.Slice         = 144,
	}
	extra := strings.repeat(`{"numbers":[1,2,3],"text":"ignored"},`, 64)
	defer delete(extra)
	for reader in Metadata_Bench_Reader {
		base := fixtures[reader == .Slice ? 2 : (reader == .Entry_Read || reader == .Entry_Strict ? 1 : 0)]
		for fixture in 0 ..< 3 {
			data: string
			switch fixture {
			case 0:
				data = strings.clone(base)
			case 1:
				data, _ = strings.replace_all(base, "Alex", `\u0041lex`)
			case 2:
				data = strings.concatenate({base[:len(base) - 1], `,"extra":[`, extra[:len(extra) - 1], `]}`})
			}
			defer delete(data)
			testing.expect(t, len(data) <= 4096)
			arena: virtual.Arena
			testing.expect(t, virtual.arena_init_growing(&arena) == nil)
			defer virtual.arena_destroy(&arena)
			s := Metadata_Bench_State {
				data   = transmute([]byte)data,
				arena  = &arena,
				reader = reader,
			}
			testing.expect_value(t, metadata_bench_read(&s, virtual.arena_allocator(&arena), t), expected[reader])
			virtual.arena_free_all(&arena)
			if allocations {
				tracker: mem.Tracking_Allocator
				mem.tracking_allocator_init(&tracker, virtual.arena_allocator(&arena))
				defer mem.tracking_allocator_destroy(&tracker)
				testing.expect_value(t, metadata_bench_read(&s, mem.tracking_allocator(&tracker)), expected[reader])
				fmt.printf(
					"METADATA_ALLOC fixture=%d reader=%v allocations=%d bytes=%d\n",
					fixture,
					reader,
					tracker.total_allocation_count,
					tracker.total_memory_allocated,
				)
				continue
			}
			warm := time.Benchmark_Options {
				bench     = metadata_bench_callback,
				rounds    = 1000,
				user_data = &s,
			}
			testing.expect_value(t, time.benchmark(&warm), time.Benchmark_Error.Okay)
			warm.rounds = 10000
			testing.expect_value(t, time.benchmark(&warm), time.Benchmark_Error.Okay)
			rounds := max(1, int(0.75 / time.duration_seconds(warm.duration) * f64(warm.rounds)))
			s.checksum = 0
			options := time.Benchmark_Options {
				bench     = metadata_bench_callback,
				rounds    = rounds,
				user_data = &s,
			}
			testing.expect_value(t, time.benchmark(&options), time.Benchmark_Error.Okay)
			testing.expect_value(t, s.checksum, u64(rounds) * expected[reader])
			fmt.printf(
				"METADATA_TIME fixture=%d reader=%v count=%d ns_per_op=%.2f seconds=%.3f\n",
				fixture,
				reader,
				options.count,
				f64(time.duration_nanoseconds(options.duration)) / f64(options.count),
				time.duration_seconds(options.duration),
			)
		}
	}
}
