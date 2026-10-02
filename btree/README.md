# btree (Odin)

Generic in-memory B-Tree for ordered keys in Odin.

This package is used in NRC for hot-path ordered indexing (for example, note sorting and pagination).

## Attribution

This implementation is based on and heavily inspired by [`github.com/tidwall/btree`](https://github.com/tidwall/btree), ported to Odin.

## Quick Start

```odin
package main

import "btree"

cmp_int :: proc(a, b: int) -> int {
        if a < b {
                return -1
        }
        if a > b {
                return 1
        }
        return 0
}

main :: proc() {
        tr := btree.create(int, cmp_int, btree.Options{degree = 32})
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

- `BTreeG(T)`: Generic tree container.
- `Options`: Construction options (`degree` controls node fanout).
- `Path_Hint`: Optional reusable lookup/insert/remove hint for locality-heavy workloads.
- `BTree_Stats`: Internal operation counters (`split_count`, `merge_count`, rebalancing counters).
- `IterG(T)`: Stateful bidirectional iterator.

## Construction And Lifecycle

- `create(T, compare, opts := Options{}, allocator := context.allocator) -> BTreeG(T)` creates a tree.
- `init(&tree, compare, opts := Options{}, allocator := context.allocator)` initializes a pre-existing tree value.
- `destroy(&tree)` frees all node memory owned by the tree.
- `clear_tree(&tree)` clears all contents (same effect as `destroy` for current contents) while keeping the tree value reusable.

The tree allocates internal node storage and must be destroyed to avoid leaks.

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

## Notes

- Not thread-safe; external synchronization is required for concurrent mutation/access.
- In-memory only; persistence must be handled by the caller.

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
