//
// btree_benchmark.odin - Core B-Tree microbenchmarks
//
// Focuses on pure tree operation costs (no external model/map bookkeeping).
//
// Run with:
//   odin run bench -o:speed
//
package btree

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:time"

BENCH_BTREE_PKG_DEFAULT_COUNT :: 1_000_000
BENCH_BTREE_PKG_DEFAULT_DEGREE :: 32
BENCH_BTREE_PKG_DEFAULT_SEEK_WINDOW :: 16
BENCH_BTREE_PKG_DEFAULT_SCAN_ROUNDS :: 1
BENCH_BTREE_PKG_KEY_SPACE :: u64(10_000_000_000_000_000)

BTB_Item :: struct {
	key: string,
	val: i64,
}

BTB_U64_Item :: struct {
	key: u64,
	val: i64,
}

BTB_Int_Item :: struct {
	key: int,
}

btree_pkg_bench_less_item :: proc(a, b: BTB_Item) -> bool {
	return a.key < b.key
}

btree_pkg_bench_cmp_item :: proc(a, b: BTB_Item) -> int {
	if a.key < b.key {
		return -1
	}
	if a.key > b.key {
		return 1
	}
	return 0
}

btree_pkg_bench_less_u64_item :: proc(a, b: BTB_U64_Item) -> bool {
	return a.key < b.key
}

btree_pkg_bench_cmp_u64_item :: proc(a, b: BTB_U64_Item) -> int {
	if a.key < b.key {
		return -1
	}
	if a.key > b.key {
		return 1
	}
	return 0
}

btree_pkg_bench_less_int_item :: proc(a, b: BTB_Int_Item) -> bool {
	return a.key < b.key
}

btree_pkg_bench_cmp_int_item :: proc(a, b: BTB_Int_Item) -> int {
	if a.key < b.key {
		return -1
	}
	if a.key > b.key {
		return 1
	}
	return 0
}

btree_pkg_bench_cmp_i32 :: proc(a, b: i32) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

btree_pkg_bench_cmp_u32 :: proc(a, b: u32) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

btree_pkg_bench_rng_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1
	return state^
}

btree_pkg_bench_shuffle_items :: proc(items: []BTB_Item, seed: ^u64) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := int(btree_pkg_bench_rng_next(seed) % u64(i + 1))
		items[i], items[j] = items[j], items[i]
	}
}

btree_pkg_bench_shuffle_u64_items :: proc(items: []BTB_U64_Item, seed: ^u64) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := int(btree_pkg_bench_rng_next(seed) % u64(i + 1))
		items[i], items[j] = items[j], items[i]
	}
}

