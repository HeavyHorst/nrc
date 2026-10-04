# Sharded Persistence

This is the current operational reference for NRC task, asset, and edge persistence.

## Workspace data and chat rooms

Protocol version 6 reserves `conv_id = 0` for workspace-owned tasks, assets and
edges, including Notes, customers, files, reminders, agendas and RoomMapping
assets. All durable queries and transaction operations require this scope.
The existing container and record codecs remain in use; scope 0 is a data
collection, not a chat room. Subscribe with `C_SubscribeConvs` to receive its
durable events. It has no chat, retained history, presence, or room-user limit.
Chat room IDs and DM IDs are unchanged. Projects, tags and relationships organize
data without splitting its identity or search scope.

Upgrade server, web client, CLI and bots together. Old clients' nonzero durable
requests are rejected, never silently redirected from a DM into public data.
This repository change does not run a production migration. Before deploying,
stop the installation and back up the entire data directory. On startup, replay
maps every legacy **public** record and tombstone to scope 0, preserving IDs,
payloads, attachments and graph relationships. New writes use scope 0. A later
checkpoint can persist that canonical representation; do not downgrade an
upgraded data directory. Restore the pre-upgrade backup for rollback.

Legacy DM data remains under its original private scope and is not exposed by
the new durable API. It requires a separately reviewed export/migration if it is
to become workspace-public. No DM payload is automatically copied into scope 0.
Existing CLI note backups likewise retain their original scope.

Replay rejects the same domain/entity ID appearing in different nonzero public
rooms, including conflicting tombstones across segments. The diagnostic names
the workspace, domain, ID and rooms; resolve the source data before restarting.
It is not a recoverable WAL tail and must not be truncated. Scope 0 is treated
as a canonical alias: the historical format cannot distinguish a separately
created legacy scope-0 object with the same ID. Installations that used custom
clients to create such records must audit that ambiguity before upgrading.

Raw segment cleaning retains original scope keys and source order, preserving
collision evidence and canonical tombstones. Existing metadata caches remain
valid. This can retain redundant legacy records until semantic checkpointing.
Checkpoint validation includes the retained active suffix before discarding
original room identities. Multiple migrated agendas retain their asset IDs;
ambiguous Agenda creation is rejected until the caller explicitly updates an ID.

## Routing and ownership

NRC has 256 logical shards independent of the runtime worker count:

```text
logical shard = XXH64(raw workspace bytes, seed 0) % 256
owner worker  = logical shard % worker count
```

Changing the worker count changes only runtime ownership. It does not rename, split, merge, or move
shard files. Worker counts from 1 through 256 are supported, including counts that do not divide 256.

Every persistent operation is encoded as one `Shard_Transaction`. A transaction names one workspace,
contains the task/asset/edge mutations that must commit together, and carries per-domain high-water
requirements. Cascade deletes therefore replay atomically, and deleted IDs are not reused after
compaction.

Client transactions validate and materialize their changed entities before WAL append. Publication
then updates only those entities and their indexes on the owning worker, without interleaving another
request. Existing conversation containers are not cloned. Reverse indexes locate task dependents and
owned assets; Note project/tag membership uses B-trees rather than shifting full sorted arrays.
Work therefore depends on the transaction and its actual cascades, plus index lookup/update cost,
not a scan of unrelated workspace contents. Hash-map growth remains amortized and tree operations
remain logarithmic; this is not a constant-latency guarantee for arbitrarily large working sets.

Allocation failures in authoritative state/index maintenance and cascade collection are process-fatal
rather than silently omitting changes. After WAL acceptance, the server must never reject a partially
published transaction or continue serving it. Recovery replays complete validated WAL transactions
before serving. A transaction whose connection was lost without an ACK may have committed; the
ACK-after-fsync contract does not remove that ambiguity.

## File layout

The data directory contains one checksummed storage-layout manifest and one active sharded generation:

```text
data/
├── storage-layout.manifest
├── storage-layout.lock
└── sharded-00000000000000000001/
    ├── shard_000/
    │   ├── shard.manifest
    │   ├── catalog-00000000000000000003.cat     # immutable segment catalog
    │   ├── cleaned-00000000000000000003.seg     # optional cleaned WAL segment
    │   ├── wal-00000000000000000001.wal         # immutable catalog member
    │   ├── wal-00000000000000000004.wal         # immutable catalog member
    │   └── wal-00000000000000000005.wal         # active WAL
    ├── ...
    └── shard_255/
```

