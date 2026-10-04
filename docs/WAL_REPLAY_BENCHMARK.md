# WAL replay benchmark

`wal_replay_benchmark.odin` measures the production
`init_active_sharded_worker_persistence` path. It uses real files and pins each
worker to a CPU. `benchmark/wal_replay.py` runs ten separate processes for each
configuration. It checks each run and saves logs, samples and setup times.
Its summaries show the median, minimum and maximum.

## Workload and timing

- The default workload creates 524288 entities. Each transaction contains one
  mutation. Each of the 256 logical shards has 2048 records and one workspace
  with one conversation. Records use `WORKSPACE_DATA_ID`, not a legacy room ID.
- Tasks have 1 KiB descriptions. Assets are Documents with 1 KiB plain payloads.
  Mixed alternates Tasks and Assets in equal numbers. The generator does not
  create edges, attachments, updates, deletes, checkpoint files or catalog files.
- Uniform tasks have Todo status and the same priority. Their timestamps
  increase with IDs. The varied fixture keeps IDs in ascending order. It cycles
  four statuses and five priorities. Update and completion times are not in
  ascending order. Use this fixture to evaluate index construction. ID order
  does not guarantee index-key order.
- Default WAL sizes are 663748608 bytes for Tasks, 629669888 for Assets and
  646709248 for Mixed. One operation means one entity create replayed. WAL MB/s
  counts serialized bytes once, including headers and metadata. One MB is
  1000000 bytes. This rate does not measure physical disk bandwidth.
- The timer includes writer opening, validation, recovery and append-state
  restoration. It also includes entity and index construction, final edge
  checks and sequence floors. Recovery validates and applies each WAL once.
- The timer starts after all workers reach a shared gate. It stops when the last
  worker finishes persistence initialization. It excludes thread creation,
  initial heap and page setup, clock calibration, fixture generation,
  verification and cleanup. It includes heap growth during replay.
- `REPLAY_SETUP` reports total setup time and the longest worker clock setup.
  These times overlap. Do not add them. Setup + replay does not measure server
  startup. Real I/O setup, retained-message initialization and network readiness
  differ from this benchmark.
- After timing, verification checks ownership, counts, fields and every payload
  byte. It checks time and priority indexes against independently sorted keys.
  Do not accept a failed run as a throughput sample.
- Each worker owns separate shards. Each shard replays records in sequence.
  The benchmark selects physical-core primary threads before SMT siblings.
  Each worker commits an initial 64 MiB heap before timing. More workers move
  more memory commitment into setup. Total committed memory is not constant
  across worker counts.

## Reproduce

Build the benchmark once. Wait for the compiler to exit. Then generate new,
disposable fixtures. During timing, do not run builds, tests, other benchmarks
or profiles. Select worker counts that fit the allowed CPUs. Include one worker
as the baseline. The runner supports up to sixteen workers.

```sh
set -eu
mkdir -p /tmp/nrc-replay
odin build . -build-mode:test -o:speed \
  -define:ODIN_TEST_THREADS=1 -define:ODIN_TEST_TRACK_MEMORY=false \
  -define:ODIN_TEST_NAMES=benchmark_wal_replay \
  -out:/tmp/nrc-replay/bench
export NRC_REPLAY_BENCH_PER_SHARD=2048
export NRC_REPLAY_BENCH_PAYLOAD_BYTES=1024
export NRC_REPLAY_BENCH_VARIED=0
for kind in task asset mixed; do
  NRC_REPLAY_BENCH_DIR=/tmp/nrc-replay/$kind \
  NRC_REPLAY_BENCH_KIND=$kind NRC_REPLAY_BENCH_MODE=generate \
    /tmp/nrc-replay/bench
done
amp orb service start wal-replay-bench --command \
  "env NRC_REPLAY_BENCH_PER_SHARD=$NRC_REPLAY_BENCH_PER_SHARD \
  NRC_REPLAY_BENCH_PAYLOAD_BYTES=$NRC_REPLAY_BENCH_PAYLOAD_BYTES \
  NRC_REPLAY_BENCH_VARIED=$NRC_REPLAY_BENCH_VARIED \
  NRC_REPLAY_BENCH_ALLOCATOR=worker NRC_REPLAY_BENCH_WORKER_COUNTS='1 4 8' \
  python3 '$PWD/benchmark/wal_replay.py' /tmp/nrc-replay/bench \
  /tmp/nrc-replay /tmp/nrc-replay/results; exec sleep infinity"
amp orb service logs wal-replay-bench
# Stop after successful completion and summary.json creation.
amp orb service stop wal-replay-bench
```

