package mem_tlsf

import "base:sanitizer"
import "core:mem"
import "core:testing"

when .Address not_in ODIN_SANITIZER_FLAGS {
	_ :: sanitizer.address_is_poisoned
}

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

@(test)
test_allocation_boundaries_and_reuse :: proc(t: ^testing.T) {
	control: Allocator
	assert(init(&control, context.allocator, 4096, 64 * mem.Kilobyte) == .None)
	defer destroy(&control)
	heap := allocator(&control)
	for alignment in ([]int{8, 64, 4096}) {
		for size in ([]int{1, 7, 8, 9, 23, 24, 25, 513}) {
			for non_zeroed in ([]bool{false, true}) {
				mode: mem.Allocator_Mode = non_zeroed ? .Alloc_Non_Zeroed : .Alloc
				data, err := heap.procedure(heap.data, mode, size, alignment, nil, 0)
				assert(err == .None)
				testing.expect_value(t, uintptr(raw_data(data)) % uintptr(alignment), uintptr(0))
				when .Address in ODIN_SANITIZER_FLAGS {
					testing.expect_value(t, len(data), size)
					testing.expect(t, sanitizer.address_region_is_poisoned(data) == nil)
					testing.expect(t, sanitizer.address_is_poisoned(raw_data(data)[size:]))
				}
				for &b, i in data[:size] {
					if !non_zeroed do testing.expect_value(t, b, byte(0))
					b = byte((i * 7 + 11) % 251)
				}
				assert(mem.free_bytes(data, heap) == .None)
				when .Address in ODIN_SANITIZER_FLAGS {
					testing.expect(t, sanitizer.address_is_poisoned(raw_data(data)))
					testing.expect(t, sanitizer.address_is_poisoned(raw_data(data)[size - 1:]))
				}
			}
		}
	}
}

@(test)
test_resize_reset_and_caller_owned_storage :: proc(t: ^testing.T) {
	for non_zeroed in ([]bool{false, true}) {
		// Eight-byte alignment also makes the caller-owned pool ASan-compatible.
		storage: [2048]u64
		bytes := mem.slice_to_bytes(storage[:])
		control: Allocator
		assert(init(&control, bytes) == .None)
		heap := allocator(&control)
		mode: mem.Allocator_Mode = non_zeroed ? .Resize_Non_Zeroed : .Resize
		data, err := mem.alloc_bytes(129, 8, heap)
		assert(err == .None)
		data = data[:129]
		for &b, i in data do b = byte(i + 3)
		// Grow into adjacent free storage, then split and reuse the old tail.
		grown, grow_err := heap.procedure(heap.data, mode, 513, 8, raw_data(data), len(data))
		assert(grow_err == .None)
		for b, i in grown[:129] do testing.expect_value(t, b, byte(i + 3))
		if !non_zeroed {
			for b in grown[129:] do testing.expect_value(t, b, byte(0))
		}
		small, shrink_err := heap.procedure(heap.data, mode, 19, 8, raw_data(grown), len(grown))
		assert(shrink_err == .None)
		when .Address in ODIN_SANITIZER_FLAGS {
			testing.expect(t, sanitizer.address_region_is_poisoned(small) == nil)
			testing.expect(t, sanitizer.address_is_poisoned(raw_data(small)[19:]))
			testing.expect(t, sanitizer.address_is_poisoned(raw_data(grown)[512:]))
		}
		blocker, blocker_err := mem.alloc_bytes(1024, 8, heap)
		assert(blocker_err == .None)
		for &b in blocker do b = 91
		moved, move_err := heap.procedure(heap.data, mode, 8193, 8, raw_data(small), len(small))
		assert(move_err == .None)
		for b in blocker do testing.expect_value(t, b, byte(91))
		for b, i in moved[:19] do testing.expect_value(t, b, byte(i + 3))
		if !non_zeroed {
			for b in moved[19:] do testing.expect_value(t, b, byte(0))
		}
		when .Address in ODIN_SANITIZER_FLAGS {
			testing.expect(t, sanitizer.address_is_poisoned(raw_data(small)))
		}
		failed, failure := heap.procedure(heap.data, mode, 32768, 8, raw_data(moved), len(moved))
		testing.expect(t, failure == .Out_Of_Memory && failed == nil)
		for b, i in moved[:19] do testing.expect_value(t, b, byte(i + 3))
		assert(mem.free_bytes(moved, heap) == .None)
		// Free_All invalidates live data; destroy returns unpoisoned caller storage.
		_, reset_err := heap.procedure(heap.data, .Free_All, 0, 0, nil, 0)
		assert(reset_err == .None)
		when .Address in ODIN_SANITIZER_FLAGS {
			testing.expect(t, sanitizer.address_is_poisoned(raw_data(blocker)))
		}
		destroy(&control)
		mem.zero(raw_data(bytes), len(bytes))
	}
}

