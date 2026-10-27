package btree

import "base:intrinsics"
import "core:mem"
import "core:simd"
import "core:strings"

SIMD_I32_LANE_INDICES :: simd.u32x8{0, 1, 2, 3, 4, 5, 6, 7}
SIMD_I32_LANE_SENTINEL :: simd.u32x8{0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff}
SIMD_I64_LANE_INDICES :: simd.u64x4{0, 1, 2, 3}
SIMD_I64_LANE_SENTINEL :: simd.u64x4{0xff, 0xff, 0xff, 0xff}

// Opt-in metadata and search words precede the items in the same allocation. Ordinary nodes
// keep their original layout. A negative prefix length marks an ineligible node.
Text_Node :: struct {
	prefix_len: int,
	valid:      bool,
}

node_text_cache :: #force_inline proc(tr: ^BTreeG($T, $Order), n: ^Node(T)) -> ^Text_Node {
	address := mem.align_forward_uintptr(uintptr(n) + size_of(Node(T)), align_of(Text_Node))
	return (^Text_Node)(rawptr(address))
}

node_search_invalidate :: #force_inline proc(tr: ^BTreeG($T, $Order), n: ^Node(T)) {
	if tr.cache != .None {
		node_text_cache(tr, n).valid = false
	}
}

// Called before changing items. Retain a conservative common prefix: deletion
// may make a longer prefix possible, but cannot invalidate the existing one.
node_search_remove :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), index: int) {
	if tr.cache == .Numeric {
		cache := node_text_cache(tr, n)
		if cache.valid do node_text_remove_word(cache, int(n.item_count), index, u64)
		return
	}
	if tr.cache != .Text do return
	cache := node_text_cache(tr, n)
	if !cache.valid do return
	if cache.prefix_len < 0 {
		cache.valid = false
		return
	}
	if n.leaf {
		node_text_remove_word(cache, int(n.item_count), index, u32)
	} else {
		node_text_remove_word(cache, int(n.item_count), index, u64)
		node_text_check_internal_prefix(cache, int(n.item_count) - 1, tr.descending)
	}
}

node_text_check_internal_prefix :: #force_inline proc(cache: ^Text_Node, count: int, descending: bool) {
	if count < 2 do return
	words := ([^]u64)(rawptr(uintptr(cache) + size_of(Text_Node)))
	first, last := words[0], words[count - 1]
	// Equal leading bytes prove prefix growth unless an endpoint could be
	// entirely padding (or indistinguishable from padding, such as eight NULs).
	pad := descending ? ~u64(0) : 0
	if first >> 56 == last >> 56 && first != pad && last != pad do cache.valid = false
}

node_text_remove_word :: proc(cache: ^Text_Node, count, index: int, $Word: typeid) {
	words := ([^]Word)(rawptr(uintptr(cache) + size_of(Text_Node)))
	for i := index; i + 1 < count; i += 1 {
		words[i] = words[i + 1]
	}
}

node_search_set :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), index: int, item: T, replace := false) {
	if tr.cache == .Numeric {
		cache := node_text_cache(tr, n)
		if cache.valid do node_text_set_word(cache, int(n.item_count), index, tree_numeric_key(tr, item), replace)
		return
	}
	if tr.cache != .Text do return
	cache := node_text_cache(tr, n)
	if !cache.valid do return
	if cache.prefix_len < 0 || n.item_count == 0 {
		cache.valid = false
		return
	}
	text, ok := tree_text_key(tr, item)
	if !ok || len(text) < cache.prefix_len {
		cache.valid = false
		return
	}
	if cache.prefix_len > 0 {
		first, _ := tree_text_key(tr, n.items[0])
		if strings.compare(text[:cache.prefix_len], first[:cache.prefix_len]) != 0 {
			cache.valid = false
			return
		}
	}
	if n.leaf {
		node_text_set_word(cache, int(n.item_count), index, text_word(text, cache.prefix_len, tr.descending, u32), replace)
	} else {
		node_text_set_word(cache, int(n.item_count), index, text_word(text, cache.prefix_len, tr.descending, u64), replace)
		node_text_check_internal_prefix(cache, int(n.item_count) + (replace ? 0 : 1), tr.descending)
	}
}

node_text_set_word :: proc(cache: ^Text_Node, count, index: int, word: $Word, replace: bool) {
	words := ([^]Word)(rawptr(uintptr(cache) + size_of(Text_Node)))
	if !replace {
		for i := count; i > index; i -= 1 {
			words[i] = words[i - 1]
		}
	}
	words[index] = word
}

text_word :: proc(text: string, offset: int, descending: bool, $Word: typeid) -> Word {
	if len(text) <= offset do return descending ? ~Word(0) : Word(0)
	if len(text) - offset >= size_of(Word) {
		// Load only complete words; short tails below retain zero-padding without overreading.
		word := intrinsics.unaligned_load((^Word)(raw_data(text[offset:])))
		when ODIN_ENDIAN == .Little {
			word = intrinsics.byte_swap(word)
		}
		return descending ? ~word : word
	}
	word: Word
	for i in 0 ..< min(size_of(Word), len(text) - offset) {
		word |= Word(text[offset + i]) << uint(8 * (size_of(Word) - 1 - i))
	}
	return descending ? ~word : word
}

