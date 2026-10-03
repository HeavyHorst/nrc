package main

import "base:intrinsics"
import "core:mem"
import tlsf "core:mem/tlsf"

WORKER_HEAP_POOL_BYTES :: 64 * mem.Megabyte

// The control stays at a stable address on the worker's stack until all worker
// callbacks and scratch cleanup have finished. Pools retain freed blocks for
// reuse and are released together at worker exit.
worker_heap_init :: proc(control: ^tlsf.Allocator, backing: mem.Allocator, initial_bytes := WORKER_HEAP_POOL_BYTES) -> bool {
	if tlsf.init(control, backing, initial_bytes, WORKER_HEAP_POOL_BYTES) != .None do return false
	// Touch without changing TLSF's already initialized block headers.
	for i := 0; i < len(control.pool.data); i += 4096 {
		intrinsics.volatile_store(&control.pool.data[i], control.pool.data[i])
	}
	return true
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
