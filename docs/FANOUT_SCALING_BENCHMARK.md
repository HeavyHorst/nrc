# Reproducible Fanout Worker Scaling

This runbook measures how NRC and the uWebSockets comparison server scale from one to two and four
fanout workers. It is intended for dedicated-hardware performance runs and future scheduled CI on a
dedicated runner. Shared CI hosts and Orbs are not valid for performance thresholds.

## Fixed-load scaling contract

Every topology uses:

- one workspace per protocol worker/event loop;
- 800 users per workspace (800, 1,600, and 3,200 total users);
- 10 conversations per workspace and 3 subscriptions per user;
- one jittered 128-byte message per user per second;
- a 75-second run with a 15-second ramp;
- fanout sampling every 100 received messages;
- traffic seed 11 and authentication enabled; and
- three non-profiled runs per implementation and topology, with alternating A/B order.

The 800-user point keeps each worker busy while retaining measured load-generator headroom through
four workers on the reference 8-core/16-thread runner. A 2,000-user/workspace trial was valid at one
and two workers but generator-limited at four workers: the minimum client-CPU idle fell to 0.3% for
NRC and 0.2% for uWebSockets. Such a run is invalid as a server-scaling result. If another machine
cannot sustain the standard point, record the failure and repeat the complete 1→2→4 series at a lower
fixed load per workspace; never reduce only one topology or implementation.

The generator assigns users round-robin to workspaces and uses a workspace-local user index for
conversation selection. At 800 users/workspace, 10 conversations, and 3 memberships/user, every
conversation has exactly 240 subscribers. The sender is excluded from counted `S_NewMessage`
fanout, so the expected value is 239 receives per send at every worker count.

NRC validates JWT signature and claims. The uWebSockets comparison checks that the authentication
header is present but does not validate it. Preserve and report this semantic difference.

## Why uWebSockets uses separate processes

uWebSockets pub/sub state belongs to one `uWS::App`. `UWS_THREAD_COUNT=2` or `4` creates independent
apps behind `SO_REUSEPORT`; it does not guarantee that all connections for a workspace reach the same
app. Such a run silently loses cross-loop fanout and is invalid.

Start one `UWS_THREAD_COUNT=1` process per workspace on a separate port and CPU. The Go generator's
`--servers` option maps workspace index `i` to endpoint `i`. NRC remains one process with one shared
service role and 1, 2, or 4 workers; all workspaces use its single endpoint.

This compares worker scaling, not equal total core count. NRC consumes one additional service core.
Report both per-worker throughput and total server cores/task-clock.

## Hardware requirements

The four-worker NRC topology needs at least:

- four physical worker cores;
- one separate physical NRC service/helper core; and
- enough separate physical load-generator cores to sustain all offered sends and fanout receives.

Ten or more physical cores are recommended. The reference 8-core machine was sufficient at the
800-user/workspace standard point, but not at 2,000. Do not place the generator on a server core or
its SMT sibling. A smaller machine may be used only if per-CPU telemetry proves generator headroom
and the limitation is recorded.

Capture `lscpu`, SMT sibling lists, governor/turbo state, kernel, steal time, background load, binary
hashes, source revisions, and the exact CPU masks. Use the same worker CPUs and client mask for both
implementations. Leave NRC's service core unused during uWebSockets runs so its architectural cost is
visible rather than hidden in the client budget.

Example for an 8-core/16-thread machine with SMT pairs `0-1,2-3,...,14-15`:

```text
worker/event-loop CPUs: 0,2,4,6
NRC service/helper CPU: 8
load-generator CPUs:    10-15
```

This example leaves only three physical load-generator cores and therefore requires especially
careful headroom validation. It is not automatically sufficient for the four-worker result.

## Build and verify

From a clean source revision:

```bash
# The capacity harness also requires Linux util-linux, iproute2, and sysstat
# commands: taskset, ss, mpstat, and pidstat.
odin build . -out:nrc-server -o:speed

cd benchmark
go test ./...
mkdir -p bin
go build -o bin/nrc-bench ./cmd/nrc-bench
go build -o bin/uwebsockets-bench ./cmd/uwebsockets-bench
cd uwebsockets
./build-server.sh
cd ../..

sha256sum nrc-server benchmark/bin/nrc-bench benchmark/bin/uwebsockets-bench \
  benchmark/uwebsockets/uwebsockets-bench-server
cat benchmark/uwebsockets/uwebsockets-bench-server.manifest.txt
```

