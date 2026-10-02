package spsc

import "core:fmt"
import "core:os"
import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"

SPSC_BENCH_ITEMS :: #config(SPSC_BENCH_ITEMS, 100_000_000)
SPSC_BENCH_CAPACITY :: #config(SPSC_BENCH_CAPACITY, 16_384)
#assert(SPSC_BENCH_ITEMS > 0 && SPSC_BENCH_ITEMS <= 1_000_000_000)
#assert(SPSC_BENCH_CAPACITY > 0 && SPSC_BENCH_CAPACITY < max(int))

@(private)
Bench_State :: struct {
	queue:      ^Queue(u64),
	items:      int,
	ready:      bool,
	start:      bool,
	checksum:   u64,
	mismatches: int,
}

@(private)
bench_consume :: proc(s: ^Bench_State) {
	sync.atomic_store(&s.ready, true)
	for !sync.atomic_load(&s.start) do sync.cpu_relax()
	checksum: u64
	mismatches := 0
	for i in 0 ..< s.items {
		value, ok := try_pop(s.queue)
		for !ok {
			sync.cpu_relax()
			value, ok = try_pop(s.queue)
		}
		checksum += value
		if value != u64(i) * 7 + 3 do mismatches += 1
	}
	s.checksum = checksum
	s.mismatches = mismatches
}

// Main is the producer. Thread creation and queue allocation are outside the
// timed interval; start signalling, retries, validation arithmetic and the
// final consumer join are included. There are no eventfd wakes or CPU pins.
@(private)
bench_transfer :: proc(t: ^testing.T, q: ^Queue(u64), items: int) -> time.Duration {
	s := Bench_State {
		queue = q,
		items = items,
	}
	consumer := thread.create_and_start_with_poly_data(&s, bench_consume)
	defer thread.destroy(consumer)
	for !sync.atomic_load(&s.ready) do sync.cpu_relax()
	start := time.tick_now()
	sync.atomic_store(&s.start, true)
	for i in 0 ..< items {
		value := u64(i) * 7 + 3
		for !try_push(q, value) do sync.cpu_relax()
	}
	thread.join(consumer)
	elapsed := time.tick_since(start)
	// Independent arithmetic-series expectation; also detect reordering, which
	// a sum alone cannot catch. Consumer ownership transfers back after the join.
	n := u64(items)
	testing.expect_value(t, s.checksum, 7 * (n * (n - 1) / 2) + 3 * n)
	testing.expect_value(t, s.mismatches, 0)
	_, extra := try_pop(q)
	testing.expect(t, !extra, "all published items must have been consumed")
	return elapsed
}

@(test)
benchmark_spsc_transfer :: proc(t: ^testing.T) {
	env, enabled := os.lookup_env_alloc("BENCH_SPSC", context.allocator)
	defer delete(env)
	if !enabled do return
	q, err := create(u64, SPSC_BENCH_CAPACITY)
	if !testing.expect(t, err == .None) do return
	defer destroy(q)
	// Exercise the same queue before measuring, including repeated wraparound.
	_ = bench_transfer(t, q, 100_000)
	elapsed := bench_transfer(t, q, SPSC_BENCH_ITEMS)
	seconds := f64(elapsed) / f64(time.Second)
	fmt.printf(
		"SPSC warmed u64 transfer: capacity=%d items=%d seconds=%.6f Mitems/s=%.3f ns/item=%.3f\n",
		SPSC_BENCH_CAPACITY,
		SPSC_BENCH_ITEMS,
		seconds,
		f64(SPSC_BENCH_ITEMS) / seconds / 1e6,
		seconds * 1e9 / f64(SPSC_BENCH_ITEMS),
	)
}