Generation zero uses `active.wal`; later active and immutable generation files use `wal-%020d.wal`.
The checksummed `shard.manifest` is authoritative. It references exactly one active WAL, an optional
immutable segment catalog, and an optional sealed WAL retained for recovery compatibility with older
manifests. A version-2 catalog is variable length and checksummed and contains an ordered list of
immutable generation WALs, cleaned segments, and legacy checkpoint WALs. NRC keeps the current catalog
in the owner worker's memory. Its 64 MiB encoded-size ceiling (about 4.2 million descriptors) is a
corruption/allocation sanity bound, not an operational segment-count limit. Files not reachable from
the manifest are never replayed; a crash may leave such files for later disk reclamation.

Do not edit manifests or choose WAL files by modification time.

## Startup and recovery

Startup acquires `storage-layout.lock`, validates `storage-layout.manifest`, and validates all 256
shard directories. A pre-compaction shard may initially contain only `active.wal`; its owner publishes
the first `shard.manifest` while opening it. After validating the shard manifest, its owner validates
and applies each referenced WAL in one scan, in this order:

```text
catalog segments in order (optional) → sealed WAL (optional) → active WAL
```

Replay builds unpublished worker state. Checksums, hash-chain links, transaction semantics and
workspace origins are still checked; final edge endpoints are validated after the whole shard.
The same scan supplies sequence floors and the active file's append hash/count. Any open, scan,
application or tail-recovery failure closes the worker's writers and discards its replayed state.
The listener is published only after all workers successfully initialize. Validation-only managed
writer initialization remains available for callers that do not rebuild worker state.

All startup WAL scans use aligned `O_DIRECT` reads. Recovery therefore validates bytes obtained from
the storage device rather than clean Linux page-cache pages that may still contain newer data after a
failed `fsync` and process restart. If the filesystem cannot provide direct I/O for the WAL, startup
fails closed instead of falling back to cached recovery.

Catalog segments and sealed files are immutable and scanned strictly. The active WAL may discard only a
physically incomplete final append: a short trailing header, or a bounded, chain-linked header whose
payload is cut off by EOF. Recovery must successfully truncate and sync that suffix before startup
can succeed. Complete checksum failures, invalid magic/flags/length bounds, broken hash links and
semantic rejection remain fatal and are never truncated. Missing manifest-referenced files also
fail startup.

If a manifest still references a sealed WAL, startup restores the active writer and schedules the
segment cleaning job again. A cleaned segment, catalog, or WAL generation created before a crash but
never made reachable from the manifest is ignored.

## Mutation acknowledgment durability contract

A successful task, asset, or edge mutation response means that the complete hash-chained shard
transaction is covered by a successful `fsync`. The same applies to successful multi-operation
transactions. Multiple independent transaction records share a write batch and fsync; they are not
merged into one application transaction, and the WAL format is unchanged.

Each shard uses group commit:

- the worker submits an async fsync when the oldest pending mutation reaches **1 ms**, or pending
  writes reach **128 KiB**, whichever comes first; new requests do not extend the deadline;
- small transaction records share the existing 128 KiB write buffer; oversized records bypass it;
- writes may continue during fsync, but its callback releases only responses covered by the submitted
  snapshot, never later writes that the device might also have persisted;
- internal state is speculative until durable. Immutable ACKs, broadcasts, and query responses wait
  in the connection's bounded outbox, so that state is not exposed over the protocol before fsync.
  This conservative barrier also delays other application frames on the same dirty shard;
- at 32 MiB of unsynced data, new mutations are deferred through the bounded request queue. A final
  accepted record can exceed that threshold by at most one maximum-sized WAL record. Full request
  or send queues apply the existing busy/backpressure behavior;
- graceful shutdown and compaction rotation force pending writes through fsync;
- a write or fsync error poisons the shard writer and starts server shutdown without publishing
  undurable successes. Storage-error shutdown exits unsuccessfully.

The window bounds batching delay, not total response latency: scheduling, a previous in-flight fsync,
storage latency, and transport backpressure can add time. Durability depends on the filesystem and
device honoring fsync. A crash after fsync but before ACK is still an ambiguous result for the client:
the mutation may have committed. This does not add durable retry deduplication for task, asset, or
edge mutations. Standalone writer tools remain responsible for driving their own flush/sync.

