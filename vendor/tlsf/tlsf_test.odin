package mem_tlsf

import "core:mem"
import "core:testing"

Failing_Backing :: struct {
	parent:         mem.Allocator,
	fail_tracking:  bool,
	live, failures: int,
}

failing_backing_proc :: proc(
	data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	mem.Allocator_Error,
) {
	state := cast(^Failing_Backing)data
	if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && size == size_of(Pool) && state.fail_tracking {
		state.failures += 1
		return nil, .Out_Of_Memory
	}
	result, err := state.parent.procedure(state.parent.data, mode, size, alignment, old_memory, old_size, location)
	if err == .None {
		if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && len(result) > 0 do state.live += 1
		if mode == .Free && old_memory != nil do state.live -= 1
	}
	return result, err
}

@(test)
test_growth_tracking_failure_rolls_back_pool_and_preserves_existing_data :: proc(t: ^testing.T) {
	state := Failing_Backing {
		parent        = context.allocator,
		fail_tracking = true,
	}
	backing := mem.Allocator {
		procedure = failing_backing_proc,
		data      = &state,
	}
	control: Allocator
	assert(init(&control, backing, 4096, 64 * mem.Kilobyte) == .None)
	heap := allocator(&control)
	original, err := mem.alloc_bytes(513, 64, heap)
	assert(err == .None)
	original = original[:513]
	for &b, i in original do b = byte((i * 3 + 17) % 251)
	for attempt in 0 ..< 2 {
		result: []byte
		growth_err: mem.Allocator_Error
		if attempt == 0 {
			result, growth_err = mem.resize_bytes(original, 8193, 64, heap)
		} else {
			result, growth_err = mem.alloc_bytes(8193, 64, heap)
		}
		testing.expect_value(t, growth_err, mem.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(result), 0)
		testing.expect_value(t, state.live, 1)
		testing.expect_value(t, state.failures, attempt + 1)
		testing.expect_value(t, control.pool.next, (^Pool)(nil))
		for b, i in original do testing.expect_value(t, b, byte((i * 3 + 17) % 251))
	}
	// The original free lists are still usable after rollback.
	small, small_err := mem.alloc_bytes(257, 64, heap)
	assert(small_err == .None)
	_ = mem.free_bytes(small, heap)
	state.fail_tracking = false
	grown, grown_err := mem.resize_bytes(original, 8193, 64, heap)
	assert(grown_err == .None)
	grown = grown[:8193]
	testing.expect(t, control.pool.next != nil)
	for b, i in grown do testing.expect_value(t, b, i < 513 ? byte((i * 3 + 17) % 251) : byte(0))
	_ = mem.free_bytes(grown, heap)
	destroy(&control)
	testing.expect_value(t, state.live, 0)
}
