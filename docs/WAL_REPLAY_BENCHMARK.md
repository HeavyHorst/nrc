# WAL replay CPU scaling

`wal_replay_benchmark.odin` times the production
`init_active_sharded_worker_persistence` path concurrently on 1, 2, 4, 8 and
16 pinned workers. It uses real files and the host storage implementation,
not simulation or an in-memory decoder.

**Timing correction:** the historical campaigns below inadvertently included
lazy per-worker clock initialization inside the replay timer. On this orb,
Odin's TSC-frequency fallback sleeps for two seconds. Their rates and speedups
describe that larger interval, not isolated WAL-processing CPU scalability.
The current harness initializes every worker's clock before the gate and
reports setup separately; the corrected campaign is recorded at the end.

## Workload and timing contract

- Fixed total workload: 524,288 create records, one mutation per transaction,
  evenly divided among all 256 logical shards. One workspace and conversation
  per shard; 2,048 live entities per conversation after replay. Records use
  canonical workspace scope `WORKSPACE_DATA_ID` (0), not legacy room IDs.
- Tasks: 1 KiB descriptions, Todo status and a short title. Assets: Documents
  with 1 KiB uncompressed payloads. Mixed: alternating 50% Tasks / 50% Documents
  within every shard. No edges, attachments, updates, deletes or checkpoints.
- Serialized WAL sizes: Tasks 663,748,608 bytes; Assets 629,669,888 bytes;
  Mixed 646,709,248 bytes. Rates count each record once, not each scan.
- The timed production path opens the managed writers, performs recovery and
  restores append state, validates and applies transactions, rebuilds entity
  indexes, validates final edge endpoints and restores sequence floors.
  The original measurements below scan active-only WAL bytes **three times**;
  the first scan-reuse change reduces that to **two**, and the current combined
  recovery/application path scans them **once**. Effective WAL MB/s is logical
  file bytes divided by elapsed time, not physical disk I/O.
- Timing starts after every worker is initialized and waiting at a shared start
  gate, and ends when the last persistence initialization returns. Thread
  creation, initial heap/page setup, clock calibration, fixture generation,
  correctness checks and teardown are excluded. `REPLAY_SETUP` reports
  wall time from worker creation through all workers becoming
  ready, and the maximum individual worker clock-initialization duration. These overlapping
  durations must not be added together. Setup excludes fixture generation,
  post-replay verification and teardown, so setup + replay is not total startup.
  The start gate uses 100 µs polling, insignificant for second-long samples.
  Network readiness, retained messages and full server startup are not timed.
- Every run checks success, shard ownership, entity counts, IDs, types/status,
  timestamps, payload lengths and every payload byte after timing. No failed
  run is accepted as a throughput result.
- Ten independent sequential processes per configuration, with rotated/reversed
  configuration order. One excluded pilot per configuration initializes the
  managed manifests and warms the storage path. Host WAL reads use **O_DIRECT**,
  bypassing the OS page cache. Device/hypervisor caches are uncontrolled; these
  are repeated-read measurements, not guaranteed cold-storage measurements.
- Physical-core primary threads are used first; SMT siblings are used only
  after all physical cores. The same data is used at every worker count
  (strong scaling). No dedicated service CPU is reserved in this isolated test.

## Reproduce

The current benchmark defaults to the production growing worker TLSF heap
(`NRC_REPLAY_BENCH_ALLOCATOR=worker`). Explicit `heap` selects the old libc heap;
`tlsf` selects the historical fixed-budget experiment. Historical results were
measured before the production-default rollout and clock-boundary correction.
Growing-heap initial setup is excluded, but subsequent pool growth is timed.
Descriptor-table preallocation was an experiment included in the prefault and
10× campaigns below, with its cost in setup. It is no longer used in production
or the harness; those historical timings have not been relabeled.

Build once, then exit the compiler before timing. Use a disposable location;
generation refuses existing directories. On machines with fewer than sixteen
allowed logical CPUs, adjust the runner's worker matrix.

```sh
mkdir -p /tmp/nrc-replay
odin build . -build-mode:test -o:speed \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_NAMES=main.benchmark_wal_replay \
  -out:/tmp/nrc-replay/bench
for kind in task asset mixed; do
  NRC_REPLAY_BENCH_DIR=/tmp/nrc-replay/$kind \
  NRC_REPLAY_BENCH_KIND=$kind NRC_REPLAY_BENCH_MODE=generate \
    /tmp/nrc-replay/bench
done
amp orb service start wal-replay-bench --command \
  "python3 $PWD/benchmark/wal_replay.py /tmp/nrc-replay/bench /tmp/nrc-replay /tmp/nrc-replay/results"
amp orb service logs wal-replay-bench
# Stop the supervised service after summary.json is written.
amp orb service stop wal-replay-bench
```

The runner retains pilot/run logs, `samples.json` and `summary.json`, including
separate setup/clock durations, and refuses to overwrite a result directory.
It requires a binary with the corrected `REPLAY_SETUP` output; historical
binaries require their matching historical runner. `NRC_REPLAY_BENCH_PER_SHARD` and
`NRC_REPLAY_BENCH_PAYLOAD_BYTES` can change fixture dimensions; set them
consistently during generation and replay. Do not compile, run other benchmarks
or execute CPU-heavy tests during the campaign.

## RAM-backed CPU control

To distinguish the ext4 storage path from CPU/memory scalability, repeat the
same production code path on a RAM-backed ext4 loop device, separately and
sequentially, never alongside the disk campaign. The measured control uses
the same 2,048 records per shard and serialized WAL sizes as the disk campaign.
It tests one versus eight physical-core workers, ten runs per configuration,
to check whether poor scale-out persists without physical-storage access.
Exploratory larger-fixture pilots were excluded after confirming that the
original fixture already gives substantial multi-core measurement intervals.

```sh
truncate -s 12G /dev/shm/nrc-replay.img
sudo /usr/sbin/mkfs.ext4 -q -F -m 0 \
  -E lazy_itable_init=0,lazy_journal_init=0 /dev/shm/nrc-replay.img
loop=$(sudo /usr/sbin/losetup --find --show /dev/shm/nrc-replay.img)
mkdir -p /tmp/nrc-replay-ramdisk
sudo mount "$loop" /tmp/nrc-replay-ramdisk
sudo chown "$(id -u):$(id -g)" /tmp/nrc-replay-ramdisk
export NRC_REPLAY_BENCH_PER_SHARD=2048
for kind in task asset mixed; do
  NRC_REPLAY_BENCH_DIR=/tmp/nrc-replay-ramdisk/$kind \
  NRC_REPLAY_BENCH_KIND=$kind NRC_REPLAY_BENCH_MODE=generate \
    /tmp/nrc-replay/bench
done
amp orb service start wal-replay-memory --command \
  "env NRC_REPLAY_BENCH_PER_SHARD=2048 NRC_REPLAY_BENCH_WORKER_COUNTS='1 8' python3 $PWD/benchmark/wal_replay.py /tmp/nrc-replay/bench /tmp/nrc-replay-ramdisk /tmp/nrc-replay/ramdisk-equal-results"
# After completion and exporting results:
amp orb service stop wal-replay-memory
sudo umount /tmp/nrc-replay-ramdisk
sudo /usr/sbin/losetup -d "$loop"
rm /dev/shm/nrc-replay.img
```

