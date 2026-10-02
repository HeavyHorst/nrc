# NRC Deterministic Simulation Plan

> **Current plan, not an implementation diary.** This document describes the architecture that exists,
> the invariants it owns, and the remaining work. Historical slice-by-slice detail belongs in Git history.
> The persistence format is documented in [`SHARDED_PERSISTENCE.md`](SHARDED_PERSISTENCE.md), and commands
> are maintained in [`TEST_MATRIX.md`](TEST_MATRIX.md).

NRC is building a FoundationDB/TigerBeetle-style deterministic testing system for a single-node,
multi-worker server. The transferable idea is not “one enormous random test.” It is:

1. run production decision paths over deterministic environmental seams;
2. express asynchronous work in one seed-controlled world;
3. compare every meaningful state transition with an independent model or invariant;
4. make crash durability depend on completed storage snapshots rather than live memory; and
5. retain focused campaigns where they provide a sharper oracle than global composition.

NRC does not implement replication or consensus, so it should not imitate distributed-database scenarios
that have no corresponding production invariant.

## Target Architecture

```text
Hegel choices / fixed schedule
             │
             ▼
      workload + simple model
             │
             ▼
┌────────────────────────────────────────────────────────────┐
│ Sim_World                                                  │
│                                                            │
│  canonical event queue          Virtual_FS                 │
│  ├─ virtual time                ├─ volatile namespace/data │
│  ├─ process incarnation         ├─ durable namespace/data  │
│  ├─ worker ownership            ├─ captured fsync snapshot │
│  ├─ causal predecessor IDs      └─ crash reconstruction    │
│  └─ owned event payloads                                   │
└───────────────────────────┬────────────────────────────────┘
                            │ production seams
                            ▼
┌────────────────────────────────────────────────────────────┐
│ Real NRC code                                              │
│ parser → handlers → models/indexes → WAL/compaction        │
│ connection/send ownership → worker pre/post-tick phases    │
└────────────────────────────────────────────────────────────┘
```

Workload generation and correctness models remain outside the kernel. `Sim_World` owns environmental
ordering and resources; it must not learn Task, Asset, Edge, DM, or retained-message semantics.

## Non-Goals

1. No distributed-replica or consensus simulator.
2. No replacement for focused unit, parser, persistence, or real-process tests.
3. No generic workload/profile/invariant registry until two semantic workloads require the same lifecycle
   contract.
4. No first-class replay CLI while Hegel’s reproduction database and executable Odin fixtures reproduce
   actual failures.
5. No outbound TCP byte-stream model until a concrete partial-delivery invariant is missing. Outbound frames
   are currently atomic captures; send progress and completion ownership are modeled separately.
6. No attempt to simulate arbitrary Linux scheduling or all POSIX filesystem behavior.
7. No new campaign merely to add another endpoint, enum value, or example to an already-owned invariant.

## Established Contracts

### One Authoritative Event Kernel

`Sim_World.events` is the only authoritative simulation queue. Events carry:

- monotonic, never-reused identity;
- virtual `ready_at` time;
- process incarnation;
- logical target and captured worker owner;
- diagnostic domain;
- optional causal predecessor; and
- one explicitly owned payload.

The kernel supports timer, send, shutdown-send, receive, close, fsync, file-read, compaction-job,
compaction-result, worker driver-action, and process-crash domains. Domain-filtered helpers are views over
the same queue; they cannot advance time past globally runnable work.

Canonical order is `(ready_at, event_id)`. Generated campaigns select a rank from that ordered runnable
set. Domains never create a hidden scheduling priority. Per-connection receive dependencies preserve TCP
byte order while allowing independent connections and workers to interleave.

Each payload has exactly one terminal disposition:

1. normal dispatch;
2. cancellation;
3. stale-incarnation discard; or
4. world teardown.

Dispatch and destruction enter the captured worker TLS before touching worker-local handles, pools, writers,
or connections. A process-crash event advances the incarnation without graceful callbacks; stale payloads
later run only their ownership-release path.

