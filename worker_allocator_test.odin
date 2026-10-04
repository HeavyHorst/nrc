package main

import "core:mem"
import "core:sys/linux"
import "core:testing"
import tlsf "vendor/tlsf"

import "byte_pool"
import pr "protocol"

worker_heap_contains_for_test :: proc(heap: ^tlsf.Allocator, p: rawptr) -> bool {
	for pool := &heap.pool; pool != nil; pool = pool.next {
		start := uintptr(raw_data(pool.data))
		if uintptr(p) >= start && uintptr(p) < start + uintptr(len(pool.data)) do return true
	}
	return false
}

@(test)
test_worker_heap_growth_resize_alignment_and_reuse :: proc(t: ^testing.T) {
	backing := context.allocator
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, 4096))
	defer tlsf.destroy(&heap)
	allocator := worker_heap_allocator(&heap)
	first, err := mem.alloc_bytes(3073, 64, allocator)
	assert(err == .None)
	// TLSF may return a rounded-up block; resize receives the caller's logical
	// slice length, not the allocator's capacity.
	first = first[:3073]
	for &b, i in first do b = byte(i % 251)
	second, err2 := mem.alloc_bytes(8193, 4096, allocator)
	assert(err2 == .None)
	defer mem.free_bytes(second, allocator)
	testing.expect(t, heap.pool.next != nil)
	testing.expect_value(t, uintptr(raw_data(second)) % 4096, uintptr(0))
	resized, err3 := mem.resize_bytes(first, 16385, 64, allocator)
	assert(err3 == .None)
	for b, i in resized do testing.expect_value(t, b, i < 3073 ? byte(i % 251) : byte(0))
	old_pointer := raw_data(resized)
	_ = mem.free_bytes(resized, allocator)
	reused, err4 := mem.alloc_bytes(16385, 64, allocator)
	assert(err4 == .None)
	defer mem.free_bytes(reused, allocator)
	testing.expect_value(t, raw_data(reused), old_pointer)
	for b in reused do testing.expect_value(t, b, byte(0))
	// Stdlib's fixed 64 MiB growth policy rejects this otherwise valid request.
	large, err5 := mem.alloc_bytes(WORKER_HEAP_POOL_BYTES + 4097, 4096, allocator)
	assert(err5 == .None)
	defer mem.free_bytes(large, allocator)
	testing.expect(t, worker_heap_contains_for_test(&heap, raw_data(large)))
	testing.expect_value(t, uintptr(raw_data(large)) % 4096, uintptr(0))
	large[len(large) - 1] = 71
	testing.expect_value(t, large[len(large) - 1], byte(71))
}

@(test)
test_worker_heap_keeps_specialized_pools_on_backing :: proc(t: ^testing.T) {
	backing := context.allocator
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, 64 * mem.Kilobyte))
	defer tlsf.destroy(&heap)
	old_td := new(Server_Thread, backing)
	old_td^ = td
	td = {}
	defer {td = old_td^; free(old_td, backing)}
	td.backing_allocator = backing
	context.allocator = worker_heap_allocator(&heap)
	worker_state_init_core(nil, 0, 8)
	defer worker_state_destroy_core_for_test()
	ws := get_or_create_workspace("worker-heap-ownership")
	conv := get_or_create_conversation(ws, pr.WORKSPACE_DATA_ID)
	task := alloc_task(transmute([]byte)string("task"), transmute([]byte)string("description"), nil, nil, nil, nil, nil, nil)
	task.id = 17
	task.status = .Todo
	task_store_put(conv, task)
	asset := alloc_asset(nil, nil, transmute([]byte)string("payload"))
	asset.asset_id = 23
	asset.asset_type = .Document
	asset_store_put(ws, "worker-heap-ownership", conv, asset)
	pointers := []rawptr{ws, conv, task, asset, raw_data(intern_username("worker-user"))}
	for p in pointers {
		testing.expect(t, worker_heap_contains_for_test(&heap, p))
	}
	testing.expect_value(t, conv.task_index.allocator, context.allocator)
	batch := alloc_batch_state(3)
	testing.expect(t, !worker_heap_contains_for_test(&heap, batch))
	free_batch_state(batch)
	testing.expect(t, !worker_heap_contains_for_test(&heap, td.spool))
	testing.expect_value(t, td.spool.backing_allocator, backing)
	td.spool.rotate_threshold = 1
	a, err_a := byte_pool.alloc(td.spool, 128)
	b, err_b := byte_pool.alloc(td.spool, 257)
	assert(err_a == .None && err_b == .None)
	testing.expect_value(t, len(td.spool.arenas), 2)
	for arena in td.spool.arenas do testing.expect(t, !worker_heap_contains_for_test(&heap, arena))
	testing.expect(t, !worker_heap_contains_for_test(&heap, raw_data(a)))
	testing.expect(t, !worker_heap_contains_for_test(&heap, raw_data(b)))
	byte_pool.release(td.spool, a)
	byte_pool.release(td.spool, b)
}

Worker_Heap_Rejecting_Backing :: struct {
	parent:    mem.Allocator,
	requests:  int,
	last_size: int,
}

worker_heap_reject_large_backing_for_test :: proc(
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
	state := cast(^Worker_Heap_Rejecting_Backing)data
	if (mode == .Alloc || mode == .Alloc_Non_Zeroed) && size > WORKER_HEAP_POOL_BYTES {
		state.requests += 1
		state.last_size = size
		return nil, .Out_Of_Memory
	}
	return state.parent.procedure(state.parent.data, mode, size, alignment, old_memory, old_size, location)
}

