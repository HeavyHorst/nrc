package btree

// Numeric words reuse the text cache's allocation and maintenance helpers, but
// use u64 in every node and no prefix. The adapter must preserve comparator
// order (allowing ties), including equality, for every stored item and query.
// The full comparator resolves collisions. Modes are fixed for a tree's life.
node_numeric_find :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T) -> (index: int, found: bool) {
	count := int(n.item_count)
	if count == 0 do return 0, false
	cache := node_text_cache(tr, n)
	words := ([^]u64)(rawptr(uintptr(cache) + size_of(Text_Node)))[:count]
	if !cache.valid {
		for i in 0 ..< count {words[i] = tree_numeric_key(tr, n.items[i])}
		cache.valid = true
	}
	word := tree_numeric_key(tr, key)
	low := text_words_lower_bound(words, word)
	if low == count || words[low] != word do return low, false
	high := low + 1
	for high < count && words[high] == word {high += 1}
	for low < high {
		mid := low + (high - low) / 2
		cmp := node_compare(tr, key, n.items[mid])
		if cmp == 0 do return mid, true
		if cmp > 0 {low = mid + 1} else {high = mid}
	}
	return low, false
}

tree_numeric_key :: #force_inline proc(tr: ^BTreeG($T, $Order), item: T) -> u64 {
	return static_numeric_key(item, tr.descending, tr.projection, Order.Numeric_Key)
}

static_numeric_key :: #force_inline proc(
	item: $T,
	descending: bool,
	projection: $P,
	$numeric_key: proc(item: rawptr, descending: bool, projection: rawptr) -> u64,
) -> u64 {
	item_copy := item
	projection_copy := projection
	return numeric_key(&item_copy, descending, &projection_copy)
}
