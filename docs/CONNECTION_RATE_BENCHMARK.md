# Reproducible Connection-Rate Benchmark

This runbook measures completed WebSocket connection lifecycles per second and compares two server
binaries with a direction-balanced paired design. Use dedicated hardware for publishable numbers.
Virtualized or shared hosts are useful for smoke tests, but CPU steal and noisy neighbours can easily
exceed the effect being measured.

This is not the steady-state chat benchmark in
[`SINGLE_CORE_BENCHMARK.md`](SINGLE_CORE_BENCHMARK.md). Each successful operation here performs:

1. TCP connect and WebSocket HTTP upgrade.
2. `X-NRC-Auth` JWT/header authentication.
3. Wait for the first `S_ServerReady` frame.
4. Send a normal WebSocket close frame and receive the peer's normal close response.
5. Close the TCP connection and immediately begin the next operation.

The generator creates one valid HS256 JWT before each run and reuses that token for all connections
in the run; NRC still parses and verifies it on every upgrade. Connection loop `i` always uses
workspace `connrate-(i mod workspace_count)`, so routing input is deterministic.

Both profiles use 128 concurrent connection loops, 48 workspace names, a 15-second warm-up
per binary, four measured A/B pairs of 30 seconds, and zero tolerated dial or `ServerReady` failures.
Odd pairs run A then B; even pairs run B then A. The reported comparison is the geometric mean of the
four per-pair throughput ratios `B/A`, not a ratio between unrelated headline medians.

Keep these profiles separate in reports:

| Profile | NRC topology | uWebSockets topology | Question answered |
|---|---|---|---|
| `equal-one-cpu` | Service/accept and one worker share one logical CPU | One event loop on that CPU | Efficiency per CPU |
| `production-two-cpu` | One service/accept core plus one worker core | Two event loops, one per core | Throughput with the same two-core budget |

The second profile is equal in total CPU budget, not architecture: NRC pipelines accept/routing into
one worker, while Linux distributes connections between two independent uWebSockets listen sockets.
Never compare a number from one profile with a number from the other.

## Architecture interpretation and sizing

`NRC_THREAD_COUNT` is the number of workspace workers, not the process's total CPU budget. When at
least two physical cores are available, NRC reserves one physical core for the service role and puts
workers on other physical cores before using SMT siblings. The service role accepts sockets, receives
enough HTTP to route by workspace, and hands an owned request to the selected worker. That worker
validates JWT and WebSocket upgrade data, sends `101` plus `ServerReady`, and retains ownership of the
connection, workspace state, subscriptions, and persistence I/O.

This split is intentional. Stable workspace ownership preserves ordering and keeps room/task state,
WAL activity, and backpressure on one worker without cross-loop synchronization. It is designed for
the complete long-lived NRC workload, not solely to maximize churn of short connections. A
uWebSockets process with two loops instead runs two complete accept-to-close pipelines. Consequently,
the `production-two-cpu` profile gives both processes two cores but gives uWebSockets two protocol
loops versus NRC's one protocol worker plus one service role.

Profiling NRC `4c9aa27` against uWebSockets `66dcff3` on a low-load 16-vCPU/8-core KVM runner
illustrated the distinction. The strict C128/48-workspace lifecycle completed with zero failures;
scaling medians below use two runs per configuration. These are diagnostic measurements, not portable
capacity claims:

| Configuration | Median completed connections/s | Scaling |
|---|---:|---:|
| NRC: service + 1 worker (2 physical cores) | 25,991 | baseline |
| NRC: service + 2 workers (3 physical cores) | 46,704 | +79.7% |
| uWebSockets: 1 complete loop (1 physical core) | 27,169 | baseline |
| uWebSockets: 2 complete loops (2 physical cores) | 52,035 | +91.5% |

With one worker, NRC's worker consumed about 96% CPU while the service role consumed about 30%; the
unused service capacity cannot execute workspace-owned protocol work. Both uWebSockets loops consumed
about 97–99% CPU. Comparing one protocol worker with one uWebSockets loop left only a 4.5% throughput
difference, while comparing the equal two-core budgets produced the expected near-2x gap. Adding a
second NRC worker recovered 79.7% without changing the ownership model. Disabling NRC's internal
affinity on the same two-core mask changed throughput by only -1.1%, so fixed pinning was not the
bottleneck.

The profile also found real residual per-connection overhead in NRC: approximately 2.0x the retired
instructions and 14.6x the context switches per success in that KVM environment. NRC performs full
HS256 JWT validation while the comparison server checks only header presence. Service-to-worker
eventfd notifications were already coalesced at roughly one write per 82 handoffs, so wakeup batching
was not the primary limit. Treat those counters as optimization guidance, not as a reason to remove
the service/worker boundary.

