package main

import "base:intrinsics"
import "core:mem"
import tlsf "vendor/tlsf"

WORKER_HEAP_POOL_BYTES :: 64 * mem.Megabyte

// The control stays at a stable address on the worker's stack until all worker
// callbacks and scratch cleanup have finished. Pools retain freed blocks for
// reuse and are released together at worker exit. The backing allocator value
// must also stay at a stable address until destruction, including pool growth.
worker_heap_init :: proc(control: ^tlsf.Allocator, backing: ^mem.Allocator, initial_bytes := WORKER_HEAP_POOL_BYTES) -> bool {
	prefaulting := mem.Allocator {
		procedure = worker_heap_backing_allocator_proc,
		data      = backing,
	}
	return tlsf.init(control, prefaulting, initial_bytes, WORKER_HEAP_POOL_BYTES) == .None
}

worker_heap_backing_allocator_proc :: proc(
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
	backing := cast(^mem.Allocator)data
	result, err := backing.procedure(backing.data, mode, size, alignment, old_memory, old_size, location)
	if err == .None && mode == .Alloc && len(result) > 0 {
		// Fresh .Alloc memory is zeroed. Write before TLSF reads its block flags
		// to avoid first reading a shared zero page and subsequently faulting COW.
		// Never touch existing resize data or TLSF's initialized pool headers.
		for i := 0; i < len(result); i += mem.PAGE_SIZE {
			intrinsics.volatile_store(&result[i], byte(0))
		}
		// An unaligned allocation may span one more page than the stride visits.
		intrinsics.volatile_store(&result[len(result) - 1], byte(0))
	}
	return result, err
}

worker_heap_allocator :: proc(control: ^tlsf.Allocator) -> mem.Allocator {
	return {procedure = worker_heap_allocator_proc, data = control}
}

worker_heap_allocator_proc :: proc(
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
	control := cast(^tlsf.Allocator)data
	if mode == .Alloc || mode == .Alloc_Non_Zeroed || mode == .Resize || mode == .Resize_Non_Zeroed {
		if size < 0 || alignment <= 0 || (alignment & (alignment - 1)) != 0 do return nil, .Invalid_Argument
		if size > 0 {
			// The pinned TLSF resize path does not reject an adjusted size of
			// zero at its block ceiling. Reject before it can trim/zero old memory.
			align := uint(max(alignment, tlsf.ALIGN_SIZE))
			limit := tlsf.BLOCK_SIZE_MAX
			if align >= limit || uint(size) >= limit - align - uint(size_of(tlsf.Block_Header)) do return nil, .Out_Of_Memory
			adjusted := (uint(size) + tlsf.ALIGN_SIZE - 1) & ~(uint(tlsf.ALIGN_SIZE) - 1)
			aligned_bound := (adjusted + align + uint(size_of(tlsf.Block_Header)) + align - 1) & ~(align - 1)
			// Search rounds up to a size-class boundary. Requests above the
			// final searchable class would grow a pool that can never serve them.
			search_limit := limit - (limit >> (tlsf.TLSF_SL_INDEX_COUNT_LOG2 + 1))
			if aligned_bound > search_limit do return nil, .Out_Of_Memory
			// Use unsigned bounded arithmetic: doubling a valid request must not
			// overflow or ask the backing allocator for an unsupported TLSF pool.
			// Stdlib TLSF refuses requests larger than its growth chunk.
			control.new_pool_size = max(uint(WORKER_HEAP_POOL_BYTES), min(2 * aligned_bound + uint(tlsf.INITIAL_POOL_OVERHEAD), limit))
		}
	}
	return tlsf.allocator_proc(data, mode, size, alignment, old_memory, old_size, location)
}

// Specialized pools and cross-thread transfers must never capture the worker's
// unsynchronized TLSF. Standalone fixtures without a worker use their context.
worker_backing_allocator :: proc() -> mem.Allocator {
	if td.backing_allocator.procedure != nil do return td.backing_allocator
	return context.allocator
}