### Explicit Virtual Storage

`storage_io.Context` is a borrowed, copyable context used by WALs, writers, manifests, compaction jobs, and
path-only recovery helpers. Virtual storage never silently falls back to host `core:os`.

`storage_io.Virtual_FS` models:

- inode identity and open handles across rename/remove;
- volatile and durable file bytes;
- volatile and durable namespace state;
- create/exclusive/truncate/read/write/stat/list/remove/rename;
- independent file and directory sync;
- submission-time asynchronous fsync snapshots;
- old-incarnation handle invalidation; and
- fail-stop storage-effect boundaries and conservative torn WAL suffixes.

In VirtualFS, a successful asynchronous fsync applies its captured submission-time snapshot before calling
the production completion unless a newer version is already durable. Older completions never roll durable
state back. Failure or crash-before-completion commits nothing. File sync does not publish an unsynced
directory entry, and directory sync does not make unsynced file bytes durable.

Host-filesystem matrices and real `SIGKILL` tests remain differential validation. They are not the source of
deterministic storage semantics.

### Production Worker Boundaries

Production and simulation share two extracted boundaries:

1. `worker_run_pre_tick` runs pending connections, shard-fsync scheduling, retained-message maintenance,
   compaction-result channel draining, and compaction scheduling in production order.
2. `worker_finish_callback_wave` publishes retained writes and deferred normal outboxes once after a batch of
   I/O callbacks.

The simulator can dispatch an explicit same-worker callback wave. Events are claimed before the first
callback, newly created events cannot join the active wave, nested dispatch is rejected, and the post-wave
boundary executes exactly once.

The simulator deliberately does not wrap `nbio.tick` in a fake “whole worker iteration.” I/O completions are
explicit event/wave choices. Add a larger turn abstraction only if a correctness invariant spans pre-tick,
the exact callback set returned by one kernel tick, and post-tick publication.

Two fixed causal proofs guard the pre-tick extraction:

- preemptive WAL rotation during fsync scheduling makes compaction eligible later in the same turn; and
- owner-channel compaction-result publication returns a writer from `Building` to an eligible state before
  exactly one follow-up job is scheduled.

The globally ranked two-worker compaction-issuance workload uses `worker_run_pre_tick`, not a direct call to
the compaction scheduler.

### Independent Models and Oracles

Models describe legal externally meaningful state, not implementation structure. They use simple maps,
sets, fixed arrays, and sorted slices rather than production B-trees, adjacency indexes, parsers, or WAL
decoders.

The principal semantic model checks:

- complete Task, Asset, and Edge fields;
- ownership and recursive cascades;
- task and Note indexes;
- graph adjacency and query results;
- active counts and paging order;
- task/asset/edge high-water floors; and
- exact durable transaction prefixes.

Transport models check generational connection identity, pending I/O pins, send queues, callback ownership,
watchdog state, pooled-buffer leases, subscriber/membership state, and exact output ledgers.

Persistence models distinguish:

- live/speculative state;
- accepted but unsynced records;
- fsync-snapshot durable prefixes;
- manifest-published authority; and
- valid orphan files that must remain non-authoritative.

Every crash/recovery campaign must reopen through the production storage path, compare the exact legal durable
state, perform a continued write, and normally verify a second restart.

### Entropy, Shrinking, and Replay

Hegel draws semantic operations, fault choices, receive splits, durable boundaries, and runnable ranks
directly so failures can shrink. Do not draw one opaque PRNG seed inside a Hegel property and hide all useful
choices behind it.

The current replay contract is sufficient:

1. `HEGEL_SEED` reproduces the campaign’s generated cases.
2. Stable call-site database keys retain minimized reproduction blobs under
   `.hegel/examples/0.33.3/`.
3. Semantic campaigns print executable Odin fixtures where a stable operation trace is useful.
4. CI uploads hidden `.hegel` artifacts and diagnostics.

Add a replay CLI or external operation-log format only after a real CI failure cannot be reproduced from
those artifacts. A speculative replay framework would add another format without improving current failures.