For deployment and reporting:

1. Budget approximately one service core plus `NRC_THREAD_COUNT` worker cores when physical cores are
   available. A single-core machine remains supported by sharing that CPU.
2. Add workers for workspace-parallel throughput; do not count the service core as a protocol worker.
3. Keep the topology-aware affinity enabled unless a controlled measurement proves otherwise on the
   target host.
4. Use the steady-state chat/task benchmarks for production capacity decisions. The connection-rate
   profile is deliberately a short-connection stress test.
5. Report worker/loop counts and total physical cores together with every headline.

## Hardware and operating-system requirements

Use a bare-metal machine reserved for the benchmark. Record firmware and kernel changes with the
results. Before a series:

1. Disable or pin unrelated services, IRQs, and housekeeping work away from benchmark CPUs.
2. Select one physical core for `equal-one-cpu`, or two distinct physical cores for
   `production-two-cpu`. Exclude those logical CPUs and every SMT sibling from the generator mask.
3. Use the same server CPU and client CPU mask for both binaries.
4. Fix the CPU governor and turbo policy for the whole series. Do not change them between A and B.
5. Keep power, cooling, kernel, sysctls, compiler versions, and mitigations constant.
6. Raise file-descriptor limits and ensure the ephemeral-port range and TIME_WAIT policy support the
   target rate. Record, rather than silently change, the active values.

The comparison runner rejects overlapping server/client CPU masks, including SMT siblings, records
CPU topology and frequency policy, verifies the running executable hashes, and stores every raw run.
It cannot detect thermal throttling, IRQ migration, SMI activity, or an unrecorded firmware change;
monitor those externally.

Before comparing different binaries on a new host, run one complete null series with the same binary
as A and B. Predeclare the maximum acceptable null bias and pair dispersion based on the smallest
effect the machine must resolve. If the identical-binary series exceeds that budget, fix the host or
increase isolation before interpreting a real A/B series; do not subtract the observed bias afterward.

Record these host values before changing any benchmark setting:

```bash
uname -a
lscpu
lscpu -e=CPU,CORE,SOCKET,NODE,MAXMHZ,MINMHZ,ONLINE
cat /proc/cmdline
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
cat /proc/interrupts
sysctl net.core.somaxconn net.ipv4.tcp_max_syn_backlog \
  net.ipv4.ip_local_port_range net.ipv4.tcp_tw_reuse net.ipv4.tcp_fin_timeout
ulimit -n
```

## Build the generator

The paired runner builds the generator itself with `-trimpath` and records its SHA-256. A standalone
build is useful for a smoke test:

```bash
cd benchmark
go build -trimpath -o /tmp/connection-rate-bench ./cmd/connection-rate-bench

/tmp/connection-rate-bench \
  --server=ws://127.0.0.1:18080 \
  --label=smoke \
  --concurrency=128 \
  --workspaces=48 \
  --duration=3s \
  --auth=true \
  --websocket-close=true \
  --require-zero-failures=true \
  --output=/tmp/connection-rate-smoke.json
```

NRC validates the JWT signature and claims. The uWebSockets comparison server currently checks only
that `X-NRC-Auth` is present. Preserve that semantic difference in every report.

## Prepare two NRC revisions

Build each revision from a clean detached worktree. The example compares `REV_A` with `REV_B`:

```bash
REPO=/absolute/path/to/nrc
REV_A=<full-git-sha-a>
REV_B=<full-git-sha-b>
SERIES=/srv/nrc-connection-rate/$(date -u +%Y%m%dT%H%M%SZ)

mkdir -p "$SERIES"
git -C "$REPO" worktree add --detach "$SERIES/source-a" "$REV_A"
git -C "$REPO" worktree add --detach "$SERIES/source-b" "$REV_B"

(cd "$SERIES/source-a" && odin build . -o:speed -out:"$SERIES/server-a")
(cd "$SERIES/source-b" && odin build . -o:speed -out:"$SERIES/server-b")

sha256sum "$SERIES/server-a" "$SERIES/server-b"
git -C "$SERIES/source-a" status --short
git -C "$SERIES/source-b" status --short
```

Create separate working directories so the servers never share persistence files:

```bash
mkdir -p "$SERIES/install-a" "$SERIES/install-b"
```

For the standard equal-CPU-budget comparison, pin the complete NRC process—including accept/service
and worker threads—to one logical CPU and disable NRC's internal affinity selection. Both binaries use
the same CPU at different times; the runner pauses the inactive process with `SIGSTOP`.

