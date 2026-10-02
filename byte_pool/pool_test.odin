package byte_pool

// Tests the pooled byte-buffer allocator used by handlers and fanout paths. The
// conventional and Hegel cases pin size-class selection, reserve/commit behavior,
// reuse, and cleanup invariants so pooled buffers can be shared without leaks or
// accidental aliasing surprises.

import "base:runtime"

import "core:log"
import "core:mem"
import "core:slice"
import "core:testing"

import hgl "../hegel"

Hegel_Model_Alloc :: struct {
	buf:         []u8,
	reserved:    u64,
	arena_index: int,
}

@(test)
test_next_power_of_two :: proc(t: ^testing.T) {
	cases := []struct {
		input:    uint,
		expected: uint,
	} {
		{0, 1},
		{1, 1},
		{2, 2},
		{3, 4},
		{4, 4},
		{5, 8},
		{7, 8},
		{8, 8},
		{9, 16},
		{15, 16},
		{16, 16},
		{17, 32},
		{100, 128},
		{1000, 1024},
		{1024, 1024},
		{1025, 2048},
	}

	for c in cases {
		result := next_power_of_two(c.input)
		testing.expectf(t, result == c.expected, "next_power_of_two(%d) = %d, expected %d", c.input, result, c.expected)
	}
}

@(test)
test_alloc_release_updates_counters :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	buf, err := alloc(pool, 1024)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect(t, buf != nil, "expected allocation to succeed")
	testing.expect_value(t, pool.arenas[pool.active_index].live_allocs, uint(1))
	testing.expect(t, pool.used > 0, "expected used bytes to increase")

	release(pool, buf)
	testing.expect_value(t, pool.used, u64(0))
	testing.expect_value(t, pool.arenas[pool.active_index].live_allocs, uint(0))
	testing.expect_value(t, pool.arenas[pool.active_index].allocated_since_reset, u64(0))
}

