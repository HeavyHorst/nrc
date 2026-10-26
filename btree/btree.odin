package btree

import "core:mem"

DEFAULT_DEGREE :: 32
MAX_HINT_DEPTH :: 8
// A degree-2 tree with L levels needs at least 2^L - 1 items. The signed
// int count therefore bounds its height below this many stack entries.
MAX_ITER_DEPTH :: size_of(int) * 8
LINEAR_SEARCH_NODE_CUTOFF :: 31

CACHE_LINE_BYTES :: 64

Path_Hint :: struct {
	used:       [MAX_HINT_DEPTH]bool,
	path:       [MAX_HINT_DEPTH]u8,
	generation: u64,
}

BTree_Stats :: struct {
	split_count:        u64,
	rebalance_count:    u64,
	merge_count:        u64,
	borrow_left_count:  u64,
	borrow_right_count: u64,
}

Options :: struct {
	degree: int,
}

Cache_Mode :: enum u8 {
	None,
	Text,
	Numeric,
}

// Policies without selectable numeric projections use this single-value type.
No_Projection :: enum u8 {
	None,
}

// Construction checks the policy's item type against the tree. Adapters must
// cast item/projection pointers to the declared types. Procedure constants must
// pass through a polymorphic procedure before invocation on this Odin version.
Static_Order :: struct(
	$Item: typeid,
	$Projection: typeid,
	$Compare: proc(a, b: rawptr, descending: bool) -> int,
	$Text_Key: proc(item: rawptr) -> (text: string, ok: bool) = static_no_text,
	$Numeric_Key: proc(item: rawptr, descending: bool, projection: rawptr) -> u64 = static_no_numeric,
) {}

// A procedure sentinel avoids this Odin version's nil-polymorphic-proc codegen bug.
static_no_numeric :: proc(item: rawptr, descending: bool, projection: rawptr) -> u64 {return 0}

static_no_text :: proc(item: rawptr) -> (text: string, ok: bool) {
	return "", false
}

Node :: struct($T: typeid) {
	items:       [^]T,
	children:    [^]^Node(T),
	item_count:  u16,
	child_count: u16,
	leaf:        bool,
}

BTreeG :: struct($T: typeid, $Order: typeid) {
	root:            ^Node(T),
	count:           int,
	min_items:       int,
	max_items:       int,
	hint_generation: u64,
	stats:           BTree_Stats,
	cache:           Cache_Mode,
	descending:      bool,
	projection:      Order.Projection,
	empty:           T,
	allocator:       mem.Allocator,
}

Iter_Stack_Item :: struct($T: typeid) {
	n: ^Node(T),
	i: int,
}

IterG :: struct($T: typeid, $Order: typeid) {
	tr:      ^BTreeG(T, Order),
	seeked:  bool,
	atstart: bool,
	atend:   bool,
	stack:   [MAX_ITER_DEPTH]Iter_Stack_Item(T),
	depth:   int,
	item:    T,
}

degree_to_min_max :: proc(degree: int) -> (min_items: int, max_items: int) {
	deg := degree
	if deg <= 0 {
		deg = DEFAULT_DEGREE
	} else if deg == 1 {
		deg = 2
	}

	max_items = deg * 2 - 1
	min_items = max_items / 2
	return
}

init_ordered :: proc {
	init_ordered_default,
	init_ordered_projection,
}

// Resolve the policy's default projection in the body: this Odin version cannot
// resolve Order.Projection in a procedure parameter type or infer a generic default.
init_ordered_default :: proc(tr: ^BTreeG($T, $Order), opts := Options{}, allocator := context.allocator, cache: Cache_Mode = .None, descending := false) {
	projection: Order.Projection
	init_ordered_projection(tr, opts, allocator, cache, descending, projection)
}

init_ordered_projection :: proc(
	tr: ^BTreeG($T, $Order),
	opts := Options{},
	allocator := context.allocator,
	cache: Cache_Mode = .None,
	descending := false,
	projection: $Projection,
) {
	#assert(Order.Item == T)
	#assert(Order.Projection == Projection)
	tr.cache = cache
	tr.descending = descending
	tr.projection = projection
	tr.allocator = allocator
	tr.min_items, tr.max_items = degree_to_min_max(opts.degree)
	if tr.max_items > 65534 {
		panic("max_items exceeds u16 count capacity")
	}
	tr.hint_generation = 1
	tr.stats = BTree_Stats{}
}

create_ordered :: proc {
	create_ordered_default,
	create_ordered_projection,
}

create_ordered_default :: proc(
	$T: typeid,
	$order: typeid,
	opts := Options{},
	allocator := context.allocator,
	cache: Cache_Mode = .None,
	descending := false,
) -> BTreeG(T, order) {
	tr := BTreeG(T, order){}
	init_ordered_default(&tr, opts, allocator, cache, descending)
	return tr
}

