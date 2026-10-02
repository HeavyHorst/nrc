//
// note_index_btree_benchmark.odin - Note Secondary Index tidwall-style B-Tree Benchmark
//
// Benchmarks note index operations using local btree package:
// - Insert notes keyed by (updated_at, asset_id)
// - Update notes via remove+insert (updated_at changes)
// - Paginate newest-first via cursor seek + reverse iterator
//
// Run with: BENCH_NOTE_INDEX_BTREE=1 odin test . -o:speed \
//   -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 \
//   -define:ODIN_TEST_NAMES=main.benchmark_note_index_btree
//
package main

import "btree"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:testing"
import "core:time"

import pr "protocol"

benchmark_track_allocator_enabled_btree :: proc() -> bool {
	track_env, ok := os.lookup_env_alloc("BENCH_NOTE_INDEX_TRACK_ALLOC", context.allocator)
	if !ok do return false
	defer delete(track_env)
	return track_env != "0" && track_env != "false" && track_env != "FALSE" && track_env != "no" && track_env != "NO"
}

BENCH_BTREE_NOTE_COUNT :: 10_000_000
BENCH_BTREE_UPDATE_COUNT :: 1_500_000
BENCH_BTREE_DELETE_COUNT :: 30_000
BENCH_BTREE_PAGE_LIMIT :: 200
BENCH_BTREE_PAGE_COUNT :: 10_000
BENCH_BTREE_DEFAULT_DEGREE :: 32