@(test)
test_alloc_internal_tracks_actual_arena_usage :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	pool.rotate_threshold = 0
	arena := pool.arenas[pool.active_index]
	before_total := arena.arena.total_used

	buf_a, err_a := alloc_internal(pool, 31, 64, false)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)
	testing.expect(t, uintptr(slice.as_ptr(buf_a)) % uintptr(64) == 0, "expected 64-byte alignment")
	header_a, header_err_a := header_from_payload_ptr(slice.as_ptr(buf_a))
	testing.expect_value(t, header_err_a, runtime.Allocator_Error.None)

	buf_b, err_b := alloc_internal(pool, 17, 128, false)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)
	testing.expect(t, uintptr(slice.as_ptr(buf_b)) % uintptr(128) == 0, "expected 128-byte alignment")
	header_b, header_err_b := header_from_payload_ptr(slice.as_ptr(buf_b))
	testing.expect_value(t, header_err_b, runtime.Allocator_Error.None)

	after_total := arena.arena.total_used
	actual_delta := after_total - before_total
	tracked_delta := u64(header_a.reserved_size) + u64(header_b.reserved_size)

	testing.expect_value(t, tracked_delta, u64(actual_delta))
	testing.expect_value(t, pool.used, tracked_delta)
	testing.expect_value(t, arena.allocated_since_reset, tracked_delta)

	release(pool, buf_a)
	release(pool, buf_b)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_release_ptr_rejects_double_free :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	buf, err := alloc(pool, 128)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect(t, buf != nil, "expected allocation to succeed")
	guard_buf, guard_err := alloc(pool, 64)
	testing.expect_value(t, guard_err, runtime.Allocator_Error.None)
	testing.expect(t, guard_buf != nil, "expected guard allocation to succeed")
	guard_header, guard_header_err := header_from_payload_ptr(slice.as_ptr(guard_buf))
	testing.expect_value(t, guard_header_err, runtime.Allocator_Error.None)

	header, header_err := header_from_payload_ptr(slice.as_ptr(buf))
	testing.expect_value(t, header_err, runtime.Allocator_Error.None)
	arena_index := int(header.arena_index)

	err_first := release_ptr(pool, slice.as_ptr(buf))
	testing.expect_value(t, err_first, runtime.Allocator_Error.None)
	testing.expect(t, pool.used > 0, "expected pool usage to stay non-zero while guard allocation is live")
	expected_live_after_first := uint(0)
	if int(guard_header.arena_index) == arena_index {
		expected_live_after_first = 1
	}
	testing.expect_value(t, pool.arenas[arena_index].live_allocs, expected_live_after_first)
	testing.expect_value(t, pool.release_count, u64(1))
	testing.expect_value(t, pool.invalid_release_count, u64(0))

	_, header_after_err := header_from_payload_ptr(slice.as_ptr(buf))
	testing.expect_value(t, header_after_err, runtime.Allocator_Error.Invalid_Pointer)
	previous_logger := context.logger
	context.logger = log.nil_logger()
	double_release_err := release_ptr(pool, slice.as_ptr(buf))
	context.logger = previous_logger
	testing.expect_value(t, double_release_err, runtime.Allocator_Error.Invalid_Pointer)
	freed_header := (^Alloc_Header)(rawptr(uintptr(slice.as_ptr(buf)) - size_of(Alloc_Header)))
	testing.expect_value(t, freed_header.magic, ALLOC_HEADER_FREED_MAGIC)
	testing.expect_value(t, freed_header.arena_index, max(u32))
	testing.expect_value(t, freed_header.alignment, uint(0))
	testing.expect_value(t, freed_header.reserved_size, uint(0))
	testing.expect_value(t, freed_header.payload_size, uint(0))
	testing.expect(t, pool.used > 0, "expected guard allocation to keep usage above zero")
	testing.expect_value(t, pool.arenas[arena_index].live_allocs, expected_live_after_first)
	testing.expect_value(t, pool.release_count, u64(1))
	testing.expect_value(t, pool.invalid_release_count, u64(1))

	release(pool, guard_buf)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_arena_rotation_and_old_generation_reset :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	pool.rotate_threshold = 256

	buf_a, err_a := alloc(pool, 320)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)

	header_a, header_err_a := header_from_payload_ptr(slice.as_ptr(buf_a))
	testing.expect_value(t, header_err_a, runtime.Allocator_Error.None)
	owner_a := int(header_a.arena_index)

	buf_b, err_b := alloc(pool, 64)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)

	header_b, header_err_b := header_from_payload_ptr(slice.as_ptr(buf_b))
	testing.expect_value(t, header_err_b, runtime.Allocator_Error.None)
	owner_b := int(header_b.arena_index)

	testing.expect(t, owner_b != owner_a, "expected allocation to rotate into a new arena")
	testing.expect(t, len(pool.arenas) >= 2, "expected at least two arenas after rotation")

	release(pool, buf_b)
	release(pool, buf_a)

	testing.expect_value(t, pool.arenas[owner_a].live_allocs, uint(0))
	testing.expect_value(t, pool.arenas[owner_a].allocated_since_reset, u64(0))
}

