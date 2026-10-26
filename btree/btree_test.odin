package btree

// Unit and property tests for the generic B-tree implementation used by indexes.
// The suite checks ordering, inserts/removes, iteration, and randomized model
// agreement so higher-level note/task indexes can depend on stable sorted access.

import "core:slice"
import "core:testing"

import hgl "../hegel"

Test_Int_Order :: Static_Order(int, No_Projection, test_cmp_int_static)
Test_I32_Order :: Static_Order(i32, No_Projection, test_cmp_i32_static)
Test_U64_Order :: Static_Order(u64, No_Projection, test_cmp_u64_static)

test_cmp_int_static :: proc(a, b: rawptr, descending: bool) -> int {
	return test_cmp_int((^int)(a)^, (^int)(b)^)
}

test_cmp_i32_static :: proc(a, b: rawptr, descending: bool) -> int {
	return test_cmp_i32((^i32)(a)^, (^i32)(b)^)
}

test_cmp_u64_static :: proc(a, b: rawptr, descending: bool) -> int {
	return test_cmp_u64((^u64)(a)^, (^u64)(b)^)
}

Test_Int_Descending_Order :: Static_Order(int, No_Projection, test_cmp_int_descending_static)

test_cmp_int_descending_static :: proc(a, b: rawptr, descending: bool) -> int {
	return test_cmp_int((cast(^int)b)^, (cast(^int)a)^)
}

@(test)
test_static_integer_descending_order :: proc(t: ^testing.T) {
	// A primitive-key fast path must not override the static policy, even
	// without a runtime comparator or the text-descending option.
	tr := create_ordered(int, Test_Int_Descending_Order, Options{degree = 2})
	defer destroy(&tr)
	hint: Path_Hint
	for key in ([?]int{4, 10, 2, 8, 6}) {
		_, replaced := set_hint(&tr, key, &hint)
		testing.expect(t, !replaced)
	}
	it := iter(&tr)
	defer iter_destroy(&it)
	expected := 10
	for ok := iter_first(&it); ok; ok = iter_next(&it) {
		testing.expect_value(t, item(&it), expected)
		expected -= 2
	}
	testing.expect_value(t, expected, 0)
	for key in ([?]int{2, 4, 6, 8, 10}) {
		value, found := get_hint(&tr, key, &hint)
		testing.expect(t, found)
		testing.expect_value(t, value, key)
	}
	testing.expect(t, iter_seek(&it, 7))
	testing.expect_value(t, item(&it), 6)
	testing.expect(t, iter_seek_hint(&it, 5, &hint))
	testing.expect_value(t, item(&it), 4)
	removed, found := remove_hint(&tr, 6, &hint)
	testing.expect(t, found)
	testing.expect_value(t, removed, 6)
	testing.expect(t, iter_seek(&it, 7))
	testing.expect_value(t, item(&it), 4)
	testing.expect_value(t, count(&tr), 4)
}

test_cmp_int :: proc(a, b: int) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

test_cmp_i32 :: proc(a, b: i32) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

test_cmp_u64 :: proc(a, b: u64) -> int {
	if a < b {
		return -1
	}
	if a > b {
		return 1
	}
	return 0
}

btree_test_node_lsearch_scalar_i32 :: proc(n: ^Node(i32), key: i32) -> (index: int, found: bool) {
	for i := 0; i < int(n.item_count); i += 1 {
		v := n.items[i]
		if v == key {
			return i, true
		}
		if v > key {
			return i, false
		}
	}

	return int(n.item_count), false
}

btree_test_node_lsearch_scalar_u64 :: proc(n: ^Node(u64), key: u64) -> (index: int, found: bool) {
	for i := 0; i < int(n.item_count); i += 1 {
		v := n.items[i]
		if v == key {
			return i, true
		}
		if v > key {
			return i, false
		}
	}

	return int(n.item_count), false
}

btree_test_rng_next :: proc(state: ^u64) -> u64 {
	state^ = state^ * 6364136223846793005 + 1
	return state^
}

btree_test_shuffle :: proc(items: []int, seed: ^u64) {
	for i := len(items) - 1; i > 0; i -= 1 {
		j := int(btree_test_rng_next(seed) % u64(i + 1))
		items[i], items[j] = items[j], items[i]
	}
}

