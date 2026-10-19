package main

import wo ".."
import "../../clock"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"

exercise :: proc(nodes: []wo.Node) -> u64 {
	a, b := wo.order(nodes)
	defer delete(a)
	defer delete(b)
	checksum: u64
	for id, i in a {checksum += id * u64(i + 1)}
	for id, i in b {checksum += id * u64(i + 1)}
	return checksum
}

main :: proc() {
	allocations := len(os.args) > 1 && os.args[1] == "alloc"
	sizes := []int{100, 1000, 10000, 100000}
	shapes := []string{"independent", "chain", "fanout", "mixed", "cycle"}
	for n in sizes {
		for shape in shapes {
			nodes := make([]wo.Node, n)
			for &node, i in nodes {
				node = wo.Node {
					id       = u64(i + 1),
					priority = i64(i % 17) - 8,
					due_at   = i64(i % 31),
				}
				switch shape {
				case "chain":
					node.dependency = u64(i)
				case "fanout":
					if i > 0 {node.dependency = 1}
				case "mixed":
					if i % 7 != 0 {node.dependency = u64(i / 2 + 1)}
					if i % 19 == 0 {node.dependency = u64(n + 1)}
				case "cycle":
					node.dependency = u64((i + 1) % n + 1)
				}
			}
			expected := exercise(nodes) // Warm-cache, deterministic fixture and checksum.
			if allocations {
				tracker: mem.Tracking_Allocator
				mem.tracking_allocator_init(&tracker, context.allocator)
				{
					context.allocator = mem.tracking_allocator(&tracker)
					assert(exercise(nodes) == expected)
				}
				assert(len(tracker.allocation_map) == 0)
				fmt.printf("%s,%d,alloc,%d,%d\n", shape, n, tracker.total_allocation_count, tracker.total_memory_allocated)
				mem.tracking_allocator_destroy(&tracker)
			} else {
				// Untimed calibration targets approximately 0.75 seconds per sample.
				pilot_rounds := 1
				pilot: i64
				for {
					pilot_start := clock.now_monotonic()
					for _ in 0 ..< pilot_rounds {_ = exercise(nodes)}
					pilot = max(i64(time.diff(pilot_start, clock.now_monotonic())), 1)
					if pilot >= 50_000_000 {break}
					pilot_rounds *= 2
				}
				rounds := max(1, int(750_000_000 * i64(pilot_rounds) / pilot))
				checksum: u64
				start := clock.now_monotonic()
				for _ in 0 ..< rounds {checksum += exercise(nodes)}
				elapsed := i64(time.diff(start, clock.now_monotonic()))
				assert(checksum == expected * u64(rounds))
				fmt.printf("%s,%d,time,%d,%d\n", shape, n, rounds, elapsed)
			}
			delete(nodes)
		}
	}
}