@(test)
test_arena_rotation_reuses_idle_generation :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	pool.rotate_threshold = 256

	buf_a, err_a := alloc(pool, 320)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)
	header_a, header_err_a := header_from_payload_ptr(slice.as_ptr(buf_a))
	testing.expect_value(t, header_err_a, runtime.Allocator_Error.None)
	owner_a := int(header_a.arena_index)

	buf_b, err_b := alloc(pool, 64)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)
	header_b, header_err_b := header_from_payload_ptr(slice.as_ptr(buf_b))
	testing.expect_value(t, header_err_b, runtime.Allocator_Error.None)
	owner_b := int(header_b.arena_index)

	testing.expect(t, owner_b != owner_a, "expected first rotation to move to a new arena")
	testing.expect_value(t, len(pool.arenas), 2)
	testing.expect_value(t, pool.rotation_count, u64(1))
	testing.expect_value(t, pool.reused_arena_count, u64(0))

	release(pool, buf_a)

	buf_c, err_c := alloc(pool, 320)
	testing.expect_value(t, err_c, runtime.Allocator_Error.None)
	header_c, header_err_c := header_from_payload_ptr(slice.as_ptr(buf_c))
	testing.expect_value(t, header_err_c, runtime.Allocator_Error.None)
	testing.expect_value(t, int(header_c.arena_index), owner_b)

	buf_d, err_d := alloc(pool, 64)
	testing.expect_value(t, err_d, runtime.Allocator_Error.None)
	header_d, header_err_d := header_from_payload_ptr(slice.as_ptr(buf_d))
	testing.expect_value(t, header_err_d, runtime.Allocator_Error.None)
	owner_d := int(header_d.arena_index)

	testing.expect_value(t, owner_d, owner_a)
	testing.expect_value(t, len(pool.arenas), 2)
	testing.expect_value(t, pool.rotation_count, u64(2))
	testing.expect_value(t, pool.reused_arena_count, u64(1))

	release(pool, buf_b)
	release(pool, buf_c)
	release(pool, buf_d)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_arena_rotation_respects_max_arenas_until_generation_is_idle :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	pool.rotate_threshold = 256
	pool.max_arenas = 2

	buf_a, err_a := alloc(pool, 320)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)
	header_a, header_err_a := header_from_payload_ptr(slice.as_ptr(buf_a))
	testing.expect_value(t, header_err_a, runtime.Allocator_Error.None)
	owner_a := int(header_a.arena_index)

	buf_b, err_b := alloc(pool, 64)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)
	header_b, header_err_b := header_from_payload_ptr(slice.as_ptr(buf_b))
	testing.expect_value(t, header_err_b, runtime.Allocator_Error.None)
	owner_b := int(header_b.arena_index)

	testing.expect(t, owner_b != owner_a, "expected first rotation to move to a second arena")
	testing.expect_value(t, len(pool.arenas), 2)
	testing.expect_value(t, pool.rotation_count, u64(1))

	buf_c, err_c := alloc(pool, 320)
	testing.expect_value(t, err_c, runtime.Allocator_Error.None)
	header_c, header_err_c := header_from_payload_ptr(slice.as_ptr(buf_c))
	testing.expect_value(t, header_err_c, runtime.Allocator_Error.None)
	testing.expect_value(t, int(header_c.arena_index), owner_b)

	buf_d, err_d := alloc(pool, 64)
	testing.expect_value(t, err_d, runtime.Allocator_Error.None)
	header_d, header_err_d := header_from_payload_ptr(slice.as_ptr(buf_d))
	testing.expect_value(t, header_err_d, runtime.Allocator_Error.None)
	testing.expect_value(t, int(header_d.arena_index), owner_b)

	testing.expect_value(t, len(pool.arenas), 2)
	testing.expect(t, pool.rotation_cap_warned, "expected rotation cap warning to be set when all arenas are busy")
	testing.expect(t, pool.rotation_capped_count > 0, "expected capped rotation attempts to be tracked")
	testing.expect_value(t, pool.rotation_count, u64(1))
	testing.expect_value(t, pool.reused_arena_count, u64(0))

	release(pool, buf_a)

	buf_e, err_e := alloc(pool, 64)
	testing.expect_value(t, err_e, runtime.Allocator_Error.None)
	header_e, header_err_e := header_from_payload_ptr(slice.as_ptr(buf_e))
	testing.expect_value(t, header_err_e, runtime.Allocator_Error.None)
	testing.expect_value(t, int(header_e.arena_index), owner_a)

	testing.expect(t, !pool.rotation_cap_warned, "expected cap warning to clear after successful rotation")
	testing.expect_value(t, pool.rotation_count, u64(2))
	testing.expect_value(t, pool.reused_arena_count, u64(1))

	release(pool, buf_b)
	release(pool, buf_c)
	release(pool, buf_d)
	release(pool, buf_e)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_reset_clears_all_arena_state :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	pool.rotate_threshold = 256

	buf_a, err_a := alloc(pool, 320)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)
	buf_b, err_b := alloc(pool, 64)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)
	buf_c, err_c := alloc(pool, 320)
	testing.expect_value(t, err_c, runtime.Allocator_Error.None)

	testing.expect_value(t, len(buf_a), 320)
	testing.expect_value(t, len(buf_b), 64)
	testing.expect_value(t, len(buf_c), 320)
	testing.expect(t, len(pool.arenas) >= 2, "expected at least two arenas before reset")
	testing.expect(t, pool.used > 0, "expected pool usage before reset")

	reset(pool)

	testing.expect_value(t, pool.active_index, 0)
	testing.expect_value(t, pool.used, u64(0))
	for arena in pool.arenas {
		if arena == nil do continue
		testing.expect_value(t, arena.live_allocs, uint(0))
		testing.expect_value(t, arena.allocated_since_reset, u64(0))
	}

	buf_after, err_after := alloc(pool, 64)
	testing.expect_value(t, err_after, runtime.Allocator_Error.None)
	header_after, header_after_err := header_from_payload_ptr(slice.as_ptr(buf_after))
	testing.expect_value(t, header_after_err, runtime.Allocator_Error.None)
	testing.expect_value(t, int(header_after.arena_index), 0)

	release(pool, buf_after)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_pool_stats_helpers_report_totals :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	testing.expect_value(t, pool_current_arena_count(pool), 1)
	reserved_before := pool_total_reserved(pool)
	committed_before := pool_total_committed(pool)
	testing.expect(t, reserved_before > 0, "expected non-zero reserved bytes")
	testing.expect(t, committed_before <= reserved_before, "expected committed <= reserved")

	pool.rotate_threshold = 256
	buf_a, err_a := alloc(pool, 320)
	testing.expect_value(t, err_a, runtime.Allocator_Error.None)
	buf_b, err_b := alloc(pool, 64)
	testing.expect_value(t, err_b, runtime.Allocator_Error.None)

	testing.expect(t, pool_current_arena_count(pool) >= 2, "expected helper to report additional arenas after rotation")
	reserved_after := pool_total_reserved(pool)
	committed_after := pool_total_committed(pool)
	testing.expect(t, reserved_after >= reserved_before, "expected reserved bytes to stay monotonic")
	testing.expect(t, committed_after <= reserved_after, "expected committed <= reserved after rotation")

	release(pool, buf_b)
	release(pool, buf_a)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_allocator_make_slice_and_delete_roundtrip :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	alloc_iface := allocator(pool)
	buf := make([]u8, 512, alloc_iface)
	testing.expect_value(t, len(buf), 512)
	testing.expect(t, pool.used > 0, "expected allocator-backed make() to increase usage")

	for i in 0 ..< len(buf) {
		buf[i] = u8(i % 251)
	}

	delete(buf, alloc_iface)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_allocator_make_dynamic_append_and_delete_roundtrip :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	alloc_iface := allocator(pool)
	items := make([dynamic]u32, 0, 1, allocator = alloc_iface)

	for i in 0 ..< 256 {
		append(&items, u32(i * 3))
	}

	testing.expect_value(t, len(items), 256)
	testing.expect(t, pool.allocation_count > 1, "expected append growth to perform allocator resizes")
	testing.expect(t, pool.release_count > 0, "expected append growth to release old buffers")

	for i in 0 ..< len(items) {
		testing.expect_value(t, items[i], u32(i * 3))
	}

	delete(items)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_allocator_new_and_free_roundtrip :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	alloc_iface := allocator(pool)
	buf := new([128]u8, alloc_iface)
	testing.expect(t, buf != nil, "expected allocator-backed new() to succeed")
	testing.expect(t, pool.used > 0, "expected allocator-backed new() to increase usage")

	free(buf, alloc_iface)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_allocator_query_features_and_info :: proc(t: ^testing.T) {
	pool := init_buffer_pool()
	testing.expect(t, pool != nil, "expected pool to initialize")
	defer destroy_buffer_pool(pool)

	alloc_iface := allocator(pool)
	features := mem.query_features(alloc_iface)
	testing.expect(t, .Alloc in features, "expected allocator to report Alloc support")
	testing.expect(t, .Alloc_Non_Zeroed in features, "expected allocator to report Alloc_Non_Zeroed support")
	testing.expect(t, .Resize in features, "expected allocator to report Resize support")
	testing.expect(t, .Resize_Non_Zeroed in features, "expected allocator to report Resize_Non_Zeroed support")
	testing.expect(t, .Free in features, "expected allocator to report Free support")
	testing.expect(t, .Free_All in features, "expected allocator to report Free_All support")
	testing.expect(t, .Query_Features in features, "expected allocator to report Query_Features support")
	testing.expect(t, .Query_Info in features, "expected allocator to report Query_Info support")

	buf, err := alloc_internal(pool, 96, 128, false)
	testing.expect_value(t, err, runtime.Allocator_Error.None)
	testing.expect(t, buf != nil, "expected allocation to succeed")

	info := mem.query_info(slice.as_ptr(buf), alloc_iface)
	testing.expect_value(t, info.pointer, slice.as_ptr(buf))
	testing.expect_value(t, info.size, 96)
	testing.expect_value(t, info.alignment, int(sanitize_alignment(128)))

	guard, guard_err := alloc(pool, 64)
	testing.expect_value(t, guard_err, runtime.Allocator_Error.None)
	testing.expect(t, guard != nil, "expected guard allocation to succeed")

	buf_ptr := slice.as_ptr(buf)
	release(pool, buf)

	freed_info := runtime.Allocator_Query_Info {
		pointer = buf_ptr,
	}
	_, query_err := alloc_iface.procedure(alloc_iface.data, .Query_Info, 0, 0, rawptr(&freed_info), 0)
	testing.expect_value(t, query_err, runtime.Allocator_Error.Invalid_Pointer)

	release(pool, guard)
	testing.expect_value(t, pool.used, u64(0))
}