create_ordered_projection :: proc(
	$T: typeid,
	$order: typeid,
	opts := Options{},
	allocator := context.allocator,
	cache: Cache_Mode = .None,
	descending := false,
	projection: $Projection,
) -> BTreeG(T, order) {
	tr := BTreeG(T, order){}
	init_ordered_projection(&tr, opts, allocator, cache, descending, projection)
	return tr
}

destroy :: proc(tr: ^BTreeG($T, $Order)) {
	if tr.root != nil {
		node_destroy(tr, tr.root)
		tr.root = nil
	}
	tr.count = 0
	tr.hint_generation += 1
}

path_hint_sync_generation :: proc(tr: ^BTreeG($T, $Order), hint: ^Path_Hint) {
	if hint == nil {
		return
	}

	// Any structural mutation (split/merge/rebalance/root swap) bumps
	// tr.hint_generation. Mismatch means cached path slots may point into
	// stale topology, so we invalidate them eagerly.
	if hint.generation != tr.hint_generation {
		for i := 0; i < MAX_HINT_DEPTH; i += 1 {
			hint.used[i] = false
		}
		hint.generation = tr.hint_generation
	}
}

count :: proc(tr: ^BTreeG($T, $Order)) -> int {
	return tr.count
}

stats :: proc(tr: ^BTreeG($T, $Order)) -> BTree_Stats {
	return tr.stats
}

reset_stats :: proc(tr: ^BTreeG($T, $Order)) {
	tr.stats = BTree_Stats{}
}

clear_tree :: proc(tr: ^BTreeG($T, $Order)) {
	destroy(tr)
}

iter :: proc(tr: ^BTreeG($T, $Order)) -> IterG(T, Order) {
	it := IterG(T, Order) {
		tr = tr,
	}
	return it
}

iter_destroy :: proc(it: ^IterG($T, $Order)) {
	it.depth = 0
	it.tr = nil
	it.seeked = false
	it.atstart = false
	it.atend = false
}

item :: proc(it: ^IterG($T, $Order)) -> T {
	return it.item
}

set :: proc(tr: ^BTreeG($T, $Order), item: T) -> (prev: T, replaced: bool) {
	return set_hint(tr, item, nil)
}

set_hint :: proc(tr: ^BTreeG($T, $Order), item: T, hint: ^Path_Hint) -> (prev: T, replaced: bool) {
	path_hint_sync_generation(tr, hint)

	if tr.root == nil {
		tr.root = node_new(tr, true)
		tr.root.items[0] = item
		tr.root.item_count = 1
		tr.count = 1
		return tr.empty, false
	}

	if int(tr.root.item_count) == tr.max_items {
		left := tr.root
		right, median := node_split(tr, left)

		new_root := node_new(tr, false)
		new_root.items[0] = median
		new_root.item_count = 1
		new_root.children[0] = left
		new_root.children[1] = right
		new_root.child_count = 2
		tr.root = new_root
	}

	prev_value, did_replace := node_set_top_down(tr, tr.root, item, hint)

	if !did_replace {
		tr.count += 1
	}

	return prev_value, did_replace
}

// load appends pre-sorted items quickly. If the key is out-of-order or the
// rightmost leaf is full, it falls back to the regular insert path.
load :: proc(tr: ^BTreeG($T, $Order), item: T) -> (prev: T, replaced: bool) {
	if tr.root == nil {
		return set_hint(tr, item, nil)
	}

	n := tr.root
	for !n.leaf {
		n = n.children[int(n.child_count) - 1]
	}

	if int(n.item_count) < tr.max_items {
		last_item := n.items[int(n.item_count) - 1]
		if node_compare(tr, last_item, item) < 0 {
			node_search_set(tr, n, int(n.item_count), item)
			n.items[int(n.item_count)] = item
			n.item_count += 1
			tr.count += 1
			return tr.empty, false
		}
	}

	return set_hint(tr, item, nil)
}

get :: proc(tr: ^BTreeG($T, $Order), key: T) -> (value: T, ok: bool) {
	return get_hint(tr, key, nil)
}

get_hint :: proc(tr: ^BTreeG($T, $Order), key: T, hint: ^Path_Hint) -> (value: T, ok: bool) {
	path_hint_sync_generation(tr, hint)

	if tr.root == nil {
		return tr.empty, false
	}

	n := tr.root
	depth := 0
	known_prefix := 0
	for {
		i, found := node_find_read(tr, n, key, hint, depth, &known_prefix)
		if found {
			return n.items[i], true
		}
		if n.leaf {
			return tr.empty, false
		}
		n = n.children[i]
		depth += 1
	}
}

