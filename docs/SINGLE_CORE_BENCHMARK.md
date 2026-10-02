# Reproducible Single-Core Benchmark Procedure

This runbook measures NRC's single-worker WebSocket chat path on one logical CPU while reserving its
physical core from benchmark-client work. It contains no reference performance numbers: results are
meaningful only with the recorded source revision, build, hardware, operating-system state, CPU
placement, and workload. Shared CI and Orb hosts are suitable for broad regression guardrails, not
low-single-digit performance claims; use dedicated hardware for those comparisons.

## Workload

The standard workload exercises:

1. WebSocket connection and JWT authentication.
2. Nickname setup and conversation subscription.
3. `C_SendMessage` acknowledgement and `S_NewMessage` fanout.
4. Periodic `C_Stats` requests and server statistics.

Use one workspace to route all connections to one NRC worker. Unless a test explicitly changes a
parameter, use:

- 10 conversations per workspace
- 3 conversations per user
- approximately one 128-byte message per user per second (the client jitters individual intervals)
- fanout sampling every 100 received messages
- 75-second duration with a 15-second ramp
- authentication enabled
- an explicitly recorded deterministic traffic seed

With the benchmark's deterministic consecutive-conversation assignment, room occupancy is balanced.
For `conversations_per_user ≤ conversations`, the harness has this exact maximum occupancy. Verify it
before running:

```text
conversations_per_user × floor(users ÷ conversations)
  + min(users mod conversations, conversations_per_user)
  ≤ MAX_ROOM_USERS
```

If this does not hold, NRC rejects subscriptions and the run is not a full-subscription capacity
measurement. Record the compiled `MAX_ROOM_USERS` value with every result.

## Record the environment

Record these values before every benchmark series:

```bash
git rev-parse HEAD
git status --short
odin version
go version
uname -a
lscpu
lscpu -e=CPU,CORE,SOCKET,MAXMHZ,MINMHZ,ONLINE
command -v mpstat >/dev/null && mpstat -P ALL 1 5

for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
  printf '%s siblings=%s\n' "${cpu##*cpu}" \
    "$(cat "$cpu/topology/thread_siblings_list")"
done

cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq 2>/dev/null || true
cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true
cat /proc/stat
sensors 2>/dev/null || true
```

Also record whether the machine is on AC power, its thermal state, kernel command line, background
load, CPU steal time, observed frequency, temperature, and any IRQ or frequency-control changes. Do
not compare runs from different hardware, CPU placements, governors, turbo states, source revisions,
or workload parameters as if they were paired measurements. If the server or load generator shares a
host with uncontrolled tenants, treat low-single-digit changes as noise unless repeated evidence proves
otherwise.

## Select CPUs

On a hybrid CPU, identify performance cores from topology and maximum-frequency data; do not assume
that every logical CPU is equivalent. Select one logical CPU for the server and exclude both it and
its SMT sibling from the load-generator mask.

For example, if CPU 0 is the selected server thread, CPU 1 is its SMT sibling, and CPUs 2-11 are the
remaining available threads:

```bash
SERVER_CPU=0
CLIENT_CPUS=2-11
```

Use the same server CPU and client mask for every implementation in a comparison. Confirm placement
while the processes run:

```bash
taskset -pc "$SERVER_PID"
taskset -apc "$SERVER_PID"
ps -L -o pid,tid,psr,comm -p "$SERVER_PID"
```

## Build

Build both binaries from the same clean source revision:

```bash
odin build . -out:server -o:speed

cd benchmark
go build -o nrc-bench ./cmd/nrc-bench
cd ..
```

Save hashes of the exact binaries used:

```bash
sha256sum server benchmark/nrc-bench
```

## Prepare the server

Use an isolated current-format data directory with a valid sharded storage layout. Do not run against
production data, reuse a directory concurrently, manually edit its manifest, or use legacy worker-WAL
data. See [Sharded Persistence](SHARDED_PERSISTENCE.md) for the required layout and startup checks.

The server resolves `data/` relative to its working directory, so start it from the prepared isolated
installation directory. Raise the file-descriptor limit before launch. Disable NRC's internal affinity
selection because `taskset` owns placement for this experiment:

```bash
ulimit -n 100000

NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret \
NRC_THREAD_COUNT=1 \
NRC_DISABLE_CPU_AFFINITY=1 \
taskset -c "$SERVER_CPU" /absolute/path/to/server \
  >server.log 2>&1 &
SERVER_PID=$!
```