BTB_Counting_Allocator :: struct {
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

btree_bench_note_sort_key_cmp :: proc(a, b: Note_Sort_Key) -> slice.Ordering {
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

btree_bench_note_sort_key_compare :: proc(a, b: Note_Sort_Key) -> int {
	cmp := btree_bench_note_sort_key_cmp(a, b)
	if cmp == .Less {
		return -1
	}
	if cmp == .Greater {
		return 1
	}
	return 0
}

btree_bench_note_after_cursor_desc :: proc(key: Note_Sort_Key, cursor_updated_at: i64, cursor_asset_id: pr.AssetID) -> bool {
	if key.updated_at < cursor_updated_at {
		return true
	}
	if key.updated_at > cursor_updated_at {
		return false
	}
	return key.asset_id < cursor_asset_id
}

btree_bench_rng_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1
	return state^
}

btree_bench_env_int :: proc(name: string, fallback: int) -> int {
	env, ok := os.lookup_env_alloc(name, context.allocator)
	if !ok {
		return fallback
	}
	defer delete(env)

	v, parse_ok := strconv.parse_int(env)
	if !parse_ok || v <= 0 {
		return fallback
	}

	return int(v)
}

btree_bench_env_bool :: proc(name: string) -> bool {
	env, ok := os.lookup_env_alloc(name, context.allocator)
	if !ok {
		return false
	}
	defer delete(env)

	if env == "0" || env == "false" || env == "FALSE" || env == "no" || env == "NO" {
		return false
	}

	return true
}

btree_bench_set_with_optional_hint :: proc(
	tr: ^btree.BTreeG(Note_Sort_Key),
	key: Note_Sort_Key,
	use_hints: bool,
	hint: ^btree.Path_Hint,
) -> (
	prev: Note_Sort_Key,
	replaced: bool,
) {
	if use_hints {
		return btree.set_hint(tr, key, hint)
	}
	return btree.set(tr, key)
}

btree_bench_remove_with_optional_hint :: proc(
	tr: ^btree.BTreeG(Note_Sort_Key),
	key: Note_Sort_Key,
	use_hints: bool,
	hint: ^btree.Path_Hint,
) -> (
	prev: Note_Sort_Key,
	removed: bool,
) {
	if use_hints {
		return btree.remove_hint(tr, key, hint)
	}
	return btree.remove(tr, key)
}

btree_bench_iter_seek_with_optional_hint :: proc(it: ^btree.IterG(Note_Sort_Key), key: Note_Sort_Key, use_hints: bool, hint: ^btree.Path_Hint) -> bool {
	if use_hints {
		return btree.iter_seek_hint(it, key, hint)
	}
	return btree.iter_seek(it, key)
}

btree_bench_counting_allocator_init :: proc(ca: ^BTB_Counting_Allocator, parent := context.allocator) {
	ca.parent = parent
	mem.compat_allocator_init(&ca.compat, btree_bench_counting_allocator_raw(ca))
}

btree_bench_counting_allocator :: proc(ca: ^BTB_Counting_Allocator) -> mem.Allocator {
	return mem.compat_allocator(&ca.compat)
}

btree_bench_counting_allocator_raw :: proc(ca: ^BTB_Counting_Allocator) -> mem.Allocator {
	return mem.Allocator{procedure = btree_bench_counting_allocator_proc, data = ca}
}

btree_bench_counting_allocator_proc :: proc(
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
	ca := (^BTB_Counting_Allocator)(allocator_data)

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

btree_bench_log_memory_snapshot :: proc(label: string, baseline_rss_mb: u32, node_count: int, key_size_bytes: int) {
	rss_mb := get_rss_memory_mb()
	rss_delta_mb := i64(rss_mb) - i64(baseline_rss_mb)
	est_node_bytes := u64(node_count) * u64(key_size_bytes)
	est_node_mb := f64(est_node_bytes) / (1024.0 * 1024.0)

	log.infof("%s Memory: RSS=%d MB (delta=%d MB), key_est=%.2f MB (%d x %dB)", label, rss_mb, rss_delta_mb, est_node_mb, node_count, key_size_bytes)
}

btree_bench_log_allocator_snapshot :: proc(label: string, ca: ^BTB_Counting_Allocator) {
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

btree_bench_log_structure_snapshot :: proc(label: string, tr: ^btree.BTreeG(Note_Sort_Key)) {
	stats := btree.stats(tr)
	log.infof(
		"%s Structure: split=%d rebalance=%d merge=%d borrow_left=%d borrow_right=%d",
		label,
		stats.split_count,
		stats.rebalance_count,
		stats.merge_count,
		stats.borrow_left_count,
		stats.borrow_right_count,
	)
}

@(test)
benchmark_note_index_btree :: proc(t: ^testing.T) {
	env, ok := os.lookup_env_alloc("BENCH_NOTE_INDEX_BTREE", context.allocator)
	defer delete(env)

	if !ok {
		log.infof("Skipping note index BTree benchmark (set BENCH_NOTE_INDEX_BTREE=1 to run)")
		return
	}

	note_count := btree_bench_env_int("BENCH_NOTE_INDEX_NOTES", btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_NOTES", BENCH_BTREE_NOTE_COUNT))
	update_count := btree_bench_env_int("BENCH_NOTE_INDEX_UPDATES", btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_UPDATES", BENCH_BTREE_UPDATE_COUNT))
	delete_count := btree_bench_env_int("BENCH_NOTE_INDEX_DELETES", btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_DELETES", BENCH_BTREE_DELETE_COUNT))
	page_limit := btree_bench_env_int("BENCH_NOTE_INDEX_PAGE_LIMIT", btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_PAGE_LIMIT", BENCH_BTREE_PAGE_LIMIT))
	page_count := btree_bench_env_int("BENCH_NOTE_INDEX_PAGES", btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_PAGES", BENCH_BTREE_PAGE_COUNT))
	degree := btree_bench_env_int("BENCH_NOTE_INDEX_BTREE_DEGREE", BENCH_BTREE_DEFAULT_DEGREE)
	use_hints := btree_bench_env_bool("BENCH_NOTE_INDEX_BTREE_HINTS")
	use_load := btree_bench_env_bool("BENCH_NOTE_INDEX_BTREE_LOAD")

	track_allocator := benchmark_track_allocator_enabled_btree()
	node_counter := BTB_Counting_Allocator{}

	allocator := context.allocator
	if track_allocator {
		btree_bench_counting_allocator_init(&node_counter)
		allocator = btree_bench_counting_allocator(&node_counter)
	}

	tree := btree.create(Note_Sort_Key, btree_bench_note_sort_key_compare, btree.Options{degree = degree}, allocator)
	defer btree.destroy(&tree)

	baseline_rss_mb := get_rss_memory_mb()
	key_size_bytes := size_of(Note_Sort_Key)

	keys_by_id := make(map[pr.AssetID]Note_Sort_Key, note_count)
	defer delete(keys_by_id)

	log.infof("=== Note Index BTree Benchmark ===")
	log.infof("Tracking allocator: %v (set BENCH_NOTE_INDEX_TRACK_ALLOC=1 for a separate allocation run)", track_allocator)
	log.infof("Hint mode: %v (set BENCH_NOTE_INDEX_BTREE_HINTS=1 to enable)", use_hints)
	log.infof("Load mode: %v (set BENCH_NOTE_INDEX_BTREE_LOAD=1 for presorted insert phase)", use_load)
	log.infof("Notes=%d, Updates=%d, Deletes=%d, PageLimit=%d, Pages=%d, Degree=%d", note_count, update_count, delete_count, page_limit, page_count, degree)

	random_counter := BTB_Counting_Allocator{}
	random_allocator := context.allocator
	if track_allocator {
		btree_bench_counting_allocator_init(&random_counter)
		random_allocator = btree_bench_counting_allocator(&random_counter)
	}
	random_tree := btree.create(Note_Sort_Key, btree_bench_note_sort_key_compare, btree.Options{degree = degree}, random_allocator)
	random_insert_hint := btree.Path_Hint{}
	random_insert_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		random_insert_hint_ptr = &random_insert_hint
	}

	random_insert_rng_state := u64(0x243f6a8885a308d3)
	random_insert_replaced := 0
	random_insert_start := time.now()
	for i := 0; i < note_count; i += 1 {
		asset_id := pr.AssetID(i + 1)
		key := Note_Sort_Key {
			updated_at = i64(btree_bench_rng_next(&random_insert_rng_state) >> 1),
			asset_id   = asset_id,
		}

		_, replaced := btree_bench_set_with_optional_hint(&random_tree, key, use_hints, random_insert_hint_ptr)
		if replaced do random_insert_replaced += 1
	}
	random_insert_seconds := time.duration_seconds(time.since(random_insert_start))
	if track_allocator do btree_bench_log_allocator_snapshot("BTree Random Insert", &random_counter)
	btree.destroy(&random_tree)
	testing.expect_value(t, random_insert_replaced, 0)
	if random_insert_replaced != 0 do return

	btree.reset_stats(&tree)

	insert_hint := btree.Path_Hint{}
	insert_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		insert_hint_ptr = &insert_hint
	}

	insert_replaced := 0
	insert_start := time.now()
	for i := 0; i < note_count; i += 1 {
		asset_id := pr.AssetID(i + 1)
		key := Note_Sort_Key {
			updated_at = i64(i + 1),
			asset_id   = asset_id,
		}

		replaced := false
		if use_load {
			_, replaced = btree.load(&tree, key)
		} else {
			_, replaced = btree_bench_set_with_optional_hint(&tree, key, use_hints, insert_hint_ptr)
		}
		if replaced do insert_replaced += 1
	}
	insert_seconds := time.duration_seconds(time.since(insert_start))
	testing.expect_value(t, insert_replaced, 0)
	if insert_replaced != 0 do return
	for i in 0 ..< note_count {
		asset_id := pr.AssetID(i + 1)
		keys_by_id[asset_id] = {
			updated_at = i64(i + 1),
			asset_id   = asset_id,
		}
	}
	btree_bench_log_memory_snapshot("BTree After Insert", baseline_rss_mb, btree.count(&tree), key_size_bytes)
	btree_bench_log_structure_snapshot("BTree After Insert", &tree)
	if track_allocator {
		btree_bench_log_allocator_snapshot("BTree After Insert", &node_counter)
	}
	btree.reset_stats(&tree)

	rng_state := u64(0x9e3779b97f4a7c15)
	now_tick := i64(note_count + 1)
	update_remove_hint := btree.Path_Hint{}
	update_remove_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		update_remove_hint_ptr = &update_remove_hint
	}
	update_insert_hint := btree.Path_Hint{}
	update_insert_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		update_insert_hint_ptr = &update_insert_hint
	}

	updates_succeeded := 0
	update_start := time.now()
	for i := 0; i < update_count; i += 1 {
		picked := int(btree_bench_rng_next(&rng_state) % u64(note_count)) + 1
		asset_id := pr.AssetID(picked)

		old_key, has_old := keys_by_id[asset_id]
		if !has_old do break
		_, removed := btree_bench_remove_with_optional_hint(&tree, old_key, use_hints, update_remove_hint_ptr)
		if !removed do break

		now_tick += 1
		new_key := Note_Sort_Key {
			updated_at = now_tick,
			asset_id   = asset_id,
		}

		_, replaced := btree_bench_set_with_optional_hint(&tree, new_key, use_hints, update_insert_hint_ptr)
		if replaced do break
		keys_by_id[asset_id] = new_key
		updates_succeeded += 1
	}
	update_seconds := time.duration_seconds(time.since(update_start))
	testing.expect_value(t, updates_succeeded, update_count)
	if updates_succeeded != update_count do return
	btree_bench_log_memory_snapshot("BTree After Update", baseline_rss_mb, btree.count(&tree), key_size_bytes)
	btree_bench_log_structure_snapshot("BTree After Update", &tree)
	if track_allocator {
		btree_bench_log_allocator_snapshot("BTree After Update", &node_counter)
	}
	btree.reset_stats(&tree)

	page_start := time.now()

	has_cursor := false
	cursor_updated_at: i64 = 0
	cursor_asset_id: pr.AssetID = 0
	rows_seen := 0
	seek_hint := btree.Path_Hint{}
	seek_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		seek_hint_ptr = &seek_hint
	}

	it := btree.iter(&tree)
	defer btree.iter_destroy(&it)

	for page := 0; page < page_count; page += 1 {
		page_rows := 0
		has_more := false
		next_cursor_updated_at: i64 = 0
		next_cursor_asset_id: pr.AssetID = 0

		has_item := false
		if has_cursor {
			cursor_key := Note_Sort_Key {
				updated_at = cursor_updated_at,
				asset_id   = cursor_asset_id,
			}
			if current_key, ok2 := keys_by_id[cursor_asset_id]; ok2 {
				cursor_key = current_key
			}

			has_item = btree_bench_iter_seek_with_optional_hint(&it, cursor_key, use_hints, seek_hint_ptr)
			if has_item {
				cmp := btree_bench_note_sort_key_cmp(btree.item(&it), cursor_key)
				if cmp == .Equal || cmp == .Greater {
					has_item = btree.iter_prev(&it)
				}
			} else {
				has_item = btree.iter_last(&it)
			}
		} else {
			has_item = btree.iter_last(&it)
		}

		for has_item {
			key := btree.item(&it)

			if has_cursor && !btree_bench_note_after_cursor_desc(key, cursor_updated_at, cursor_asset_id) {
				has_item = btree.iter_prev(&it)
				continue
			}

			if page_rows < page_limit {
				page_rows += 1
				rows_seen += 1
				next_cursor_updated_at = key.updated_at
				next_cursor_asset_id = key.asset_id
				has_item = btree.iter_prev(&it)
				continue
			}

			has_more = true
			break
		}

		if page_rows == 0 {
			break
		}

		has_cursor = true
		cursor_updated_at = next_cursor_updated_at
		cursor_asset_id = next_cursor_asset_id

		if !has_more {
			break
		}
	}

	page_seconds := time.duration_seconds(time.since(page_start))

	delete_start := time.now()
	deleted := 0
	delete_hint := btree.Path_Hint{}
	delete_hint_ptr: ^btree.Path_Hint = nil
	if use_hints {
		delete_hint_ptr = &delete_hint
	}
	for deleted < delete_count {
		picked := int(btree_bench_rng_next(&rng_state) % u64(note_count)) + 1
		asset_id := pr.AssetID(picked)

		key, has_key := keys_by_id[asset_id]
		if !has_key {
			continue
		}

		_, removed := btree_bench_remove_with_optional_hint(&tree, key, use_hints, delete_hint_ptr)
		if !removed do break
		delete_key(&keys_by_id, asset_id)
		deleted += 1
	}
	delete_seconds := time.duration_seconds(time.since(delete_start))
	testing.expect_value(t, deleted, delete_count)
	if deleted != delete_count do return
	btree_bench_log_memory_snapshot("BTree After Delete", baseline_rss_mb, btree.count(&tree), key_size_bytes)
	btree_bench_log_structure_snapshot("BTree After Delete", &tree)
	if track_allocator {
		btree_bench_log_allocator_snapshot("BTree After Delete", &node_counter)
	}

	tree_count := 0
	count_it := btree.iter(&tree)
	defer btree.iter_destroy(&count_it)
	has_item := btree.iter_first(&count_it)
	for has_item {
		tree_count += 1
		has_item = btree.iter_next(&count_it)
	}

	testing.expect_value(t, tree_count, len(keys_by_id))
	testing.expect_value(t, tree_count, btree.count(&tree))

	insert_rate := f64(note_count) / insert_seconds
	random_insert_rate := f64(note_count) / random_insert_seconds
	update_rate := f64(update_count) / update_seconds
	delete_rate := f64(delete_count) / delete_seconds
	page_rate := f64(rows_seen) / page_seconds

	if use_hints {
		log.infof("Mode: hinted")
	} else {
		log.infof("Mode: no-hint")
	}
	if use_load {
		log.infof("Sequential insert path: load")
	} else {
		log.infof("Sequential insert path: set")
	}
	log.infof("Insert (random keys):     %s (%.0f ops/s)", fmt.tprintf("%.3fs", random_insert_seconds), random_insert_rate)
	log.infof("Insert:  %s (%.0f ops/s)", fmt.tprintf("%.3fs", insert_seconds), insert_rate)
	log.infof("Update:  %s (%.0f ops/s, remove+insert)", fmt.tprintf("%.3fs", update_seconds), update_rate)
	log.infof("Paging:  %s (%d rows returned, %.0f rows/s)", fmt.tprintf("%.3fs", page_seconds), rows_seen, page_rate)
	log.infof("Delete:  %s (%.0f ops/s)", fmt.tprintf("%.3fs", delete_seconds), delete_rate)
	log.infof("Final tree size: %d", tree_count)
}
