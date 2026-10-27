# btree (Odin)

Generic in-memory B-Tree for ordered keys in Odin.

This package is used in NRC for hot-path ordered indexing (for example, note sorting and pagination).

## Attribution

This implementation is based on and heavily inspired by [`github.com/tidwall/btree`](https://github.com/tidwall/btree), ported to Odin.

## Quick Start

```odin
package main

import "btree"

Int_Order :: btree.Static_Order(int, btree.No_Projection, cmp_int)

cmp_int :: proc(a_ptr, b_ptr: rawptr, descending: bool) -> int {
        a, b := (^int)(a_ptr)^, (^int)(b_ptr)^
        if a < b {
                return -1
        }
        if a > b {
                return 1
        }
        return 0
}

main :: proc() {
        tr := btree.create_ordered(int, Int_Order, btree.Options{degree = 32})
        defer btree.destroy(&tr)

        _, _ = btree.set(&tr, 10)
        _, _ = btree.set(&tr, 20)
        _, _ = btree.set(&tr, 15)

        value, ok := btree.get(&tr, 15)
        if ok {
                // value == 15
        }

        _, _ = btree.remove(&tr, 10)
}
```

## Core Types

- `BTreeG(T, Order)`: Generic tree container with an explicit order policy.
- `Static_Order(T, Projection, compare_adapter, text_adapter, numeric_adapter)`: Compile-time policy with an explicit projection type; both search adapters are optional. Use `No_Projection` when there is no projection choice.
- `Cache_Mode`: `.None`, `.Text`, or `.Numeric`; these modes are mutually exclusive.
- `Options`: Construction options (`degree` controls node fanout).
- `Path_Hint`: Optional reusable lookup/insert/remove hint for locality-heavy workloads.
- `BTree_Stats`: Internal operation counters (`split_count`, `merge_count`, rebalancing counters).
- `IterG(T, Order)`: Stateful bidirectional iterator using the tree's policy.

## Construction And Lifecycle

- `create_ordered(T, Policy, opts := Options{}, allocator := context.allocator, cache = .None, descending = false)` creates a tree with its policy's zero-value projection.
- `init_ordered(&tree, opts := Options{}, allocator := context.allocator, cache = .None, descending = false)` initializes an empty or destroyed tree value with its declared policy; it panics if the tree still owns nodes.
- Both constructors also accept a named `projection` argument. Its type must exactly match `Policy.Projection`; a mismatched enum or integer fails compilation. Pass a typed value, such as `projection = My_Projection(.Time)`, or a variable of that type.
- `destroy(&tree)` frees all node memory owned by the tree.
- `clear_tree(&tree)` clears all contents (same effect as `destroy` for current contents) while keeping the tree value reusable.

The tree allocates internal node storage and must be destroyed to avoid leaks.

## Ownership And Copying

A `BTreeG` value owns its node storage through `root`. There is no clone
operation, and the struct must not be duplicated as a value.

- **Do not copy a tree.** `b := a` gives two structs the same `root`: mutations
  through one are visible through the other, and destroying both double-frees.
  Pass `^BTreeG` between procedures instead. The value returned by
  `create_ordered` is safe because that tree is still empty; assigning it over a
  live tree drops the only reference to the old nodes.
- **`init_ordered` requires an empty or destroyed tree.** It sets `cache`,
  `descending`, `projection`, `allocator`, the degree limits and stats, but
  leaves `root` and `count` untouched, so it panics when `root` is non-nil.
  Reinitializing a live tree would leak its nodes; if the new degree or cache
  mode differed, the surviving nodes would no longer match the tree's layout and
  later inserts or cache updates could write outside their original allocation
  or into their item array.
- **Moving is explicit.** If a tree must move, assign the struct and zero the
  source (`moved := tr; tr = {}`) so the source's `destroy` is a no-op.
- **Item payloads are borrowed.** `set` copies `T` into the node but never
  deep-copies strings, slices or pointers, and `remove`, `clear_tree` and
  `destroy` never free them. Referenced storage must stay alive and immutable
  while the item is in the tree; changing a comparator field in place breaks
  ordering. The caller owns all payload memory.
- **Iterators are non-owning cursors.** `IterG` stores node pointers and indices,
  not storage. Copying an iterator is harmless, but any mutation invalidates
  every copy. `iter_destroy` only clears the cursor.
- **The allocator must outlive the tree.** It is captured at construction and
  used for every node allocation and free; destroy a tree exactly once with the
  allocator it was created with.

## CRUD API

- `set(&tree, item) -> (prev, replaced)` inserts or replaces an existing key-equivalent item.
- `set_hint(&tree, item, &hint) -> (prev, replaced)` same as `set`, with a mutable path hint.
- `load(&tree, item) -> (prev, replaced)` optimized append path for pre-sorted inserts; falls back to normal insert when needed.
- `get(&tree, key) -> (value, ok)` lookup.
- `get_hint(&tree, key, &hint) -> (value, ok)` lookup with hint.
- `contains(&tree, key) -> bool` convenience lookup.
- `remove(&tree, key) -> (prev, removed)` delete by key.
- `remove_hint(&tree, key, &hint) -> (prev, removed)` delete with hint.
- `count(&tree) -> int` item count.

All query/delete calls return an `ok`/`removed` flag. Do not rely on returned value alone for miss detection.

## Ordered Traversal

- `scan(&tree, f)` in ascending order.
- `scan_ctx(&tree, ctx, f)` in ascending order with caller-provided callback context.
- `reverse(&tree, f)` in descending order.
- `ascend(&tree, pivot, f)` ascending from first item `>= pivot`.
- `ascend_hint(&tree, pivot, &hint, f)` hinted `ascend`.
- `descend(&tree, pivot, f)` descending from first item `<= pivot`.
- `descend_hint(&tree, pivot, &hint, f)` hinted `descend`.

Traversal callback signature is `proc(item: T) -> bool`. Return `false` to stop early.

## Iterator API

Create/destroy:

- `iter(&tree) -> IterG(T)`
- `iter_destroy(&it)`

The iterator keeps its traversal stack inline and does not allocate. On a
64-bit target the stack holds 64 node/index pairs (1 KiB); the iterator also
stores its current item and position flags. Even at minimum degree 2, a tree
with L levels needs at least 2^L - 1 items, so the signed `int` item count bounds
the required depth. `iter_destroy` invalidates the iterator without freeing
heap storage. Mutating the tree still invalidates existing iterator positions.

Positioning:

- `iter_first(&it) -> bool`
- `iter_last(&it) -> bool`
- `iter_seek(&it, key) -> bool` (positions on first item `>= key`)
- `iter_seek_hint(&it, key, &hint) -> bool`

Movement and read:

- `iter_next(&it) -> bool`
- `iter_prev(&it) -> bool`
- `item(&it) -> T`

Typical pagination pattern:

```odin
it := btree.iter(&tree)
defer btree.iter_destroy(&it)

if btree.iter_seek(&it, cursor_key) {
        for ok := true; ok; ok = btree.iter_next(&it) {
                row := btree.item(&it)
                // consume row
        }
}
```

## Hints (`Path_Hint`)

`Path_Hint` caches recent search path indices up to a bounded depth. Reuse one hint per hot access stream when keys are nearby (for example sequential inserts, localized seeks, cursor pagination).

Use hints only when you expect key locality. For uniformly random keys, prefer non-hint APIs (`set`, `get`, `remove`, `iter_seek`) because hint tracking adds overhead and can be slower.

```odin
hint := btree.Path_Hint{}
for item in sorted_items {
        _, _ = btree.set_hint(&tree, item, &hint)
}
```

Hints are optional and safe to ignore when simplicity matters.

Rule of thumb: one hint per sequential/cursor-like stream, no hint for random access workloads.

## Stats And Tuning

- `stats(&tree) -> BTree_Stats` exposes structural operation counters.
- `reset_stats(&tree)` clears counters.
- `Options.degree` controls node size tradeoffs.

Degree behavior:

- `degree <= 0` uses default (`32`).
- `degree == 1` is coerced to `2`.

Higher degree generally means fewer levels and potentially better scan locality, at the cost of larger nodes.

## Comparator Contract

The `compare` proc defines key ordering and equality semantics.

- Return negative when `a < b`, zero when equal, positive when `a > b`.
- Comparison must be consistent and transitive.
- If your item contains payload fields, include only key fields in `compare` if replacement-by-key is desired.

Example composite key comparator:

```odin
Note_Key :: struct {
        updated_at: i64,
        id:         u64,
}

note_key_compare :: proc(a, b: Note_Key) -> int {
        if a.updated_at != b.updated_at {
                if a.updated_at < b.updated_at {
                        return -1
                }
                return 1
        }
        if a.id < b.id {
                return -1
        }
        if a.id > b.id {
                return 1
        }
        return 0
}
```

## Static Ordering

Use a fixed policy when the ordering is known at compile time. This allows the
compiler to inline comparison instead of loading a runtime procedure pointer:

```odin
note_order_compare :: proc(a, b: rawptr, descending: bool) -> int {
        return note_key_compare((^Note_Key)(a)^, (^Note_Key)(b)^)
}

Note_Order :: btree.Static_Order(Note_Key, btree.No_Projection, note_order_compare)
tree := btree.create_ordered(Note_Key, Note_Order)
defer btree.destroy(&tree)
```

Adapters must cast to the policy's declared item type. Their pointers borrow
temporary item copies: treat them as read-only and never retain them. Construction
checks that the policy's item and projection types match the tree, but cannot check raw-pointer
casts inside adapters. The comparator receives the tree's `descending` flag;
it may ignore it for a fixed order, as above. Keep ordering configuration fixed
for the tree's lifetime. A static policy also controls hinted searches.

For static text search, supply a fourth policy argument with signature
`proc(rawptr) -> (string, bool)` and pass `cache = .Text` at construction.
The cache is off by default, even when the policy supplies a text adapter. This
allows mixed numeric/text policies to opt in only for text-ordered instances.
Without a text adapter, the static policy reports all items ineligible.

Explicit type annotations must include the policy:
`BTreeG(Note_Key, Note_Order)` and `IterG(Note_Key, Note_Order)`. Types from
`create_ordered` and `iter` can be inferred. There is no runtime comparator API.

## Notes

- Not thread-safe; external synchronization is required for concurrent mutation/access.
- In-memory only; persistence must be handled by the caller.

## Text Search

`create_ordered` and `init_ordered` accept a `cache` enum and a
`descending` boolean. Text extraction comes from the policy's text adapter,
with signature `proc(item: rawptr) -> (text: string, ok: bool)`.
Select `cache = .Text` to enable it, or `.None` for ordinary nodes with unchanged allocation layout.

For eligible items, text must be the primary comparator key, ordered by raw
bytes (reverse byte order when `descending = true`). The original comparator
still resolves equal text and truncated-key collisions, including secondary ID
ordering. Return `ok = false` for unsupported query forms or records; queries or
nodes containing these records fall back to the original comparator. Keep the
accessor and its configuration fixed for the tree's lifetime, and do not mutate
stored key bytes outside tree operations.

Text nodes cache their common-prefix length and a search word per slot: four
bytes in leaves, eight bytes in internal nodes. The cache and contiguous search
words follow the node header, before the full items and child pointers, within
the same allocation. Item alignment is preserved; nodes without text caching
keep their original layout.
Non-hinted searches, including those during mutations, lazily populate this
cache and compare eight leaf words or four internal words at once on SIMD-capable
targets. Ordinary insertions,
replacements and deletions maintain valid search words in place. The common prefix
may stay conservatively short after deletion; inserting a key that does not share
it invalidates the cache. Sibling borrowing maintains words through the same
checked helpers; merging retains the parent's cache but invalidates the merged
child. After internal word maintenance, equal leading bytes in the endpoint
words trigger lazy rebuilding when neither endpoint could be entirely padding:
they prove that the common prefix can grow. This avoids keeping unnecessarily
short internal prefixes without reading key bytes during the check. Entirely
padding-like words (including eight NUL bytes) are conservatively skipped, and
leaf prefixes may remain short. Splits and eligibility changes can also require
a refresh. Hints retain the ordinary search
path. Even reads therefore require external synchronization. Each opt-in node uses
additional memory, and structural changes still incur cache-rebuilding costs.

Unhinted checked searches (`get`, `iter_seek`, `set`, and the `remove` fallback)
carry a prefix guarantee down the search path.
Two neighboring separators bound an interior child; their common cached bytes
can extend this guarantee, stopping before zero bytes that might be padding.
Outer children retain only ancestor guarantees. Descendants compare only the
remaining prefix bytes. This state lasts for one descent and adds no node storage.
Splitting a child preserves its ancestor bounds; extracting a predecessor for
deletion starts without the original query's prefix guarantee. Cache maintenance
still validates incoming text, and hinted searches keep their existing behavior.

Unhinted text `remove` first attempts an exact descent without prefix checks.
Only a full-comparator match permits an item mutation. If that descent finds
nothing, it retries from the root with checked prefix propagation. This targets
deletion of existing keys; absent keys may pay for two descents. `get`, `set`,
and lower-bound searches never use the optimistic path.

NRC's title, project, and assignee task indexes always use the text cache.
There is no uncached text-index configuration. Comparator fallback for unsupported
text query forms and collisions remains necessary for correctness.

## Numeric Search

The fifth optional `Static_Order` argument is a numeric adapter:
`proc(item: rawptr, descending: bool, projection: rawptr) -> u64`. Enable it with
`cache = .Numeric`. The tree stores the policy's declared projection type, not
an integer mode. A policy can serve several projection values without changing
the tree's type. For example:

```odin
Projection :: enum u8 {Time, Enum_Value}
Order :: btree.Static_Order(Key, Projection, compare, btree.static_no_text, numeric_key)
tree := btree.create_ordered(Key, Order, cache = .Numeric, projection = Projection(.Enum_Value))
```

The numeric adapter casts `projection` to `^Projection`, just as it casts `item`
to `^Key`. Both pointers borrow temporary copies: do not modify or retain them.
This raw-pointer boundary avoids this Odin version's unsupported dependent
callback parameter type. The constructor checks the projection type at compile
time; it cannot verify casts inside the adapter. Policies with only one projection
use `No_Projection` and ignore that pointer.

Keep cache, direction and projection fixed for the tree's lifetime. Text and numeric
caches cannot be selected together. The default adapter is a procedure sentinel
because this Odin version cannot generate code for a nil polymorphic-procedure
default; without a custom adapter all words collide and use the full comparator.

Words must preserve comparator order: `compare(a,b) < 0` requires `word(a) <= word(b)`;
equal keys must have equal words. This includes query keys, descending order and
out-of-range values. Collisions are permitted; SIMD finds a word's lower bound,
then the original comparator searches its equal-word interval. No text conversion,
prefix processing or optimistic removal is used. Hints keep comparator search.

Numeric nodes reuse the cache layout and mutation helpers, storing contiguous
`u64` words in both leaves and internal nodes. At degree 32 this adds 520 bytes
per node on x86-64: 16 metadata bytes plus 63 words. Insert/remove/replace maintain
warm words, while splits and merges can require a lazy rebuild. Reads therefore
still require external synchronization.

NRC enables numeric caching only for Task Priority/Status/Color (enum projection),
Task CreatedAt, and chronological Note indexes, including secondary Note indexes.
The chronological Task index is uncached: paired local benchmarks favored ordinary
nodes for its lookup and mutation workload. Note caches remain enabled for the
normally smaller per-tree working sets. DueAt, calendar, appointment, relation and
ticket indexes remain unchanged.
The enum projection includes secondary IDs when text is empty, and conservatively
collapses saturated-number buckets and nonempty text to comparator ties. Numeric
cache modes do not change the original comparator or cursor semantics.

## Cache Differential Tests

`test_hegel_text_search_model` in this package and
`test_hegel_task_query_numeric_model` in the root package apply identical
operations to cached and uncached trees, checked against one independent slice
model. The numeric property uses the actual Task projections. Both properties
prefill past a degree-32 leaf, warm search caches, mix hinted/unhinted mutations
and bursts, check lookup and bounded pages in both directions, and drain to empty.
The text oracle compares bytes explicitly; neither oracle uses a search-word
projection or the tree's comparator to determine expected order.

The normal budgets are 200 text cases and 144 numeric cases. For a larger,
reproducible run, execute these sequentially from the repository root:

```bash
HEGEL_SEED=20261027 HEGEL_TEST_CASE_MULTIPLIER=5 HEGEL_DIAGNOSTICS=1 \
  ./test/run_odin_tests.sh btree/ -o:speed -define:ODIN_TEST_LOG_LEVEL=error \
  -define:ODIN_TEST_NAMES=btree.test_hegel_text_search_model
HEGEL_SEED=20261027 HEGEL_TEST_CASE_MULTIPLIER=5 HEGEL_DIAGNOSTICS=1 \
  ./test/run_odin_tests.sh . -o:speed -define:ODIN_TEST_LOG_LEVEL=error \
  -define:ODIN_TEST_NAMES=main.test_hegel_task_query_numeric_model
```

## Benchmarking

Standalone benchmark entrypoint (no test runner overhead):

```bash
odin run bench -o:speed
```

The benchmark reads these environment variables:

- `BENCH_BTREE_PKG_COUNT` (default `1000000`)
- `BENCH_BTREE_PKG_DEGREE` (default `32`)
- `BENCH_BTREE_PKG_SEEK_WINDOW` (default `16`)
- `BENCH_BTREE_PKG_SCAN_ROUNDS` (default `1`)

Benchmark note: random `*-hint` lines are intentional control cases that demonstrate hint behavior under poor locality, not a recommended production mode.

For comparisons, run at least 10 independent process invocations with identical environment variables and report the median plus spread, not the best run. Keep the compiler, commit, CPU placement, power policy, and cache policy fixed. Each seek-window line reports both seek requests/s and visited items/s because a request combines one tree seek with zero or more iterator steps.

### C-Style Comparable Benchmark

The benchmark includes an integer-key section that mirrors `btree.c` labels:

- `load (seq)`, `load (rand)`
- `set (seq)`, `set (seq-hint)`, `set (rand)`
- `get (seq)`, `get (seq-hint)`, `get (rand)`
- `delete (rand)`

For structural comparability with `btree.c`, set Odin `BENCH_BTREE_PKG_DEGREE` so that `degree * 2 - 1` matches C `MAX_ITEMS`.

Example parity setup:

- Odin `BENCH_BTREE_PKG_DEGREE=16` -> effective `max_items=31`
- C `MAX_ITEMS=31` (or `32`)

### Small-Node Search Strategy

For non-hinted lookups, the tree uses a hybrid node search:

- linear search for small nodes (`len(items) <= LINEAR_SEARCH_NODE_CUTOFF`, currently `31`)
- binary search for larger nodes

This improves random-path performance on small/default node sizes where branch-heavy binary search can lose to simple sequential comparison.

### Comparing Against `btree.c`

Example parity commands:

- Odin: `BENCH_BTREE_PKG_COUNT=1000000 BENCH_BTREE_PKG_DEGREE=16 odin run bench -o:speed`
- C (tidwall/btree.c): `MAX_ITEMS=32 N=1000000 ./tests/run.sh bench`

The implementations do not emit identical phase sets, so compare only matching key type and operation boundaries. Run both on the same machine in balanced order and summarize repeated runs; historical single-run figures are intentionally not kept as reference results.