contains :: proc(tr: ^BTreeG($T, $Order), key: T) -> bool {
	_, ok := get(tr, key)
	return ok
}

remove :: proc(tr: ^BTreeG($T, $Order), key: T) -> (prev: T, removed: bool) {
	return remove_hint(tr, key, nil)
}

remove_hint :: proc(tr: ^BTreeG($T, $Order), key: T, hint: ^Path_Hint) -> (prev: T, removed: bool) {
	path_hint_sync_generation(tr, hint)

	if tr.root == nil {
		return tr.empty, false
	}

	// Exact matches are proven by the full comparator. A failed optimistic
	// descent has not mutated any items, so retry from the root with checks.
	if hint == nil && tr.cache == .Text {
		prev, removed = node_delete(tr, &tr.root, false, key, nil, 0, optimistic = true)
	}
	if !removed {
		prev, removed = node_delete(tr, &tr.root, false, key, hint, 0, optimistic = false)
	}
	if !removed {
		return tr.empty, false
	}

	if tr.root.item_count == 0 && !tr.root.leaf {
		old_root := tr.root
		tr.root = old_root.children[0]
		node_destroy_header(tr, old_root)
		tr.hint_generation += 1
	}

	tr.count -= 1
	if tr.count == 0 {
		if tr.root != nil {
			node_destroy_header(tr, tr.root)
		}
		tr.root = nil
		tr.hint_generation += 1
	}

	return prev, true
}

scan :: proc(tr: ^BTreeG($T, $Order), f: proc(item: T) -> bool) {
	if tr.root == nil {
		return
	}
	_ = node_scan(tr.root, f)
}

scan_ctx :: proc(tr: ^BTreeG($T, $Order), ctx: rawptr, f: proc(ctx: rawptr, item: T) -> bool) {
	if tr.root == nil {
		return
	}
	_ = node_scan_ctx(tr.root, ctx, f)
}

scan_ctx_with_prefetch :: proc(tr: ^BTreeG($T, $Order), ctx: rawptr, f: proc(ctx: rawptr, item: T) -> bool, prefetch: proc(ctx: rawptr, item: T)) {
	if tr.root == nil {
		return
	}
	_ = node_scan_ctx_with_prefetch(tr.root, ctx, f, prefetch)
}

reverse :: proc(tr: ^BTreeG($T, $Order), f: proc(item: T) -> bool) {
	if tr.root == nil {
		return
	}
	_ = node_reverse(tr.root, f)
}

ascend :: proc(tr: ^BTreeG($T, $Order), pivot: T, f: proc(item: T) -> bool) {
	if tr.root == nil {
		return
	}
	_ = node_ascend(tr, tr.root, pivot, nil, 0, f)
}

ascend_hint :: proc(tr: ^BTreeG($T, $Order), pivot: T, hint: ^Path_Hint, f: proc(item: T) -> bool) {
	path_hint_sync_generation(tr, hint)

	if tr.root == nil {
		return
	}
	_ = node_ascend(tr, tr.root, pivot, hint, 0, f)
}

descend :: proc(tr: ^BTreeG($T, $Order), pivot: T, f: proc(item: T) -> bool) {
	if tr.root == nil {
		return
	}
	_ = node_descend(tr, tr.root, pivot, nil, 0, f)
}

descend_hint :: proc(tr: ^BTreeG($T, $Order), pivot: T, hint: ^Path_Hint, f: proc(item: T) -> bool) {
	path_hint_sync_generation(tr, hint)

	if tr.root == nil {
		return
	}
	_ = node_descend(tr, tr.root, pivot, hint, 0, f)
}

iter_seek :: proc(it: ^IterG($T, $Order), key: T) -> bool {
	return iter_seek_hint(it, key, nil)
}

iter_seek_hint :: proc(it: ^IterG($T, $Order), key: T, hint: ^Path_Hint) -> bool {
	if it.tr == nil {
		return false
	}
	path_hint_sync_generation(it.tr, hint)

	it.seeked = true
	it.atstart = false
	it.atend = false
	it.depth = 0

	if it.tr.root == nil {
		return false
	}

	n := it.tr.root
	depth := 0
	known_prefix := 0
	for {
		i, found := node_find_read(it.tr, n, key, hint, depth, &known_prefix)
		it.stack[it.depth] = Iter_Stack_Item(T) {
			n = n,
			i = i,
		}
		it.depth += 1
		if found {
			it.item = n.items[i]
			return true
		}
		if n.leaf {
			it.stack[it.depth - 1].i -= 1
			return iter_next(it)
		}
		n = n.children[i]
		depth += 1
	}
}