btree_pkg_bench_env_int :: proc(name: string, fallback: int) -> int {
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

btree_pkg_bench_log_rate :: proc(label: string, op_count: int, elapsed_seconds: f64) {
	rate := f64(op_count) / elapsed_seconds
	fmt.println(fmt.tprintf("%-20s %.3fs (%.0f ops/s)", fmt.tprintf("%s:", label), elapsed_seconds, rate))
}

btree_pkg_bench_log_seek_window :: proc(label: string, seek_count, visited_count: int, elapsed_seconds: f64) {
	seek_rate := f64(seek_count) / elapsed_seconds
	visited_rate := f64(visited_count) / elapsed_seconds
	fmt.println(
		fmt.tprintf(
			"%-36s %.3fs (%d seeks, %.0f seeks/s; %d visited, %.0f items/s)",
			fmt.tprintf("%s:", label),
			elapsed_seconds,
			seek_count,
			seek_rate,
			visited_count,
			visited_rate,
		),
	)
}

btree_pkg_bench_log_cstyle :: proc(label: string, op_count: int, elapsed_seconds: f64) {
	ns_per_op := elapsed_seconds * 1e9 / f64(op_count)
	rate := f64(op_count) / elapsed_seconds
	fmt.println(fmt.tprintf("%-14s %d ops in %.3f secs %.1f ns/op %.0f op/sec", label, op_count, elapsed_seconds, ns_per_op, rate))
}

btree_pkg_bench_assert :: proc(ok: bool, message: string) {
	if !ok {
		panic(message)
	}
}

btree_pkg_bench_assert_eq_int :: proc(got, want: int, message: string) {
	if got != want {
		panic(fmt.tprintf("%s (got=%d want=%d)", message, got, want))
	}
}

btree_pkg_bench_assert_eq_i64 :: proc(got, want: i64, message: string) {
	if got != want {
		panic(fmt.tprintf("%s (got=%d want=%d)", message, got, want))
	}
}

btree_pkg_bench_assert_eq_u64 :: proc(got, want: u64, message: string) {
	if got != want {
		panic(fmt.tprintf("%s (got=%d want=%d)", message, got, want))
	}
}

btree_pkg_bench_assert_eq_u32 :: proc(got, want: u32, message: string) {
	if got != want {
		panic(fmt.tprintf("%s (got=%d want=%d)", message, got, want))
	}
}

btree_pkg_bench_assert_eq_string :: proc(got, want: string, message: string) {
	if got != want {
		panic(fmt.tprintf("%s (got=%q want=%q)", message, got, want))
	}
}

@(thread_local)
btree_pkg_bench_scan_counter: int
@(thread_local)
btree_pkg_bench_scan_sum: i64
@(thread_local)
btree_pkg_bench_u64_scan_counter: int
@(thread_local)
btree_pkg_bench_u64_scan_sum: i64
@(thread_local)
btree_pkg_bench_u32_scan_counter: int
@(thread_local)
btree_pkg_bench_u32_scan_sum: u64

btree_pkg_bench_scan_cb :: proc(item: BTB_Item) -> bool {
	btree_pkg_bench_scan_sum += item.val
	btree_pkg_bench_scan_counter += 1
	return true
}

btree_pkg_bench_u64_scan_cb :: proc(item: BTB_U64_Item) -> bool {
	btree_pkg_bench_u64_scan_sum += item.val
	btree_pkg_bench_u64_scan_counter += 1
	return true
}

btree_pkg_bench_u32_scan_cb :: proc(item: u32) -> bool {
	btree_pkg_bench_u32_scan_sum += u64(item)
	btree_pkg_bench_u32_scan_counter += 1
	return true
}

btree_pkg_bench_u64_to_16_digit_ascii :: proc(dst: []u8, value: u64) {
	v := value
	for i := len(dst) - 1; i >= 0; i -= 1 {
		dst[i] = u8('0') + u8(v % 10)
		v /= 10
	}
}

btree_pkg_bench_make_items_random_unique :: proc(item_count: int) -> (items: [dynamic]BTB_Item, key_slab: []u8) {
	items = make([dynamic]BTB_Item, 0, item_count)
	key_slab = make([]u8, item_count * 16)
	used := make(map[u64]bool, item_count)
	defer delete(used)
	rng_state := u64(0x243f6a8885a308d3)

	for len(items) < item_count {
		key_num := btree_pkg_bench_rng_next(&rng_state) % BENCH_BTREE_PKG_KEY_SPACE
		if used[key_num] {
			continue
		}
		used[key_num] = true

		i := len(items)
		offset := i * 16
		chunk := key_slab[offset:offset + 16]
		btree_pkg_bench_u64_to_16_digit_ascii(chunk, key_num)

		append(&items, BTB_Item{key = transmute(string)chunk, val = i64(key_num)})
	}

	return
}

btree_pkg_bench_make_u64_items_random_unique :: proc(item_count: int) -> (items: [dynamic]BTB_U64_Item) {
	items = make([dynamic]BTB_U64_Item, 0, item_count)
	used := make(map[u64]bool, item_count)
	defer delete(used)
	rng_state := u64(0x243f6a8885a308d3)

	for len(items) < item_count {
		key_num := btree_pkg_bench_rng_next(&rng_state) % BENCH_BTREE_PKG_KEY_SPACE
		if used[key_num] {
			continue
		}
		used[key_num] = true

		i := len(items)
		append(&items, BTB_U64_Item{key = key_num, val = i64(key_num) + i64(i)})
	}

	return
}

btree_pkg_bench_make_int_values :: proc(item_count: int) -> [dynamic]int {
	values := make([dynamic]int, 0, item_count)
	for i := 0; i < item_count; i += 1 {
		append(&values, i)
	}
	return values
}

btree_pkg_bench_shuffle_ints :: proc(values: []int, seed: ^u64) {
	for i := len(values) - 1; i > 0; i -= 1 {
		j := int(btree_pkg_bench_rng_next(seed) % u64(i + 1))
		values[i], values[j] = values[j], values[i]
	}
}

btree_pkg_bench_make_i32_values :: proc(item_count: int) -> [dynamic]i32 {
	values := make([dynamic]i32, 0, item_count)
	for i := 0; i < item_count; i += 1 {
		append(&values, i32(i))
	}
	return values
}

btree_pkg_bench_shuffle_i32s :: proc(values: []i32, seed: ^u64) {
	for i := len(values) - 1; i > 0; i -= 1 {
		j := int(btree_pkg_bench_rng_next(seed) % u64(i + 1))
		values[i], values[j] = values[j], values[i]
	}
}

btree_pkg_bench_make_u32_values :: proc(item_count: int) -> [dynamic]u32 {
	values := make([dynamic]u32, 0, item_count)
	for i := 0; i < item_count; i += 1 {
		append(&values, u32(i))
	}
	return values
}

btree_pkg_bench_shuffle_u32s :: proc(values: []u32, seed: ^u64) {
	for i := len(values) - 1; i > 0; i -= 1 {
		j := int(btree_pkg_bench_rng_next(seed) % u64(i + 1))
		values[i], values[j] = values[j], values[i]
	}
}

btree_pkg_benchmark_u32_core_ops_run :: proc(bench_count, degree, seek_window, scan_rounds: int) {
	seq_vals := btree_pkg_bench_make_u32_values(bench_count)
	defer delete(seq_vals)

	rand_vals := make([dynamic]u32, len(seq_vals))
	defer delete(rand_vals)
	copy(rand_vals[:], seq_vals[:])
	shuffle_state := u64(0x69a4_29dc)
	btree_pkg_bench_shuffle_u32s(rand_vals[:], &shuffle_state)

	fmt.println("")
	fmt.println("=== BTree U32 Key Benchmark ===")
	fmt.println(fmt.tprintf("Count=%d Degree=%d SeekWindow=%d ScanRounds=%d", bench_count, degree, seek_window, scan_rounds))

	expected_scan_sum: u64 = 0
	for v in seq_vals {
		expected_scan_sum += u64(v)
	}

	seq_set_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	seq_set_replaced := 0
	seq_set_start := time.now()
	for v in seq_vals {
		_, replaced := set(&seq_set_tree, v)
		if replaced do seq_set_replaced += 1
	}
	seq_set_seconds := time.duration_seconds(time.since(seq_set_start))
	btree_pkg_bench_assert_eq_int(seq_set_replaced, 0, "u32 sequential set should not replace")
	btree_pkg_bench_log_rate("u32-set-seq", bench_count, seq_set_seconds)
	destroy(&seq_set_tree)

	seq_set_hint_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	seq_set_hint := Path_Hint{}
	seq_set_hint_replaced := 0
	seq_set_hint_start := time.now()
	for v in seq_vals {
		_, replaced := set_hint(&seq_set_hint_tree, v, &seq_set_hint)
		if replaced do seq_set_hint_replaced += 1
	}
	seq_set_hint_seconds := time.duration_seconds(time.since(seq_set_hint_start))
	btree_pkg_bench_assert_eq_int(seq_set_hint_replaced, 0, "u32 sequential set_hint should not replace")
	btree_pkg_bench_log_rate("u32-set-seq-hint", bench_count, seq_set_hint_seconds)
	destroy(&seq_set_hint_tree)

	seq_load_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	defer destroy(&seq_load_tree)
	seq_load_replaced := 0
	seq_load_start := time.now()
	for v in seq_vals {
		_, replaced := load(&seq_load_tree, v)
		if replaced do seq_load_replaced += 1
	}
	seq_load_seconds := time.duration_seconds(time.since(seq_load_start))
	btree_pkg_bench_assert_eq_int(seq_load_replaced, 0, "u32 sequential load should not replace")
	btree_pkg_bench_log_rate("u32-load-seq", bench_count, seq_load_seconds)

	rand_set_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	rand_set_replaced := 0
	rand_set_start := time.now()
	for v in rand_vals {
		_, replaced := set(&rand_set_tree, v)
		if replaced do rand_set_replaced += 1
	}
	rand_set_seconds := time.duration_seconds(time.since(rand_set_start))
	btree_pkg_bench_assert_eq_int(rand_set_replaced, 0, "u32 random set should not replace")
	btree_pkg_bench_log_rate("u32-set-rand", bench_count, rand_set_seconds)
	destroy(&rand_set_tree)

	rand_set_hint_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	rand_set_hint := Path_Hint{}
	rand_set_hint_replaced := 0
	rand_set_hint_start := time.now()
	for v in rand_vals {
		_, replaced := set_hint(&rand_set_hint_tree, v, &rand_set_hint)
		if replaced do rand_set_hint_replaced += 1
	}
	rand_set_hint_seconds := time.duration_seconds(time.since(rand_set_hint_start))
	btree_pkg_bench_assert_eq_int(rand_set_hint_replaced, 0, "u32 random set_hint should not replace")
	btree_pkg_bench_log_rate("u32-set-rand-hint-control", bench_count, rand_set_hint_seconds)
	destroy(&rand_set_hint_tree)

	get_rand_start := time.now()
	get_rand_valid := 0
	for v in rand_vals {
		got, ok := get(&seq_load_tree, v)
		if ok && got == v do get_rand_valid += 1
	}
	get_rand_seconds := time.duration_seconds(time.since(get_rand_start))
	btree_pkg_bench_assert_eq_int(get_rand_valid, bench_count, "u32 random get result mismatch")
	btree_pkg_bench_log_rate("u32-get-rand", bench_count, get_rand_seconds)

	remove_rand_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	defer destroy(&remove_rand_tree)
	for v in seq_vals {
		_, replaced := load(&remove_rand_tree, v)
		btree_pkg_bench_assert(!replaced, "u32 remove preload should not replace")
	}
	remove_rand_start := time.now()
	remove_rand_valid := 0
	for v in rand_vals {
		prev, removed := remove(&remove_rand_tree, v)
		if removed && prev == v do remove_rand_valid += 1
	}
	remove_rand_seconds := time.duration_seconds(time.since(remove_rand_start))
	btree_pkg_bench_assert_eq_int(remove_rand_valid, bench_count, "u32 random remove result mismatch")
	btree_pkg_bench_log_rate("u32-remove-rand", bench_count, remove_rand_seconds)

	pivot_tree := create(u32, btree_pkg_bench_cmp_u32, Options{degree = degree})
	defer destroy(&pivot_tree)
	for v in seq_vals {
		_, replaced := load(&pivot_tree, v)
		btree_pkg_bench_assert(!replaced, "u32 pivot preload should not replace")
	}

	seek_window_items := 0
	pivot_it := iter(&pivot_tree)
	defer iter_destroy(&pivot_it)
	pivot_start := time.now()
	for pivot in rand_vals {
		ok := iter_seek(&pivot_it, pivot)
		if !ok {
			continue
		}
		seek_window_items += 1
		for step := 1; step < seek_window; step += 1 {
			if !iter_next(&pivot_it) {
				break
			}
			seek_window_items += 1
		}
	}
	pivot_seconds := time.duration_seconds(time.since(pivot_start))
	btree_pkg_bench_log_seek_window("u32-iter-random-seek-window", bench_count, seek_window_items, pivot_seconds)

	scan_ops := bench_count * scan_rounds
	scan_start := time.now()
	total_scan_count := 0
	total_scan_sum: u64 = 0
	for i := 0; i < scan_rounds; i += 1 {
		btree_pkg_bench_u32_scan_counter = 0
		btree_pkg_bench_u32_scan_sum = 0
		scan(&pivot_tree, btree_pkg_bench_u32_scan_cb)
		total_scan_count += btree_pkg_bench_u32_scan_counter
		total_scan_sum += btree_pkg_bench_u32_scan_sum
	}
	scan_seconds := time.duration_seconds(time.since(scan_start))
	btree_pkg_bench_assert_eq_int(total_scan_count, scan_ops, "u32 scan count mismatch")
	btree_pkg_bench_assert_eq_u64(total_scan_sum, expected_scan_sum * u64(scan_rounds), "u32 scan sum mismatch")
	btree_pkg_bench_log_rate("u32-scan", scan_ops, scan_seconds)
}

btree_pkg_bench_insert_items :: proc(tr: ^BTreeG(BTB_Item), items: []BTB_Item, use_load, use_hints: bool, hint: ^Path_Hint) {
	for item in items {
		replaced := false
		if use_load {
			_, replaced = load(tr, item)
		} else if use_hints {
			_, replaced = set_hint(tr, item, hint)
		} else {
			_, replaced = set(tr, item)
		}
		if replaced {
			panic("unexpected replace during benchmark insert")
		}
	}
}

btree_pkg_bench_insert_u64_items :: proc(tr: ^BTreeG(BTB_U64_Item), items: []BTB_U64_Item, use_load, use_hints: bool, hint: ^Path_Hint) {
	for item in items {
		replaced := false
		if use_load {
			_, replaced = load(tr, item)
		} else if use_hints {
			_, replaced = set_hint(tr, item, hint)
		} else {
			_, replaced = set(tr, item)
		}
		if replaced {
			panic("unexpected replace during u64 benchmark insert")
		}
	}
}

btree_pkg_benchmark_u64_core_ops_run :: proc(bench_count, degree, seek_window, scan_rounds: int) {
	base_items := btree_pkg_bench_make_u64_items_random_unique(bench_count)
	defer delete(base_items)

	seq_items := make([dynamic]BTB_U64_Item, len(base_items))
	defer delete(seq_items)
	copy(seq_items[:], base_items[:])
	slice.sort_by(seq_items[:], proc(a, b: BTB_U64_Item) -> bool {
		return a.key < b.key
	})

	rand_items := make([dynamic]BTB_U64_Item, len(base_items))
	defer delete(rand_items)
	copy(rand_items[:], base_items[:])
	shuffle_state := u64(0x9e3779b97f4a7c15)
	btree_pkg_bench_shuffle_u64_items(rand_items[:], &shuffle_state)

	fmt.println("=== BTree U64 Key Benchmark ===")
	fmt.println(fmt.tprintf("Count=%d Degree=%d SeekWindow=%d ScanRounds=%d", bench_count, degree, seek_window, scan_rounds))

	expected_scan_sum: i64 = 0
	for item in seq_items {
		expected_scan_sum += item.val
	}

	seq_set_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&seq_set_tree)
	seq_set_valid := true
	seq_set_start := time.now()
	for item in seq_items {
		_, replaced := set(&seq_set_tree, item)
		seq_set_valid = seq_set_valid && !replaced
	}
	seq_set_seconds := time.duration_seconds(time.since(seq_set_start))
	btree_pkg_bench_assert(seq_set_valid, "u64 sequential set should not replace")
	btree_pkg_bench_log_rate("u64-set-seq", bench_count, seq_set_seconds)

	seq_set_hint_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&seq_set_hint_tree)
	seq_set_hint := Path_Hint{}
	seq_set_hint_valid := true
	seq_set_hint_start := time.now()
	for item in seq_items {
		_, replaced := set_hint(&seq_set_hint_tree, item, &seq_set_hint)
		seq_set_hint_valid = seq_set_hint_valid && !replaced
	}
	seq_set_hint_seconds := time.duration_seconds(time.since(seq_set_hint_start))
	btree_pkg_bench_assert(seq_set_hint_valid, "u64 sequential set_hint should not replace")
	btree_pkg_bench_log_rate("u64-set-seq-hint", bench_count, seq_set_hint_seconds)

	seq_load_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&seq_load_tree)
	seq_load_valid := true
	seq_load_start := time.now()
	for item in seq_items {
		_, replaced := load(&seq_load_tree, item)
		seq_load_valid = seq_load_valid && !replaced
	}
	seq_load_seconds := time.duration_seconds(time.since(seq_load_start))
	btree_pkg_bench_assert(seq_load_valid, "u64 sequential load should not replace")
	btree_pkg_bench_log_rate("u64-load-seq", bench_count, seq_load_seconds)

	rand_set_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&rand_set_tree)
	rand_set_valid := true
	rand_set_start := time.now()
	for item in rand_items {
		_, replaced := set(&rand_set_tree, item)
		rand_set_valid = rand_set_valid && !replaced
	}
	rand_set_seconds := time.duration_seconds(time.since(rand_set_start))
	btree_pkg_bench_assert(rand_set_valid, "u64 random set should not replace")
	btree_pkg_bench_log_rate("u64-set-rand", bench_count, rand_set_seconds)

	rand_set_hint_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&rand_set_hint_tree)
	rand_set_hint := Path_Hint{}
	rand_set_hint_valid := true
	rand_set_hint_start := time.now()
	for item in rand_items {
		_, replaced := set_hint(&rand_set_hint_tree, item, &rand_set_hint)
		rand_set_hint_valid = rand_set_hint_valid && !replaced
	}
	rand_set_hint_seconds := time.duration_seconds(time.since(rand_set_hint_start))
	btree_pkg_bench_assert(rand_set_hint_valid, "u64 random set_hint should not replace")
	btree_pkg_bench_log_rate("u64-set-rand-hint-control", bench_count, rand_set_hint_seconds)

	get_rand_start := time.now()
	get_rand_valid := 0
	for item in rand_items {
		value, ok := get(&seq_load_tree, item)
		if ok && value.key == item.key && value.val == item.val do get_rand_valid += 1
	}
	get_rand_seconds := time.duration_seconds(time.since(get_rand_start))
	btree_pkg_bench_assert_eq_int(get_rand_valid, bench_count, "u64 random get result mismatch")
	btree_pkg_bench_log_rate("u64-get-rand", bench_count, get_rand_seconds)

	remove_rand_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&remove_rand_tree)
	btree_pkg_bench_insert_u64_items(&remove_rand_tree, seq_items[:], true, false, nil)
	remove_rand_start := time.now()
	remove_rand_valid := 0
	for item in rand_items {
		prev, removed := remove(&remove_rand_tree, item)
		if removed && prev.key == item.key && prev.val == item.val do remove_rand_valid += 1
	}
	remove_rand_seconds := time.duration_seconds(time.since(remove_rand_start))
	btree_pkg_bench_assert_eq_int(remove_rand_valid, bench_count, "u64 random remove result mismatch")
	btree_pkg_bench_log_rate("u64-remove-rand", bench_count, remove_rand_seconds)

	pivot_tree := create(BTB_U64_Item, btree_pkg_bench_cmp_u64_item, Options{degree = degree})
	defer destroy(&pivot_tree)
	btree_pkg_bench_insert_u64_items(&pivot_tree, seq_items[:], true, false, nil)

	seek_window_items := 0
	pivot_it := iter(&pivot_tree)
	defer iter_destroy(&pivot_it)
	pivot_start := time.now()
	for pivot in rand_items {
		ok := iter_seek(&pivot_it, pivot)
		if !ok {
			continue
		}
		seek_window_items += 1
		for step := 1; step < seek_window; step += 1 {
			if !iter_next(&pivot_it) {
				break
			}
			seek_window_items += 1
		}
	}
	pivot_seconds := time.duration_seconds(time.since(pivot_start))
	btree_pkg_bench_log_seek_window("u64-iter-random-seek-window", bench_count, seek_window_items, pivot_seconds)

	scan_ops := bench_count * scan_rounds
	scan_start := time.now()
	total_scan_count := 0
	total_scan_sum: i64 = 0
	for i := 0; i < scan_rounds; i += 1 {
		btree_pkg_bench_u64_scan_counter = 0
		btree_pkg_bench_u64_scan_sum = 0
		scan(&pivot_tree, btree_pkg_bench_u64_scan_cb)
		total_scan_count += btree_pkg_bench_u64_scan_counter
		total_scan_sum += btree_pkg_bench_u64_scan_sum
	}
	scan_seconds := time.duration_seconds(time.since(scan_start))
	btree_pkg_bench_assert_eq_int(total_scan_count, scan_ops, "u64 scan count mismatch")
	btree_pkg_bench_assert_eq_i64(total_scan_sum, expected_scan_sum * i64(scan_rounds), "u64 scan sum mismatch")
	btree_pkg_bench_log_rate("u64-scan", scan_ops, scan_seconds)
}