btree_test_slice_equal :: proc(a, b: []int) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i := 0; i < len(a); i += 1 {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

btree_test_expect_slice_equal :: proc(t: ^testing.T, got, want: []int, msg: string) {
	testing.expect_value(t, len(got), len(want))
	if len(got) != len(want) {
		testing.expect(t, false, msg)
		return
	}

	for i := 0; i < len(got); i += 1 {
		testing.expect_value(t, got[i], want[i])
	}
}

@(thread_local)
btree_test_collect_target: ^[dynamic]int

btree_test_collect_cb :: proc(item: int) -> bool {
	append(btree_test_collect_target, item)
	return true
}

btree_test_collect_scan :: proc(tr: ^BTreeG(int, Test_Int_Order)) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	scan(tr, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_collect_reverse :: proc(tr: ^BTreeG(int, Test_Int_Order)) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	reverse(tr, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_collect_ascend :: proc(tr: ^BTreeG(int, Test_Int_Order), pivot: int) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	ascend(tr, pivot, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_collect_descend :: proc(tr: ^BTreeG(int, Test_Int_Order), pivot: int) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	descend(tr, pivot, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_collect_ascend_hint :: proc(tr: ^BTreeG(int, Test_Int_Order), pivot: int, hint: ^Path_Hint) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	ascend_hint(tr, pivot, hint, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_collect_descend_hint :: proc(tr: ^BTreeG(int, Test_Int_Order), pivot: int, hint: ^Path_Hint) -> [dynamic]int {
	items := make([dynamic]int, 0, max(count(tr), 1))
	btree_test_collect_target = &items
	descend_hint(tr, pivot, hint, btree_test_collect_cb)
	btree_test_collect_target = nil
	return items
}

btree_test_model_keys_sorted :: proc(model: map[int]bool) -> [dynamic]int {
	keys := make([dynamic]int, 0, max(len(model), 1))
	for k, exists in model {
		if exists {
			append(&keys, k)
		}
	}
	slice.sort_by(keys[:], proc(a, b: int) -> bool {
		return a < b
	})
	return keys
}

btree_test_check_node :: proc(
	t: ^testing.T,
	tr: ^BTreeG(int, Test_Int_Order),
	n: ^Node(int),
	is_root: bool,
	depth: int,
) -> (
	item_count: int,
	min_value: int,
	max_value: int,
	has_value: bool,
	leaf_depth: int,
) {
	testing.expect(t, n != nil, "node must not be nil")
	if n == nil {
		return 0, 0, 0, false, depth
	}

	testing.expect(t, int(n.item_count) <= tr.max_items, "node item count must be <= max_items")
	if !is_root {
		testing.expect(t, int(n.item_count) >= tr.min_items, "non-root node item count must be >= min_items")
	}

	for i := 1; i < int(n.item_count); i += 1 {
		testing.expect(t, node_compare(tr, n.items[i - 1], n.items[i]) < 0, "node items must be strictly increasing")
	}

	if n.leaf {
		testing.expect_value(t, n.child_count, 0)
		if n.item_count == 0 {
			return 0, 0, 0, false, depth
		}
		return int(n.item_count), n.items[0], n.items[int(n.item_count) - 1], true, depth
	}

	testing.expect_value(t, n.child_count, n.item_count + 1)
	if n.child_count == 0 {
		if n.item_count == 0 {
			return 0, 0, 0, false, depth
		}
		return int(n.item_count), n.items[0], n.items[int(n.item_count) - 1], true, depth
	}

	left_count, left_min, left_max, left_has, left_leaf_depth := btree_test_check_node(t, tr, n.children[0], false, depth + 1)
	testing.expect(t, left_has, "internal node children must contain values")
	testing.expect(t, node_compare(tr, left_max, n.items[0]) < 0, "left child max must be < first separator")

	item_count = int(n.item_count) + left_count
	min_value = left_min
	max_value = left_max
	has_value = true
	leaf_depth = left_leaf_depth

	for i := 1; i < int(n.child_count); i += 1 {
		child_count, child_min, child_max, child_has, child_leaf_depth := btree_test_check_node(t, tr, n.children[i], false, depth + 1)
		testing.expect(t, child_has, "internal node children must contain values")
		testing.expect_value(t, child_leaf_depth, leaf_depth)

		separator := n.items[i - 1]
		testing.expect(t, node_compare(tr, separator, child_min) < 0, "separator must be < right child min")
		if i < int(n.item_count) {
			testing.expect(t, node_compare(tr, child_max, n.items[i]) < 0, "child max must be < next separator")
		}

		item_count += child_count
		max_value = child_max
	}

	return
}

btree_test_assert_tree_sane :: proc(t: ^testing.T, tr: ^BTreeG(int, Test_Int_Order)) {
	if tr.root == nil {
		testing.expect_value(t, count(tr), 0)
		return
	}

	testing.expect(t, tr.root.item_count > 0, "root must contain items when tree is non-empty")
	if !tr.root.leaf {
		testing.expect_value(t, tr.root.child_count, tr.root.item_count + 1)
	}

	item_count, _, _, has_value, _ := btree_test_check_node(t, tr, tr.root, true, 0)
	testing.expect(t, has_value, "non-empty tree must contain values")
	testing.expect_value(t, item_count, count(tr))

	scanned := btree_test_collect_scan(tr)
	defer delete(scanned)
	testing.expect_value(t, len(scanned), count(tr))
	for i := 1; i < len(scanned); i += 1 {
		testing.expect(t, node_compare(tr, scanned[i - 1], scanned[i]) < 0, "scan must be strictly increasing")
	}
}

BTREE_Test_Metrics :: struct {
	node_count: int,
	item_count: int,
	height:     int,
}

btree_test_collect_metrics :: proc(n: ^Node(int), depth: int, metrics: ^BTREE_Test_Metrics) {
	if n == nil {
		return
	}

	metrics.node_count += 1
	metrics.item_count += int(n.item_count)
	if depth + 1 > metrics.height {
		metrics.height = depth + 1
	}

	if !n.leaf {
		for i := 0; i < int(n.child_count); i += 1 {
			btree_test_collect_metrics(n.children[i], depth + 1, metrics)
		}
	}
}

btree_test_tree_metrics :: proc(tr: ^BTreeG(int, Test_Int_Order)) -> BTREE_Test_Metrics {
	metrics := BTREE_Test_Metrics{}
	if tr.root == nil {
		return metrics
	}

	btree_test_collect_metrics(tr.root, 0, &metrics)
	return metrics
}

btree_test_assert_tree_matches_model :: proc(t: ^testing.T, tr: ^BTreeG(int, Test_Int_Order), model: map[int]bool) {
	btree_test_assert_tree_sane(t, tr)
	testing.expect_value(t, count(tr), len(model))

	expected := btree_test_model_keys_sorted(model)
	defer delete(expected)

	actual_scan := btree_test_collect_scan(tr)
	defer delete(actual_scan)
	btree_test_expect_slice_equal(t, actual_scan[:], expected[:], "scan order should match model")

	actual_reverse := btree_test_collect_reverse(tr)
	defer delete(actual_reverse)
	reverse_expected := make([dynamic]int, 0, len(expected))
	defer delete(reverse_expected)
	for i := len(expected) - 1; i >= 0; i -= 1 {
		append(&reverse_expected, expected[i])
	}
	btree_test_expect_slice_equal(t, actual_reverse[:], reverse_expected[:], "reverse order should match model")

	for k in expected {
		v, ok := get(tr, k)
		testing.expect(t, ok, "model key must be retrievable")
		testing.expect_value(t, v, k)
		testing.expect(t, contains(tr, k), "contains must match get")
	}
}

btree_test_find_promoted_median_candidate_in_subtree :: proc(n: ^Node(int), max_items: int) -> (key: int, ok: bool) {
	if n == nil || n.leaf {
		return 0, false
	}

	for i := 0; i < int(n.child_count); i += 1 {
		child := n.children[i]
		if int(child.item_count) == max_items {
			return child.items[int(child.item_count) / 2], true
		}
	}

	for i := 0; i < int(n.child_count); i += 1 {
		child := n.children[i]
		candidate, found := btree_test_find_promoted_median_candidate_in_subtree(child, max_items)
		if found {
			return candidate, true
		}
	}

	return 0, false
}

BTREE_Test_Node_Find_Case :: struct {
	key:   int,
	index: int,
	found: bool,
}

@(test)
test_btree_node_find_linear_search_positions :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 32})
	defer destroy(&tr)

	n := node_new(&tr, true)
	defer node_destroy_header(&tr, n)

	for i := 0; i < 16; i += 1 {
		n.items[i] = i * 2
	}
	n.item_count = 16
	testing.expect(t, n.item_count <= LINEAR_SEARCH_NODE_CUTOFF, "fixture must stay in linear-search range")

	cases := [8]BTREE_Test_Node_Find_Case {
		{key = -3, index = 0, found = false},
		{key = 0, index = 0, found = true},
		{key = 1, index = 1, found = false},
		{key = 14, index = 7, found = true},
		{key = 15, index = 8, found = false},
		{key = 30, index = 15, found = true},
		{key = 31, index = 16, found = false},
		{key = 999, index = 16, found = false},
	}

	for c in cases {
		index, found := node_find(&tr, n, c.key, nil, 0)
		testing.expect_value(t, index, c.index)
		testing.expect_value(t, found, c.found)
	}
}

@(test)
test_btree_node_find_linear_search_positions_i32 :: proc(t: ^testing.T) {
	tr := create_ordered(i32, Test_I32_Order, Options{degree = 32})
	defer destroy(&tr)

	n := node_new(&tr, true)
	defer node_destroy_header(&tr, n)

	for i := 0; i < 16; i += 1 {
		n.items[i] = i32(i * 3)
	}
	n.item_count = 16
	testing.expect(t, n.item_count <= LINEAR_SEARCH_NODE_CUTOFF, "fixture must stay in linear-search range")

	index, found := node_find(&tr, n, i32(-5), nil, 0)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, found, false)

	index, found = node_find(&tr, n, i32(0), nil, 0)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, found, true)

	index, found = node_find(&tr, n, i32(10), nil, 0)
	testing.expect_value(t, index, 4)
	testing.expect_value(t, found, false)

	index, found = node_find(&tr, n, i32(30), nil, 0)
	testing.expect_value(t, index, 10)
	testing.expect_value(t, found, true)

	index, found = node_find(&tr, n, i32(47), nil, 0)
	testing.expect_value(t, index, 16)
	testing.expect_value(t, found, false)
}

@(test)
test_btree_node_find_linear_search_positions_u64 :: proc(t: ^testing.T) {
	tr := create_ordered(u64, Test_U64_Order, Options{degree = 32})
	defer destroy(&tr)

	n := node_new(&tr, true)
	defer node_destroy_header(&tr, n)

	for i := 0; i < 18; i += 1 {
		n.items[i] = u64(i * 5)
	}
	n.item_count = 18
	testing.expect(t, n.item_count <= LINEAR_SEARCH_NODE_CUTOFF, "fixture must stay in linear-search range")

	index, found := node_find(&tr, n, u64(0), nil, 0)
	testing.expect_value(t, index, 0)
	testing.expect_value(t, found, true)

	index, found = node_find(&tr, n, u64(44), nil, 0)
	testing.expect_value(t, index, 9)
	testing.expect_value(t, found, false)

	index, found = node_find(&tr, n, u64(45), nil, 0)
	testing.expect_value(t, index, 9)
	testing.expect_value(t, found, true)

	index, found = node_find(&tr, n, u64(200), nil, 0)
	testing.expect_value(t, index, 18)
	testing.expect_value(t, found, false)
}

@(test)
test_btree_node_lsearch_i32_matches_scalar_boundaries :: proc(t: ^testing.T) {
	tr := create_ordered(i32, Test_I32_Order, Options{degree = 32})
	defer destroy(&tr)

	sizes := [5]int{7, 8, 9, 16, LINEAR_SEARCH_NODE_CUTOFF}

	for size in sizes {
		testing.expect(t, size > 0, "size fixture must be positive")

		n := node_new(&tr, true)
		for i := 0; i < size; i += 1 {
			n.items[i] = i32(i * 3)
		}
		n.item_count = u16(size)

		max_key := i32((size - 1) * 3)
		for k := i32(-6); k <= max_key + 6; k += 1 {
			direct_index, direct_found := node_lsearch(&tr, n, k)
			scalar_index, scalar_found := btree_test_node_lsearch_scalar_i32(n, k)
			testing.expect_value(t, direct_index, scalar_index)
			testing.expect_value(t, direct_found, scalar_found)

			find_index, find_found := node_find(&tr, n, k, nil, 0)
			testing.expect_value(t, find_index, scalar_index)
			testing.expect_value(t, find_found, scalar_found)
		}

		node_destroy_header(&tr, n)
	}
}

@(test)
test_btree_node_lsearch_u64_matches_scalar_boundaries :: proc(t: ^testing.T) {
	tr := create_ordered(u64, Test_U64_Order, Options{degree = 32})
	defer destroy(&tr)

	sizes := [5]int{7, 8, 9, 18, LINEAR_SEARCH_NODE_CUTOFF}

	for size in sizes {
		testing.expect(t, size > 0, "size fixture must be positive")

		n := node_new(&tr, true)
		for i := 0; i < size; i += 1 {
			n.items[i] = u64(i * 5)
		}
		n.item_count = u16(size)

		max_key := u64((size - 1) * 5)
		for k := u64(0); k <= max_key + 9; k += 1 {
			direct_index, direct_found := node_lsearch(&tr, n, k)
			scalar_index, scalar_found := btree_test_node_lsearch_scalar_u64(n, k)
			testing.expect_value(t, direct_index, scalar_index)
			testing.expect_value(t, direct_found, scalar_found)

			find_index, find_found := node_find(&tr, n, k, nil, 0)
			testing.expect_value(t, find_index, scalar_index)
			testing.expect_value(t, find_found, scalar_found)
		}

		node_destroy_header(&tr, n)
	}
}

@(test)
test_btree_linear_search_cutoff_get_remove_parity :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 16})
	defer destroy(&tr)

	for i := 0; i < 4000; i += 2 {
		_, replaced := set(&tr, i)
		testing.expect(t, !replaced, "set should insert even keys")
	}

	testing.expect_value(t, count(&tr), 2000)
	btree_test_assert_tree_sane(t, &tr)

	for i := 0; i < 4000; i += 1 {
		value, ok := get(&tr, i)
		if i % 2 == 0 {
			testing.expect(t, ok, "get should find inserted even key")
			testing.expect_value(t, value, i)
		} else {
			testing.expect(t, !ok, "get should miss non-inserted odd key")
		}
	}

	for i := 3998; i >= 0; i -= 2 {
		value, removed := remove(&tr, i)
		testing.expect(t, removed, "remove should delete inserted even key")
		testing.expect_value(t, value, i)
	}

	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "tree root should collapse to nil after full drain")
}