iter_first :: proc(it: ^IterG($T, $Order)) -> bool {
	if it.tr == nil {
		return false
	}

	it.seeked = true
	it.atstart = false
	it.atend = false
	it.depth = 0

	if it.tr.root == nil {
		return false
	}

	n := it.tr.root
	for {
		it.stack[it.depth] = Iter_Stack_Item(T) {
			n = n,
			i = 0,
		}
		it.depth += 1
		if n.leaf {
			break
		}
		n = n.children[0]
	}

	s := &it.stack[it.depth - 1]
	it.item = s.n.items[s.i]
	return true
}

iter_last :: proc(it: ^IterG($T, $Order)) -> bool {
	if it.tr == nil {
		return false
	}

	it.seeked = true
	it.atstart = false
	it.atend = false
	it.depth = 0

	if it.tr.root == nil {
		return false
	}

	n := it.tr.root
	for {
		it.stack[it.depth] = Iter_Stack_Item(T) {
			n = n,
			i = int(n.item_count),
		}
		it.depth += 1
		if n.leaf {
			it.stack[it.depth - 1].i -= 1
			break
		}
		n = n.children[int(n.item_count)]
	}

	s := &it.stack[it.depth - 1]
	it.item = s.n.items[s.i]
	return true
}

iter_next :: proc(it: ^IterG($T, $Order)) -> bool {
	if it.tr == nil {
		return false
	}
	if !it.seeked {
		return iter_first(it)
	}
	if it.depth == 0 {
		if it.atstart {
			return iter_first(it) && iter_next(it)
		}
		return false
	}

	s := &it.stack[it.depth - 1]
	s.i += 1
	if s.n.leaf {
		if s.i == int(s.n.item_count) {
			for {
				it.depth -= 1
				if it.depth == 0 {
					it.atend = true
					return false
				}
				s = &it.stack[it.depth - 1]
				if s.i < int(s.n.item_count) {
					break
				}
			}
		}
	} else {
		n := s.n.children[s.i]
		for {
			it.stack[it.depth] = Iter_Stack_Item(T) {
				n = n,
				i = 0,
			}
			it.depth += 1
			if n.leaf {
				break
			}
			n = n.children[0]
		}
	}

	s = &it.stack[it.depth - 1]
	it.item = s.n.items[s.i]
	return true
}

iter_prev :: proc(it: ^IterG($T, $Order)) -> bool {
	if it.tr == nil {
		return false
	}
	if !it.seeked {
		return false
	}
	if it.depth == 0 {
		if it.atend {
			return iter_last(it) && iter_prev(it)
		}
		return false
	}

	s := &it.stack[it.depth - 1]
	if s.n.leaf {
		s.i -= 1
		if s.i == -1 {
			for {
				it.depth -= 1
				if it.depth == 0 {
					it.atstart = true
					return false
				}
				s = &it.stack[it.depth - 1]
				s.i -= 1
				if s.i > -1 {
					break
				}
			}
		}
	} else {
		n := s.n.children[s.i]
		for {
			it.stack[it.depth] = Iter_Stack_Item(T) {
				n = n,
				i = int(n.item_count),
			}
			it.depth += 1
			if n.leaf {
				it.stack[it.depth - 1].i -= 1
				break
			}
			n = n.children[int(n.item_count)]
		}
	}

	s = &it.stack[it.depth - 1]
	it.item = s.n.items[s.i]
	return true
}

node_new :: proc(tr: ^BTreeG($T, $Order), leaf: bool) -> ^Node(T) {
	node_size := size_of(Node(T))
	items_offset := mem.align_forward_int(node_size, align_of(T))
	if tr.cache != .None {
		cache_offset := mem.align_forward_int(node_size, align_of(Text_Node))
		word_bytes := leaf && tr.cache == .Text ? size_of(u32) : size_of(u64)
		items_offset = mem.align_forward_int(cache_offset + size_of(Text_Node) + word_bytes * tr.max_items, align_of(T))
	}
	items_bytes := size_of(T) * tr.max_items

	children_offset := items_offset + items_bytes
	children_bytes := 0
	if !leaf {
		children_offset = mem.align_forward_int(children_offset, align_of(^Node(T)))
		children_bytes = size_of(^Node(T)) * (tr.max_items + 1)
	}

	total_size := children_offset + children_bytes
	allocation_alignment := align_of(Node(T))
	if allocation_alignment < CACHE_LINE_BYTES {
		allocation_alignment = CACHE_LINE_BYTES
	}

	storage, alloc_err := mem.alloc_bytes(total_size, allocation_alignment, tr.allocator)
	if alloc_err != nil {
		panic("node allocation failed")
	}
	n := (^Node(T))(raw_data(storage))

	n^ = Node(T) {
		leaf = leaf,
	}

	items_data := raw_data(storage[items_offset:])
	n.items = ([^]T)(items_data)
	n.item_count = 0
	if tr.cache != .None {
		node_text_cache(tr, n)^ = {}
	}

	if !leaf {
		children_data := raw_data(storage[children_offset:])
		n.children = ([^]^Node(T))(children_data)
		n.child_count = 0
	}

	return n
}

