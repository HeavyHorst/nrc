package main

import "clock"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:testing"
import "core:time"
import pr "protocol"

// Measures the real collection path through its first 100 rows, not WebSocket
// latency or serialization. Fixtures and indexes are constructed outside timing.
@(test)
benchmark_task_work_order_page :: proc(t: ^testing.T) {
	enabled := os.get_env("BENCH_WORK_ORDER", context.allocator)
	defer delete(enabled)
	if enabled != "1" do return
	mode := os.get_env("BENCH_WORK_ORDER_ALLOC", context.allocator)
	defer delete(mode)
	allocation_run := mode == "1"
	for n in ([?]int{100, 1000, 10000, 100000}) {
		for shape in ([?]string{"independent", "chain", "fanout", "mixed", "cycle"}) {
			conv: Conversation_State
			conv.tasks = make(map[pr.TaskID]^pr.Task, n)
			tasks := make([]pr.Task, n)
			for &task, i in tasks {
				task = pr.Task {
					id       = pr.TaskID(i + 1),
					status   = .Todo,
					priority = u8(i % 17),
					due_at   = i64(i % 31),
				}
				switch shape {
				case "chain":
					task.blocked_by = pr.TaskID(i)
				case "fanout":
					if i > 0 do task.blocked_by = 1
				case "mixed":
					if i % 7 != 0 do task.blocked_by = pr.TaskID(i / 2 + 1)
					if i % 19 == 0 do task.blocked_by = pr.TaskID(n + 1)
				case "cycle":
					task.blocked_by = pr.TaskID((i + 1) % n + 1)
				}
				conv.tasks[task.id] = &task
			}
			req := pr.TaskQueryRequest {
				status_mask = 7,
				sort        = .WorkOrder,
				limit       = 100,
				color       = 255,
			}
			expected := work_order_bench_page(&conv, req)
			if allocation_run {
				tracker: mem.Tracking_Allocator
				mem.tracking_allocator_init(&tracker, context.allocator)
				{
					context.allocator = mem.tracking_allocator(&tracker)
					testing.expect_value(t, work_order_bench_page(&conv, req), expected)
				}
				testing.expect_value(t, len(tracker.allocation_map), 0)
				fmt.printf("page,%s,%d,alloc,%d,%d\n", shape, n, tracker.total_allocation_count, tracker.total_memory_allocated)
				mem.tracking_allocator_destroy(&tracker)
			} else {
				pilot_rounds := 1
				pilot: i64
				for {
					start := clock.now_monotonic()
					for _ in 0 ..< pilot_rounds {_ = work_order_bench_page(&conv, req)}
					pilot = max(i64(time.diff(start, clock.now_monotonic())), 1)
					if pilot >= 50_000_000 do break
					pilot_rounds *= 2
				}
				rounds := max(1, int(750_000_000 * i64(pilot_rounds) / pilot))
				checksum: u64
				start := clock.now_monotonic()
				for _ in 0 ..< rounds {checksum += work_order_bench_page(&conv, req)}
				elapsed := i64(time.diff(start, clock.now_monotonic()))
				testing.expect_value(t, checksum, expected * u64(rounds))
				fmt.printf("page,%s,%d,time,%d,%d\n", shape, n, rounds, elapsed)
			}
			delete(tasks)
			delete(conv.tasks)
		}
	}
}

work_order_bench_page :: proc(conv: ^Conversation_State, req: pr.TaskQueryRequest) -> u64 {
	rows := make([dynamic]pr.Task, 0, 100)
	defer delete(rows)
	page := collect_task_query_page(conv, req, &rows)
	checksum := u64(page.total_count)
	for task, i in rows {checksum += u64(task.id) * u64(i + 1)}
	return checksum
}
