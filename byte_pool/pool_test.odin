package byte_pool

// Backing-allocator ownership, logical lengths, and accounting. The backing
// fixture deliberately rounds allocations and checks the original free tuple.
import hgl "../hegel"
import "base:runtime"
import "core:mem"
import "core:testing"

Test_Backing :: struct {
	parent:                  mem.Allocator,
	round_extra:             int,
	fail:                    bool,
	last:                    []u8,
	metadata:                rawptr,
	bytes:                   u64,
	allocs, frees, free_all: u64,
	bad_free:                bool,
	entries:                 [256][]u8,
}

test_backing_allocator :: proc(b: ^Test_Backing) -> mem.Allocator {
	return {procedure = test_backing_proc, data = b}
}

test_backing_proc :: proc(
	data: rawptr,
	mode: runtime.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	[]u8,
	runtime.Allocator_Error,
) {
	b := (^Test_Backing)(data)
	#partial switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		if b.fail do return nil, .Out_Of_Memory
		buf, err := b.parent.procedure(b.parent.data, mode, size + b.round_extra, alignment, nil, 0, location)
		if err != .None do return nil, err
		for &entry in b.entries {
			if entry == nil {
				entry = buf
				b.last = buf
				b.bytes += u64(len(buf))
				if b.allocs == 0 do b.metadata = raw_data(buf)
				b.allocs += 1
				return buf, .None
			}
		}
		panic("backing fixture capacity exhausted")
	case .Free:
		for &entry in b.entries {
			if entry != nil && raw_data(entry) == old_memory {
				// new(BufferPool)/free(pool) may omit metadata's size. Buffer
				// frees, unlike metadata frees, must supply the actual length.
				if old_size != len(entry) && old_memory != b.metadata {
					b.bad_free = true
					return nil, .Invalid_Pointer
				}
				_, err := b.parent.procedure(b.parent.data, mode, 0, alignment, old_memory, len(entry), location)
				if err == .None {
					b.bytes -= u64(len(entry))
					b.frees += 1
					entry = nil
				}
				return nil, err
			}
		}
		b.bad_free = true
		return nil, .Invalid_Pointer
	case .Free_All:
		b.free_all += 1
		return nil, .Mode_Not_Implemented
	case:
		return b.parent.procedure(b.parent.data, mode, size, alignment, old_memory, old_size, location)
	}
}

// Independent of the implementation's alignment helper.
test_alignment :: proc(request: uint) -> uint {
	a := uint(align_of(Alloc_Header))
	for a < request do a *= 2
	return a
}

@(test)
test_alloc_release_backing_accounting :: proc(t: ^testing.T) {
	b := Test_Backing {
		parent      = context.allocator,
		round_extra = 37,
	}
	p := init_buffer_pool(test_backing_allocator(&b))
	testing.expect(t, p != nil)
	defer destroy_buffer_pool(p)
	baseline := b.bytes
	buf, err := alloc_internal(p, 31, 128, false)
	testing.expect(t, err == .None)
	testing.expect_value(t, len(buf), 31)
	testing.expect_value(t, uintptr(raw_data(buf)) % 128, uintptr(0))
	h, he := header_from_payload_ptr(raw_data(buf))
	testing.expect(t, he == .None)
	testing.expect_value(t, h.owner, p)
	testing.expect_value(t, h.allocation, rawptr(raw_data(b.last)))
	testing.expect_value(t, u64(h.reserved_size), b.bytes - baseline)
	testing.expect_value(t, p.used, b.bytes - baseline)
	testing.expect_value(t, p.live_allocs, uint(1))
	// A shortened slice must free the original backing base and actual length.
	release(p, buf[:7])
	testing.expect_value(t, b.bytes, baseline)
	testing.expect(t, !b.bad_free)
	testing.expect_value(t, p.used, u64(0))
	testing.expect_value(t, p.live_allocs, uint(0))
	testing.expect_value(t, p.allocation_count, u64(1))
	testing.expect_value(t, p.release_count, u64(1))
	buf, err = alloc(p, 17)
	testing.expect(t, err == .None)
	a := allocator(p)
	_, err = a.procedure(a.data, .Free, 0, 0, raw_data(buf), 0)
	testing.expect(t, err == .None)
	testing.expect_value(t, b.bytes, baseline)
	testing.expect(t, !b.bad_free)
}