@(test)
test_hegel_pool_zeroed_allocations_are_zero :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_pool_zeroed_allocations_are_zero, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool zero-fill property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_pool_zeroed_allocations_are_zero :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	pool := init_buffer_pool()
	if pool == nil {
		return hgl.interesting("pool initialization failed")
	}
	defer destroy_buffer_pool(pool)

	size, size_err := hgl.draw_u32(tc, 1, 4096)
	if size_err == .Stop_Test {
		return hgl.abort()
	}
	if size_err != nil {
		return hgl.interesting("draw allocation size")
	}

	alignment, alignment_err := hgl.draw_u32(tc, 0, 512)
	if alignment_err == .Stop_Test {
		return hgl.abort()
	}
	if alignment_err != nil {
		return hgl.interesting("draw allocation alignment")
	}

	buf, alloc_err := alloc_internal(pool, uint(size), uint(alignment), true)
	if alloc_err != .None {
		return hgl.interesting("zeroed allocation failed for bounded request")
	}
	if buf == nil || len(buf) != int(size) {
		return hgl.interesting("zeroed allocation returned wrong slice length")
	}

	expected_alignment := sanitize_alignment(uint(alignment))
	if uintptr(slice.as_ptr(buf)) % uintptr(expected_alignment) != 0 {
		return hgl.interesting("zeroed allocation pointer is misaligned")
	}
	for b in buf {
		if b != 0 {
			return hgl.interesting("zeroed allocation contained non-zero byte")
		}
	}

	release(pool, buf)
	if pool.used != 0 {
		return hgl.interesting("pool usage non-zero after releasing zeroed allocation")
	}

	return hgl.valid()
}

