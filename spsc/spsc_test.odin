package spsc

import hgl "../hegel"
import "core:testing"

@(test)
test_capacity_wrap_and_cached_indices :: proc(t: ^testing.T) {
	// Includes a single usable slot, non-power-of-two ring sizes and NRC's
	// production capacity. Values distinguish FIFO order and successive cycles.
	capacities := [4]int{1, 2, 3, 16_384}
	for capacity in capacities {
		q, err := create(int, capacity)
		if !testing.expect(t, err == .None) do return
		defer destroy(q)
		producer := q
		consumer := q
		for cycle in 0 ..< 4 {
			base := cycle * (capacity + 1)
			_, received := try_pop(consumer)
			testing.expect(t, !received && !can_pop(consumer))
			for i in 0 ..< capacity {
				testing.expect(t, can_push(producer))
				testing.expect(t, can_push(producer), "preflight must not reserve a slot")
				testing.expect(t, try_push(producer, base + i + 1))
			}
			// The consumer's cached head still describes an empty ring here.
			testing.expect(t, can_pop(consumer), "availability must read the published head")
			testing.expect(t, can_pop(consumer), "availability must not consume an item")
			testing.expect(t, !can_push(producer))
			testing.expect(t, !try_push(producer, -1), "full push must preserve existing values")
			first, ok := try_pop(consumer)
			testing.expect(t, ok && first == base + 1)
			// Refresh a stale full producer cache while the consumer still has data.
			testing.expect(t, try_push(producer, base + capacity + 1))
			for i in 1 ..< capacity + 1 {
				value, present := try_pop(consumer)
				testing.expect(t, present && value == base + i + 1, "FIFO must survive partial drain and wrap")
			}
			_, extra := try_pop(consumer)
			testing.expect(t, !extra && !can_pop(consumer))
		}
	}
}

@(test)
test_hegel_fifo_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_fifo_model, nil, {test_cases = 2000})
	testing.expectf(t, err == nil, "hegel SPSC FIFO model failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

@(private)
Model_Value :: struct {
	sequence: int,
	payload:  i64,
}

// Sequential model checking, not an OS-thread or weak-memory scheduler. The
// Handoff integration test separately exercises real threads and wakeups.
prop_fifo_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	capacity_raw, capacity_err := hgl.draw_i64(tc, 1, 16)
	if capacity_err == .Stop_Test do return hgl.abort()
	if capacity_err != nil do return hgl.interesting("draw capacity")
	capacity := int(capacity_raw)
	steps, steps_err := hgl.draw_i64(tc, 1, 128)
	if steps_err == .Stop_Test do return hgl.abort()
	if steps_err != nil do return hgl.interesting("draw steps")
	q, err := create(Model_Value, capacity)
	if err != .None do return hgl.interesting("create queue")
	defer destroy(q)

	// A linear list, deliberately independent of ring indices and cursor caches.
	model: [16]Model_Value
	count := 0
	sequence := 0
	for _ in 0 ..< steps {
		op, op_err := hgl.draw_i64(tc, 0, 3)
		if op_err == .Stop_Test do return hgl.abort()
		if op_err != nil do return hgl.interesting("draw operation")
		burst, burst_err := hgl.draw_i64(tc, 1, i64(capacity + 2))
		if burst_err == .Stop_Test do return hgl.abort()
		if burst_err != nil do return hgl.interesting("draw burst")
		payload, payload_err := hgl.draw_i64(tc, -100_000, 100_000)
		if payload_err == .Stop_Test do return hgl.abort()
		if payload_err != nil do return hgl.interesting("draw payload")
		for _ in 0 ..< burst {
			switch op {
			case 0:
				sequence += 1
				value := Model_Value {
					sequence = sequence,
					payload  = payload,
				}
				// Do not preflight each push: that would hide missing cache
				// refreshes in try_push by refreshing via can_push instead.
				pushed := try_push(q, value)
				if pushed != (count < capacity) do return hgl.interesting("push capacity differs from model")
				if pushed {
					model[count] = value
					count += 1
				}
			case 1:
				value, popped := try_pop(q)
				if popped != (count > 0) do return hgl.interesting("pop availability differs from model")
				if popped {
					if value != model[0] do return hgl.interesting("FIFO payload differs from model")
					for i in 1 ..< count do model[i - 1] = model[i]
					count -= 1
				}
			case 2:
				if can_push(q) != (count < capacity) do return hgl.interesting("can_push differs from model")
			case 3:
				if can_pop(q) != (count > 0) do return hgl.interesting("can_pop differs from model")
			}
		}
	}
	// Also expose corruption from rejected pushes or supposedly read-only checks.
	for i in 0 ..< count {
		value, ok := try_pop(q)
		if !ok || value != model[i] do return hgl.interesting("final drain differs from model")
	}
	_, extra := try_pop(q)
	if extra || can_pop(q) || !can_push(q) do return hgl.interesting("final empty state differs from model")
	return hgl.valid()
}
