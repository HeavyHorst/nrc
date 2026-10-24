# Test Matrix

NRC separates fast correctness checks, deterministic simulation, real-process behavior, scheduled fault campaigns, and performance monitoring. Use the narrowest tier that exercises the changed boundary.

## Verification record — 2026-09-10

The verification work completed against committed
[`cd07c8f`](https://github.com/HeavyHorst/nrc/commit/cd07c8f40128870fdc62afce59e389263fd00e41)
in a Linux x64 Amp orb. Both commands below exited successfully. This is a historical
result for that commit, not a claim that later changes have been verified. GitHub Actions
credits were exhausted, so verification ran locally rather than through hosted CI.

```bash
PYTHONDONTWRITEBYTECODE=1 python3 test/run_mutation_audit.py \
  --output .amp/in/artifacts/final-six-mutant-audit
./test/run_all_tests.sh
```

| Check | Observed result |
|---|---|
| Mutation audit | Clean six-test baseline passed; all six mutants produced the required semantic failures |
| Root Odin suites | 480 normal and 554 simulation tests passed |
| Odin subpackages | WebSocket, protocol, persistence (normal and simulation), btree, byte pool, ULID, nbio, and Hegel suites passed |
| Python runner unit tests | 14 passed |
| Go suites | Protocol and full real-process server E2E passed |
| Client unit tests | 121 passed; zero skipped |
| Browser E2E | Command palette, virtual lists, and mobile shell passed |

The full matrix ended with `All test suites passed.` No new failures required code
changes, and the checkout remained clean after temporary mutation worktrees were removed.
The audit used strict memory checks and Hegel generation seed 12345. The full matrix used
the script's defaults; it was not an additional `go test -race` campaign.

Raw evidence from this run is retained in the originating orb under
`.amp/in/artifacts/final-six-mutant-audit/` and
`.amp/in/artifacts/final-local-test-matrix/run.log`. These ignored artifacts are not part
of a repository clone; this record preserves the result, and the commands reproduce the
checks. Choose a new output directory when rerunning the audit.

This establishes sensitivity to six selected injected faults, not an exhaustive mutation
score or formal proof. Real-process `SIGKILL` checks do not model loss of kernel-cached
writes; deterministic storage simulation covers that separate failure model. Use focused
tests during development, the full matrix for cross-boundary changes, and the existing
multi-seed Hegel and real-process fault campaigns before releases or after changes to
persistence, connection lifetime, or authorization. No new recurring job was enabled by
this verification work.

## Local fast

Use `./test/run_odin_tests.sh` for focused tests while iterating. It fetches and
verifies libhegel automatically. For the direct Odin commands below, first run
`HEGEL_LIBHEGEL_PATH="$(./test/fetch_libhegel.sh)" && export HEGEL_LIBHEGEL_PATH`
successfully from the repository root.

```bash
odin build .
odin build . -define:NRC_SIMULATION=true
odin test . -o:speed -define:NRC_SIMULATION=true -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error \
  -define:ODIN_TEST_NAMES=main.test_generated_transactional_shard_semantic_replay_fixture,main.test_hegel_generated_transactional_shard_state_matches_replay,main.test_shard_checkpoint_preserves_floors_after_every_entity_is_deleted,main.test_shard_checkpoint_floor_witness_routes_to_every_logical_shard,main.test_hegel_simulation_generated_message_fanout_matches_model,main.test_hegel_simulation_delayed_send_completion_lifetime_choices,main.test_hegel_shard_compaction_manifest_roundtrip,main.test_hegel_generated_jwt_tokens_preserve_validation_contract,
```

`ODIN_TEST_NAMES` accepts a comma-separated list of fully qualified tests. A trailing comma is supported and makes copied failure commands easy to reuse.

## AddressSanitizer detector and real I/O checks

On 64-bit Linux with an ASan-capable Odin/linker toolchain and usable io_uring:

```bash
./test/run_asan_checks.sh
```

This opt-in check first runs a valid allocation/resize/release control, then
requires five deliberately invalid accesses to fail with ASan `use-after-poison`
and exit code 86: `byte_pool` use-after-free and one-byte overflow with another
buffer still live, TLSF accesses past a shrunk allocation (both resize modes),
and access after Free_All. A crash, compiler error or missing diagnostic is a
failure, not evidence that the detector works. It then runs the TLSF contract
tests and five existing Linux connection-close-barrier tests with ASan and fatal
Odin memory checks. The lifecycle tests use one thread and exercise deferred
send, writev and shutdown, partial sends/writes, terminal callbacks and FD reuse
over real loopback sockets and io_uring. Compiler and tests run sequentially.

The runner repeats this with `TLSF_ASAN_QUARANTINE=false` and `true`. An extra
stale-pointer probe deliberately reallocates the same payload size after free:
the no-quarantine control must reuse the address and exit normally, while the
quarantine variant must retain the old poisoned block and fail in ASan. Allocator
tests also exercise FIFO eviction at the entry/byte limits, reset and allocation
pressure. Neither variant replaces the other.

Both smoke variants enable `TLSF_CHECK_INVARIANTS=true`: physical blocks,
neighbor links, coalescing, free lists, size classes, bitmaps and quarantine
accounting are checked after allocator operations. Eight deliberate metadata
corruptions must produce their exact invariant assertions. Double-free and
resize of quarantined storage must also be refused. These assertion probes have
a ten-second timeout; a hang or unrelated crash is a failure.

All tests retain the real TLSF: ASan builds poison free pool storage, headers and
rounding slack, unpoison requested payloads, and revoke access on free/shrink.
The hooks are compile-time conditional; normal builds retain the original
allocation path, layout and returned capacity. ASan builds return the requested
length rather than rounded capacity. See `vendor/tlsf/README.md`.

This is not complete memory-safety coverage: TLSF metadata helpers intentionally
bypass ASan, and other suballocators need their own instrumentation. `byte_pool`
headers/alignment padding remain inside a live TLSF allocation, so payload
underruns into that storage are not covered. ASan does not instrument kernel
io_uring accesses or detect stale handles after valid memory reuse. LeakSanitizer
only sees whole backing pools, not leaked TLSF blocks. Lifecycle assertions,
generation checks, ownership counters and normal allocator tests remain necessary.

The runner fixes ASan options (including leak detection) rather than inheriting
options that can suppress errors. It prints unexpected failure diagnostics and
removes temporary binaries/logs on exit. It is separate from the default matrix
because it requires sanitizer runtime support in addition to the usual tools.

For the complete root suites, keep the normal runs and additionally run ASan
with fatal allocator tracking (sequentially, never both root builds at once):

```bash
./test/run_odin_tests.sh . -sanitize:address -o:speed -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
./test/run_odin_tests.sh . -sanitize:address -o:speed -define:NRC_SIMULATION=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
```

Repeat both commands with `-define:TLSF_ASAN_QUARANTINE=true` for delayed reuse.
This opt-in mode is bounded to 128 blocks / 1 MiB per heap and releases oldest
blocks early under pressure; it cannot guarantee detection after eventual reuse.
Enabling it without ASan is a compile error. Ordinary builds retain the same
allocator size and allocation path.

For targeted structure validation without ASan:

```bash
./test/run_odin_tests.sh vendor/tlsf/ -define:TLSF_CHECK_INVARIANTS=true -define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true
```

The structure checker is opt-in and requires assertions enabled. Its per-operation
heap walks and independently allocated scratch map are intentionally expensive;
do not enable it for production or throughput measurements.

## Protocol fuzzing (coverage-guided)

`test/run_protocol_fuzz.sh` builds a libFuzzer + AddressSanitizer binary whose
target is the protocol request and response parsers, then runs a bounded
campaign. It complements the Hegel properties: Hegel checks named invariants on
generated messages, libFuzzer explores byte-level mutations of real client and
server messages.

Prerequisites are Odin plus clang 19 or newer with its sanitizer runtimes and
the matching `llvm-link` (Debian/Ubuntu: `clang-19 libclang-rt-19-dev llvm-19`).
Override the compiler with `CLANG=...`; `ODIN_BIN` selects Odin. The version
floor is set by the IR, not by taste: Odin emits `#dbg_declare` debug records,
which LLVM only accepts from version 19 on, and clang 15 and 16 reject the
module with `expected instruction opcode`. Opaque pointers alone would only
need version 15.

```bash
# Build only.
./test/run_protocol_fuzz.sh --build

# Bounded campaign: 60 seconds by default, or an exact run count.
./test/run_protocol_fuzz.sh --seconds 60
./test/run_protocol_fuzz.sh --runs 1000000

# Regenerate the committed seed corpus after a wire-format change.
./test/run_protocol_fuzz.sh --seeds

# Fail if the committed corpus no longer matches the serializers.
./test/run_protocol_fuzz.sh --check-seeds

# Re-run a crash artifact; the campaign prints this command on failure.
./test/run_protocol_fuzz.sh --replay test/protocol_fuzz/artifacts/crash-<hash>
```

The target covers every client-to-server opcode in `Opcode`: all task, asset,
edge, graph, ticket, direct-message, legacy-chat, retained-message and history
requests, and `C_ApplyTransaction` with its eight operation types. It also covers
every server-to-client response that has an Odin parser: handshake, chat,
presence, stats, auth, direct messages, retained-chat pages, tasks, slices,
assets, note lists, edges, and the graph result messages. Each one is parsed
through the same function its caller dispatches to. A unit test in the package
walks `Opcode` and fails if any `C_*` or parseable `S_*` member has no dispatch
case, so adding an opcode cannot silently shrink what the campaign reaches. The
handful of responses that only the Go CLI and the JS client decode are listed
explicitly as a manual inventory; adding an Odin parser requires removing the
opcode from that list and adding a dispatch case. The guard verifies the
target's dispatch, not whether a parser exists in the protocol package. The
target starts no workers, sockets or files.

It dispatches on the real two-byte opcode, caps inputs at 128 KiB, runs with a
nil logger, and asserts that every returned byte field borrows from the input
slice instead of fabricated memory. Request parsers run with a nil allocator;
response parsers that build lists get a per-input arena that is destroyed before
the next input. A returned error is a normal result; only an assertion, a
sanitizer finding, or a crash fails the run.

`test/protocol_fuzz/corpus/` holds the committed seed set, one seed per opcode
and direction. Every seed is produced by a serializer or `write_*` helper in the
protocol package — the client serializers for requests, the operation-body
serializers for transactions, and the server serializers for responses — and the
generator re-parses each one before writing it, so a serializer/parser drift
fails regeneration instead of silently shrinking coverage. Adding a request or
response format therefore means adding its serializer next to the others rather
than encoding bytes in the fuzz tooling. `--check-seeds` rebuilds the corpus in
a scratch directory and diffs it against the committed one; the full matrix runs
that check, so a wire change cannot leave the corpus stale. Campaigns grow a
working copy under `test/protocol_fuzz/.build/corpus`; both that directory and
the crash artifacts are ignored by Git.

The build has two non-obvious constraints. The first is the clang floor above.
The second is that the linked module must be compiled to an object without
`-fsanitize=address`. Clang adds no AddressSanitizer checks when it compiles
this IR (a one-line C function emitted to IR and recompiled the same way also
gets none), so Odin's `-sanitize:address` is what actually instruments the
parsers and clang contributes only the sanitizer-coverage pass. Enabling
`-fsanitize=address` on the IR as well produced a binary that
segmentation-faults during Odin runtime startup in `os.get_args`, so the runner
leaves it off. The
per-package modules are merged with `llvm-link` into one unit before compiling;
separate per-package objects also link on this toolchain, so merging is a
simplification rather than a requirement. Odin's generated `main` is kept as the
program entry so the same binary also runs as a plain Odin program for
`--seeds`, and it hands control to `LLVMFuzzerRunDriver` from
`libclang_rt.fuzzer_no_main`. Keeping it is a convenience, not a requirement:
the same target linked under libFuzzer's own `main`, without Odin's entry point
and therefore without `__$startup_runtime`, executed the whole corpus at
identical coverage.

The wiring is verified by a negative control: an injected one-byte heap
over-read in a parser is reported as
`AddressSanitizer: heap-buffer-overflow` at that file and line, written as a
`crash-*` artifact, and reproduced by `--replay`, both with exit status 134.

Coverage figures come from 30- to 40-second campaigns on one x64 machine with
`-max_len=8192`. They are indicative rather than stable, because the budget is
wall-clock time rather than a run count. The committed seeds cover 1,412
instrumented edges on load and a campaign reaches roughly 3,300 at about 65,000
executions per second. The response direction costs roughly half the throughput
of the request-only target because the allocating parsers get a fresh arena per
input. The corpus buys a large head start, not reachability: the mutator and its
auto-dictionary still find most of the same counters on their own within the same
budget.

This is not a substitute for the rest of the matrix. The target stops at the
parsers: it covers no handler state, persistence, or serialization, and it finds
memory errors reachable from a single message payload rather than logic errors
that need workspace state. ASan still cannot see TLSF metadata helpers, which
intentionally bypass it.

## Go client decoder fuzzing

`protocol-go/fuzz_test.go` routes a server-to-client frame through the same
decoders the CLI uses. It seeds from the Odin response corpus under
`test/protocol_fuzz/corpus/`, so both implementations see the exact bytes the
server serializers produce. A decoder error is a normal result; a panic, OOM or
timeout fails the run. Opcodes without a Go decoder (`S_TaskAssignees`,
`S_HistoryPage`, and the retired voice/screen-share range) are skipped.

```bash
cd protocol-go
# Seeds only; this is what the full matrix runs.
go test ./...

# Bounded campaign.
go test -run '^$' -fuzz '^FuzzDecodeServerFrame$' -fuzztime 60s .
```

The first campaign found two decoder bugs, both fixed with regression tests:
`S_AllEdgeList` trusted a four-byte edge count before allocating, so a 16-byte
frame could exhaust memory; and the graph query, shortest-path and
common-neighbors decoders read the edge count without checking that the node
list had left two bytes for it. Failing fuzz inputs are kept under
`protocol-go/testdata/fuzz/FuzzDecodeServerFrame/` and therefore run as ordinary
cases in every `go test`.

A follow-up review hardened the remaining count-derived allocations: every
decoder preallocates at most `recordCapacity` (256) records and grows the slice
as records are actually parsed, so a claimed count cannot allocate the full
slice before the first truncation error. Edges now go through
`parseEdgeStrict`, which rejects a creator length that runs past the frame
instead of letting missing creator bytes be read as the trailing correlation ID.
`TestRecordCapacityCapsCountDerivedSlices`,
`TestDecodeAllEdgeListRejectsTruncatedCreator` and
`TestDecodeEdgeCreatedRejectsTruncatedCreator` cover those contracts. The
`S_AllEdgeList` count is kept unsigned until the capacity check, so
`0xffffffff` is rejected on 32-bit builds instead of becoming `-1` and panicking
in `make`; `GOARCH=386 go test ./...` is part of the verification.

Zstd asset payloads are bounded before decompression: `DecodeAssetPayload`
rejects a `payload_raw_len` above `MaxPayloadLength` and a compressed payload
above the same limit, then caps `DecodeAll` at the declared raw length through
the destination capacity and `WithDecodeAllCapLimit`. The decoder memory limit
is 8 MiB, not `MaxPayloadLength`: zstd clamps the allowed frame window to that
limit, and a valid non-single-segment frame for 65535 bytes uses a 65536-byte
window. A small compressed frame therefore cannot expand into a multi-megabyte
allocation before the length check, while valid frames with a larger window are
still accepted. `TestDecodeAssetPayloadBoundsZstdExpansion` uses a 4096-byte
expansion so it isolates the capacity cap from the global memory limit;
`TestDecodeAssetPayloadAcceptsZstdAtLimit` and
`TestDecodeAssetPayloadAcceptsNonSingleSegmentWindow` cover the valid
65535-byte boundary in both frame layouts.

## JS client decoder fuzzing

`client/protocol.js` holds the shared record decoders and `client/frames.js`
holds the shared whole-frame decoders. Both are ordinary browser scripts; the
client loads them before the handlers, and the handlers in `app.js`, `tasks.js`,
`assets.js`, `edges.js`, `calendar.js`, `history.js`, `overview.js`, `slices.js`,
`task-query.js` and `transactions.js` call them. `client/fuzz/protocol.fuzz.cjs`
drives the same `decodeServerFrame` dispatcher, so a campaign exercises the
production frame path rather than a parallel copy.

`decodeServerFrame` covers every server-to-client response opcode the client
handles: 53 opcodes from `S_ServerReady` (100) through `S_CalendarPeople` (173).
`S_StatsResponse` (110) is deliberately excluded because the browser client
ignores it; `S_AuthResponse` (111) is not in the client opcode table. Other
opcodes return `null`.

The committed corpus under `test/protocol_fuzz/corpus/` is reused directly,
together with JS-only seeds under `client/fuzz/corpus/`:
`client/fuzz/seed-corpus.cjs` copies every supported server frame and fails if a
committed seed stops decoding or an opcode has no seed. Campaigns grow
`client/fuzz/.build/corpus`; rerunning `--seeds` overwrites only the named
seeds, so inputs discovered by earlier campaigns survive. The normal test
tier replays every supported seed, every truncation and one trailing-byte
mutation through `node --test client/protocol-fuzz.test.mjs`; it also checks the
opcode-to-kind table. The coverage-guided campaign is opt-in because it installs
Jazzer.js and its native addon.

```bash
# Seed replay; this is what node --test client/*.test.mjs runs.
node --test client/protocol-fuzz.test.mjs

# Bounded campaign (installs client/fuzz dependencies on first use).
./test/run_js_protocol_fuzz.sh --seconds 60
./test/run_js_protocol_fuzz.sh --runs 1000000

# Rebuild the working corpus only.
./test/run_js_protocol_fuzz.sh --seeds

# Re-run one artifact.
./test/run_js_protocol_fuzz.sh --replay client/fuzz/artifacts/crash-<hash>
```

A `ProtocolError` is a normal result for malformed input; a hang, OOM, or any
other exception fails the run. JS has no AddressSanitizer, so the campaign
looks for unbounded work and state-independent decoder faults rather than
memory errors. Jazzer's prototype-pollution and path-traversal detectors are
also active.

`@jazzer.js/core` is pinned to 2.1.0 because the 4.0.0 prebuilt addon requires
glibc 2.38 and Debian 12 ships 2.36. Bump the pin on a newer runner image.

## Full local

Run both production and deterministic-simulation root suites before merging changes that cross handlers, persistence, protocol, connection lifetime, or worker boundaries:

```bash
odin test . -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test . -o:speed -define:NRC_SIMULATION=true -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
```

Package checks can be run independently:

```bash
odin test websocket/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test protocol/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test persistence/ -o:speed -define:ODIN_TEST_LOG_LEVEL=error
odin test persistence/ -o:speed -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error
odin test btree/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test byte_pool/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test clock/ -o:speed -define:ODIN_TEST_LOG_LEVEL=error
odin test nbio/ -o:speed -define:ODIN_TEST_LOG_LEVEL=error
odin test hegel/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
```

## Hegel availability and diagnostics

Hegel properties use `libhegel` 0.47.1; no library binary ships in the current
source tree. The test wrapper, seed campaign and mutation runner fetch the pinned
Linux amd64 release into `.hegel/libhegel-0.47.1/` and verify its SHA256. A valid
cache works offline. Failed downloads and corrupt cache files stop the runner;
remove a corrupt cached file to download it again.

`./test/run_odin_tests.sh` sets `HEGEL_REQUIRED=true` unless a caller explicitly
supplies that define. Direct Odin commands should set it too, so a missing,
unloadable or incorrectly versioned library fails rather than skipping properties.
The wrapper accepts `HEGEL_LIBHEGEL_PATH` for a trusted local 0.47.1 library on
other platforms or offline installations. Campaign and mutation runners always
use the pinned Linux download, not a caller override.

The reproduction database remains separate under `.hegel/examples/0.47.1/`;
native reproduction blobs are only compatible with the library version that
created them. Server builds and starts do not fetch or load Hegel.

Set `HEGEL_DIAGNOSTICS=1` to print property progress, executed/interesting counts, and timing. Property failures print a focused `ODIN_TEST_NAMES` command; generated model failures may also print a literal replay fixture.

## Local multi-seed Hegel campaign

No GitHub Actions quota is required. Run from any directory with Python 3, GNU `timeout`,
and Odin installed (`ODIN_BIN` can select the compiler):

```bash
python3 test/run_hegel_campaign.py --seconds 900 --seed 2026090902
# Reproduce one generation seed with the same source/compiler:
python3 test/run_hegel_campaign.py --seed 2026090902 --runs 1 --seconds 190
```

The runner builds one optimized simulation executable, waits for the compiler to exit, then
runs 15 durability, compaction-publication, and connection-lifecycle properties in sequential
processes. Each process uses a distinct nonzero `HEGEL_SEED`, a fresh example database, one
test thread, multiplier 1, and fatal memory checks. Odin's test-order seed stays fixed; it
does **not** control Hegel generation. Diagnostics verify that every selected property ran
with the requested generation seed.

The default execution budget is 15 minutes, excluding compilation. Each process has a
180-second timeout; the runner avoids starting another seed when it is unlikely to finish
within the remaining budget. Timeout cleanup may take five additional seconds. Any failure
or timeout stops the campaign and returns nonzero; an interrupted run is not a passing seed.
Ctrl-C during a seed stops its process group, preserves the database and reproduction
instructions, and records an `interrupted` result before removing temporary files.

Results default to a new `.amp/in/artifacts/hegel-campaign-<UTC timestamp>/` directory, or
use `--output <new-directory>`. It contains compiler/source metadata, the tracked source diff,
a runner snapshot, per-seed logs, case counts, and a summary. Failures also retain the Hegel
database and a reproduction command. With diagnostics enabled, native failures print their
minimized reproduction blobs even when the caller suppresses its logger. A native error or
timeout may not produce a minimized example. Successful campaigns demonstrate only the
selected histories, not exhaustive correctness. These runs measure correctness, not throughput.

Test the runner itself with:
`PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p test_hegel_campaign.py`.

## Local targeted mutation audit

Check whether tests detect six deliberately introduced faults:

```bash
python3 test/run_mutation_audit.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p test_mutation_audit.py
```

The runner audits **committed HEAD**, excluding staged, unstaged, and untracked changes.
It creates a detached temporary worktree and builds the clean six-test baseline, then
one mutant at a time: ACK before fsync, socket lookup instead of generational I/O-context
lookup, catalog checksum bypass, and omitted replay application while the task floor is
zero, plus bypassed DM membership authorization and message fanout across workspaces.
The workspace mutant broadcasts to every workspace's matching conversation rather than
only the sender's workspace; its detector requires a frame at the wrong-workspace recipient.
The fixture collides both recipient usernames and conversation IDs. The DM detector requires evidence of
an unauthorized message reaching a legitimate participant, not merely a changed error
response. All seven optimized simulation builds run sequentially, with required Hegel,
generation seed 12345, one test thread, and fatal memory checks. Each test process gets
fresh disposable data and a fresh Hegel database. No hosted CI is used.

Success requires the baseline to pass and each mutant to produce its specific expected
assertion/property failure. A surviving mutant, changed source anchor, compiler error,
crash, memory error, unexpected failure, or timeout makes the audit fail. This is a
six-fault sensitivity check, not a general mutation score or proof of correctness.
Changed code or test diagnostics may require explicitly updating the audit anchors.

`--timeout 300` sets the limit in seconds **per build and per test process**, not for the
whole audit. Timeout or Ctrl-C stops the process group before cleanup. The disposable
worktree is removed on completion or handled failure; the original worktree is untouched.
An uncatchable kill of the runner can require manual removal with `git worktree remove`.

Results default to `.amp/in/artifacts/mutation-audit-<UTC timestamp>/`; `--output` accepts
a new directory. `summary.json` records the source commit, compiler version, fixed seed,
build commands, statuses, and exact mutation definitions. Each case retains build/test
logs, a mutation patch, and any Hegel reproduction database. A runner snapshot is also
saved. To reproduce a failure, create a disposable worktree at the recorded commit,
apply that case's patch with `git apply`, and use its recorded build flags (replace the
temporary `-out:` path). Run with `HEGEL_SEED=12345 HEGEL_DIAGNOSTICS=1
HEGEL_TEST_CASE_MULTIPLIER=1` and `HEGEL_LIBHEGEL_PATH` pointing to the downloaded
library version used by that run (currently 0.47.1); the test log retains native
minimized reproduction blobs when Hegel produces them.