@(test)
test_release_rejects_wrong_live_owner :: proc(t: ^testing.T) {
	p := init_buffer_pool()
	q := init_buffer_pool()
	defer destroy_buffer_pool(p)
	defer destroy_buffer_pool(q)
	x, xe := alloc(p, 128)
	y, ye := alloc(q, 64)
	testing.expect(t, xe == .None)
	testing.expect(t, ye == .None)
	defer release(p, x)
	defer release(q, y)
	before_p, before_q := p^, q^
	err := release_ptr(q, raw_data(x))
	testing.expect(t, err == .Invalid_Pointer)
	testing.expect_value(t, p.used, before_p.used)
	testing.expect_value(t, q.used, before_q.used)
	testing.expect_value(t, p.live_allocs, before_p.live_allocs)
	testing.expect_value(t, q.live_allocs, before_q.live_allocs)
	testing.expect_value(t, p.allocation_count, before_p.allocation_count)
	testing.expect_value(t, q.allocation_count, before_q.allocation_count)
	testing.expect_value(t, p.release_count, before_p.release_count)
	testing.expect_value(t, q.release_count, before_q.release_count)
	testing.expect_value(t, p.invalid_release_count, before_p.invalid_release_count)
	testing.expect_value(t, q.invalid_release_count, before_q.invalid_release_count + 1)
	x[0] = 91
	testing.expect_value(t, x[0], u8(91))
}

@(test)
test_allocator_roundtrips_and_features :: proc(t: ^testing.T) {
	p := init_buffer_pool()
	defer destroy_buffer_pool(p)
	a := allocator(p)
	buf := make([]u8, 512, a)
	testing.expect_value(t, len(buf), 512)
	delete(buf, a)
	x := new([128]u8, a)
	free(x, a)
	items := make([dynamic]u32, 0, 1, allocator = a)
	for i in 0 ..< 256 do append(&items, u32(i * 3))
	for value, i in items do testing.expect_value(t, value, u32(i * 3))
	delete(items)
	testing.expect_value(t, p.used, u64(0))
	testing.expect_value(t, p.live_allocs, uint(0))
	features := mem.query_features(a)
	modes := []runtime.Allocator_Mode{.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Free, .Query_Features, .Query_Info}
	for mode in modes {
		testing.expect(t, mode in features)
	}
	testing.expect(t, !(.Free_All in features))
	query_buf, err := alloc_internal(p, 96, 128, false)
	testing.expect(t, err == .None)
	defer release(p, query_buf)
	info := mem.query_info(raw_data(query_buf), a)
	testing.expect_value(t, info.pointer, rawptr(raw_data(query_buf)))
	testing.expect_value(t, info.size, 96)
	testing.expect_value(t, info.alignment, 128)
}

@(test)
test_failure_preserves_live_allocation_and_free_all_is_rejected :: proc(t: ^testing.T) {
	b := Test_Backing {
		parent      = context.allocator,
		round_extra = 19,
	}
	p := init_buffer_pool(test_backing_allocator(&b))
	defer destroy_buffer_pool(p)
	x, err := alloc(p, 32)
	testing.expect(t, err == .None)
	defer release(p, x)
	for &v in x do v = 73
	a := allocator(p)
	before := p^
	bytes := b.bytes
	b.fail = true
	y, ae := alloc(p, 64)
	testing.expect(t, ae == .Out_Of_Memory)
	testing.expect(t, y == nil)
	y, ae = a.procedure(a.data, .Resize, 128, 64, raw_data(x), 0)
	testing.expect(t, ae == .Out_Of_Memory)
	testing.expect(t, y == nil)
	_, ae = a.procedure(a.data, .Free_All, 0, 0, nil, 0)
	testing.expect(t, ae == .Mode_Not_Implemented)
	testing.expect_value(t, b.free_all, u64(0))
	testing.expect_value(t, b.bytes, bytes)
	testing.expect_value(t, p.used, before.used)
	testing.expect_value(t, p.live_allocs, before.live_allocs)
	testing.expect_value(t, p.allocation_count, before.allocation_count)
	testing.expect_value(t, p.release_count, before.release_count)
	for v in x do testing.expect_value(t, v, u8(73))
	b.fail = false
}

@(test)
test_allocation_overflow_guards :: proc(t: ^testing.T) {
	b := Test_Backing {
		parent = context.allocator,
	}
	p := init_buffer_pool(test_backing_allocator(&b))
	defer destroy_buffer_pool(p)
	count := b.allocs
	requests := []struct {
		size, alignment: uint,
	}{{max(uint), 8}, {uint(max(int)), 128}, {1, max(uint)}, {1, uint(max(int)) + 1}}
	for request in requests {
		x, err := alloc_internal(p, request.size, request.alignment, false)
		testing.expect(t, err != .None)
		testing.expect(t, x == nil)
	}
	testing.expect_value(t, b.allocs, count)
	testing.expect_value(t, p.used, u64(0))
}