node_destroy_header :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T)) {
	if n == nil {
		return
	}

	free_err := mem.free(rawptr(n), tr.allocator)
	if free_err != nil {
		panic("node free failed")
	}
}

node_destroy :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T)) {
	if n == nil {
		return
	}

	if !n.leaf {
		for i := 0; i < int(n.child_count); i += 1 {
			node_destroy(tr, n.children[i])
		}
	}

	node_destroy_header(tr, n)
}

node_bsearch :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T) -> (index: int, found: bool) {
	low := 0
	high := int(n.item_count)
	for low < high {
		h := int(uint(low + high) >> 1)
		cmp: int
		#no_bounds_check {
			cmp = node_compare(tr, key, n.items[h])
		}
		if cmp == 0 {
			return h, true
		} else if cmp > 0 {
			low = h + 1
		} else {
			high = h
		}
	}

	return low, false
}

node_lsearch :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T) -> (index: int, found: bool) {
	for i := 0; i < int(n.item_count); i += 1 {
		cmp: int
		#no_bounds_check {
			cmp = node_compare(tr, key, n.items[i])
		}
		if cmp == 0 {
			return i, true
		}
		if cmp < 0 {
			return i, false
		}
	}

	return int(n.item_count), false
}

node_find_read :: #force_inline proc(
	tr: ^BTreeG($T, $Order),
	n: ^Node(T),
	key: T,
	hint: ^Path_Hint,
	depth: int,
	known_prefix: ^int,
) -> (
	index: int,
	found: bool,
) {
	if hint == nil && tr.cache == .Text {
		return node_text_find(tr, n, key, known_prefix, false)
	}
	return node_find(tr, n, key, hint, depth)
}

node_find :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T, hint: ^Path_Hint, depth: int, known_prefix: ^int = nil) -> (index: int, found: bool) {
	if hint == nil {
		if tr.cache == .Numeric {
			return node_numeric_find(tr, n, key)
		}
		if tr.cache == .Text {
			return node_text_find(tr, n, key, known_prefix, false)
		}
		if int(n.item_count) <= LINEAR_SEARCH_NODE_CUTOFF {
			return node_lsearch(tr, n, key)
		}
		return node_bsearch(tr, n, key)
	}
	return node_hintsearch(tr, n, key, hint, depth)
}

node_compare :: #force_inline proc(tr: ^BTreeG($T, $Order), a, b: T) -> int {
	return static_compare(a, b, tr.descending, Order.Compare)
}

static_compare :: #force_inline proc(a, b: $T, descending: bool, $compare: proc(a, b: rawptr, descending: bool) -> int) -> int {
	a_copy, b_copy := a, b
	return compare(&a_copy, &b_copy, descending)
}

node_items_insert_at :: proc(n: ^Node($T), index: int, value: T) {
	#no_bounds_check {
		for i := int(n.item_count); i > index; i -= 1 {
			n.items[i] = n.items[i - 1]
		}
		n.items[index] = value
	}
	n.item_count += 1
}

node_items_remove_at :: proc(n: ^Node($T), index: int) -> T {
	removed: T
	#no_bounds_check {
		removed = n.items[index]
		for i := index; i < int(n.item_count) - 1; i += 1 {
			n.items[i] = n.items[i + 1]
		}
	}
	n.item_count -= 1
	return removed
}

node_items_pop_last :: proc(n: ^Node($T)) -> T {
	last_index := n.item_count - 1
	last := n.items[last_index]
	n.item_count = last_index
	return last
}

node_children_insert_at :: proc(n: ^Node($T), index: int, child: ^Node(T)) {
	#no_bounds_check {
		for i := int(n.child_count); i > index; i -= 1 {
			n.children[i] = n.children[i - 1]
		}
		n.children[index] = child
	}
	n.child_count += 1
}

node_children_remove_at :: proc(n: ^Node($T), index: int) -> ^Node(T) {
	removed: ^Node(T)
	#no_bounds_check {
		removed = n.children[index]
		for i := index; i < int(n.child_count) - 1; i += 1 {
			n.children[i] = n.children[i + 1]
		}
	}
	n.child_count -= 1
	return removed
}

node_children_pop_last :: proc(n: ^Node($T)) -> ^Node(T) {
	last_index := n.child_count - 1
	last := n.children[last_index]
	n.child_count = last_index
	return last
}