btree_pkg_benchmark_core_ops_run :: proc() {
	bench_count := btree_pkg_bench_env_int("BENCH_BTREE_PKG_COUNT", BENCH_BTREE_PKG_DEFAULT_COUNT)
	degree := btree_pkg_bench_env_int("BENCH_BTREE_PKG_DEGREE", BENCH_BTREE_PKG_DEFAULT_DEGREE)
	seek_window := btree_pkg_bench_env_int("BENCH_BTREE_PKG_SEEK_WINDOW", 0)
	if seek_window <= 0 {
		// Backward compatibility with old env name.
		seek_window = btree_pkg_bench_env_int("BENCH_BTREE_PKG_PIVOT_SPAN", BENCH_BTREE_PKG_DEFAULT_SEEK_WINDOW)
	}
	scan_rounds := btree_pkg_bench_env_int("BENCH_BTREE_PKG_SCAN_ROUNDS", BENCH_BTREE_PKG_DEFAULT_SCAN_ROUNDS)
	if seek_window > bench_count {
		seek_window = bench_count
	}

	base_items, key_slab := btree_pkg_bench_make_items_random_unique(bench_count)
	defer delete(base_items)

	seq_items := make([dynamic]BTB_Item, len(base_items))
	defer delete(seq_items)
	copy(seq_items[:], base_items[:])
	slice.sort_by(seq_items[:], proc(a, b: BTB_Item) -> bool {
		return a.key < b.key
	})

	defer delete(key_slab)

	rand_items := make([dynamic]BTB_Item, len(base_items))
	defer delete(rand_items)
	copy(rand_items[:], base_items[:])
	shuffle_state := u64(0x9e3779b97f4a7c15)
	btree_pkg_bench_shuffle_items(rand_items[:], &shuffle_state)

	fmt.println("=== BTree Package Benchmark ===")
	fmt.println(fmt.tprintf("Count=%d Degree=%d SeekWindow=%d ScanRounds=%d", bench_count, degree, seek_window, scan_rounds))
	fmt.println("Dataset: random unique 16-digit keys; sequential phases use sorted copy")
	fmt.println("Note: random *-hint phases are control cases (poor locality), not recommended usage")
	expected_scan_sum: i64 = 0
	for item in seq_items {
		expected_scan_sum += item.val
	}

	// Inserts
	seq_set_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&seq_set_tree)
	seq_set_valid := true
	seq_set_start := time.now()
	for item in seq_items {
		_, replaced := set(&seq_set_tree, item)
		seq_set_valid = seq_set_valid && !replaced
	}
	seq_set_seconds := time.duration_seconds(time.since(seq_set_start))
	btree_pkg_bench_assert(seq_set_valid, "sequential set result mismatch")
	btree_pkg_bench_assert_eq_int(count(&seq_set_tree), bench_count, "sequential set count mismatch")
	btree_pkg_bench_log_rate("set-seq", bench_count, seq_set_seconds)

	seq_set_hint_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&seq_set_hint_tree)
	seq_set_hint := Path_Hint{}
	seq_set_hint_valid := true
	seq_set_hint_start := time.now()
	for item in seq_items {
		_, replaced := set_hint(&seq_set_hint_tree, item, &seq_set_hint)
		seq_set_hint_valid = seq_set_hint_valid && !replaced
	}
	seq_set_hint_seconds := time.duration_seconds(time.since(seq_set_hint_start))
	btree_pkg_bench_assert(seq_set_hint_valid, "sequential set_hint result mismatch")
	btree_pkg_bench_assert_eq_int(count(&seq_set_hint_tree), bench_count, "sequential set_hint count mismatch")
	btree_pkg_bench_log_rate("set-seq-hint", bench_count, seq_set_hint_seconds)

	seq_load_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&seq_load_tree)
	seq_load_valid := true
	seq_load_start := time.now()
	for item in seq_items {
		_, replaced := load(&seq_load_tree, item)
		seq_load_valid = seq_load_valid && !replaced
	}
	seq_load_seconds := time.duration_seconds(time.since(seq_load_start))
	btree_pkg_bench_assert(seq_load_valid, "sequential load result mismatch")
	btree_pkg_bench_assert_eq_int(count(&seq_load_tree), bench_count, "sequential load count mismatch")
	btree_pkg_bench_log_rate("load-seq", bench_count, seq_load_seconds)

	rand_set_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&rand_set_tree)
	rand_set_valid := true
	rand_set_start := time.now()
	for item in rand_items {
		_, replaced := set(&rand_set_tree, item)
		rand_set_valid = rand_set_valid && !replaced
	}
	rand_set_seconds := time.duration_seconds(time.since(rand_set_start))
	btree_pkg_bench_assert(rand_set_valid, "random set result mismatch")
	btree_pkg_bench_assert_eq_int(count(&rand_set_tree), bench_count, "random set count mismatch")
	btree_pkg_bench_log_rate("set-rand", bench_count, rand_set_seconds)

	rand_set_hint_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&rand_set_hint_tree)
	rand_set_hint := Path_Hint{}
	rand_set_hint_valid := true
	rand_set_hint_start := time.now()
	for item in rand_items {
		_, replaced := set_hint(&rand_set_hint_tree, item, &rand_set_hint)
		rand_set_hint_valid = rand_set_hint_valid && !replaced
	}
	rand_set_hint_seconds := time.duration_seconds(time.since(rand_set_hint_start))
	btree_pkg_bench_assert(rand_set_hint_valid, "random set_hint result mismatch")
	btree_pkg_bench_assert_eq_int(count(&rand_set_hint_tree), bench_count, "random set_hint count mismatch")
	btree_pkg_bench_log_rate("set-rand-hint-control", bench_count, rand_set_hint_seconds)

	rand_load_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&rand_load_tree)
	rand_load_valid := true
	rand_load_start := time.now()
	for item in rand_items {
		_, replaced := load(&rand_load_tree, item)
		rand_load_valid = rand_load_valid && !replaced
	}
	rand_load_seconds := time.duration_seconds(time.since(rand_load_start))
	btree_pkg_bench_assert(rand_load_valid, "random load result mismatch")
	btree_pkg_bench_assert_eq_int(count(&rand_load_tree), bench_count, "random load count mismatch")
	btree_pkg_bench_log_rate("load-rand", bench_count, rand_load_seconds)

	// Gets
	get_seq_valid := 0
	get_seq_start := time.now()
	for item in seq_items {
		value, ok := get(&seq_load_tree, item)
		if ok && value.key == item.key && value.val == item.val do get_seq_valid += 1
	}
	get_seq_seconds := time.duration_seconds(time.since(get_seq_start))
	btree_pkg_bench_assert_eq_int(get_seq_valid, bench_count, "get_seq result mismatch")
	btree_pkg_bench_log_rate("get-seq", bench_count, get_seq_seconds)

	get_seq_hint := Path_Hint{}
	get_seq_hint_valid := 0
	get_seq_hint_start := time.now()
	for item in seq_items {
		value, ok := get_hint(&seq_load_tree, item, &get_seq_hint)
		if ok && value.key == item.key && value.val == item.val do get_seq_hint_valid += 1
	}
	get_seq_hint_seconds := time.duration_seconds(time.since(get_seq_hint_start))
	btree_pkg_bench_assert_eq_int(get_seq_hint_valid, bench_count, "get_seq_hint result mismatch")
	btree_pkg_bench_log_rate("get-seq-hint", bench_count, get_seq_hint_seconds)

	get_rand_valid := 0
	get_rand_start := time.now()
	for item in rand_items {
		value, ok := get(&seq_load_tree, item)
		if ok && value.key == item.key && value.val == item.val do get_rand_valid += 1
	}
	get_rand_seconds := time.duration_seconds(time.since(get_rand_start))
	btree_pkg_bench_assert_eq_int(get_rand_valid, bench_count, "random get result mismatch")
	btree_pkg_bench_log_rate("get-rand", bench_count, get_rand_seconds)

	get_rand_hint := Path_Hint{}
	get_rand_hint_valid := 0
	get_rand_hint_start := time.now()
	for item in rand_items {
		value, ok := get_hint(&seq_load_tree, item, &get_rand_hint)
		if ok && value.key == item.key && value.val == item.val do get_rand_hint_valid += 1
	}
	get_rand_hint_seconds := time.duration_seconds(time.since(get_rand_hint_start))
	btree_pkg_bench_assert_eq_int(get_rand_hint_valid, bench_count, "get_rand_hint result mismatch")
	btree_pkg_bench_log_rate("get-rand-hint-control", bench_count, get_rand_hint_seconds)

	// Removes
	remove_rand_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&remove_rand_tree)
	btree_pkg_bench_insert_items(&remove_rand_tree, seq_items[:], true, false, nil)
	remove_rand_valid := 0
	remove_rand_start := time.now()
	for item in rand_items {
		prev, removed := remove(&remove_rand_tree, item)
		if removed && prev.key == item.key && prev.val == item.val do remove_rand_valid += 1
	}
	remove_rand_seconds := time.duration_seconds(time.since(remove_rand_start))
	btree_pkg_bench_assert_eq_int(remove_rand_valid, bench_count, "random remove result mismatch")
	btree_pkg_bench_assert_eq_int(count(&remove_rand_tree), 0, "random remove did not empty tree")
	btree_pkg_bench_log_rate("remove-rand", bench_count, remove_rand_seconds)

	remove_rand_hint_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&remove_rand_hint_tree)
	btree_pkg_bench_insert_items(&remove_rand_hint_tree, seq_items[:], true, false, nil)
	remove_rand_hint := Path_Hint{}
	remove_rand_hint_valid := 0
	remove_rand_hint_start := time.now()
	for item in rand_items {
		prev, removed := remove_hint(&remove_rand_hint_tree, item, &remove_rand_hint)
		if removed && prev.key == item.key && prev.val == item.val do remove_rand_hint_valid += 1
	}
	remove_rand_hint_seconds := time.duration_seconds(time.since(remove_rand_hint_start))
	btree_pkg_bench_assert_eq_int(remove_rand_hint_valid, bench_count, "remove_rand_hint result mismatch")
	btree_pkg_bench_assert_eq_int(count(&remove_rand_hint_tree), 0, "random remove_hint did not empty tree")
	btree_pkg_bench_log_rate("remove-rand-hint-control", bench_count, remove_rand_hint_seconds)

	// Iterator random-seek + forward-window pagination-like walks.
	pivot_tree := create(BTB_Item, btree_pkg_bench_cmp_item, Options{degree = degree})
	defer destroy(&pivot_tree)
	btree_pkg_bench_insert_items(&pivot_tree, seq_items[:], true, false, nil)

	seek_window_items := 0
	pivot_it := iter(&pivot_tree)
	defer iter_destroy(&pivot_it)
	pivot_start := time.now()
	for pivot in rand_items {
		ok := iter_seek(&pivot_it, pivot)
		if !ok {
			continue
		}
		seek_window_items += 1
		for step := 1; step < seek_window; step += 1 {
			if !iter_next(&pivot_it) {
				break
			}
			seek_window_items += 1
		}
	}
	pivot_seconds := time.duration_seconds(time.since(pivot_start))
	btree_pkg_bench_log_seek_window("iter-random-seek-window", bench_count, seek_window_items, pivot_seconds)

	pivot_hint := Path_Hint{}
	seek_window_hint_items := 0
	pivot_hint_it := iter(&pivot_tree)
	defer iter_destroy(&pivot_hint_it)
	pivot_hint_start := time.now()
	for pivot in rand_items {
		ok := iter_seek_hint(&pivot_hint_it, pivot, &pivot_hint)
		if !ok {
			continue
		}
		seek_window_hint_items += 1
		for step := 1; step < seek_window; step += 1 {
			if !iter_next(&pivot_hint_it) {
				break
			}
			seek_window_hint_items += 1
		}
	}
	pivot_hint_seconds := time.duration_seconds(time.since(pivot_hint_start))
	btree_pkg_bench_log_seek_window("iter-random-seek-window-hint-control", bench_count, seek_window_hint_items, pivot_hint_seconds)

	scan_ops := bench_count * scan_rounds

	// Full scans via iterator API.
	iter_scan_it := iter(&pivot_tree)
	defer iter_destroy(&iter_scan_it)
	iter_scan_count := 0
	iter_scan_sum: i64 = 0
	iter_scan_start := time.now()
	for i := 0; i < scan_rounds; i += 1 {
		for ok := iter_first(&iter_scan_it); ok; ok = iter_next(&iter_scan_it) {
			iter_scan_sum += item(&iter_scan_it).val
			iter_scan_count += 1
		}
	}
	iter_scan_seconds := time.duration_seconds(time.since(iter_scan_start))
	btree_pkg_bench_assert_eq_int(iter_scan_count, scan_ops, "iter full scan count mismatch")
	btree_pkg_bench_assert_eq_i64(iter_scan_sum, expected_scan_sum * i64(scan_rounds), "iter full scan sum mismatch")
	btree_pkg_bench_log_rate("iter-full-scan", scan_ops, iter_scan_seconds)

	iter_reverse_it := iter(&pivot_tree)
	defer iter_destroy(&iter_reverse_it)
	iter_reverse_count := 0
	iter_reverse_sum: i64 = 0
	iter_reverse_start := time.now()
	for i := 0; i < scan_rounds; i += 1 {
		for ok := iter_last(&iter_reverse_it); ok; ok = iter_prev(&iter_reverse_it) {
			iter_reverse_sum += item(&iter_reverse_it).val
			iter_reverse_count += 1
		}
	}
	iter_reverse_seconds := time.duration_seconds(time.since(iter_reverse_start))
	btree_pkg_bench_assert_eq_int(iter_reverse_count, scan_ops, "iter full reverse count mismatch")
	btree_pkg_bench_assert_eq_i64(iter_reverse_sum, expected_scan_sum * i64(scan_rounds), "iter full reverse sum mismatch")
	btree_pkg_bench_log_rate("iter-full-reverse", scan_ops, iter_reverse_seconds)

	// Full scans
	total_scan_count := 0
	total_scan_sum: i64 = 0
	scan_start := time.now()
	for i := 0; i < scan_rounds; i += 1 {
		btree_pkg_bench_scan_counter = 0
		btree_pkg_bench_scan_sum = 0
		scan(&pivot_tree, btree_pkg_bench_scan_cb)
		total_scan_count += btree_pkg_bench_scan_counter
		total_scan_sum += btree_pkg_bench_scan_sum
	}
	scan_seconds := time.duration_seconds(time.since(scan_start))
	btree_pkg_bench_assert_eq_int(total_scan_count, scan_ops, "scan count mismatch")
	btree_pkg_bench_assert_eq_i64(total_scan_sum, expected_scan_sum * i64(scan_rounds), "scan sum mismatch")
	btree_pkg_bench_log_rate("scan", scan_ops, scan_seconds)

	total_reverse_count := 0
	total_reverse_sum: i64 = 0
	reverse_start := time.now()
	for i := 0; i < scan_rounds; i += 1 {
		btree_pkg_bench_scan_counter = 0
		btree_pkg_bench_scan_sum = 0
		reverse(&pivot_tree, btree_pkg_bench_scan_cb)
		total_reverse_count += btree_pkg_bench_scan_counter
		total_reverse_sum += btree_pkg_bench_scan_sum
	}
	reverse_seconds := time.duration_seconds(time.since(reverse_start))
	btree_pkg_bench_assert_eq_int(total_reverse_count, scan_ops, "reverse count mismatch")
	btree_pkg_bench_assert_eq_i64(total_reverse_sum, expected_scan_sum * i64(scan_rounds), "reverse sum mismatch")
	btree_pkg_bench_log_rate("reverse", scan_ops, reverse_seconds)

	fmt.println("")
	btree_pkg_benchmark_u64_core_ops_run(bench_count, degree, seek_window, scan_rounds)
	btree_pkg_benchmark_u32_core_ops_run(bench_count, degree, seek_window, scan_rounds)
}
