//
// note_index_rbtree_benchmark.odin - Note Secondary Index RB-Tree Benchmark
//
// Benchmarks note index operations using core:container/rbtree:
// - Insert notes keyed by (updated_at, asset_id)
// - Update notes via remove+insert (updated_at changes)
// - Paginate newest-first via cursor seek + reverse iterator
//
// Run with: BENCH_NOTE_INDEX_RB=1 odin test . -o:speed \
//   -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 \
//   -define:ODIN_TEST_NAMES=main.benchmark_note_index_rb
//
package main

import rbtree "core:container/rbtree"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:testing"
import "core:time"

import pr "protocol"

benchmark_track_allocator_enabled_rb :: proc() -> bool {
	track_env, ok := os.lookup_env_alloc("BENCH_NOTE_INDEX_TRACK_ALLOC", context.allocator)
	if !ok do return false
	defer delete(track_env)
	return track_env != "0" && track_env != "false" && track_env != "FALSE" && track_env != "no" && track_env != "NO"
}

BENCH_RB_NOTE_COUNT :: 10_000_000
BENCH_RB_UPDATE_COUNT :: 1_500_000
BENCH_RB_DELETE_COUNT :: 30_000
BENCH_RB_PAGE_LIMIT :: 200
BENCH_RB_PAGE_COUNT :: 10_000

RBB_Counting_Allocator :: struct {
	parent:                mem.Allocator,
	compat:                mem.Compat_Allocator,
	live_bytes:            u64,
	peak_live_bytes:       u64,
	total_allocated_bytes: u64,
	total_freed_bytes:     u64,
	alloc_calls:           u64,
	free_calls:            u64,
	resize_calls:          u64,
}

rb_bench_note_sort_key_cmp :: proc(a, b: Note_Sort_Key) -> slice.Ordering {
	if a.updated_at < b.updated_at {
		return .Less
	}
	if a.updated_at > b.updated_at {
		return .Greater
	}

	if a.asset_id < b.asset_id {
		return .Less
	}
	if a.asset_id > b.asset_id {
		return .Greater
	}

	return .Equal
}

rb_bench_note_after_cursor_desc :: proc(key: Note_Sort_Key, cursor_updated_at: i64, cursor_asset_id: pr.AssetID) -> bool {
	if key.updated_at < cursor_updated_at {
		return true
	}
	if key.updated_at > cursor_updated_at {
		return false
	}
	return key.asset_id < cursor_asset_id
}

rb_bench_rng_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1
	return state^
}

rb_bench_counting_allocator_init :: proc(ca: ^RBB_Counting_Allocator, parent := context.allocator) {
	ca.parent = parent
	mem.compat_allocator_init(&ca.compat, rb_bench_counting_allocator_raw(ca))
}

rb_bench_counting_allocator :: proc(ca: ^RBB_Counting_Allocator) -> mem.Allocator {
	return mem.compat_allocator(&ca.compat)
}

rb_bench_counting_allocator_raw :: proc(ca: ^RBB_Counting_Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = rb_bench_counting_allocator_proc, data = ca}
}

rb_bench_counting_allocator_proc :: proc(
	allocator_data: rawptr,
	mode: mem.Allocator_Mode,
	size, alignment: int,
	old_memory: rawptr,
	old_size: int,
	location := #caller_location,
) -> (
	data: []byte,
	err: mem.Allocator_Error,
) {
	ca := (^RBB_Counting_Allocator)(allocator_data)

	switch mode {
	case .Alloc, .Alloc_Non_Zeroed:
		data, err = ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil {
			sz := u64(max(size, 0))
			ca.live_bytes += sz
			ca.total_allocated_bytes += sz
			ca.alloc_calls += 1
			if ca.live_bytes > ca.peak_live_bytes {
				ca.peak_live_bytes = ca.live_bytes
			}
		}
		return

	case .Free:
		_, err = ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil {
			old_sz := u64(max(old_size, 0))
			if old_sz > ca.live_bytes {
				ca.live_bytes = 0
			} else {
				ca.live_bytes -= old_sz
			}
			ca.total_freed_bytes += old_sz
			ca.free_calls += 1
		}
		return nil, err

	case .Resize, .Resize_Non_Zeroed:
		data, err = ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil {
			new_sz := u64(max(size, 0))
			old_sz := u64(max(old_size, 0))
			if new_sz >= old_sz {
				delta := new_sz - old_sz
				ca.live_bytes += delta
				ca.total_allocated_bytes += delta
			} else {
				delta := old_sz - new_sz
				if delta > ca.live_bytes {
					ca.live_bytes = 0
				} else {
					ca.live_bytes -= delta
				}
				ca.total_freed_bytes += delta
			}
			ca.resize_calls += 1
			if ca.live_bytes > ca.peak_live_bytes {
				ca.peak_live_bytes = ca.live_bytes
			}
		}
		return

	case .Free_All:
		_, err = ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
		if err == nil {
			ca.total_freed_bytes += ca.live_bytes
			ca.live_bytes = 0
		}
		return nil, err

	case .Query_Features, .Query_Info:
		return ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
	}

	return ca.parent.procedure(ca.parent.data, mode, size, alignment, old_memory, old_size, location)
}