Do not transfer a `-march=native` uWebSockets binary to a machine with a different ISA. Build on the
target or use an explicitly recorded portable target such as `-march=x86-64-v3` when AVX2 is part of
the runner contract.

## Automated case harness

[`run_fanout_capacity_case.sh`](../benchmark/run_fanout_capacity_case.sh) runs one fail-fast case and
retains commands, hashes, logs, JSON, affinity, pidstat, mpstat, and softirq evidence beneath
`.benchmark-results/fanout-capacity/`. It rejects overlapping server/client masks, client placement on
a server SMT sibling, invalid room occupancy, wrong TID affinity, protocol failures, stopped progress,
less than 98% ACK/fanout attainment, insufficient generator idle, and excessive steal.

The defaults reproduce the 24-core reference layout. Pin a different dedicated runner explicitly:

```bash
FANOUT_WORKER_CPUS=0,2,4,6 \
FANOUT_SERVICE_CPU=8 \
FANOUT_CLIENT_CPUS=10-47 \
FANOUT_EXPECTED_ONLINE_CPUS=0-47 \
FANOUT_EXPECTED_NUMA_NODES=0 \
benchmark/run_fanout_capacity_case.sh nrc 4 search-3000 1 3000
```

Optional `NRC_SERVER_BIN`, `NRC_BENCH_BIN`, `UWS_SERVER_BIN`, `UWS_BENCH_BIN`, and
`NRC_BENCH_DATA_DIR` override build/data paths. `FANOUT_EXPECTED_*_SHA256` variables make known binary
identity mandatory. `FANOUT_MIN_CLIENT_IDLE_PERCENT` defaults to 5 and
`FANOUT_MAX_CLIENT_STEAL_PERCENT` to 0.1.

[`reproduce_fanout_capacity_reference.sh`](../benchmark/reproduce_fanout_capacity_reference.sh)
alternates 18 runs at the conservative confirmed reference points. It is a regression/confirmation
series, not a fresh boundary search; improvements require repeating the documented search procedure.

The capacity-confirmation profile preserves the fixed-load protocol flags but uses the six
implementation/topology-specific loads recorded in the capacity table and reproduction script:
NRC 3,125/3,250/3,000 and uWebSockets 3,000/3,125/3,125 users/workspace for 1/2/4 workers.

## Server topology

Prepare a fresh current-format NRC data directory for every run. The server resolves `data/` relative
to its working directory.

For `N` workers, restrict NRC to the selected worker CPUs plus its service CPU, set
`NRC_THREAD_COUNT=N`, and set `NRC_SERVICE_CPU` explicitly. Verify every TID after startup:

```bash
NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret \
NRC_THREAD_COUNT="$N" NRC_SERVICE_CPU=8 \
taskset -c "$NRC_CPU_MASK" /absolute/path/to/nrc-server >nrc.log 2>&1 &
NRC_PID=$!

taskset -apc "$NRC_PID"
ps -L -o pid,tid,psr,comm -p "$NRC_PID"
```

For uWebSockets, start `N` independent processes, each pinned to one worker CPU and using a distinct
port. For two workers:

```bash
taskset -c 0 env PORT=8082 AUTH_ENABLED=1 UWS_THREAD_COUNT=1 \
  ./uwebsockets-bench-server >uws-0.log 2>&1 &
taskset -c 2 env PORT=8083 AUTH_ENABLED=1 UWS_THREAD_COUNT=1 \
  ./uwebsockets-bench-server >uws-1.log 2>&1 &
```

Require one successful `listening` line per process and verify each TID's affinity. Stop and reap all
servers between runs; do not leave inactive comparison servers consuming CPU or ports.

## Generator commands

NRC, two workers/workspaces and 1,600 users:

```bash
taskset -c 10-15 benchmark/bin/nrc-bench \
  --server=ws://127.0.0.1:8080 \
  --users=1600 --workspaces=2 \
  --conversations=10 --convs-per-user=3 \
  --duration=75s --ramp-up=15s \
  --msg-interval=1s --msg-size=128 \
  --fanout-sample-rate=100 --seed=11 --auth \
  --output=nrc-2w.json
```