node_text_refresh :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), cache: ^Text_Node, words: []$Word) {
	cache.valid = true
	cache.prefix_len = -1
	first, first_ok := tree_text_key(tr, n.items[0])
	last, last_ok := tree_text_key(tr, n.items[int(n.item_count) - 1])
	if !first_ok || !last_ok do return
	prefix_len := strings.prefix_length(first, last)
	for i in 0 ..< int(n.item_count) {
		text, ok := tree_text_key(tr, n.items[i])
		if !ok do return
		words[i] = text_word(text, prefix_len, tr.descending, Word)
	}
	cache.prefix_len = prefix_len
}

text_words_lower_bound :: proc(words: []$Word, word: Word) -> int {
	i := 0
	when simd.HAS_HARDWARE_SIMD {
		when Word == u32 {
			Vector :: simd.u32x8
			LANES :: SIMD_I32_LANE_INDICES
			SENTINELS :: SIMD_I32_LANE_SENTINEL
		} else {
			Vector :: simd.u64x4
			LANES :: SIMD_I64_LANE_INDICES
			SENTINELS :: SIMD_I64_LANE_SENTINEL
		}
		key_vec: Vector = word
		for ; i + len(LANES) <= len(words); i += len(LANES) {
			block := intrinsics.unaligned_load((^Vector)(raw_data(words[i:])))
			ge := simd.lanes_ge(block, key_vec)
			if simd.reduce_or(ge) != 0 {
				lanes := simd.select(ge, LANES, SENTINELS)
				return i + int(simd.reduce_min(lanes))
			}
		}
	}
	for ; i < len(words); i += 1 {
		if words[i] >= word do return i
	}
	return len(words)
}

node_text_find :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T, known_prefix: ^int, $optimistic: bool) -> (index: int, found: bool) {
	if n.leaf do return node_text_find_words(tr, n, key, u32, known_prefix, optimistic)
	return node_text_find_words(tr, n, key, u64, known_prefix, optimistic)
}

node_text_find_words :: proc(tr: ^BTreeG($T, $Order), n: ^Node(T), key: T, $Word: typeid, known_prefix: ^int, $optimistic: bool) -> (index: int, found: bool) {
	count := int(n.item_count)
	if count == 0 do return 0, false
	text, eligible := tree_text_key(tr, key)
	if !eligible do return node_bsearch(tr, n, key)
	cache := node_text_cache(tr, n)
	words := ([^]Word)(rawptr(uintptr(cache) + size_of(Text_Node)))[:count]
	if !cache.valid do node_text_refresh(tr, n, cache, words)
	if cache.prefix_len < 0 do return node_bsearch(tr, n, key)

	// Ancestor separators can prove a prefix for both the query and this
	// entire subtree. Only check bytes beyond that per-descent guarantee.
	if !optimistic && cache.prefix_len > 0 {
		shared := min(len(text), cache.prefix_len)
		start := 0
		if known_prefix != nil do start = min(known_prefix^, shared)
		cmp := 0
		if shared > start {
			first, _ := tree_text_key(tr, n.items[0])
			cmp = strings.compare(text[start:shared], first[start:shared])
		}
		if cmp == 0 && len(text) < cache.prefix_len do cmp = -1
		if tr.descending do cmp = -cmp
		if cmp < 0 do return 0, false
		if cmp > 0 do return count, false
	}

	// Interior children lie between two separators sharing this prefix.
	// Outer children have only one such bound: retain the ancestor guarantee,
	// but never extend it from this node. No state survives the read operation.
	defer {
		if !optimistic && known_prefix != nil && !n.leaf && index > 0 && index < count {
			left, right := words[index - 1], words[index]
			common_bits := intrinsics.count_leading_zeros(left ~ right)
			if tr.descending do left = ~left
			// A zero byte could be padding beyond a short separator. Do not
			// infer a prefix through it, even when the other word also has zero.
			// Each byte's high bit is set exactly when that byte is zero.
			low_bits := (~Word(0) / 255) * 127
			zero_bytes := ~(((left & low_bits) + low_bits) | left | low_bits)
			common_bytes := int(min(common_bits, intrinsics.count_leading_zeros(zero_bytes)) / 8)
			known_prefix^ = max(known_prefix^, cache.prefix_len + common_bytes)
		}
	}

	word := text_word(text, cache.prefix_len, tr.descending, Word)
	low := text_words_lower_bound(words, word)
	if low == count || words[low] != word do return low, false
	high := low + 1
	for high < count && words[high] == word {high += 1}
	// Truncation, zero padding, and duplicate text can collide. The original
	// comparator remains authoritative, including secondary fields and IDs.
	for low < high {
		mid := low + (high - low) / 2
		cmp := node_compare(tr, key, n.items[mid])
		if cmp == 0 do return mid, true
		if cmp > 0 {low = mid + 1} else {high = mid}
	}
	return low, false
}

tree_text_key :: #force_inline proc(tr: ^BTreeG($T, $Order), item: T) -> (text: string, ok: bool) {
	return static_text_key(item, Order.Text_Key)
}

static_text_key :: #force_inline proc(item: $T, $text_key: proc(item: rawptr) -> (text: string, ok: bool)) -> (text: string, ok: bool) {
	if text_key == nil do return "", false
	item_copy := item
	return text_key(&item_copy)
}
