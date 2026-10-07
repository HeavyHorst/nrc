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
  -define:ODIN_TEST_NAMES=main.test_generated_transactional_shard_semantic_replay_fixture,main.test_hegel_generated_transactional_shard_state_matches_replay,main.test_shard_checkpoint_preserves_floors_after_every_entity_is_deleted,main.test_shard_checkpoint_floor_witness_routes_to_every_logical_shard,main.test_hegel_simulation_generated_message_fanout_matches_model,main.test_hegel_simulation_delayed_send_completion_lifetime_choices,main.test_hegel_shard_compaction_manifest_roundtrip,
```

`ODIN_TEST_NAMES` accepts a comma-separated list of fully qualified tests. A trailing comma is supported and makes copied failure commands easy to reuse.

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
odin test ulid/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
odin test nbio/ -o:speed -define:ODIN_TEST_LOG_LEVEL=error
odin test hegel/ -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
```

## Hegel availability and diagnostics

Hegel properties use `libhegel` 0.33.3; no library binary ships in the current
source tree. The test wrapper, seed campaign and mutation runner fetch the pinned
Linux amd64 release into `.hegel/libhegel-0.33.3/` and verify its SHA256. A valid
cache works offline. Failed downloads and corrupt cache files stop the runner;
remove a corrupt cached file to download it again.

`./test/run_odin_tests.sh` sets `HEGEL_REQUIRED=true` unless a caller explicitly
supplies that define. Direct Odin commands should set it too, so a missing,
unloadable or incorrectly versioned library fails rather than skipping properties.
The wrapper accepts `HEGEL_LIBHEGEL_PATH` for a trusted local 0.33.3 library on
other platforms or offline installations. Campaign and mutation runners always
use the pinned Linux download, not a caller override.

The reproduction database remains separate under `.hegel/examples/0.33.3/`;
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
0.33.3 library; the test log retains native
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