@(test)
test_btree_set_get_remove :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	seed_values := [6]int{5, 1, 9, 3, 7, 2}
	for v in seed_values {
		_, replaced := set(&tr, v)
		testing.expect(t, !replaced, "set should not replace for fresh key")
	}

	testing.expect_value(t, count(&tr), 6)

	v, ok := get(&tr, 7)
	testing.expect(t, ok, "get should find inserted key")
	testing.expect_value(t, v, 7)

	_, ok = get(&tr, 4)
	testing.expect(t, !ok, "get should miss non-existent key")

	_, removed := remove(&tr, 3)
	testing.expect(t, removed, "remove should delete existing key")
	testing.expect_value(t, count(&tr), 5)

	_, removed = remove(&tr, 3)
	testing.expect(t, !removed, "remove should fail when key is already gone")

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_load_presorted_fast_path :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	for i := 1; i <= 500; i += 1 {
		_, replaced := load(&tr, i)
		testing.expect(t, !replaced, "load should append fresh presorted keys")
	}

	testing.expect_value(t, count(&tr), 500)
	btree_test_assert_tree_sane(t, &tr)

	scanned := btree_test_collect_scan(&tr)
	defer delete(scanned)
	for i := 0; i < len(scanned); i += 1 {
		testing.expect_value(t, scanned[i], i + 1)
	}
}

@(test)
test_btree_load_falls_back_for_out_of_order_and_replace :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	_, replaced := load(&tr, 10)
	testing.expect(t, !replaced, "first load should insert")
	_, replaced = load(&tr, 30)
	testing.expect(t, !replaced, "second sorted load should insert")

	_, replaced = load(&tr, 20)
	testing.expect(t, !replaced, "out-of-order load should still insert via fallback")

	prev: int
	prev, replaced = load(&tr, 20)
	testing.expect(t, replaced, "duplicate load should replace existing key via fallback")
	testing.expect_value(t, prev, 20)

	testing.expect_value(t, count(&tr), 3)
	btree_test_assert_tree_sane(t, &tr)

	want := [3]int{10, 20, 30}
	scanned := btree_test_collect_scan(&tr)
	defer delete(scanned)
	btree_test_expect_slice_equal(t, scanned[:], want[:], "load fallback should preserve sorted order")
}

@(test)
test_btree_iterator_seek_and_prev :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	for i := 1; i <= 10; i += 1 {
		_, _ = set(&tr, i)
	}

	it := iter(&tr)
	defer iter_destroy(&it)

	has_item := iter_seek(&it, 6)
	testing.expect(t, has_item, "seek should find key 6")
	testing.expect_value(t, item(&it), 6)

	has_item = iter_prev(&it)
	testing.expect(t, has_item, "prev from 6 should move to 5")
	testing.expect_value(t, item(&it), 5)

	has_item = iter_seek(&it, 11)
	testing.expect(t, !has_item, "seek past max should fail")

	has_item = iter_last(&it)
	testing.expect(t, has_item, "last should move to maximum")
	testing.expect_value(t, item(&it), 10)
}

@(test)
test_btree_scan_reverse_ascend_descend_and_hints :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	for i := 0; i < 1000; i += 10 {
		_, replaced := set(&tr, i)
		testing.expect(t, !replaced, "insert should not replace")
	}

	all := btree_test_collect_scan(&tr)
	defer delete(all)

	reversed := btree_test_collect_reverse(&tr)
	defer delete(reversed)
	testing.expect_value(t, len(reversed), len(all))
	for i := 0; i < len(all); i += 1 {
		testing.expect_value(t, reversed[i], all[len(all) - 1 - i])
	}

	hint := Path_Hint{}
	for pivot := -1; pivot <= 1000; pivot += 7 {
		asc := btree_test_collect_ascend(&tr, pivot)
		defer delete(asc)
		asc_hint := btree_test_collect_ascend_hint(&tr, pivot, &hint)
		defer delete(asc_hint)
		testing.expect(t, btree_test_slice_equal(asc[:], asc_hint[:]), "ascend_hint should match ascend")

		expected_asc := make([dynamic]int, 0, len(all))
		defer delete(expected_asc)
		for v in all {
			if v >= pivot {
				append(&expected_asc, v)
			}
		}
		btree_test_expect_slice_equal(t, asc[:], expected_asc[:], "ascend results should match expected")

		desc := btree_test_collect_descend(&tr, pivot)
		defer delete(desc)
		desc_hint := btree_test_collect_descend_hint(&tr, pivot, &hint)
		defer delete(desc_hint)
		testing.expect(t, btree_test_slice_equal(desc[:], desc_hint[:]), "descend_hint should match descend")

		expected_desc := make([dynamic]int, 0, len(all))
		defer delete(expected_desc)
		for i := len(all) - 1; i >= 0; i -= 1 {
			if all[i] <= pivot {
				append(&expected_desc, all[i])
			}
		}
		btree_test_expect_slice_equal(t, desc[:], expected_desc[:], "descend results should match expected")
	}

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_iterator_seek_next_prev_sequences :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	for i := 0; i < 20000; i += 2 {
		_, _ = set(&tr, i)
	}

	it := iter(&tr)
	defer iter_destroy(&it)

	vals_next := make([dynamic]int, 0, 8)
	defer delete(vals_next)
	for ok := iter_seek(&it, 501); ok && len(vals_next) < 4; ok = iter_next(&it) {
		append(&vals_next, item(&it))
	}
	btree_test_expect_slice_equal(t, vals_next[:], []int{502, 504, 506, 508}, "seek+next sequence should be contiguous evens")

	vals_prev := make([dynamic]int, 0, 8)
	defer delete(vals_prev)
	for ok := iter_seek(&it, 501); ok && len(vals_prev) < 4; ok = iter_prev(&it) {
		append(&vals_prev, item(&it))
	}
	btree_test_expect_slice_equal(t, vals_prev[:], []int{502, 500, 498, 496}, "seek+prev sequence should start at seek result")

	hint := Path_Hint{}
	vals_next_hint := make([dynamic]int, 0, 8)
	defer delete(vals_next_hint)
	for ok := iter_seek_hint(&it, 501, &hint); ok && len(vals_next_hint) < 4; ok = iter_next(&it) {
		append(&vals_next_hint, item(&it))
	}
	btree_test_expect_slice_equal(t, vals_next_hint[:], []int{502, 504, 506, 508}, "seek_hint+next sequence should match")

	vals_prev_hint := make([dynamic]int, 0, 8)
	defer delete(vals_prev_hint)
	for ok := iter_seek_hint(&it, 501, &hint); ok && len(vals_prev_hint) < 4; ok = iter_prev(&it) {
		append(&vals_prev_hint, item(&it))
	}
	btree_test_expect_slice_equal(t, vals_prev_hint[:], []int{502, 500, 498, 496}, "seek_hint+prev sequence should match")
}

@(test)
test_btree_random_ops_against_model :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 16})
	defer destroy(&tr)

	model := make(map[int]bool, 4096)
	defer delete(model)

	rng_state := u64(0x1234_dead_beef_cafe)
	for i := 0; i < 20000; i += 1 {
		r := btree_test_rng_next(&rng_state)
		key := int(r % 2048)
		op := int((r >> 8) % 100)

		exists := model[key]
		switch {
		case op < 50:
			prev, replaced := set(&tr, key)
			if exists {
				testing.expect(t, replaced, "set should replace existing key")
				testing.expect_value(t, prev, key)
			} else {
				testing.expect(t, !replaced, "set should not replace missing key")
			}
			model[key] = true

		case op < 80:
			prev, removed := remove(&tr, key)
			if exists {
				testing.expect(t, removed, "remove should delete existing key")
				testing.expect_value(t, prev, key)
				delete_key(&model, key)
			} else {
				testing.expect(t, !removed, "remove should not delete missing key")
			}

		case:
			value, ok := get(&tr, key)
			if exists {
				testing.expect(t, ok, "get should find model key")
				testing.expect_value(t, value, key)
			} else {
				testing.expect(t, !ok, "get should miss non-model key")
			}
		}

		if i % 257 == 0 {
			btree_test_assert_tree_matches_model(t, &tr, model)
		}
	}

	btree_test_assert_tree_matches_model(t, &tr, model)
}

@(test)
test_btree_get_hint_parity_under_random_churn :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	model := make(map[int]bool, 8192)
	defer delete(model)

	hint := Path_Hint{}
	rng_state := u64(0x9b97f4a7c15d3e1b)
	for i := 0; i < 30000; i += 1 {
		r := btree_test_rng_next(&rng_state)
		key := int(r % 4096)
		op := int((r >> 12) % 100)
		exists := model[key]

		switch {
		case op < 45:
			if op % 2 == 0 {
				prev, replaced := set(&tr, key)
				if exists {
					testing.expect(t, replaced, "set should replace existing key")
					testing.expect_value(t, prev, key)
				} else {
					testing.expect(t, !replaced, "set should insert missing key")
				}
			} else {
				prev, replaced := set_hint(&tr, key, &hint)
				if exists {
					testing.expect(t, replaced, "set_hint should replace existing key")
					testing.expect_value(t, prev, key)
				} else {
					testing.expect(t, !replaced, "set_hint should insert missing key")
				}
			}
			model[key] = true

		case op < 75:
			if op % 2 == 0 {
				prev, removed := remove(&tr, key)
				if exists {
					testing.expect(t, removed, "remove should delete existing key")
					testing.expect_value(t, prev, key)
					delete_key(&model, key)
				} else {
					testing.expect(t, !removed, "remove should miss absent key")
				}
			} else {
				prev, removed := remove_hint(&tr, key, &hint)
				if exists {
					testing.expect(t, removed, "remove_hint should delete existing key")
					testing.expect_value(t, prev, key)
					delete_key(&model, key)
				} else {
					testing.expect(t, !removed, "remove_hint should miss absent key")
				}
			}

		case:
			plain_value, plain_ok := get(&tr, key)
			hint_value, hint_ok := get_hint(&tr, key, &hint)
			testing.expect_value(t, hint_ok, plain_ok)
			if plain_ok {
				testing.expect_value(t, hint_value, plain_value)
			}
		}

		probe := int((btree_test_rng_next(&rng_state) >> 7) % 4096)
		plain_value, plain_ok := get(&tr, probe)
		hint_value, hint_ok := get_hint(&tr, probe, &hint)
		testing.expect_value(t, hint_ok, plain_ok)
		if plain_ok {
			testing.expect_value(t, hint_value, plain_value)
		}

		if model[probe] {
			testing.expect(t, plain_ok, "model-present key should be found by get")
			testing.expect_value(t, plain_value, probe)
		} else {
			testing.expect(t, !plain_ok, "model-absent key should not be found by get")
		}

		if i % 257 == 0 {
			btree_test_assert_tree_matches_model(t, &tr, model)
		}
	}

	btree_test_assert_tree_matches_model(t, &tr, model)
}

