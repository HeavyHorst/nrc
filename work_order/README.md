# Priority-aware work order

`Node :: struct {id: u64, dependency: u64, priority: i64, due_at: i64}`

`order(nodes: []Node) -> (ordered: [dynamic]u64, unresolved: [dynamic]u64)`

IDs must be unique (asserted). Zero dependency means none; a missing dependency
blocks that node and its descendants. Cycles, self-cycles and their descendants
also remain unresolved. Ready nodes compete anew after each emission: priority
descending, positive due date ascending (nonpositive dates last), ID ascending.
Unresolved uses the same comparator, not topological order. Input is unchanged.
All allocations use the allocator context; caller deletes both returned arrays.
The implementation uses flat child adjacency lists and a binary ready heap:
expected O(E + V log V) time with hash-map lookup, O(V) space.

## Verification

From the repository root:

```sh
odinfmt -w work_order/
./test/run_odin_tests.sh work_order/
odin build work_order/benchmark -o:speed -vet -out:/tmp/nrc-work-order-bench
/tmp/nrc-work-order-bench alloc
```

The Hegel property compares generated graphs against an independent quadratic
scan model (no heap or production comparator), including missing dependencies,
cycles, ties and reversed input enumeration. The default budget is 1,000 cases;
run `HEGEL_TEST_CASE_MULTIPLIER=10 ./test/run_odin_tests.sh work_order/` for 10,000.
The root simulation suite additionally sends fragmented WorkOrder requests
through the real parser/handler, verifies two exact cursor pages and checks
that querying leaves records, indexes and the ID sequence unchanged.

## Standalone benchmark

The separate `main` package covers 100, 1,000, 10,000 and 100,000 nodes for
independent, chain, fanout, mixed (roots, branching, missing dependencies and
blocked descendants), and cycle graphs. Fixtures and warmup are untimed.
Timing includes ordering, result checksum traversal and deletion; it is not
an isolated heap microbenchmark. One untimed pilot calibrates each sample to
roughly 0.75 seconds. Inspect actual durations before publishing results.
Checksums are validated after timing. The allocation mode performs one tracked
call per case, including result deletion, and asserts zero live allocations.
Its CSV fields are shape,size,alloc,allocation_count,total_allocated_bytes.
Timing CSV fields are shape,size,time,rounds,elapsed_nanoseconds.

Run at least ten independent processes, sequentially with no concurrent builds:

```sh
mkdir -p /tmp/nrc-work-order-results
for i in $(seq 1 10); do
  /tmp/nrc-work-order-bench > /tmp/nrc-work-order-results/run-$i.csv
done
python3 - <<'PY'
import csv, glob, statistics
samples = {}
for path in glob.glob('/tmp/nrc-work-order-results/run-*.csv'):
    for shape, size, mode, rounds, ns in csv.reader(open(path)):
        samples.setdefault((shape, int(size)), []).append(int(ns)/int(rounds))
for key, values in sorted(samples.items()):
    assert len(values) >= 10
    print(*key, 'ns/order median/min/max', statistics.median(values), min(values), max(values))
PY
```

Record commit, Odin version, CPU/hardware, power policy, allocator, warm-cache
state and flags with published medians and spread. Allocation runs are separate
from timing. Shared-orb measurements are not performance regression thresholds.