## Local simulation stress

Run the full simulation suite with required Hegel support when needed:

```bash
HEGEL_DIAGNOSTICS=1 odin test . -o:speed \
  -define:NRC_SIMULATION=true \
  -define:HEGEL_REQUIRED=true \
  -define:ODIN_TEST_LOG_LEVEL=error
```

## Local real-environment faults

The race-enabled real-process suite below runs four 60-step outside-in campaigns with consecutive
replayable seeds derived from `NRC_FAULT_CAMPAIGN_SEED`. The campaigns cover TCP reset,
half-close and delay, reconnects, process pause, and in-flight `SIGKILL`. Separate
once-per-run tests cover targeted multi-client isolation and concurrent multi-workspace
crashes. The suite also exercises a kernel `EFBIG` write rejection, a real partial WAL
write, and a non-writable shard directory at rotation, then checks acknowledged-prefix recovery and
continued writes. Abrupt restart, trailing shard-WAL garbage, worker-count resize, compaction
publication crashes, and slow-reader backpressure remain in the same suite. These tests exercise the
real kernel, filesystem, process lifecycle, and WebSocket stack rather than simulation failpoints.
`RLIMIT_FSIZE` reaches io_uring writes; the previous strace `write(2)` injector did not.
`ENOSPC` completion failures remain covered by the deterministic simulation suite.
`SIGKILL` coverage verifies kernel-accepted bytes; deterministic WAL crash tests model loss of
un-fsynced bytes.