@(test)
test_btree_insert_delete_cycles_and_hints :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 4})
	defer destroy(&tr)

	keys := make([dynamic]int, 0, 256)
	defer delete(keys)
	for i := 0; i < 256; i += 1 {
		append(&keys, i)
	}

	rng_state := u64(0xabcdef)
	hint := Path_Hint{}
	for round := 0; round < 3; round += 1 {
		btree_test_shuffle(keys[:], &rng_state)
		for k in keys {
			_, replaced := set(&tr, k)
			testing.expect(t, !replaced, "set during cycle insert should not replace")
		}

		btree_test_assert_tree_sane(t, &tr)

		for _, k in keys {
			v, ok := get_hint(&tr, k, &hint)
			testing.expect(t, ok, "get_hint should find inserted key")
			testing.expect_value(t, v, k)
		}

		btree_test_shuffle(keys[:], &rng_state)
		for k in keys {
			prev, removed := remove_hint(&tr, k, &hint)
			testing.expect(t, removed, "remove_hint should delete inserted key")
			testing.expect_value(t, prev, k)
		}

		testing.expect_value(t, count(&tr), 0)
		btree_test_assert_tree_sane(t, &tr)
	}
}

@(test)
test_btree_clear_and_reuse :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	for i := 0; i < 128; i += 1 {
		_, _ = set(&tr, i)
	}
	btree_test_assert_tree_sane(t, &tr)

	clear_tree(&tr)
	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "clear_tree should drop root")

	for i := 1000; i < 1128; i += 1 {
		_, replaced := set(&tr, i)
		testing.expect(t, !replaced, "tree should be reusable after clear")
	}

	for i := 1000; i < 1128; i += 1 {
		v, ok := get(&tr, i)
		testing.expect(t, ok, "reused tree must return inserted keys")
		testing.expect_value(t, v, i)
	}

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_split_merge_boundaries :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 4})
	defer destroy(&tr)

	for i := 0; i < 512; i += 1 {
		_, replaced := set(&tr, i)
		testing.expect(t, !replaced, "initial insert should not replace")
	}
	btree_test_assert_tree_sane(t, &tr)
	testing.expect(t, tr.root != nil, "root should exist after inserts")
	testing.expect(t, !tr.root.leaf, "small degree with many keys should produce internal root")

	for i := 0; i < 511; i += 1 {
		prev, removed := remove(&tr, i)
		testing.expect(t, removed, "remove should succeed while draining tree")
		testing.expect_value(t, prev, i)
	}
	btree_test_assert_tree_sane(t, &tr)
	testing.expect_value(t, count(&tr), 1)
	last, ok := get(&tr, 511)
	testing.expect(t, ok, "remaining key must still be present")
	testing.expect_value(t, last, 511)
	testing.expect(t, tr.root != nil, "root should still exist with one key")
	testing.expect(t, tr.root.leaf, "tree should collapse back to single leaf")

	prev, removed := remove(&tr, 511)
	testing.expect(t, removed, "final remove should succeed")
	testing.expect_value(t, prev, 511)
	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "root should be nil after removing all keys")
}

@(test)
test_btree_empty_tree_and_iterator_edges :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order)
	defer destroy(&tr)

	_, ok := get(&tr, 42)
	testing.expect(t, !ok, "get on empty tree should fail")
	_, removed := remove(&tr, 42)
	testing.expect(t, !removed, "remove on empty tree should fail")
	testing.expect(t, !contains(&tr, 42), "contains should be false on empty tree")

	scanned := btree_test_collect_scan(&tr)
	defer delete(scanned)
	testing.expect_value(t, len(scanned), 0)
	reversed := btree_test_collect_reverse(&tr)
	defer delete(reversed)
	testing.expect_value(t, len(reversed), 0)
	asc := btree_test_collect_ascend(&tr, 100)
	defer delete(asc)
	testing.expect_value(t, len(asc), 0)
	desc := btree_test_collect_descend(&tr, -100)
	defer delete(desc)
	testing.expect_value(t, len(desc), 0)

	it := iter(&tr)
	defer iter_destroy(&it)
	testing.expect(t, !iter_first(&it), "iter_first on empty tree should fail")
	testing.expect(t, !iter_last(&it), "iter_last on empty tree should fail")
	testing.expect(t, !iter_seek(&it, 1), "iter_seek on empty tree should fail")
	testing.expect(t, !iter_next(&it), "iter_next on empty tree should fail")
	testing.expect(t, !iter_prev(&it), "iter_prev on empty tree should fail")
}

@(test)
test_btree_hint_fallback_with_stale_paths :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	for i := 0; i < 4096; i += 2 {
		_, _ = set(&tr, i)
	}

	hint := Path_Hint{}
	for i := 0; i < MAX_HINT_DEPTH; i += 1 {
		hint.used[i] = true
		hint.path[i] = 255
	}

	for key := -1; key <= 4097; key += 11 {
		want_value, want_ok := get(&tr, key)
		got_value, got_ok := get_hint(&tr, key, &hint)
		testing.expect_value(t, got_ok, want_ok)
		if got_ok {
			testing.expect_value(t, got_value, want_value)
		}
	}

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_hint_generation_sync_after_structural_change :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 2})
	defer destroy(&tr)

	hint := Path_Hint{}
	for i := 0; i < 128; i += 1 {
		_, _ = set_hint(&tr, i, &hint)
	}

	v, ok := get_hint(&tr, 64, &hint)
	testing.expect(t, ok, "get_hint should find existing key")
	testing.expect_value(t, v, 64)

	old_generation := tr.hint_generation
	old_split_count := stats(&tr).split_count
	for stats(&tr).split_count == old_split_count {
		_, _ = set(&tr, count(&tr) + 1000)
	}
	testing.expect(t, tr.hint_generation > old_generation, "split should advance tree hint generation")

	// Simulate a stale reused hint from an older tree structure.
	hint.generation = old_generation
	for i := 0; i < MAX_HINT_DEPTH; i += 1 {
		hint.used[i] = true
		hint.path[i] = 255
	}

	v, ok = get_hint(&tr, 64, &hint)
	testing.expect(t, ok, "get_hint should still work with stale generation hint")
	testing.expect_value(t, v, 64)
	testing.expect_value(t, hint.generation, tr.hint_generation)

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_hint_generation_advances_on_root_split :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 2})
	defer destroy(&tr)

	// degree=2 => max_items=3 at root
	for i := 0; i < 3; i += 1 {
		_, _ = set(&tr, i)
	}
	testing.expect_value(t, int(tr.root.item_count), tr.max_items)

	before := tr.hint_generation
	_, replaced := set(&tr, 100)
	testing.expect(t, !replaced, "root split insert should not replace")
	testing.expect(t, tr.hint_generation > before, "root split should advance hint generation")
	testing.expect(t, tr.root != nil && !tr.root.leaf, "root split should create internal root")

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_set_hint_heavy_split_insert_and_replace :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 2})
	defer destroy(&tr)

	model := make(map[int]bool, 8192)
	defer delete(model)

	keys := make([dynamic]int, 0, 4096)
	defer delete(keys)

	hint := Path_Hint{}

	for i := 0; i < 4096; i += 1 {
		append(&keys, i)
		prev, replaced := set_hint(&tr, i, &hint)
		testing.expect(t, !replaced, "set_hint insert should not replace")
		testing.expect_value(t, prev, 0)
		model[i] = true
	}

	btree_test_assert_tree_matches_model(t, &tr, model)

	rng_state := u64(0xfeed_beef_0001)
	btree_test_shuffle(keys[:], &rng_state)
	for k in keys {
		prev, replaced := set_hint(&tr, k, &hint)
		testing.expect(t, replaced, "set_hint reinsert should replace existing key")
		testing.expect_value(t, prev, k)
	}

	btree_test_assert_tree_matches_model(t, &tr, model)
}

