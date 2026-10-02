# CPU-explicit retained-message history comparison

This benchmark compares NRC's retained-message history page path with an indexed SQLite analogue
without hiding the CPU topology. It reports three deliberately different cases:

1. **Hot owner / SQLite parallel** — one NRC owning-worker surrogate pinned to one logical CPU;
   one SQLite process with four reader threads allowed on four logical CPUs. This preserves the old
   hot-owner stress result, but is explicitly not a CPU-equal comparison.
2. **Hot owner / one CPU each** — NRC and the entire multithreaded SQLite process are each pinned to
   one logical CPU.
3. **Matched logical-CPU scale-out** — four independent NRC processes, workspaces, and stores pinned
   one per logical CPU; one SQLite process pinned to the same four logical CPUs with four readers.
   NRC rates are aggregated. This measures partitioned worker scale-out, not one hot conversation.

SQLite readers are pthreads in one process, each with its own connection and prepared statement.
They are not separate processes. Under write pressure SQLite adds one writer thread. NRC's aggregate
offered write rate is divided among its independent scale-out processes so both backends receive the
same aggregate offer.

## Run

Dependencies: Odin, Python 3, a C compiler, pthreads, and SQLite 3 development files.

```bash
python3 benchmark/message-history/run_comparison.py \
  --runs 10 --rounds 2000 --cpu-list 0,2,4,6 \
  --workload active --output /tmp/message-history-active.json

python3 benchmark/message-history/run_comparison.py \
  --runs 10 --rounds 2000 --cpu-list 0,2,4,6 \
  --workload sealed --write-rate 25000 --duration-seconds 2 \
  --nrc-writers 8 --nrc-batch-records 16 \
  --output /tmp/message-history-sealed.json
```

`--cpu-list` explicitly selects logical CPU IDs. The example chooses one SMT sibling from each of
four physical cores on its host; inspect `lscpu -e=CPU,CORE` instead of assuming that mapping.
Alternatively, `--logical-cpus 4` selects the first four CPUs from the process's affinity mask.
Those are not necessarily four physical cores. Record the host topology when publishing results.
Runs are independent process repetitions; they are sequential, not ten simultaneous processes.
For the sealed workload, `--rounds` controls the idle baseline and `--duration-seconds` controls the
loaded phase. Every NRC owner and the SQLite process issue synchronized page waves for that fixed
duration, then finish the in-flight wave. Scale-out rates use actual completed pages and writes over
the shared makespan rather than assuming equal per-owner work. Each scale-out NRC row also retains
its raw `owner_results` (CPU, elapsed time, completed pages, and achieved writes) so skew is visible.
`--nrc-batch-records` controls retained-message records per NRC group commit; `0` restores uncapped,
byte-bounded batches. Use separate output files for `0`, `4`, `8`, and `16` when tuning the
throughput/tail-latency tradeoff. Use enough `--nrc-writers` to stage more than the tested cap before
a flush (eight writers can stage up to 32 records) so the cap is actually exercised.
Use `--topology hot_owner_parallel_sqlite` for a quicker hot-owner tuning sweep; omit it for the full
three-topology Portal dataset.

To render a combined report, merge the `rows` arrays from the active and sealed JSON documents while
keeping the shared metadata, then run:

```bash
python3 benchmark/message-history/render_portal.py \
  /tmp/message-history-combined.json /tmp/message-history-portal
```

Serve the generated directory through an Amp Portal or another static HTTP server.

## Workloads and boundaries

- Active: 10,000 retained target-conversation messages with five interleaved distractors per target,
  256-byte content, and alternating ascending and descending pages requested with limit 100.
- Sealed: 100,000 conversation-clustered records with 1 KiB content and alternating ascending and
  descending pages requested with limit 100. Both backends enforce NRC's 96 KiB page-byte budget,
  so this fixture returns 91 messages per page. NRC's loaded phase follows its idle phase in the same
  process and store. SQLite uses separately seeded fresh processes/databases for idle and loaded
  phases; this cache-state difference is a disclosed limitation. The loaded comparison is
  fixed-duration; its page count is observed work, not a preset stopping target.
- NRC exercises production handlers, protocol serialization/parsing, io_uring, and simulated client
  delivery. SQLite measures the prepared indexed query directly. The result is therefore a system-
  path comparison, not an isolated storage-engine microbenchmark.
- NRC additionally reports separate p95 distributions for the synchronous batched WAL `write()`
  syscall and threshold-triggered async `fsync()` submission-through-CQ-callback latency. The latter
  normally has only about two samples in a two-second loaded phase, making its per-run p95 the maximum. The Portal shows
  median per-run p95 and sample counts, renders missing fsync samples as N/A, and omits scale-out because
  independent owner p95s cannot be merged into an aggregate p95.
- NRC also reports median per-run maxima for hot-owner descending-page and write-turn latency because two fsyncs
  among thousands of turns are too sparse to affect p95. Maxima are descriptive tail observations,
  not stable percentiles.
- NRC page latency ends at the instant the complete frame becomes visible in the simulated client,
  rather than when the benchmark later polls and parses that frame. The loaded result separately
  reports owning-worker submit-plus-commit/publish and commit/publish p95 so write-path CPU and
  storage stalls are not folded into already-delivered page latency.
- SQLite uses WAL mode and `synchronous=NORMAL`. NRC writes use the benchmark's production message
  WAL path. Record durability and cache state with any published result.
- The orchestrator uses temporary independent databases and stores and deletes them after each run.

The JSON contains every raw process result plus the CPU set and topology. Use medians across process
runs for headline values; retain the raw rows so spread and outliers remain auditable.

## NRC sealed-page phase profile

The sealed benchmark also reports simulation-only timings for request/index/io_uring retrieval to
bytes-ready, record decode/validation, protocol serialization/submission, and full delivery:

```bash
BENCH_MESSAGE_HISTORY=1 NRC_MESSAGE_BENCH_RECORDS=100000 \
NRC_MESSAGE_BENCH_CONTENT_BYTES=1024 NRC_MESSAGE_BENCH_HISTORY_ROUNDS=1000 \
odin test . -o:speed -define:NRC_SIMULATION=true \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_LOG_LEVEL=info \
  -define:ODIN_TEST_NAMES=main.benchmark_message_store_sealed_history
```

Profiling instrumentation is compiled only with `NRC_SIMULATION=true`; production builds do not pay
for timestamps or profile fields.
