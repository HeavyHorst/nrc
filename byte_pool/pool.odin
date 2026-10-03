package byte_pool

import "base:runtime"
import "core:log"
import "core:math/bits"
import "core:mem"
import "core:mem/virtual"
import "core:slice"

DEFAULT_POOL_USAGE_BUDGET_BYTES :: u64(64 * mem.Megabyte)
DEFAULT_ARENA_ROTATE_THRESHOLD :: uint(8 * mem.Megabyte)
DEFAULT_ARENA_RESERVE_BYTES :: uint(8 * mem.Megabyte)
MAX_POOL_ARENAS :: 8
ALLOC_HEADER_MAGIC :: u32(0x4E524341) // "NRCA"
ALLOC_HEADER_FREED_MAGIC :: u32(0x4E524346) // "NRCF"

Pool_Arena :: struct {
	arena:                 virtual.Arena,
	alloc:                 runtime.Allocator,
	live_allocs:           uint,
	allocated_since_reset: u64,
}

Alloc_Header :: struct #align (align_of(uintptr)) {
	magic:         u32,
	arena_index:   u32,
	alignment:     uint,
	reserved_size: uint,
	payload_size:  uint,
}

#assert(align_of(Alloc_Header) == align_of(uintptr))
#assert(size_of(Alloc_Header) % align_of(uintptr) == 0)

BufferPool :: struct {
	backing_allocator:     runtime.Allocator,
	arenas:                [dynamic]^Pool_Arena,
	active_index:          int,
	used:                  u64,
	usage_budget:          u64,
	rotate_threshold:      uint,
	max_arenas:            int,
	rotation_cap_warned:   bool,
	rotation_count:        u64,
	rotation_capped_count: u64,
	reused_arena_count:    u64,
	allocation_count:      u64,
	release_count:         u64,
	invalid_release_count: u64,
}

init_buffer_pool :: proc(allocator := context.allocator) -> ^BufferPool {
	context.allocator = allocator
	pool := new(BufferPool)
	pool.backing_allocator = allocator
	pool.active_index = -1
	pool.usage_budget = DEFAULT_POOL_USAGE_BUDGET_BYTES
	pool.rotate_threshold = DEFAULT_ARENA_ROTATE_THRESHOLD
	pool.max_arenas = MAX_POOL_ARENAS
	pool.arenas = make([dynamic]^Pool_Arena, 0, 2)

	if !buffer_pool_add_arena(pool) {
		delete(pool.arenas)
		free(pool)
		return nil
	}

	pool.active_index = 0
	return pool
}

destroy_buffer_pool :: proc(pool: ^BufferPool) {
	if pool == nil {
		return
	}
	context.allocator = pool.backing_allocator

	for arena in pool.arenas {
		if arena == nil do continue
		virtual.arena_destroy(&arena.arena)
		free(arena)
	}
	delete(pool.arenas)
	free(pool)
}

buffer_pool_add_arena :: proc(pool: ^BufferPool) -> bool {
	if pool == nil {
		return false
	}
	context.allocator = pool.backing_allocator

	arena := new(Pool_Arena)
	err := virtual.arena_init_growing(&arena.arena, reserved = DEFAULT_ARENA_RESERVE_BYTES)
	if err != .None {
		log.errorf("Failed to initialize virtual arena for byte pool: %v", err)
		free(arena)
		return false
	}

	arena.alloc = virtual.arena_allocator(&arena.arena)
	append(&pool.arenas, arena)
	return true
}

next_power_of_two :: proc(n: uint) -> uint {
	if n == 0 {
		return 1
	}
	return 1 << uint(bits.len(n - 1))
}

sanitize_alignment :: proc(alignment: uint) -> uint {
	a := alignment
	if a == 0 {
		a = align_of(uintptr)
	}
	if a < align_of(Alloc_Header) {
		a = align_of(Alloc_Header)
	}
	if (a & (a - 1)) != 0 {
		a = next_power_of_two(a)
	}
	return a
}

active_arena :: proc(pool: ^BufferPool) -> ^Pool_Arena {
	if pool == nil {
		return nil
	}
	if pool.active_index < 0 || pool.active_index >= len(pool.arenas) {
		return nil
	}
	return pool.arenas[pool.active_index]
}

reset_arena_if_idle :: proc(arena: ^Pool_Arena) {
	if arena == nil || arena.live_allocs != 0 {
		return
	}
	if arena.allocated_since_reset == 0 {
		return
	}

	virtual.arena_free_all(&arena.arena)
	arena.allocated_since_reset = 0
}

