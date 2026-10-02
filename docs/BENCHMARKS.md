# Benchmark Reference

This document lists the benchmarks currently in this repository, what they measure, and how to run them.

## Benchmark Types

1. Test-runner benchmarks (`@(test)`): executed via `odin test ...` and usually gated by environment variables.
2. Workload benchmarks: larger end-to-end-style scenarios (index maintenance, WAL compaction, load generation).
3. Microbenchmarks: short tight loops for serialization, parsing, hashing, and protocol parsing.

## Notes About `odin test`

1. `odin test` enables its own memory tracking output in this toolchain.
2. Most benchmarks in this repo are intentionally env-gated so normal test runs stay fast.
3. Timing runs must use `-o:speed`, `-define:ODIN_TEST_THREADS=1`, an exact `ODIN_TEST_NAMES` filter, and normally `-define:ODIN_TEST_TRACK_MEMORY=false`.
4. Keep input counts, environment flags, durability mode, and cache state identical between comparisons. Record the commit, Odin version, CPU, and power policy.
5. Target at least 0.5–1 second per sample. Run at least 10 independent process invocations and report the median plus a spread such as min–max or IQR; do not publish the best single run.
6. Microbenchmarks use `time.Benchmark_Options`, keep setup and teardown outside the timed callback, populate the true operation and processed-byte counts, and validate an observable checksum after timing.
7. Disk, network, and concurrent workloads use explicit stopwatches because their multi-phase boundaries do not fit a single microbenchmark callback. Their output must state warm/cold cache and durability semantics.
8. Allocation counts are separate runs with explicit tracking allocators. Do not compare allocator-instrumented timing with normal timing.

## SPSC Queue Transfer

`spsc/spsc_benchmark.odin` measures one producer and one consumer on separate
OS threads, transferring `u64` values through the actual queue. Defaults are
100 million items and 16,384 usable slots. An item means one successful push
plus one successful pop, not an individual queue operation. Output reports
Mitems/s and amortized ns/item (not individual message latency).

The same queue receives a 100,000-item warmup before timing. Allocation and
thread creation are excluded; start signalling, busy-spin retries, payload
generation, FIFO/checksum arithmetic, and the final consumer join are included.
Assertions run afterward, checking sequence order, an independently calculated
checksum, and an empty queue. There is no CPU pinning, eventfd notification,
network, disk, or durability work. OS scheduling and core placement affect results.
This measures the cached-cursor implementation, not its speedup against an
uncached baseline. Normal tests skip the workload unless `BENCH_SPSC` is set.

```bash
odin build spsc -build-mode:test -o:speed -out:/tmp/nrc-spsc-bench \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_NAMES=benchmark_spsc_transfer
for run in $(seq 1 10); do BENCH_SPSC=1 /tmp/nrc-spsc-bench; done
rm /tmp/nrc-spsc-bench
```

Use `-define:SPSC_BENCH_ITEMS=200000000` to adjust sample duration toward
0.5–1 second, or `-define:SPSC_BENCH_CAPACITY=3` to exercise a smaller ring.
Report the median and spread of at least ten independent invocations with the
environment metadata listed above. For a quick correctness check:

```bash
BENCH_SPSC=1 ./test/run_odin_tests.sh spsc -o:speed \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_NAMES=benchmark_spsc_transfer \
  -define:SPSC_BENCH_ITEMS=100003 -define:SPSC_BENCH_CAPACITY=3
```

## Calendar JSON Field Reader

`calendar_json_benchmark.odin` compares the selective token reader (`reader=1`)
with JSON-tree extraction (`reader=0`). The baseline omits the former separate
safety preflight, so it is a conservative comparison, not an exact replay of the
old handler. Fixtures are an ordinary reminder, an escaped title, and a reminder
with 64 irrelevant nested records. Both readers receive identical bytes and use
a warmed reusable arena, reset after each read. The checksum validates deadline
and title length; allocation runs additionally compare the title text.

```bash
odin build . -build-mode:test -o:speed -out:/tmp/calendar-json-bench \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_NAMES=benchmark_calendar_json
for run in $(seq 1 10); do BENCH_CALENDAR_JSON=1 /tmp/calendar-json-bench; done
BENCH_CALENDAR_JSON=1 BENCH_CALENDAR_JSON_ALLOC=1 /tmp/calendar-json-bench
rm /tmp/calendar-json-bench
```

The last run measures allocator calls/bytes separately, not timing. These
are warm in-memory parser measurements: no Zstd, network, disk, index building
or durability work is included. Do not extrapolate them to end-to-end latency.