The control needs enough tmpfs capacity and RAM for approximately 1.94 GB of
fixtures, filesystem metadata and materialized state. On this Linux 6.1 orb,
plain tmpfs rejects O_DIRECT with EINVAL: an attempted pilot failed and was
excluded. The ext4 loop device accepts the unchanged production reader, while
its backing image lives in tmpfs. These are not reads from a durable disk. This
control removes physical-storage access, but loop-device/filesystem software
and scheduling remain included: it is **not a pure CPU-only benchmark or a
durability-equivalent production throughput measurement**. SHA/CRC, all three
scans, parsing, validation, allocation and index rebuilding remain included.

## Interpretation limits

Workers replay distinct shards concurrently; each shard's history remains
serial. A single workspace maps to one shard and cannot exploit extra replay
workers. Uneven shard populations likewise limit speedup. These balanced results
are not a promise for a one-workspace deployment, compacted/checkpointed history,
large attachments, compressed assets, rich metadata or update-heavy logs.

This benchmark includes production validation and state materialization; it is
not merely SHA/CRC or record decoding throughput. CPU scaling may also reflect
increased storage concurrency. It does not isolate CPU execution from storage.

## Measurement environment, 2026-10-03

Base revision [`15234ef`](https://github.com/HeavyHorst/nrc/commit/15234ef5601ad98e2085635f757e04fe856e9e2a)
plus this local benchmark; production code unchanged. Odin
`dev-2026-09-nightly:a2fb372`, `-o:speed`, default target/microarchitecture,
test memory tracking disabled. Linux 6.1.158+, KVM Intel Xeon @ 2.60 GHz;
8 physical cores / 16 logical CPUs, approximately 31 GiB RAM. Allowed CPUs
0–15, no workload CPU quota or cgroup throttling; host power policy and shared
host scheduling are unknown. Workers use 0,2,4,6,8,10,12,14, then SMT siblings
1,3,5,7,9,11,13,15. Runtime thread affinity was inspected and matched this plan.
Storage: `/dev/root` ext4 on the orb's virtual block device; durability and
underlying device-cache guarantees unknown. No other builds/tests/benchmarks
ran during timing.

Throughput-campaign source SHA-256 (before adding optional perf controls):
`dff8834a12770083c162c7e21fc52b158dd74581034ca5b8500a9109b8ce3151`.
Throughput-campaign executable SHA-256:
`52282923bee939c7fe24143459294898f9803135da4196ed90f318c4dd1602a6`.

An earlier complete disk campaign used legacy room scope 42, following existing
test fixture patterns. That adds legacy-origin migration validation and does
not represent current writes. Those 150 samples and partial RAM-backed
experiments are excluded from the current-scope results. Both final campaigns
use newly generated scope-0 fixtures and the same final executable.

## Current-scope results: ext4 virtual disk

**k records/s, median (minimum–maximum), ten runs per cell:**

| Workers | Tasks | Assets | Mixed |
|---:|---:|---:|---:|
| 1 | 79.7 (56.5–81.0) | 86.3 (61.1–93.2) | 83.8 (57.9–86.2) |
| 2 | 97.5 (91.8–106.6) | 113.8 (86.0–128.0) | 107.4 (79.1–113.5) |
| 4 | 94.0 (72.8–99.6) | 108.3 (98.3–116.4) | 104.3 (95.0–109.9) |
| 8 | 91.9 (84.8–98.4) | 109.2 (102.6–114.5) | 101.2 (90.2–105.7) |
| 16 | 85.2 (74.1–91.2) | 105.6 (103.5–114.3) | 96.2 (89.3–101.3) |

All **150/150** measured samples passed replay/state/scope/payload checks;
15 calibration/warmup pilots excluded. Timed intervals were **4.098–9.276 s**.
The one-worker median times for 524,288 records were **6.58 / 6.07 / 6.25 s**
(Tasks / Assets / Mixed), approximately **101 / 104 / 103 logical WAL MB/s**.
Two workers reduced these to **5.38 / 4.61 / 4.88 s**, approximately
**123 / 137 / 133 MB/s**.

| Workers | Task speedup | Asset speedup | Mixed speedup |
|---:|---:|---:|---:|
| 2 | 1.22× | 1.32× | 1.28× |
| 4 | 1.18× | 1.26× | 1.24× |
| 8 | 1.15× | 1.26× | 1.21× |
| 16 | 1.07× | 1.22× | 1.15× |

Two workers gave the highest medians in this campaign, but the broad overlapping
ranges do not establish a universally optimal worker count. This production
recovery path **does not scale near-linearly** on the measured orb, even with
perfectly balanced shard populations. Sixteen workers add little over one;
SMT does not recover the lost scaling.

## Current-scope results: RAM-backed ext4 control

Same fixture and executable, one versus eight physical-core workers. These
are **k records/s, median (minimum–maximum)** across ten runs per cell:

| Workers | Tasks | Assets | Mixed |
|---:|---:|---:|---:|
| 1 | 80.8 (74.1–83.1) | 92.8 (87.7–94.7) | 85.8 (82.0–87.6) |
| 8 | 95.8 (91.2–97.2) | 113.9 (111.3–116.8) | 102.6 (98.6–106.3) |

Speedups at eight workers: **1.19× Tasks / 1.23× Assets / 1.20× Mixed**.
Median elapsed times at one worker were **6.49 / 5.65 / 6.11 s** and at eight
workers **5.47 / 4.60 / 5.11 s**. Eight-worker logical WAL throughput was
approximately **121 / 137 / 127 MB/s**.

All **60/60** measured samples passed full state/scope/payload checks;
six pilots excluded. Timed intervals were **4.489–7.077 s**. Across both final
campaigns, **210/210 samples** passed, validating 110,100,480 recovered entities.
Raw logs, individual sample JSON and summaries are exported under
`.amp/in/artifacts/wal-replay/`; disposable fixtures and the loop mount were
removed afterward. The production server implementation was not modified.

**Conclusion:** poor scale-out persists with RAM-backed files, so physical
disk access alone is not a sufficient explanation. The control still includes
loop-device/filesystem software and the same three validation/application
passes; this control alone does not identify a CPU bottleneck. The follow-up
perf investigation below identifies allocation-driven VM-lock contention.
Controlled production-hardware profiling is still needed to quantify its
server-only impact. The two campaigns were sequential rather than interleaved
A/B pairs; small absolute differences between them must not be attributed
solely to storage medium.

Harness verification after timing: `odin build . -vet` passed, and
`./test/run_odin_tests.sh . -define:ODIN_TEST_LOG_LEVEL=error` passed all
**566 normal root tests**. Python syntax, exported sample counts, ten samples
per configuration and independently recomputed medians were checked. Benchmark
and documentation additions remain local/uncommitted; no production code changed.

## Perf investigation, 2026-10-03

The follow-up profiles identify a major scaling bottleneck: **allocator-driven
process memory-map lock contention**. Shard state is worker-local, but the
threads share the process address space and its kernel mmap read/write lock.
Task/Asset post-image allocation calls Odin's default heap allocator, which
delegates zeroed allocation to libc `calloc`. Sampled allocation stacks enter
`mprotect`, then mmap-lock handling and scheduler wakeups. Reader-side page
faults also acquire the same lock.

Same 524,288-record canonical fixtures and optimized compiler flags; real ext4
virtual disk, glibc 2.36-9+deb12u14, perf 6.1.187. Hardware cycles/instructions
are not exposed by this VM. Software CPU-clock samples, syscall counts and
mmap-lock tracepoints are available with sudo. Optional FIFO controls enable
collection immediately before the replay timer starts and acknowledge disable
before validation/cleanup is released. Setup and verification are not profiled.

### CPU stacks

Software `cpu-clock` sampling at 199 Hz, DWARF call chains, zero lost samples.
Percentages are of sampled **CPU time, not wall time**. `calloc`/`mprotect`
columns are inclusive call-stack costs; mprotect is a subset of calloc here,
so they must not be added. SHA is self cost.

| Eight-worker workload | libc calloc, inclusive | mprotect, inclusive | SHA-256 hardware transform, self |
|---|---:|---:|---:|
| Tasks | 37.2% | 25.9% | 17.1% |
| Assets | 35.4% | 23.7% | 25.2% |
| Mixed | 38.0% | 24.0% | 19.7% |

For Mixed at one worker, calloc/mprotect were only **10.4% / 3.8%**; SHA was
**27.7%**. At eight workers, **60.2%** of sampled CPU execution was in kernel
symbols versus **46.6%** at one. The stack path includes:

```text
alloc_task / alloc_asset_with_attachments
  → runtime heap allocator → libc calloc → mprotect
  → do_mprotect_pkey → process mmap lock → rwsem wakeups / scheduler
```

### Counters and lock acquisition latency

Three fresh-process gated perf-stat runs per worker count, Mixed. The mprotect
counter is `raw_syscalls:sys_enter` filtered to x86-64 syscall ID 10. Active
CPUs are computed per run as gated task-clock seconds / the benchmark's replay
seconds, not perf's whole-process elapsed time.

| Metric | One worker | Eight workers |
|---|---:|---:|
| mprotect calls per replay | 184,308 | 184,472 |
| Median CPU seconds, including harness threads | 4.24 | 7.10 |
| Median replay seconds in these counter runs | 6.57 | 5.15 |
| Median average active CPUs | 0.65 | 1.43 |

Adding workers therefore increases CPU work substantially but leaves most
CPUs idle or waiting, rather than executing eight-way parallel replay.

Separate gated `mmap_lock_start_locking` / `mmap_lock_acquire_returned` traces
show all workers accessing the same `mm`. Successfully paired write-lock
acquisitions had **p99 0.917 µs at one worker versus 509.896 µs at eight**.
Aggregate successful read/write acquisition latency rose from **0.197
thread-seconds** to **23.427 thread-seconds**. The eight-worker traced replay
lasted **6.332 wall seconds**; these latencies sum across threads and overlap,
so they are not a wall-time percentage. Failed read trylocks are recorded
separately and excluded from that total. There were zero lost trace samples;
one overlapping start in the one-worker trace was not treated as an extra
matched acquisition. Tracing adds overhead, so these are diagnostic timings,
not replacement throughput measurements.

### Benchmark overhead and interpretation

The test runner itself is visible: **20.6% of sampled CPU at one worker and
10.6% at eight** belongs to the main runner thread. Odin's
[runner loop](https://github.com/odin-lang/Odin/blob/a2fb372/core/testing/runner.odin#L607-L627)
requests a 1 µs sleep while polling for test completion. This overhead is not
part of the production server, and must be removed with a standalone/blocking
driver before claiming precise server-only utilization or optimization gains.
The mmap contention is nevertheless directly observed inside actual entity
allocation on replay worker threads, not just in the runner.

A one-off `MALLOC_TOP_PAD_=262144` control did not materially reduce mprotect
calls (183,784 versus 184,472) or replay time; it is not a demonstrated fix.
Odin's [Unix heap allocator](https://github.com/odin-lang/Odin/blob/a2fb372/base/runtime/heap_allocator_unix.odin#L1-L38)
delegates to libc and does not configure mallopt in this path.

The next targeted experiments are larger, long-lived worker-owned allocation
chunks to reduce heap protection/page-mapping operations, and eliminating
redundant validation/hash passes without weakening recovery guarantees. The
three WAL scans explain substantial hashing work but do not by themselves
explain the increased shared-lock contention. No server allocator or recovery
behavior was changed by this investigation.

### Reproduce and artifacts

Build/generate the fixtures as above. For one profile (repeat with workers=1
or another kind):

```sh
mkfifo /tmp/nrc-replay/control /tmp/nrc-replay/ack
sudo env NRC_REPLAY_BENCH_DIR=/tmp/nrc-replay/mixed \
  NRC_REPLAY_BENCH_KIND=mixed NRC_REPLAY_BENCH_WORKERS=8 \
  NRC_REPLAY_BENCH_PERF_CONTROL=/tmp/nrc-replay/control \
  NRC_REPLAY_BENCH_PERF_ACK=/tmp/nrc-replay/ack \
  perf record --delay=-1 \
  --control=fifo:/tmp/nrc-replay/control,/tmp/nrc-replay/ack \
  -e cpu-clock -F 199 --call-graph dwarf \
  -o /tmp/nrc-replay/profile.data -- /tmp/nrc-replay/bench
sudo perf report -i /tmp/nrc-replay/profile.data --stdio \
  --children --call-graph none --sort dso,symbol
```

Use the same controls with `perf stat -e raw_syscalls:sys_enter --filter
'id == 10' -e task-clock,context-switches,page-faults` for counters, or with
the mmap-lock tracepoint events for lock timing. Both FIFO variables must be
set only when a compatible perf process is servicing them; acknowledgements
in this perf version include the terminating NUL byte.

Perf-instrumented benchmark source SHA-256:
`947f4b96639bfe321583dafd7aa431fc22183e9949724bf9eab2a11ffdb4578e`.
Executable SHA-256:
`b7ebcf1bf9b6bdace8f96a48a93023a64b783f388015c1e468980177a3fe538d`.
All **13 successful profiling/control runs** passed full replay verification;
two initial acknowledgement-protocol troubleshooting attempts were excluded.
Text reports, checked run logs, and aggregated counter/lock JSON are exported
under `.amp/in/artifacts/wal-replay-perf/`. Raw DWARF stacks and raw kernel traces
are not exported and are removed with the disposable fixtures.
The optional controls also passed `odin build . -vet` and all **566 normal
root tests** after profiling. These benchmark/report changes remain local and
uncommitted; no production allocator settings were changed.

## Allocator and scan-reuse experiment, 2026-10-03

The follow-up separates two changes:

1. **Experimental TLSF worker heaps.** Set `NRC_REPLAY_BENCH_ALLOCATOR=tlsf`
   for the benchmark. Each worker initializes `core:mem/tlsf` from its own
   fixed backing buffer, writes one byte per 4 KiB page before the start gate,
   and retains the allocator through entity verification and complete teardown.
   All allocations using the worker's `context.allocator` participate, including
   entity blocks, maps, indexes and direct-read buffers; this is not an
   entity-only allocator comparison. The temporary allocator remains unchanged.
   There is no pool growth or heap fallback in the measured interval.
2. **Production scan reuse.** `replay_shard_compaction_sequence` can return the
   active file's successful inspection. Managed-writer initialization uses its
   last hash and record count instead of scanning the active file again solely
   to reconstruct append state. Each file still receives checksum, hash-chain,
   transaction and high-water validation during recovery. Active tail recovery
   must finish successfully before the inspection is returned. Strict state
   rebuild remains a separate verified scan, with final edge validation and
   startup failure cleanup unchanged.

The backing budget is owned shards × (records per shard × (payload bytes +
2,048) + 1 MiB). For this fixture and the power-of-two worker counts, total
backing is **1.75 GiB**, whether one or sixteen workers are used. It is a generous
experimental capacity, not a production sizing policy. Preallocation/page
touching is excluded from replay timings: moving that work earlier does not
make it free for total server startup or memory consumption. At measurement
time production workers still used their existing allocator; TLSF was opt-in
only in the benchmark. The subsequent default rollout uses growing 64 MiB
pools rather than this fixed experimental budget; see `docs/DEVELOPMENT.md`.

The regression checks distinguish active-file append state from cumulative
checkpoint/sealed/active counts and other files' hashes, and append after a
recovered torn tail before strict reinspection. A small TLSF churn test replaces
and removes variable-size Tasks and Assets many times with cumulative allocation
volume exceeding the fixed pool, checking payload bytes and individual reuse.
The final benchmark also checks that TLSF entity pointers lie within their
worker's backing buffer, outside the timed interval.

Use the same build, fixtures and runner as above, changing only the allocator:

```sh
NRC_REPLAY_BENCH_ALLOCATOR=tlsf python3 benchmark/wal_replay.py \
  /tmp/nrc-replay/bench /tmp/nrc-replay /tmp/nrc-replay/tlsf-results
```

For an allocator-only comparison retain a binary from before the scan-reuse
change; compare it with the new binary using both default heap and TLSF. Never
run these timing campaigns concurrently with builds, tests or profiling.

### Gated perf confirmation

Three independent Mixed runs per binary/allocator/worker count, using the
existing FIFO gates and software events. The x86-64 `raw_syscalls:sys_enter`
filters are syscall 10 (`mprotect`) and 17 (`pread64`). Setup, page touching,
verification and destruction are excluded. Medians for eight workers:

| Variant | mprotect calls | pread64 calls | Process CPU seconds | Replay seconds |
| --- | ---: | ---: | ---: | ---: |
| Original heap, three scans | 184,456 | 2,560 | 7.55 | 5.14 |
| TLSF, three scans | 0 | 2,560 | 3.63 | 4.09 |
| Heap, scan reuse | 184,504 | 1,792 | 6.58 | 4.98 |
| TLSF + scan reuse | 0 | 1,792 | 2.66 | 2.98 |

Page faults in the measured phase fall from roughly 212,000 to 80–90 with
TLSF; these faults were largely moved into the excluded pre-touch phase, not
eliminated from total startup. Removing one WAL pass removes 768 `pread64`
calls; the totals also contain reads other than active-WAL scanning. The
per-record checksum/hash/semantic work in these active-only fixtures likewise
falls from three passes to two, without skipping checks on either remaining
pass.

One eight-worker Mixed CPU profile per original heap, TLSF-only and combined
variant used 199 Hz software sampling with DWARF call chains and zero lost
samples. Original heap allocation accounts for 37.6% inclusive sampled CPU,
with mprotect a 24.9% subset. No mprotect appears in either TLSF profile.
Hardware SHA-256 transform self cost is 20.5% / 37.4% / 34.1%, respectively;
these are fractions of different total CPU costs, not evidence that hashing
became slower. The old allocator/kernel work no longer obscures hashing.

In the combined gated runs, average active CPUs in the benchmark process are
still only about 0.86 at eight workers. This includes the test runner, not just
replay workers, and excludes storage work outside this process. Eliminating
allocator contention alone does not establish linear whole-replay scaling;
the host direct-I/O path and harness remain part of the measurement.

An early TLSF prototype assigned `context.allocator` inside an `if` block.
Odin context changes are lexical, so replay outside that block still used the
heap. Those troubleshooting runs are excluded entirely. The corrected switch
is in the replay scope; all accepted TLSF runs check backing-range membership
and full payloads, and gated counters independently confirm zero mprotect.

### Throughput results

Same canonical 524,288-record fixtures, hardware, compiler and optimization
flags as above. Fresh heap baselines and scan-reuse-only runs use one and eight
workers, ten processes per cell. TLSF-only and combined runs use the full
1/2/4/8/16 matrix, ten processes per cell. Each campaign is sequential, with
rotated/reversed case ordering and excluded pilots; variants are measured in
separate campaigns rather than paired in the same repetition. Host scheduling
and device caches remain uncontrolled. All **420 timed disk samples** passed.

Eight-worker medians, **thousand records/s**:

| Workload | Original heap | TLSF only | Scan reuse only | Both | Both / original |
| --- | ---: | ---: | ---: | ---: | ---: |
| Tasks | 95.2 | 125.3 | 103.6 | 167.6 | 1.76× |
| Assets | 111.0 | 129.4 | 119.6 | 172.2 | 1.55× |
| Mixed | 97.3 | 126.9 | 110.4 | 168.6 | 1.73× |

The fresh original one-worker medians are 73.2 / 85.0 / 80.5 thousand
records/s for Tasks / Assets / Mixed. Combined one-worker medians are
101.8 / 110.9 / 105.8. The broader spread in the baseline (especially at one
worker) is retained in the raw min/max summaries; small differences should
not be interpreted as statistically established gains.

TLSF only, retaining all three scans:

| Workers | Tasks, k records/s | Assets, k records/s | Mixed, k records/s |
| ---: | ---: | ---: | ---: |
| 1 | 83.5 | 94.1 | 89.4 |
| 2 | 123.3 | 128.1 | 124.7 |
| 4 | 124.0 | 129.2 | 126.6 |
| 8 | 125.3 | 129.4 | 126.9 |
| 16 | 125.7 | 132.8 | 133.6 |

TLSF + scan reuse:

| Workers | Tasks, k records/s | Assets, k records/s | Mixed, k records/s |
| ---: | ---: | ---: | ---: |
| 1 | 101.8 | 110.9 | 105.8 |
| 2 | 138.4 | 149.2 | 144.6 |
| 4 | 171.3 | 172.6 | 170.0 |
| 8 | 167.6 | 172.2 | 168.6 |
| 16 | 167.7 | 175.2 | 173.9 |

Eight-worker combined replay completes in about **3.13 / 3.04 / 3.11 seconds**,
respectively. Scaling from the same combined variant at one worker is only
**1.65× / 1.55× / 1.59×**, not the improvement factor over the old eight-worker
binary. Four-worker and higher results overlap; neither eight physical workers
nor sixteen SMT workers establish an additional clear throughput gain here.

### RAM-backed combined control

Copy the exact final disk fixtures to ext4 on a 6 GiB loop image backed by
tmpfs, flush the filesystem, then run the combined binary with TLSF at one and
eight workers, ten processes per cell. Preallocation, validation and teardown
remain outside the timer; reads still use the same O_DIRECT implementation.
All **60 timed RAM-backed samples** passed; the mount, loop device and backing
image were removed afterward.

| Workload | One worker, k records/s | Eight workers, k records/s | Speedup |
| --- | ---: | ---: | ---: |
| Tasks | 107.2 | 206.7 | 1.93× |
| Assets | 117.7 | 211.9 | 1.80× |
| Mixed | 112.5 | 210.6 | 1.87× |

Removing physical-storage access improves eight-worker throughput by about
23–25%, but scaling remains below twofold. **Physical disk bandwidth alone
does not explain the remaining limit.** The loop/filesystem path, blocking I/O,
test-runner polling and uncontrolled host scheduling remain in this control;
it is not a pure CPU/hash benchmark. The residual bottleneck has not been
isolated, so these results must not be presented as evidence of a shared SHA
lock or as a prediction of native-server CPU utilization. Independent SHA
contexts have no shared lock in the inspected Odin implementation.

### Verification and artifacts

The final source passes the normal and simulation root suites, including
complete-record corruption rejection, exhaustive representative torn-record
cuts, Hegel recovery/crash properties, manifest-order continuation and rollback
after startup apply failure. TLSF churn also overwrites the caller's input
buffer before checking stored bytes, detecting borrowed rather than owned
payload storage. These checks predate the production allocator rollout.

Checked logs, samples, median/min/max summaries, the 24 gated counter runs,
three CPU profiles as text reports, binary/source fingerprints and verification
results are retained under `.amp/in/artifacts/wal-replay-optimization/`.
Raw DWARF stack data and disposable fixture/binary directories are not exported.
Those samples predate the production allocator rollout and clock correction.

## Clock-initialized replay, 2026-10-03

Oracle identified that the benchmark did not call `ulid.init()` on its replay
workers. The first WAL initialization therefore lazily calibrated each worker's
thread-local TSC inside the timer. A diagnostic trace confirmed failed hardware
`perf_event_open` calls followed by two-second sleeps. The sleeps overlap across
workers, creating roughly two wall seconds of fixed overhead, not two seconds
times the worker count. Production initializes the clock before persistence.

The corrected harness initializes each pinned worker's clock before signaling
`ready`. It reports aggregate worker setup separately, including thread creation,
initial heap setup/page touching and clock initialization. A second diagnostic
trace verified that all eight calibration sleeps precede `REPLAY_SETUP` and the
replay interval. Traced diagnostic times are not throughput samples.

### Campaign contract

Based on [the worker-default revision](https://github.com/HeavyHorst/nrc/commit/22a85c9fc5e9617576abcf170249ce20fd25de93)
plus this benchmark-only clock/setup-reporting correction. Same Odin version,
compiler flags, reported 8-core/16-thread KVM hardware, affinity ordering and
canonical workload described above. Regenerated with the unchanged fixture
builder: 524,288 records per workload and the same serialized WAL sizes.
Recovery still uses two verified passes. No production recovery or allocator
policy changed in this follow-up.

Two sequential disk campaigns: fixed-budget TLSF first, growing production
worker heap second. Each uses 1/2/4/8/16 workers, ten independent processes per
cell, rotating/reversing configuration order and one excluded pilot per cell.
The RAM-backed control then uses the exact disk fixtures copied to ext4 on a
6 GiB loop image in tmpfs, one/eight workers, ten processes per cell and fixed
TLSF. All **360 timed samples and 36 pilots** passed full entity/payload checks.
There are no subtracted or synthetically corrected historical samples here.
No builds, tests or other benchmark campaigns ran concurrently.

Host scheduling, device caches and power policy remain uncontrolled. These are
sequential campaigns, not interleaved allocator/storage A/B pairs. Hardware
instruction/cycle counters remain unavailable. All rates below are median
**thousand records/s**, counting each logical record once.

### Fixed-budget TLSF, disk

| Workers | Tasks, k records/s | Assets, k records/s | Mixed, k records/s |
| ---: | ---: | ---: | ---: |
| 1 | 174.9 | 214.1 | 190.4 |
| 2 | 323.2 | 395.2 | 353.7 |
| 4 | 516.6 | 526.4 | 533.8 |
| 8 | 460.6 | 507.4 | 497.7 |
| 16 | 474.9 | 522.8 | 480.9 |

One-to-eight speedups are **2.63× / 2.37× / 2.61×**, rather than the historical
1.65× / 1.55× / 1.59× over the interval containing clock initialization.
Eight-worker replay takes **1.138 / 1.033 / 1.053 seconds**. Median setup spans
approximately 2.15–2.85 seconds across cells; clock calibration alone remains
approximately two seconds, now correctly reported outside replay.

Disk throughput still flattens around four workers. Sixteen workers use SMT,
not sixteen physical cores. Raw min/max spread is retained: the fastest
sixteen-worker Asset/Mixed runs exceed 1.1 million records/s while their medians
are around 0.5 million. Do not interpret small median differences as a proven
benefit or regression, or infer a precise native-server CPU ceiling.

### Growing production worker heap, disk

| Workers | Tasks, k records/s | Assets, k records/s | Mixed, k records/s |
| ---: | ---: | ---: | ---: |
| 1 | 126.4 | 164.9 | 140.5 |
| 2 | 137.8 | 203.7 | 161.7 |
| 4 | 234.0 | 372.1 | 278.6 |
| 8 | 438.2 | 539.8 | 503.0 |
| 16 | 526.1 | 557.5 | 566.6 |

One-to-eight speedups are **3.47× / 3.27× / 3.58×**; eight-worker replay takes
**1.197 / 0.972 / 1.047 seconds**. Median setup spans approximately 2.15–2.90
seconds. Subsequent pool growth and faults are included in replay, unlike the
fixed-budget comparison.

This is a production-policy measurement, **not a constant-preallocation CPU
control**: the initial write-touched capacity is 64 MiB per worker, so it grows
from 64 MiB at one worker to 512 MiB at eight and 1 GiB at sixteen. More workers
can move more page-commit work into excluded setup and require less timed
growth. The fixed-budget comparison keeps total preallocation at 1.75 GiB
for every worker count. Do not attribute all production-mode speedup to CPU
parallelism or treat its low-worker allocation overhead as storage latency.

### RAM-backed fixed-budget control

| Workload | One worker, k records/s | Eight workers, k records/s | Speedup |
| --- | ---: | ---: | ---: |
| Tasks | 187.0 | 1,029.5 | 5.51× |
| Assets | 231.3 | 1,147.7 | 4.96× |
| Mixed | 206.3 | 1,043.7 | 5.06× |

Eight-worker replay takes **0.510 / 0.457 / 0.502 seconds**, versus disk's
1.138 / 1.033 / 1.053 seconds with the same fixed-budget mode. The storage-medium
control changes the remaining limit substantially: roughly twice the
eight-worker throughput and much stronger scaling. This supports a significant
storage-path contribution after calibration is excluded, but does not identify
a particular device, filesystem lock or scheduling bottleneck. The loop/ext4
path still performs synchronous direct I/O; this is not a pure CPU benchmark.
No shared SHA lock was found. Remaining nonlinearity cannot be assigned to SHA,
memory bandwidth or a specific global lock from these measurements alone.

### Gated counters and allocation placement

Three independent Mixed perf-stat runs for each allocator and one/eight workers,
after the throughput campaigns. The existing FIFO gates exclude setup and
teardown. All **12 diagnostic runs** passed full replay verification. Medians:

| Mode | Workers | Replay seconds | CPU seconds | Average active CPUs | Page faults | mprotect | pread64 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Fixed TLSF | 1 | 2.696 | 2.448 | 0.91 | 62 | 0 | 1,792 |
| Fixed TLSF | 8 | 0.995 | 2.492 | 2.51 | 81 | 0 | 1,792 |
| Growing worker | 1 | 3.813 | 3.916 | 1.03 | 303,388 | 0 | 1,792 |
| Growing worker | 8 | 0.988 | 5.364 | 5.43 | 122,985 | 0 | 1,792 |

Average active CPUs is computed per run as gated CPU seconds / replay seconds,
then summarized; it is not perf's whole-process `CPUs utilized` field. CPU totals
include harness threads but exclude storage work charged outside this process.
The fixed comparison now shows about 2.5 active CPUs at eight workers, not the
historical 0.86 over the interval containing calibration.

The production heap retains zero measured `mprotect` calls, but growth/page
commit costs are now visible inside replay. Its higher CPU work and faults
must not be described as proof of a particular contention mechanism without
stacks or lock traces. Nor does zero `mprotect` mean allocation is free.

### Verification and exports

The normal root suite passed **570 tests**, production vet passed, Python syntax
was checked, and all sample counts and median/min/max rates were independently
recomputed from record counts and elapsed times. Raw samples, setup durations,
run/pilot logs, gated counter files and source/binary fingerprints are retained
under `.amp/in/artifacts/wal-replay-clock-fixed/`. Disposable fixtures, binary,
RAM image and loop mount are removed after export. Historical reports remain
available, clearly distinguished from these newly measured results.

## Write-first worker TLSF prefault trial (2026-10-03)

Fresh zeroed TLSF backing is now write-touched before pool header initialization,
including growth pools. The existing FD-preallocation trial is present in both
conditions. Ten alternating independent samples per cell on the same Mixed
524288-record corpus, ext4/loop backed by RAM, with O_DIRECT reads:

| Workers | Replay before→after, s | Full launch→listener before→after, s | Listener RSS before→after, MiB |
| ---: | ---: | ---: | ---: |
| 1 | 3.512→2.829 | 7.176→7.075 | 854.7→881.6 |
| 4 | 1.741→0.757 | 6.390→4.922 | 927.1→1135.3 |
| 8 | 0.784→0.460 | 5.600→4.698 | 1024.4→1218.7 |

Eight-worker replay improves 41.3%, full startup 16.1%; the cost is roughly
194 MiB additional resident memory from committing unused growth-pool tails.
One→eight replay speedup is 6.15× rather than 4.48×, but initial committed
capacity still increases with worker count: this is not a constant-budget
CPU control. These results do not replace the disk tables above.

Three gated eight-worker CPU profiles per condition attribute 34.40/29.89/30.47%
of before CPU samples to the targeted TLB/IPI leaves, all with COW and TLB-flush
stacks; none are sampled after. SHA-256 then accounts for 35.58–36.40%, XXH64
7.56–9.99%. Gated CPU-s falls 5.175→2.443; page faults increase 122986→131160
because more backing is committed. This is removal of the expensive COW/IPI
path, not elimination of faults or proof of zero TLB activity.

Raw samples, setup timings, real-server readiness/RAM snapshots, counters,
profiles, source/binary fingerprints, reproduction scripts and checksum-verified
perf recordings are under `.amp/in/artifacts/wal-replay-prefault/`, with a full
`REPORT.md`. Throughput is 1.140 million logical records/s on this RAM-backed
workload; a 10× corpus at unchanged throughput would take about 4.6 s of replay,
an extrapolation rather than a measurement. Fixed startup costs amortize, but
hashing, memory commitment, indexes and storage work grow with the corpus.

After the campaign, the licensed pinned TLSF copy in `vendor/tlsf/` received a
separate tracking-allocation-failure rollback fix. The measured binaries predate
that dependency switch and do not exercise its failure path. Its regression
fails on the original dependency and passes with rollback; normal/simulation
root suites pass 571/656 tests, production vet and targeted Go E2E pass, and
Oracle's follow-up review finds no blockers.

## 10× Mixed corpus follow-up (2026-10-03)

Ten alternating independent processes per size, worker count and timing mode,
using the same current binaries (prefaulting plus vendored TLSF recovery fix).
Small is 524288 records/646709248 WAL bytes; large is 5242880 records/6467092480
bytes. Payloads remain 1024 bytes, shards remain 256, and records per shard grow
2048→20480. Both corpora use RAM-backed ext4/loop with O_DIRECT reads, not disk.

| Workers | Small→large replay, s | Small→large full startup, s | Small→large listener RSS, GiB |
| ---: | ---: | ---: | ---: |
| 1 | 3.076→29.671 | 7.132→34.735 | 0.861→7.361 |
| 4 | 0.799→8.022 | 5.074→12.724 | 1.109→7.609 |
| 8 | 0.529→5.026 | 4.764→9.260 | 1.190→7.690 |

At eight workers, 10× data takes 9.50× replay time but only 1.94× full startup
and 6.46× resident memory. Large throughput is 1.043 million logical records/s;
one→eight speedup is 5.90× versus small's 5.82×. Fixed startup costs amortize,
while record processing remains approximately proportional. Use the fresh
same-binary 0.529 s baseline, not the previous campaign's 0.460 s value.

Three gated large-corpus CPU captures show SHA-256 hardware-transform leaves
at 30.26–30.57%, XXH64 at 7.11–7.28%, and fault-handling stacks at 19.55–23.53%,
almost entirely under TLSF backing prefaulting. Kernel page-zeroing alone is
11.09–15.05%; it is included in fault handling, not an additional category.
TLSF bookkeeping leaves are 2.05–2.19%. No targeted COW/TLB IPI leaves are
sampled. Gated eight-worker counters show 28.347 CPU-s and 1835208 faults;
ordinary page commitment remains work even though the old COW hotspot is gone.
No DRAM-bandwidth ceiling or allocator mutex is established by these profiles.

All 120 timing samples and 18 diagnostic processes pass their checks; all six
CPU captures report zero lost samples and all saved listener snapshots report
zero swap. The filesystem's roughly 6.7 GiB backing is additional to process
RSS. Full spreads, setup timing, counters, profiles, archived recordings,
reproduction scripts and fingerprints are retained in
`.amp/in/artifacts/wal-replay-10x/REPORT.md` and its adjacent exports.

## Retained changes after review

Keep write-first initial/growth-pool prefaulting, accepting earlier commitment
of unused pool tails, and the pinned TLSF tracking-node OOM rollback fix.
Reject startup FD-table preallocation: its ten-run eight-worker full-startup
gain was only 77 ms (1.34%), and four-worker startup was effectively unchanged.
Its helper, benchmark call and dedicated test were removed together.

The prefault A/B and 10× measurements above included FD preallocation in both
conditions. They remain valid comparisons, but at that review the combination
without that experiment had not yet been timed. Do not subtract 77 ms from other
campaigns or relabel their historical numbers; the fresh comparison below uses
the actual default without FD preallocation.

## Single-pass recovery and huge-page trial (2026-10-04)

Baseline: [26c8503](https://github.com/HeavyHorst/nrc/commit/26c8503efc491e17310f500be24b55a8c08edbaa).
Three conditions: baseline, single-pass recovery/application, and single-pass
plus best-effort huge-page advice on fully owned TLSF backing interiors. None
includes FD-table preallocation. Ten independent processes per cell, alternating
condition/case order; same corpora and growing worker heaps. Root production
files retained after the trial match the measured single-pass condition.

Single-pass startup keeps checksum/hash-chain, transaction/origin and final-edge
validation, active-tail truncate+sync, and file-local append hash/count. It applies
validated records into unpublished state and discards that state on any failure.
Checkpoint+sealed prefix floors are captured during the scan instead of rescanned;
the active-only timing corpus does not measure that separate benefit.

### Retained single-pass result

524288 create records, 1024-byte payloads and 256 shards. Median seconds:

| Kind | 1 worker, before→single | 4 workers, before→single | 8 workers, before→single | Single 1→8 speedup |
| --- | ---: | ---: | ---: | ---: |
| Tasks | 3.273→2.351 | 0.965→0.731 | 0.619→0.450 | 5.22× |
| Assets | 2.583→1.715 | 0.743→0.525 | 0.537→0.374 | 4.58× |
| Mixed | 2.965→2.023 | 0.867→0.616 | 0.570→0.375 | 5.40× |

At eight workers the reductions are 27.3%, 30.4% and 34.3%. With 10× Mixed
(5242880 records / 6467092480 WAL bytes), replay improves 4.798→2.871 s,
or 40.2%, reaching 1.826 million logical records/s.

Throughput from the unrounded single-pass median durations:

| Kind | Workers | Logical records/s | Serialized WAL MB/s |
| --- | ---: | ---: | ---: |
| Tasks | 1 | 223013 | 282.3 |
| Tasks | 4 | 717259 | 908.0 |
| Tasks | 8 | 1164496 | 1474.3 |
| Assets | 1 | 305707 | 367.2 |
| Assets | 4 | 999081 | 1199.9 |
| Assets | 8 | 1401344 | 1683.0 |
| Mixed | 1 | 259230 | 319.8 |
| Mixed | 4 | 851216 | 1050.0 |
| Mixed | 8 | 1399670 | 1726.5 |
| Mixed 10× | 8 | 1826199 | 2252.6 |

MB is 1000000 bytes. The generated Tasks/Assets/Mixed WAL corpora contain
663748608 / 629669888 / 646709248 bytes respectively, including serialized
headers and transaction metadata. One operation here is one logical entity
create replayed, not a live request or an individual validation step. These
rates divide each corpus's logical WAL bytes by replay time; they are not
physical disk bandwidth or full-startup throughput.

Real-server Mixed launch→listener medians, including setup and TCP-readiness
verification, are 7.086→6.199 s at one worker, 5.076→4.806 s at four and
4.882→4.654 s at eight. Large eight-worker startup improves 9.143→7.379 s
(19.3%). Listener RSS remains effectively unchanged: approximately 881.6,
1135.3 and 1218.7 MiB for small 1/4/8, and 7874.4 MiB for large eight workers.

### Huge pages: measured, not retained as default

The hint worked: large startup shows 7440 MiB AnonHugePages; gated faults drop
1835209→61019 and median CPU-s 21.086→16.622 versus single-pass ordinary pages.
However, incremental full-startup benefit is inconsistent on small Mixed and
only 208 ms / 2.8% between medians on large Mixed, with 6/10 faster pairs and a
134 ms median paired saving. Large replay improves another 5.7% (2.871→2.708 s).
Live-growth tail latency under pressure was not measured with `defrag=madvise`.
After Oracle review, retain single-pass/prefix-floor reuse but remove the THP
production hint and its dedicated bounds code; preserve the prototype in exports.

Three gated large eight-worker CPU profiles per condition attribute 20.53–21.91%
of single-pass CPU samples to SHA hardware-transform leaves, 5.22–5.25% to XXH64,
and 22.84–26.61% to fault-handling stacks. Page zeroing is included in those
stacks; TLSF bookkeeping is 3.04–3.52%. No targeted TLB/IPI or direct-compaction
samples occur, which is not proof of absence under other pressure. There is no
demonstrated allocator mutex or DRAM-bandwidth ceiling explaining nonlinearity.

This is RAM-backed ext4/loop with O_DIRECT, not cold physical-disk throughput.
Odin a2fb372, optimized builds, tracking disabled, Linux 6.1.158+, eight exposed
cores/sixteen logical CPUs, KVM; hardware PMU/governor unavailable and host
scheduling uncontrolled. The roughly 8 GiB filesystem is additional to RSS.
Initial heap commitment grows with worker count, so this is not a constant-memory
CPU control. Full startup and isolated replay are separate measurements.

All 420 timing samples, 18 diagnostic processes and nine loss-free CPU captures
were checked; raw archive hashes match the original recordings. Existing
corruption/torn-tail/durable-prefix tests were reused, extending only floor and
recovery-I/O-cleanup coverage. Full spreads, paired results, raw samples/logs,
readiness RAM/THP snapshots, counters/stacks, archived recordings, source/binary
fingerprints and scripts are in `.amp/in/artifacts/wal-replay-single-pass/REPORT.md`
and adjacent exports.

## Payload zeroing and replay index insertion (2026-10-04)

Baseline: [48a2fd3](https://github.com/HeavyHorst/nrc/commit/48a2fd35b9e8da96b1dd41fcc0d4d6673679c674).
These experiments do not reduce replay volume or change compaction. Large Mixed
again contains 5242880 create records / 6467092480 serialized WAL bytes, eight
workers, 1 KiB payloads and production growing TLSF heaps. Same toolchain/orb,
RAM-backed ext4/O_DIRECT, tracking disabled. Each row is a separate alternating
ten-process-per-condition campaign with one excluded warmup per condition;
do not compare absolute times between rows as a speedup.

| Candidate | Before median, s | Candidate median, s | Reduction | Faster pairs |
| --- | ---: | ---: | ---: | ---: |
| Non-zeroed payload allocation, explicit descriptors | 3.010484 | 3.009772 | 0.024% | 6/10 |
| Replay-only B-tree load, ordered records | 3.114043 | 2.962546 | 4.865% | 8/10 |
| Replay-only B-tree load, reverse-ID records | 3.167166 | 3.162177 | 0.158% | 6/10 |

The zeroing change was reverted: no meaningful wall-time benefit. The index
candidate uses existing `btree.load` only while synchronous shard replay applies
records; ordinary live mutations retain `btree.set`. Sorted keys take its append
path, while unordered/equal keys and full leaves fall back to normal insertion.
No validation is removed and no index work is deferred beyond readiness. Ordered
candidate throughput is 1.770 million logical records/s / 2183 decimal WAL MB/s.
Reverse order shows no demonstrated wall-time improvement; three gated perf-stat
runs show CPU-s medians 20.41684→20.72154, a noisy 1.49% increase. Fallback has
an extra rightmost-path traversal, so this is an order-sensitive tradeoff, not a
universal speedup. Oracle found no blockers and recommended keeping the small
replay-only candidate on that evidence; the varied-data follow-up below supersedes
that retention decision. This is streaming insertion, not bulk index rebuilding.

Normal 571, simulation 656 and B-tree 31 tests and optimized vet passed, reusing
existing unordered-index/query and B-tree split/replacement fixtures. All 60
retained timing processes and 12 gated perf-stat diagnostics completed; replay
also verifies entity counts/ownership/IDs/types/status/timestamps and payload
bytes outside timing. Full startup was not measured. Raw data, spreads, patches,
sources and scripts are in `.amp/in/artifacts/wal-replay-index-load/REPORT.md`,
its `reverse/` directory and the adjacent `wal-replay-zeroing/` export.

### ID-sorted records with varied index fields: candidate rejected

The earlier ordered fixture correlated timestamps with IDs and used identical
task priorities/statuses. Real checkpoints sort by ID, not by those index keys.
The follow-up keeps IDs ascending but cycles all four task statuses and five
priorities, with deterministic non-monotonic update and completion timestamps.
Set `NRC_REPLAY_BENCH_VARIED=1` for both generation and replay. Verification
checks stored fields, active counts, time-index order and global/project/assignee
priority-index order against independently sorted expected keys outside timing.
Both builds share this exact benchmark code; only the insertion implementation
differs. Twelve small replay checks cover Tasks/Assets/Mixed, uniform/varied and
both builds before the large run.

Same large Mixed record/byte counts and eight-worker RAM-backed setup as above,
ten alternating processes per condition and one excluded warmup each:

| Insertion | Median replay, s | Range, s | Logical records/s | WAL MB/s |
| --- | ---: | ---: | ---: | ---: |
| Ordinary B-tree set | 3.352239 | 3.318558–3.646109 | 1563994 | 1929.2 |
| Replay-only B-tree load | 3.377904 | 3.305169–3.528109 | 1552110 | 1914.5 |

The candidate median is 0.77% slower, with overlapping spreads. It wins only
3/10 pairs; median paired loss is 34.35 ms. Three gated perf-stat runs show CPU-s
medians 23.71214→23.20181 (2.15% lower) and effectively identical faults
(1835208→1835209), but this small diagnostic sample does not establish a CPU
benefit or offset the lack of a repeatable wall-time benefit. Reject the candidate:
ordinary insertion and its original tests are restored. Retain only the varied
fixture and stronger benchmark verification. This corpus emulates checkpoint ID
ordering using active-WAL post-images; literal catalog/checkpoint files, edges,
other asset types and full process startup were not measured.

Raw samples/logs, counters, source/patch snapshots, binary fingerprints and
reproduction scripts are in `.amp/in/artifacts/wal-replay-varied/`.