@(test)
test_resize_same_size_stronger_alignment :: proc(t: ^testing.T) {
	p := init_buffer_pool()
	defer destroy_buffer_pool(p)
	x, err := alloc(p, 37)
	testing.expect(t, err == .None)
	for &v in x do v = 53
	a := allocator(p)
	y, re := a.procedure(a.data, .Resize, 37, 4096, raw_data(x), 0)
	testing.expect(t, re == .None)
	testing.expect_value(t, len(y), 37)
	testing.expect_value(t, uintptr(raw_data(y)) % 4096, uintptr(0))
	for v in y do testing.expect_value(t, v, u8(53))
	release(p, y)
}

Hegel_Model_Alloc :: struct {
	buf:      []u8,
	reserved: u64,
	pattern:  u8,
}

@(test)
test_hegel_pool_zeroed_allocations_are_zero :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_pool_zeroed_allocations_are_zero, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool zero-fill: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_pool_zeroed_allocations_are_zero :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	size, se := hgl.draw_u32(tc, 1, 4096)
	if se == .Stop_Test do return hgl.abort()
	if se != nil do return hgl.interesting("draw zero-fill size")
	alignment, ae := hgl.draw_u32(tc, 0, 512)
	if ae == .Stop_Test do return hgl.abort()
	if ae != nil do return hgl.interesting("draw zero-fill alignment")
	p := init_buffer_pool()
	if p == nil do return hgl.interesting("pool initialization failed")
	defer destroy_buffer_pool(p)
	x, err := alloc_internal(p, uint(size), uint(alignment), true)
	if err != .None do return hgl.interesting("zeroed bounded allocation failed")
	defer release(p, x)
	if len(x) != int(size) do return hgl.interesting("zeroed logical length mismatch")
	if uintptr(raw_data(x)) % uintptr(test_alignment(uint(alignment))) != 0 do return hgl.interesting("zeroed alignment mismatch")
	for v in x {
		if v != 0 do return hgl.interesting("nonzero zeroed allocation")
	}
	return hgl.valid()
}

@(test)
test_hegel_pool_accounting_matches_live_allocation_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_pool_accounting_matches_live_allocation_model, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool accounting: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_pool_accounting_matches_live_allocation_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	b := Test_Backing {
		parent      = context.allocator,
		round_extra = 23,
	}
	p := init_buffer_pool(test_backing_allocator(&b))
	if p == nil do return hgl.interesting("pool initialization failed")
	defer destroy_buffer_pool(p)
	live: [128]Hegel_Model_Alloc
	n := 0
	// Cleanup also runs for aborted/shrunk cases: destroy must never see live allocations.
	defer {
		for item in live[:n] do release(p, item.buf)
	}
	baseline := b.bytes
	allocs, frees := u64(0), u64(0)
	count, ce := hgl.draw_u32(tc, 0, 100)
	if ce == .Stop_Test do return hgl.abort()
	if ce != nil do return hgl.interesting("draw operation count")
	for _ in 0 ..< int(count) {
		op, oe := hgl.draw_u32(tc, 0, 9)
		if oe == .Stop_Test do return hgl.abort()
		if oe != nil do return hgl.interesting("draw operation")
		if op <= 5 || n == 0 {
			size, se := hgl.draw_u32(tc, 0, 2048)
			if se == .Stop_Test do return hgl.abort()
			if se != nil do return hgl.interesting("draw size")
			alignment, ae := hgl.draw_u32(tc, 0, 256)
			if ae == .Stop_Test do return hgl.abort()
			if ae != nil do return hgl.interesting("draw alignment")
			zeroed, ze := hgl.draw_bool(tc)
			if ze == .Stop_Test do return hgl.abort()
			if ze != nil do return hgl.interesting("draw zeroed flag")
			before := b.bytes
			x, err := alloc_internal(p, uint(size), uint(alignment), zeroed)
			if err != .None do return hgl.interesting("bounded allocation failed")
			if size != 0 {
				live[n] = {
					buf      = x,
					reserved = b.bytes - before,
					pattern  = u8(n + 1),
				}
				n += 1
				allocs += 1
				if len(x) != int(size) do return hgl.interesting("wrong logical length")
				if uintptr(raw_data(x)) % uintptr(test_alignment(uint(alignment))) != 0 do return hgl.interesting("misalignment")
				for &v in x {
					if zeroed && v != 0 do return hgl.interesting("nonzero zeroed allocation")
					v = live[n - 1].pattern
				}
			} else if x != nil {
				return hgl.interesting("non-nil zero allocation")
			}
		} else if op <= 8 {
			idx, ie := hgl.draw_u32(tc, 0, u32(n - 1))
			if ie == .Stop_Test do return hgl.abort()
			if ie != nil do return hgl.interesting("draw release index")
			release(p, live[idx].buf)
			frees += 1
			n -= 1
			live[idx] = live[n]
			live[n] = {}
		} else {
			// The former reset operation now frees each owned allocation, not the heap.
			for n > 0 {
				n -= 1
				release(p, live[n].buf)
				live[n] = {}
				frees += 1
			}
		}
		if why := hegel_check_pool_model(p, live[:n]); why != "" do return hgl.interesting(why)
		if p.used != b.bytes - baseline || b.bad_free || b.free_all != 0 do return hgl.interesting("backing accounting/free tuple mismatch")
		if p.allocation_count != allocs || p.release_count != frees do return hgl.interesting("operation counters drifted")
	}
	for n > 0 {
		n -= 1
		release(p, live[n].buf)
		frees += 1
		if why := hegel_check_pool_model(p, live[:n]); why != "" do return hgl.interesting(why)
	}
	if b.bytes != baseline || b.bad_free || p.release_count != frees do return hgl.interesting("final drain mismatch")
	return hgl.valid()
}