node_hintsearch :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T, hint: ^Path_Hint, depth: int) -> (index: int, found: bool) {
	// Hint path visualization (per depth):
	//
	//   depth:       0    1    2    3
	//   hint.used:  [1]  [1]  [0]  [0]
	//   hint.path:  [2]  [5]  [ ]  [ ]
	//
	// Meaning:
	// - At root (depth 0), start probing around slot 2.
	// - At the next node (depth 1), start probing around slot 5.
	// - Depths 2+ are uncached and must search normally.
	//
	// How these are set:
	// - hint.used[depth] becomes true after node_hintsearch computes a
	//   final index for that depth.
	// - hint.path[depth] stores that chosen index (or index+1 for leaf
	//   exact hits, to bias toward nearby follow-up operations).
	// - If a depth's stored path changes, all deeper hint.used slots are
	//   cleared because descent will follow a different subtree chain.
	// - Structural edits (split/merge/rebalance/root changes) bump
	//   tr.hint_generation, and path_hint_sync_generation clears all slots.
	//
	// If current depth picks a different slot than cached, deeper levels are
	// invalidated because descent now enters a different subtree chain.

	// Hint search flow:
	// 1) Try hinted slot at this depth as a seed probe.
	// 2) If probe brackets the key, accept immediately.
	// 3) Otherwise tighten [low, high] and run binary search fallback.
	// 4) Write back updated path slot and invalidate deeper cached levels if the chosen slot changed.
	low := 0
	high := int(n.item_count) - 1
	use_existing_bounds := false

	if depth < MAX_HINT_DEPTH && hint.used[depth] {
		index = int(hint.path[depth])
		if index >= int(n.item_count) {
			if n.item_count > 0 && node_compare(tr, n.items[int(n.item_count) - 1], key) < 0 {
				index = int(n.item_count)
				use_existing_bounds = true
			}
			if !use_existing_bounds {
				index = int(n.item_count) - 1
			}
		}

		if !use_existing_bounds {
			cmp: int
			#no_bounds_check {
				cmp = node_compare(tr, key, n.items[index])
			}
			if cmp < 0 {
				cmp_prev := -1
				if index > 0 {
					#no_bounds_check {
						cmp_prev = node_compare(tr, n.items[index - 1], key)
					}
				}
				if index == 0 || cmp_prev < 0 {
					use_existing_bounds = true
				} else {
					high = index - 1
				}
			} else if cmp > 0 {
				low = index + 1
			} else {
				found = true
				use_existing_bounds = true
			}
		}
	}

	if !use_existing_bounds {
		for low <= high {
			mid := low + ((high + 1) - low) / 2
			cmp_mid: int
			#no_bounds_check {
				cmp_mid = node_compare(tr, key, n.items[mid])
			}
			if cmp_mid >= 0 {
				low = mid + 1
			} else {
				high = mid - 1
			}
		}

		low_is_equal := false
		if low > 0 {
			#no_bounds_check {
				low_is_equal = node_compare(tr, n.items[low - 1], key) == 0
			}
		}
		if low_is_equal {
			index = low - 1
			found = true
		} else {
			index = low
			found = false
		}
	}

	if depth < MAX_HINT_DEPTH {
		hint.used[depth] = true
		path_index: u8
		if n.leaf && found {
			// For leaf exact hits, bias hint path to the next slot to better align
			// with follow-up inserts/seeks around the same key neighborhood.
			path_index = u8(index + 1)
		} else {
			path_index = u8(index)
		}

		if path_index != hint.path[depth] {
			hint.path[depth] = path_index
			// Parent path changed; deeper cached slots are no longer guaranteed
			// to match the subtree we will descend into from this node.
			for i := depth + 1; i < MAX_HINT_DEPTH; i += 1 {
				hint.used[i] = false
			}
		}
	}

	return index, found
}

node_split :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T)) -> (right: ^Node(T), median: T) {
	tr.stats.split_count += 1
	// Split changes child boundaries/path topology; invalidate all path hints.
	tr.hint_generation += 1
	node_search_invalidate(tr, n)

	mid := tr.max_items / 2
	median = n.items[mid]

	right = node_new(tr, n.leaf)
	right_item_count := int(n.item_count) - (mid + 1)
	right.item_count = u16(right_item_count)
	for i := 0; i < right_item_count; i += 1 {
		right.items[i] = n.items[mid + 1 + i]
	}

	if !n.leaf {
		right_child_count := int(n.child_count) - (mid + 1)
		right.child_count = u16(right_child_count)
		for i := 0; i < right_child_count; i += 1 {
			right.children[i] = n.children[mid + 1 + i]
		}
	}

	n.item_count = u16(mid)
	if !n.leaf {
		n.child_count = u16(mid + 1)
	}

	return
}

