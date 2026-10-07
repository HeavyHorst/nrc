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
use the worker's shared TLSF heap through `byte_pool` and are released on
completion. The package retains allocation provenance and buffer-only accounting,
not a separate arena heap. Typed leases and shared references govern I/O lifetime;
shortened send slices still release the original complete allocation.

Each production worker installs its own unsynchronized Odin TLSF heap
for worker-owned state: entities, maps, indexes and interned strings. It starts
with a write-touched 64 MiB backing pool, grows in at least 64 MiB chunks (larger
for oversized requests), reuses freed blocks and releases all pools at worker
exit. Fresh zeroed backing is write-touched before TLSF initializes block headers,
including growth pools; unused pool tails therefore become resident too.
This commits approximately 64 MiB per worker before replay; freed pools
are retained until exit rather than returned immediately to the OS.
On Linux, pools of at least 64 MiB use anonymous mappings aligned and rounded
to 2 MiB. The server requests transparent hugepages with `MADV_HUGEPAGE`
before touching the pool. The request is advisory: ordinary pages remain usable
if the kernel rejects the advice or cannot supply hugepages. No reserved
hugetlb pool or system-wide policy change is required. Check `AnonHugePages`
in `/proc/PID/smaps` to verify actual backing; advice alone is not proof.
Rounding can add less than 2 MiB per pool. Under memory pressure, THP can
cause allocation or compaction stalls. Build with
`-define:WORKER_HEAP_HUGEPAGES=false` to restore the caller-backed pool path.
Small pools and TLSF tracking nodes continue to use the caller's allocator.
The licensed, pinned copy in `vendor/tlsf/` rolls back a fresh growth pool if its
tracking-node allocation fails, preserving existing allocations and freeing the
untracked backing buffer. See its README for the upstream revision and local fix.
Individual allocations must fit TLSF's block limit (below 4 GiB on 64-bit,
including alignment overhead); unsupported allocation/resize requests fail
without changing an existing allocation. Growth pools never exceed that limit.
The temporary allocator is unchanged. Connection handle storage, batch pools
and nbio infrastructure retain their existing backing allocators.
Compaction/sealing jobs and results explicitly capture the thread-safe backing
allocator, never the owning worker's TLSF heap. Buffer allocations capture the
worker heap once; they are allocated and released only on that worker.
Buffer-scoped `Free_All` is unsupported because it would reset unrelated worker
records. Live-byte counters include each backing block's capacity and metadata,
not total TLSF heap usage. The 64 MiB buffer usage budget is a reporting
denominator, not an allocation cap. TLSF growth caused by a transient burst is
retained until worker exit; consider post-drain RSS as well as live buffer bytes.

Retained-message append batches use io_uring. The worker retains each immutable
batch until write completion. ACKs still wait for fsync. Admission permits at
most 512 live send contexts per store, including duplicate retries, and at most
256 unique deferred requests. Contexts retire after write completion; ACKs
waiting for fsync remain in separately bounded connection outboxes, outside this
context limit.

Production shard-transaction batches also use io_uring, including records larger
than the fixed write buffer. A leased batch is immutable; requests for its shard
wait in the bounded deferred-request queue until write completion. Durability
watermarks advance only after fsync, not after submission or write completion.
History and sealed dedup lookups open, read and close their read descriptors
asynchronously. The service thread samples RSS and disk space; requests consume
cached values. Disk-space probes refresh after one second, and samples older than
two seconds or failed probes cause write-admission backpressure, reported to
protocol clients with WebSocket close code 1013 (retry later). Concurrent lazy
history opens reserve cache capacity; duplicate opens and descriptor exhaustion
return a retryable capacity error rather than poisoning the store. Startup takes
the initial sample synchronously.

Runtime WAL rotation, segment publication and retained-message retention cleanup
run on the storage service. Workers submit detached, backing-allocator-owned
snapshots and gate the affected shard until the durable publication result is
adopted. No worker indexes, arenas, connection handles or live WAL file objects
cross this boundary. Snapshots carry buffer-free WAL metadata, not the 128 KiB
append buffer; frozen sources carry only a segment descriptor. Job-owned
publication lists, returned catalogs and WAL paths transfer ownership without
another deep copy. WAL paths retain their allocator across adoption. The worker's
still-authoritative catalog and retained segment descriptors remain detached
copies. Rotation drains write/fsync leases before submission;
retention also drains history readers. Sealed publication preserves already
borrowed frozen snapshots and the active WAL's outstanding fsync boundary.
Publication results wait for completion-queue capacity rather than being
dropped. Shutdown never overwrites a manifest while its publication is pending.
Startup, recovery, standalone stores without a service, and shutdown retain
synchronous filesystem operations.

The sealing service deletes obsolete source WALs after durable manifest
publication and reader drain. Queue refusal retries later. An accepted deletion
can leave a safe, unreferenced file on failure or shutdown; this does not add
orphan collection. Standalone stores without a sealing service delete directly.

Run the host and simulation suites sequentially:

```bash
./test/run_odin_tests.sh .
./test/run_odin_tests.sh . -define:NRC_SIMULATION=true
```

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
