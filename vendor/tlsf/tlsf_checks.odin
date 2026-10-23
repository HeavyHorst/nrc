package mem_tlsf

import "base:runtime"

when !TLSF_CHECK_INVARIANTS {
	_ :: runtime.heap_allocator
}

// Expensive, opt-in test instrumentation. Walk physical blocks before following
// free-list links, so a corrupt list pointer is rejected without dereferencing it.
when TLSF_CHECK_INVARIANTS {
	Check_Block :: struct {
		free, listed, quarantined: bool,
	}

	@(private, no_sanitize_address)
	check_invariants :: proc(control: ^Allocator) {
		// Never use context.allocator: it may be the TLSF being checked. Scratch
		// is local and independent of its pools, including caller-owned pools.
		blocks := make(map[^Block_Header]Check_Block, allocator = runtime.heap_allocator())
		defer delete(blocks)
		for pool := &control.pool; pool != nil; pool = pool.next {
			assert(len(pool.data) >= int(POOL_OVERHEAD + BLOCK_SIZE_MIN), "TLSF invariant: pool bounds")
			start := uintptr(raw_data(pool.data))
			assert(start % ALIGN_SIZE == 0, "TLSF invariant: pool alignment")
			sentinel := start + uintptr(align_down(len(pool.data) - POOL_OVERHEAD, ALIGN_SIZE)) + uintptr(BLOCK_HEADER_OVERHEAD)
			previous: ^Block_Header
			previous_free := false
			position := start
			for {
				assert(position <= sentinel, "TLSF invariant: block outside pool")
				block := (^Block_Header)(position - uintptr(BLOCK_HEADER_OVERHEAD))
				size := block_size(block)
				is_free := block_is_free(block)
				assert(block_is_prev_free(block) == previous_free, "TLSF invariant: previous-free flag")
				if previous_free {
					assert(block.prev_phys_block == previous, "TLSF invariant: previous physical block")
				}
				if position == sentinel {
					assert(size == 0 && !is_free, "TLSF invariant: sentinel")
					break
				}
				assert(size >= BLOCK_SIZE_MIN && size % ALIGN_SIZE == 0, "TLSF invariant: block size")
				assert(size <= uint(sentinel - position) - BLOCK_HEADER_OVERHEAD, "TLSF invariant: block extent")
				assert(!(is_free && previous_free), "TLSF invariant: uncoalesced free blocks")
				_, duplicate := blocks[block]
				assert(!duplicate, "TLSF invariant: overlapping pool blocks")
				blocks[block] = {free = is_free}
				previous = block
				previous_free = is_free
				position += uintptr(size + BLOCK_HEADER_OVERHEAD)
			}
		}

		fl_bitmap: u32
		for fl in 0 ..< FL_INDEX_COUNT {
			sl_bitmap: u32
			for sl in 0 ..< SL_INDEX_COUNT {
				previous := &control.block_null
				block := control.blocks[fl][sl]
				if block != &control.block_null do sl_bitmap |= u32(1) << uint(sl)
				for block != &control.block_null {
					record, found := blocks[block]
					assert(found && record.free, "TLSF invariant: free-list member")
					assert(!record.listed, "TLSF invariant: duplicate or cyclic free-list member")
					block_fl, block_sl := mapping_insert(block_size(block))
					assert(int(block_fl) == fl && int(block_sl) == sl, "TLSF invariant: size class")
					assert(block.prev_free == previous, "TLSF invariant: previous free-list link")
					record.listed = true
					blocks[block] = record
					previous = block
					block = block.next_free
				}
			}
			assert(control.sl_bitmap[fl] == sl_bitmap, "TLSF invariant: second-level bitmap")
			if sl_bitmap != 0 do fl_bitmap |= u32(1) << uint(fl)
		}
		assert(control.fl_bitmap == fl_bitmap, "TLSF invariant: first-level bitmap")
		for _, record in blocks {
			assert(record.free == record.listed, "TLSF invariant: unlisted free block")
		}
		when TLSF_ASAN_QUARANTINE {
			q := &control.quarantine
			assert(q.head >= 0 && q.head < QUARANTINE_CAPACITY, "TLSF invariant: quarantine head")
			assert(q.count >= 0 && q.count <= QUARANTINE_CAPACITY, "TLSF invariant: quarantine count")
			bytes: uint
			for i in 0 ..< q.count {
				block := q.blocks[(q.head + i) % QUARANTINE_CAPACITY]
				record, found := blocks[block]
				assert(found && !record.free && !record.quarantined, "TLSF invariant: quarantine member")
				record.quarantined = true
				blocks[block] = record
				bytes += block_size(block) + BLOCK_HEADER_OVERHEAD
			}
			assert(bytes == q.bytes && bytes <= QUARANTINE_BYTES, "TLSF invariant: quarantine bytes")
		}
	}
}
