# Development

## Toolchains and build

The core requires Linux 5.19+ with usable io_uring. Tested locally with Odin
`dev-2026-09-nightly:a2fb372`, Go `1.26.8` and Node `24.21.0`.
Go module requirements are in each `go.mod`; the proxy requires at least Go 1.26.6.
Docker builds supply their own toolchains and build Odin from upstream HEAD.

Install an Odin compiler, Go and Node.js before you build.
On Debian/Ubuntu, also install `libopus-dev` and `libzstd-dev`.
Run these commands from the repository root:

```sh
odin build . -out:server -o:speed
odin build . -out:server -vet
go -C cli build -o ../nrc ./cmd/nrc
npm ci --prefix client
npm run build --prefix client
```

Keep the default Odin target for binaries that you distribute.
Use `-microarch:native` only if the target hardware supports the same CPU features.

The standalone server listens on port 8080 and expects authenticated upgrades.
Serving static `client/` alone does not provide browser authentication.
Use the [Compose deployment](../README.md#quickstart) for the complete web application.
Production serves the complete generated `client/dist/`, not the source directory.
After frontend changes, rebuild the Nginx image and reload open browser tabs.

## Tests

Run the core and simulation suites one after the other. Do not run them in
parallel. For the full test matrix, install Playwright/Chromium first.
The Odin test wrapper downloads the pinned Hegel library on Linux amd64 and
checks its SHA256 before use. Later runs use the local cache without a download.
See [TEST_MATRIX.md](TEST_MATRIX.md).

```sh
# Core and simulation suites: run sequentially, not in parallel.
./test/run_odin_tests.sh . -define:ODIN_TEST_LOG_LEVEL=error
./test/run_odin_tests.sh . -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error

go -C protocol-go test ./...
go -C cli test ./...
node --test client/*.test.mjs
npm run test:build --prefix client

# Full local matrix, including real-process and browser tests.
./test/run_all_tests.sh
```

The test wrapper releases compiler memory before running tests and requires
Hegel by default, so an unloadable library does not silently skip properties.
For offline setup or another platform, set `HEGEL_LIBHEGEL_PATH` to a trusted
libhegel 0.33.3 build. Explicit overrides are not checked against the Linux digest;
the Odin loader checks the version. Direct `odin test` does not download anything:
run `./test/fetch_libhegel.sh` first from the repository root on Linux amd64,
or export its returned path for tests launched elsewhere.
Set `ODIN_BIN` if Odin is outside PATH.
To check production routing and caching, install Nginx with Brotli, Python 3
and curl. Then build the client and run `./test/nginx_production_smoke.sh`.
The script uses temporary upstream servers.

Run tests that write data only on disposable installations.
Do not run them on a shared or production workspace.
Follow [AGENTS.md](../AGENTS.md) and [client guidance](../client/AGENTS.md)
when you edit code. Format Odin with `odinfmt -w .`.
For frontend changes, also update the PWA cache contract.

## Architecture

The main thread accepts connections and routes an owned HTTP upgrade request to
a workspace worker. That worker validates authentication/upgrade and owns its
connections, state, subscriptions and persistence I/O through io_uring.
`NRC_THREAD_COUNT` counts workers, not all process threads. By default a service
core is reserved when possible, and workers use the remaining physical cores.

Workspace bytes hash to one of 256 logical shards; the shard maps to a worker.
Changing worker count changes ownership, not storage identity. Durable task,
asset and edge mutations share atomic shard transactions. Background compaction
uses manifest-driven immutable segments. Transient asynchronous send buffers
use the thread-local byte pool and are released on completion.

| Path | Responsibility |
| --- | --- |
| `server.odin`, `worker.odin` | Startup, routing, worker lifecycle |
| `*_handlers.odin`, `protocol/` | Request handling and binary wire contract |
| `shard_*.odin`, `persistence/`, `storage_io/` | Durable writes, recovery and compaction |
| `nbio/`, `byte_pool/`, `spsc/` | Networking, buffers and handoff queues |
| `client/`, `cli/`, `protocol-go/` | Web client, CLI and shared Go wire codecs |
| `services/` | Tailscale gateway and optional processors |

See [persistence](SHARDED_PERSISTENCE.md), [simulation](DETERMINISTIC_SIMULATOR_PLAN.md)
and [benchmarks](BENCHMARKS.md) for deeper engineering details.