After success or failure, the supervised command waits until you stop it.
This prevents automatic restarts from repeating the campaign. Outside an orb,
run the Python command directly. Use new fixture and result directories.
The generator and runner reject existing destinations. If a run fails, inspect
its log.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NRC_REPLAY_BENCH_KIND` | required | `task`, `asset`, `mixed` |
| `NRC_REPLAY_BENCH_MODE` | replay | `generate` builds fixtures; `replay` reads them |
| `NRC_REPLAY_BENCH_PER_SHARD` | 2048 | Positive even record count; 20480 gives 10× data |
| `NRC_REPLAY_BENCH_PAYLOAD_BYTES` | 1024 | Positive payload length |
| `NRC_REPLAY_BENCH_VARIED` | 0 | Set 1 for varied task index fields |
| `NRC_REPLAY_BENCH_ALLOCATOR` | worker | Production growing TLSF; `heap`/`tlsf` are historical controls |
| `NRC_REPLAY_BENCH_WORKER_COUNTS` | 1 2 4 8 16 | Python runner matrix; must include 1 |

Use the same dimensions and variation for generation and replay. For a large
varied run, set `NRC_REPLAY_BENCH_PER_SHARD=20480` and
`NRC_REPLAY_BENCH_VARIED=1` before generation. For an A/B comparison, use the same
benchmark code and data in both binaries. Alternate the binary order between
repetitions. Keep every completed sample. Report the median and the spread,
not the best run.

## Storage and profiling controls

Reads use aligned `O_DIRECT`. If the filesystem does not support direct I/O,
recovery fails. Reads bypass the Linux page cache. Device and hypervisor caches
can still contain data from earlier reads.

For a RAM-backed storage comparison, use ext4 on a tmpfs-backed loop image.
Do not use plain tmpfs: it rejected direct I/O on the measured Linux 6.1 orb.
Run one storage campaign at a time. Provide enough RAM for fixtures and state.

```sh
set -eu
# Fresh owned image/device only. Size for the selected fixtures and filesystem.
test ! -e /dev/shm/nrc-replay.img
truncate -s 12G /dev/shm/nrc-replay.img
sudo /usr/sbin/mkfs.ext4 -q -F -m 0 \
  -E lazy_itable_init=0,lazy_journal_init=0 /dev/shm/nrc-replay.img
loop=$(sudo /usr/sbin/losetup --find --show /dev/shm/nrc-replay.img)
mkdir /tmp/nrc-replay-ramdisk
sudo mount "$loop" /tmp/nrc-replay-ramdisk
sudo chown "$(id -u):$(id -g)" /tmp/nrc-replay-ramdisk
# Generate fixtures here; pass this root as the Python runner's second argument.
# After the campaign stops and results are exported:
sudo umount /tmp/nrc-replay-ramdisk
sudo /usr/sbin/losetup -d "$loop"
rm /dev/shm/nrc-replay.img
```

The three default fixtures use approximately 1.94 GB, excluding filesystem
metadata. A 10× Mixed fixture uses approximately 6.47 GB. RAM-backed ext4 still
includes filesystem, loop-device, blocking I/O and scheduling costs. It is not
a CPU-only measurement. It does not provide the durability of physical storage.

Optional perf FIFO gates exclude setup, verification and cleanup. Set both FIFO
variables only when a compatible perf process handles their acknowledgements.
Use the same dimensions and variation as generation. This example uses defaults:

```sh
set -eu
mkfifo /tmp/nrc-replay/control /tmp/nrc-replay/ack
sudo env NRC_REPLAY_BENCH_DIR=/tmp/nrc-replay/mixed \
  NRC_REPLAY_BENCH_KIND=mixed NRC_REPLAY_BENCH_WORKERS=8 \
  NRC_REPLAY_BENCH_PER_SHARD=2048 NRC_REPLAY_BENCH_PAYLOAD_BYTES=1024 \
  NRC_REPLAY_BENCH_VARIED=0 NRC_REPLAY_BENCH_ALLOCATOR=worker \
  NRC_REPLAY_BENCH_PERF_CONTROL=/tmp/nrc-replay/control \
  NRC_REPLAY_BENCH_PERF_ACK=/tmp/nrc-replay/ack \
  perf record --delay=-1 \
  --control=fifo:/tmp/nrc-replay/control,/tmp/nrc-replay/ack \
  -e cpu-clock -F 199 --call-graph dwarf \
  -o /tmp/nrc-replay/profile.data -- /tmp/nrc-replay/bench