Verify that the log reports one worker and that the server is listening before starting clients. Stop
the server with `kill -INT "$SERVER_PID"` after each run and wait for a clean exit. Restart it between
runs so connection state and allocator history do not carry over.

## Run

Run the load generator outside the server core and write both text and JSON output:

```bash
USERS=2500
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-users-${USERS}"

taskset -c "$CLIENT_CPUS" benchmark/nrc-bench \
  --server=ws://127.0.0.1:8080 \
  --users="$USERS" \
  --workspaces=1 \
  --conversations=10 \
  --convs-per-user=3 \
  --duration=75s \
  --ramp-up=15s \
  --msg-interval=1s \
  --msg-size=128 \
  --fanout-sample-rate=100 \
  --seed=11 \
  --auth \
  --output="${RUN_ID}.json" \
  2>&1 | tee "${RUN_ID}.log"
```

Do not use `--start-server` for controlled single-core runs: manual startup is required to control the
server working directory, affinity, environment, logs, and lifecycle.

## Find the capacity boundary

Capacity near overload is stochastic. A single successful or failed run is not an exact limit.

1. Start at a user count known to complete with zero errors.
2. Increase in coarse steps until connections close, errors appear, or receive throughput stops
   scaling.
3. Bisect the interval with smaller user-count steps.
4. Warm each build before collecting measured runs.
5. Run the candidate boundary for the full 75-second workload.
6. Repeat each boundary point at least three times, alternating A/B order for every paired comparison.
7. Report the distribution, the highest repeatedly zero-error point, and the interval containing the
   first unstable runs.

Use the same seed set for every build in a comparison. Each client owns an independent random stream
derived from the base seed and client ID, so goroutine scheduling cannot change another client's
traffic choices. Kernel and runtime scheduling remain nondeterministic: preserve every run and report
distributions rather than selecting the best result. A reproducible claim describes the procedure and
observed interval, not an exact connection count guaranteed on every run.

## Determine validity

A run is valid only when:

- the intended number of clients connected and all requested subscriptions fit the room limit;
- the server remained on the selected CPU and used one worker;
- the client did not run on the server core or its SMT sibling;
- no unrelated process or thermal/power event changed the environment;
- the complete configured duration ran; and
- raw JSON, client log, and server log were retained.

Classify a run as stable only if it has zero failed connections, zero client errors, no mid-run
disconnects, and continuing receive progress. The harness snapshots primary results before intentional
client shutdown and reports teardown errors separately. `messages_sent` is the client-side offered
count; `messages_acknowledged` shows how many sends received an ACK before the snapshot.

The JSON contains only the last concurrently received stats response; its queue depth and backpressure
fields describe that requesting connection, not a worker-wide maximum or time series. Report them as a
final snapshot, not evidence that aggregate backpressure did or did not occur.

## Report results

Store the environment capture, commands, logs, and JSON together. A result report should include:

```text
UTC date:
Git revision and worktree state:
Server/client binary SHA-256:
Odin and Go versions:
Kernel:
CPU model and topology:
Server CPU and SMT sibling:
Client CPU mask:
Governor and turbo state:
Observed frequency, steal time, and temperature:
Power/thermal/background-load state:
MAX_ROOM_USERS:
Server environment and command:
Client command:
Run order and repetition count:
Traffic seeds:
Connected / failed:
Steady-state / teardown disconnects:
Messages sent/sec and received/sec:
Messages sent and acknowledged:
ACK observed p50/p95/p99:
ACK lag p50/p95/p99:
Fanout lag p50/p95/p99:
Total errors and errors by type:
Final server-stat snapshot (connections, memory, IO pending, queue depth, backpressure):
Paths to raw JSON and logs:
```

For cross-system comparisons, use the same load-generator binary and workload where possible. Document
semantic differences such as NRC JWT validation versus header-presence-only authentication in the
uWebSockets benchmark. Never compare only headline throughput when connectivity, admitted
subscriptions, error counts, or latency tails differ. Do not rank implementations from isolated runs
or report a low-single-digit delta as meaningful without controlled, alternating paired evidence on
dedicated hardware.

## Related documentation

- [Benchmark suite](BENCHMARKS.md)
- [Go benchmark tool](../benchmark/README.md)
- [uWebSockets baseline](../benchmark/uwebsockets/README.md)
- [Sharded persistence](SHARDED_PERSISTENCE.md)