The build-time overrides `NRC_SHARD_COMMIT_WINDOW_MS` and `NRC_SHARD_COMMIT_MAX_BYTES` allow
hardware-specific tuning. See [the group-commit benchmark](BENCHMARKS.md#shard-group-commit-comparison)
for the throughput/latency comparison used to choose the defaults and a reproducible runner.

### Segmented retained messages

Retained-message ACKs also wait for fsync. The retained store preserves callback-wave write batching
and submits async fsync after **1 ms** from the first pending write or **128 KiB** of pending bytes.
Writes behind an in-flight fsync start a separate window and cannot be acknowledged by its completion.
These thresholds bound batching delay, not device or end-to-end latency.

ACKs (including duplicate retries), broadcasts, history pages, and subscription responses are immutable
outbox snapshots tagged with the active WAL generation and record prefix. They remain queued until
that prefix is durable. This conservatively delays other application frames on the same retained
shard too; a frame depending on both the entity WAL and the message WAL waits for both. Control frames
remain independent. Existing bounded outboxes enforce slow-client backpressure.

Successful segment rotation durably publishes the old generation before waking its outboxes. Storage
failures poison the store and start shutdown without releasing undurable successes; worker maintenance
also detects stores poisoned by asynchronous history or dedup reads. Queued waiters use
generation-checked connection handles, not I/O pins, and are discarded during shutdown. Graceful
connection close drops unsent application frames, including priority ACKs, so its terminal close frame
cannot be blocked by storage; an already submitted transport send still finishes first.
Retained-message retry deduplication and on-disk/protocol formats are unchanged. Ephemeral messages
remain non-persistent; this does not give them their own durability guarantee.

`SIGKILL` process tests verify recovery of bytes retained by the running kernel and filesystem. They
do not prove power-loss durability. Deterministic WAL tests separately model dropping all un-fsynced
bytes and verify recovery to the exact last durable prefix.

## Non-blocking compaction

The owner rotates before an accepted append would make the active WAL exceed 500 MiB. Rotation is
independent of cleaning: it fsyncs the old WAL, creates and fsyncs a new active WAL, appends the old WAL
to a new durable catalog, and atomically publishes both through the manifest. New mutations then use
the new WAL even while the process-wide background compactor is cleaning an older catalog snapshot.
Except for a single record that is itself larger than a configured test threshold, immutable generation
WALs therefore remain bounded by the WAL byte limit.

Raw backlog is normalized newest-first, one bounded generation at a time. Compacting the newest raw WAL
uses an explicit one-member bound. An empty WAL is strictly inspected and removed without scanning other
members. A non-empty raw WAL uses the linear fast path: validate its floors against the immutable
snapshot and find latest keys within that generation during one strict checksum/hash-chain scan. It
records bounded offsets for the generation's transactions and measures the exact physically dirty
ratio. Below 20% dirty, publication adopts the immutable, already validated generation WAL directly as
a catalog member: no payload is reread or rewritten, and the same physical WAL remains authoritative.
At or above 20% dirty, cleaning directly rereads and checksum-validates only the retained records, then
strictly replays its bounded outputs. The offset metadata is capped at 32 MiB;
if a generation contains enough tiny transactions to exceed that cap, cleaning falls back to a second
strict sequential scan rather than using unbounded memory. Keys include `(workspace, conversation,
domain, entity ID)`. Transactions
containing an edge mutation or a task or asset deletion are retained whole; graph-neutral creates and
updates can be deduplicated within the generation. Records superseded by a newer segment may remain
until an ordinary sweep, which is safe because that newer segment still replays afterward. This avoids
both the former second full-generation scan and rescanning every older prefix, newer suffix, and both
complete catalogs for each raw generation. After
raw backlog reaches zero, cleaning sweeps forward through the catalog in bounded groups, normally
selecting at most 1 GiB of source files per pass. For each group it scans that group and the newer
immutable tail to identify the globally latest mutation for every `(workspace, conversation, domain,
entity ID)`. It measures physically reclaimable transaction bytes: because shard transactions are
atomic, a transaction is retained whole when any mutation in it remains latest.
Already-adopted or cleaned groups are rewritten only when at least 20% of their measured bytes are
dirty; clean groups advance the sweep without publication.

Each immutable segment may have a rebuildable `metadata-<kind>-<generation>.meta` sidecar. The checksummed
sidecar is bound to the physical segment identity and byte size and stores the segment's start/end
high-water floors, a Bloom filter, an exact sorted set of entity keys, and a compact record table. Each
record-table entry identifies the WAL offset and physical size, transaction flags, and exact keys
mutated by that atomic transaction. Raw normalization creates this metadata during its mandatory
validation scan. Ordinary sweeping can therefore derive candidate latest state and dirty bytes without
reading candidate WAL payloads, uses the preceding segment's persisted end floors instead of replaying
the older prefix, and probes newer Bloom filters before consulting exact keys. A Bloom positive is never
enough to discard state: only an exact key hit marks a candidate transaction as superseded. Rewrites
read and checksum only retained records at their captured offsets. Missing, corrupt, or oversized
metadata is a cache miss and falls back to strict WAL scanning; metadata is rebuilt and durably
republished when possible. Candidate metadata also has a conservative 256 MiB aggregate decoded-memory
budget; groups that would exceed it use the strict WAL path. The final semantic source/candidate replay
remains the publication gate. Compaction accounts prefix, latest, measure, copy, and replay read bytes
separately.

Raw normalization and ordinary semantic sweeping have independent readiness state. A rotated WAL that
contains only entity creates still receives its mandatory strict raw validation, but it does not
invalidate an already completed ordinary sweep when the uninterrupted live writer has also classified
every create as advancing its domain's high-water floor: those creates cannot make an older catalog
record dirty. The durable raw scan independently confirms the mutation operations, while the live writer
provides the cross-segment floor lineage. Updates, moves, deletes, reused or non-advancing IDs, mixed
transactions, and conservatively any non-empty active WAL found during restart do invalidate the sweep.
This prevents append-only traffic from repeatedly rescanning an ever-growing adopted catalog while
preserving cross-segment cleaning after mutations that can supersede older state.

Retained records are streamed into as many cleaned segments as necessary, each normally capped at
500 MiB, while preserving transaction order, tombstones, and a final high-water floor witness. Thus a
large live shard produces multiple bounded cleaned files instead of one shard-sized snapshot. The
number of catalog members grows with retained live data rather than being capped at 64.

The full semantic path strictly replays both source and candidate catalogs into isolated state,
requires equal state digests and high-water floors, and rejects a final graph containing an edge whose
endpoint is absent. Raw normalization instead requires the snapshot's captured final floors, strict
input parsing, output floors equal to the selected generation's final witness, and exact retention of
every graph-sensitive transaction. The final no-op group of an ordinary sweep performs a complete
semantic audit, so graph validation is deferred rather than removed from backlog normalization. The
owner can rebase a middle-group replacement over immutable WALs appended after the cleaner took its
snapshot. It renames and directory-fsyncs every cleaned output, writes and fsyncs the new catalog,
atomically publishes that catalog plus the latest active WAL, and only then removes replaced catalogs
and segments. The manifest remains recovery authority at every publication boundary.

Raw normalization also prepares the next empty active WAL on the background compactor: the owner first
claims an exclusive future generation, then the compactor fsyncs that empty file and its parent directory.
The owner consumes the prepared WAL only after validating the returned generation against current
manifest/catalog authority; concurrent rotations make stale reservations into ignored orphans. A crash
at any preparation point is safe because no manifest references the candidate. If preparation is not
ready, rotation retains the synchronous creation fallback. When an ordinary durability fsync becomes
due within one maximum-record size of the WAL limit, the owner rotates synchronously instead of starting
an async fsync that could make the next boundary append reject while the fsync remains in flight.

Raw-WAL cleaner backlog and filesystem free space provide pressure controls. At 4 GiB backlog or 2 GiB
available space, the owner prioritizes cleaning. At 8 GiB backlog or 1 GiB available space, new shard
mutations are rejected without poisoning the writer or changing in-memory state; no success response is
sent, so clients may retry. These thresholds are configurable build constants.

No overflow WAL or merge-back phase exists. Segment publication never rewrites or pauses the new active
WAL. Version-1 fixed catalogs remain readable for recovery, but new publications use variable-length
version-2 catalogs.

## Verification and benchmark

Normal and simulation suites exercise manifest and catalog encoding, restart boundaries, active writes
during cleaning, high-water preservation, missing/corrupt references, orphan generations, graph replay
ordering, and fail-closed corruption. Deterministic fault campaigns cover cleaned-segment, catalog, and
root-manifest publication boundaries.

Run the real-filesystem stress benchmark with:

```bash
BENCH_SHARD_COMPACTION=1 \
odin test . -o:speed \
  -define:ODIN_TEST_THREADS=1 \
  -define:ODIN_TEST_NAMES=main.benchmark_shard_compaction_stress
```

See [`BENCHMARKS.md`](BENCHMARKS.md) for workload defaults and overrides.

## Legacy installation cutover

Current binaries cannot read or migrate worker-number task/asset/edge WAL layouts. For a remaining
legacy installation, use the stopped-server, verified-backup procedure pinned in
[`SHARDED_PERSISTENCE_MIGRATION.md`](SHARDED_PERSISTENCE_MIGRATION.md). That runbook intentionally
uses commit `70d3da1`; its commands and pre-cutover layout are not current runtime APIs.
