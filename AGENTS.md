# AGENTS.md

## Project Overview
This is NRC (No Relay Chat), a WebSocket collaboration server written in **Odin**.
Workers own workspace state and non-blocking connection I/O. Start with
`docs/DEVELOPMENT.md` for architecture, build and test commands.

## NRC Design Philosophy
"No Relay Chat" emphasizes the ephemeral, real-time nature of the system. It is a dry, functional piece of infrastructure, like a government utility or a dedicated hardware terminal.

- **NRC-300**: Standard nomenclature for the terminal interface.
- **Messages**: Ephemeral by default. Operators can enable bounded room-message retention; DMs remain ephemeral.
- **Tasks**: Persistent. Kanban tasks are stored server-side and persist across sessions.

## Programming Language & Framework
- **Language**: Odin; see `docs/DEVELOPMENT.md` for checked toolchain versions.
- **Odin binary**: `odin` on PATH, or `ODIN_BIN` for the test wrapper.

## Build & Development Commands

### Building the project:
```bash
odin build . -out:server
```

### Running the server:
```bash
odin run . 
# or after building:
./server
```

### Debug build:
```bash
odin build . -out:server -debug
```

### Release/optimized build:
```bash
odin build . -out:server -o:speed
```

## Project Structure

### Core Files:
- `server.odin` - Main server implementation with multi-threaded WebSocket handling
- `http.odin` - HTTP upgrade and WebSocket handshake responses
- `worker.odin` - Worker lifecycle and I/O loop

### Modules/Packages:
- `nbio/` - Non-blocking I/O implementation
- `spsc/` - Single-producer/single-consumer handoff queues
- `websocket/` - WebSocket protocol implementation
- `protocol/` - Custom protocol definitions
- `persistence/`, `storage_io/` - WAL and storage I/O
- `ulid/` - ULID (Universally Unique Lexicographically Sortable Identifier) generation
- `byte_pool/` - Transient asynchronous send buffers

### Client Examples:
- `client/`, `cli/` - Web client and Go CLI

## Architecture Notes

- **Multi-threaded**: Uses worker threads with thread-local storage (`@(thread_local) td: Server_Thread`)
- **Non-blocking I/O**: Custom nbio implementation for high-performance networking
- **Connection routing**: Workspace hash selects one of 256 logical shards; shard modulo worker count selects its owner
- **Memory management**: Includes memory tracking in debug builds with leak detection
- **Graceful shutdown**: Handles SIGINT for clean server shutdown

## Design Philosophy

Keep connection status, selected scope and record counts visible near the relevant controls.
Use compact tables and grouped controls for tasks, notes and other records.
Reuse the client's existing components and semantic theme tokens; see `client/AGENTS.md`.
Theme values are defined in `client/css/foundation.css`, not in this document.

## Code Style Conventions

- **Naming**: snake_case for variables and functions, PascalCase for types
- **Error handling**: Uses Odin's error return patterns with `Maybe(T)` types
- **Memory**: Manual memory management with explicit `new()`, `free()`, `delete()` calls
- **Async/network send buffers**: Short-lived dynamically allocated buffers that cross an async send boundary (`nrc_send_frame`, `websocket_send_all`, queued sends, `nbio.send_all`/writev) should be allocated from `byte_pool` (`byte_pool.alloc(td.spool, ...)`) and released in the send completion callback with `byte_pool.release(td.spool, buf)`. Stable connection-owned buffers, static storage, and explicitly ref-counted shared broadcast buffers are acceptable when their lifetime is guaranteed to exceed the async operation. Do not use `make`/`delete` for transient frame/send buffers; the multi-arena byte pool is a deliberate performance optimization and ownership model.
- **Logging**: Uses structured logging with thread IDs and context information
- **Constants**: ALL_CAPS with underscores (e.g., `PENDING_QUEUE_CAPACITY`)
- **Time**: Always use `ulid.time_now()` instead of `time.now()` for better performance (syscall optimization)
- **Stack allocation for bounded arrays**: When array size is bounded by a constant (e.g., MAX_ATTACHMENTS_PER_TASK=10), use stack-allocated fixed arrays during parsing and slice to actual size. This avoids all heap allocations for parsing.

## Testing