activate_fresh_arena :: proc(pool: ^BufferPool) -> bool {
	if pool == nil {
		return false
	}

	for i := 0; i < len(pool.arenas); i += 1 {
		arena := pool.arenas[i]
		if i == pool.active_index || arena == nil {
			continue
		}
		if arena.live_allocs == 0 {
			virtual.arena_free_all(&arena.arena)
			arena.allocated_since_reset = 0
			pool.active_index = i
			pool.reused_arena_count += 1
			pool.rotation_count += 1
			pool.rotation_cap_warned = false
			return true
		}
	}

	if len(pool.arenas) >= pool.max_arenas {
		pool.rotation_capped_count += 1
		if !pool.rotation_cap_warned {
			log.warnf("Byte pool reached max arena count (%d); reusing active arena until old generations drain", pool.max_arenas)
			pool.rotation_cap_warned = true
		}
		return false
	}

	if !buffer_pool_add_arena(pool) {
		return false
	}

	pool.active_index = len(pool.arenas) - 1
	pool.rotation_count += 1
	pool.rotation_cap_warned = false
	return true
}

rotate_if_needed :: proc(pool: ^BufferPool) {
	if pool == nil || pool.rotate_threshold == 0 {
		return
	}

	arena := active_arena(pool)
	if arena == nil {
		return
	}

	if arena.allocated_since_reset < u64(pool.rotate_threshold) {
		return
	}

	if arena.live_allocs == 0 {
		virtual.arena_free_all(&arena.arena)
		arena.allocated_since_reset = 0
		return
	}

	_ = activate_fresh_arena(pool)
}

header_from_payload_ptr :: proc(ptr: rawptr) -> (^Alloc_Header, runtime.Allocator_Error) {
	if ptr == nil {
		return nil, .Invalid_Pointer
	}

	header_ptr := uintptr(ptr) - size_of(Alloc_Header)
	header := (^Alloc_Header)(rawptr(header_ptr))
	if header.magic == ALLOC_HEADER_FREED_MAGIC {
		return nil, .Invalid_Pointer
	}
	if header.magic != ALLOC_HEADER_MAGIC {
		return nil, .Invalid_Pointer
	}

	return header, .None
}

alloc_from_arena :: proc(arena: ^Pool_Arena, total_size, alignment: uint, zeroed: bool) -> ([]u8, runtime.Allocator_Error, uint) {
	if arena == nil {
		return nil, .Out_Of_Memory, 0
	}

	alloc_fn := mem.alloc_bytes_non_zeroed
	if zeroed {
		alloc_fn = mem.alloc_bytes
	}

	before_used := arena.arena.total_used
	raw, err := alloc_fn(int(total_size), int(alignment), arena.alloc)
	if err != .None {
		return nil, err, 0
	}

	after_used := arena.arena.total_used
	consumed := total_size
	if after_used >= before_used {
		consumed = after_used - before_used
	}
	if consumed < total_size {
		consumed = total_size
	}

	return raw, .None, consumed
}

alloc_internal :: proc(pool: ^BufferPool, size, alignment: uint, zeroed: bool) -> ([]u8, runtime.Allocator_Error) {
	if pool == nil {
		return nil, .Invalid_Argument
	}
	if size == 0 {
		return nil, .None
	}

	a := sanitize_alignment(alignment)
	header_and_padding := mem.align_forward_uint(size_of(Alloc_Header), a)
	overhead := header_and_padding
	if size > max(uint) - overhead {
		return nil, .Out_Of_Memory
	}
	total_size := size + overhead

	rotate_if_needed(pool)
	arena := active_arena(pool)
	if arena == nil {
		return nil, .Out_Of_Memory
	}

	raw, err, consumed := alloc_from_arena(arena, total_size, a, zeroed)
	if err != .None {
		if !activate_fresh_arena(pool) {
			return nil, err
		}

		arena = active_arena(pool)
		if arena == nil {
			return nil, .Out_Of_Memory
		}

		raw, err, consumed = alloc_from_arena(arena, total_size, a, zeroed)
		if err != .None {
			return nil, err
		}
	}

	base_addr := uint(uintptr(raw_data(raw)))
	payload_addr := mem.align_forward_uint(base_addr + size_of(Alloc_Header), a)
	header_addr := payload_addr - size_of(Alloc_Header)

	header := (^Alloc_Header)(rawptr(uintptr(header_addr)))
	header.magic = ALLOC_HEADER_MAGIC
	header.arena_index = u32(pool.active_index)
	header.alignment = a
	header.reserved_size = consumed
	header.payload_size = size

	pool.used += u64(header.reserved_size)
	pool.allocation_count += 1
	arena.live_allocs += 1
	arena.allocated_since_reset += u64(header.reserved_size)

	return slice.bytes_from_ptr(rawptr(uintptr(payload_addr)), int(size)), .None
}