rb_bench_log_memory_snapshot :: proc(label: string, baseline_rss_mb: u32, node_count: int, node_size_bytes: int) {
	rss_mb := get_rss_memory_mb()
	rss_delta_mb := i64(rss_mb) - i64(baseline_rss_mb)
	est_node_bytes := u64(node_count) * u64(node_size_bytes)
	est_node_mb := f64(est_node_bytes) / (1024.0 * 1024.0)

	log.infof("%s Memory: RSS=%d MB (delta=%d MB), node_est=%.2f MB (%d x %dB)", label, rss_mb, rss_delta_mb, est_node_mb, node_count, node_size_bytes)
}

rb_bench_log_allocator_snapshot :: proc(label: string, ca: ^RBB_Counting_Allocator) {
	live_mb := f64(ca.live_bytes) / (1024.0 * 1024.0)
	peak_mb := f64(ca.peak_live_bytes) / (1024.0 * 1024.0)
	total_mb := f64(ca.total_allocated_bytes) / (1024.0 * 1024.0)

	log.infof(
		"%s Allocator: live=%.2f MB peak=%.2f MB total=%.2f MB alloc=%d free=%d resize=%d",
		label,
		live_mb,
		peak_mb,
		total_mb,
		ca.alloc_calls,
		ca.free_calls,
		ca.resize_calls,
	)
}

