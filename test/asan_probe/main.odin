package main

import "../../byte_pool"
import tlsf "../../vendor/tlsf"
import "core:fmt"
import "core:mem"
import "core:os"

main :: proc() {
	assert(len(os.args) == 2)
	heap: tlsf.Allocator
	assert(tlsf.init(&heap, context.allocator, 4096, 64 * mem.Kilobyte) == .None)
	defer tlsf.destroy(&heap)
	allocator := tlsf.allocator(&heap)
	pool := byte_pool.init_buffer_pool(allocator)
	assert(pool != nil)
	defer byte_pool.destroy_buffer_pool(pool)
	a, err := byte_pool.alloc(pool, 37)
	assert(err == .None)
	b, err_b := byte_pool.alloc(pool, 53)
	assert(err_b == .None)
	defer byte_pool.release(pool, b)
	for &v, i in a do v = byte(i + 1)
	for &v in b do v = 91
	ptr := raw_data(a)
	switch os.args[1] {
	case "valid":
		// Exercise TLSF's own resize path as well as byte_pool's.
		raw, raw_err := mem.alloc_bytes(23, 256, allocator)
		assert(raw_err == .None)
		for &v, i in raw do v = byte(3 * i + 7)
		raw_grown, raw_grow_err := mem.resize_bytes(raw, 97, 256, allocator)
		assert(raw_grow_err == .None && uintptr(raw_data(raw_grown)) % 256 == 0)
		for v, i in raw_grown do assert(v == (i < 23 ? byte(3 * i + 7) : byte(0)))
		raw_small, raw_shrink_err := mem.resize_bytes(raw_grown, 11, 8, allocator)
		assert(raw_shrink_err == .None)
		for v, i in raw_small do assert(v == byte(3 * i + 7))
		assert(mem.free_bytes(raw_small, allocator) == .None)
		// Grow, preserve an asymmetric prefix, zero the tail, then shrink.
		grown, grow_err := mem.resize_bytes(a, 129, 64, byte_pool.allocator(pool))
		assert(grow_err == .None)
		assert(uintptr(raw_data(grown)) % 64 == 0)
		for v, i in grown do assert(v == (i < 37 ? byte(i + 1) : byte(0)))
		small, shrink_err := mem.resize_bytes(grown, 19, 8, byte_pool.allocator(pool))
		assert(shrink_err == .None)
		for v, i in small do assert(v == byte(i + 1))
		byte_pool.release(pool, small)
		for v in b do assert(v == 91)
		assert(pool.live_allocs == 1)
		fmt.println("valid allocation/resize/release control passed")
	case "use-after-free":
		byte_pool.release(pool, a)
		fmt.println(ptr[0]) // Must fail through ASan, not a slice bounds check.
	case "reuse":
		byte_pool.release(pool, a)
		replacement, replace_err := byte_pool.alloc(pool, 37)
		assert(replace_err == .None)
		defer byte_pool.release(pool, replacement)
		when tlsf.TLSF_ASAN_QUARANTINE {
			assert(raw_data(replacement) != ptr)
		} else {
			assert(raw_data(replacement) == ptr)
		}
		fmt.println(ptr[0]) // Undetected after reuse without quarantine.
	case "overflow":
		fmt.println(ptr[37]) // One byte past the logical end, with b still live.
		byte_pool.release(pool, a)
	case "shrink":
		raw, raw_err := mem.alloc_bytes(129, 8, allocator)
		assert(raw_err == .None)
		small, shrink_err := mem.resize_bytes(raw, 19, 8, allocator)
		assert(shrink_err == .None)
		fmt.println(raw_data(small)[19])
	case "shrink-non-zeroed":
		raw, raw_err := mem.alloc_bytes_non_zeroed(129, 8, allocator)
		assert(raw_err == .None)
		small, shrink_err := mem.resize_bytes_non_zeroed(raw, 19, 8, allocator)
		assert(shrink_err == .None)
		fmt.println(raw_data(small)[19])
	case "free-all":
		_, reset_err := allocator.procedure(allocator.data, .Free_All, 0, 0, nil, 0)
		assert(reset_err == .None)
		fmt.println(ptr[0])
	case "double-free", "resize-freed", "resize-freed-non-zeroed":
		raw, raw_err := mem.alloc_bytes(129, 8, allocator)
		assert(raw_err == .None)
		assert(mem.free_bytes(raw, allocator) == .None)
		mode: mem.Allocator_Mode = .Free
		if os.args[1] == "resize-freed" do mode = .Resize
		if os.args[1] == "resize-freed-non-zeroed" do mode = .Resize_Non_Zeroed
		_, _ = allocator.procedure(allocator.data, mode, 19, 8, raw_data(raw), len(raw))
		panic("quarantined block unexpectedly accepted")
	case "corrupt-size", "corrupt-neighbor", "corrupt-list", "corrupt-class", "corrupt-bitmap", "corrupt-head", "corrupt-next", "corrupt-prev":
		corrupt_heap(&heap, os.args[1])
		// A query does not repair the damage, but its exit runs the checker.
		_, _ = allocator.procedure(allocator.data, .Query_Info, 0, 0, nil, 0)
		panic("corrupt heap unexpectedly accepted")
	case:
		panic("unknown probe")
	}
}

// Deliberately bypass ASan only for fault injection. The invariant checker must
// diagnose these corruptions, not merely trigger ASan on the injected write.
@(no_sanitize_address)
corrupt_heap :: proc(heap: ^tlsf.Allocator, kind: string) {
	first := (^tlsf.Block_Header)(uintptr(raw_data(heap.pool.data)) - uintptr(tlsf.BLOCK_HEADER_OVERHEAD))
	switch kind {
	case "corrupt-size":
		first.size = 4
	case "corrupt-neighbor":
		first.size |= tlsf.BLOCK_HEADER_PREV_FREE
	case "corrupt-bitmap":
		heap.fl_bitmap ~= 1
	case "corrupt-list", "corrupt-class", "corrupt-head", "corrupt-next", "corrupt-prev":
		for fl in 0 ..< tlsf.FL_INDEX_COUNT {
			for sl in 0 ..< tlsf.SL_INDEX_COUNT {
				block := heap.blocks[fl][sl]
				if block == &heap.block_null do continue
				if kind == "corrupt-list" {
					block.next_free = block
				} else if kind == "corrupt-head" {
					heap.blocks[fl][sl] = (^tlsf.Block_Header)(uintptr(8))
				} else if kind == "corrupt-next" {
					block.next_free = (^tlsf.Block_Header)(uintptr(8))
				} else if kind == "corrupt-prev" {
					block.prev_free = block
				} else {
					heap.blocks[fl][sl] = &heap.block_null
					heap.blocks[fl][(sl + 1) % tlsf.SL_INDEX_COUNT] = block
				}
				return
			}
		}
		panic("probe needs a free block")
	}
}