release_ptr :: proc(pool: ^BufferPool, ptr: rawptr) -> runtime.Allocator_Error {
	if pool == nil || ptr == nil {
		return .None
	}

	header, err := header_from_payload_ptr(ptr)
	if err != .None {
		pool.invalid_release_count += 1
		log.error("Failed to release to byte pool: invalid pointer")
		return err
	}

	arena_index := int(header.arena_index)
	if arena_index < 0 || arena_index >= len(pool.arenas) {
		pool.invalid_release_count += 1
		log.errorf("Failed to release to byte pool: invalid arena index %d", arena_index)
		return .Invalid_Pointer
	}

	arena := pool.arenas[arena_index]
	if arena == nil {
		pool.invalid_release_count += 1
		log.errorf("Failed to release to byte pool: nil arena at index %d", arena_index)
		return .Invalid_Pointer
	}

	if arena.live_allocs == 0 {
		pool.invalid_release_count += 1
		log.errorf("Byte pool release underflow on arena %d", arena_index)
		return .Invalid_Pointer
	}
	if pool.used < u64(header.reserved_size) {
		pool.invalid_release_count += 1
		log.errorf("Byte pool usage underflow: used=%d release=%d", pool.used, header.reserved_size)
		return .Invalid_Pointer
	}

	arena.live_allocs -= 1
	pool.release_count += 1
	pool.used -= u64(header.reserved_size)
	header.magic = ALLOC_HEADER_FREED_MAGIC
	header.arena_index = max(u32)
	header.alignment = 0
	header.reserved_size = 0
	header.payload_size = 0

	reset_arena_if_idle(arena)
	return .None
}

alloc :: proc(pool: ^BufferPool, size: uint) -> ([]u8, runtime.Allocator_Error) {
	return alloc_internal(pool, size, align_of(uintptr), true)
}

release :: proc(pool: ^BufferPool, data: []u8) {
	if data == nil {
		return
	}

	if err := release_ptr(pool, slice.as_ptr(data)); err != .None {
		log.error("Failed to release to byte pool")
	}
}

reset :: proc(pool: ^BufferPool) {
	if pool == nil {
		return
	}

	for arena in pool.arenas {
		if arena == nil do continue
		virtual.arena_free_all(&arena.arena)
		arena.live_allocs = 0
		arena.allocated_since_reset = 0
	}

	pool.active_index = 0
	pool.used = 0
	pool.rotation_cap_warned = false
}

pool_current_arena_count :: proc(pool: ^BufferPool) -> int {
	if pool == nil {
		return 0
	}
	return len(pool.arenas)
}

pool_total_reserved :: proc(pool: ^BufferPool) -> u64 {
	if pool == nil {
		return 0
	}

	total := u64(0)
	for arena in pool.arenas {
		if arena == nil {
			continue
		}
		total += u64(arena.arena.total_reserved)
	}

	return total
}

pool_total_committed :: proc(pool: ^BufferPool) -> u64 {
	if pool == nil {
		return 0
	}

	total := u64(0)
	for arena in pool.arenas {
		if arena == nil {
			continue
		}

		block := arena.arena.curr_block
		for block != nil {
			total += u64(block.committed)
			block = block.prev
		}
	}

	return total
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
	if pool == nil {
		return nil, .Invalid_Argument
	}

	if size < 0 || old_size < 0 {
		return nil, .Invalid_Argument
	}

	requested_alignment := uint(alignment)
	if alignment <= 0 {
		requested_alignment = align_of(uintptr)
	}

	switch mode {
	case .Alloc:
		return alloc_internal(pool, uint(size), requested_alignment, true)
	case .Alloc_Non_Zeroed:
		return alloc_internal(pool, uint(size), requested_alignment, false)
	case .Free:
		return nil, release_ptr(pool, old_memory)
	case .Free_All:
		reset(pool)
		return nil, .None
	case .Resize, .Resize_Non_Zeroed:
		if old_memory == nil {
			zeroed := mode == .Resize
			return alloc_internal(pool, uint(size), requested_alignment, zeroed)
		}

		if size == 0 {
			return nil, release_ptr(pool, old_memory)
		}

		header, err := header_from_payload_ptr(old_memory)
		if err != .None {
			return nil, err
		}

		if uint(size) == header.payload_size {
			return slice.bytes_from_ptr(old_memory, size), .None
		}

		zeroed := mode == .Resize
		new_mem, alloc_err := alloc_internal(pool, uint(size), requested_alignment, zeroed)
		if alloc_err != .None {
			return nil, alloc_err
		}

		copy_count := int(min(header.payload_size, uint(size)))
		old_bytes := slice.bytes_from_ptr(old_memory, copy_count)
		copy(new_mem[:copy_count], old_bytes)

		free_err := release_ptr(pool, old_memory)
		if free_err != .None {
			return nil, free_err
		}

		return new_mem, .None
	case .Query_Features:
		set := (^runtime.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Free_All, .Query_Features, .Query_Info}
		}
		return nil, .None
	case .Query_Info:
		info := (^runtime.Allocator_Query_Info)(old_memory)
		if info != nil && info.pointer != nil {
			header, err := header_from_payload_ptr(info.pointer)
			if err != .None {
				return nil, err
			}
			info.size = int(header.payload_size)
			info.alignment = int(header.alignment)
			return slice.bytes_from_ptr(rawptr(info), size_of(info^)), .None
		}
		return nil, .None
	}

	return nil, .Mode_Not_Implemented
}

// Returns an allocator interface for use with new(), make(), etc.
allocator :: proc(pool: ^BufferPool) -> runtime.Allocator {
	return runtime.Allocator{procedure = buffer_pool_allocator_proc, data = pool}
}