sudo perf report -i /tmp/nrc-replay/profile.data --stdio --children
rm /tmp/nrc-replay/control /tmp/nrc-replay/ack
```

Use the same gates with `perf stat -e task-clock,context-switches,page-faults`.
CPU sample shares are not wall-time percentages. Inclusive stack costs overlap.
For example, fault handling includes page zeroing. Process CPU totals include
the test harness. They exclude storage work charged outside the process.

## Reference measurements: 2026-10-04

Production uses the single-pass recovery from
[48a2fd3](https://github.com/HeavyHorst/nrc/commit/48a2fd35b9e8da96b1dd41fcc0d4d6673679c674),
measured against [26c8503](https://github.com/HeavyHorst/nrc/commit/26c8503efc491e17310f500be24b55a8c08edbaa).
The varied fixture and stronger verification are in
[588a20f](https://github.com/HeavyHorst/nrc/commit/588a20fe151f60576cf6c5cdb826199add9a0ed8).
The retained implementation has no FD-table preallocation or huge-page hint.

The runs used Odin `dev-2026-09-nightly:a2fb372` with optimized default-target
builds and memory tracking disabled. The KVM orb ran Linux 6.1.158+. It exposed
eight physical cores and sixteen logical CPUs, with 31 GiB RAM and no swap.
Storage was RAM-backed ext4 with `O_DIRECT`. Hardware PMU and governor controls
were unavailable. Host scheduling and power policy were uncontrolled.

Each table cell represents ten independent processes. Do not combine absolute
times from separate campaigns into an A/B result. These are not cold
physical-disk rates.

Single-pass uniform corpus, 524288 records, median seconds:

| Kind | 1 worker | 4 workers | 8 workers | 1→8 speedup | 8-worker records/s | 8-worker WAL MB/s |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Tasks | 2.351 | 0.731 | 0.450 | 5.22× | 1164496 | 1474.3 |
| Assets | 1.715 | 0.525 | 0.374 | 4.58× | 1401344 | 1683.0 |
| Mixed | 2.023 | 0.616 | 0.375 | 5.40× | 1399670 | 1726.5 |

Eight-worker replay improved 27–34% against its paired baseline. With 10× Mixed
(5242880 records / 6467092480 WAL bytes), replay improved from 4.798 to 2.871 s
(40.2%). Throughput reached 1826199 records/s / 2252.6 MB/s. A separate startup
measurement improved from 9.143 to 7.379 s (19.3%), from launch to listener
readiness. Listener RSS stayed approximately 7874 MiB. Filesystem backing used
additional RAM.

Later ID-sorted, varied-field large Mixed campaign, eight workers:

| Insertion | Median replay, s | Min–max, s | Records/s | WAL MB/s |
| --- | ---: | ---: | ---: | ---: |
| Ordinary B-tree set | 3.352239 | 3.318558–3.646109 | 1563994 | 1929.2 |
| Replay-only B-tree load | 3.377904 | 3.305169–3.528109 | 1552110 | 1914.5 |

The candidate won only 3/10 pairs. Its median paired loss was 34.35 ms.
The spreads overlap, so they do not establish a reliable regression.
The results show no repeatable wall-time benefit. Production keeps ordinary
insertion.

## Conclusions and limits

- **Keep worker-local growing TLSF and write-first prefaulting.** They avoid
  the earlier libc allocation/mmap contention and shared-zero-page COW path.
  Prefaulting commits unused pool tails earlier. Allocation still has a cost.
- **Keep single-pass recovery and prefix-floor reuse.** Recovery still checks
  checksums, SHA chains, transactions, origins and final edge endpoints.
  Active-tail recovery still requires truncate and sync. If startup fails,
  it discards unpublished worker state.
- **Reject huge-page advice as a default.** It greatly reduced measured faults.
  Its extra startup benefit was small and noisy. Growth latency under memory
  pressure was not measured. FD preallocation was also rejected.
- **Reject payload pre-zeroing removal and replay-only sorted insertion.**
  Zeroing removal showed no meaningful gain. Sorted insertion helped the uniform
  fixture, but showed no repeatable benefit with varied index keys.
- **Do not use early timings as isolated replay rates.** Those timings included
  overlapping two-second TSC calibration sleeps on each worker. We did not
  correct them by subtraction.
- **Scaling depends on the workload.** One workspace belongs to one shard.
  Uneven shard sizes, compressed assets, rich metadata, edges and repeated
  updates can change the result. ID-sorted active records emulate checkpoint
  order. They do not measure literal checkpoint files. Current evidence does
  not establish an allocator mutex, shared SHA lock or DRAM-bandwidth ceiling
  as the sole cause of non-linear scaling.

## Historical journal and raw evidence

The published
[588a20f revision](https://github.com/HeavyHorst/nrc/blob/588a20fe151f60576cf6c5cdb826199add9a0ed8/docs/WAL_REPLAY_BENCHMARK.md)
preserves the full journal, detailed tables, corrections and artifact inventory.
Use it as the durable reference for earlier campaigns. Do not label those
results as measurements of the current binary.

The measurement orb contains exported logs, JSON samples, profiles, hashes and
scripts under `.amp/in/artifacts/wal-replay-*/`. These ignored exports are not
in Git. Another checkout might not contain them. If you need raw evidence,
copy the exports to durable storage before you retire the orb.
For each new result, record source and binary revisions, fixture dimensions,
storage and cache state, CPU affinity, compiler flags and warmup policy.