### Running tests:
```bash
# Run the complete local test matrix: normal and simulation root suites, all Odin
# test subpackages, Go server E2E, client unit tests, and browser E2E
./test/run_all_tests.sh

# Run all tests in a specific package
./test/run_odin_tests.sh websocket/

# Run tests in current directory
./test/run_odin_tests.sh .

# Run tests quietly while preserving errors and failures
./test/run_odin_tests.sh . -define:ODIN_TEST_LOG_LEVEL=error

# Run simulation tests quietly
./test/run_odin_tests.sh . -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error

# Run tests with custom thread count
./test/run_odin_tests.sh websocket/ -define:ODIN_TEST_THREADS=8

# Run tests with custom random seed
./test/run_odin_tests.sh websocket/ -define:ODIN_TEST_RANDOM_SEED=12345
```

Use `test/run_odin_tests.sh` by default rather than `odin test`. It builds with
`-build-mode:test`, waits for the compiler to exit, then runs and removes the temporary executable.
This avoids retaining the compiler's memory during test execution. Pass the package and ordinary
build/test defines as arguments; the script owns the build mode and output path and preserves the
caller's working directory. Optimization, test concurrency, and memory tracking are unchanged.
The wrapper fetches checksum-pinned libhegel 0.33.3 into the ignored `.hegel/` cache and requires
Hegel by default. It accepts a trusted `HEGEL_LIBHEGEL_PATH` override. Direct Odin test commands
need `test/fetch_libhegel.sh` first or an explicit library path; Odin itself never downloads it.

Run root-package Odin commands sequentially in constrained development environments. In particular,
**never run the normal and `NRC_SIMULATION=true` root test suites in parallel**. Each root compile can
consume substantial CPU, memory, and I/O; parallel runs overload small orbs and can trigger false
Hegel `TooSlow` failures. Do not parallelize root benchmark builds with other root builds either.

The complete test script requires Go, Node.js, and Playwright with Chromium in addition to Odin.
Set `ODIN_BIN=/path/to/odin` when Odin is not available as `odin` on `PATH`.

When adding main-package WAL/persistence tests, build temporary WAL paths with `test_wal_path(...)`
instead of hard-coded `data/...` names. The helper includes the test process ID and simulation config
in the filename, so overlapping suites such as `odin test .` and
`odin test . -define:NRC_SIMULATION=true` can run from the same workspace without racing on WAL,
checkpoint, manifest, or staging files. If you add WAL tests in another package, provide the same
kind of process/config-specific path helper there before using persistent files under `data/`.

Odin's built-in test runner provides:
- Multi-threaded test execution (default: 4 threads)
- Memory tracking and leak detection
- Automatic test discovery (procedures marked with `@(test)`)
- Built-in benchmarking support
- Randomized test ordering with configurable seeds

The test runner installs its own logger for each test. To reduce noisy INFO/WARN
output from WAL, compaction, handoff, and simulation fixtures, use
`-define:ODIN_TEST_LOG_LEVEL=error` instead of adding broad `context.logger`
overrides in test code. Keep narrow logger overrides only for tests that
intentionally exercise expected-error logging and need local suppression.

## Odin Benchmarking

- Benchmarks are ordinary `@(test)` procedures or standalone workload programs; Odin has no
  `@(benchmark)` or automatic calibration.
- Use `core:time.Benchmark_Options` / `time.benchmark` for microbenchmarks. Build deterministic
  runtime fixtures before the timed callback, put only the measured operation in the callback,
  populate the exact `count` and `processed` fields, and validate an observable checksum afterward.
- Use manual `time.Stopwatch`/monotonic timing for disk, network, stateful, or concurrent workloads
  whose setup and completion boundaries do not fit one callback.
- Timed loops must use `0 ..< rounds`. Keep assertions, formatting, fixture generation, warmup, and
  teardown outside the timed interval. Use real serialized bytes for throughput denominators.
- Run timing builds with `-o:speed`, `-define:ODIN_TEST_THREADS=1`, an exact
  `ODIN_TEST_NAMES` filter, and normally `-define:ODIN_TEST_TRACK_MEMORY=false`.
- Size each sample for roughly 0.5–1 second, explicitly warm caches when claiming warm-cache results,
  then run at least 10 independent process invocations and report the median plus spread. Record the
  commit, Odin version, hardware, power policy, cache state, workload flags, and durability mode.