node_split_child :: proc(tr: ^BTreeG($T, $Order), parent: ^Node(T), child_index: int) {
	right, median := node_split(tr, parent.children[child_index])

	node_search_set(tr, parent, child_index, median)
	node_children_insert_at(parent, child_index + 1, right)
	node_items_insert_at(parent, child_index, median)
}

node_set_top_down :: proc(tr: ^BTreeG($T, $Order), root: ^Node(T), item: T, hint: ^Path_Hint) -> (prev: T, replaced: bool) {
	n := root
	depth := 0
	known_prefix := 0

	for {
		i, found := node_find(tr, n, item, hint, depth, &known_prefix)
		if found {
			prev = n.items[i]
			node_search_set(tr, n, i, item, true)
			n.items[i] = item
			return prev, true
		}

		if n.leaf {
			node_search_set(tr, n, i, item)
			node_items_insert_at(n, i, item)
			return tr.empty, false
		}

		if int(n.children[i].item_count) == tr.max_items {
			// Splitting only partitions the child: its ancestor prefix guarantee
			// still holds for both halves. Cache maintenance remains checked.
			node_split_child(tr, n, i)

			cmp := node_compare(tr, item, n.items[i])
			if cmp > 0 {
				i += 1
			} else if cmp == 0 {
				prev = n.items[i]
				node_search_set(tr, n, i, item, true)
				n.items[i] = item
				return prev, true
			}
		}

		n = n.children[i]
		depth += 1
	}
}

node_delete :: proc(
	tr: ^BTreeG($T, $Order),
	cn: ^^Node(T),
	take_max: bool,
	key: T,
	hint: ^Path_Hint,
	depth: int,
	ancestor_prefix: int = 0,
	$optimistic: bool,
) -> (
	prev: T,
	deleted: bool,
) {
	n := cn^
	known_prefix := ancestor_prefix

	i: int
	found: bool
	if take_max {
		i = int(n.item_count) - 1
		found = true
	} else {
		when optimistic {
			i, found = node_text_find(tr, n, key, nil, true)
		} else {
			i, found = node_find(tr, n, key, hint, depth, &known_prefix)
		}
	}

	if n.leaf {
		if found {
			node_search_remove(tr, n, i)
			prev = node_items_remove_at(n, i)
			return prev, true
		}
		return tr.empty, false
	}

	if found {
		if take_max {
			i += 1
			prev, deleted = node_delete(tr, &n.children[i], true, tr.empty, nil, 0, optimistic = false)
		} else {
			prev = n.items[i]
			max_item, _ := node_delete(tr, &n.children[i], true, tr.empty, nil, 0, optimistic = false)
			deleted = true
			node_search_set(tr, n, i, max_item, true)
			n.items[i] = max_item
		}
	} else {
		prev, deleted = node_delete(tr, &n.children[i], take_max, key, hint, depth + 1, known_prefix, optimistic)
	}

	if !deleted {
		return tr.empty, false
	}

	if int(n.children[i].item_count) < tr.min_items {
		node_rebalance(tr, n, i)
	}

	return prev, true
}

node_rebalance :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), i: int) {
	tr.stats.rebalance_count += 1
	// Borrow/merge changes separator placement and sibling layout.
	tr.hint_generation += 1

	idx := i
	if idx == int(n.item_count) {
		idx -= 1
	}

	left := n.children[idx]
	right := n.children[idx + 1]

	if int(left.item_count) + int(right.item_count) < tr.max_items {
		tr.stats.merge_count += 1
		node_search_invalidate(tr, left)
		node_search_remove(tr, n, idx)

		left_old_items := int(left.item_count)
		merged_item_count := left_old_items + 1 + int(right.item_count)
		left.item_count = u16(merged_item_count)
		left.items[left_old_items] = n.items[idx]
		for j := 0; j < int(right.item_count); j += 1 {
			left.items[left_old_items + 1 + j] = right.items[j]
		}

		if !left.leaf {
			left_old_children := int(left.child_count)
			left.child_count = u16(left_old_children + int(right.child_count))
			for j := 0; j < int(right.child_count); j += 1 {
				left.children[left_old_children + j] = right.children[j]
			}
		}

		_ = node_items_remove_at(n, idx)
		_ = node_children_remove_at(n, idx + 1)

		node_destroy_header(tr, right)
	} else if int(left.item_count) > int(right.item_count) {
		tr.stats.borrow_left_count += 1

		node_search_set(tr, right, 0, n.items[idx])
		node_search_set(tr, n, idx, left.items[int(left.item_count) - 1], true)
		node_search_remove(tr, left, int(left.item_count) - 1)
		node_items_insert_at(right, 0, n.items[idx])

		n.items[idx] = node_items_pop_last(left)

		if !left.leaf {
			node_children_insert_at(right, 0, node_children_pop_last(left))
		}
	} else {
		tr.stats.borrow_right_count += 1

		left_old_items := int(left.item_count)
		node_search_set(tr, left, left_old_items, n.items[idx])
		node_search_set(tr, n, idx, right.items[0], true)
		node_search_remove(tr, right, 0)
		left.item_count = u16(left_old_items + 1)
		left.items[left_old_items] = n.items[idx]

		n.items[idx] = right.items[0]
		_ = node_items_remove_at(right, 0)

		if !left.leaf {
			left_old_children := int(left.child_count)
			left.child_count = u16(left_old_children + 1)
			left.children[left_old_children] = right.children[0]
			_ = node_children_remove_at(right, 0)
		}
	}
}