hegel_check_pool_model :: proc(p: ^BufferPool, live: []Hegel_Model_Alloc) -> string {
	expected := u64(0)
	for item in live {
		h, err := header_from_payload_ptr(raw_data(item.buf))
		if err != .None do return "invalid live header"
		if h.owner != p || h.magic != ALLOC_HEADER_MAGIC do return "live header ownership changed"
		if u64(h.reserved_size) != item.reserved do return "reserved size disagrees with backing allocator"
		if h.payload_size != uint(len(item.buf)) do return "payload size changed"
		for v in item.buf {
			if v != item.pattern do return "another operation corrupted live bytes"
		}
		expected += item.reserved
	}
	if p.used != expected do return "used bytes disagree with independent model"
	if p.live_allocs != uint(len(live)) do return "live count disagrees with model"
	return ""
}

@(test)
test_hegel_allocator_resize_preserves_prefix_and_accounting :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_allocator_resize_preserves_prefix_and_accounting, nil, {test_cases = 100})
	testing.expectf(t, err == nil, "hegel byte-pool resize: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_allocator_resize_preserves_prefix_and_accounting :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	old_size, oe := hgl.draw_u32(tc, 1, 512)
	if oe == .Stop_Test do return hgl.abort()
	if oe != nil do return hgl.interesting("draw old size")
	new_size, ne := hgl.draw_u32(tc, 0, 1024)
	if ne == .Stop_Test do return hgl.abort()
	if ne != nil do return hgl.interesting("draw new size")
	alignment, ae := hgl.draw_u32(tc, 0, 512)
	if ae == .Stop_Test do return hgl.abort()
	if ae != nil do return hgl.interesting("draw alignment")
	b := Test_Backing {
		parent      = context.allocator,
		round_extra = 31,
	}
	p := init_buffer_pool(test_backing_allocator(&b))
	if p == nil do return hgl.interesting("pool initialization failed")
	defer destroy_buffer_pool(p)
	baseline := b.bytes
	x, err := alloc_internal(p, uint(old_size), uint(alignment), true)
	if err != .None do return hgl.interesting("initial allocation failed")
	defer {
		if x != nil do release(p, x)
	}
	for i in 0 ..< len(x) do x[i] = u8((i * 31 + 7) % 251 + 1)
	a := allocator(p)
	before := p^
	y, re := a.procedure(a.data, .Resize, int(new_size), int(alignment), raw_data(x), 0)
	if re != .None do return hgl.interesting("bounded resize failed")
	x = y // No reads from the released old storage, including deferred cleanup.
	if len(y) != int(new_size) do return hgl.interesting("wrong resize logical length")
	for i in 0 ..< int(min(old_size, new_size)) {
		if y[i] != u8((i * 31 + 7) % 251 + 1) do return hgl.interesting("prefix not preserved with old_size=0")
	}
	for i in int(old_size) ..< int(new_size) {
		if y[i] != 0 do return hgl.interesting("Resize growth not zeroed")
	}
	if new_size != 0 && uintptr(raw_data(y)) % uintptr(test_alignment(uint(alignment))) != 0 do return hgl.interesting("resize misaligned")
	if p.used != b.bytes - baseline || b.bad_free do return hgl.interesting("resize backing accounting mismatch")
	if new_size == 0 {
		if y != nil || p.live_allocs != 0 || p.release_count != before.release_count + 1 do return hgl.interesting("resize-to-zero did not release")
	} else if new_size != old_size {
		if p.allocation_count != before.allocation_count + 1 || p.release_count != before.release_count + 1 do return hgl.interesting("resize replacement counters")
	} else {
		// Same-size in-place is optional, provided alignment is satisfied.
		if p.live_allocs != 1 do return hgl.interesting("same-size resize live count")
	}
	release(p, x)
	x = nil
	if p.used != 0 || p.live_allocs != 0 || b.bytes != baseline || b.bad_free do return hgl.interesting("resize final drain mismatch")
	return hgl.valid()
}