## Current Coverage Ownership

The table records invariant ownership, not every test name.

| Family | Primary invariant | Principal coverage |
| --- | --- | --- |
| Transactional semantic model | Task/Asset/Edge/index/adjacency/floor equivalence | Generated live mutation, rotation, compaction, crash/replay, paging, and graph observations |
| Durable-prefix recovery | Reopen equals one exact acknowledged/snapshot prefix | Generated histories, every representative WAL cut, torn tails, semantic corruption, continuation writes |
| Compaction publication | Manifest-selected state is authoritative across build/install/cleanup faults | Fixed failpoint matrices, VirtualFS effect cuts, repeated generations, stale-result rebase, orphan classification |
| Event-kernel ownership | Every callback payload is dispatched or destroyed exactly once under its owner | Cancellation, stale incarnation, dependency chains, quiescence, worker switching |
| Connection lifetime | Old generations cannot mutate replacements and every lease is released once | Send/receive/close/timer/watchdog/partial-write interleavings and socket reuse |
| WebSocket receive/parser | Chunking is semantically irrelevant; malformed prefixes classify independently | Arbitrary receive compositions, framing oracle, handler-policy oracle, post-error usability |
| Graph ranking | Filtered multi-anchor traversal, evidence paths, and personalized ranking match an independent model | Generated direct/split-wire equivalence across topology, anchor weights, candidates, depth, relation, direction, and top-N |
| Global one-worker composition | Transport, fsync, cleaner, crash, and handler semantics agree | Dependent full-WebSocket histories, deferred WAL work, retained reads/writes, exact output ledgers |
| Global two-worker composition | Worker-local ownership and durability remain independent in one world | Ranked receive/send/fsync/crash, compaction issuance/publication/rebase, continuation and second restart |
| DM authorization | Membership, subscription, routing, reconnect, and workspace isolation match a model | Generated pending semantic/lifecycle histories with exact recipient ledgers |
| Retained messages | Active/sealed history, dedup, read ownership, and durability match sequence models | Focused models plus VirtualFS/global read, append, fsync, crash, and callback-wave composition |
| Real environment | Kernel, process, filesystem, and WebSocket assumptions hold outside simulation | Go E2E with `SIGKILL`, TCP faults, backpressure, ENOSPC/partial writes, resize, and compaction stages |

This layered structure is intentional. A focused parser or storage campaign is not duplicate merely because a
global workload touches the same subsystem: it is duplicate only when production path, fault dimension, and
oracle are all materially the same.

## Rules for New Work

A proposed campaign or extension must answer all of these:

1. **What new invariant is checked?** “More endpoints” or “more random cases” is insufficient.
2. **Which production decision path was previously absent?** Name the exact branch or phase boundary.
3. **Why can an existing campaign not own it?** Prefer extending the narrowest existing owner.
4. **What independent oracle rejects a plausible wrong implementation?** State the counterfactual failure.
5. **What is the local and nightly event budget?** Case count alone is not a coverage metric.
6. **How does failure shrink and replay?** Include semantic choices and event ranks.
7. **Which resources must return to baseline?** Include callbacks, pins, pools, reservations, files, and
   deferred ownership.

Do not add the work if these answers collapse to an existing invariant. Add a mandatory fixed schedule when a
generated choice could miss the critical state; use Hegel around that anchor to explore neighboring states.

## Remaining Plan

### Priority 0 — Measure and Rebudget Existing Campaigns

Status: baseline complete. [`DETERMINISTIC_SIMULATION_BUDGET.md`](DETERMINISTIC_SIMULATION_BUDGET.md) records
the fixed-seed local and 4× runs, Hegel cases and body time by invariant owner, simulation source-group costs,
peak memory, and the duplication assessment. The measured 4× suite takes about 94 seconds, so there is no
evidence-based reason to split or reduce it. Its 2.23 GiB peak RSS is a reason not to raise the blanket multiplier
without another memory measurement.