@(test)
test_worker_heap_rejects_unsupported_sizes_without_mutation :: proc(t: ^testing.T) {
	state := Worker_Heap_Rejecting_Backing {
		parent = context.allocator,
	}
	backing := mem.Allocator {
		procedure = worker_heap_reject_large_backing_for_test,
		data      = &state,
	}
	heap: tlsf.Allocator
	assert(worker_heap_init(&heap, &backing, 64 * mem.Kilobyte))
	defer tlsf.destroy(&heap)
	allocator := worker_heap_allocator(&heap)
	original, err := mem.alloc_bytes(113, 64, allocator)
	assert(err == .None)
	original = original[:113]
	defer mem.free_bytes(original, allocator)
	for &b, i in original do b = byte((3 * i + 7) % 251)
	modes := []mem.Allocator_Mode{.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed}
	requests := []struct {
		size, alignment: int,
		error:           mem.Allocator_Error,
	} {
		{4 * mem.Gigabyte, 64, .Out_Of_Memory},
		{4 * mem.Gigabyte - 1, 64, .Out_Of_Memory},
		{4 * mem.Gigabyte - 64 * mem.Megabyte, 64, .Out_Of_Memory},
		{4 * mem.Gigabyte - 64 * mem.Megabyte - 95, 64, .Out_Of_Memory},
		{max(int), 64, .Out_Of_Memory},
		{113, 1 << 62, .Out_Of_Memory},
		{-1, 64, .Invalid_Argument},
		{113, 3, .Invalid_Argument},
	}
	for mode in modes {
		for request in requests {
			old_memory: rawptr
			old_size := 0
			if mode == .Resize || mode == .Resize_Non_Zeroed {
				old_memory = raw_data(original)
				old_size = len(original)
			}
			result, rejected := allocator.procedure(allocator.data, mode, request.size, request.alignment, old_memory, old_size)
			testing.expect_value(t, rejected, request.error)
			testing.expect_value(t, len(result), 0)
			for b, i in original do testing.expect_value(t, b, byte((3 * i + 7) % 251))
		}
	}
	testing.expect_value(t, state.requests, 0)
	// A supported block must not double into an unsupported backing pool.
	// Refuse the backing request so this test never allocates multiple GiB.
	result, rejected := mem.resize_bytes(original, 2 * mem.Gigabyte, 64, allocator)
	testing.expect_value(t, rejected, mem.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, len(result), 0)
	testing.expect_value(t, state.requests, 1)
	testing.expect_value(t, state.last_size, 4 * mem.Gigabyte)
	for b, i in original do testing.expect_value(t, b, byte((3 * i + 7) % 251))
	// The aligned bound lands exactly on the final searchable size class;
	// one byte larger above must be rejected without asking for another pool.
	near_limit, near_error := mem.alloc_bytes(4 * mem.Gigabyte - 64 * mem.Megabyte - 96, 64, allocator)
	testing.expect_value(t, near_error, mem.Allocator_Error.Out_Of_Memory)
	testing.expect_value(t, len(near_limit), 0)
	testing.expect_value(t, state.requests, 2)
	testing.expect_value(t, state.last_size, 4 * mem.Gigabyte)
}

worker_heap_mapped_backing_for_test :: proc(
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
	return (cast(^[]byte)data)^, .None
}

@(test)
test_worker_heap_prefaults_all_fresh_pages_without_touching_guards :: proc(t: ^testing.T) {
	page := mem.PAGE_SIZE
	mapping, err := linux.mmap(0, uint(5 * page), {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(err == .NONE)
	defer linux.munmap(mapping, uint(5 * page))
	// Guard residency must not depend on the machine's global THP policy.
	_ = linux.madvise(mapping, uint(5 * page), .NOHUGEPAGE)
	bytes := ([^]byte)(mapping)[:5 * page]
	// No read before allocation: the unaligned result crosses three absent
	// anonymous pages, with an untouched guard page on each side.
	span := bytes[2 * page - 17:3 * page + 17]
	parent := mem.Allocator {
		procedure = worker_heap_mapped_backing_for_test,
		data      = &span,
	}
	resident: [5]b8
	assert(linux.mincore(mapping, uint(len(bytes)), resident[:]) == .NONE)
	for r in resident do testing.expect_value(t, r, b8(false))
	result, alloc_err := worker_heap_backing_allocator_proc(&parent, .Alloc, len(span), 1, nil, 0)
	testing.expect_value(t, alloc_err, mem.Allocator_Error.None)
	testing.expect_value(t, raw_data(result), raw_data(span))
	assert(linux.mincore(mapping, uint(len(bytes)), resident[:]) == .NONE)
	for r, i in resident do testing.expect_value(t, r, b8(i >= 1 && i <= 3))
	for b in result do testing.expect_value(t, b, byte(0))
	// Forwarded modes must not zero existing contents at page boundaries.
	for &b, i in result do b = byte((i * 7 + 3) % 251)
	modes := []mem.Allocator_Mode{.Resize, .Resize_Non_Zeroed, .Alloc_Non_Zeroed, .Free}
	for mode in modes {
		_, forward_err := worker_heap_backing_allocator_proc(&parent, mode, len(span), 1, raw_data(span), len(span))
		testing.expect_value(t, forward_err, mem.Allocator_Error.None)
		for b, i in span do testing.expect_value(t, b, byte((i * 7 + 3) % 251))
	}
}