@(test)
test_btree_top_down_insert_replaces_promoted_median :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 2})
	defer destroy(&tr)

	// Grow the tree until some internal node has a full child. Re-inserting that
	// child's median key exercises the top-down branch where
	// split child median equals the incoming key.
	next_key := 0
	target_key := 0
	found_target := false
	for pass := 0; pass < 8 && !found_target; pass += 1 {
		for i := 0; i < 1024; i += 1 {
			_, replaced := set(&tr, next_key)
			testing.expect(t, !replaced, "initial population should only insert")
			next_key += 1
		}

		target_key, found_target = btree_test_find_promoted_median_candidate_in_subtree(tr.root, tr.max_items)
	}
	testing.expect(t, found_target, "expected to find a full child candidate for promoted-median replace")
	if !found_target {
		return
	}

	count_before := count(&tr)
	reset_stats(&tr)
	prev, replaced := set(&tr, target_key)
	testing.expect(t, replaced, "reinserted key should replace existing value")
	testing.expect_value(t, prev, target_key)
	testing.expect_value(t, count(&tr), count_before)

	s := stats(&tr)
	testing.expect(t, s.split_count > 0, "top-down insert should split full child before descending")

	v, ok := get(&tr, target_key)
	testing.expect(t, ok, "target key should remain retrievable after replace")
	testing.expect_value(t, v, target_key)

	btree_test_assert_tree_sane(t, &tr)
}

@(test)
test_btree_delete_heavy_rebalance_with_and_without_hints :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 2})
	defer destroy(&tr)

	model := make(map[int]bool, 8192)
	defer delete(model)

	keys := make([dynamic]int, 0, 4096)
	defer delete(keys)

	for i := 0; i < 4096; i += 1 {
		append(&keys, i)
		_, replaced := set(&tr, i)
		testing.expect(t, !replaced, "set should not replace during setup")
		model[i] = true
	}

	btree_test_assert_tree_matches_model(t, &tr, model)

	rng_state := u64(0xc001_d00d_0002)
	btree_test_shuffle(keys[:], &rng_state)
	hint := Path_Hint{}
	for i, k in keys {
		prev: int
		removed := false
		if i % 2 == 0 {
			prev, removed = remove(&tr, k)
		} else {
			prev, removed = remove_hint(&tr, k, &hint)
		}

		testing.expect(t, removed, "remove path should delete existing key")
		testing.expect_value(t, prev, k)
		delete_key(&model, k)

		if i % 257 == 0 {
			btree_test_assert_tree_matches_model(t, &tr, model)
		}
	}

	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "root should be nil after deleting all keys")
	btree_test_assert_tree_matches_model(t, &tr, model)
}

@(test)
test_btree_large_random_insert_delete :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 16})
	defer destroy(&tr)

	N :: 20_000
	keys := make([dynamic]int, 0, N)
	defer delete(keys)
	for i := 0; i < N; i += 1 {
		append(&keys, i)
	}

	rng_state := u64(0x1122334455667788)
	btree_test_shuffle(keys[:], &rng_state)
	for i, k in keys {
		_, replaced := set(&tr, k)
		testing.expect(t, !replaced, "large random insert should not replace")
		if i % 5000 == 0 {
			btree_test_assert_tree_sane(t, &tr)
		}
	}
	btree_test_assert_tree_sane(t, &tr)
	testing.expect_value(t, count(&tr), N)
	metrics := btree_test_tree_metrics(&tr)
	testing.expect(t, metrics.node_count > 0, "metrics should report nodes for non-empty tree")
	fill_factor := f64(metrics.item_count) / f64(metrics.node_count * tr.max_items)
	testing.expect(t, fill_factor > 0.20, "random insert fill factor should stay above low-water mark")

	branch_factor := max(tr.min_items + 1, 2)
	height_upper_bound := 1
	capacity := 1
	for capacity < count(&tr) {
		capacity *= branch_factor
		height_upper_bound += 1
	}
	height_upper_bound += 1
	testing.expect(t, metrics.height <= height_upper_bound, "tree height should stay within expected bound")

	btree_test_shuffle(keys[:], &rng_state)
	for i := 0; i < N * 9 / 10; i += 1 {
		_, removed := remove(&tr, keys[i])
		testing.expect(t, removed, "large random delete should remove existing key")
		if i % 4000 == 0 {
			btree_test_assert_tree_sane(t, &tr)
		}
	}

	btree_test_assert_tree_sane(t, &tr)
	testing.expect_value(t, count(&tr), N / 10)
}

@(test)
test_btree_adversarial_delete_patterns :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	N :: 4096
	for i := 0; i < N; i += 1 {
		_, _ = set(&tr, i)
	}

	// Pattern 1: every other key.
	for i := 0; i < N; i += 2 {
		prev, removed := remove(&tr, i)
		testing.expect(t, removed, "every-other pattern should remove key")
		testing.expect_value(t, prev, i)
	}
	btree_test_assert_tree_sane(t, &tr)

	// Pattern 2: from one side only (leftmost remaining keys).
	for i := 1; i < N; i += 4 {
		_, removed := remove(&tr, i)
		testing.expect(t, removed, "left-side pattern should remove key")
	}
	btree_test_assert_tree_sane(t, &tr)

	// Pattern 3: repeatedly remove the current median key.
	for count(&tr) > 0 {
		it := iter(&tr)
		mid_index := count(&tr) / 2
		mid_value := 0
		j := 0
		for ok := iter_first(&it); ok; ok = iter_next(&it) {
			if j == mid_index {
				mid_value = item(&it)
				break
			}
			j += 1
		}
		iter_destroy(&it)

		prev, removed := remove(&tr, mid_value)
		testing.expect(t, removed, "median-delete pattern should remove key")
		testing.expect_value(t, prev, mid_value)

		if count(&tr) % 257 == 0 {
			btree_test_assert_tree_sane(t, &tr)
		}
	}

	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "root should be nil after full adversarial drain")
}

@(test)
test_btree_repeated_full_drain_and_repopulate :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	N :: 3000
	keys := make([dynamic]int, 0, N)
	defer delete(keys)
	for i := 0; i < N; i += 1 {
		append(&keys, i)
	}

	rng_state := u64(0x44aa88cc55dd99ee)
	hint := Path_Hint{}
	for round := 0; round < 5; round += 1 {
		btree_test_shuffle(keys[:], &rng_state)
		for i, k in keys {
			_, replaced := set_hint(&tr, k, &hint)
			testing.expect(t, !replaced, "repopulate should insert fresh keys")
			if i % 700 == 0 {
				btree_test_assert_tree_sane(t, &tr)
			}
		}
		testing.expect_value(t, count(&tr), N)

		btree_test_shuffle(keys[:], &rng_state)
		for i, k in keys {
			_, removed := remove_hint(&tr, k, &hint)
			testing.expect(t, removed, "drain should remove existing keys")
			if i % 700 == 0 {
				btree_test_assert_tree_sane(t, &tr)
			}
		}

		testing.expect_value(t, count(&tr), 0)
		testing.expect(t, tr.root == nil, "tree should collapse to nil root after full drain")
	}
}

@(test)
test_btree_iterator_mixed_direction_walk :: proc(t: ^testing.T) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = 8})
	defer destroy(&tr)

	N :: 1024
	for i := 0; i < N; i += 1 {
		_, _ = set(&tr, i)
	}

	it := iter(&tr)
	defer iter_destroy(&it)
	start := N / 2
	testing.expect(t, iter_seek(&it, start), "iter_seek should position on exact start key")
	testing.expect_value(t, item(&it), start)

	pos := start
	rng_state := u64(0xa5a5f00d12345678)
	for step := 0; step < 5000; step += 1 {
		go_next := (btree_test_rng_next(&rng_state) & 1) == 1
		if pos == 0 {
			go_next = true
		} else if pos == N - 1 {
			go_next = false
		}

		if go_next {
			testing.expect(t, iter_next(&it), "iter_next should succeed inside bounds")
			pos += 1
		} else {
			testing.expect(t, iter_prev(&it), "iter_prev should succeed inside bounds")
			pos -= 1
		}

		testing.expect_value(t, item(&it), pos)
	}
}

btree_test_next_permutation :: proc(values: []int) -> bool {
	if len(values) < 2 {
		return false
	}

	i := len(values) - 2
	for i >= 0 && values[i] >= values[i + 1] {
		i -= 1
	}
	if i < 0 {
		return false
	}

	j := len(values) - 1
	for values[j] <= values[i] {
		j -= 1
	}
	values[i], values[j] = values[j], values[i]

	for left, right := i + 1, len(values) - 1; left < right; left, right = left + 1, right - 1 {
		values[left], values[right] = values[right], values[left]
	}

	return true
}

btree_test_assert_present_keys :: proc(t: ^testing.T, tr: ^BTreeG(int, Test_Int_Order), present: []bool) {
	btree_test_assert_tree_sane(t, tr)

	expected := make([dynamic]int, 0, len(present))
	defer delete(expected)
	for key := 0; key < len(present); key += 1 {
		if present[key] {
			append(&expected, key)
		}
	}

	testing.expect_value(t, count(tr), len(expected))

	scanned := btree_test_collect_scan(tr)
	defer delete(scanned)
	btree_test_expect_slice_equal(t, scanned[:], expected[:], "scan order should match present set")

	for key := 0; key < len(present); key += 1 {
		v, ok := get(tr, key)
		testing.expect_value(t, ok, present[key])
		if present[key] {
			testing.expect_value(t, v, key)
		}
	}
}

btree_test_run_insert_delete_order :: proc(t: ^testing.T, degree: int, insert_order, delete_order: []int) {
	tr := create_ordered(int, Test_Int_Order, Options{degree = degree})
	defer destroy(&tr)

	present := make([]bool, len(insert_order))
	defer delete(present)

	for key in insert_order {
		_, replaced := set(&tr, key)
		testing.expect(t, !replaced, "insert permutation should only add fresh keys")
		present[key] = true
		btree_test_assert_present_keys(t, &tr, present)
	}

	hint := Path_Hint{}
	for i, key in delete_order {
		prev: int
		removed := false
		if i % 2 == 0 {
			prev, removed = remove(&tr, key)
		} else {
			prev, removed = remove_hint(&tr, key, &hint)
		}

		testing.expect(t, removed, "delete permutation should remove existing key")
		testing.expect_value(t, prev, key)
		present[key] = false
		btree_test_assert_present_keys(t, &tr, present)
	}

	testing.expect_value(t, count(&tr), 0)
	testing.expect(t, tr.root == nil, "tree should be empty after permutation drain")
}