The measurement procedure remains:

1. Measure each simulation test/property with one fixed seed, local case counts, optimized builds, and Hegel
   diagnostics. Record wall time, generated cases, and where available operation/event counts.
2. Group costs by invariant owner from the table above. Identify accidental overlap only where production path,
   generated dimension, and oracle are the same.
3. Preserve the bounded full simulation suite in PR CI. Do not weaken deterministic branch anchors to improve
   timing.
4. Replace the blanket nightly multiplier only after measurements identify expensive low-yield repetition or
   underfunded high-value persistence/kernel campaigns.
5. Prefer explicit filtered nightly groups with separate seeds/budgets over a new runtime profile registry. Odin’s
   existing `ODIN_TEST_NAMES` filter and `HEGEL_TEST_CASE_MULTIPLIER` are enough initially.
6. Keep one periodic full-suite stress run as a canary if weighted groups replace the nightly blanket run.

Acceptance:

- a checked-in report maps generated property names and fixed campaign groups to time and invariant owner;
- PR and nightly budgets are stated in wall time and generated work, not only multipliers;
- any removed/reduced overlap has a written invariant-equivalence justification; and
- Hegel failure artifacts remain independently retained for each scheduled group.

All acceptance points are satisfied without changing CI allocation. Revisit this priority after a material
campaign/budget change or a 25% runtime or memory regression.

### Priority 1 — Deepen Existing Global Histories Only at New Causal Boundaries

The kernel, VirtualFS, worker switching, production pre-tick, and callback-wave boundary are established. A real
worker-owned compaction-result channel is now covered while another worker completes storage progress before the
owner's production pre-tick drains that channel and issues same-turn follow-up work. The retained-message and shard
WAL models also already share generated crash decisions with independent durable subsets. The next global extension
must expose a production decision that current schedules cannot falsify.

The remaining good candidate, only when tied to the concrete publication invariant, is:

1. Generated callback-wave grouping where multiple callbacks genuinely share retained-write or deferred-outbox
   publication semantics.

Do not add a generic worker-turn scheduler or migrate every direct helper call for aesthetic consistency. Existing
direct dispatch remains valid for focused ownership/corruption tests.

Acceptance for any extension:

- the old implementation can be mutated in one plausible way that makes the new test fail;
- the history reuses an existing semantic model and output/quiescence oracle;
- crash recovery derives state only from completed snapshots and published authority; and
- continuation plus second restart still pass.

### Priority 2 — Strengthen Coverage Signals, Not Campaign Count

Case count does not show whether meaningful states occurred. Add lightweight test-only transition accounting only
where a campaign currently cannot prove reachability from its mandatory fixtures.

Useful signals include:

- publication outcomes and fault boundaries reached;
- durable-prefix masks and fsync-attempt outcomes;
- worker ownership and stale-destruction paths;
- callback-wave sizes and publication counts;
- manifest/catalog shapes and orphan classifications; and
- quiescence failure categories.

Prefer assertions local to the existing campaign. Do not build a generic coverage framework unless at least two
campaigns require the same counter and reporting lifecycle.

### Priority 3 — Optional Real-Process Chaos

Simulation cannot validate kernel FD reuse, actual `io_uring`, filesystem behavior, process startup, or scheduler
effects. Keep real-process coverage thin and externally modeled.

Add more chaos only when test telemetry proves the intended state occurred—for example, the same numeric FD reused
while an old generation still has pending I/O, or `SIGKILL` during a reported compaction phase. Save exact operation,
fault, and kill traces. Do not use timing-only failures as evidence of a covered race.

## Explicit Deferrals

- **Workload registry:** deferred until two semantic workloads share begin/apply/dispatch/check/finish semantics.
- **Replay CLI:** deferred until Hegel database artifacts fail to reproduce a real failure.
- **Outbound byte streams:** deferred until complete-frame capture misses a concrete peer-observation invariant.
- **More graph/query endpoints:** existing structural, shortest-path, neighborhood, common-neighbor, paging, and
  nonmutation models are sufficient until a new ranking/filter invariant appears.
