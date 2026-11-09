# Personal-memory storage operations

These commands operate on local SQLite files. They do not deploy, restart services,
or install a restored database. Production stop/start, volume extraction and
replacement require separate operator approval. Never run `docker/backup.sh` as
a test: it stops the real stack.

## Runtime maintenance

The AI service runs maintenance when personal memory opens, then once a minute.
It uses the existing cancellation/join shutdown path before closing SQLite.

- `wal_checkpoint(TRUNCATE)` flushes committed WAL pages and tries to truncate the
  WAL. A busy reader defers reclamation; it does not discard commits.
- Once per day, including startup, maintenance considers `VACUUM`. It requires at
  least 64 MiB of free database pages, no low-space warning, and available disk
  space of at least twice the DB size plus 256 MiB. This is whole-file compaction,
  not deletion of records. Each maintenance call has a 30-second context timeout.
  Capture and other SQLite users can wait during compaction; it is not an online,
  zero-latency operation. Large databases may need an approved offline window.
- Filesystem availability below 1 GiB **or** 10% produces a warning each minute,
  with available, database and WAL byte counts. Maintenance errors and busy
  checkpoints also warn. Connect these log messages to the deployment's alerting;
  this change does not configure an external pager. Other processes can consume
  the filesystem after a sample, so the free-space check is not a reservation.

There is no total user quota and no automatic deletion of originals. SQLite can
reuse free pages even when compaction is skipped. Expand storage on a low-space
alert; do not delete `receipts`, `runs`, deleted segment identities or policy rows.
Consumed approvals, including `outcome_unknown`, remain permanently non-replayable.

## Backups and verification

`docker/backup.sh` still quiesces all captured services, archives complete volumes
and keeps seven days. It now creates private directories and archives. The whole
personal-memory volume is required, including DB/WAL/SHM files. Archive checksums
and tar listing checks are transport checks, not SQLite restore verification.

For a standalone consistent snapshot, use Python 3 with SQLite >=3.42 and FTS5.
The SQLite backup API includes committed WAL state while capture continues. The
source must be a private regular file in a private directory; output must not
exist. Commands below use placeholders for an authorized local fixture:

```sh
umask 077
mkdir -m 700 /tmp/memory-drill
python3 services/bots/nrc-ai/personal_memory/storage_ops.py snapshot \
  /private/source/memory.db /tmp/memory-drill/backup.db
python3 services/bots/nrc-ai/personal_memory/storage_ops.py verify \
  /tmp/memory-drill/backup.db
```

Snapshots have mode 0600 and are integrity-checked, fsynced and published without
overwriting a destination. Verification checks SQLite integrity, foreign keys,
the memory tables and storage lineage. It does not prove application semantics;
the disposable restore test below exercises those. Protect backup media and any
off-host transport with encryption and access controls. Existing archives are not
retroactively chmodded or encrypted by this change.

## Restore without resurrecting forgotten content

**Never install a raw old snapshot.** It can contain forgotten originals and lack
approvals consumed since the snapshot. Disabling retention alone is insufficient:
old history remains readable, and missing approval guards can permit replay.

The supported restore command requires the latest authoritative, stopped database
as its safety source, with its WAL if present. Preserve it before any replacement.
The tool acquires the same advisory ownership lock as the Go store on both inputs.
It refuses different storage lineages and detectable older/divergent safety data.
The required flag is an operator attestation, not an automatic freshness proof.

```sh
python3 services/bots/nrc-ai/personal_memory/storage_ops.py restore \
  /private/staging/old-backup.db /private/current/memory.db \
  /private/staging/reconciled.db --confirm-latest-safety
python3 services/bots/nrc-ai/personal_memory/storage_ops.py verify \
  /private/staging/reconciled.db
```

The command only creates a new staged file. It applies current deletion
tombstones, rebuilds FTS from surviving originals, invalidates summaries, carries
all current run/approval guards and receipt outcomes, and reserves current sequence
numbers. Captures newer than the backup become empty deleted identities rather
than invented recovered content. All scopes are disabled, with newer epochs and
change revisions; resuming retention requires explicit configuration. Originals
that survived deletion are restored only to their backup version.

After a separately approved installation, ensure no old WAL/SHM is paired with the
new database, reopen it, inspect forgotten-record absence and receipts, and only
then allow users to re-enable retention. Keep the safety source protected until
the restore is accepted. Prefer the current DB itself if it is healthy; restore
is not needed just to make a backup.

If the latest safety source is lost or its freshness cannot be established, **do
not restore personal memory into service or enable approval execution**. This
implementation deliberately has no unsafe disaster-recovery override. An old
backup alone cannot reveal later deletions or consumed approvals. A separately
durable, non-rollback safety ledger would be needed to support that recovery case.
Snapshots made before storage-lineage support are not accepted for reconciliation.
Backups retain forgotten bytes until their own retention expires; live deletion
cannot erase immutable archives, filesystem snapshots or remote model retention.

## Local checks

```sh
go -C services/bots/nrc-ai test -race ./personal_memory -count=1
bash -n docker/backup.sh
```

Tests use disposable directories. They cover concurrent capture/checkpoint and
snapshot, offline ownership refusal, restart, deletion and FTS absence after
restore, receipt replay refusal, private output and no-clobber publication.

## UI synchronization contract

`Scope.Changes(ctx)` returns `{enabled, epoch, revision}` from one indexed policy
row. `revision` is a durable per-owner/workspace invalidation token, not an event
count. Segment and receipt inserts/updates/deletes and policy changes increment
it transactionally. Summary-only work and idempotent approval retries do not.
Opening an existing DB migrates the column without changing consent or epoch;
crash recovery of active segments increments the affected scope's revision.

`Segment.RunID` is serialized as optional `run_id`. Read/history/export responses
include it only when a run matches that segment's owner, workspace, channel and
sequence. Raw voice captures omit it. Request keys are never exposed.