@(test)
test_btree_exhaustive_small_permutation_insert_delete :: proc(t: ^testing.T) {
	base := [6]int{0, 1, 2, 3, 4, 5}
	asc := [6]int{0, 1, 2, 3, 4, 5}
	desc := [6]int{5, 4, 3, 2, 1, 0}
	DEGREES :: [3]int{2, 3, 8}

	for degree in DEGREES {
		perm := base
		permutation_count := 0

		for {
			permutation_count += 1

			same := perm
			btree_test_run_insert_delete_order(t, degree, perm[:], same[:])

			reversed := perm
			for left, right := 0, len(reversed) - 1; left < right; left, right = left + 1, right - 1 {
				reversed[left], reversed[right] = reversed[right], reversed[left]
			}
			btree_test_run_insert_delete_order(t, degree, perm[:], reversed[:])

			btree_test_run_insert_delete_order(t, degree, perm[:], asc[:])
			btree_test_run_insert_delete_order(t, degree, perm[:], desc[:])

			if !btree_test_next_permutation(perm[:]) {
				break
			}
		}

		testing.expect_value(t, permutation_count, 720)
	}
}

// -------------------------------------------------------------------------
// Hegel property-based tests
// -------------------------------------------------------------------------

btree_test_draw_permutation :: proc(tc: ^hgl.Test_Case, count: int) -> ([]int, hgl.Draw_Error) {
	items := make([]int, count)
	for i in 0 ..< count {
		items[i] = i
	}

	for i in 0 ..< count - 1 {
		j_raw, draw_err := hgl.draw_i64(tc, i64(i), i64(count - 1))
		if draw_err != nil {
			delete(items)
			return nil, draw_err
		}
		j := int(j_raw)
		items[i], items[j] = items[j], items[i]
	}

	return items, nil
}

@(test)
test_hegel_model_equivalence_mixed_ops :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_model_equivalence_mixed_ops, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "hegel btree model-equivalence property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_model_equivalence_mixed_ops :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	degree_raw, draw_err := hgl.draw_i64(tc, 2, 64)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil {
		return hgl.interesting("draw degree")
	}
	degree := int(degree_raw)

	op_count_raw: i64
	op_count_raw, draw_err = hgl.draw_i64(tc, 50, 800)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil {
		return hgl.interesting("draw op_count")
	}
	op_count := int(op_count_raw)

	key_range_raw: i64
	key_range_raw, draw_err = hgl.draw_i64(tc, 32, 4096)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil {
		return hgl.interesting("draw key_range")
	}
	key_range := int(key_range_raw)

	tr := create_ordered(int, Test_Int_Order, Options{degree = degree})
	defer destroy(&tr)

	model := make(map[int]bool, key_range)
	defer delete(model)

	hint := Path_Hint{}

	for i := 0; i < op_count; i += 1 {
		key_raw, key_err := hgl.draw_i64(tc, 0, i64(key_range - 1))
		if key_err == .Stop_Test do return hgl.abort()
		if key_err != nil do return hgl.interesting("draw operation key")
		key := int(key_raw)

		op_type_raw, op_type_err := hgl.draw_i64(tc, 0, 99)
		if op_type_err == .Stop_Test do return hgl.abort()
		if op_type_err != nil do return hgl.interesting("draw operation type")
		op_type := int(op_type_raw)

		switch {
		case op_type < 45:
			// Alternate between plain set and hint set
			if i % 2 == 0 {
				_, _ = set(&tr, key)
			} else {
				_, _ = set_hint(&tr, key, &hint)
			}
			model[key] = true

		case op_type < 75:
			// Alternate between plain remove and hint remove
			if i % 2 == 0 {
				_, _ = remove(&tr, key)
			} else {
				_, _ = remove_hint(&tr, key, &hint)
			}
			delete_key(&model, key)

		case:
			plain_v, plain_ok := get(&tr, key)
			hint_v, hint_ok := get_hint(&tr, key, &hint)
			if plain_ok != hint_ok {
				return hgl.interesting("get_hint parity mismatch (ok)")
			}
			if plain_ok && plain_v != hint_v {
				return hgl.interesting("get_hint parity mismatch (value)")
			}
			if plain_ok != model[key] {
				return hgl.interesting("get/model parity mismatch")
			}
			if plain_ok && plain_v != key {
				return hgl.interesting("get value wrong")
			}
		}
	}

	// Final structural verification
	scanned := btree_test_collect_scan(&tr)
	defer delete(scanned)

	if len(scanned) != count(&tr) {
		return hgl.interesting("scan length != count")
	}
	if len(scanned) != len(model) {
		return hgl.interesting("scan length != model size")
	}

	for i := 1; i < len(scanned); i += 1 {
		if scanned[i - 1] >= scanned[i] {
			return hgl.interesting("scan not strictly sorted")
		}
	}

	for key, exists in model {
		if !exists {
			continue
		}
		v, ok := get(&tr, key)
		if !ok {
			return hgl.interesting("model key missing in tree")
		}
		if v != key {
			return hgl.interesting("model key value wrong")
		}
		if !contains(&tr, key) {
			return hgl.interesting("contains false for model key")
		}
	}

	reversed := btree_test_collect_reverse(&tr)
	defer delete(reversed)
	if len(reversed) != len(scanned) {
		return hgl.interesting("reverse length mismatch")
	}
	for i := 0; i < len(reversed); i += 1 {
		if reversed[i] != scanned[len(scanned) - 1 - i] {
			return hgl.interesting("reverse mismatch")
		}
	}

	return hgl.valid()
}

// Text eligibility is deliberately not part of identity: unsupported query
// keys must still find eligible records, and replacements can change eligibility.
Text_Test_Item :: struct {
	text:        string,
	id:          int,
	version:     int,
	unsupported: bool,
}

text_test_cmp :: proc(a, b: Text_Test_Item) -> int {
	if a.text < b.text do return -1
	if a.text > b.text do return 1
	return test_cmp_int(a.id, b.id)
}

text_test_cmp_desc :: proc(a, b: Text_Test_Item) -> int {
	if a.text < b.text do return 1
	if a.text > b.text do return -1
	return test_cmp_int(a.id, b.id)
}

text_test_key :: proc(a: Text_Test_Item) -> (string, bool) {
	return a.text, !a.unsupported
}

Text_Test_Order :: Static_Order(Text_Test_Item, No_Projection, text_test_cmp_static, text_test_key_static)

text_test_cmp_static :: proc(a, b: rawptr, descending: bool) -> int {
	if descending do return text_test_cmp_desc((cast(^Text_Test_Item)a)^, (cast(^Text_Test_Item)b)^)
	return text_test_cmp((cast(^Text_Test_Item)a)^, (cast(^Text_Test_Item)b)^)
}

text_test_key_static :: proc(item: rawptr) -> (text: string, ok: bool) {
	return text_test_key((cast(^Text_Test_Item)item)^)
}

text_test_fixture :: proc(i: int) -> Text_Test_Item {
	// Start with a long shared prefix, then progressively shorten it after
	// reads have warmed the tree. Three IDs per text exercise comparator ties.
	texts := [?]string {
		"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/alpha",
		"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/beta",
		"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/gamma",
		"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/",
		"abcdefghijklmnopqrstuvwxyz/0123456789/common/",
		"abc",
		"ab",
		"a",
		"",
		"a\x00",
		"a\x00b",
		"a\x7f",
		"a\x80",
		"a\xff",
		"\x80",
		"\xff",
		"common/é",
		"common/ê",
		"common/\xc3",
		"abcd1xxxA",
		"abcd2xxxB",
		"abcd\x00xxxA",
		"abcd\x00xxxB",
		"abcdefgh1",
		"abcdefgh2",
	}
	return {text = texts[(i / 3) % len(texts)], id = i}
}

// Deliberately independent of the tree comparator: compare raw bytes explicitly,
// reverse only text ordering, and retain ascending secondary IDs in both orders.
text_test_model_compare :: proc(a, b: Text_Test_Item, descending: bool) -> int {
	text_order := 0
	for i in 0 ..< min(len(a.text), len(b.text)) {
		if a.text[i] != b.text[i] {
			text_order = a.text[i] < b.text[i] ? -1 : 1
			break
		}
	}
	if text_order == 0 && len(a.text) != len(b.text) do text_order = len(a.text) < len(b.text) ? -1 : 1
	if text_order != 0 do return descending ? -text_order : text_order
	if a.id == b.id do return 0
	return a.id < b.id ? -1 : 1
}