- **More authorization campaigns:** existing generated pending lifecycle histories own this state space.
- **Broader VirtualFS/POSIX behavior:** add only a storage outcome required by production recovery.
- **One giant global workload:** rejected. Focused campaigns plus bounded global compositions provide better models,
  shrinking, and diagnosis.
- **Continuous fuzzing service:** deferred until measured nightly groups demonstrate sustained useful work that CI
  cannot provide. If added, it is an operations/results pipeline, not another fuzzer.

## Budget Policy

Current baseline on 2026-09-05 in a constrained `a1.small` orb, single-threaded compilation and test execution:

- normal root suite: 437 tests in about 18 seconds;
- simulation root suite: 486 tests in 45.56 seconds with 15,208 generated cases and 1.01 GiB peak RSS;
- simulation 4× suite: 486 tests in 94.04 seconds with 59,076 generated cases and 2.23 GiB peak RSS; and
- focused pre-tick/compaction composition: 3 tests in about 2.4 seconds.

These are development measurements, not CI thresholds. PR CI keeps the full bounded simulation suite and an
18-minute diagnostic watchdog inside a 20-minute job. Nightly currently uses
`HEGEL_TEST_CASE_MULTIPLIER=4` with a 55-minute watchdog. The measured baseline supports retaining both settings;
the watchdogs are diagnostic ceilings rather than expected runtimes.

Use these tiers:

1. **Focused iteration:** exact `ODIN_TEST_NAMES`, fixed seed, local case counts.
2. **PR/push:** full normal and simulation suites at local budgets.
3. **Nightly:** measured weighted groups plus a periodic full-suite canary; until implemented, retain the current
   full 4× run.
4. **Real-environment schedule:** seeded Go fault campaigns, independent from deterministic simulation budgets.

## Verification Commands

Use [`TEST_MATRIX.md`](TEST_MATRIX.md) as the command source of truth. Root Odin suites must run sequentially in
constrained environments.

```console
# Focused simulation
HEGEL_SEED=12345 odin test . -o:speed \
  -define:NRC_SIMULATION=true \
  -define:HEGEL_REQUIRED=true \
  -define:ODIN_TEST_LOG_LEVEL=error \
  -define:ODIN_TEST_NAMES=main.test_name,

# Full root suites
odin test . -o:speed -define:HEGEL_REQUIRED=true -define:ODIN_TEST_LOG_LEVEL=error
HEGEL_SEED=12345 odin test . -o:speed \
  -define:NRC_SIMULATION=true \
  -define:HEGEL_REQUIRED=true \
  -define:ODIN_TEST_LOG_LEVEL=error

# Stress controls
HEGEL_DIAGNOSTICS=1 HEGEL_SEED=12345 HEGEL_TEST_CASE_MULTIPLIER=4 \
  odin test . -o:speed \
  -define:NRC_SIMULATION=true \
  -define:HEGEL_REQUIRED=true \
  -define:ODIN_TEST_LOG_LEVEL=error
```

## Completion Standard

The architecture is at the intended foundation when:

1. every relevant asynchronous production boundary can be represented as a deterministic event or callback wave;
2. storage crash outcomes come from VirtualFS durability and production reopen paths;
3. worker-local ownership survives cross-worker interleaving and stale-event destruction;
4. focused models own parser, persistence, transport, and authorization invariants;
5. bounded global workloads compose those pieces across real production decisions;
6. failures shrink and replay from retained Hegel artifacts or stable fixtures; and
7. CI effort is allocated by measured bug-finding value rather than campaign count.

Items 1–7 are substantially implemented at the current scale. The next decision should come from the existing kcov
artifact and direct review of high-impact production branches: selectively deepen an existing owner only when that
review identifies a new causal invariant. NRC can approach FoundationDB/TigerBeetle’s testing discipline through
this architecture, but not their distributed-protocol state space or continuous-fuzzing scale without additional
infrastructure and compute.
