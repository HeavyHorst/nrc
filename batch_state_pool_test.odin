package main

import "core:testing"

reset_batch_pool_counters :: proc() {
	td.batch_state_pool.pooled_allocations = 0
	td.batch_state_pool.pooled_reuses = 0
	td.batch_state_pool.pooled_releases = 0
	td.batch_state_pool.pooled_drops = 0
	td.batch_state_pool.heap_fallback_allocs = 0
	td.batch_state_pool.heap_fallback_frees = 0
}

@(test)
test_batch_pool_class_selection :: proc(t: ^testing.T) {
	testing.expect_value(t, batch_pool_class_for_count(1), 0)
	testing.expect_value(t, batch_pool_class_for_count(2), 0)
	testing.expect_value(t, batch_pool_class_for_count(3), 1)
	testing.expect_value(t, batch_pool_class_for_count(4), 1)
	testing.expect_value(t, batch_pool_class_for_count(8), 2)
	testing.expect_value(t, batch_pool_class_for_count(16), 3)
	testing.expect_value(t, batch_pool_class_for_count(32), 4)
	testing.expect_value(t, batch_pool_class_for_count(64), 5)
	testing.expect_value(t, batch_pool_class_for_count(128), 6)
	testing.expect_value(t, batch_pool_class_for_count(256), 7)
	testing.expect_value(t, batch_pool_class_for_count(257), -1)
}

@(test)
test_batch_pool_cache_depth_halves_with_larger_classes :: proc(t: ^testing.T) {
	expected := [Batch_Pool_Class_Count]int{8192, 8192, 4096, 2048, 1024, 512, 256, 128}
	for class in 0 ..< Batch_Pool_Class_Count {
		testing.expect_value(t, batch_pool_max_free_for_class(class), expected[class])
	}
	testing.expect_value(t, batch_pool_max_free_for_class(-1), 0)
	testing.expect_value(t, batch_pool_max_free_for_class(Batch_Pool_Class_Count), 0)
}

@(test)
test_batch_pool_reuses_released_state :: proc(t: ^testing.T) {
	init_batch_state_pool()
	defer destroy_batch_state_pool()
	reset_batch_pool_counters()

	state1 := alloc_batch_state(8)
	testing.expect(t, state1 != nil, "expected batch state allocation")
	testing.expect_value(t, state1.pool_class, 2)
	testing.expect_value(t, state1.capacity, 8)

	free_batch_state(state1)

	state2 := alloc_batch_state(8)
	testing.expect(t, state2 != nil, "expected reused batch state")
	testing.expect(t, state1 == state2, "expected second allocation to reuse previously freed state")

	testing.expect_value(t, td.batch_state_pool.pooled_allocations, 1)
	testing.expect_value(t, td.batch_state_pool.pooled_reuses, 1)
	testing.expect_value(t, td.batch_state_pool.pooled_releases, 1)
	testing.expect_value(t, td.batch_state_pool.heap_fallback_allocs, 0)

	free_batch_state(state2)
}

@(test)
test_batch_pool_fallback_for_oversized_batches :: proc(t: ^testing.T) {
	init_batch_state_pool()
	defer destroy_batch_state_pool()
	reset_batch_pool_counters()

	state := alloc_batch_state(Max_Batch_Size)
	testing.expect(t, state != nil, "expected fallback batch state allocation")
	testing.expect_value(t, state.pool_class, -1)
	testing.expect_value(t, state.capacity, Max_Batch_Size)
	testing.expect_value(t, td.batch_state_pool.heap_fallback_allocs, 1)

	free_batch_state(state)
	testing.expect_value(t, td.batch_state_pool.heap_fallback_frees, 1)
	testing.expect_value(t, td.batch_state_pool.pooled_releases, 0)
}

@(test)
test_batch_pool_free_list_cap_drops_excess :: proc(t: ^testing.T) {
	init_batch_state_pool()
	defer destroy_batch_state_pool()
	reset_batch_pool_counters()

	class := Batch_Pool_Class_Count - 1
	max_free := batch_pool_max_free_for_class(class)
	states := make([dynamic]^Batch_Send_State, 0, max_free + 1)
	defer delete(states)

	for _ in 0 ..< max_free + 1 {
		state := alloc_batch_state(batch_pool_class_capacity(class))
		testing.expect(t, state != nil, "expected pooled batch state allocation")
		append(&states, state)
	}

	for state in states {
		free_batch_state(state)
	}

	testing.expect_value(t, len(td.batch_state_pool.free_lists[class]), max_free)
	testing.expect_value(t, td.batch_state_pool.pooled_drops, 1)
}