- Allocation measurement is a separate run with an explicit tracking/counting allocator. Do not
  compare allocation-instrumented timings with normal throughput timings.
- See `docs/BENCHMARKS.md` for benchmark-specific commands and workload semantics.

## Performance Considerations

- Server is designed for high concurrency with configurable thread count (defaults to CPU core count)
- Uses buffered channels for thread-safe inter-thread communication
- WebSocket upgrade handling is optimized to minimize memory allocations
- Buffer sizes are tuned for performance (8KB connection buffers)
- The `byte_pool` package is the hot-path allocator for transient frame/send buffers. It uses multi-arena allocation/rotation to reduce allocator overhead and fragmentation under high concurrency. Prefer the existing helpers (`allocate_websocket_frame_buffer`, `send_pooled_buffer`, `send_pooled_buffer_priority`) when constructing WebSocket responses, and add new pooled-send callbacks rather than mixing allocator families.

## Default Configuration

- **Port**: 8080
- **Thread Count**: Auto-detected (CPU core count)
- **Queue Capacity**: 16384 pending connections per thread
- **Connection Close Delay**: 500ms for graceful shutdown

## Common Pitfalls

### Legacy Persistence Migration

Current builds are sharded-only and contain no migration commands. For an installation that still
uses worker-number task/asset/edge WALs, use the pinned historical procedure in
[`docs/SHARDED_PERSISTENCE_MIGRATION.md`](docs/SHARDED_PERSISTENCE_MIGRATION.md) from its specified
Git commit. Back up the stopped installation first; do not adapt those commands to the current binary.

### Adding New Protocol Opcodes

When adding new opcodes to `protocol/types.odin`, you **MUST** also update the opcode validation ranges in `protocol/protocol.odin` in the `get_opcode` function. Otherwise the server will reject the opcode as "Invalid/corrupted protocol opcode".

The validation checks explicit ranges like:
```odin
if (status_code >= 40 && status_code <= 42) ||  // Edges client opcodes
   (status_code >= 150 && status_code <= 152)   // Edges server opcodes
```

If you add opcodes outside existing ranges, add a new range check.

### Work Slices

A slice is an explicit asset (`AssetType.Slice`), not a view derived from task project labels. Its
members are the tasks, notes and files linked to it with a `MemberOf` edge, so a slice spans
projects and one task can belong to several slices. The register, the record and `nrc slice` all
fold their counters from those edges; nothing is derived twice.

- **Membership is a set.** A second `MemberOf` edge between one member and one container is refused
  (`duplicate_membership_edge`), because the fold would count the member twice. Generic relations
  may repeat. The unique pair is unordered, so direction does not change the identity.
- **`MemberOf` also carries customer membership.** A contact or activity belongs to a customer
  company through a member → company `MemberOf` edge, written by `nrc customer` and the customer
  editor; the slice register only folds `MemberOf` edges whose target is an `AssetType.Slice`, so a
  company target is skipped. Work links such as a company's notes or tasks stay `RelatedTo`.
- **A slice name is its identity.** It is unique per conversation and fixed at creation: `create`
  refuses a taken name, `update` refuses a rename, and a record that does not decode or carries no
  name is refused rather than stored as an asset no command can address.
- **Relation and asset-type bounds follow the enums** (`min`/`max(pr.RelationType)`), never a
  literal. A literal bound once rejected `MemberOf` at the WAL and shut the server down on the first
  assign; the same shape appears in `protocol/graph_query.odin`, the AI sidecar's relation mask and
  the client's relation tables, so a new relation has to be added in all of them.
- **Iterating `map[key]` for a key that is not there segfaults** in this Odin release. Read an
  adjacency list with the guarded lookup (`edge_ids, ok := conv.edges_by_entity[key]`) — a slice
  with no members has no adjacency entry at all, so the unguarded form crashes on the common case.

## Pre-Commit Tasks

1. **Format Odin files**:
```bash
odinfmt -w .
```

2. **Vet for problems** (run before commit/push):
```bash
odin build . -vet
```

3. **Update `BUILD_VERSION`** in `server.odin`:
```bash
date +dev-%Y-%m:$(git rev-parse --short HEAD)
```
Update the constant in `server.odin` line 95 with the current date and commit hash (format: `dev-YYYY-MM:XXXXXXX`)
