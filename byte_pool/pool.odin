package byte_pool

import "base:runtime"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:slice"

DEFAULT_POOL_USAGE_BUDGET_BYTES :: u64(64 * mem.Megabyte)
ALLOC_HEADER_MAGIC :: u32(0x4E524341) // "NRCA"

// Address identity checks worker confinement without a gettid syscall per frame.
@(thread_local)
thread_owner: u8

Alloc_Header :: struct #align (align_of(uintptr)) {
	magic:         u32,
	owner:         ^BufferPool,
	allocation:    rawptr,
	alignment:     uint,
	reserved_size: uint,
	payload_size:  uint,
}

#assert(align_of(Alloc_Header) == align_of(uintptr))
#assert(size_of(Alloc_Header) % align_of(uintptr) == 0)

// A buffer ownership/accounting domain, not a separate heap. The captured
// allocator must outlive every lease and remain confined to this worker.
BufferPool :: struct {
	backing_allocator:     runtime.Allocator,
	owner_thread:          rawptr,
	live_allocs:           uint,
	used:                  u64,
	usage_budget:          u64,
	allocation_count:      u64,
	release_count:         u64,
	invalid_release_count: u64,
}

init_buffer_pool :: proc(allocator := context.allocator) -> ^BufferPool {
	pool, err := new(BufferPool, allocator)
	if err != .None do return nil
	pool.backing_allocator = allocator
	pool.owner_thread = &thread_owner
	pool.usage_budget = DEFAULT_POOL_USAGE_BUDGET_BYTES
	return pool
}

destroy_buffer_pool :: proc(pool: ^BufferPool) {
	if pool == nil do return
	assert(pool.owner_thread == &thread_owner, "buffer allocator used outside its worker")
	assert(pool.live_allocs == 0 && pool.used == 0, "buffer allocator destroyed with live leases")
	free(pool, pool.backing_allocator)
}

next_power_of_two :: proc(n: uint) -> uint {
	if n == 0 do return 1
	return 1 << uint(bits.len(n - 1))
}

sanitize_alignment :: proc(alignment: uint) -> uint {
	a := max(alignment, uint(align_of(Alloc_Header)))
	if (a & (a - 1)) != 0 do a = next_power_of_two(a)
	return a
}

// Only live allocation pointers are valid here. Storage is immediately reusable
// after release: never attempt to diagnose duplicate frees by reading it again.
header_from_payload_ptr :: proc(ptr: rawptr) -> (^Alloc_Header, runtime.Allocator_Error) {
	if ptr == nil do return nil, .Invalid_Pointer
	header := (^Alloc_Header)(rawptr(uintptr(ptr) - size_of(Alloc_Header)))
	if header.magic != ALLOC_HEADER_MAGIC do return nil, .Invalid_Pointer
	return header, .None
}

alloc_internal :: proc(pool: ^BufferPool, size, alignment: uint, zeroed: bool) -> ([]u8, runtime.Allocator_Error) {
	if pool == nil do return nil, .Invalid_Argument
	assert(pool.owner_thread == &thread_owner, "buffer allocator used outside its worker")
	if size == 0 do return nil, .None
	if alignment > uint(max(int)) do return nil, .Out_Of_Memory
	a := sanitize_alignment(alignment)
	if a > uint(max(int)) do return nil, .Out_Of_Memory
	overhead := mem.align_forward_uint(size_of(Alloc_Header), a)
	if overhead > uint(max(int)) || size > uint(max(int)) - overhead do return nil, .Out_Of_Memory
	alloc_fn := mem.alloc_bytes_non_zeroed
	if zeroed do alloc_fn = mem.alloc_bytes
	raw, err := alloc_fn(int(size + overhead), int(a), pool.backing_allocator)
	if err != .None do return nil, err
	payload := raw_data(raw)[overhead:]
	header := (^Alloc_Header)(rawptr(uintptr(payload) - size_of(Alloc_Header)))
	header^ = {
		magic         = ALLOC_HEADER_MAGIC,
		owner         = pool,
		allocation    = raw_data(raw),
		alignment     = a,
		reserved_size = uint(len(raw)),
		payload_size  = size,
	}
	pool.used += u64(len(raw))
	pool.live_allocs += 1
	pool.allocation_count += 1
	// TLSF may return a larger block; expose only the requested logical length.
	return slice.bytes_from_ptr(payload, int(size)), .None
}