2026-09-27 orb measurement: 10 independent invocations, median (min–max),
with the command above. Base commit
[`692cdb2`](https://github.com/HeavyHorst/nrc/commit/692cdb26645b190474ede4ce518080b11515ab00)
plus the uncommitted Calendar implementation; Odin
`dev-2026-09-nightly:a2fb372`, Linux x86-64, 2 KVM vCPUs,
Intel Xeon @ 2.60 GHz. Host power policy is not exposed. CPU scheduling is shared;
these are not dedicated-hardware results. Source SHA-256:
`calendar_index.odin`: `c5e804eca1c9884f97890afb1b3ca643c81347d6823ea5fece2778b13ff6964c`;
`calendar_json_benchmark.odin`: `cec27541e8595a37758c0e22d8128d2f81341175b53b4000f58b3475f1af3220`.

| Fixture | Tree µs/read | Token µs/read | Allocations, tree → token | Allocated bytes, tree → token |
|---|---:|---:|---:|---:|
| Ordinary reminder | 2.904 (2.700–3.616) | 1.213 (1.099–1.353) | 10 → 0 | 975 → 0 |
| Escaped title | 3.169 (2.990–3.373) | 1.261 (1.152–1.455) | 10 → 1 | 987 → 22 |
| 64 extra nested records | 123.705 (111.452–144.131) | 45.840 (42.786–54.260) | 394 → 0 | 91,046 → 0 |

Allocation counts come from the separate instrumented run, not the timing run.
These results precede extraction of the shared `json_metadata.odin` reader and
its reuse for Note metadata. They do not measure the current generic reader or
Note index maintenance.

## Index Structure Benchmarks

### Note Index RB-Tree

1. File: `note_index_rbtree_benchmark.odin`
2. Entry point: `benchmark_note_index_rb`
3. Run: `BENCH_NOTE_INDEX_RB=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_note_index_rb`
4. Measures: random and sequential insert, update as remove+insert, cursor pagination, delete, and memory snapshots.
5. Shared workload tunables: `BENCH_NOTE_INDEX_NOTES`, `BENCH_NOTE_INDEX_UPDATES`, `BENCH_NOTE_INDEX_DELETES`, `BENCH_NOTE_INDEX_PAGE_LIMIT`, and `BENCH_NOTE_INDEX_PAGES`.
6. `BENCH_NOTE_INDEX_TRACK_ALLOC=1` enables a separate allocation-instrumented run; it is disabled by default and its timing is not comparable to a normal run.

### Note Index B-Tree (Local Package)

1. File: `note_index_btree_benchmark.odin`
2. Entry point: `benchmark_note_index_btree`
3. Run baseline: `BENCH_NOTE_INDEX_BTREE=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_note_index_btree`
4. Add `BENCH_NOTE_INDEX_BTREE_HINTS=1` for hints or `BENCH_NOTE_INDEX_BTREE_LOAD=1` for the sorted load path.
5. Measures: random insert, sequential insert (`set` vs `load`), update remove+insert, paging, delete, allocator/memory and structural counters.
6. Uses the same shared workload tunables as RB-tree. Legacy B-tree-specific count variables remain accepted. `BENCH_NOTE_INDEX_TRACK_ALLOC=1` is a separate allocation run.

## B-Tree Package Workload Benchmark

1. File: `btree/btree_benchmark.odin`
2. Entry point: `btree/bench/main.odin`
3. Run: `odin run btree/bench -o:speed`
4. Measures: sequential/random `set`, hinted `set`, `load`, sequential/random `get`, hinted `get`, random `remove`, hinted `remove`, iterator seek+pivot stepping, full `scan`, full `reverse`.
5. Dataset: random unique 16-digit numeric string keys; sequential phases use sorted copy; random phases use shuffled copy.
6. Tunables: `BENCH_BTREE_PKG_COUNT`, `BENCH_BTREE_PKG_DEGREE`, `BENCH_BTREE_PKG_SEEK_WINDOW`, and `BENCH_BTREE_PKG_SCAN_ROUNDS`. The old `PIVOT_SPAN` name remains a compatibility fallback.
7. Seek-window output reports requests/seeks per second separately from visited items per second; these are not interchangeable operation counts.

## Persistence Microbenchmarks

### Asset Persistence

1. File: `asset_persistence_test.odin`
2. Benchmarks: `benchmark_asset_record_serialization`, `benchmark_asset_payload_size_calculation`, `benchmark_asset_xxhash_crc`.
3. Run one at a time, for example: `BENCH_PERSISTENCE_MICRO=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_asset_record_serialization`.
4. Measures: full asset record serialization and hash/checksum primitive throughput.

### Edge Persistence

1. File: `edge_persistence_test.odin`
2. Benchmarks: `benchmark_edge_record_serialization`, `benchmark_edge_payload_size_calculation`, `benchmark_edge_xxhash_crc`.
3. Run one at a time, for example: `BENCH_PERSISTENCE_MICRO=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_edge_record_serialization`.
4. Measures: full edge record serialization and hash/checksum primitive throughput.

## Sharded WAL Compaction Stress Benchmark

1. File: `shard_compaction_benchmark.odin`
2. Entry point: `benchmark_shard_compaction_stress`
3. Run: `BENCH_SHARD_COMPACTION=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_shard_compaction_stress`
4. Measures: sealed-WAL write throughput, background checkpoint duration and reduction ratio, concurrent active-WAL write throughput, and verified post-publication replay.
5. Default scale: 550,000 repeated 1 KiB updates in the sealed WAL and 100,000 updates written while checkpoint construction runs. This intentionally crosses the 500 MiB production rotation threshold.
6. Overrides: `NRC_SHARD_BENCH_BASE_UPDATES`, `NRC_SHARD_BENCH_ACTIVE_UPDATES`, and `NRC_SHARD_BENCH_PAYLOAD_BYTES`.
7. Base/active write timers include write flushes and production periodic fsyncs (100 MiB or 1 second), but exclude rotation's forced sync. Checkpoint duration covers thread start through direct-I/O replay, checkpoint write/fsync, and verification; durable rename/manifest publication is validated but untimed. The overlap flag is sampled while active writes execute, not inferred from nested timer lengths.

### Ordinary Sweep Scaling

1. Entry point: `benchmark_shard_ordinary_sweep_scaling` in `shard_compaction_benchmark.odin`.
2. Run: `BENCH_SHARD_ORDINARY_SWEEP=1 NRC_SHARD_ORDINARY_SWEEP_GIB=5 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_shard_ordinary_sweep_scaling`.
3. Run the pre-index comparison by additionally setting `-define:NRC_SHARD_SEGMENT_METADATA_INDEX_ENABLED=false`; this retains the former prefix and complete newer-tail WAL scans.
4. Scale with `NRC_SHARD_ORDINARY_SWEEP_GIB` (normally 5, 10, and 20) and optionally `NRC_SHARD_ORDINARY_SWEEP_SEGMENT_MIB` (default 500). Each immutable segment contains large atomic task transactions with distinct entity keys, keeping the fixture live and forcing multiple clean catalog groups without requiring payload-sized replay memory. Fixture creation emits the same record metadata that raw normalization produces, outside the sweep timer.
5. Reports fixture and sweep duration, segment/group counts, total logical read amplification, and bytes attributed to prefix-floor discovery, latest-state discovery, dirty measurement, retained copying, and semantic replay. Metadata summary and exact-index reads are charged to the prefix or latest phase that requested them.
6. This is a large disk workload, not a microbenchmark. Run one process at a time, record cache state, and use independent process repetitions before publishing timing claims.

## Retained Message Storage Benchmarks

1. File: `message_store_benchmark.odin`
2. Append/recovery/index run: `BENCH_MESSAGE_STORE=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_message_store_initial`.
3. Add `NRC_MESSAGE_BENCH_TRACK_ALLOC=1` only for a separate allocation run; append allocation counts exclude store initialization, and tracking intentionally distorts timing.
4. Sealed-history run: `BENCH_MESSAGE_HISTORY=1 odin test . -o:speed -define:NRC_SIMULATION=true -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_message_store_sealed_history`.
5. The sealed-history benchmark uses the production pagination handler and io_uring reads, with simulated network delivery to remove socket variability. It explicitly warms one ascending and descending request before reporting average, p50, and p95 warm-cache latency.
6. Concurrent history under live retained-message traffic: `BENCH_MESSAGE_HISTORY_LIVE=1 odin test . -o:speed -define:NRC_SIMULATION=true -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_message_store_history_under_live_traffic`.
7. The live-traffic benchmark runs multiple production history and send-v2 handlers on the owning worker, interleaving io_uring completion waves with rate-controlled unique writes. It reports no-traffic and loaded p50/p95 page latency plus achieved write and page rates.
8. Overrides: `NRC_MESSAGE_BENCH_RECORDS`, `NRC_MESSAGE_BENCH_CONTENT_BYTES`, `NRC_MESSAGE_BENCH_HISTORY_ROUNDS`, `NRC_MESSAGE_BENCH_HISTORY_READERS`, `NRC_MESSAGE_BENCH_LIVE_WRITERS`, and `NRC_MESSAGE_BENCH_LIVE_WRITE_RATE`. Profilers may set `NRC_MESSAGE_BENCH_SKIP_BASELINE=1` to isolate the loaded phase.
9. Initial append timing includes write flushes and threshold-triggered production fsyncs, but excludes shutdown's final sync. Recovery uses direct-I/O WAL inspection. The separately reported seal/index phase includes final WAL sync plus durable index and manifest publication.

### Retained Message Durable ACK Comparison

Build the baseline and candidate separately with `odin build . -o:speed`, naming the
binaries `before` and `after` in a temporary directory. From `benchmark/`, build
`go build -o /tmp/nrc-retained-bins/retained-message-bench ./cmd/retained-message-bench`.
From the repository root, run:

```bash
python3 benchmark/retained-commit/run.py \
  --binaries /tmp/nrc-retained-bins --output /tmp/nrc-retained-results --repetitions 10
```

The runner uses Amp-supervised servers, one worker on CPU 0 and the Go client on
CPU 1. Each sample gets a fresh process and storage directory, 24-hour retention,
200 ms untimed warmup, and one measured second plus completion of outstanding
requests. Before/after order alternates between repetitions. It tests one
workspace/conversation, unique `C_SendMessageV2` IDs, and no subscribers; this is
ingestion/ACK performance, not fanout or sealed-history/rotation performance.
Depth means requests per connection wave (at most four), not an open-loop arrival
rate. Throughput counts validated correlated ACKs; latency starts immediately
before each WebSocket write and ends at its ACK read, including client scheduling
and processing of earlier ACKs. Results include raw samples, throughput median and
min–max, and medians of each run's p50/p99 latency.

The baseline ACK follows write completion and does **not** guarantee fsync;
the candidate ACK follows fsync with a 1 ms / 128 KiB group-commit policy. This is
the cost of strengthening durability, not a like-for-like durability comparison.
Neither timing includes shutdown. Cache is warmed but not dropped; virtual-disk
fsync behavior and shared CPU topology limit extrapolation to production hardware.

#### Measured comparison (2026-09-07)

Baseline: [9b289cd](https://github.com/HeavyHorst/nrc/commit/9b289cd340d79723d4cd8796f382495ad212a4f3).
Candidate: that baseline plus the uncommitted retained durable-ACK changes;
the report records the source diff and binary SHA-256 hashes. The later
multi-worker simulation accounting fix is test-only and is not part of this
runtime comparison. Odin `dev-2026-08-nightly:902106f`, Go `1.26.7`, optimized
builds, ext4 virtual disk, Intel Xeon @ 2.60 GHz; two exposed logical CPUs share
one core. CPU power policy is not exposed by the orb. These are closed-loop
client/server measurements, not isolated storage or maximum-capacity claims.

All 120 samples succeeded (ten per variant/case), validating 4,471,371 measured
ACKs. Samples lasted 1.000–1.013 seconds. Throughput entries are median
[min–max] messages/s; latency entries are medians of per-run percentiles.

| Connections × depth | Content | Before messages/s | Durable messages/s | Change | ACK p50 ms, before → after | ACK p99 ms, before → after |
|---|---:|---:|---:|---:|---:|---:|
| 1 × 1 | 256 B | 8,205 [7,481–8,888] | 559 [547–577] | −93.2% | 0.126 → 1.743 | 0.180 → 2.130 |
| 16 × 1 | 256 B | 79,119 [75,875–80,848] | 8,688 [8,282–8,972] | −89.0% | 0.177 → 1.817 | 0.613 → 2.435 |
| 128 × 1 | 256 B | 63,230 [48,227–65,809] | 54,012 [41,822–56,738] | −14.6% | 1.988 → 2.121 | 5.899 → 6.589 |
| 16 × 4 | 256 B | 99,128 [87,821–105,569] | 35,605 [28,607–36,566] | −64.1% | 0.483 → 1.723 | 1.700 → 3.435 |
| 16 × 1 | 4 KiB | 33,389 [31,470–34,562] | 8,470 [8,298–8,801] | −74.6% | 0.402 → 1.872 | 1.840 → 2.860 |
| 16 × 4 | 4 KiB | 37,761 [33,571–39,903] | 25,181 [20,175–26,450] | −33.3% | 1.185 → 2.225 | 4.703 → 5.471 |

Waiting for durability costs approximately 1.6 ms median ACK latency for small
stop-and-wait requests here. Concurrent requests amortize group commit, but the
128-connection results also have substantial host/client scheduling variation.
No outliers were removed. These runs do not establish power-loss behavior of the
virtual disk, long-running rotation performance, or a production latency SLA.

#### Larger connection/pipeline sweep (2026-09-07)

Add `--connection-sweep` to the runner command to repeat a 128-connection,
depth-one control and test 64/128/256/512 connections at depth four, all with
256-byte content. Maximum outstanding requests are connections × depth; waves
drain before refill, so this is not a constantly full sliding window. Hardware,
server source revisions, one-worker/one-workspace placement, warmup and timing policy
match the comparison above. This does not measure multi-worker scaling.

The runner now sets the **benchmark processes'** file-descriptor limit to 8,192.
The initial 512-connection attempt exhausted the orb's 1,024-descriptor soft
limit (the server opens about 520 descriptors before clients connect). No
application queue or retained-operation limits were changed. A subsequent
attempt exposed the benchmark client's incorrect request-order ACK assumption
on the unchanged baseline. The client now matches by correlation ID, rejects
duplicate/unknown ACKs, requires every request to complete, and timestamps the
matching request. Reversed, duplicate, unknown and missing ACK regression cases
pass with `go test -race ./cmd/retained-message-bench` from `benchmark/`.
Both interrupted campaigns were excluded; the entire sweep was restarted with
the corrected client and identical descriptor limits for both server variants.

The final **100/100 samples passed**, validating 3,259,742 measured ACKs, with
ten fresh-server runs per variant/case. Measured intervals including final drain
lasted 1.001–1.292 seconds. Entries are median [min–max] messages/s and medians of
per-run ACK latency percentiles. No completed-run outliers were removed.

| Connections × depth | Max in flight | Before messages/s | Durable messages/s | Change | ACK p50 ms, before → after | ACK p99 ms, before → after |
|---|---:|---:|---:|---:|---:|---:|
| 128 × 1 | 128 | 53,808 [46,670–70,077] | 50,695 [42,399–54,136] | −5.8% | 2.321 → 2.206 | 6.899 → 8.271 |
| 64 × 4 | 256 | 47,734 [37,035–50,625] | 56,642 [49,368–64,652] | +18.7% | 5.139 → 4.070 | 12.983 → 13.563 |
| 128 × 4 | 512 | 29,413 [23,307–31,750] | 30,058 [27,654–33,331] | +2.2% | 17.527 → 16.639 | 25.879 → 30.903 |
| 256 × 4 | 1,024 | 16,891 [15,268–17,773] | 16,697 [15,911–17,328] | −1.1% | 62.815 → 61.855 | 73.503 → 79.679 |
| 512 × 4 | 2,048 | 9,846 [9,033–10,333] | 9,859 [9,234–10,500] | +0.1% | 230.527 → 232.127 | 246.527 → 257.471 |

The durable version peaks at 64 × 4 within this sweep, but pushing further
reduces throughput and increases latency sharply in **both** implementations.
At the deepest loads their throughput is effectively comparable relative to
the observed spread; fsync gating is not the sole cause of the scaling decline.
This experiment does not isolate the client/server/kernel bottleneck. The
repeated depth-one control also shows substantial host/run variation, so small
percentage differences should not be treated as precise performance gains.
These connections continuously send at their maximum closed-loop rate, unlike
hundreds of mostly idle human chat users.

#### Profiling the high-concurrency decline (2026-09-07)

`perf record -e cpu-clock:u -F 499 --call-graph dwarf -p SERVER_PID -- sleep 9`
works in this orb; hardware `cycles:u` reports unsupported. The server was built
with `odin build . -o:speed`, **without `-debug`**, which would enable different
debug allocator/logging behavior. The ordinary ELF symbol table identifies Odin
functions; some optimized call chains are incomplete. Client profiling used
`cpu-clock:u` with frame-pointer call graphs. Neither profiling nor its throughput
was mixed into the uninstrumented comparison samples.

Profiles used fresh stores, one second of warmup and six seconds of depth-four,
256-byte traffic. At 512 connections, two independent profiles attributed
**61.62% and 61.12%** of server user-space samples (inclusive, not additive with
children) to `retained_message_stage_deferred`. Its hot descendants are
`retained_message_queue_append`, `retained_message_defer_append`, string/map
hashing, fingerprinting and allocation. No samples were lost. `/proc` thread
counters show the worker consuming 93.6% and 94.8% of a CPU during the workloads;
user CPU was 6.62/6.80 seconds and system CPU 0.50/0.40 seconds. Run-queue wait
was 0.186/0.092 seconds over roughly 7.6 seconds, not the dominant delay. The
repeat client's `/usr/bin/time -v` reported 19% CPU (0.49 seconds user, 0.93
system), no major faults and no swaps. This is predominantly server user-space
work, not client saturation or waiting for fsync. A 64-connection profile also
showed deferred replay, but its longer run reached segment rotation/index work;
do not interpret that profile as the original one-second no-rotation workload.

The cause is the deferred-queue drain algorithm:

1. The default write batch admits only **16 records**.
2. After publishing that batch, `retained_message_stage_deferred` clears the
   deferred map and retries **every** remaining item through the append path.
3. Only the next batch fits. All others recompute fingerprints, allocate dedup
   keys, redo lookups, and rebuild the deferred map/array, then repeat after the
   next flush. Rebuilding these queues also adds allocation/copy churn.

For a fixed backlog of \(Q\) unique messages and batch size \(B\), retry work
grows as \(O(Q^2/B)\), rather than \(O(Q)\). Illustratively, a fully queued burst
of 2,048 messages at batch size 16 can entail 132,096 append-path visits,
including initial attempts, even with no new arrivals. Both compared versions
contain this algorithm; ACK-after-fsync did not introduce it.

As a causal cross-check, twenty **uninstrumented** fresh-server runs alternated
`NRC_MESSAGE_WRITE_BATCH_RECORDS=16` and `128` (ten each), keeping the same
binary, 512 connections, depth four, 256-byte payload, 200 ms warmup, one-second
measurement plus drain, one worker, and **unchanged 1 ms / 128 KiB fsync gating**.
All twenty runs passed correlated ACK validation:

| Write batch records | Median messages/s [min–max] | Median ACK p50 | Median ACK p99 |
|---|---:|---:|---:|
| 16 (default) | 9,931 [8,959–10,216] | 232.1 ms | 252.8 ms |
| 128 (diagnostic override) | 52,431 [47,760–57,623] | 39.1 ms | 65.1 ms |

The 5.28× throughput increase supports the profile and code diagnosis. It is
not a recommendation to change the default blindly: increasing batch size also
changes write amortization and fairness. The structural remedy is incremental
FIFO draining that preserves the untouched tail and its dedup metadata, rather
than repeatedly rebuilding it. No production batching or durability behavior
was changed during this investigation.

#### Incremental deferred-drain fix (2026-09-07)

The drain now consumes only the prefix that fits and preserves the remaining
contexts, keys and map entries. It compacts after consuming at least as many
entries as remain, making queue maintenance amortized linear. Deferred duplicate
requests remain owned by their exact primary rather than repeating admission;
rotation or legitimate expired-ID reuse cannot change that association.

The following comparison uses **durable ACKs in both binaries**, unchanged
1 ms / 128 KiB fsync grouping and the default **16-record write batch**. It is
not the earlier write-ACK versus fsync-ACK comparison. Ten alternating fresh-server
samples per binary/configuration (100 total) used one worker, 256-byte unique
messages, no subscribers, 200 ms warmup and one-second timed waves plus drain.
The server and client were pinned to CPUs 0/1 (exposed SMT siblings) in the orb.
Builds used `-o:speed`, without allocation instrumentation; no builds, tests or
profiles ran concurrently with the timing samples. All correlated ACK checks passed.

| Connections × outstanding/connection | Before messages/s [min–max] | After messages/s [min–max] | Ratio | ACK p99 before → after |
|---|---:|---:|---:|---:|
| 128 × 1 | 50,360 [34,774–56,252] | 50,054 [40,834–53,092] | 0.99× | 8.69 → 8.57 ms |
| 64 × 4 | 62,681 [47,441–72,605] | 82,474 [63,516–85,938] | 1.32× | 12.10 → 10.96 ms |
| 128 × 4 | 29,999 [27,296–32,177] | 83,707 [79,232–90,307] | 2.79× | 29.82 → 21.19 ms |
| 256 × 4 | 16,941 [16,534–17,706] | 79,956 [70,034–90,837] | 4.72× | 79.52 → 42.10 ms |
| 512 × 4 | 9,799 [9,174–11,291] | 70,379 [60,300–82,371] | 7.18× | 257.02 → 66.46 ms |

Throughput and p99 columns report medians across independent processes, not a
pooled latency distribution. The depth-one control is effectively unchanged;
the high-outstanding collapse is substantially reduced, not replaced by unlimited
scaling. This is an ingestion benchmark, **not a broadcast/fanout measurement**.

A separate 512 × 4 `cpu-clock:u`/DWARF profile (one-second warmup, six-second
measurement) attributed 7.62% inclusive user-space samples to deferred staging,
versus approximately 61% in the earlier profiles, with no lost samples. The
faster run reached segment rotation: WAL clustering accounted for 19.39% and
index writing 8.58% inclusive samples (overlapping, not additive). Its instrumented
p99 was 665.6 ms; do not extrapolate the short fresh-store p99 table to sustained
rotation-heavy traffic or compare that instrumented latency directly to the table.

Reproduce with `benchmark/retained-commit/run.py --connection-sweep --repetitions 10
--binaries DIR --output DIR --durability 'Both durable; batch16; before full replay,
after incremental drain'`. Binary hashes, compiler/CPU/filesystem metadata and
all samples are in `.amp/in/artifacts/retained-incremental-drain/results.json`.
The post-fix profile reports are alongside it under `profile/`.

#### Buffered offline WAL writes (2026-09-07)

The next optimization buffers `WAL_File_Builder` output in a fixed 128 KiB
array, shared by retained-segment sealing and shard checkpoint/cleaner writers.
It adds 128 KiB per builder without a new heap allocation. `file_size` remains
the logical size, including buffered records, so caller-generated offsets and
segment limits are unchanged. Oversized records flush the pending prefix and
bypass the buffer. Finish flushes before fsync; short writes and write errors
abort and close the file. Hash chaining, on-disk formats, directory/manifest
publication ordering and live ACK durability are unchanged.

Compared with [the preceding implementation](https://github.com/HeavyHorst/nrc/commit/80d47c204861037f0c51723c985e14eb93fcc4b8),
ten alternating independent process runs per binary produced:

| Measurement | Before median [min–max] | Buffered median [min–max] |
|---|---:|---:|
| Seal/index 100,000 records | 1,091 ms [1,044–1,293] | 848 ms [794–870] |
| Rotation-heavy ingestion | 53,267 msg/s [45,793–70,536] | 60,268 msg/s [54,003–72,486] |
| Network ACK p50 (median of runs) | 24.61 ms | 24.71 ms |
| Network ACK p99 (median of runs) | 684.03 ms | 514.94 ms |

Sealing takes **22.3% less time**; this network workload gains **13.1% throughput**
and its median per-run p99 decreases **24.7%**. These are not worst-case latency
guarantees. Rotation remains synchronous, with per-record source reads, sorting,
hashing, index construction and validation still on the worker.

The isolated fixture is `benchmark_message_store_initial`: 100,000 records,
256-byte content, 64 interleaved conversations, 40.15 MiB WAL and 11.44 MiB index.
Each process creates a fresh store; sealing follows append/dedup/recovery, with
no page-cache drop and the production strict-inspection direct-I/O policy intact.
One process per binary was discarded as warmup, then ten per binary were timed.
The benchmark ran on CPU 0 with `-o:speed`, `ODIN_TEST_THREADS=1` and
`ODIN_TEST_TRACK_MEMORY=false`.

Network runs used `benchmark/retained-commit/run.py --rotation --repetitions 10
--binaries DIR --output DIR --durability 'Both durable; before per-record offline
writes, after 128KiB offline buffering'`: 512 connections, depth four, 256-byte
content, one worker, one-second warmup and six-second timed waves plus drain.
There are no subscribers. All 20 runs passed correlated ACK checks and produced
one or two sealed segments; rotation count is recorded per sample. This
time-based workload does not force identical rotation counts in each run.
The existing 16-record live batches and 1 ms / 128 KiB fsync policy were unchanged.

Both experiments used the same two-vCPU Intel Xeon 2.60 GHz orb (CPUs exposed as
SMT siblings), with the network server/client pinned to CPUs 0/1. Host power
policy was not controlled. Builds, tests and tracing did not overlap timing runs.
Compiler, filesystem, binary hashes and raw samples are saved under
`.amp/in/artifacts/retained-buffered-writes/{rotation,network}/results.json`.

A separate `strace -f -c` run of the 100,000-record fixture recorded total
`write` calls dropping from **200,012 to 100,334**, while `pread64` stayed at
**100,087**. The totals include fixture ingestion as well as sealing; the
100,000 per-record sealed-WAL writes become 322 buffered writes. Trace timings
are instrumentation-distorted and are not included in the performance table.

#### Reusing segment-index scratch and validated bytes (2026-09-07)

The index writer now encodes the conversation index directly from the sorted
scratch records produced by clustering, then sorts that same array in place for
the dedup index. This eliminates two full record-array allocations/copies and
the redundant conversation sort during sealing. Recovery explicitly sorts its
scratch records before invoking the same writer.

Rotation and recovery also read each index once, validate those bytes, and
borrow them for metadata loading. Validation restores the checksum field;
metadata and cached entries retain their own storage. Missing/corrupt indexes
still rebuild from strictly inspected WALs, and rotation still validates the
new index before manifest publication. No validation checks, formats, fsyncs,
or ACK durability requirements were removed.

A fresh paired comparison against the **already-buffered offline builder**
used the same two workloads and orb methodology as the preceding experiment:
ten alternating measured processes per binary per workload, plus one discarded
warmup process per binary for the isolated fixture. Timing did not overlap
builds, tests or instrumentation.

| Measurement | Before median [min–max] | Index reuse median [min–max] |
|---|---:|---:|
| Seal/index 100,000 messages, 64 interleaved conversations | 807 ms [781–861] | 766 ms [758–785] |
| Single-conversation rotation-heavy ingestion, 512 × 4 | 56,525 msg/s [51,913–76,038] | 62,371 msg/s [53,934–71,640] |
| Network ACK p50 (median of runs) | 25.33 ms | 23.19 ms |
| Network ACK p99 (median of runs) | 515.84 ms | 489.98 ms |

The isolated sealing median improved **5.1%**, with every paired after-run
faster. Network median throughput increased **10.3%** and median per-run p99
decreased **5.0%** in this sample. Network ranges overlap substantially and
individual runs seal one or two segments; do not interpret these medians as
guaranteed gains or compare them directly with previous experiments' medians.
All 20 network samples passed ACK checks and sealed at least one segment.
Source reads, WAL clustering and worker-blocking rotation remain unchanged.

Raw results, binary hashes and methodology are under
`.amp/in/artifacts/retained-index-reuse/{rotation,network}/results.json`.
Verification passed all 467 normal and 527 simulation root tests plus vet.
The expanded index regression rejects bad checksums, generation mismatches,
invalid offsets, repeated sequences and malformed layouts, then checks that
recovery rebuilds byte-identical conversation and dedup indexes.

#### Coalescing adjacent WAL reads (2026-09-07)

After Oracle approved index reuse, the next change coalesces physically adjacent
records in the desired output order into one read. The reusable buffer is
128 KiB or the largest record, whichever is larger. It never prefetches through
gaps: fully interleaved conversations retain per-record reads with no added
application-level read amplification. Each record still goes through the WAL
builder, preserving record framing, hash chaining and publication semantics.

Fresh comparisons against the **index-reuse version** used ten alternating
measured processes per binary per workload. The isolated fixtures discard one
warmup process per binary and seal exactly 100,000 messages with 256-byte content.
Network runs use the existing `--rotation` workload (512 × 4, one conversation,
one-second warmup, six-second timed traffic plus drain, one worker). Hardware,
affinity, build flags and cache policy match the preceding experiments; no
builds, tests or tracing overlapped timing runs.

| Measurement | Before median [min–max] | Coalesced median [min–max] |
|---|---:|---:|
| Seal/index, one conversation | 662 ms [631–706] | 607 ms [576–654] |
| Seal/index, 64 interleaved conversations (control) | 784 ms [760–822] | 794 ms [771–843] |
| Single-conversation rotation-heavy ingestion | 53,425 msg/s [50,633–59,962] | 61,081 msg/s [53,707–67,267] |
| Network ACK p50 (median of runs) | 26.71 ms | 25.76 ms |
| Network ACK p99 (median of runs) | 499.07 ms | 448.64 ms |

The fixed single-conversation fixture takes **8.3% less sealing time**, with
all ten after-runs faster than their paired baseline. The interleaved control
shows **1.3% more time**, with overlapping ranges—not evidence of a benefit
for that layout. Network medians show **14.3% higher throughput** and **10.1%
lower p99**, but samples seal one or two segments, so those end-to-end gains
include variable rotation counts and are not guaranteed. All 20 network samples
passed ACK validation and sealed at least one segment.

For the fixed single-conversation fixture, separate `strace -f -c -e trace=pread64`
runs counted **100,086 → 408** positioned reads, including fixture recovery and
strict inspection. The clustering pass itself changes from 100,000 individual
reads to 322 grouped reads. Instrumented timings are excluded from the table.

The benchmark now accepts `NRC_MESSAGE_BENCH_CONVERSATIONS` (default 64); use
`1` for the contiguous fixture with `BENCH_MESSAGE_STORE=1` and
`NRC_MESSAGE_BENCH_RECORDS=100000`. Both single-conversation binaries were built
with this same fixture change. The baseline used the approved index-reuse patch
without read coalescing. Raw results and binary hashes are under
`.amp/in/artifacts/retained-read-coalescing/{single-rotation,rotation,network}/results.json`,
with syscall counts under `syscalls/`.

All 468 normal and 528 simulation root tests passed, plus vet. A new regression
checks payloads, fingerprints, sequences and index offsets for contiguous runs
crossing read-buffer boundaries, interleaved records and grouped/backward-seek
layouts. Rotation is still synchronous; this does not remove worker stalls.

#### Copying already-ordered WALs (2026-09-07)

The next comparison uses `9ba395d` as baseline. After strict source inspection,
the candidate checks whether physical order already matches conversation/sequence
order. If so, it copies the closed append-only source verbatim in 128 KiB chunks,
preserving offsets and the validated hash chain instead of sorting and rehashing.
Interleaved files retain the coalesced-read/rebuild path. Both paths still fsync
the new WAL before index/manifest publication; ACK durability is unchanged.
An explicit indexed-byte-count check rejects legacy headers incompatible with
the index callback's current-header offsets.

Same isolated fixtures and network recipe as above: ten alternating measured
processes per binary, no concurrent builds/tests/tracing, one discarded warmup
per isolated fixture. Raw logs, samples and binary hashes are under
`.amp/in/artifacts/retained-verbatim-copy/{1,64,network}/results.json`.

| Measurement | Before median [min–max] | Candidate median [min–max] |
|---|---:|---:|
| Seal/index, one conversation | 595 ms [571–667] | 486 ms [479–567] |
| Seal/index, 64 interleaved conversations | 771 ms [753–995] | 770 ms [756–851] |
| Rotation-heavy ingestion, 512 connections × 4 outstanding | 62,406 msg/s [57,518–77,144] | 67,550 msg/s [58,880–73,401] |
| Network ACK p50 (median of runs) | 23.37 ms | 22.54 ms |
| Network ACK p99 (median of runs) | 453.38 ms | 225.95 ms |

The isolated ordered fixture uses **18.4% less sealing time**, with non-overlapping
sample ranges; the interleaved control is essentially unchanged. Network throughput
is **8.2% higher by median**, but ranges overlap substantially. Network p99 is
bimodal and sensitive to rotation timing/counts; the median is not evidence
that typical rotation stalls or tail latency have halved. All network samples
passed ACK validation and sealed at least one segment. Rotation remains
synchronous, and this optimization does not change broadcast fanout costs.

The copy tests cover oversized chunks, byte identity, hash-chain continuation,
nonempty-builder rejection, truncated input extent, short/error writes and fsync
failure. Root coverage includes ordered/interleaved/grouped layouts and strict
rejection of legacy-header offsets. Oracle found no blocker to buffered copying
under the append-only source and supported crash/fault model; this is not a
general copy contract for externally overwritten files.

#### Borrowing decoded fields during WAL scans (2026-09-07)

Against `5efdca6`, the candidate uses the existing borrowed decoder in
`message_scan_record` instead of allocating/freeing three strings and the content
for every scanned record. Validation and index building consume the fields
synchronously. Recovery already copies retained keys and cached payloads into
owned arenas. Strict checksums, fingerprints, fsync and publication are unchanged.

Ten alternating measured processes per version and layout used the same 100,000
record, 256-byte fixture, CPU 0, optimized/uninstrumented binaries and one discarded
warmup per version. Files were fresh per process and warm from fixture writes;
strict inspection still uses direct I/O. No builds/tests/tracing overlapped timings.
Raw logs, hardware metadata and binary hashes are under
`.amp/in/artifacts/retained-borrowed-scan/{1,64}/results.json`.

| Measurement | Before median [min–max] | Candidate median [min–max] | Median time reduction |
|---|---:|---:|---:|
| Seal/index, one conversation | 480 ms [472–516] | 443 ms [433–453] | 7.7% |
| Seal/index, 64 interleaved conversations | 754 ms [745–858] | 727 ms [710–765] | 3.6% |
| Recovery, one conversation | 429 ms [413–467] | 394 ms [380–423] | 8.2% |
| Recovery, 64 conversations | 424 ms [404–480] | 399 ms [381–419] | 5.9% |

Only ordered sealing has non-overlapping sample ranges. These are storage timings,
not a new network throughput claim; the network benchmark was not rerun here.
A separate allocation-tracked regression verifies zero callback allocations when
index output capacity is preallocated, then overwrites the recovery input buffer
and verifies retained keys/cache data remain intact. All 470 normal and 530
simulation root tests passed, as did vet and `git diff --check`.

#### Pointer-based index comparators (2026-09-07)

Profiling `97a5869` with `perf record -e cpu-clock:u -F 999 --call-graph dwarf`
identified sorting as a larger avoidable CPU cost than index rereading. The
typed `slice.sort_by` Boolean adapter copies both records and may call the
comparator twice. The candidate instead uses the existing
`slice.sort_by_generic_cmp` API with in-place, three-way comparisons for both
conversation and dedup ordering. The smoothsort algorithm, key ordering and
equal-key semantics remain unchanged. It removes the now-unused Boolean helpers.
There is no change to I/O, checksums, strict validation or publication ordering.

Fresh uninstrumented measurements: ten alternating processes per version/layout,
one discarded warmup per version, 100,000 records with 256-byte content, CPU 0,
`-o:speed`, one test thread and allocation tracking disabled. Files are fresh per
process and warm from fixture writes/recovery; strict inspection uses direct I/O.
Power policy is uncontrolled. No tests, builds or profiling overlap timings.

| Seal/index workload | Before median [min–max] | Candidate median [min–max] | Median time reduction |
|---|---:|---:|---:|
| One conversation | 444 ms [428–455] | 402 ms [392–418] | 9.4% |
| 64 interleaved conversations | 726 ms [711–780] | 676 ms [645–693] | 6.9% |

Both layouts have non-overlapping measured ranges. Follow-up profiles used
three independent processes per version/layout, identical optimized debug builds,
999 Hz user-CPU sampling and 32 KiB DWARF stack dumps. Total attributed samples:

| Profile stage | Before → Candidate |
|---|---:|
| One conversation: dedup sorting | 245 → 168 |
| 64 conversations: conversation sorting | 236 → 182 |
| 64 conversations: dedup sorting | 220 → 177 |

These samples support reduced sorting CPU work, not wall-time percentages:
blocked I/O is absent, finite stack unwinding can omit callers, and three
instrumented runs are not the ten timing samples. Strict inspection remains a
major CPU cost; interleaved WAL rewriting also remains. Index read/validation
accounted for only 2–5 attributed samples per follow-up run. This is not a network
throughput measurement, and rotation still blocks its worker.

Raw timings and metadata are under
`.amp/in/artifacts/retained-pointer-sort/{1,64}/results.json`; filtered stacks and
profile counts are under `profile/`. The regression compares both comparators
pairwise against the previous Boolean ordering, including equal keys, unsigned
boundaries and every client-ID byte, then checks complete sorted-record equality.
All 471 normal and 531 simulation root tests passed, plus vet and diff checks.

#### Fresh cumulative ingestion, broadcast and rotation comparison (2026-09-07)

This compares the original [9b289cd](https://github.com/HeavyHorst/nrc/commit/9b289cd340d79723d4cd8796f382495ad212a4f3)
against [be34a88](https://github.com/HeavyHorst/nrc/commit/be34a8821c7e07e4c8e7c1d8ea652beb59de4649),
including all retained-ACK, queue-drain and sealing optimizations above. Both
servers were freshly built with `odin build . -o:speed`, without debug or
allocation instrumentation. The original ACKs/broadcasts after writing; the
current server waits for fsync. **This is a cumulative product comparison, not
equal-durability throughput.** Production batching and rotation settings were
not overridden.

There were ten alternating independent fresh-server samples per version/case,
240 samples total. One NRC worker ran on CPU 0 and the same updated Go client
on CPU 1, exposed SMT siblings in the same two-vCPU Xeon orb. Content was 256 B,
retention 24h, and all connections used one workspace/conversation. Power policy
was uncontrolled; no builds, tests or profiling overlapped timing. Per-process
CPU/resource reports are retained. These timing tests do not establish physical
power-loss durability or multi-worker/remote-network capacity.

**Short ingestion:** 200 ms warmup, one-second measured waves plus ACK drain,
no subscribers, and no rotations in any sample. Depth is outstanding requests
per publisher wave, not a continuously full sliding window. Rates are median
[min–max]; p99 is the median of per-run percentiles.

| Publishers × depth | Original messages/s [min–max] | Current messages/s [min–max] | Ratio | ACK p99 original → current |
|---|---:|---:|---:|---:|
| 64 × 1 | 75,237 [57,908–77,891] | 33,877 [31,786–35,302] | 0.45× | 2.33 → 4.71 ms |
| 64 × 4 | 45,825 [41,818–50,930] | 79,247 [60,291–90,941] | 1.73× | 12.21 → 11.24 ms |
| 128 × 1 | 60,632 [47,980–64,321] | 56,402 [49,475–59,344] | 0.93× | 6.54 → 7.41 ms |
| 128 × 4 | 27,859 [25,338–28,600] | 90,657 [76,877–96,263] | 3.25× | 25.56 → 19.86 ms |
| 512 × 1 | 24,949 [23,397–26,662] | 65,007 [39,493–71,557] | 2.61× | 32.42 → 23.39 ms |
| 512 × 4 | 9,240 [8,832–9,686] | 80,914 [61,021–86,135] | 8.76× | 261.50 → 59.89 ms |

**Actual broadcast subscribers:** 16 depth-one publishers targeted 1,000
messages/s, with 1/16/64/128 separate subscribers. Each subscribed through
`C_SubscribeConvsV2` and waited for correlated readiness, accepting the normal
presence updates around subscription. Warmup was 200 ms, measurement one second,
and both warmup and final broadcasts were drained. All 4,180,000 measured
deliveries were observed with matching identities and checked payload fields,
subject to the historical validator limitations below.

| Subscribers | Delivered/s original → current (median) | Receiver p99 original → current (median) | Peak outstanding deliveries original → current (median of peaks) |
|---|---:|---:|---:|
| 1 | 999 → 998 | 0.32 → 2.53 ms | 7 → 8.5 |
| 16 | 15,985 → 15,958 | 0.57 → 2.74 ms | 128 → 150.5 |
| 64 | 63,931 → 63,831 | 2.06 → 4.15 ms | 468 → 634.5 |
| 128 | 127,781 → 127,612 | 3.58 → 5.69 ms | 1,017 → 1,417 |

Both versions published all 1,000 scheduled messages in every fanout sample;
slightly lower rates reflect final drain time. There was no final backlog.
The largest observed aggregate backlog was 1,247 original / 1,722 current at
128 subscribers. This shows no delivery collapse at the tested rate, **not a
maximum fanout capacity**. Receiver p99 ranges, CPU usage and all sample values
are in the raw results; occasional low-subscriber latency outliers were retained.

**Sustained default-setting rotation:** one-second warmup plus 35 measured
seconds. Every sample sealed at least one segment. The fixed-rate case used
64 depth-one publishers targeting 8,000 messages/s and 16 subscribers; every
sample published all 280,000 scheduled messages and delivered all 4,480,000
expected broadcasts. Table entries are medians except rotation ranges.

| Workload/metric | Original | Current |
|---|---:|---:|
| 512 × 4, unrestricted ingestion | 7,972 msg/s [7,903–8,128] | 63,253 msg/s [59,102–68,903] |
| Unrestricted ACK p99 | 287.36 ms | 85.98 ms |
| Unrestricted sealed segments/run | 1 | 6–8 |
| Unrestricted probe p99 | 4.62 ms | 540.93 ms |
| Unrestricted maximum probe RTT (median of maxima) | 585.21 ms | 1,354.75 ms |
| 8,000/s with 16 subscribers: delivered/s | 127,995 | 127,986 |
| Fixed-rate receiver p99 | 8.44 ms | 11.33 ms |
| Fixed-rate sealed segments/run | 1 | 1 |
| Fixed-rate maximum probe RTT (median of maxima) | 615.94 ms | 292.61 ms |
| Fixed-rate maximum publisher pacing lateness (median of maxima) | 624.01 ms | 303.61 ms |
| Fixed-rate peak outstanding deliveries (median of peaks) | 2,016 | 2,048 |

Unrestricted sustained throughput improves **7.93×**, but the faster server
also rotates much more often. Its largest individual probe RTT was **1,542.14 ms**
(original: 634.37 ms), despite much better ACK p99. At matched offered work and
one rotation each, the maximum probe RTT roughly halves, but receiver p99 still
includes the added durability wait. Final delivery backlog was zero in every
run; fixed-rate aggregate backlog never exceeded 2,130 original / 2,432 current.

Measurement boundaries matter:

- Rate-targeted publishing has bounded outstanding requests and is ACK-backpressured,
  not a pure open-loop generator. It can pause then catch up; pacing lateness is
  reported so an 8,000/s average is not mistaken for uninterrupted delivery.
- Receiver latency runs from the publisher's write-start timestamp to receiver
  `ReadMessage` completion using the same-process wall clock. It includes tracker
  bookkeeping before the write and client/socket scheduling, but excludes waiting
  for a scheduled publish slot. Delivery throughput includes final broadcast drain.
- Backlog is published-but-not-yet-observed deliveries across subscribers, **not
  the server's send queue or TCP Send-Q**. The tracker retains identities under a
  10-million-delivery cap to reject missing, duplicate and unknown messages.
- A separate connection probes the same worker every 100 ms. Probe RTT is a
  responsiveness indicator including client/transport delays, not a direct timer
  of worker execution or proof that every spike is caused by rotation.
- Fixed-rate sustained client CPU was 32.81 s original / 16.85 s current by median
  over warmup, measurement and cleanup. The original client was close to its
  single-CPU budget; these are end-to-end results, not isolated server limits.

**Next target:** long-pause behavior, particularly synchronous sealing on the
worker. Background sealing is the more consequential candidate than another
index micro-optimization, but must preserve authoritative WAL/manifest ordering,
reads/dedup, bounded pending work and fsync-before-publication. This experiment
does not itself implement that architectural change.

Reproduce with `benchmark/retained-commit/run.py`, a directory containing freshly
built `before`, `after`, and `retained-message-bench` binaries, and each of
`--cumulative-ingestion`, `--fanout`, and `--sustained`, all with `--repetitions 10`.
Pass `--binaries DIR --output DIR --durability DESCRIPTION`. Build the client with
`go build -o DIR/retained-message-bench ./cmd/retained-message-bench` from `benchmark/`.
The optional `--duration` override is for pilots and disables the default rotation
assertion. Pilots (including corrected subscription-presence handling and the
rejected depth-four paced ACK measurement) are excluded from these results.

All **240/240 samples passed**, recording **37,134,425 measured ACKs** and
**93,780,000 measured subscriber deliveries**, with no detected missing/duplicate
deliveries and zero recorded final delivery backlog. Subsequent Oracle review
found two validator gaps: payload padding was checked but its exact length was
not, and the final 20 ms grace period could miss a trailing duplicate. These
historical runs therefore do not establish full-payload/exactly-once validation.
The current client checks exact content length and waits for an ordered,
correlated unsubscribe ACK from every subscriber before reporting success,
continuing to validate pages through that fence. The fence is outside timing.
Regression tests cover truncated/extended payloads and delayed trailing duplicates.
The runner now rejects rate-targeted samples with unissued scheduled messages;
all historical rate-targeted samples already meet this requirement.
`go test -race ./cmd/retained-message-bench`
passed; the runner's new modes were exercised in the full campaign. No server
implementation changed. Raw results, hashes, resource reports and probe timelines:
`.amp/in/artifacts/retained-cumulative/{ingestion,fanout,sustained}/results.json`;
combined medians/min/max and totals: `retained-cumulative/summary.json` under the
same artifact root.

#### Background retained segment construction (2026-09-08)

Retained sealing now queues immutable source-WAL construction on the existing
bounded compactor service. The job owns its directory and generation inputs;
it does not borrow the live store or its indexes. The worker keeps the source
WAL and active indexes available for reads/dedup, but pauses appends to that
store until the result is published. Source fsync, metadata loading, manifest
publication and new-active-WAL initialization remain owner-side. The manifest
format and fsync-before-ACK policy are unchanged. This is worker responsiveness
work, not concurrent ingestion into the next generation.

Oracle review identified a shutdown transition where a capacity-deferred tail
could initiate a new seal after cancellation, stranding a connection pin.
Cancellation now rejects every unstaged deferred tail while preserving staged
writes and any in-flight source freeze. The deterministic regression failed
before the fix and passed afterward; Oracle's follow-up found the blocker
resolved. Tests also exercise service-thread construction, bounded queue retry,
reader-delayed publication, stale results, build/manifest failure recovery and
history/dedup across completion.

The paired sustained comparison uses the same 35-second workloads and CPU
placement as above, now with **equal durability**: the pre-offload `be34a88`
production binary (equivalent server behavior to `a0f89ab`) versus background
sealing including the shutdown correction. Both use the stronger payload-length
and ordered-unsubscribe-fence validator. One initial campaign attempt rejected
a baseline rate-targeted sample for unfinished scheduled work. The paced client
now drains all scheduled slots even if the last ACK crosses the nominal phase
deadline, including catch-up in elapsed time and reporting pacing lateness.
It remains ACK-backpressured, not open-loop. A delayed-ACK regression covers this
boundary, and both versions use this same corrected client. Initial incomplete
results are excluded from the final comparison and retained separately.

Ten alternating independent samples per version/workload completed: 40 runs,
55,582,459 measured ACKs and 89,600,000 measured subscriber deliveries. Every
run rotated; every fixed-rate sample published its 280,000 scheduled messages
and validated all 4,480,000 deliveries through the final fence, with zero final
backlog. Server threads, including the compactor, inherited the same CPU-0
affinity; the client used CPU 1. No builds/tests overlapped timing. This did not
add a CPU to the server's budget.

| Metric (median of per-run values) | Before | Background construction |
|---|---:|---:|
| Saturated 512 × 4 throughput | 70,481 msg/s [68,058–76,448] | 70,701 msg/s [68,553–75,338] |
| Saturated ACK p99 | 68.58 ms | 77.44 ms |
| Saturated probe p99 | 625.92 ms | 89.86 ms |
| Saturated maximum probe RTT | 1,518.08 ms | 208.70 ms |
| Saturated rotations/run (range) | 4–9 | 5–8 |
| Fixed 8,000/s × 16 subscribers: delivery rate | 127,987/s | 127,988/s |
| Fixed-rate receiver p99 | 11.58 ms | 11.66 ms |
| Fixed-rate maximum probe RTT | 312.83 ms | 30.83 ms |
| Fixed-rate maximum pacing lateness | 328.63 ms | 354.42 ms |
| Fixed-rate peak delivery backlog | 2,040 | 2,032 |

The median maximum probe RTT is **86% lower under saturation** and **90% lower
at fixed rate**, with effectively unchanged throughput. The largest observed
saturated probe was 2,807.81 ms before / 246.66 ms after. This is not a universal
latency win: saturated ACK p99 increased about 13%, receiver p99 was essentially
unchanged, and publisher catch-up delay did not improve. Appends still wait for
their store's sealing; unrelated requests can now run during construction.
Probe RTT still includes transport/client scheduling and is not a direct timer
of worker execution. The fixed-rate source rotated once per sample except one
baseline sample that rotated twice; production hour/size thresholds were intact.

Verification: 473 normal tests, 535 simulation tests, Odin vet and Go benchmark
race tests passed. Two combined compiler-plus-simulation invocations were stopped
after prolonged stalls with suspected memory pressure; the exact final simulation binary subsequently
passed all 535 tests in 43.85 s when run without the compiler resident. A separate
non-fancy-output simulation build also passed (45.18 s). The interrupted runs are
not counted as passes; no test assertion failed in the completed full suites.

Raw results and resources:
`.amp/in/artifacts/retained-seal-comparison-final/results.json`; combined
medians/min/max and totals: `summary.json` in the same directory. The next step
for reducing retained-publisher pauses would require allowing ingestion into a
new active generation during sealing, with explicit recovery and read/dedup
support for the frozen source. That is not implemented by this change.

#### Concurrent retained rollover (2026-09-08)

The next experiment durably names frozen WAL A and new active WAL B before
admitting B writes. A seals in the background while B continues its normal
fsync-before-ACK batches. At most one frozen source is retained per store;
another full active generation waits if sealing/retirement has not finished.
Rollover still waits for current store readers, but publication of A's sealed
descriptor does not wait for B readers or change B's writer/fsync state. Old A
snapshots keep their own indexes and read descriptor alive until their borrows
end. Recovery completes a manifest-listed frozen source synchronously at startup.

**Compatibility:** manifest v3 records pending A+B state and reads existing v2
manifests. Startup upgrades manifests on write. Older binaries cannot read v3;
use a stopped-installation backup if rollback to an older binary is required.
WAL and index formats, 16-record batching, and the 1 ms / 128 KiB fsync policy
are unchanged.

Oracle review found a fatal-publication path that stranded staged B contexts.
The fix discards only never-written buffered bytes and releases pending/deferred
contexts while preserving written counters and in-flight fsync accounting.
Review also exposed a pre-existing process-restart durability hole: complete
but unsynced bytes found during recovery were treated as durable. Startup now
syncs the active WAL before trusting recovered durable counts or admitting
duplicate ACKs. New tests cover an ACKed B prefix plus a staged suffix through
publication/build failure, and process-only restart followed by duplicate ACK
and storage crash. Oracle's focused follow-up found both issues resolved.

An initial campaign stopped after 16 successful samples when the baseline exited
with a failed seal. A separate baseline diagnostic reproduced a failed job with
a 663,528,703-byte source containing 1,519,867 records: its required index size,
182,384,120 bytes, exceeds the 167,772,160-byte hard limit. Continuous reader
pins had bypassed the ordinary rotation checks. The candidate inherited that
admission bug, so the initial timing results are not the final candidate.

The final candidate makes rotation pending a strict new-record barrier even
while genuine readers delay rollover, releases completed negative-lookup pins
before queueing/dedup classification, and enforces a projected per-record index
ceiling of 1,398,100 records. Duplicate-first batches cannot bypass the checks.
Tests cover a real held history reader, finite-wave resumption, miss/follower
pin release and the exact mid-batch ceiling; Oracle confirmed the boundedness
and finite-workload pin-progress invariants. Endless fresh readers can still
delay rollover, and already oversized old WALs are not automatically repaired.

The paired sustained campaign compares freshly built `e6131cb` (background
sealing, appends paused, with the known reader-growth bug) against concurrent
rollover including all fixes above. This is a cumulative product comparison,
not an isolation of the overlap change alone: enforcing the original rotation
thresholds can increase sealing frequency relative to the buggy baseline.
Ten alternating fresh-server attempts per version/workload use the same 35-second
workloads, 256-byte payload, CPU placement, production thresholds and stronger
delivery validator as the previous section. No builds/tests overlap timing.
The runner's `--keep-going` option records failures without retrying/replacing
them, completes the remaining attempts, and still exits nonzero if any failed.
Summary rates describe successful samples only; failures are reported separately.
Its failure-path check injected two failed attempts, retained both and no success
samples, and verified nonzero exit.
Final results: `.amp/in/artifacts/retained-concurrent-rollover-final/results.json`.

All 40 final attempts succeeded (10 per version/workload). Medians below are
per-process statistics, not percentiles pooled across runs; maximum latency
rows are the median of each process's maximum.

| Workload / metric | Background seal, paused | Concurrent rollover + fixes |
| --- | ---: | ---: |
| 512 publishers × depth 4: messages/s | 65,779 (62,480–72,672) | 58,731 (57,475–61,123) |
| Saturated ACK p99 | 81.12 ms | 84.48 ms |
| Saturated independent probe p99 | 74.34 ms | 29.62 ms |
| Saturated independent probe maximum | 212.48 ms | 44.50 ms |
| 64 publishers × depth 1, 16 subscribers: messages/s | 7,999.43 | 7,999.32 |
| Paced publisher maximum scheduling lateness | 437.56 ms | 56.78 ms |
| Paced ACK p99 | 11.72 ms | 12.14 ms |
| Paced receiver p99 | 12.34 ms | 12.78 ms |

Peak throughput fell 10.7%; saturated probe maxima improved 4.8× and paced
publisher maximum lateness improved 7.7×. This is a pause reduction, not an
across-the-board latency or throughput improvement. Scheduling lateness measures
delay before issuing a scheduled publish; it is not ACK latency. Every paced
sample drained all 280,000 scheduled publishes and 4,480,000 receiver deliveries
with zero final backlog (89,600,000 verified deliveries across both versions).
Median completed sealed segments rose from 7 to 16 under saturation and from
1 to 2 at fixed rate, consistent with the threshold-enforcement confound above.
Detailed medians/min/max and delivery checks are in `summary.json` beside the raw
results. Both server variants had userspace threads pinned to CPU 0; the client
used CPU 1 (SMT siblings in this two-vCPU orb). Follow-up inspection found that
the kernel io_uring worker retained affinity 0–1 despite userspace pinning.
Thus sealing gained no additional userspace CPU budget, but fsync kernel work
was not confined to CPU 0. This applies to both compared variants.

After the production fixes, separate compile-then-execute root suites passed:
475 normal tests in 16.12 s and 544 simulation tests in 45.53 s, with
`-define:ODIN_TEST_LOG_LEVEL=error` and additionally `-define:NRC_SIMULATION=true`
for simulation. Vet passed. Oracle's focused follow-ups found no remaining
blockers for the reviewed failure cleanup, recovered durability, index-bound,
and finite-workload reader-pin progress invariants.

#### Safety-matched sealing comparison (2026-09-08)

The follow-up backports the candidate's admission barriers, index ceiling,
negative-lookup pin release, pending-rotation batch scheduling, buffered-write
failure reset, and recovered-WAL sync onto paused background sealing at
`e6131cb`. The concurrent binary is `d88ab0b`. The control retains v2/paused
publication; it does not acquire the concurrent architecture's frozen state.
Control patch and evidence are under
`.amp/in/artifacts/retained-paused-safe-comparison/`.

Both optimized variants use the same client and production settings as above.
The original campaign saved 37 successful attempts before an Amp executor
replacement terminated its unsupervised harness/client during attempt 38.
That infrastructure interruption is recorded in `interruption.json`, not called
a product failure. Two final paced attempts had not started. One supplementary
complete paired repetition ran under a supervised, non-restarting harness;
all four attempts succeeded. Its raw data is in the sibling
`retained-paused-safe-supplement/` directory. The paired analysis uses the first
nine complete repetitions plus that supplementary repetition, excluding the
one original unpaired completed saturation sample. All 41 successful samples
and the interrupted attempt remain available; no measurements were overwritten.

| Metric (median across 10 matched runs/version) | Paused + safety fixes | Concurrent + safety fixes |
| --- | ---: | ---: |
| 512 × depth 4 messages/s | 61,461 (57,084–65,946) | 61,123 (55,043–63,534) |
| Saturated ACK p99 | 364.54 ms | 81.25 ms |
| Saturated probe p99 | 46.67 ms | 27.72 ms |
| Saturated per-run probe maximum | 67.89 ms | 38.19 ms |
| 64 × depth 1, 16 subscribers, messages/s | 7,999.38 | 7,999.44 |
| Paced per-run maximum scheduling lateness | 385.57 ms | 69.74 ms |
| Paced ACK p99 | 11.49 ms | 11.93 ms |
| Paced receiver p99 | 11.95 ms | 12.51 ms |

The median paired saturated throughput change is -3.08% (range -5.93% to
+4.52%; nine of ten pairs slower), whereas the ratio of the two throughput
medians is -0.55%. Report both rather than treating those estimators as identical.
The original 10.7% product-comparison loss is not an isolated concurrency cost.
Every paced run delivered 4,480,000 messages with zero final backlog, totaling
89,600,000 deliveries. Kernel io-wq affinity remained 0–1 in both variants;
only userspace server threads were pinned to CPU 0, client to CPU 1.

Median completed segments still differ: 11 paused versus 16 concurrent.
Source inspection identifies another architectural difference: paused
`reset_active_message_indexes` initializes the next dedup map using the previous
map's length (clamped to 256–1,000,000), whereas concurrent rollover transfers
A's indexes and lazily initializes B with the default capacity 256. Repeated
map growth is a plausible contributor to arena consumption/rotation frequency;
this campaign does not isolate that cost from overlap or manifest changes.

The control passed 473 normal tests and 535 simulation tests, plus optimized
vet and `git diff --check`. Its first normal run failed to create a shard
recovery fixture in the fresh worktree; after the `data/` directory existed,
the complete rerun passed. Both logs are retained. No production files were
changed in the main checkout for this experiment.

#### Larger-orb CPU placement control (2026-09-08)

An independent 8-vCPU/16-GiB orb ran 40/40 successful saturation attempts,
10 alternating paused-safe/concurrent pairs per placement, with the same source
variants and 35-second workload. No failed measurement attempts or replacements.
Its Odin compiler was `dev-2026-09-nightly:a2fb372`, versus
`dev-2026-08-nightly:902106f` on the small orb; absolute rates are not pooled or
compared across machines. Within the larger orb, both variants use identical
compiler, client and settings.

The guest reports four cores with SMT pairs 0/1, 2/3, 4/5, 6/7. Shared placement
puts worker, main, sealing and kernel io-wq on CPU 0; split keeps worker on CPU 0
and moves main, sealing and io-wq to CPU 2. Client stays on CPU 4. These are
distinct guest-reported cores; KVM host physical placement and power policy
are unverified. The extra CPU serves all those roles, not sealing alone.
Dynamically created io-wq threads were pinned during untimed warmup; server
TID/mask equality at warmup/final endpoints and client affinity were verified
for every sample. This does not rule out transient threads between snapshots
or attribute unrelated kernel/IRQ work.

| Placement / metric | Paused-safe | Concurrent |
| --- | ---: | ---: |
| Shared messages/s median [min–max] | 47,277 [46,292–49,142] | 46,386 [38,839–48,165] |
| Shared ACK p99 median | 372.22 ms | 102.85 ms |
| Shared probe p99 median | 55.92 ms | 27.37 ms |
| Split messages/s median [min–max] | 53,646 [48,413–55,044] | 54,115 [51,897–56,247] |
| Split ACK p99 median | 385.28 ms | 81.63 ms |
| Split probe p99 median | 50.53 ms | 25.42 ms |

Concurrent versus paused-safe median paired throughput changes are -1.90%
shared (range -18.36% to +0.83%) and +2.80% split (-4.79% to +9.62%). Ratios
of throughput medians are -1.89% and +0.87%, respectively. These measurements
do not establish a stable 10% concurrency penalty or a guaranteed small
throughput gain with split CPUs. They support a smaller shared-CPU cost and
substantially better typical ACK/probe tails. A 448 ms shared-concurrent probe
maximum outlier is retained, not hidden by the median.

Split/shared throughput medians increase 13.47% paused and 16.66% concurrent.
All shared attempts preceded all split attempts: these placement comparisons
remain sensitive to between-block host drift. They are not interleaved causal
estimates of sealing CPU cost. The preserved-capacity versus default-256 map
difference above remains; median seals are 9/12 shared and 10/14.5 split for
paused/concurrent. The unsafe original baseline was not measured on this orb,
so the safety fixes' separate throughput cost cannot be calculated here.

Both optimized builds and `go test -race ./cmd/retained-message-bench` passed.
The transferred `summarize.py` was rerun in the parent and validated all 40
counts, durations, rotation, probes and recorded affinities. Two failed short
affinity setup pilots are preserved separately; they are not measured attempts.
The existing harness moved to a supervised cgroup between attempts after
32/40 completed, with no process restart, affinity change or interruption.

Evidence: `.amp/in/artifacts/retained-affinity-summary.json` and
`retained-affinity-report.md`; full reproducibility archive
`retained-affinity.tar.gz` in that directory includes source patch/bundle,
runner, client source, raw attempts, resource/affinity snapshots and logs.
Archive SHA256: `c83915e220808734739bd3f62492d9ca8e29dec7ec8ae2841aa26204b65fce15`.

#### Concurrent index pre-sizing experiment (2026-09-08)

This compares unchanged concurrent rollover at `d88ab0b` against the same code
with independent B indexes eagerly initialized from A's dedup/conversation
counts, using the existing paused-reset clamps (256–1,000,000 and 32–65,536).
Both variants retain identical v3/durability/safety behavior. The experiment is
rejected for shipping: it improves saturation throughput but worsens typical
tails and increases process RSS high-water. Its pre-sizing code and dedicated
regression were removed; the benchmark evidence is retained below.

The same larger orb ran 40/40 successful 35-second saturation attempts, ten
alternating binary pairs per shared/split placement. This time placements were
also interleaved within repetitions; placement order reversed every two
repetitions. The entire harness/client was supervised from the outset, with
zero restarts or replacement samples. CPU roles, warmup io-wq pinning, workload,
compiler and client match the larger-orb control above. All timing ran without
concurrent builds/profiling. Host physical topology/power remain unverified.

| Metric (per-run medians) | Shared unchanged → pre-sized | Split unchanged → pre-sized |
| --- | ---: | ---: |
| Messages/s | 46,046 → 49,625 | 54,813 → 58,284 |
| ACK p99 | 102.98 → 125.92 ms | 82.56 → 109.92 ms |
| Probe p99 | 25.01 → 50.22 ms | 27.57 → 45.17 ms |
| Per-run probe maximum | 36.72 → 80.86 ms | 40.80 → 61.41 ms |
| Completed seals | 12 → 9 | 15 → 10.5 |
| Process RSS high-water | 382.60 → 488.54 MiB | 401.51 → 504.16 MiB |

Median paired throughput improvement is +7.05% shared (+2.95% to +17.01%,
faster 10/10) and +6.63% split (-15.13% to +16.03%, faster 7/10). Ratios of
throughput medians are +7.77%/+6.33%. Median paired ACK p99 worsens
21.97%/35.78%; probe p99 worsens 115.83%/63.60%. Not every tail statistic gets
worse: the unchanged split run retains the largest individual probe outlier,
299.263 ms. Initial rollover pause was not separately instrumented; eager
allocation, larger segments, manifest work and scheduling costs are not isolated.

Paired process RSS high-water increases by 107.15 MiB shared and 102.48 MiB
split (medians). VmRSS/VmHWM/VmSize/VmPeak and smaps_rollup were read only at
endpoints, with no instrumentation in timed binaries. This is process-wide
memory, not isolated index memory, and the fixed-time pre-sized runs usually
process more records. Final RSS also depends on generation lifecycle.

A separate parent allocation-only probe used production index publication and
serialized 256-byte content, one conversation, test allocator tracking, no
disk/network or active payload cache. Default capacity 256 began at 26,248
arena bytes and crossed the 64 MiB soft rotation budget at 131,073 records /
78,625,680 bytes. Capacity 131,073 began at 23,072,384 bytes and crossed at
196,609 records / 105,385,104 bytes. Thus fewer growth steps allow 50% more
records before crossing, but front-load allocation and increase the growth-step
overshoot. These are arena observations, not RSS or throughput measurements.

Verification: 476 normal tests passed in 15.98 s, 545 simulation tests in
44.50 s; vet and diff checks passed. The new 600-A/600-B, 48-conversation test
checks empty independent pre-sized B indexes, unchanged capacity after B fills,
and intact frozen A contents. It passes the patch and fails unchanged `d88ab0b`.
Both optimized builds and client race checks passed in the larger orb. Parent
reran the transferred summarizer, validating all 40 counts/durations/rotation/
probes/recorded affinities. No production push or commit was made for this trial.

Evidence under `.amp/in/artifacts/`: `retained-presizing-report.md`,
`retained-presizing-summary.json`, validation logs/probe source in
`retained-presizing-validation/`, and full reproducibility archive
`retained-presizing.tar.gz` (SHA256
`48064eaab80ce7715d32ba7fdff87ec52668a0721333942ce08400d6520abd10`).

#### Shipping verification and simulation limits

The shipped candidate excludes pre-sizing. After integrating current main,
475 normal and 544 simulation tests passed with `-o:speed`,
`-define:HEGEL_REQUIRED=true` and `-define:ODIN_TEST_LOG_LEVEL=error` (plus
`-define:NRC_SIMULATION=true` for simulation), compiling and executing the two
root suites sequentially. Oracle's final review found no concrete release
blocker. This is regression evidence, not a proof of correctness.

The rollover boundary sweep exhausts completed storage effects on four fixed
paths: rollover, seal build, publication and startup recovery. At shipping its
recovery assertions checked high-water, generation/segment shape, record counts
and index validity. The subsequent test-only strengthening also checks an
independent ledger defined before persistence: distinct A/B payloads, message
IDs, authors, timestamps, content types and sequences. It pages forward and
backward one message at a time across sealed/active storage, verifies cursors,
page metadata and empty conversations, and exercises handler-level duplicate
ACKs and conflict responses for every retained record. History is checked again
after those requests, along with unchanged high-water, active record count and
active WAL size. These assertions run after every crash boundary and each
unfaulted control path, closing the exact-data coverage gap identified by review.
The focused sweep and full 544-test simulation suite passed (Hegel required for
the full suite). A temporary same-length persisted-payload mutation preserved
record counts but failed the new history and duplicate assertions; the mutation
was removed after this negative-control check.

Remaining high-value non-blocking follow-ups:

- Interleave A publication success/failure with B's outstanding fsync and later
  buffered suffix, including completion failure and crash.
- Cover mixed cached/uncached A+B readers, publication, retirement and cache
  accounting while newer readers remain live, including cancellation/error.

Generated campaigns are finite; the simulated compaction job executes as one
event, with internal storage effects crash-swept rather than arbitrarily
interleaved. This does not prove OS-thread race freedom, real kernel/filesystem
power-loss behavior, OOM handling, endless-reader liveness or production-scale
resource behavior. The real OS-thread channel test and server benchmarks add
evidence beyond simulation but do not eliminate those limitations.

### WAL, Retained-Message, Task, and Asset Write Size Sweep

1. Runner: `benchmark/wal-retained/run_benchmark.py`.
2. Run: `python3 benchmark/wal-retained/run_benchmark.py --output /tmp/wal-retained-results`.
3. Measures raw hash-chained WAL writes, production 16-record retained-message batches, task creates, and asset creates at 64 B, 256 B, 1 KiB, 4 KiB, and 16 KiB payloads. Both MiB/s and operations per second are reported.
4. Task and asset workloads include their production mutation builder, validation, shard transaction envelope, hash chain, and one transaction flush per operation. Their threshold fsync is serialized by this single-writer benchmark; the server submits it asynchronously.
5. Defaults to ten independent process runs per size and up to 128 MiB written per sample. Retained-message samples are capped at 100,000 records to remain within one active segment. The runner reports median plus IQR/min/max in `results.json` and the generated static portal.
6. Captures `perf` user-space CPU-clock profiles for the smallest and largest payloads. This software event is used because Amp orbs do not expose hardware PMU counters.
7. The timed interval includes production threshold-triggered fsyncs but excludes initialization and shutdown's final fsync. New files are used for each sample; the OS page cache is not dropped.

### WAL Hash-Chain Algorithm Sweep

1. Runner: `benchmark/hash-chain/run_benchmark.py`.
2. Run: `python3 benchmark/hash-chain/run_benchmark.py --output /tmp/hash-chain-results`.
3. The runner always builds the standalone Odin workload with `-o:speed`. It compares SHA-256, SHA-512/256, SHA3-256, BLAKE2s-256, BLAKE2b-256, and SM3 through their direct `core:crypto` APIs.
4. Every operation initializes a fresh context, copies the preceding 32-byte digest into an NRC-sized 52-byte WAL header, hashes the complete record, and produces a 32-byte digest. The final digest checksum is observed after timing.
5. Payloads are 64 B, 256 B, 1 KiB, 4 KiB, and 16 KiB. Each algorithm uses a fixed byte count sized for roughly 0.5–1 second per process; defaults are ten independent processes per algorithm and size. Results report median and IQR/min/max for both MiB/s and chains/s.
6. SHA-256 uses Odin's runtime-selected implementation, so results on SHA-NI hosts represent the accelerated path. The sweep measures chain computation only; it excludes WAL XXH64, serialization, and file I/O.

## Maximum Connection Scale Probe

1. File: `connection_scale_benchmark.odin`.
2. Run: `BENCH_MAX_CONNECTION_SCALE=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_max_connection_scale`.
3. Measures one worker populated to its hard connection limit: aggregate setup/index cost and RSS, repeated idle/watchdog/absent-user paths, and single-turn/full-drain queue behavior.
4. One-shot saturated-watchdog and queue timings are scale probes, not stable microbenchmark latency samples; repeat the whole process and report their spread.

## Protocol Microbenchmark

1. File: `protocol/protocol_test.odin`
2. Benchmark: `benchmark_parse_send_message_request`
3. Run: `BENCH_PROTOCOL_PARSE=1 odin test protocol/ -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=protocol.benchmark_parse_send_message_request`.
4. Measures: parser throughput for `C_SendMessage` request payload decoding.

## Retrieval Graph-Ranking Comparison

1. File: `graph_rank_benchmark.odin`.
2. Benchmark: `benchmark_graph_rank_retrieval_stage`.
3. Run: `BENCH_GRAPH_RANK=1 odin test . -o:speed -define:NRC_SIMULATION=true -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_graph_rank_retrieval_stage`.
4. Measures the former five-neighborhood traversal/serialization stage against the single server-side traversal, personalized PageRank, path extraction, and compact serialization stage on the same deterministic overlapping graph. It reports client request and server response WebSocket bytes separately.
5. `NRC_GRAPH_RANK_BENCH_ROUNDS` controls paired operations per sample (default 2,000). Alternate `NRC_GRAPH_RANK_BENCH_ORDER=baseline-first` and `proposed-first` across independent process runs. The baseline timing excludes the former Go path/PageRank post-processing, so it is a conservative lower bound for old-path latency.
6. Set `NRC_GRAPH_RANK_BENCH_PAYLOAD=/tmp/graph-rank.bin` on the Odin run to export its actual compact result, then run `NRC_GRAPH_RANK_BENCH_PAYLOAD=/tmp/graph-rank.bin go test -run '^$' -bench BenchmarkRetrieveGraphPostprocessing -benchmem` from `services/bots/nrc-ai`. The Go benchmark validates and consumes that response while measuring the removed Go path/PageRank work and proposed merge. Add each result to its corresponding Odin stage when comparing graph-stage compute; wire decoding, transport scheduling, and socket latency remain excluded.

## Slice Register Listing Benchmark

1. File: `slice_register_benchmark.odin`.
2. Benchmark: `benchmark_slice_register`.
3. Run: `BENCH_SLICE_REGISTER=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_slice_register`.
4. Measures one slice listing as `process_list_task_slices` builds it: a growing arena per round, `collect_task_slices` folding every slice's `MemberOf` edges, and `unassigned_task_count`. Serialization and the send path are excluded.
5. Tunables: `BENCH_SLICE_REGISTER_SLICES` (default 200), `_MEMBERS` (members per slice, default 20, capped by the task count), `_TASKS` (non-member tasks, default 2,000), `_ASSETS` (non-slice assets, default 2,000), `_ROUNDS` (default 500).
6. Measured on 2026-09-23 (Odin dev-2026-09, `ead60d6`, 200 rounds per run, median of three runs):

   | Slices | Member edges | Tasks | Other assets | Per listing |
   | --- | --- | --- | --- | --- |
   | 20 | 100 | 200 | 200 | 147 µs |
   | 200 | 2,000 | 2,000 | 2,000 | 1.01 ms |
   | 1,000 | 5,000 | 5,000 | 10,000 | 5.16 ms |

7. The listing deliberately keeps no slice index: the counters are folded from the membership edges, so they cannot drift from the members they describe. These numbers are the argument for that choice — a listing is a few milliseconds of a worker thread, and listings are bounded by user actions (a task mutation burst is debounced to one, opening a view asks once). An index would need invalidation on task create/update/delete, `MemberOf` edge create/delete for both task and asset members, slice asset create/update/delete and member asset changes, for a saving below the round trip that asked for the listing. Re-run this benchmark before adding one.

## WebSocket Primitive Benchmarks

### Frame Masking Throughput

1. File: `websocket/mask_test.odin`
2. Benchmark: `benchmarkMask`
3. Run: `BENCH_MASK=1 odin test websocket/ -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=websocket.benchmarkMask`
4. Measures: raw payload masking throughput (`mask`) over a 1MB buffer repeated many times.
5. Notes: benchmark is env-gated; without `BENCH_MASK=1` it does not execute work.

### Frame Header Write/Read Throughput

1. File: `websocket/frame_test.odin`
2. Benchmark: `benchmarkWriteReadHeader`
3. Run: `BENCH_FRAME_HEADER=1 odin test websocket/ -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=websocket.benchmarkWriteReadHeader`
4. Measures: header serialization throughput (`writeFrameHeader`) and parser throughput (`readFrameHeader`) across a fixed sample sized for an optimized run.
5. Notes: logs write and read frame rates separately.

### Frame Iterator Throughput

1. File: `websocket/frame_test.odin`.
2. Benchmarks: `benchmarkFrameIterator` and `benchmarkFrameIteratorWithSmallPayload`.
3. Run one at a time with `BENCH_FRAME_ITERATOR=1`, `-o:speed`, memory tracking disabled, one test thread, and an exact `ODIN_TEST_NAMES` filter.
4. Measures validated frame parsing for representative 8 KiB and 125-byte masked frames and reports operations and processed bytes.

## Go Load Benchmark Suite

1. Directory: `benchmark/`
2. Entry point binary: `benchmark/cmd/nrc-bench/main.go`
3. Build: `cd benchmark && go build -o nrc-bench ./cmd/nrc-bench`
4. Run: `./nrc-bench --server=ws://localhost:8080 --users=100 --duration=60s`
5. Measures: end-to-end WebSocket system behavior under load including connection latency, message RTT, throughput, and server stats.

### Shard Group-Commit Comparison

`benchmark/group-commit/run.py` runs the existing asset WebSocket benchmark against prebuilt
servers. It requires an Amp orb and uses a dedicated supervised service, stopped between samples.
Do not run builds, other benchmarks, or other CPU/disk-heavy work concurrently.

Build the original server from a separate checkout of the pre-group-commit revision and the
candidate binaries from the working tree. Root builds must be sequential:

```bash
mkdir -p /tmp/nrc-group-bench
go -C benchmark build -o /tmp/nrc-group-bench/asset-kv-bench ./cmd/asset-kv-bench
# BASELINE_CHECKOUT must contain the original kernel-accepted-ACK implementation.
odin build "$BASELINE_CHECKOUT" -o:speed -out:/tmp/nrc-group-bench/before
for spec in '5 131072' '1 131072' '2 131072' '5 32768' '5 524288'; do
    set -- $spec
    odin build . -o:speed -define:NRC_SHARD_COMMIT_WINDOW_MS="$1" \
        -define:NRC_SHARD_COMMIT_MAX_BYTES="$2" \
        -out:/tmp/nrc-group-bench/durable-$1-$2
done
python3 benchmark/group-commit/run.py --binaries /tmp/nrc-group-bench \
    --output /tmp/nrc-group-bench/results
```

- Ten independent server processes per variant, with rotated/reversed variant order. One active
  server at a time; fresh temporary storage for each variant/repetition. No page-cache dropping.
- One server worker on logical CPU 0 and the client on CPU 2 by default. Check `lscpu -e` first:
  these must be different physical cores. Override `--server-cpu` / `--client-cpu` as necessary.
- Sixteen authenticated clients, one workspace/shard, 1 KiB asset payloads and 128-byte previews.
  Creates only: 30,000 measured operations at pipeline depth 1, then 60,000 at depth 32. Each case
  has 512 untimed warmup creates. Change `--ops` to scale both counts for faster/slower machines.
- Timing covers client encoding, transport, server mutation handling, and correlated ACK delivery.
  Startup, warmup, and shutdown are excluded. The old ACK does **not** guarantee fsync; all durable
  variants do. Compare durable variants for tuning, not as equivalent semantics to the old server.
- Latencies are measured from the start of each client's request batch, not from each individual
  socket write. At depth 1 this is request/ACK latency; at depth 32 it includes batch preparation
  and sending earlier requests. The client sends the whole batch before reading its responses.
- `results.json` contains individual samples, median/min/max throughput, median per-run p50/p99,
  and shortest sample duration. Every warmup and sample must complete without protocol errors.
- This probes one hot shard and finite-window closed-loop clients. It does not establish storage
  device fsync latency, low-traffic many-shard CPU cost, broadcast capacity, or production limits.
  On a shared orb, treat results as directional and record host/power-policy uncertainty.

#### 2026-09-06 directional orb result

Baseline: [`d067c11`](https://github.com/HeavyHorst/nrc/commit/d067c11b37f9a091ecd1f891eea0daa002c7d91d),
compared with the uncommitted group-commit implementation. Odin
`dev-2026-09-nightly:a2fb372`, `-o:speed`; KVM Intel Xeon 2.60 GHz, two physical cores/four logical
CPUs; server CPU 0, client CPU 2; ext4 virtual disk. Host power policy and physical storage cache
behavior are not exposed by the orb. Workload and warmup are as above. All 120 measured samples
completed without protocol errors; the shortest was 453 ms.

Throughput is median **kops/s (min–max)** across ten repetitions. Latency is the median of the ten
per-run p99 values. The baseline's fast ACKs are **not durable ACKs**.

| Variant | Depth 1 kops/s | Depth 1 p99 ms | Depth 32 kops/s |
|---|---:|---:|---:|
| Before, kernel-accepted ACK | 64.53 (51.69–66.22) | 1.21 | 84.15 (77.85–88.20) |
| Durable 5 ms / 128 KiB | 2.65 (2.63–2.69) | 6.92 | 78.93 (69.89–85.04) |
| Durable 2 ms / 128 KiB | 5.38 (5.29–5.49) | 3.75 | 80.29 (75.54–86.79) |
| **Durable 1 ms / 128 KiB** | **8.30 (8.03–8.52)** | **2.74** | **84.32 (75.75–87.33)** |
| Durable 5 ms / 32 KiB | 2.65 (2.61–2.67) | 6.90 | 83.16 (72.36–87.51) |
| Durable 5 ms / 512 KiB | 2.65 (2.63–2.68) | 6.84 | 74.86 (67.55–77.88) |

Selected **1 ms / 128 KiB**: 3.13× the depth-1 throughput of 5 ms / 128 KiB, with lower ACK latency
and comparable pipelined throughput to the original server. The byte-threshold sweep does not
justify changing the existing write-buffer-sized threshold on this evidence. These are not
production capacity guarantees: particularly, shorter windows can mean more fsyncs across many
lightly loaded shards. Re-run on deployment storage before treating this as a hardware optimum.

#### Parallel-connection sweep

To distinguish connection concurrency from per-connection pipelining, reuse the same binaries:

```bash
python3 benchmark/group-commit/run.py --binaries /tmp/nrc-group-bench \
    --output /tmp/nrc-group-bench/connections --variants before durable-1-131072 \
    --connection-sweep --ops 50000
```

This runs 16, 64, 128, 256, and 512 connections with one outstanding request each, plus a control
with 16 connections and 32 outstanding requests each. Every case measures 50,000 creates after
512 untimed warmup creates. All writers still target one workspace/shard; 64 conversations avoid
hitting the per-conversation asset cap as the six cases accumulate data. Server storage is fresh
for each variant/repetition, and case order is rotated/reversed between repetitions (identically
for both variants). CPU placement, payloads, durability semantics, and ten-repetition reporting
are otherwise unchanged. This tests actively writing connections, not idle connection capacity.

2026-09-06 results on the same orb and prebuilt binaries: 120 measured samples, ten per
variant/case, zero protocol errors. All samples lasted at least 581 ms. Throughput below is median
**kops/s (min–max)**; p99 is the median of per-run values for the durable variant.

| Connections × pipeline depth | Before kops/s | Durable 1 ms / 128 KiB kops/s | Durable p99 ms |
|---|---:|---:|---:|
| 16 × 1 | 49.85 (45.45–61.65) | 7.91 (7.64–8.08) | 2.88 |
| 64 × 1 | 53.43 (46.00–60.76) | 28.72 (28.04–29.39) | 6.33 |
| 128 × 1 | 54.19 (47.59–60.91) | 48.55 (41.80–54.46) | 8.26 |
| 256 × 1 | 52.40 (45.71–58.84) | 50.95 (42.48–56.30) | 14.36 |
| 512 × 1 | 47.75 (44.75–52.08) | 50.31 (42.95–54.59) | 24.33 |
| 16 × 32, control | 79.86 (69.77–86.07) | 76.62 (64.65–84.43) | 14.73 |

More actively writing connections increased durable non-pipelined throughput by 6.44× from 16
to 256 connections. At 256 connections the durable median was 97% of the old median, within the
observed spread. Increasing to 512 did not improve throughput and increased latency. Equal
outstanding-request counts are not interchangeable: 16 pipelined connections outperformed 512
non-pipelined connections. This setup does not isolate whether the server, single-core load
generator, or transport is responsible for that difference. The sweep uses more conversations
and varying accumulated state than the window sweep; compare variants within this sweep, not
absolute rates between the two experiments. The initial per-room-cap-aborted run is excluded.

#### Atomic transactions versus individual pipelined updates

`benchmark/cmd/asset-kv-bench/transaction_benchmark_test.go` is an opt-in real-server benchmark;
normal Go tests skip it. Build once, then use the supervised runner:

```bash
go -C benchmark test -c -o /tmp/nrc-group-bench/transaction-bench ./cmd/asset-kv-bench
bash benchmark/group-commit/transactions.sh /tmp/nrc-group-bench \
    /tmp/nrc-group-bench/transactions 10
```

The runner expects the optimized `durable-1-131072` binary built above. It pins the one-worker
server to CPU 0 and the single authenticated client connection to CPU 2, on distinct physical
cores. Every sample has a fresh server and data directory; case order rotates/reverses across
ten repetitions. Do not run other heavy work concurrently.

- Each case preloads one conversation with either 32 or 4,096 Note assets, then repeatedly updates
  the same 32 hot assets. The larger fixture adds unchanged assets, isolating sensitivity to
  conversation population without timed dataset growth. Payloads are 1 KiB plus 128-byte previews.
- Compare 32 individual requests in flight against one 32-operation transaction; also compare
  128 individual requests against four pipelined 32-operation transactions. Atomic and independent
  requests intentionally have different semantics and response sizes.
- Requests alternate between two pre-encoded update patterns. Encoding/preload are untimed;
  each case warms 16 pipeline waves and measures 65,536 mutations. Timed work includes socket
  writes, server execution/WAL/fsync, response reads/decoding, and correlated result validation.
- Report **mutations per second**, not transactions per second. Wave latency runs from first send
  through the final response in that wave; it is not per-mutation latency. Individual responses
  contain full updated assets, whereas transaction responses contain compact per-operation results.
- Every ACK must have the expected correlation, opcode, committed status, operation types, and
  entity IDs. After timing, read back every hot asset's exact preview/payload and one untouched
  cold asset. Any failure aborts the run. The `sample-*.json` files contain the raw successful data.
- To run one case manually, set `NRC_TRANSACTION_BENCH=1`, `NRC_TRANSACTION_BENCH_CASE=0..7`,
  and `NRC_TRANSACTION_BENCH_OUTPUT=/path/to/result.json`, then invoke the compiled test with
  `-test.run '^TestTransactionThroughput$'`. Cases 0–3 use 32 assets; 4–7 use 4,096. Within each
  population the shapes are individual×32, transaction×1, individual×128, transaction×4.

2026-09-06 **before delta-publication** results, same orb/toolchain and durable 1 ms / 128 KiB server as above. All 80 independent
samples passed ACK and final-state verification: 5,242,880 measured mutations. The shortest
sample was 659 ms. Throughput is median **k mutations/s (min–max)** across ten repetitions.

| Requests outstanding | 32 Note assets | 4,096 Note assets |
|---|---:|---:|
| 32 individual updates | 15.06 (14.15–15.42) | 15.05 (14.25–15.80) |
| One 32-operation transaction | 15.66 (15.23–15.85) | 6.29 (6.04–6.57) |
| 128 individual updates | 46.07 (43.11–47.62) | 45.72 (41.77–47.17) |
| Four pipelined 32-operation transactions | 91.31 (82.58–99.49) | 9.54 (9.28–9.77) |

At equal 128-mutation concurrency, pipelined transactions were 1.98× faster for the small
conversation, but 4.79× slower for the populated conversation. Individual-update throughput was
almost unchanged by population. This is consistent with the transaction path's conversation-wide
container/index rebuilding, although this experiment does not profile the individual preparation
stages. Compact transaction responses also contribute to the small-conversation advantage.
These are single-connection Note-update results, not a claim about all transaction shapes or
production capacity. This baseline used full conversation-container/index rebuilding.

After replacing transaction publication with changed-entity updates, removing the workspace-wide
blocker scan, and indexing ownership cascades, the same unmodified driver was rerun against the
optimized candidate. Durability remained ACK-after-fsync, **1 ms / 128 KiB**. Each case again used ten
fresh server processes, the same CPU placement, rotated case order, and 65,536 verified mutations.
All 80 samples passed (5,242,880 measured mutations); the shortest sample was 763 ms.

| Requests outstanding, after delta publication | 32 Note assets | 4,096 Note assets |
|---|---:|---:|
| 32 individual updates | 14.30 (13.69–14.98) | 14.43 (13.28–14.77) |
| One 32-operation transaction | 14.61 (13.71–15.65) | 14.74 (13.70–15.25) |
| 128 individual updates | 41.46 (38.64–45.43) | 42.84 (39.48–46.32) |
| Four pipelined 32-operation transactions | 82.11 (75.84–85.85) | 77.63 (70.84–85.33) |

Units remain median k mutations/s (min–max). The populated four-transaction case improved **8.13×**
over its earlier 9.54k baseline. Increasing population 128× now costs about **5.5%**, rather than
89.5%, in that shape. One outstanding transaction is effectively flat across populations. At 4,096
Notes, four pipelined transactions deliver **1.81×** the mutation rate of 128 individual updates.

The campaigns ran sequentially, not as interleaved A/B pairs; individual-update controls also slowed,
so small cross-campaign differences must not be attributed solely to code. These fixtures contain
1 KiB payloads and plain previews, not multi-GiB resident state or populated project/tag buckets.
Secondary-index semantics are covered by unit and simulation tests, not by this throughput fixture.
The fix removes full-state work, not tree-depth/cache effects or occasional amortized map growth.

#### Small-value KV-shaped updates

The transaction driver accepts `NRC_TRANSACTION_BENCH_PAYLOAD_BYTES` and
`NRC_TRANSACTION_BENCH_PREVIEW_BYTES` (defaults 1024 and 128). The runner accepts a space-separated
`NRC_TRANSACTION_BENCH_CASES` filter. For example, with prebuilt optimized server/client binaries:

```bash
NRC_TRANSACTION_BENCH_CASES='6 7' \
NRC_TRANSACTION_BENCH_PAYLOAD_BYTES=64 \
NRC_TRANSACTION_BENCH_PREVIEW_BYTES=0 \
bash benchmark/group-commit/transactions.sh /tmp/nrc-group-bench/kv-binaries \
    /tmp/nrc-group-bench/kv-64 10
```

2026-09-06: current delta-publication build including the Oracle interning-error corrections,
ACK-after-fsync at 1 ms / 128 KiB, same orb/CPU placement. One connection, one worker/shard,
4,096 resident Notes and 32 hot IDs. Both shapes have 128 mutations outstanding per wave. Values
are uncompressed, previews empty; this is the NRC asset protocol with its normal entity/index
metadata, not a dedicated bare-key/value protocol. Ten fresh processes per size/shape, 16 warmup
waves and 65,536 measured mutations each. All 60 samples passed ACK and final-state checks:
3,932,160 mutations, shortest sample 679 ms.

| Value size | 128 individual writes: k updates/s (min–max) | Value MB/s | 4 × 32-operation transactions: k updates/s (min–max) | Value MB/s |
|---|---:|---:|---:|---:|
| 64 B | 61.25 (47.14–64.87) | 3.92 | 64.59 (60.76–66.18) | 4.13 |
| 256 B | 59.22 (45.88–63.52) | 15.16 | 64.28 (60.90–66.69) | 16.46 |
| 1,024 B | 45.78 (41.56–47.62) | 46.88 | 93.03 (89.35–96.46) | 95.26 |

Rates are medians; MB/s means decimal value bytes/s divided by 1,000,000, excluding keys, protocol
and WAL overhead. For reference, the earlier 1 KiB/128-byte-preview transaction results correspond
to 84.08 MB/s (32 Notes) and 79.49 MB/s (4,096 Notes), counting payload only; including previews,
94.59 and 89.43 MB/s respectively.

Smaller values do not automatically raise transaction ops/s at this fixed concurrency. The small
waves do not reach the 128 KiB early-commit threshold, whereas 128 × 1 KiB values plus metadata can;
the small-value wave medians are around 2 ms versus around 1.4 ms for 1 KiB transactions. This is
consistent with timer/fsync waiting, not proof of a server CPU-capacity ceiling. Larger pipelines or
more connections require a separate measurement. Payload-size campaigns ran sequentially on shared
hardware, so small differences between sizes are not precise regression measurements.

#### Small-value concurrency sweep

Set `NRC_TRANSACTION_BENCH_INFLIGHT` to 128, 256, 512, or 1024 to override mutations per
wave. In this mode the driver measures **512 waves at every depth**, keeping p99 sample counts
constant and preventing deeper pipelines from producing excessively short samples. The default
without this variable remains 65,536 mutations. For example, 1,024 mutations in 32 transactions:

```bash
NRC_TRANSACTION_BENCH_CASES=7 NRC_TRANSACTION_BENCH_PAYLOAD_BYTES=64 \
NRC_TRANSACTION_BENCH_PREVIEW_BYTES=0 NRC_TRANSACTION_BENCH_INFLIGHT=1024 \
bash benchmark/group-commit/transactions.sh /tmp/nrc-group-bench/concurrency-binaries \
    /tmp/nrc-group-bench/concurrency-64-1024 10
```

Use case 6 for individual writes. A failed run exits nonzero and records client/server logs; it must
not be included as a successful throughput sample. Run shapes separately so an overloaded individual
case does not prevent measuring the transaction case.

2026-09-06 results: same server binary as the small-value sweep, default **1 ms / 128 KiB** durable
ACKs and **512-frame send backlog cap** unchanged. One connection/worker/shard, 4,096 resident Notes,
32 hot IDs, empty previews. Ten fresh-server attempts per size/depth/shape; size/depth variants
rotated/reversed across repetitions, individual then transaction shape. Each sample had 16 untimed
warmup waves. Of 160 attempts, **140 completed all checks** (28,835,840 measured mutations) and
**20 overloaded**. The shortest successful sample lasted 993 ms.

Throughput is median **k updates/s (min–max)**; each transaction contains 32 mutations:

| In-flight mutations | 64 B individual | 64 B transactions | 256 B individual | 256 B transactions |
|---|---:|---:|---:|---:|
| 128 | 61.29 (46.03–65.13) | 64.24 (62.14–65.97) | 61.07 (46.14–63.95) | 63.45 (62.78–64.70) |
| 256 | 84.82 (69.26–86.18) | 127.47 (122.56–130.60) | 80.51 (70.22–83.84) | 125.86 (117.57–127.00) |
| 512 | 119.62 (111.86–128.22) | 251.43 (243.09–259.11) | 106.77 (103.65–121.68) | 185.97 (182.88–190.46) |
| 1,024 | Overload: 0/10 completed | 325.50 (317.99–332.44) | Overload: 0/10 completed | 280.80 (233.91–290.31) |

Wave-completion **p50 / p99 milliseconds**, median of each successful run's percentiles; these are
not per-request latencies:

| In-flight mutations | 64 B individual | 64 B transactions | 256 B individual | 256 B transactions |
|---|---:|---:|---:|---:|
| 128 | 2.00 / 2.99 | 1.99 / 2.16 | 2.06 / 3.08 | 2.01 / 2.19 |
| 256 | 3.02 / 3.59 | 1.99 / 2.24 | 3.10 / 4.17 | 2.03 / 2.24 |
| 512 | 4.19 / 5.89 | 2.03 / 2.30 | 4.35 / 6.36 | 2.75 / 3.07 |
| 1,024 | — | 3.14 / 3.41 | — | 3.60 / 4.40 |

Batched throughput rose **5.07×** for 64 B and **4.43×** for 256 B from 128 to 1,024 in flight,
reaching 20.83 and 71.89 decimal value MB/s respectively. The 64 B case nearly quadrupled through
512 in flight without materially increasing wave latency; 1,024 bought further throughput with
higher latency. These are the highest tested depths, not established capacity maxima.

Every individual-write attempt at 1,024 ended with WebSocket **1013, Server too busy**. Captured
server logs identify the 512-frame send queue filling. A 1,024-mutation transactional wave produces
only 32 result frames, so it avoids this per-connection backlog limit. No queue limits were raised
and no partial/failing runs were averaged into throughput. More connections were not tested here;
these results measure deeper pipelines on a single connection, including client decoding overhead.

### Paired Connection-Rate Benchmark

1. Generator: `benchmark/cmd/connection-rate-bench/main.go`.
2. A/B runner: `benchmark/run_connection_rate_comparison.sh`.
3. Measures: completed TCP connect, authenticated WebSocket upgrade, `ServerReady`, WebSocket close,
   and TCP close lifecycles per second with p50/p95/p99 setup latency.
4. Comparison: fixed CPU masks, inactive-server suspension, balanced A→B/B→A order, raw JSON for
   every run, and geometric mean of per-pair throughput ratios.
5. Dedicated-hardware runbook: [`CONNECTION_RATE_BENCHMARK.md`](CONNECTION_RATE_BENCHMARK.md).

### Fanout Worker Scaling

1. Runbook: [`FANOUT_SCALING_BENCHMARK.md`](FANOUT_SCALING_BENCHMARK.md).
2. Measures: 1→2→4 worker scaling at fixed offered load and at independently confirmed capacity
   boundaries, with fanout deliveries, ACK/fanout latency, CPU placement, and load-generator headroom.
3. uWebSockets topology: one independent single-loop process and port per workspace; using
   `UWS_THREAD_COUNT>1` with one listen port is invalid for fanout because pub/sub state is loop-local.
4. Intended execution: controlled dedicated hardware or a dedicated-core runner. Shared CI/orbs are
   useful only for functional smoke tests, not performance regression thresholds.

## Comparable External Baselines

### Socket.IO Baseline

1. Directory: `benchmark/socketjs/`
2. Run: `cd benchmark/socketjs && npm install && node benchmark.js --startServer --auth --users=1000 --workspaces=1 --duration=60`
3. Notes: Baseline for directional comparison; event-driven Socket.IO semantics differ from NRC protocol framing.

### uWebSockets (C++) Baseline

1. Directory: `benchmark/uwebsockets/`
2. Build server: `cd benchmark/uwebsockets && ./build-server.sh`
3. Go load generator entry point: `benchmark/cmd/uwebsockets-bench/main.go`
4. Run managed: `cd benchmark && go run ./cmd/uwebsockets-bench --start-server --auth --users=1000 --workspaces=1 --duration=60s`
5. Notes: Uses upstream `uNetworking/uWebSockets` C++ library with Go-based load generation for fairer comparison with `nrc-bench`.

### Redis Asset KV Baseline

1. Go comparison tool: `benchmark/cmd/asset-kv-bench/main.go`
2. Build: `cd benchmark && go build -o asset-kv-bench ./cmd/asset-kv-bench`
3. Run NRC only: `./asset-kv-bench --backend=nrc --start-server --auth --profile=mixed --ops=10000 --assets=1000 --payload-size=4096`
4. Run Redis only: `./asset-kv-bench --backend=redis --redis-addr=127.0.0.1:6379 --profile=mixed --ops=10000 --assets=1000 --payload-size=4096`
5. Run both: `./asset-kv-bench --backend=both --start-server --auth --redis-addr=127.0.0.1:6379 --output=asset-kv-results.json`
6. Run pipelined: `./asset-kv-bench --backend=both --start-server --auth --redis-addr=127.0.0.1:6379 --pipeline-depth=16`
7. Measures: asset-shaped create/get/update/delete latency and throughput using equivalent payload bytes. NRC is measured end-to-end through the WebSocket asset protocol and WAL path; Redis is measured through RESP `SET`/`GET`/`DEL` using binary values encoded with NRC asset metadata.
8. Notes: `--pipeline-depth=1` is the default. Values above 1 pipeline both backends: NRC sends multiple correlated WebSocket requests before reading responses, while Redis writes multiple RESP commands before reading replies.
9. Notes: Redis persistence mode is external to the tool. Record whether Redis ran with persistence disabled, AOF `everysec`, AOF `always`, TCP, or unix socket before comparing results.
10. Reproducible Valkey/Redis AOF pipeline runbook: see `benchmark/README.md`, section “Reproducible Asset KV / Valkey AOF Pipeline Runs”. It includes CPU pinning, Redis `io-threads`, AOF `appendfsync everysec`, NRC worker-thread affinity, and the 100k-op pipelined commands used for 4- and 8-workspace comparisons.

### Redis Durable Write / Atomic Batch Comparison

`benchmark/cmd/asset-kv-bench/redis_comparison_test.go` and
`benchmark/group-commit/redis_comparison.py` compare the current durable NRC write
path against Redis 8.10.1 core, using **raw Redis string values**, not the older
asset-metadata encoding described above. This is a logical-value comparison, not
identical protocol work: NRC maintains Note metadata/indexes and individual updates
return the full asset; Redis SET/MSET replies are compact `+OK` responses.

Reproduce in an orb (do not install/build while timing):

```bash
NRC_SETUP_REDIS=1 .agents/setup
mkdir -p /tmp/nrc-redis-compare
odin build . -o:speed -out:/tmp/nrc-redis-compare/server
go -C benchmark test -c ./cmd/asset-kv-bench -o /tmp/nrc-redis-compare/client
amp orb service start redis-comparison --command \
  "python3 $PWD/benchmark/group-commit/redis_comparison.py /tmp/nrc-redis-compare/server $HOME/.local/toolchains/redis-8.10.1/bin/redis-server /tmp/nrc-redis-compare/client /tmp/nrc-redis-compare/results"
amp orb service logs redis-comparison
```

After all 360 samples finish, run `amp orb service stop redis-comparison`.
Use a new output directory for a new campaign; the runner refuses to overwrite
an existing directory, including on an automatic supervisor restart.
The runner pins the entire server
to CPU 0 and client to CPU 2; verify these are different physical cores on the
target machine. There is one connection, one NRC workspace/worker, Redis
`io-threads 1`, and a fresh server/data directory/client process per sample.
Redis has AOF enabled, snapshots and automatic AOF rewriting disabled, and
`no-appendfsync-on-rewrite no`. It tests `appendfsync always` (durable before
reply) and `everysec` (**weaker ACK-before-durable baseline**) separately.
Redis `always` can share one fsync across multiple commands processed in an
event-loop cycle; it is not necessarily one fsync per pipelined SET.

The 36 configurations cover 64 B, 1 KiB, and 16 KiB uncompressed values, with:

- One update and one outstanding request.
- 128 individually pipelined updates.
- One atomic batch: NRC transaction versus Redis MSET (32 updates for 64 B/1 KiB;
  4 updates for 16 KiB). A 32 × 16 KiB NRC batch was rejected during pilot testing
  by the production 128 KiB WebSocket-frame cap; the limit is not raised here.
- Pipelined atomic batches totaling 128 outstanding updates (4 × 32 or 32 × 4).

Preload 4,096 entries with empty previews, then repeatedly update 32 hot keys,
alternating two deterministic binary values on every write to each key. Preload,
request encoding, 16 warmup waves, and final full-value checks of all hot keys and
one cold key are outside timing. Every measured reply is checked. NRC batches
check committed status and every returned entity ID. Each configuration has a
256-wave calibration pilot excluded from results, then ten independent measured
samples in rotated/reversed order, calibrated toward one second with a minimum
of 100 waves. Report updates/s (not batch requests/s), decimal payload MB/s,
median and spread across samples. Latencies are **whole-wave completion** p50/p99,
not individual pipelined-request latency. Raw per-sample JSON includes the actual
duration and serialized application request bytes (excluding WebSocket framing).

This is a short, warm hot-set overwrite comparison, not a multi-connection scaling,
large-working-set, checkpoint/rewrite, sustained disk-saturation, or crash-recovery
benchmark. Host storage caches and power-loss guarantees are unknown in the orb.

#### Measured 2026-09-06

NRC [9b289cd](https://github.com/HeavyHorst/nrc/commit/9b289cd340d79723d4cd8796f382495ad212a4f3),
default **1 ms / 128 KiB** group commit; Odin dev-2026-09-nightly:a2fb372 with
`-o:speed`; Go 1.26.8. Redis 8.10.1 core built with GCC 12.2.0, `-O3 -flto=auto`,
jemalloc 5.3.0, no TLS. Linux 6.1.158+, ext4, Xeon 2.60 GHz KVM, two physical/four
logical CPUs, about 8 GiB RAM; CPU placement as above, power policy unknown.
All **360 measured samples passed** reply/final-state checks. Measured intervals
ranged from 0.774 to 2.939 seconds; calibration pilots are excluded.

**Updates/s: median (minimum–maximum across ten runs).** Redis `everysec` is not
durability-equivalent to the first two columns.

| Value | Shape | NRC durable | Redis always | Redis everysec (weaker) |
|---|---|---:|---:|---:|
| 64 B | Single | 563 (527–576) | 1,702 (1,437–1,772) | 8,946 (8,164–11,247) |
| 64 B | Pipeline 128 | 54,766 (48,073–64,438) | 136,812 (129,977–151,156) | 508,784 (489,655–517,718) |
| 64 B | Batch 32 | 16,747 (16,133–17,086) | 47,022 (41,394–51,410) | 278,971 (252,490–289,759) |
| 64 B | Batch 32 × pipeline 4 | 64,990 (62,494–66,574) | 169,527 (154,415–178,148) | 846,715 (786,209–888,748) |
| 1 KiB | Single | 546 (527–563) | 1,575 (1,492–1,628) | 9,133 (7,928–10,923) |
| 1 KiB | Pipeline 128 | 47,273 (43,353–48,243) | 28,365 (25,413–31,975) | 258,824 (242,714–283,814) |
| 1 KiB | Batch 32 | 15,883 (15,087–16,362) | 39,432 (38,353–43,988) | 221,405 (192,187–245,595) |
| 1 KiB | Batch 32 × pipeline 4 | 93,993 (91,612–97,261) | 46,712 (44,999–49,453) | 380,411 (256,354–410,634) |
| 16 KiB | Single | 511 (503–519) | 1,357 (1,263–1,495) | 7,834 (7,721–8,131) |
| 16 KiB | Pipeline 128 | 16,004 (13,699–17,029) | 4,526 (4,355–4,856) | 36,524 (33,565–44,482) |
| 16 KiB | Batch 4 | 1,933 (1,871–1,993) | 4,993 (4,523–5,565) | 21,721 (19,970–23,609) |
| 16 KiB | Batch 4 × pipeline 32 | 17,600 (16,262–18,190) | 6,127 (5,557–6,410) | 39,884 (36,574–44,361) |

For pipelined batches, NRC / Redis always / Redis everysec payload throughput was
**4.16 / 10.85 / 54.19 MB/s** at 64 B, **96.25 / 47.83 / 389.54 MB/s** at 1 KiB,
and **288.36 / 100.39 / 653.46 MB/s** at 16 KiB (decimal MB, logical values only).
The corresponding median-of-run wave p99 latencies were **2.180 / 0.956 / 0.216 ms**,
**1.599 / 3.457 / 0.657 ms**, and **8.472 / 24.830 / 19.941 ms** respectively.

Redis wins all 64 B and non-pipelined cases here. NRC beats Redis always in the
1 KiB and 16 KiB pipelined cases; at 1 KiB, combining atomic batches with pipelining
nearly doubles NRC throughput versus individually pipelined writes. These results
do not establish a general Redis/NRC ranking or identify the bottleneck without
profiling; especially do not treat the weaker everysec results as durable ACK rates.

#### Byte-threshold comparison at a fixed 1 ms

The reusable runner accepts `--variant LABEL=BINARY` to compare NRC builds
instead of Redis. Compare 64, 128, and 256 KiB without the removed experimental
tracing, extra callback drain, or record-count trigger. ACK-after-fsync and the
1 ms time window are identical across builds.

```bash
mkdir -p /tmp/nrc-byte-threshold
for kib in 64 128 256; do
  odin build . -o:speed -out:/tmp/nrc-byte-threshold/kib$kib -define:NRC_SHARD_COMMIT_MAX_BYTES=$((kib * 1024))
done
go -C benchmark test -c ./cmd/asset-kv-bench -o /tmp/nrc-byte-threshold/client
amp orb service start byte-threshold --command \
  "python3 $PWD/benchmark/group-commit/redis_comparison.py /tmp/nrc-byte-threshold/kib128 unused /tmp/nrc-byte-threshold/client /tmp/nrc-byte-threshold/results --variant kib64=/tmp/nrc-byte-threshold/kib64 --variant kib128=/tmp/nrc-byte-threshold/kib128 --variant kib256=/tmp/nrc-byte-threshold/kib256"
```

This is the fixed-wave workload described above: 64 B, 1 KiB, and 16 KiB values;
single writes, 128-request pipelines, atomic batches, and pipelined atomic batches.
Batch width is 32 updates at 64 B/1 KiB and four at 16 KiB; pipelined batches have
128 logical updates outstanding. There is one connection/worker, 4,096 resident
Notes, and 32 hot keys. Use 36 excluded pilots and ten fresh measured processes
per case (360 samples), retaining the same CPU pinning, approximately one-second
calibration, warmup, rotated order, and ACK/final-state checks. Stop the supervised
service on completion. No compilation or other heavy checks run during timing.

The byte threshold is an early-fsync trigger, **not a hard maximum group size**.
It is checked at worker scheduling boundaries; callback waves or writes arriving
during a preceding fsync can produce larger groups. Fsync counts are not traced
in this comparison. The separate pending-write backpressure limit is unchanged.

Measured on **2026-09-07**, with the same hardware/toolchains as the Redis campaign
and the production server restored to its pre-experiment implementation. All
**360/360 measured samples passed** ACK and final-state checks. Durations were
0.763–1.384 seconds. Median logical updates/s:

| Value | Shape | 64 KiB | 128 KiB | 256 KiB |
|---|---|---:|---:|---:|
| 64 B | Single | 559 | 559 | 564 |
| 64 B | Pipeline 128 | 61,473 | 60,360 | 62,454 |
| 64 B | Batch 32 | 16,861 | 16,752 | 16,752 |
| 64 B | Batch 32 × pipeline 4 | 65,042 | 64,766 | 65,746 |
| 1 KiB | Single | 552 | 558 | 559 |
| 1 KiB | Pipeline 128 | 62,675 | 43,880 | 48,586 |
| 1 KiB | Batch 32 | 16,009 | 15,935 | 15,998 |
| 1 KiB | Batch 32 × pipeline 4 | 72,788 | 94,651 | 61,648 |
| 16 KiB | Single | 512 | 511 | 516 |
| 16 KiB | Pipeline 128 | 16,064 | 16,161 | 16,441 |
| 16 KiB | Batch 4 | 4,078 | 1,956 | 1,962 |
| 16 KiB | Batch 4 × pipeline 32 | 17,725 | 17,403 | 17,383 |

**Retain 128 KiB as the general-purpose default.** Reducing to 64 KiB improved
1 KiB individual pipelines by 42.8% and isolated 16 KiB batches by 108.5%, but
reduced 1 KiB pipelined-batch throughput by 23.1%. For that batch case the ten-run
ranges were 68,674–76,917/s at 64 KiB versus 87,530–98,158/s at 128 KiB; median
wave p99 worsened from 1.604 to 2.019 ms. Increasing to 256 KiB lost 34.9% in that
same case, with a 59,806–64,143/s range and 2.277 ms wave p99.

The 16 KiB isolated-batch gain at 64 KiB is also clear: 3,842–4,309/s versus
1,908–2,037/s at 128 KiB, with wave p99 falling from 2.206 to 1.170 ms. A four-value
transaction plus WAL metadata exceeds 64 KiB and can trigger before the 1 ms
timer. This is a useful workload-specific tradeoff, not a broadly dominant
replacement. Most remaining cases were close or noisy; for example, 64 B
individual pipelines ranged from 48,327–66,901/s, 47,613–66,509/s, and
45,783–66,144/s at 64/128/256 KiB respectively.

All three thresholds passed **466 normal Odin tests** before timing. The retained
default also passed **520 simulation tests**, `odin build . -vet`, and the Go
benchmark package's race tests. Experimental code and harnesses are removed;
only the reusable comparison benchmark and historical measurements remain.
These are short, warm, single-worker tests on the orb's ext4 storage, not proof
that one threshold is optimal on every disk or under sustained multi-worker load.

#### Historical commit-policy experiment

The following experiment results are retained as decision history, not current
configuration instructions. The microsecond override, record-count trigger,
ready-I/O drain, per-group tracing, and experimental client harnesses were removed
after choosing the general-purpose 1 ms / 128 KiB policy. ACK-after-fsync remains.
The reusable Redis/NRC comparison runner is retained for byte-threshold tuning.

All policies below retained ACK-after-fsync and the 128 KiB byte trigger. Zero
wait made writes eligible at the next worker pre-tick; it did not mean one fsync
per request. The optional count trigger counted one outer WAL record per atomic
transaction, even when that transaction contained 32 mutations.

Measured on 2026-09-06 with the same hardware/toolchains as the Redis campaign,
but a freshly remeasured baseline interleaved with the experimental builds.
All **480 measured samples passed** reply and final-state checks; 48 pilots are
excluded. Measured intervals ranged from 0.750 to 2.553 seconds.

**Median updates/s across ten independent processes per configuration:**

| Value | Shape | 1 ms default | No extra wait | 250 µs | 1 ms + 32 records |
|---|---|---:|---:|---:|---:|
| 64 B | Single | 552 | 1,481 | 930 | 559 |
| 64 B | Pipeline 128 | 58,481 | 66,988 | 58,453 | 51,656 |
| 64 B | Batch 32 | 16,570 | 39,413 | 27,495 | 16,696 |
| 64 B | Batch 32 × pipeline 4 | 65,013 | 84,939 | 108,514 | 64,124 |
| 1 KiB | Single | 547 | 1,440 | 902 | 551 |
| 1 KiB | Pipeline 128 | 45,007 | 55,897 | 59,996 | 56,258 |
| 1 KiB | Batch 32 | 15,655 | 34,805 | 24,920 | 15,884 |
| 1 KiB | Batch 32 × pipeline 4 | 90,316 | 72,683 | 88,802 | 90,417 |
| 16 KiB | Single | 507 | 1,215 | 803 | 504 |
| 16 KiB | Pipeline 128 | 15,951 | 16,147 | 15,929 | 16,440 |
| 16 KiB | Batch 4 | 1,935 | 3,915 | 2,926 | 1,919 |
| 16 KiB | Batch 4 × pipeline 32 | 17,211 | 17,665 | 17,425 | 17,362 |

The small individually pipelined workload is noisy: min–max updates/s were
50,556–63,273 (default), 62,283–71,920 (zero), 53,229–77,918 (250 µs), and
46,289–68,732 (32 records). Do not describe the 250 µs policy as an improvement
for that case: its median throughput is effectively unchanged.

Removing the timer reduced 64 B single-write median-of-run p50 latency from
**1.802 to 0.659 ms**, confirming a substantial intentional-wait penalty. However,
zero wait reduced 1 KiB pipelined-batch throughput by **19.5%**. The 250 µs policy
increased 64 B pipelined-batch throughput by **66.9%**, reducing wave p99 from
**2.160 to 1.379 ms**. At 1 KiB its pipelined-batch throughput was **1.7% lower**,
and wave p99 increased from **1.692 to 2.188 ms**. These are real tradeoffs, not
a universal win. The 32-record trigger did not provide a consistent improvement;
in particular four atomic batch requests never reach that trigger.

250 µs is a candidate compromise for mixed workloads; zero wait favors sequential
latency but can split a pipeline across earlier fsync submissions. This campaign
did not trace fsync counts, so the latter mechanism is an interpretation, not a
measured attribution. Production defaults are unchanged: multi-connection load
and sustained fsync pressure have not been compared for these policies.

#### Historical ACK-driven client coalescing experiment

The now-removed harness compared three continuous, closed-loop producer
strategies on one connection:

- `pipeline`: immediately send each submitted request; refill each producer as
  soon as its own ACK is processed, without waiting for a whole wave.
- `ack-coalesce`: send whatever is already queued when idle, then collect new
  submissions until every request in that transmitted group has been ACKed.
  Flush the collected group without an additional timer. Individual producers
  are notified of their own ACK immediately, not at group completion.
- `drain-coalesce`: a control that combines requests already queued into fewer
  network writes, but does **not** wait for the previous group's ACKs.

Coalescing buffers separately framed, masked WebSocket messages into one underlying
TCP write (with short-write handling). Independent updates remain independent;
atomic transactions remain separate atomic transactions. No updates are discarded,
overwritten in the queue, or silently combined into one atomic transaction. This
is transport coalescing, not TigerBeetle's event batching into one protocol request:
NRC still pays its existing per-request parsing, WAL-record, and ACK costs.

The campaign focuses on 64 B and 1 KiB values with 128 logical updates outstanding:
128 producers of individual writes, or four producers of atomic 32-write batches.
Each producer owns disjoint keys and alternates values, avoiding order-dependent
final-state checks. Preload 4,096 Notes; the busy workload has 128 hot keys, rather
than the previous benchmark's 32. Additional 64 B single-producer controls compare
pipeline and ACK-coalescing when idle. Latency starts before enqueue and ends when
the individual ACK is processed, **including client queueing**. The previous
fixed-wave numbers are not directly comparable to this continuous workload.

The three policies were 1 ms, zero wait, and 250 µs, each retaining ACK-after-fsync
and the 128 KiB trigger.

There are 42 configurations, 42 excluded calibration pilots, and ten independent
measured processes per configuration (420 samples), with the same server/client
CPU pinning, fresh data, rotated order, and approximately one-second calibration as
above. Each producer warms up with 16 requests before measurement. Phase timing
includes producer startup and client scheduling; request encoding is precomputed,
while WebSocket framing remains timed in all modes. Every ACK and every final hot
value plus one cold value is checked. JSON includes request latency, TCP write
calls (Go `net.Conn.Write` calls, not traced kernel syscalls), and transmitted
group-size distributions. Stop the service after completion.
This is not an open-loop overload, multi-connection, or production SDK benchmark.

Measured on **2026-09-07** with the same hardware/toolchains as above. All **420
measured samples passed**. Measured durations were 0.840–1.526 seconds; pilots and
separate race-instrumented smoke tests are excluded. Median logical updates/s:

| Value | Request type | Server window | Continuous pipeline | ACK-gated coalescing | Drain without ACK gate |
|---|---|---|---:|---:|---:|
| 64 B | Individual | 1 ms | 62,273 | 30,731 | 63,497 |
| 64 B | Individual | 0 | 90,143 | 61,475 | 88,119 |
| 64 B | Individual | 250 µs | 86,955 | 49,055 | 91,531 |
| 64 B | Atomic 32 | 1 ms | 63,838 | 32,357 | 64,296 |
| 64 B | Atomic 32 | 0 | 100,158 | 62,192 | 99,729 |
| 64 B | Atomic 32 | 250 µs | 102,148 | 53,533 | 102,722 |
| 1 KiB | Individual | 1 ms | 53,005 | 44,530 | 52,311 |
| 1 KiB | Individual | 0 | 74,576 | 35,936 | 75,002 |
| 1 KiB | Individual | 250 µs | 72,861 | 44,299 | 75,439 |
| 1 KiB | Atomic 32 | 1 ms | 92,037 | 29,943 | 88,285 |
| 1 KiB | Atomic 32 | 0 | 91,564 | 47,124 | 90,976 |
| 1 KiB | Atomic 32 | 250 µs | 90,036 | 47,065 | 86,658 |

The ACK gate lost throughput in every busy workload/policy pair. At zero server
wait, 64 B individual-write min–max rates were 81,426–98,259 updates/s for plain
pipelining, 58,317–64,043 for ACK-gating, and 83,147–93,734 for drain-only coalescing.
ACK-gating combined a median 103 requests per TCP Write in that case, yet request
p99 rose from **2.186 to 3.178 ms**. At 1 KiB, individual-write p99 rose from
**2.685 to 4.561 ms**, with throughput falling **51.8%**. Fewer network writes were
not sufficient to offset delaying new work behind earlier ACKs.

For 64 B values under the 1 ms policy, ACK-gating averaged 64 independent requests per transmitted
group versus 128 logical requests permitted across queue plus network. Atomic
requests averaged two per group versus four producers. Client queueing therefore
leaves less work eligible for server-side batching. Unlike TigerBeetle's protocol
batch, a combined transport write here does not remove per-request processing.
The drain-only control averaged only about 1.00–1.04 requests per TCP Write under
this closed-loop arrival pattern and showed no consistent throughput benefit.

Single-producer controls remained close: pipeline versus ACK-coalescing p50 was
1.839/1.807 ms at 1 ms server wait, 0.668/0.673 ms at zero, and 1.058/1.093 ms at
250 µs. There is no intentional idle collection delay. These results argue against
adding this ACK gate to NRC's current client protocol; they do not rule out a true
non-atomic bulk protocol, bursty arrivals, or a different client CPU/load topology.
No production SDK behavior or server defaults were changed by this experiment.

### Historical Durability Groups Across Connections

The now-removed multi-connection harness extended the continuous-pipeline workload to
multiple connections in the same workspace, with disjoint conversations/keys.
Keep 4,096 resident Notes **total**, not per connection. Compare one connection
with 128 outstanding logical updates, four connections with the same total 128,
and four connections with 512 total (128 each). Individual writes use one request
per update; atomic transactions use 32 updates per request. Thus 128 logical
updates means four outstanding atomic requests, not 128 batches. The 512-total
case changes the hot set from 128 to 512 keys as well as concurrency.

Opt-in tracing buffered completed groups in memory until graceful SIGINT shutdown,
keeping formatting and logging outside measurement. The trace code and its
analysis helpers have since been removed.

The matrix has 36 cases, 36 excluded pilots, and ten independent measured
processes per case. Retain the CPU placement, fresh data, warmup, calibration,
rotated order, and ACK/final-value checks described above. All connections finish
warmup before the shared measurement barrier. Throughput uses Go's monotonic
clock; Unix timestamps correlate the measurement interval with the server trace.
Analysis requires exact equality between traced requests/mutations and measured
ACKs/updates, and rejects intervals containing untraced synchronous WAL rotations.

Each `COMMIT_TRACE` row records shard, submission/completion Unix nanoseconds,
outer WAL transactions (requests in this workload), mutations, serialized WAL
bytes, collection nanoseconds, overlap with the preceding fsync, WAL-write
nanoseconds, observed fsync nanoseconds, and transactions appended during the
preceding fsync. **Collection and prior-fsync overlap are not additive.**
Collection starts after the group's first successful append and ends at fsync
submission. Fsync latency includes submission/worker scheduling and callback
delivery, not just device service time. WAL-write time is the cumulative write
latency delta between submissions; it is not a CPU profile. No trace claims
power-loss guarantees beyond the underlying filesystem/storage stack.

#### Measured 2026-09-07

Same hardware/toolchains and base revision as the preceding campaign, plus the
opt-in trace hooks and multi-connection client. **360/360 measured samples passed**;
durations were 0.765–1.407 seconds. Median logical updates/s:

| Value | Request type | Connections : total inflight updates | 1 ms | 250 µs | Zero wait |
|---|---|---|---:|---:|---:|
| 64 B | Individual | 1 : 128 | 60,418 | 83,162 | 82,606 |
| 64 B | Individual | 4 : 128 | 59,480 | 88,654 | 89,139 |
| 64 B | Individual | 4 : 512 | 135,667 | 141,548 | 128,817 |
| 64 B | Atomic 32 | 1 : 128 | 63,514 | 101,024 | 96,859 |
| 64 B | Atomic 32 | 4 : 128 | 63,065 | 100,094 | 98,179 |
| 64 B | Atomic 32 | 4 : 512 | 248,799 | 330,020 | 347,319 |
| 1 KiB | Individual | 1 : 128 | 51,171 | 72,952 | 69,089 |
| 1 KiB | Individual | 4 : 128 | 51,460 | 71,114 | 70,801 |
| 1 KiB | Individual | 4 : 512 | 105,393 | 103,565 | 104,072 |
| 1 KiB | Atomic 32 | 1 : 128 | 86,284 | 88,251 | 85,744 |
| 1 KiB | Atomic 32 | 4 : 128 | 89,596 | 84,328 | 86,834 |
| 1 KiB | Atomic 32 | 4 : 512 | 198,593 | 201,901 | 201,309 |

More connections at the same total outstanding work did not consistently help.
Increasing total outstanding work did, especially for atomic batches: at 250 µs,
64 B batches rose from 101k to 330k updates/s (6.47 to 21.12 payload MB/s), while
1 KiB batches rose from 88k to 202k (90.37 to 206.75 MB/s). At 512 total updates,
each connection has only 128 outstanding individual writes or four atomic requests;
none of these runs hit the 512-frame per-connection send-queue cap.

There is substantial run-to-run spread. For example, 64 B individual writes at
4 : 512 ranged from 109,407 to 167,083/s with zero wait, versus 105,504–146,887/s
at 250 µs. The corresponding atomic-batch ranges were 331,835–357,270/s and
317,943–378,943/s. Do not interpret small median differences as a universal policy
ranking. Higher throughput also costs queueing latency: at 250 µs, 64 B individual
request p99 increased from 2.365 ms at 1 : 128 to 4.999 ms at 4 : 512.

The trace explains why a second timer-based collection layer is unpromising:

- At 64 B, 1 : 128, individual writes with the 1 ms window averaged about 68
  requests/fsync, with 1,059 µs collection time, including 610 µs overlapping the
  previous fsync. At 250 µs, about 53 requests/fsync shared 528 µs collection time,
  **500 µs of which already overlapped the preceding fsync**; 97% of requests
  arrived while that fsync was in flight.
- Zero-wait 64 B atomic batches shared about two requests/64 mutations per fsync
  at 1 : 128, versus 7.9 requests/about 254 mutations at 4 : 512. Collection time
  was 499/581 µs, including 480/525 µs overlapping the previous fsync. There is
  already opportunistic collection while durability I/O is outstanding.
- Fsync submission-to-callback means were roughly 0.6–0.9 ms, depending on case;
  a 250 µs configured window therefore does not mean a 250 µs commit cycle.
  The 128 KiB threshold is a trigger, not a hard group-size limit: callback waves
  and work collected during the previous fsync can exceed it.

The values above summarize per-sample means using medians across ten runs.
Default **1 ms / 128 KiB**, ACK-after-fsync, and per-connection queue limits remain
unchanged. These are short, warm overwrite tests on one server worker/shard, not
multi-worker scaling or sustained storage-device saturation measurements.

#### Historical Bounded Ready-I/O Drain Experiment

The now-removed experiment ran one nonblocking nbio callback wave before the
existing durability scheduler whenever a shard was due for fsync. It introduced
no timer or loop waiting for arrivals, and retained the snapshot, single in-flight
fsync, and durable ACK watermark.

The 64 B follow-up had 120 samples: ten per case, including an untraced zero-wait
control. A separate 1 KiB follow-up compared traced baseline and drain variants
in 80 further samples.
All **200/200 passed**, with 0.879–1.265 second measured intervals. Twenty pilots
and four race-instrumented real-server smoke cases are excluded. Compare within
these paired campaigns, not against rates from the earlier collection period.

| Value | Request type | Connections : inflight | Zero wait | Zero + ready drain | Change |
|---|---|---|---:|---:|---:|
| 64 B | Individual | 1 : 128 | 86,576 | 94,729 | +9.4% |
| 64 B | Individual | 4 : 512 | 150,550 | 155,556 | +3.3% |
| 64 B | Atomic 32 | 1 : 128 | 96,011 | 99,493 | +3.6% |
| 64 B | Atomic 32 | 4 : 512 | 349,524 | 340,139 | −2.7% |
| 1 KiB | Individual | 1 : 128 | 72,545 | 77,928 | +7.4% |
| 1 KiB | Individual | 4 : 512 | 122,457 | 120,510 | −1.6% |
| 1 KiB | Atomic 32 | 1 : 128 | 90,293 | 89,126 | −1.3% |
| 1 KiB | Atomic 32 | 4 : 512 | 211,639 | 207,966 | −1.7% |

Single-connection individual writes improved in nine of ten repetitions for
each value size. Their request p99 improved from 2.214 to 2.106 ms at 64 B and
2.697 to 2.584 ms at 1 KiB. Other cases showed mixed results and broad overlapping
ranges. For example, 64 B individual writes at 4 : 512 ranged from 128,160–163,151/s
without the drain and 131,529–166,394/s with it. Atomic 1 KiB request p99 worsened
from 1.966 to 2.264 ms at 1 : 128 and 3.617 to 3.833 ms at 4 : 512.

This was not a large increase in group size: at 64 B, individual 1 : 128 groups
averaged 54.8 versus 56.8 requests/fsync; individual 4 : 512 groups averaged
93.5 versus 93.2. Atomic groups remained near two and eight requests respectively.
The strongest measured gain was localized, not evidence for another batching
layer or for enabling the drain globally. **The experiment was removed.**

The untraced 64 B control medians were 88,753/146,470 individual updates/s and
97,544/346,910 atomic updates/s at 1 : 128 / 4 : 512. Tracing changed medians by
−2.5% to +2.8%, with no consistent slowdown; this is an overhead sanity check,
not a precise instrumentation-cost estimate. Validation also passed 468 normal
and 522 simulation tests with tracing, 467 normal tests with the drain enabled,
default and traced/drain vet builds, Go race checks, and the trace-analysis test.

### SQLite Retained-Message History Baseline

1. Runner and methodology: [`../benchmark/message-history/README.md`](../benchmark/message-history/README.md).
2. Compares active and sealed 100-message history pages, including sealed reads under retained-write pressure.
3. Always report the topology: hot NRC owner versus parallel SQLite is intentionally retained as a
   stress case but is not CPU-equal; the suite also runs one-logical-CPU and matched-logical-CPU
   partitioned scale-out comparisons.
4. SQLite readers are threads in one process with independent connections, not separate processes.
   Benchmark repetitions are separate sequential processes.
5. This is directional: NRC includes the production handler/protocol/io_uring/delivery path while
   SQLite measures a prepared indexed query directly.

## Quick Command Summary

1. Note index RB workload: `BENCH_NOTE_INDEX_RB=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_note_index_rb`
2. Note index B-tree workload: `BENCH_NOTE_INDEX_BTREE=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_note_index_btree`
3. B-tree package workload: `odin run btree/bench -o:speed`
4. Sharded WAL compaction workload: `BENCH_SHARD_COMPACTION=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_shard_compaction_stress`
5. Slice register listing: `BENCH_SLICE_REGISTER=1 odin test . -o:speed -define:ODIN_TEST_TRACK_MEMORY=false -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_NAMES=main.benchmark_slice_register`
6. Asset KV Redis comparison: `cd benchmark && go run ./cmd/asset-kv-bench --backend=both --start-server --auth`