node_scan :: proc(n: ^Node($T), f: proc(item: T) -> bool) -> bool {
	if n.leaf {
		for i := 0; i < int(n.item_count); i += 1 {
			if !f(n.items[i]) {
				return false
			}
		}
		return true
	}

	for i := 0; i < int(n.item_count); i += 1 {
		if !node_scan(n.children[i], f) {
			return false
		}
		if !f(n.items[i]) {
			return false
		}
	}

	return node_scan(n.children[int(n.child_count) - 1], f)
}

node_scan_ctx :: proc(n: ^Node($T), ctx: rawptr, f: proc(ctx: rawptr, item: T) -> bool) -> bool {
	if n.leaf {
		for i := 0; i < int(n.item_count); i += 1 {
			if !f(ctx, n.items[i]) {
				return false
			}
		}
		return true
	}

	for i := 0; i < int(n.item_count); i += 1 {
		if !node_scan_ctx(n.children[i], ctx, f) {
			return false
		}
		if !f(ctx, n.items[i]) {
			return false
		}
	}

	return node_scan_ctx(n.children[int(n.child_count) - 1], ctx, f)
}

node_scan_ctx_with_prefetch :: proc(n: ^Node($T), ctx: rawptr, f: proc(ctx: rawptr, item: T) -> bool, prefetch: proc(ctx: rawptr, item: T)) -> bool {
	if n.leaf {
		for i := 0; i < int(n.item_count); i += 1 {
			// Prefetch next item while processing current to hide cache latency
			if i + 1 < int(n.item_count) {
				prefetch(ctx, n.items[i + 1])
			}
			if !f(ctx, n.items[i]) {
				return false
			}
		}
		return true
	}

	for i := 0; i < int(n.item_count); i += 1 {
		if !node_scan_ctx_with_prefetch(n.children[i], ctx, f, prefetch) {
			return false
		}
		if !f(ctx, n.items[i]) {
			return false
		}
	}

	return node_scan_ctx_with_prefetch(n.children[int(n.child_count) - 1], ctx, f, prefetch)
}

node_reverse :: proc(n: ^Node($T), f: proc(item: T) -> bool) -> bool {
	if n.leaf {
		for i := int(n.item_count) - 1; i >= 0; i -= 1 {
			if !f(n.items[i]) {
				return false
			}
		}
		return true
	}

	if !node_reverse(n.children[int(n.child_count) - 1], f) {
		return false
	}

	for i := int(n.item_count) - 1; i >= 0; i -= 1 {
		if !f(n.items[i]) {
			return false
		}
		if !node_reverse(n.children[i], f) {
			return false
		}
	}

	return true
}

node_ascend :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), pivot: T, hint: ^Path_Hint, depth: int, f: proc(item: T) -> bool) -> bool {
	i, found := node_find(tr, n, pivot, hint, depth)
	if !found {
		if !n.leaf {
			if !node_ascend(tr, n.children[i], pivot, hint, depth + 1, f) {
				return false
			}
		}
	}

	for ; i < int(n.item_count); i += 1 {
		if !f(n.items[i]) {
			return false
		}
		if !n.leaf {
			if !node_scan(n.children[i + 1], f) {
				return false
			}
		}
	}

	return true
}

node_descend :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), pivot: T, hint: ^Path_Hint, depth: int, f: proc(item: T) -> bool) -> bool {
	i, found := node_find(tr, n, pivot, hint, depth)
	if !found {
		if !n.leaf {
			if !node_descend(tr, n.children[i], pivot, hint, depth + 1, f) {
				return false
			}
		}
		i -= 1
	}

	for ; i >= 0; i -= 1 {
		if !f(n.items[i]) {
			return false
		}
		if !n.leaf {
			if !node_reverse(n.children[i], f) {
				return false
			}
		}
	}

	return true
}