@(test)
test_hegel_allocator_resize_preserves_prefix_and_accounting :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_allocator_resize_preserves_prefix_and_accounting, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool resize property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_allocator_resize_preserves_prefix_and_accounting :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	pool := init_buffer_pool()
	if pool == nil {
		return hgl.interesting("pool initialization failed")
	}
	defer destroy_buffer_pool(pool)

	alloc_iface := allocator(pool)
	old_size, old_size_err := hgl.draw_u32(tc, 1, 512)
	if old_size_err == .Stop_Test {
		return hgl.abort()
	}
	if old_size_err != nil {
		return hgl.interesting("draw old resize size")
	}

	new_size, new_size_err := hgl.draw_u32(tc, 0, 1024)
	if new_size_err == .Stop_Test {
		return hgl.abort()
	}
	if new_size_err != nil {
		return hgl.interesting("draw new resize size")
	}

	alignment, alignment_err := hgl.draw_u32(tc, 0, 512)
	if alignment_err == .Stop_Test {
		return hgl.abort()
	}
	if alignment_err != nil {
		return hgl.interesting("draw resize alignment")
	}

	old, alloc_err := alloc_internal(pool, uint(old_size), uint(alignment), true)
	if alloc_err != .None {
		return hgl.interesting("initial resize allocation failed")
	}
	if old == nil || len(old) != int(old_size) {
		return hgl.interesting("initial resize allocation returned wrong slice length")
	}

	pattern: [512]u8
	for i in 0 ..< int(old_size) {
		pattern[i] = u8((i * 31 + 7) % 251 + 1)
		old[i] = pattern[i]
	}

	old_ptr := slice.as_ptr(old)
	used_before := pool.used
	alloc_count_before := pool.allocation_count
	release_count_before := pool.release_count

	resized, resize_err := alloc_iface.procedure(alloc_iface.data, .Resize, int(new_size), int(alignment), old_ptr, int(old_size))
	if resize_err != .None {
		return hgl.interesting("resize failed for bounded request")
	}

	if new_size == 0 {
		if resized != nil {
			return hgl.interesting("resize-to-zero returned a buffer")
		}
		if pool.used != 0 {
			return hgl.interesting("resize-to-zero left pool usage non-zero")
		}
		if pool.allocation_count != alloc_count_before {
			return hgl.interesting("resize-to-zero changed allocation count")
		}
		if pool.release_count != release_count_before + 1 {
			return hgl.interesting("resize-to-zero did not release old allocation")
		}
		return hgl.valid()
	}

	if resized == nil || len(resized) != int(new_size) {
		return hgl.interesting("resize returned wrong slice length")
	}

	copy_count := int(min(old_size, new_size))
	for i in 0 ..< copy_count {
		if resized[i] != pattern[i] {
			return hgl.interesting("resize did not preserve prefix bytes")
		}
	}

	if new_size == old_size {
		if slice.as_ptr(resized) != old_ptr {
			return hgl.interesting("same-size resize changed pointer")
		}
		if pool.used != used_before {
			return hgl.interesting("same-size resize changed pool usage")
		}
		if pool.allocation_count != alloc_count_before {
			return hgl.interesting("same-size resize changed allocation count")
		}
		if pool.release_count != release_count_before {
			return hgl.interesting("same-size resize changed release count")
		}
	} else {
		if pool.allocation_count != alloc_count_before + 1 {
			return hgl.interesting("resize did not allocate replacement buffer")
		}
		if pool.release_count != release_count_before + 1 {
			return hgl.interesting("resize did not release old buffer")
		}
	}

	release(pool, resized)
	if pool.used != 0 {
		return hgl.interesting("pool usage non-zero after releasing resized allocation")
	}
	for arena in pool.arenas {
		if arena == nil {
			continue
		}
		if arena.live_allocs != 0 {
			return hgl.interesting("arena has live allocations after resized allocation release")
		}
	}

	return hgl.valid()
}