release_ptr :: proc(pool: ^BufferPool, ptr: rawptr) -> runtime.Allocator_Error {
	if pool == nil || ptr == nil do return .None
	assert(pool.owner_thread == &thread_owner, "buffer allocator used outside its worker")
	header, err := header_from_payload_ptr(ptr)
	if err != .None {
		pool.invalid_release_count += 1
		return err
	}
	if header.owner != pool {
		pool.invalid_release_count += 1
		return .Invalid_Pointer
	}
	assert(pool.live_allocs > 0 && pool.used >= u64(header.reserved_size), "buffer accounting underflow")
	reserved := header.reserved_size
	allocation := slice.bytes_from_ptr(header.allocation, int(reserved))
	// Do not read the header after free; the shared heap may reuse it at once.
	err = mem.free_bytes(allocation, pool.backing_allocator)
	if err != .None do return err
	pool.live_allocs -= 1
	pool.release_count += 1
	pool.used -= u64(reserved)
	return .None
}

alloc :: proc(pool: ^BufferPool, size: uint) -> ([]u8, runtime.Allocator_Error) {
	return alloc_internal(pool, size, align_of(uintptr), true)
}

release :: proc(pool: ^BufferPool, data: []u8) {
	if data == nil do return
	if err := release_ptr(pool, raw_data(data)); err != .None do log.errorf("Failed to release buffer: %v", err)
}

buffer_pool_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]byte,
	runtime.Allocator_Error,
) {
	pool := (^BufferPool)(allocator_data)
	if pool == nil do return nil, .Invalid_Argument
	assert(pool.owner_thread == &thread_owner, "buffer allocator used outside its worker")
	if size < 0 || old_size < 0 do return nil, .Invalid_Argument
	requested_alignment := uint(max(alignment, 0))
	switch mode {
	case .Alloc:
		return alloc_internal(pool, uint(size), requested_alignment, true)
	case .Alloc_Non_Zeroed:
		return alloc_internal(pool, uint(size), requested_alignment, false)
	case .Free:
		return nil, release_ptr(pool, old_memory)
	case .Free_All:
		// Never reset the shared worker heap and invalidate its records.
		return nil, .Mode_Not_Implemented
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil do return alloc_internal(pool, uint(size), requested_alignment, mode == .Resize)
		header, err := header_from_payload_ptr(old_memory)
		if err != .None do return nil, err
		if header.owner != pool do return nil, .Invalid_Pointer
		if size == 0 do return nil, release_ptr(pool, old_memory)
		if requested_alignment > uint(max(int)) do return nil, .Out_Of_Memory
		a := sanitize_alignment(requested_alignment)
		if a > uint(max(int)) do return nil, .Out_Of_Memory
		if uint(size) == header.payload_size && uintptr(old_memory) % uintptr(a) == 0 do return slice.bytes_from_ptr(old_memory, size), .None
		new_mem, alloc_err := alloc_internal(pool, uint(size), requested_alignment, mode == .Resize)
		if alloc_err != .None do return nil, alloc_err
		copy_count := int(min(header.payload_size, uint(size)))
		copy(new_mem[:copy_count], slice.bytes_from_ptr(old_memory, copy_count))
		free_err := release_ptr(pool, old_memory)
		if free_err != .None {
			_ = release_ptr(pool, raw_data(new_mem))
			return nil, free_err
		}
		return new_mem, .None
	case .Query_Features:
		if set := (^runtime.Allocator_Mode_Set)(old_memory); set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features, .Query_Info}
		}
		return nil, .None
	case .Query_Info:
		if info := (^runtime.Allocator_Query_Info)(old_memory); info != nil && info.pointer != nil {
			header, err := header_from_payload_ptr(info.pointer)
			if err != .None do return nil, err
			if header.owner != pool do return nil, .Invalid_Pointer
			info.size = int(header.payload_size)
			info.alignment = int(header.alignment)
			return slice.bytes_from_ptr(rawptr(info), size_of(info^)), .None
		}
		return nil, .None
	}
	return nil, .Mode_Not_Implemented
}

allocator :: proc(pool: ^BufferPool) -> runtime.Allocator {
	return {procedure = buffer_pool_allocator_proc, data = pool}
}