when TLSF_ASAN_QUARANTINE {
	@(test)
	test_quarantine_delays_reuse_and_evicts_oldest_at_limits :: proc(t: ^testing.T) {
		control: Allocator
		assert(init(&control, context.allocator, 4 * mem.Megabyte) == .None)
		defer destroy(&control)
		heap := allocator(&control)
		blocks: [129][]byte
		for &b in blocks {
			err: mem.Allocator_Error
			b, err = mem.alloc_bytes(32, 8, heap)
			assert(err == .None)
		}
		for b in blocks[:128] do assert(mem.free_bytes(b, heap) == .None)
		// Direct dispatch: mem.alloc_bytes short-circuits zero-size requests.
		_, _ = heap.procedure(heap.data, .Alloc, 0, 8, nil, 0)
		_, _ = heap.procedure(heap.data, .Alloc_Non_Zeroed, 0, 8, nil, 0)
		fresh, fresh_err := mem.alloc_bytes(32, 8, heap)
		assert(fresh_err == .None)
		for b in blocks[:128] {
			testing.expect(t, raw_data(fresh) != raw_data(b))
			testing.expect(t, sanitizer.address_is_poisoned(raw_data(b)))
		}
		// Consecutive evictions wrap both FIFO indices without resetting the heap.
		held := blocks[128]
		for i in 0 ..< 3 * len(blocks) {
			assert(mem.free_bytes(held, heap) == .None)
			reused, reuse_err := mem.alloc_bytes(32, 8, heap)
			assert(reuse_err == .None)
			testing.expect_value(t, raw_data(reused), raw_data(blocks[i % len(blocks)]))
			held = reused
		}
		assert(mem.free_bytes(fresh, heap) == .None)
		assert(mem.free_bytes(held, heap) == .None)
		_, reset_err := heap.procedure(heap.data, .Free_All, 0, 0, nil, 0)
		assert(reset_err == .None)
		large: [3][]byte
		for &b in large {
			err: mem.Allocator_Error
			b, err = mem.alloc_bytes(400 * mem.Kilobyte, 8, heap)
			assert(err == .None)
		}
		for b in large do assert(mem.free_bytes(b, heap) == .None)
		// Three blocks exceed 1 MiB, though far below the entry-count limit.
		reused, err := mem.alloc_bytes(400 * mem.Kilobyte, 8, heap)
		assert(err == .None)
		testing.expect_value(t, raw_data(reused), raw_data(large[0]))
		for b in large[1:] do testing.expect(t, sanitizer.address_is_poisoned(raw_data(b)))
		assert(mem.free_bytes(reused, heap) == .None)
		// A single block larger than the byte budget bypasses the FIFO.
		huge, huge_err := mem.alloc_bytes(2 * mem.Megabyte, 8, heap)
		assert(huge_err == .None)
		assert(mem.free_bytes(huge, heap) == .None)
		huge_again, again_err := mem.alloc_bytes(2 * mem.Megabyte, 8, heap)
		assert(again_err == .None)
		testing.expect_value(t, raw_data(huge_again), raw_data(huge))
		assert(mem.free_bytes(huge_again, heap) == .None)
	}

	@(test)
	test_quarantine_releases_under_pressure_and_resets :: proc(t: ^testing.T) {
		storage: [128]u64
		bytes := mem.slice_to_bytes(storage[:])
		control: Allocator
		assert(init(&control, bytes) == .None)
		heap := allocator(&control)
		for _ in 0 ..< 2 {
			data, err := mem.alloc_bytes(800, 8, heap)
			assert(err == .None)
			assert(mem.free_bytes(data, heap) == .None)
			// A fixed pool must reuse quarantine storage rather than falsely OOM.
			reused, reuse_err := mem.alloc_bytes(800, 8, heap)
			assert(reuse_err == .None)
			testing.expect_value(t, raw_data(reused), raw_data(data))
			for &b in reused do b = 73
			assert(mem.free_bytes(reused, heap) == .None)
			_, reset_err := heap.procedure(heap.data, .Free_All, 0, 0, nil, 0)
			assert(reset_err == .None)
		}
		destroy(&control)
		mem.zero(raw_data(bytes), len(bytes))
	}
}