uWebSockets, two loops/workspaces and 1,600 users:

```bash
taskset -c 10-15 benchmark/bin/uwebsockets-bench \
  --servers=ws://127.0.0.1:8082,ws://127.0.0.1:8083 \
  --users=1600 --workspaces=2 \
  --conversations=10 --convs-per-user=3 \
  --duration=75s --ramp-up=15s \
  --msg-interval=1s --msg-size=128 \
  --fanout-sample-rate=100 --seed=11 --auth \
  --output=uws-2w.json
```

For four workers, use 3,200 users, four workspaces, four uWebSockets endpoints, and worker CPUs
`0,2,4,6`. For one worker, use 800 users and one workspace. Keep every other flag unchanged.

## Generator and run validity

Capture `mpstat -P ALL 1` and per-process/per-TID `pidstat` throughout every measured run. A result is
valid only when:

- all requested clients connect and subscriptions fit `MAX_ROOM_USERS`;
- failed connections, steady-state errors, and steady-state disconnects are zero;
- sent and acknowledged messages continue progressing;
- post-ramp fanout deliveries match the deterministic expected fanout within the declared tolerance;
- no load-generator CPU is saturated for sustained intervals and aggregate generator CPU retains
  documented headroom;
- server and client TIDs stay on their assigned CPU masks;
- CPU steal, thermal throttling, or unrelated load does not invalidate the run; and
- the full 75 seconds complete and raw JSON/logs are retained.

Teardown errors are recorded separately. A final server stats response is one connection's final
snapshot, not a worker-wide queue-depth time series.

## Report scaling

For each implementation and topology report medians and ranges across all three runs:

- sent and acknowledged messages/s;
- run-wide and post-ramp fanout deliveries/s;
- ACK and fanout p50/p95/p99;
- failed connections, steady-state and teardown errors/disconnects;
- CPU/task-clock per server TID and aggregate server core use;
- generator CPU, per-client-CPU idle/softirq, and steal time; and
- actual TID affinity.

For metric `M`, calculate scaling and parallel efficiency relative to the one-worker result:

```text
scaling(N)   = M(N) / M(1)
efficiency(N) = scaling(N) / N
```

Do not call offered-load scaling a server capacity gain unless the server is busy and generator
headroom is proven. Do not compare p99 from a profiled run with non-profiled results.

## Reference result

The following medians come from three alternating, non-profiled runs on the dedicated-core
8-core/16-thread KVM runner described above. All 18 runs had zero failed connections, runtime errors,
steady-state disconnects, and teardown errors; steal was 0%. Minimum client-CPU idle at four workers
was 12.3% for NRC and 8.8% for uWebSockets.

| Server | Workers | Users | Sent/s | Fanout/s run-wide | Fanout/s post-ramp | ACK p99 | Fanout p99 |
|---|---:|---:|---:|---:|---:|---:|---:|
| NRC | 1 | 800 | 720.7 | 165,656 | 190,856 | 16.00 ms | 9.48 ms |
| NRC | 2 | 1,600 | 1,445.4 | 332,253 | 383,808 | 15.60 ms | 9.34 ms |
| NRC | 4 | 3,200 | 2,882.4 | 662,441 | 763,957 | 17.73 ms | 11.59 ms |
| uWebSockets | 1 | 800 | 720.7 | 165,678 | 190,907 | 5.72 ms | 5.85 ms |
| uWebSockets | 2 | 1,600 | 1,445.4 | 332,303 | 383,791 | 5.43 ms | 5.55 ms |
| uWebSockets | 4 | 3,200 | 2,882.4 | 662,523 | 763,789 | 8.06 ms | 8.78 ms |

NRC's four-worker run-wide fanout factor was 3.999× and its post-ramp factor 4.003×. uWebSockets
measured 3.999× and 4.001× respectively. These are offered-load scaling ratios, not maximum-capacity
efficiencies: every topology held the configured load, but its stable capacity frontier was not
reached. NRC uses `N+1` assigned server cores because its service role is separate; uWebSockets uses
`N` isolated loop cores. Observed receives/send remained 238.89–239.18 across both implementations
and all topologies, confirming constant workspace-local fanout.