// The oracle uses only an independently sorted slice and public tree APIs.
// Looking up every fixture (including missing and ineligible queries) after
// every mutation both verifies lower bounds and warms caches for the next write.
text_test_check :: proc(tr: ^BTreeG(Text_Test_Item, $Order), model: []Text_Test_Item, descending: bool, hint: ^Path_Hint) -> string {
	want := make([]Text_Test_Item, len(model))
	defer delete(want)
	copy(want, model)
	slice.sort_by(want, proc(a, b: Text_Test_Item) -> bool {return text_test_model_compare(a, b, false) < 0})
	if descending {
		slice.sort_by(want, proc(a, b: Text_Test_Item) -> bool {return text_test_model_compare(a, b, true) < 0})
	}
	if count(tr) != len(want) do return "text count mismatch"
	it := iter(tr)
	defer iter_destroy(&it)
	n := 0
	for ok := iter_first(&it); ok; ok = iter_next(&it) {
		if n >= len(want) do return "extra forward item"
		if item(&it) != want[n] do return "text forward mismatch"
		n += 1
	}
	if n != len(want) do return "missing forward item"
	n = len(want)
	for ok := iter_last(&it); ok; ok = iter_prev(&it) {
		n -= 1
		if n < 0 do return "extra reverse item"
		if item(&it) != want[n] do return "text reverse mismatch"
	}
	if n != 0 do return "missing reverse item"
	// Also query every live model key, including keys outside the fixed fixture.
	// An absent secondary ID for each text checks lower bounds within tie runs.
	for i in 0 ..< 102 + 2 * len(want) {
		key := text_test_fixture(i)
		// Include both an absent tie-breaker and a key beyond the entire tree.
		if i == 96 do key = {
			text = "a",
			id   = -1,
		}
		if i == 97 do key = {
			text = "\xff\xff",
			id   = 999,
		}
		if i >= 98 && i < 102 {
			// Misses inside and outside long-prefix intervals must preserve
			// lower bounds, including descents through outer children.
			misses := [?]string {
				"aa",
				"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/alph",
				"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefix/alphaz",
				"abcdefghijklmnopqrstuvwxyz/0123456789/common/prefiy",
			}
			key.text = misses[i - 98]
			key.id = -1
		}
		if i >= 102 {
			key = want[(i - 102) / 2]
			if i % 2 != 0 do key.id = -1
		}
		lower := 0
		for lower < len(want) {
			c := text_test_model_compare(want[lower], key, descending)
			if c >= 0 do break
			lower += 1
		}
		exists := lower < len(want) && text_test_model_compare(want[lower], key, descending) == 0
		for unsupported in ([?]bool{false, true}) {
			key.unsupported = unsupported
			v, ok := get(tr, key)
			if ok != exists do return "text get presence mismatch"
			if ok && v != want[lower] do return "text get value mismatch"
			v, ok = get_hint(tr, key, hint)
			if ok != exists do return "text hinted get presence mismatch"
			if ok && v != want[lower] do return "text hinted get value mismatch"
			ok = iter_seek(&it, key)
			if ok != (lower < len(want)) do return "text seek presence mismatch"
			if ok && item(&it) != want[lower] do return "text seek lower bound mismatch"
			ok = iter_seek_hint(&it, key, hint)
			if ok != (lower < len(want)) do return "text hinted seek presence mismatch"
			if ok && item(&it) != want[lower] do return "text hinted seek lower bound mismatch"
		}
		// Exclusive pages around present AND absent cursors. Compare every item,
		// including crossing child boundaries and exhausting either tree end.
		key.unsupported = i % 2 != 0
		for reverse in ([?]bool{false, true}) {
			ok := iter_seek(&it, key)
			index := lower
			if reverse {
				index -= 1
				ok = ok ? iter_prev(&it) : iter_last(&it)
			} else if exists {
				index += 1
				ok = iter_next(&it)
			}
			for offset in 0 ..< 1 + i % 7 {
				if ok != (index >= 0 && index < len(want)) do return "text page length mismatch"
				if !ok do break
				if item(&it) != want[index] do return "text page item mismatch"
				index += reverse ? -1 : 1
				ok = reverse ? iter_prev(&it) : iter_next(&it)
			}
		}
	}
	return ""
}

text_test_mutate :: proc(
	tr: ^BTreeG(Text_Test_Item, $Order),
	model: ^[dynamic]Text_Test_Item,
	value: Text_Test_Item,
	op: int,
	hint: ^Path_Hint,
	other: ^BTreeG(Text_Test_Item, Order) = nil,
	other_hint: ^Path_Hint = nil,
) -> string {
	index := -1
	for v, i in model^ {
		if text_test_model_compare(v, value, false) == 0 {index = i; break}
	}
	prev: Text_Test_Item
	found: bool
	switch op {
	case 0:
		prev, found = set(tr, value)
	case 1:
		prev, found = set_hint(tr, value, hint)
	case 2:
		prev, found = load(tr, value)
	case 3:
		prev, found = remove(tr, value)
	case 4:
		prev, found = remove_hint(tr, value, hint)
	}
	if found != (index >= 0) do return "text mutation presence mismatch"
	if found && prev != model^[index] do return "text mutation previous value mismatch"
	if other != nil {
		other_prev: Text_Test_Item
		other_found: bool
		switch op {
		case 0:
			other_prev, other_found = set(other, value)
		case 1:
			other_prev, other_found = set_hint(other, value, other_hint)
		case 2:
			other_prev, other_found = load(other, value)
		case 3:
			other_prev, other_found = remove(other, value)
		case 4:
			other_prev, other_found = remove_hint(other, value, other_hint)
		}
		if other_found != found do return "text cached/uncached mutation presence differs"
		if found && other_prev != prev do return "text cached/uncached mutation previous value differs"
	}
	if op >= 3 {
		if index >= 0 do ordered_remove(model, index)
	} else if index >= 0 {
		model^[index] = value
	} else {
		append(model, value)
	}
	return ""
}

@(test)
test_text_search_mutations :: proc(t: ^testing.T) {
	text_test_search_mutations_order(t, Text_Test_Order)
}

@(test)
test_text_remove_prefix_boundaries :: proc(t: ^testing.T) {
	for descending in ([?]bool{false, true}) {
		tr := create_ordered(Text_Test_Item, Text_Test_Order, Options{degree = 3}, cache = .Text, descending = descending)
		defer destroy(&tr)
		model := make([dynamic]Text_Test_Item)
		defer delete(model)
		hint: Path_Hint
		texts := [?]string {
			"middle/common/a",
			"middle/common/b",
			"middle/common/c",
			"middle/common/d",
			"middle/common/e",
			"middle/common/f",
			"middle/common/g",
			"middle/common/h",
		}
		for i in 0 ..< 128 {
			value := Text_Test_Item {
				text = texts[i / 16],
				id   = i,
			}
			testing.expect_value(t, text_test_mutate(&tr, &model, value, 0, &hint), "")
		}
		// Border subtrees need not share the internal separators' prefix.
		// The short right-border key forces an optimistic wrong descent in
		// ascending order; no item may be removed before a full-key match.
		for text in ([?]string{"a", "z"}) {
			testing.expect_value(t, text_test_mutate(&tr, &model, {text = text, id = 200}, 0, &hint), "")
		}
		testing.expect_value(t, text_test_check(&tr, model[:], descending, &hint), "")
		for text in ([?]string{"z", "a", "", "middle/common/", "middle/common/z", "zzzz"}) {
			value := Text_Test_Item {
				text = text,
				id   = 200,
			}
			for _ in 0 ..< 2 {
				testing.expect_value(t, text_test_mutate(&tr, &model, value, 3, &hint), "")
				testing.expect_value(t, text_test_check(&tr, model[:], descending, &hint), "")
			}
		}
	}
}

text_test_search_mutations_order :: proc(t: ^testing.T, $Order: typeid) {
	for degree in ([?]int{2, 3, 0}) {
		for descending in ([?]bool{false, true}) {
			tr: BTreeG(Text_Test_Item, Order)
			init_ordered(&tr, Options{degree = degree}, cache = .Text, descending = descending)
			defer destroy(&tr)
			model := make([dynamic]Text_Test_Item)
			defer delete(model)
			hint: Path_Hint
			// Splits, eligibility-changing replacements, merges to empty, then
			// ascending/descending ordered load into a previously used tree.
			for phase in 0 ..< 4 {
				for j in 0 ..< 96 {
					i := j
					if phase == 2 do i = (j * 37) % 96
					v := text_test_fixture(i)
					op := j % 2
					if phase == 1 {
						v.version = 1
						v.unsupported = j % 7 == 0
					}
					if phase == 2 do op = 3 + j % 2
					if phase == 3 {
						// Identical text and ascending IDs are sorted in both modes.
						v = {
							text = "reload/common/prefix",
							id   = j,
						}
						op = 2
					}
					testing.expect_value(t, text_test_mutate(&tr, &model, v, op, &hint), "")
					// Warm the new load keys as well as the original fixture keys.
					_, _ = get(&tr, v)
					testing.expect_value(t, text_test_check(&tr, model[:], descending, &hint), "")
				}
			}
		}
	}
}

