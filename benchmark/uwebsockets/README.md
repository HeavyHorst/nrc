# uWebSockets (C++) Comparable Benchmark

This folder adds a **C++ uWebSockets** baseline (not `uWebSockets.js`) with a **Go load generator** using the same benchmark client stack as `nrc-bench`.

The baseline now speaks the same **NRC benchmark binary wire path** (`protocol-go`) for the chat hot path, so ACK/fanout measurements are protocol-aligned:

1. N clients connect.
2. Clients subscribe to a configurable set of conversations.
3. Clients send periodic messages with ack-based RTT measurement (both observed RTT and server-timestamp-based ACK lag).
4. Broadcast fanout lag is measured from `NEW` server timestamp to client receive time.
5. Broadcast receives are counted per client.

## Server Build (C++)

`build-server.sh` checks out its pinned upstream `uNetworking/uWebSockets` revision (with submodules),
builds `uSockets`, and compiles [`server.cpp`](./server.cpp) into `uwebsockets-bench-server`. Set
`UWS_REVISION` explicitly to benchmark another revision, and record that revision with the result.
The script resets the dependency checkout, uses an explicit no-TLS uSockets configuration, and emits
`uwebsockets-bench-server.manifest.txt` with all source revisions, compiler settings, source hash, and
binary hash.

```bash
cd benchmark/uwebsockets
./build-server.sh
```

The clone is stored in `benchmark/uwebsockets/.deps/uWebSockets`.

`UWS_THREAD_COUNT` controls the number of independent uWebSockets event loops (default `1`). Each
thread owns its own `uWS::App` and listen socket; on Linux, uSockets uses `SO_REUSEPORT` to distribute
connections across the listeners. For the documented two-core connection-rate profile:

```bash
PORT=8082 AUTH_ENABLED=1 UWS_THREAD_COUNT=2 taskset -c 2,3 ./uwebsockets-bench-server
```

The process exits if any worker cannot bind the port. Confirm that the log contains one `listening`
line per configured worker before measuring.

## Run

```bash
# Build + start managed uWebSockets C++ server, then run Go clients
cd benchmark
go run ./cmd/uwebsockets-bench --start-server --auth --users=1000 --workspaces=1 --duration=60s

# Or benchmark an already-running server
go run ./cmd/uwebsockets-bench --server=ws://127.0.0.1:8082 --users=1000 --duration=60s

# Enable fanout lag sampling at 1:100 messages
go run ./cmd/uwebsockets-bench --server=ws://127.0.0.1:8082 --users=1000 --duration=60s --fanout-sample-rate=100
```

## Notes

1. Default URL is `ws://127.0.0.1:8082` to avoid colliding with NRC (`8080`) and Socket.IO baseline (`8081`).
2. `--auth` currently enforces **header presence** (`X-NRC-Auth`) on the C++ server. It does not validate JWT signature/claims.
3. uWebSockets now implements the same binary benchmark opcodes used by NRC for this workload (`S_ServerReady`, `C_SubscribeConvs`, `C_SendMessage`, `S_AckSendMessage`, `S_NewMessage`, `C_Stats`, `S_StatsResponse`).
4. `benchmark/cmd/uwebsockets-bench` reuses the shared `scenario`, `client`, and `metrics` packages, so client-side parsing and metric collection paths are consistent with `nrc-bench`.
5. `--fanout-sample-rate` controls fanout lag measurement cost (default `100`, use `0` to disable).
6. For reproducible connection-rate A/B runs, use the dedicated
   [`connection-rate runbook`](../../docs/CONNECTION_RATE_BENCHMARK.md) instead of managed server mode.
7. uWebSockets pub/sub state belongs to one `uWS::App`. Consequently, `UWS_THREAD_COUNT>1` is valid
   for the connection-lifecycle benchmark, but the chat fanout benchmark would only publish to
   subscribers on the same event loop. Do not report multi-thread fanout results without adding an
   explicit cross-loop broadcast mechanism.

## Multi-loop fanout scaling

For a valid 2- or 4-loop fanout comparison, start one single-loop uWebSockets process per workspace
on a distinct port and CPU. Pass those endpoints to the generator in workspace order:

```bash
benchmark/bin/uwebsockets-bench \
  --servers=ws://127.0.0.1:8082,ws://127.0.0.1:8083 \
  --workspaces=2 \
  # remaining workload flags...
```

`--servers` accepts either one endpoint for every workspace or exactly one endpoint per workspace.
The latter keeps every workspace and its subscribers inside one `uWS::App`, while retaining one Go
load-generator process and deterministic client assignment. Do not replace this topology with
`UWS_THREAD_COUNT=2` or `4`; `SO_REUSEPORT` does not route all connections for a workspace to the
same event loop.

See the [fanout scaling runbook](../../docs/FANOUT_SCALING_BENCHMARK.md) for CPU isolation,
repetition, validity, and reporting requirements.

Load-generator binaries are build artifacts. Build them into `benchmark/bin/`; no prebuilt generator
binary in the repository should be used for a controlled comparison.