```bash
cd test/e2e
NRC_FAULT_CAMPAIGN_SEED=12345 NRC_FAULT_CAMPAIGN_STEPS=60 NRC_FAULT_CAMPAIGN_RUNS=4 \
go test -race -count=1 -timeout=20m \
  -run '^(TestOutsideInFaultCampaign|TestOutsideInMultiClientFaultCampaign|TestOutsideInConcurrentMultiWorkspaceCrash|TestOutsideInWALWriteErrorRecoversAcknowledgedPrefixAndContinues|TestOutsideInPartialWALWriteTruncatesTailAndContinues|TestOutsideInNonWritableShardDirectoryDefersRotationAndRecovers|TestDirtyRestartRecoversKernelAcceptedTaskAssetEdgeState|TestDirtyRestartTruncatesTrailingShardWALGarbage|TestCompactionCrashBoundariesRecoverExactStateAndContinueWriting|TestWorkerCountResizeReassignsReplaysAndContinuesWrites|TestSlowReaderBackpressureDoesNotStopHealthyPeer)$' -v
```

Replay one failed campaign with its logged seed, preserving the step count and selecting only
that seed's subtest:

```bash
cd test/e2e
NRC_FAULT_CAMPAIGN_SEED=12345 NRC_FAULT_CAMPAIGN_STEPS=60 NRC_FAULT_CAMPAIGN_RUNS=1 \
go test -race -count=1 -timeout=20m \
  -run '^TestOutsideInFaultCampaign$/^seed-12345$' -v
```

For controlled load testing, microbenchmarks, masking throughput, WAL/compaction workloads, and comparison tools, see `docs/BENCHMARKS.md`.