@(test)
benchmark_note_index_rb :: proc(t: ^testing.T) {
	env, ok := os.lookup_env_alloc("BENCH_NOTE_INDEX_RB", context.allocator)
	defer delete(env)

	if !ok {
		log.infof("Skipping note index RB benchmark (set BENCH_NOTE_INDEX_RB=1 to run)")
		return
	}
	note_count := btree_bench_env_int("BENCH_NOTE_INDEX_NOTES", BENCH_RB_NOTE_COUNT)
	update_count := btree_bench_env_int("BENCH_NOTE_INDEX_UPDATES", BENCH_RB_UPDATE_COUNT)
	delete_count := btree_bench_env_int("BENCH_NOTE_INDEX_DELETES", BENCH_RB_DELETE_COUNT)
	page_limit := btree_bench_env_int("BENCH_NOTE_INDEX_PAGE_LIMIT", BENCH_RB_PAGE_LIMIT)
	page_count := btree_bench_env_int("BENCH_NOTE_INDEX_PAGES", BENCH_RB_PAGE_COUNT)

	tree := rbtree.Tree(Note_Sort_Key, bool){}
	track_allocator := benchmark_track_allocator_enabled_rb()
	node_counter := RBB_Counting_Allocator{}
	if track_allocator {
		rb_bench_counting_allocator_init(&node_counter)
		rbtree.init_cmp(&tree, rb_bench_note_sort_key_cmp, rb_bench_counting_allocator(&node_counter))
	} else {
		rbtree.init_cmp(&tree, rb_bench_note_sort_key_cmp)
	}
	defer rbtree.destroy(&tree, false)

	baseline_rss_mb := get_rss_memory_mb()
	node_size_bytes := size_of(rbtree.Node(Note_Sort_Key, bool))

	keys_by_id := make(map[pr.AssetID]Note_Sort_Key, note_count)
	defer delete(keys_by_id)

	log.infof("=== Note Index RB Benchmark ===")
	log.infof("Tracking allocator: %v (set BENCH_NOTE_INDEX_TRACK_ALLOC=1 for a separate allocation run)", track_allocator)
	log.infof("Notes=%d, Updates=%d, Deletes=%d, PageLimit=%d, Pages=%d", note_count, update_count, delete_count, page_limit, page_count)

	// --------------------------------------------------------------------
	// Phase 0: Random-key insert throughput (standalone tree)
	// --------------------------------------------------------------------
	random_tree := rbtree.Tree(Note_Sort_Key, bool){}
	random_counter := RBB_Counting_Allocator{}
	if track_allocator {
		rb_bench_counting_allocator_init(&random_counter)
		rbtree.init_cmp(&random_tree, rb_bench_note_sort_key_cmp, rb_bench_counting_allocator(&random_counter))
	} else {
		rbtree.init_cmp(&random_tree, rb_bench_note_sort_key_cmp)
	}

	random_insert_rng_state := u64(0x243f6a8885a308d3)
	random_insert_succeeded := 0
	random_insert_start := time.now()
	for i := 0; i < note_count; i += 1 {
		asset_id := pr.AssetID(i + 1)
		key := Note_Sort_Key {
			updated_at = i64(rb_bench_rng_next(&random_insert_rng_state) >> 1),
			asset_id   = asset_id,
		}

		_, _, err := rbtree.find_or_insert(&random_tree, key, true)
		if err == nil do random_insert_succeeded += 1
	}
	random_insert_seconds := time.duration_seconds(time.since(random_insert_start))
	if track_allocator do rb_bench_log_allocator_snapshot("RB Random Insert", &random_counter)
	rbtree.destroy(&random_tree, false)
	testing.expect_value(t, random_insert_succeeded, note_count)
	if random_insert_succeeded != note_count do return

	// --------------------------------------------------------------------
	// Phase 1: Insert notes
	// --------------------------------------------------------------------
	insert_succeeded := 0
	insert_start := time.now()
	for i := 0; i < note_count; i += 1 {
		asset_id := pr.AssetID(i + 1)
		key := Note_Sort_Key {
			updated_at = i64(i + 1),
			asset_id   = asset_id,
		}

		_, _, err := rbtree.find_or_insert(&tree, key, true)
		if err == nil do insert_succeeded += 1
	}
	insert_seconds := time.duration_seconds(time.since(insert_start))
	testing.expect_value(t, insert_succeeded, note_count)
	if insert_succeeded != note_count do return
	for i in 0 ..< note_count {
		asset_id := pr.AssetID(i + 1)
		keys_by_id[asset_id] = {
			updated_at = i64(i + 1),
			asset_id   = asset_id,
		}
	}
	rb_bench_log_memory_snapshot("RB After Insert", baseline_rss_mb, rbtree.len(tree), node_size_bytes)
	if track_allocator {
		rb_bench_log_allocator_snapshot("RB After Insert", &node_counter)
	}

	// --------------------------------------------------------------------
	// Phase 2: Random updates (remove+insert with newer timestamps)
	// --------------------------------------------------------------------
	rng_state := u64(0x9e3779b97f4a7c15)
	now_tick := i64(note_count + 1)

	updates_succeeded := 0
	update_start := time.now()
	for i := 0; i < update_count; i += 1 {
		picked := int(rb_bench_rng_next(&rng_state) % u64(note_count)) + 1
		asset_id := pr.AssetID(picked)

		old_key, has_old := keys_by_id[asset_id]
		if !has_old do break
		removed := rbtree.remove_key(&tree, old_key, false)
		if !removed do break

		now_tick += 1
		new_key := Note_Sort_Key {
			updated_at = now_tick,
			asset_id   = asset_id,
		}

		_, _, err := rbtree.find_or_insert(&tree, new_key, true)
		if err != nil do break
		keys_by_id[asset_id] = new_key
		updates_succeeded += 1
	}
	update_seconds := time.duration_seconds(time.since(update_start))
	testing.expect_value(t, updates_succeeded, update_count)
	if updates_succeeded != update_count do return
	rb_bench_log_memory_snapshot("RB After Update", baseline_rss_mb, rbtree.len(tree), node_size_bytes)
	if track_allocator {
		rb_bench_log_allocator_snapshot("RB After Update", &node_counter)
	}

	// --------------------------------------------------------------------
	// Phase 3: Paged listing (matches current cursor-seek behavior)
	// --------------------------------------------------------------------
	page_start := time.now()

	has_cursor := false
	cursor_updated_at: i64 = 0
	cursor_asset_id: pr.AssetID = 0
	rows_seen := 0

	for page := 0; page < page_count; page += 1 {
		page_rows := 0
		next_cursor_updated_at: i64 = 0
		next_cursor_asset_id: pr.AssetID = 0

		it: rbtree.Iterator(Note_Sort_Key, bool)
		if has_cursor {
			cursor_key := Note_Sort_Key {
				updated_at = cursor_updated_at,
				asset_id   = cursor_asset_id,
			}
			cursor_node := rbtree.find(tree, cursor_key)
			if cursor_node != nil {
				it = rbtree.iterator_from_pos(&tree, cursor_node, .Backward)
				_, _ = rbtree.iterator_next(&it) // skip cursor item itself
			} else {
				it = rbtree.iterator(&tree, .Backward)
			}
		} else {
			it = rbtree.iterator(&tree, .Backward)
		}

		for {
			node, has_next := rbtree.iterator_next(&it)
			if !has_next {
				break
			}

			key := node.key

			if has_cursor && !rb_bench_note_after_cursor_desc(key, cursor_updated_at, cursor_asset_id) {
				continue
			}

			if page_rows < page_limit {
				page_rows += 1
				rows_seen += 1
				next_cursor_updated_at = key.updated_at
				next_cursor_asset_id = key.asset_id
				continue
			}

			break
		}

		if page_rows == 0 {
			break
		}

		has_cursor = true
		cursor_updated_at = next_cursor_updated_at
		cursor_asset_id = next_cursor_asset_id
	}

	page_seconds := time.duration_seconds(time.since(page_start))

	// --------------------------------------------------------------------
	// Phase 4: Random deletes
	// --------------------------------------------------------------------
	delete_start := time.now()
	deleted := 0
	for deleted < delete_count {
		picked := int(rb_bench_rng_next(&rng_state) % u64(note_count)) + 1
		asset_id := pr.AssetID(picked)

		key, has_key := keys_by_id[asset_id]
		if !has_key {
			continue
		}

		removed := rbtree.remove_key(&tree, key, false)
		if !removed do break
		delete_key(&keys_by_id, asset_id)
		deleted += 1
	}
	delete_seconds := time.duration_seconds(time.since(delete_start))
	testing.expect_value(t, deleted, delete_count)
	if deleted != delete_count do return
	rb_bench_log_memory_snapshot("RB After Delete", baseline_rss_mb, rbtree.len(tree), node_size_bytes)
	if track_allocator {
		rb_bench_log_allocator_snapshot("RB After Delete", &node_counter)
	}

	// Basic integrity check: count iterator nodes == map size
	tree_count := 0
	it := rbtree.iterator(&tree, .Forward)
	for {
		_, has_next := rbtree.iterator_next(&it)
		if !has_next {
			break
		}
		tree_count += 1
	}
	testing.expect_value(t, tree_count, len(keys_by_id))
	testing.expect_value(t, tree_count, rbtree.len(tree))

	// Summary
	random_insert_rate := f64(note_count) / random_insert_seconds
	insert_rate := f64(note_count) / insert_seconds
	update_rate := f64(update_count) / update_seconds
	delete_rate := f64(delete_count) / delete_seconds
	page_rate := f64(rows_seen) / page_seconds

	log.infof("Insert (random keys):     %s (%.0f ops/s)", fmt.tprintf("%.3fs", random_insert_seconds), random_insert_rate)
	log.infof("Insert:  %s (%.0f ops/s)", fmt.tprintf("%.3fs", insert_seconds), insert_rate)
	log.infof("Update:  %s (%.0f ops/s, remove+insert)", fmt.tprintf("%.3fs", update_seconds), update_rate)
	log.infof("Paging:  %s (%d rows returned, %.0f rows/s)", fmt.tprintf("%.3fs", page_seconds), rows_seen, page_rate)
	log.infof("Delete:  %s (%.0f ops/s)", fmt.tprintf("%.3fs", delete_seconds), delete_rate)
	log.infof("Final tree size: %d", tree_count)
}