```bash
SERVER_CPU=2
CLIENT_CPUS=4-15
ulimit -n 1000000

(
  cd "$SERIES/install-a"
  exec env NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret \
    NRC_THREAD_COUNT=1 NRC_DISABLE_CPU_AFFINITY=1 NRC_PORT=18080 \
    taskset -c "$SERVER_CPU" "$SERIES/server-a"
) >"$SERIES/server-a.log" 2>&1 &
A_PID=$!

(
  cd "$SERIES/install-b"
  exec env NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret \
    NRC_THREAD_COUNT=1 NRC_DISABLE_CPU_AFFINITY=1 NRC_PORT=18081 \
    taskset -c "$SERVER_CPU" "$SERIES/server-b"
) >"$SERIES/server-b.log" 2>&1 &
B_PID=$!

grep 'running with thread_count' "$SERIES"/server-*.log
taskset -pc "$A_PID"
taskset -pc "$B_PID"
ps -L -o pid,tid,psr,comm -p "$A_PID,$B_PID"
```

Do not combine results from this equal-one-CPU profile with NRC's production topology, where a
single worker can use a separate service core. Production-topology scaling is a different benchmark
and must be labeled with its complete CPU budget.

## Run the paired comparison

Run from the repository containing the comparison runner. The output directory must not exist:

```bash
RESULTS="$SERIES/results"

"$REPO/benchmark/run_connection_rate_comparison.sh" \
  --a-url=ws://127.0.0.1:18080 \
  --a-label="$REV_A" \
  --a-pid="$A_PID" \
  --a-binary="$SERIES/server-a" \
  --a-source-id="$REV_A" \
  --a-topology=nrc-one-worker \
  --b-url=ws://127.0.0.1:18081 \
  --b-label="$REV_B" \
  --b-pid="$B_PID" \
  --b-binary="$SERIES/server-b" \
  --b-source-id="$REV_B" \
  --b-topology=nrc-one-worker \
  --server-cpus="$SERVER_CPU" \
  --client-cpus="$CLIENT_CPUS" \
  --profile=equal-one-cpu \
  --concurrency=128 \
  --workspaces=48 \
  --warmup=15s \
  --duration=30s \
  --pairs=4 \
  --out-dir="$RESULTS"
```

The runner verifies both PID-to-binary hashes, distinct numeric-loopback endpoints, exclusive listener
ownership, immutable source IDs, declared runtime topology, and CPU masks before measuring. It keeps
both listening processes alive, but only one runnable at a time. Its exit trap uses pidfds to resume
only the original processes after success, failure, SIGINT, or SIGTERM.

Stop servers cleanly after the series:

```bash
kill -INT "$A_PID" "$B_PID"
wait "$A_PID" "$B_PID"
```

## Compare NRC with uWebSockets

The uWebSockets build is pinned by default to the revision recorded in
[`build-server.sh`](../benchmark/uwebsockets/build-server.sh). Override `UWS_REVISION` only when the
new revision is part of the benchmark identity:

```bash
cd "$REPO"
benchmark/uwebsockets/build-server.sh
sha256sum benchmark/uwebsockets/uwebsockets-bench-server
cat benchmark/uwebsockets/uwebsockets-bench-server.manifest.txt
git -C benchmark/uwebsockets/.deps/uWebSockets rev-parse HEAD \
  | tee "$SERIES/uwebsockets-source-revision.txt"
```

For `equal-one-cpu`, start one event loop on the same `SERVER_CPU` and use its real PID and binary as
side B:

```bash
PORT=18082 AUTH_ENABLED=1 UWS_THREAD_COUNT=1 taskset -c "$SERVER_CPU" \
  "$REPO/benchmark/uwebsockets/uwebsockets-bench-server" \
  >"$SERIES/uwebsockets.log" 2>&1 &
UWS_PID=$!
```

Then invoke the same paired runner with NRC as A and uWebSockets as B. Do not use the managed
`--start-server` modes for controlled measurements because they do not establish the required CPU,
working-directory, binary-hash, and lifecycle invariants. Declare `--b-topology=uws-one-loop`, pass
the pinned uWebSockets SHA as `--b-source-id`, and pass
`--b-build-manifest=benchmark/uwebsockets/uwebsockets-bench-server.manifest.txt`.

## Run the production two-core profile

Choose two logical CPUs from different physical cores. Start NRC with one worker and its normal
topology-aware affinity enabled; explicitly identify the service core so the role assignment is part
of the recorded setup:

```bash
SERVICE_CPU=2
WORKER_CPU=3
SERVER_CPUS="$SERVICE_CPU,$WORKER_CPU"
CLIENT_CPUS=4-15

(
  cd "$SERIES/install-a"
  exec env NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret \
    NRC_THREAD_COUNT=1 NRC_SERVICE_CPU="$SERVICE_CPU" NRC_PORT=18080 \
    taskset -c "$SERVER_CPUS" "$SERIES/server-a"
) >"$SERIES/server-a-production.log" 2>&1 &
NRC_PID=$!
```