## Capacity-scaling reference

A separate capacity search ran after resizing the dedicated runner to 24 physical SMT cores
(48 vCPUs), with 19 physical cores reserved for the load generator. It searched in users/workspace
from 3,000 in 250-user steps plus one 125-user intermediate. Every selected capacity point passed
three independent 75-second runs; the next stage was unstable. At four workers the least-idle
load-generator CPU retained a median 42.1% idle for NRC and 33.1% for uWebSockets, with 0% steal, so
these are server rather than generator boundaries.

| Server | Workers | Highest stable users/workspace | Total users | First unstable users/workspace | Post-ramp fanout/s | Fanout p99 |
|---|---:|---:|---:|---:|---:|---:|
| NRC | 1 | 3,125 | 3,125 | 3,250 | 2,919,064 | 129.6 ms |
| NRC | 2 | 3,250 | 6,500 | 3,375 | 6,322,394 | 146.4 ms |
| NRC | 4 | 3,000 | 12,000 | 3,125 | 10,761,248 | 109.2 ms |
| uWebSockets | 1 | 3,000 | 3,000 | 3,125 | 2,679,532 | 53.2 ms |
| uWebSockets | 2 | 3,125 | 6,250 | 3,250 | 5,814,998 | 49.4 ms |
| uWebSockets | 4 | 3,125 | 12,500 | 3,250 | 11,609,346 | 66.8 ms |

NRC's total-user capacity factors were 1×→2.080×→3.840×; its post-ramp fanout-capacity factors were
1×→2.166×→3.687×, giving four-worker efficiencies of 96.0% and 92.2%. uWebSockets measured
1×→2.083×→4.167× users and 1×→2.170×→4.333× fanout. Values above 100% are not superlinear
fixed-load speedups: the independently measured per-workspace boundary was higher at two/four loops
than at one loop.

All 18 selected runs had zero failed connections, runtime errors, and steady-state disconnects, and
maintained at least 98% exact offered ACK/fanout. Confirmation disqualified initially passing NRC
points at 1W/3,250 and 4W/3,125 after fresh runs produced steady-state disconnects; the table therefore
uses the lower conservative 3/3-stable points. Capacity remains specific to this 75-second workload.
In particular, uWebSockets ACK p99 reached 415–690 ms at its selected boundaries.

The tested capacity topology used worker/loop CPUs `0,2,4,6`, NRC service CPU `8`, excluded SMT
siblings `1,3,5,7,9`, and load-generator CPUs `10-47`, all in one NUMA node. NRC's service/helper CPU
used only 0.47–0.99% CPU but still occupied a separate physical core. Reproducing the four-worker
capacity boundary requires five isolated NRC server cores plus enough separate generator cores to
prove at least 5% idle on every load-generator CPU; the tested allocation used 19.

## Scheduled dedicated CI

Run the benchmark procedure on a labeled, dedicated runner with exclusive CPU ownership; never on a
general shared GitHub-hosted runner. Use two separate CI tiers:

- a shorter fixed-load regression series at 800 users/workspace, which detects throughput, latency,
  correctness, and coordination regressions but does not measure maximum capacity; and
- a less frequent capacity search or confirmation series on the 24-core class runner, which detects
  changes to the stable 1/2/4-worker frontier.

A scheduled job should:

1. verify a known machine identity and exact CPU topology;
2. fail before measurement if the worktree, governor, affinity, ports, or background-load preconditions
   differ;
3. build and hash every binary;
4. perform one unreported warm-up, then three alternating measured runs per topology;
5. validate every raw result before calculating aggregates;
6. upload commands, environment, logs, JSON, CPU telemetry, hashes, and summary as immutable artifacts;
7. compare against a rolling baseline from the same machine and configuration; and
8. flag regressions for review rather than automatically rewriting the baseline.

Establish noise bounds from repeated unchanged builds before choosing thresholds. Use a minimum
absolute and relative threshold, and require a repeated regression across multiple runs; a single p99
outlier or low-single-digit throughput delta is not a reliable failure signal. Keep functional smoke
tests separate from scheduled performance gates.