@(test)
test_hegel_pool_accounting_matches_live_allocation_model :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_pool_accounting_matches_live_allocation_model, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool accounting property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_pool_accounting_matches_live_allocation_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	pool := init_buffer_pool()
	if pool == nil {
		return hgl.interesting("pool initialization failed")
	}
	defer destroy_buffer_pool(pool)

	threshold, threshold_err := hgl.draw_u32(tc, 0, 1024)
	if threshold_err == .Stop_Test {
		return hgl.abort()
	}
	if threshold_err != nil {
		return hgl.interesting("draw rotate threshold")
	}
	pool.rotate_threshold = uint(threshold)

	max_arenas, max_arenas_err := hgl.draw_u32(tc, 1, MAX_POOL_ARENAS)
	if max_arenas_err == .Stop_Test {
		return hgl.abort()
	}
	if max_arenas_err != nil {
		return hgl.interesting("draw max arenas")
	}
	pool.max_arenas = int(max_arenas)

	op_count, op_count_err := hgl.draw_u32(tc, 0, 100)
	if op_count_err == .Stop_Test {
		return hgl.abort()
	}
	if op_count_err != nil {
		return hgl.interesting("draw operation count")
	}

	live: [128]Hegel_Model_Alloc
	live_count := 0
	successful_allocs := u64(0)
	successful_releases := u64(0)

	for _ in 0 ..< int(op_count) {
		op, op_err := hgl.draw_u32(tc, 0, 9)
		if op_err == .Stop_Test {
			return hgl.abort()
		}
		if op_err != nil {
			return hgl.interesting("draw operation")
		}

		if op <= 5 || live_count == 0 {
			size, size_err := hgl.draw_u32(tc, 0, 2048)
			if size_err == .Stop_Test {
				return hgl.abort()
			}
			if size_err != nil {
				return hgl.interesting("draw allocation size")
			}

			alignment, alignment_err := hgl.draw_u32(tc, 0, 256)
			if alignment_err == .Stop_Test {
				return hgl.abort()
			}
			if alignment_err != nil {
				return hgl.interesting("draw allocation alignment")
			}

			zeroed, zeroed_err := hgl.draw_bool(tc)
			if zeroed_err == .Stop_Test {
				return hgl.abort()
			}
			if zeroed_err != nil {
				return hgl.interesting("draw zeroed flag")
			}

			buf, alloc_err := alloc_internal(pool, uint(size), uint(alignment), zeroed)
			if alloc_err != .None {
				return hgl.interesting("allocation failed for bounded request")
			}

			if size == 0 {
				if buf != nil {
					return hgl.interesting("zero-size allocation returned a buffer")
				}
				if model_err := hegel_check_pool_model(pool, live[:live_count]); model_err != "" {
					return hgl.interesting(model_err)
				}
				continue
			}

			if buf == nil || len(buf) != int(size) {
				return hgl.interesting("allocation returned wrong slice length")
			}

			header, header_err := header_from_payload_ptr(slice.as_ptr(buf))
			if header_err != .None {
				return hgl.interesting("allocated buffer has invalid header")
			}

			expected_alignment := sanitize_alignment(uint(alignment))
			if header.alignment != expected_alignment {
				return hgl.interesting("header alignment does not match sanitized alignment")
			}
			if uintptr(slice.as_ptr(buf)) % uintptr(expected_alignment) != 0 {
				return hgl.interesting("allocated buffer pointer is misaligned")
			}
			if header.payload_size != uint(size) {
				return hgl.interesting("header payload size mismatch")
			}
			if int(header.arena_index) < 0 || int(header.arena_index) >= len(pool.arenas) {
				return hgl.interesting("header arena index out of bounds")
			}

			if live_count >= len(live) {
				release(pool, buf)
				successful_releases += 1
			} else {
				live[live_count] = Hegel_Model_Alloc {
					buf         = buf,
					reserved    = u64(header.reserved_size),
					arena_index = int(header.arena_index),
				}
				live_count += 1
			}
			successful_allocs += 1
		} else if op <= 8 {
			idx_raw, idx_err := hgl.draw_u32(tc, 0, u32(live_count - 1))
			if idx_err == .Stop_Test {
				return hgl.abort()
			}
			if idx_err != nil {
				return hgl.interesting("draw release index")
			}

			idx := int(idx_raw)
			release(pool, live[idx].buf)
			successful_releases += 1
			live_count -= 1
			live[idx] = live[live_count]
			live[live_count] = {}
		} else {
			reset(pool)
			live_count = 0
			for i in 0 ..< len(live) {
				live[i] = {}
			}
		}

		if model_err := hegel_check_pool_model(pool, live[:live_count]); model_err != "" {
			return hgl.interesting(model_err)
		}
		if pool.allocation_count != successful_allocs {
			return hgl.interesting("allocation count drifted from successful allocation model")
		}
		if pool.release_count != successful_releases {
			return hgl.interesting("release count drifted from successful release model")
		}
	}

	for live_count > 0 {
		live_count -= 1
		release(pool, live[live_count].buf)
		live[live_count] = {}
		successful_releases += 1
		if model_err := hegel_check_pool_model(pool, live[:live_count]); model_err != "" {
			return hgl.interesting(model_err)
		}
	}

	if pool.release_count != successful_releases {
		return hgl.interesting("final release count drifted from model")
	}
	if pool.used != 0 {
		return hgl.interesting("pool usage non-zero after releasing all model allocations")
	}
	for arena in pool.arenas {
		if arena == nil {
			continue
		}
		if arena.live_allocs != 0 {
			return hgl.interesting("arena has live allocations after model drain")
		}
		if arena.allocated_since_reset != 0 {
			return hgl.interesting("idle arena did not reset allocated_since_reset")
		}
	}

	return hgl.valid()
}