@(test)
test_hegel_text_search_model :: proc(t: ^testing.T) {
	if !hgl.can_run() do return
	result, err := hgl.run(prop_text_search_model, nil, {test_cases = 200})
	testing.expectf(t, err == nil, "text model property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_text_search_model :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	config, err := hgl.draw_i64(tc, 0, 11)
	if err == .Stop_Test do return hgl.abort()
	if err != nil do return hgl.interesting("draw text configuration")
	degrees := [?]int{2, 3, 0}
	descending := config % 2 != 0
	// Reuse generated texts across mutations so random bytes exercise successful
	// replacements/deletions and ID ties, not just unrelated insertion misses.
	prefix, prefix_err := hgl.draw_bytes(tc, 0, 40)
	if prefix_err == .Stop_Test do return hgl.abort()
	if prefix_err != nil do return hgl.interesting("draw text prefix")
	defer delete(prefix)
	storage: [16][104]byte
	texts: [16]string
	for &text, i in texts {
		suffix, suffix_err := hgl.draw_bytes(tc, 0, 64)
		if suffix_err == .Stop_Test do return hgl.abort()
		if suffix_err != nil do return hgl.interesting("draw text suffix")
		prefix_text := string(prefix)
		switch i % 4 {
		case 1:
			prefix_text = "\x00\x00\x00\x00\x00\x00\x00\x00"
		case 2:
			prefix_text = "\xff\xff\xff\xff\xff\xff\xff\xff"
		case 3:
			prefix_text = ""
		}
		copy(storage[i][:], transmute([]byte)prefix_text)
		copy(storage[i][len(prefix_text):], suffix)
		length := len(prefix_text) + len(suffix)
		text = length == 0 ? "" : string(storage[i][:length])
		delete(suffix)
	}
	// Compare uncached and cached instances of the same static policy.
	tr := create_ordered(Text_Test_Item, Text_Test_Order, Options{degree = degrees[(config / 2) % len(degrees)]}, descending = descending)
	defer destroy(&tr)
	static_tr := create_ordered(
		Text_Test_Item,
		Text_Test_Order,
		Options{degree = degrees[(config / 2) % len(degrees)]},
		cache = .Text,
		descending = descending,
	)
	defer destroy(&static_tr)
	static_hint: Path_Hint
	model := make([dynamic]Text_Test_Item)
	defer delete(model)
	hint: Path_Hint
	// Start above a full degree-32 leaf, then warm every key before mutations.
	// Generated texts share three IDs each, so both word and full-text ties occur.
	for i in 0 ..< 96 {
		v := text_test_fixture(i)
		if i >= 48 do v.text = texts[(i - 48) / 3]
		if failure := text_test_mutate(&tr, &model, v, 0, &hint, &static_tr, &static_hint); failure != "" {
			return hgl.interesting(failure)
		}
	}
	if failure := text_test_check(&static_tr, model[:], descending, &static_hint); failure != "" {
		return hgl.interesting(failure)
	}
	// Exercise both read-after-write and mutation bursts without intervening
	// reads that could refresh a stale cache before the next mutation.
	check_interval := config < 6 ? 1 : 8
	for step in 0 ..< 128 {
		draw, draw_err := hgl.draw_i64(tc, 0, 959)
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw text operation")
		v := text_test_fixture(int(draw % 96))
		if draw % 96 >= 48 do v.text = texts[(int(draw % 96) - 48) / 3]
		// Force some operations onto live keys even when the generated stream
		// otherwise keeps selecting absent keys. Payload changes check replacement.
		if step % 4 == 0 && len(model) > 0 do v = model[int(draw) % len(model)]
		v.version = step
		// Keep burst cases mostly eligible so they exercise maintained words,
		// rather than spending almost every search in the fallback comparator.
		v.unsupported = draw >= 480 && (config < 6 || step % 17 == 0)
		op := int(draw / 96) % 5
		if failure := text_test_mutate(&tr, &model, v, op, &hint, &static_tr, &static_hint); failure != "" {
			return hgl.interesting(failure)
		}
		if (step + 1) % check_interval == 0 {
			if failure := text_test_check(&tr, model[:], descending, &hint); failure != "" {
				return hgl.interesting(failure)
			}
			if failure := text_test_check(&static_tr, model[:], descending, &static_hint); failure != "" {
				return hgl.interesting(failure)
			}
		}
	}
	// Generated successful deletions force shrinking and root collapse, with
	// warmed searches between batches. Both trees keep sharing the same oracle.
	for len(model) > 0 {
		index, draw_err := hgl.draw_i64(tc, 0, i64(len(model) - 1))
		if draw_err == .Stop_Test do return hgl.abort()
		if draw_err != nil do return hgl.interesting("draw text drain")
		v := model[int(index)]
		if failure := text_test_mutate(&tr, &model, v, 3 + int(index % 2), &hint, &static_tr, &static_hint); failure != "" {
			return hgl.interesting(failure)
		}
		if len(model) % check_interval == 0 {
			if failure := text_test_check(&tr, model[:], descending, &hint); failure != "" {
				return hgl.interesting(failure)
			}
			if failure := text_test_check(&static_tr, model[:], descending, &static_hint); failure != "" {
				return hgl.interesting(failure)
			}
		}
	}
	return hgl.valid()
}

@(test)
test_hegel_insert_order_independence :: proc(t: ^testing.T) {
	if !hgl.can_run() {
		return
	}

	result, err := hgl.run(prop_insert_order_independence, nil, {test_cases = 5000})
	testing.expectf(t, err == nil, "hegel btree insert-order property failed: err=%v interesting=%v", err, result.interesting_test_cases)
}

prop_insert_order_independence :: proc(tc: ^hgl.Test_Case, _: rawptr) -> hgl.Body_Result {
	degree_raw, draw_err := hgl.draw_i64(tc, 2, 64)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil {
		return hgl.interesting("draw degree")
	}
	degree := int(degree_raw)

	count_raw: i64
	count_raw, draw_err = hgl.draw_i64(tc, 20, 1000)
	if draw_err == .Stop_Test do return hgl.abort()
	if draw_err != nil {
		return hgl.interesting("draw count")
	}
	key_count := int(count_raw)

	tr := create_ordered(int, Test_Int_Order, Options{degree = degree})
	defer destroy(&tr)

	insert_order, insert_order_err := btree_test_draw_permutation(tc, key_count)
	if insert_order_err == .Stop_Test do return hgl.abort()
	if insert_order_err != nil do return hgl.interesting("draw insert order")
	defer delete(insert_order)

	for k in insert_order {
		_, replaced := set(&tr, k)
		if replaced {
			return hgl.interesting("insert replaced on fresh key")
		}
	}

	if count(&tr) != key_count {
		return hgl.interesting("count mismatch after insert")
	}

	scanned := btree_test_collect_scan(&tr)
	defer delete(scanned)

	if len(scanned) != key_count {
		return hgl.interesting("scan length mismatch after insert")
	}

	for i := 0; i < key_count; i += 1 {
		if scanned[i] != i {
			return hgl.interesting("scan value mismatch after insert")
		}
	}

	for i := 1; i < len(scanned); i += 1 {
		if scanned[i - 1] >= scanned[i] {
			return hgl.interesting("scan not sorted after insert")
		}
	}

	reversed := btree_test_collect_reverse(&tr)
	defer delete(reversed)
	if len(reversed) != key_count {
		return hgl.interesting("reverse length mismatch after insert")
	}
	for i := 0; i < key_count; i += 1 {
		if reversed[i] != key_count - 1 - i {
			return hgl.interesting("reverse value mismatch after insert")
		}
	}

	delete_order, delete_order_err := btree_test_draw_permutation(tc, key_count)
	if delete_order_err == .Stop_Test do return hgl.abort()
	if delete_order_err != nil do return hgl.interesting("draw delete order")
	defer delete(delete_order)

	for i, k in delete_order {
		prev, removed := remove(&tr, k)
		if !removed {
			return hgl.interesting("delete missing existing key")
		}
		if prev != k {
			return hgl.interesting("delete returned wrong value")
		}
		if i % 100 == 0 {
			partial := btree_test_collect_scan(&tr)
			defer delete(partial)
			for j := 1; j < len(partial); j += 1 {
				if partial[j - 1] >= partial[j] {
					return hgl.interesting("partial scan not sorted during delete")
				}
			}
		}
	}

	if count(&tr) != 0 {
		return hgl.interesting("count non-zero after full delete")
	}
	if tr.root != nil {
		return hgl.interesting("root not nil after full delete")
	}

	return hgl.valid()
}

Numeric_Test_Projection :: enum u8 {
	Partial,
	All_Tied,
}
Numeric_Test_Order :: Static_Order(u64, Numeric_Test_Projection, numeric_test_compare, static_no_text, numeric_test_word)

numeric_test_compare :: proc(a, b: rawptr, descending: bool) -> int {
	cmp := test_cmp_u64((^u64)(a)^, (^u64)(b)^)
	return descending ? -cmp : cmp
}

numeric_test_word :: proc(item: rawptr, descending: bool, projection: rawptr) -> u64 {
	// One policy supports both partial collisions and completely tied nodes.
	word := (^Numeric_Test_Projection)(projection)^ == .Partial ? (^u64)(item)^ >> 4 : 0
	return descending ? ~word : word
}

@(test)
test_numeric_cache_mutations_and_seeks :: proc(t: ^testing.T) {
	for config in ([?]struct {
			cache:      Cache_Mode,
			projection: Numeric_Test_Projection,
		}{{.None, .Partial}, {.Numeric, .Partial}, {.Numeric, .All_Tied}}) {
		for descending in ([?]bool{false, true}) {
			for degree in ([?]int{2, 3, 32}) {
				tr := create_ordered(
					u64,
					Numeric_Test_Order,
					Options{degree = degree},
					descending = descending,
					cache = config.cache,
					projection = config.projection,
				)
				defer destroy(&tr)
				present: [129]bool
				hint: Path_Hint
				it := iter(&tr)
				defer iter_destroy(&it)
				for step in 0 ..< 2 * len(present) {
					key := u64((step * 73) % len(present))
					if step < len(present) {
						_, replaced := set(&tr, key)
						testing.expect(t, !replaced)
						present[key] = true
						_, replaced = set_hint(&tr, key, &hint)
						testing.expect(t, replaced)
					} else {
						_, removed := remove(&tr, key)
						testing.expect(t, removed)
						present[key] = false
					}
					for query in 0 ..< len(present) + 1 {
						value, found := get(&tr, u64(query))
						testing.expect_value(t, found, query < len(present) && present[query])
						if found do testing.expect_value(t, value, u64(query))
						expected := descending ? min(query, len(present) - 1) : query
						for expected >= 0 && expected < len(present) && !present[expected] {
							expected += descending ? -1 : 1
						}
						ok := iter_seek(&it, u64(query))
						testing.expect_value(t, ok, expected >= 0 && expected < len(present))
						if ok do testing.expect_value(t, item(&it), u64(expected))
					}
				}
				testing.expect_value(t, count(&tr), 0)
			}
		}
	}
}