Start uWebSockets with two independent apps/event loops. uSockets gives each loop a listen socket on
the same port using `SO_REUSEPORT`. Pin the two loop threads individually so neither loop migrates
between the two benchmark cores; the main thread only waits in `join()`:

```bash
PORT=18082 AUTH_ENABLED=1 UWS_THREAD_COUNT=2 taskset -c "$SERVER_CPUS" \
  "$REPO/benchmark/uwebsockets/uwebsockets-bench-server" \
  >"$SERIES/uwebsockets-production.log" 2>&1 &
UWS_PID=$!

for _ in {1..100}; do
  mapfile -t UWS_WORKER_TIDS < <(
    find "/proc/$UWS_PID/task" -mindepth 1 -maxdepth 1 -printf '%f\n' | grep -vx "$UWS_PID" | sort -n
  )
  [[ "${#UWS_WORKER_TIDS[@]}" -eq 2 ]] && break
  sleep 0.05
done
[[ "${#UWS_WORKER_TIDS[@]}" -eq 2 ]]
taskset -pc "$SERVICE_CPU" "${UWS_WORKER_TIDS[0]}"
taskset -pc "$WORKER_CPU" "${UWS_WORKER_TIDS[1]}"
[[ "$(grep -c 'listening on' "$SERIES/uwebsockets-production.log")" -eq 2 ]]
```

Invoke the paired runner with these PIDs and `--profile=production-two-cpu`:

```bash
"$REPO/benchmark/run_connection_rate_comparison.sh" \
  --a-url=ws://127.0.0.1:18080 --a-label=nrc-production \
  --a-pid="$NRC_PID" --a-binary="$SERIES/server-a" \
  --a-source-id="$REV_A" --a-topology=nrc-one-worker \
  --b-url=ws://127.0.0.1:18082 --b-label=uwebsockets-two-loop \
  --b-pid="$UWS_PID" --b-binary="$REPO/benchmark/uwebsockets/uwebsockets-bench-server" \
  --b-source-id=66dcff3dd48f0c19dd1703426365d062039321d0 --b-topology=uws-two-loop \
  --b-build-manifest="$REPO/benchmark/uwebsockets/uwebsockets-bench-server.manifest.txt" \
  --server-cpus="$SERVER_CPUS" --client-cpus="$CLIENT_CPUS" \
  --profile=production-two-cpu \
  --concurrency=128 --workspaces=48 --warmup=15s --duration=30s --pairs=4 \
  --out-dir="$SERIES/results-production-two-cpu"
```

The uWebSockets two-loop configuration is only valid for this connection-lifecycle workload. Its
built-in pub/sub tree is per app/event loop, whereas NRC preserves workspace state on its routed
worker. Also retain the authentication caveat: NRC verifies HS256 JWTs; this comparison server only
checks that the auth header exists.

Use full lowercase 40-character Git SHAs (or 64-character immutable content IDs) for source IDs. For
uWebSockets, the runner also binds that ID to the manifest's upstream revision and verifies the
manifest's binary and `server.cpp` hashes against the running process and archived source.

## Artifacts and interpretation

Retain the complete output directory. It contains:

- `environment.txt` and `environment-after.txt`: Git state, binary hashes, CPU topology, affinity,
  kernel, governor, load, frequency/thermal snapshots, and interrupt counters.
- `connection-rate-bench`: the exact generator binary used.
- `invocation.txt`, copied build manifests, and `source-snapshot/`: the exact runner invocation,
  benchmark/protocol sources and hashes, working-tree patch, source IDs, and compiler/build inputs.
- `warmup-a/b.{json,log}`: unreported warm-up runs.
- `pair-*.{json,log}`: every measured run in execution order.
- `runs.tsv`: pair/order/side mapping.
- `summary.json`: arithmetic distributions and geometric paired throughput ratio.

A valid headline requires zero dial, `ServerReady`, close-write, and close-read failures. A success is
counted only after validating the authenticated `ServerReady` payload and receiving a normal peer
close response.
Do not discard slow runs, select the best run, compare isolated medians from different windows, or
claim a regression/improvement from the aggregate means alone. Publish at least:

1. Every per-run rate and p50/p95/p99.
2. Every per-pair `B/A` ratio and the geometric mean ratio.
3. Rate ranges and failure counts for both sides.
4. Exact source revisions and all three binary hashes.
5. CPU masks, SMT topology, governor/turbo state, kernel, and active sysctls.
6. Authentication differences and total CPU budget.

If pair ratios vary more than the expected effect, the result is inconclusive even when their mean is
non-zero. Investigate thermal, frequency, IRQ, generator saturation, or background-load variance and
repeat the complete series; do not increase confidence by merely adding noisy samples.