hegel_check_pool_model :: proc(pool: ^BufferPool, live: []Hegel_Model_Alloc) -> string {
	if pool == nil {
		return "pool is nil"
	}
	if len(pool.arenas) <= 0 {
		return "pool has no arenas"
	}
	if pool.active_index < 0 || pool.active_index >= len(pool.arenas) {
		return "active arena index out of bounds"
	}
	if len(pool.arenas) > pool.max_arenas {
		return "pool exceeded max arena count"
	}
	if pool_total_committed(pool) > pool_total_reserved(pool) {
		return "committed bytes exceed reserved bytes"
	}

	expected_used := u64(0)
	expected_live_by_arena: [MAX_POOL_ARENAS]uint
	for item in live {
		if item.buf == nil {
			return "model contains nil live allocation"
		}
		header, header_err := header_from_payload_ptr(slice.as_ptr(item.buf))
		if header_err != .None {
			return "model live allocation has invalid header"
		}
		if header.magic != ALLOC_HEADER_MAGIC {
			return "model live allocation header magic changed"
		}
		if u64(header.reserved_size) != item.reserved {
			return "model live allocation reserved size changed"
		}
		if int(header.arena_index) != item.arena_index {
			return "model live allocation arena index changed"
		}
		if item.arena_index < 0 || item.arena_index >= len(pool.arenas) || item.arena_index >= len(expected_live_by_arena) {
			return "model live allocation arena index out of bounds"
		}
		expected_used += item.reserved
		expected_live_by_arena[item.arena_index] += 1
	}

	if pool.used != expected_used {
		return "pool used bytes do not match model"
	}
	for arena, i in pool.arenas {
		if arena == nil {
			return "pool contains nil arena"
		}
		if arena.live_allocs != expected_live_by_arena[i] {
			return "arena live allocation count does not match model"
		}
		if arena.live_allocs == 0 && arena.allocated_since_reset != 0 {
			return "idle arena retained allocated_since_reset"
		}
	}

	return ""
}
