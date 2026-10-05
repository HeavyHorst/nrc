# NRC Benchmark Suite

A load testing tool for the NRC WebSocket server. Simulates concurrent users performing realistic chat operations.

## Building

```bash
cd benchmark
go build -o nrc-bench ./cmd/nrc-bench
go build -o asset-kv-bench ./cmd/asset-kv-bench
go build -o connection-rate-bench ./cmd/connection-rate-bench
```

## Usage

```bash
# Basic usage - 100 users for 60 seconds
./nrc-bench --server=ws://localhost:8080 --users=100 --duration=60s

# Start server locally with e2e-style auth env + send authenticated client headers
./nrc-bench --start-server --auth --users=100 --duration=60s

# High load test - 1000 users
./nrc-bench --users=1000 --duration=120s --ramp-up=30s

# Stress test with frequent messages
./nrc-bench --users=500 --msg-interval=100ms --msg-size=1024

# Save results to JSON
./nrc-bench --users=100 --duration=60s --output=results.json

# Build the generators where the fanout scaling harness expects them
mkdir -p bin
go build -o bin/nrc-bench ./cmd/nrc-bench
go build -o bin/uwebsockets-bench ./cmd/uwebsockets-bench

# Map two workspaces deterministically to two isolated server endpoints
./bin/nrc-bench --servers=ws://127.0.0.1:8082,ws://127.0.0.1:8083 --workspaces=2

# Steady-state perf capture (CPU flamegraph input + perf stat)
./profile_steady_state.sh --server-pid <PID>
```

`--servers` accepts either one WebSocket endpoint shared by every workspace or exactly one endpoint
per workspace. It is intended for multi-worker fanout comparisons where the baseline server keeps
pub/sub state local to each event loop. Conversation assignment uses a workspace-local user index so
room occupancy does not change when the workspace count changes. Normal NRC runs should continue to
use `--server`.

The dedicated-hardware 1→2→4 worker procedure is documented in
[`docs/FANOUT_SCALING_BENCHMARK.md`](../docs/FANOUT_SCALING_BENCHMARK.md).
Use `run_fanout_capacity_case.sh` for one validated case and
`reproduce_fanout_capacity_reference.sh` for the alternating 18-run reference confirmation series.

## Connection-rate comparison

`connection-rate-bench` repeatedly performs TCP connect, authenticated WebSocket upgrade,
`ServerReady`, WebSocket close, and TCP close. Use
[`run_connection_rate_comparison.sh`](./run_connection_rate_comparison.sh) for direction-balanced A/B
pairs with fixed CPU masks, binary verification, environment capture, and JSON results. The complete
dedicated-hardware procedure is in
[`docs/CONNECTION_RATE_BENCHMARK.md`](../docs/CONNECTION_RATE_BENCHMARK.md).

## Asset KV / Redis Comparison

`asset-kv-bench` compares NRC's asset service to Redis for equivalent asset-shaped values. NRC runs through the real WebSocket asset protocol (`C_CreateAsset`, `C_GetAsset`, `C_UpdateAsset`, `C_DeleteAsset`) and server WAL path. Redis uses RESP `SET`, `GET`, and `DEL` with binary values encoded with NRC-style asset metadata plus the same preview/payload bytes.

```bash
cd benchmark

# NRC only, with a managed local server
./asset-kv-bench --backend=nrc --start-server --auth --profile=mixed --ops=10000 --assets=1000 --payload-size=4096

# Redis only, against an already-running Redis
./asset-kv-bench --backend=redis --redis-addr=127.0.0.1:6379 --profile=mixed --ops=10000 --assets=1000 --payload-size=4096

# Run both and save machine-readable results
./asset-kv-bench --backend=both --start-server --auth --redis-addr=127.0.0.1:6379 --output=asset-kv-results.json

# Compare compressed NRC asset payloads with equivalent compressed Redis values
./asset-kv-bench --backend=both --start-server --auth --zstd --payload-size=16384

# Send 16 in-flight requests per worker connection before reading responses
./asset-kv-bench --backend=both --start-server --auth --pipeline-depth=16
```

`--pipeline-depth=1` is the default and keeps one in-flight request per worker connection. Values above 1 pipeline both backends: NRC sends that many WebSocket asset requests with unique correlation IDs before reading matched responses, and Redis writes that many RESP commands before reading replies in order.

Assets use workspace-data scope `0`. Use `--workspaces` to distribute records;
`--conversations` remains accepted for compatibility but no longer changes asset scope.
Reject samples with nonzero `errors`; rejected creates are not successful throughput.

Profiles:

| Profile | Mix |
|---------|-----|
| `create-only` | 100% create / Redis `SET` |
| `read-only` | preload, then 100% get / Redis `GET` |
| `mixed` | 80% get, 15% update, 5% create |
| `write-heavy` | 50% create, 40% update, 10% delete |

When comparing Redis results, record Redis persistence and transport separately: persistence disabled, AOF `appendfsync everysec`, AOF `appendfsync always`, TCP, or unix socket. Those modes change the interpretation of the numbers.

### Reproducible Asset KV / Valkey AOF Pipeline Runs

Use this runbook when comparing NRC's persistent asset path with Valkey/Redis using AOF durability. The examples below use Valkey/Redis AOF `appendfsync everysec`, which is the closest mode to NRC's batched WAL with periodic fsync. For an in-memory-only Redis baseline, replace `--appendonly yes --appendfsync everysec` with `--appendonly no`.

Build the binaries first:

```bash
# From the repository root.
odin build . -o:speed -out:/tmp/nrc-asset-kv-server

cd benchmark
go build -o /tmp/asset-kv-bench ./cmd/asset-kv-bench
cd ..
```

#### 4 target threads / 4 workspaces / concurrency 128 or 256

Give NRC CPUs `0-4` and explicitly request 4 workers: it will use the physical core containing CPU `4` for the main/compactor service roles and assign workers from the remaining allowed CPUs, using SMT siblings only because four workers were requested. Redis/Valkey is pinned to CPUs `0-3` and configured with `io-threads=4`. Pin the Go benchmark client away from the target, for example CPUs `6-11` on a 12-core machine.

Start Valkey/Redis with AOF every second:

```bash
rm -rf /tmp/nrc-kv-bench/redis-io4-aof
mkdir -p /tmp/nrc-kv-bench/redis-io4-aof

taskset -c 0-3 redis-server \
  --port 6380 \
  --bind 127.0.0.1 \
  --protected-mode no \
  --save "" \
  --appendonly yes \
  --appendfsync everysec \
  --dir /tmp/nrc-kv-bench/redis-io4-aof \
  --daemonize yes \
  --pidfile /tmp/nrc-kv-bench/redis-io4-aof/redis.pid \
  --logfile /tmp/nrc-kv-bench/redis-io4-aof/redis.log \
  --io-threads 4 \
  --io-threads-do-reads yes

redis-cli -p 6380 CONFIG GET io-threads appendonly appendfsync save
redis-cli -p 6380 INFO persistence | grep -E 'aof_enabled|aof_current_size|aof_delayed_fsync'
```

Start NRC with 4 worker threads:

```bash
NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret NRC_THREAD_COUNT=4 \
  taskset -c 0-4 /tmp/nrc-asset-kv-server \
  >/tmp/nrc-kv-bench/nrc-ws4.log 2>&1 &

# Wait until the log shows 4 worker start lines before benchmarking:
grep -c 'Worker thread started' /tmp/nrc-kv-bench/nrc-ws4.log
grep 'running with thread_count' /tmp/nrc-kv-bench/nrc-ws4.log
```

Run the pipelined comparison at concurrency 128:

```bash
taskset -c 6-11 /tmp/asset-kv-bench \
  --backend=both \
  --auth \
  --redis-addr=127.0.0.1:6380 \
  --profile=mixed \
  --ops=100000 \
  --assets=10000 \
  --concurrency=128 \
  --pipeline-depth=8 \
  --payload-size=512 \
  --preview-size=32 \
  --workspaces=4 \
  --conversations=64 \
  --timeout=20s \
  --output=/tmp/nrc-kv-bench/pipeline-depth8-c128-ws4-io4-aof-100k.json
```

Run the same workload at concurrency 256:

```bash
taskset -c 6-11 /tmp/asset-kv-bench \
  --backend=both \
  --auth \
  --redis-addr=127.0.0.1:6380 \
  --profile=mixed \
  --ops=100000 \
  --assets=10000 \
  --concurrency=256 \
  --pipeline-depth=8 \
  --payload-size=512 \
  --preview-size=32 \
  --workspaces=4 \
  --conversations=64 \
  --timeout=20s \
  --output=/tmp/nrc-kv-bench/pipeline-depth8-c256-ws4-io4-aof-100k.json
```

#### 8 target threads / 8 workspaces / concurrency 256

On a 12-core machine, NRC uses worker CPUs `0-7`, service CPU `8`, and client CPUs `9-11`. This leaves fewer client CPUs than the 4-thread example, so compare results with that pinning constraint in mind.

Restart Valkey/Redis with `io-threads=8`:

```bash
redis-cli -p 6380 SHUTDOWN NOSAVE || true

rm -rf /tmp/nrc-kv-bench/redis-io8-aof
mkdir -p /tmp/nrc-kv-bench/redis-io8-aof

taskset -c 0-7 redis-server \
  --port 6380 \
  --bind 127.0.0.1 \
  --protected-mode no \
  --save "" \
  --appendonly yes \
  --appendfsync everysec \
  --dir /tmp/nrc-kv-bench/redis-io8-aof \
  --daemonize yes \
  --pidfile /tmp/nrc-kv-bench/redis-io8-aof/redis.pid \
  --logfile /tmp/nrc-kv-bench/redis-io8-aof/redis.log \
  --io-threads 8 \
  --io-threads-do-reads yes

redis-cli -p 6380 CONFIG GET io-threads appendonly appendfsync save
```

Restart NRC with 8 worker threads:

```bash
NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret NRC_THREAD_COUNT=8 \
  taskset -c 0-8 /tmp/nrc-asset-kv-server \
  >/tmp/nrc-kv-bench/nrc-ws8.log 2>&1 &

grep -c 'Worker thread started' /tmp/nrc-kv-bench/nrc-ws8.log
grep 'running with thread_count' /tmp/nrc-kv-bench/nrc-ws8.log
```

Run the pipelined comparison:

```bash
taskset -c 9-11 /tmp/asset-kv-bench \
  --backend=both \
  --auth \
  --redis-addr=127.0.0.1:6380 \
  --profile=mixed \
  --ops=100000 \
  --assets=10000 \
  --concurrency=256 \
  --pipeline-depth=8 \
  --payload-size=512 \
  --preview-size=32 \
  --workspaces=8 \
  --conversations=64 \
  --timeout=20s \
  --output=/tmp/nrc-kv-bench/pipeline-depth8-c256-ws8-io8-aof-100k.json
```

#### Cleanup and interpretation notes

Stop temporary servers after the run:

```bash
pkill -INT -f /tmp/nrc-asset-kv-server || true
redis-cli -p 6380 SHUTDOWN NOSAVE || true
```

Notes for reproducibility:

1. `--ops=200` is useful only as a smoke/latency probe. It is too short for stable throughput numbers, especially at high concurrency.
2. For non-`create-only` profiles, the benchmark preloads at least one asset per worker. If `--concurrency` is greater than `--assets`, actual preload creates will exceed `--assets`.
3. Keep Redis persistence mode in the result name or notes: `appendonly=no`, `appendfsync=everysec`, and `appendfsync=always` are different benchmarks.
4. By default NRC reserves one complete allowed physical core for main/compactor service work, assigns one worker per remaining physical core, and leaves SMT siblings unused. Explicit `NRC_THREAD_COUNT` can opt into SMT. A single physical core is shared. Confirm both `CPU roles` and `running with thread_count` in the log.
5. Redis `io-threads` accelerates network I/O, but command execution remains mostly single-threaded. Confirm live settings with `redis-cli -p 6380 CONFIG GET io-threads appendonly appendfsync`.

## Steady-State Profiling

Use [`profile_steady_state.sh`](./profile_steady_state.sh) to capture `perf` data only after ramp-up, so connect/ramp transients don't pollute flamegraphs.

```bash
# Terminal 1: pin server to one core
taskset -c 2 ./server

# Terminal 2: run steady-state profiler (load pinned away from server core)
taskset -c 4-7 ./benchmark/profile_steady_state.sh --server-pid <PID>
```

Default behavior:

1. Runs `nrc-bench` with `--users=2000 --workspaces=1 --duration=75s --ramp-up=15s`.
2. Waits 20 seconds after benchmark start.
3. Captures `perf stat`, cycle-stack `perf record`, LLC-miss `perf record`, and `perf mem` (best effort) for 30 seconds.
4. Exports timestamped artifacts to `.amp/in/artifacts/perf/steady-<timestamp>/`.

Artifacts written per run:

1. `benchmark.json` benchmark metrics summary.
2. `benchmark.log` full benchmark stdout/stderr.
3. `perf-stat.txt` hardware counter summary (`perf stat -d -d`).
4. `perf.data` raw sampled stacks for flamegraphs.
5. `perf.script` expanded stacks from `perf script`.
6. `perf-llc.data`, `perf-llc.script`, and `perf-llc.report.txt` for cache-miss-attributed stack analysis.
7. `perf-mem.data` and `perf-mem.report.txt` for memory-access attribution when `perf mem` is supported.
8. `perf-llc.status.txt` / `perf-mem.status.txt` and corresponding `.log` files for capture success/failure diagnostics.
9. `run-meta.txt` run configuration for reproducibility.

## Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--server` | `ws://localhost:8080` | WebSocket server URL |
| `--start-server` | `false` | Start server process via `odin run .` and set `NRC_JWT_SECRET` |
| `--users` | `100` | Number of concurrent users |
| `--duration` | `60s` | Benchmark duration |
| `--ramp-up` | `10s` | Time to gradually start all users |
| `--msg-interval` | `1s` | Interval between messages per user |
| `--ping-interval` | `10s` | Interval between pings (0 to disable) |
| `--fanout-sample-rate` | `100` | Sample every N fanout messages for lag calc (1=all, 0=disable) |
| `--msg-size` | `128` | Message payload size in bytes |
| `--workspaces` | `4` | Number of workspaces to distribute users |
| `--conversations` | `10` | Number of conversations per workspace |
| `--convs-per-user` | `3` | Conversations each user subscribes to |
| `--auth` | `false` | Send JWT in `X-NRC-Auth` like e2e |
| `--jwt-secret` | `dev-insecure-nrc-jwt-secret` | JWT HMAC secret (also used for managed server env) |
| `--jwt-issuer` | `nrc-tailscale-proxy` | JWT issuer |
| `--jwt-audience` | `nrc` | JWT audience |
| `--jwt-ttl` | `5m` | JWT token TTL |
| `--output` | | JSON output file (optional) |

## What It Measures

### Latency Metrics
- **Message ACK Observed RTT**: Time from sending `C_SendMessage` to processing `S_AckSendMessage` in the client loop
- **Message ACK Lag**: Time from server ACK timestamp (`S_AckSendMessage.timestamp`) to client receive time
- **Fanout Lag**: Time from server-assigned message timestamp in `S_NewMessage` to client receive time (sampled by `--fanout-sample-rate`)
- **Ping RTT**: Time from `C_Stats` to `S_StatsResponse`
- **Connect Time**: Full connection setup (TCP + WS upgrade + ServerReady + SetNickname + Subscribe)

All latencies reported as p50, p95, p99, and max.

### Throughput Metrics
- Messages sent/received per second
- Bytes sent/received per second

### Server Metrics (from Pong)
- Thread count and per-thread connections
- Memory usage
- io_uring buffer pool utilization
- Send queue depth and backpressure status

## User Simulation

Each simulated user follows this flow:

1. **Connect** - WebSocket handshake to `ws://server/workspace-id`
2. **Wait for ServerReady** - Receive `S_ServerReady`
3. **Set Nickname** - Send `C_SetNickname`, wait for `S_NicknameResponse`
4. **Subscribe** - Send `C_SubscribeConvs` for assigned conversations
5. **Active Loop**:
   - Send messages at configured interval to random subscribed conversation
   - Send pings at configured interval
   - Receive and count broadcast messages
6. **Disconnect** - Graceful WebSocket close

## Example Output

```
╔═══════════════════════════════════════════════════════════╗
║                  NRC BENCHMARK SUITE                      ║
╚═══════════════════════════════════════════════════════════╝

Server:        ws://localhost:8080
Users:         100
Duration:      1m0s
...

[5s] Active: 100 | Msgs: 487 sent, 14123 recv | ACK Obs p99: 1.23ms | ACK Lag p99: 0.94ms | Fanout p99: 1.78ms
[10s] Active: 100 | Msgs: 983 sent, 29456 recv | ACK Obs p99: 1.45ms | ACK Lag p99: 1.12ms | Fanout p99: 2.04ms
...

=== NRC Benchmark Results ===
Duration: 1m0s

CONNECTIONS
  Total:   100
  Active:  0
  Failed:  0
  Connect Time: p50=12.34ms p95=23.45ms p99=34.56ms

MESSAGES
  Sent:     5892 (98.2/sec)
  Received: 176234 (2937.2/sec)
  ACK Observed RTT: p50=0.45ms p95=1.12ms p99=1.89ms max=12.34ms
  ACK Lag: p50=0.34ms p95=0.91ms p99=1.42ms max=10.22ms
  Fanout Lag: p50=0.72ms p95=1.55ms p99=2.41ms max=17.80ms

THROUGHPUT
  Sent:     12.34 KB/s
  Received: 345.67 KB/s

PING/PONG
  Sent: 594  Received: 594
  RTT: p50=0.34ms p95=0.89ms p99=1.23ms

ERRORS
  Total: 0
```

## Architecture

```
benchmark/
├── cmd/nrc-bench/main.go     # CLI entry point
├── client/client.go           # WebSocket client with state machine
├── metrics/collector.go       # HDR histogram-based metrics
└── scenario/scenario.go       # Benchmark orchestration

Uses shared wire helpers from `../protocol-go`.
```

## SocketJS Baseline

For a comparable Socket.IO baseline, see `socketjs/README.md`.

## uWebSockets Baseline

For a comparable **uWebSockets (C++)** baseline, see `uwebsockets/README.md`.
