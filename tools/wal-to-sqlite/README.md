# Offline Sharded-V1 WAL importer

This tool creates a **new, verified SQLite data set**. It does not activate it,
write a server layout manifest, start NRC, repair a WAL, or remove old files.
Only synthetic data was used during development and testing.

## Requirements

- Linux with `renameat2(RENAME_NOREPLACE)` and advisory `flock` support.
- Python 3.11 or newer, SQLite 3.37 or newer through Python's `sqlite3` module,
  and `libxxhash.so.0` (Debian/Ubuntu package `libxxhash0`). No pip packages.
- A trusted NRC projection builder matching the bundled schema.
  Build it in the SQLite server checkout with:

  ```sh
  odin build . -define:NRC_SQLITE_PROJECTION_BUILDER=true -out:projection-builder
  ```

The importer itself needs no Odin compiler and imports no server packages.
Copy this entire directory to keep it runnable after the old WAL/RAM server
code is removed. Keep the tested projection-builder binary with the migration
bundle. That executable uses the same Odin parsers as the SQLite write path;
the importer deliberately has no alternate JSON projection implementation.

`legacy.py` freezes the binary contracts from source archive SHA256
`a14a7bb5e462855a7ba810ecf830b8fc19f717be082e9fda8d0177011d6963cf`, based on
commit `dfb1700ed62e28f2440627f5ba693223fa73ec31`. The archive's uncommitted
changes, not `origin/main`, were the source of truth. The bundled `schema.sql`
includes the history ACL/endpoint columns and workspace-only keys;
`slice_summaries.sql` upgrades to schema 2, and `slice_incremental.sql` replaces
the dirty cache with schema-3 incremental Slice projections. `slice_pagination.sql`
adds schema-4 Slice ordering indexes; `monitoring.sql` adds the schema-5
monitoring state foundation, followed by `chronicle.sql` for schema-6
note-chronicle storage. The import fingerprints all six files and creates
schema-6 databases with initially empty monitoring and chronicle tables. Keep all six
files in the migration bundle. The real Odin projection builder populates the
derived membership, summary, project and workspace counters before activation.

Frozen legacy imports leave all eight Chronicle tables empty, including inputs,
claims, results, deletion receipts and budgets. Existing notes and technical
history do not invent capture inputs or opt a workspace in. Capture and the
authenticated service API are implemented; the processing worker and UI remain
separate work. The importer makes no provider sends.

Existing SQLite installations must stop all writers, back up the complete data
directory and explicitly migrate each schema-5 shard offline with `chronicle.sql`
inside `BEGIN IMMEDIATE` / `COMMIT`. Startup never upgrades old schemas silently.
For schema 4, apply `monitoring.sql` first; for schemas 1 through 3, also apply
the preceding Slice migrations in order. See the
[stopped migration procedure](../../docs/DEVELOPMENT.md#sqlite-schema-6).

Decoder references in that snapshot: `storage_layout.odin`,
`shard_compaction_manifest.odin`, `shard_segment_catalog.odin`,
`persistence/wal_core.odin`, `shard_transaction.odin`,
`shard_transaction_validation.odin`, `task_persistence.odin`,
`asset_persistence.odin`, `edge_persistence.odin`, `dm_persistence.odin`,
`history.odin`, and `workspace_data.odin`. These small frozen readers replace
the need to vendor the application and its worker/runtime dependencies.

## Run against an explicit offline copy

1. Stop all writers before taking the source copy. Keep the original backup.
   The copy must include `storage-layout.manifest`, the existing
   `storage-layout.lock`, the complete selected `sharded-<20-digit-generation>`
   directory, all 256 shard directories, and every manifest-referenced file.
   Do not point this command at a running server's data directory.
2. Choose a target directory that **does not exist**, outside the source tree.
   Its parent must already exist. Budget disk space for both the unchanged
   source and the new SQLite databases, temporary SQLite journals, and indexes.
3. Run the importer with explicit paths. There are no default data paths:

   ```sh
   python3 /path/to/wal-to-sqlite/import_wal.py \
     --source /path/to/offline-copy \
     --target /path/to/new-sqlite-data \
     --projection-builder /path/to/projection-builder
   ```

4. Require exit status 0 and inspect `IMPORT_COMPLETE.json` in the target.
   It records the source hashes, replay file order, schema and builder hashes,
   output database hashes, canonical digests, table counts, and sequence floors.
   The completion status is `verified-not-activated`.
5. Use the separate activation command below to assemble a new server data
   directory. The importer itself never activates its output.

The source lock is acquired exclusively, non-blocking, through a read-only
file descriptor. A missing lock is an error; the tool never creates it. Every
source file is SHA256-hashed before and after the import, including retained
message files and unreferenced old segments. Symlinks and special files are
refused. These checks do not replace an offline, immutable source snapshot:
uncooperative writers can ignore advisory locks. Reads may update filesystem
access times; file contents and names are never written by the importer.

The target contains `shard_000.sqlite3`, etc., only for shards with replay
records. A shard containing only high-water metadata is still occupied. Each
database has `application_id=0x4e524351` and `user_version=6`.

## Replay and preservation rules

- Read the selected layout generation. In each shard, replay checkpoint or
  catalog segments, then the sealed WAL, then the active WAL in manifest order.
  Catalog versions 1 and 2 and all four descriptor kinds are supported. Without
  a shard manifest, only `active.wal` is authoritative. Unreferenced files are
  hashed but not replayed. Every WAL starts its own SHA256 chain.
- Verify metadata XXH64, both legacy XXH32 and current XXH64 record checksums,
  SHA256 chain links, versions, lengths, workspace shard routing, transaction
  floors and record identities. **Even an incomplete final append is fatal.**
  Recover it separately on a disposable copy with the appropriate old-server
  procedure, then start a fresh import. There is no skip/repair option.
- All unsigned IDs, attachment sizes, and sequence floors are eight-byte
  big-endian BLOBs, including values above `INT64_MAX`. Other byte fields remain
  BLOBs; attachment order, compressed payloads and preview bytes are unchanged.
  As in old replay, an asset's zero/missing `payload_raw_len` becomes the stored
  payload byte length. Asset record versions 1 through 3 are accepted.
- Task/asset/edge floors come from every transaction, including deleted maximum
  IDs and transactions with no mutations. They are not recomputed from live rows.
  History event IDs and high-water marks are workspace-local. History JSON is
  preserved byte-for-byte; the immutable owner and endpoint prefix is stored
  separately, so private reminder ACLs survive deletion. History endpoint kinds
  use Task=1/Asset=2, unlike edge endpoint kinds.
- DM pairs are hash-validated and membership masks 0 through 3 are preserved.
  Zero is a durable revocation. Public legacy room scopes merge into workspace
  records, as in old replay, but the destination tables have no scope column.
  Conflicting public room origins for one entity are rejected, even if a tombstone
  intervened. Legacy DM-scoped tasks, assets and edges (including tombstones)
  reject the import: they cannot become public workspace records. No private
  record is silently discarded or made public. DM membership and retained chat
  storage are unaffected by this restriction.
- Membership edges use the schema's unordered unique pair constraint. Duplicate
  pairs fail the import; there is no deduplication. Polymorphic parent/endpoint
  references are retained as declared by the schema, without invented cascades
  or repairs. Tombstones remove only their own entity and its attachments.

## Projections and publication

For each occupied shard the importer closes the canonical database, then calls
`projection-builder <absolute-shard-path>`. The builder must rebuild all derived
Notes, Reminder, Calendar/People, Slice, Customer, Ticket and RoomMapping tables
in one transaction with the server's Odin parsers. It must reject invalid
Appointment/Ticket canonical bodies that old WAL validation rejected. Missing
executables or nonzero exit statuses fail the import. Treat the builder as
trusted code: a successful no-op cannot prove semantic completeness.

The projection builder populates Slice membership summaries before publication.
Runtime writes finalize affected Slice projections in the same transaction.
Read-only runtime readers reject pending finalization; reads never repair an
unfinished offline import.

Every Appointment, Ticket and TicketEntry post-image is also queued in a
temporary SQLite validation database, including images later overwritten or
deleted. Each image gets a separate scratch workspace key; its validation
fields, including the original unnormalized raw length, stay unchanged. The
same Odin builder validates this database before publication. It is deleted
after validation and never becomes part of the output. This catches invalid
intermediate mutations without keeping their bodies in RAM or duplicating the
Odin parsers in Python. `validated_asset_images` records their count per shard.

Canonical typed row digests and schema definitions are compared before and
after the builder. SQLite integrity and foreign-key checks run before and after
it and after a fresh read-only reopen. The importer checkpoints SQLite WALs and
closes the databases before hashing the final files. The server may select WAL
journaling when it later opens them.

Work happens in a sibling `.TARGET.incomplete-*` directory. Ordinary failures
remove that staging directory. A crash may leave it behind; it is not an import
result and must not be activated. After verification and `fsync`, an atomic
no-replace rename publishes the target. An existing target is never reused or
overwritten. Retry with a new target after correcting the source or builder.
If the final parent-directory sync fails after the rename, the completion marker
is removed and the target directory is synced; the remaining target must not be
activated. If removal or that sync also fails, the command reports
`Publication state indeterminate` with the target path. Inspect that directory
before any use: the completion marker may survive a crash.

`source_generation` and `retained_message_generation` in the completion report
identify the **original layout generation**. Retained-message bodies, manifests,
segment generations and files remain in the source; they are not copied into
SQLite. The later server cutover must preserve access to that original retained
message generation. It must not infer a new generation from the SQLite target.
Attachment file contents likewise remain external; this tool imports their
ordered metadata only.

## Assemble a startable SQLite directory

Keep the source snapshot offline and unchanged. Activation takes the exact source
used by the importer, its verified output, and another **nonexistent** target:

```sh
python3 /path/to/wal-to-sqlite/activate_import.py \
  --source /path/to/offline-copy \
  --import-dir /path/to/new-sqlite-data \
  --target /path/to/activated-data
```

This publishes a complete server **data directory**, not a deployment. It does
not replace an existing directory, change a mount, start a server, or copy external
attachment blobs. Preserve the attachment store separately and keep its paths
consistent with the server/proxy configuration before starting the new instance.

Activation locks the source and verifies its inventory against `IMPORT_COMPLETE.json`.
It checks schema/database hashes and occupied-shard coverage, copies occupied
databases, creates empty databases for the remaining shards, and verifies SQLite
integrity and foreign keys. It copies each shard's entire `messages` directory
byte-for-byte, including manifests and sealed/active files, without rewriting their
formats. The original layout generation is preserved. Source and import inventories
are checked again before publication; both inputs remain unchanged.

The result contains all 256 `sharded-<generation>/shard_NNN/workspace.sqlite3`
files, the retained directories, a mode-3 layout manifest and
`ACTIVATION_COMPLETE.json`. No workspace WAL is copied. Files and directories are
synced before atomic no-replace publication. A publication-sync failure removes
the layout manifest and syncs its removal so startup refuses the incomplete result.
If this cleanup fails, publication is indeterminate; do not start the target even
if its manifest exists. As with import,
advisory locks do not protect against uncooperative writers: use immutable offline
inputs and a trusted import report. Retained files are copied, not semantically
repaired; the server and Attachment-GC validate their format when opening them.

## Tests

From any checkout containing this directory:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/wal-to-sqlite -v
```

To run the real Odin integration cases too:

```sh
NRC_TEST_PROJECTION_BUILDER=/absolute/path/to/projection-builder \
  PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tools/wal-to-sqlite -v
```

The unit suite creates all sources in temporary directories and uses a clearly
scoped test-double builder. It covers exact byte/ID preservation, ordered
attachments, both WAL checksum formats, checkpoint/sealed/active precedence,
both catalog versions, all segment kinds, workspace-local history floors and
ACL reconstruction, revocation, deleted floors, private-record rejection, conflicting
origins, duplicate memberships, corrupt/truncated sources, missing files, locks,
symlinks, existing targets and failed/tampering builders. Unit tests alone do not
verify Odin projection semantics; use the real-builder integration test for that.
That test checks every projection family through a complete WAL import and
reopen, ambiguous room names, and invalid intermediate Appointment/Ticket/
TicketEntry images followed by deletion or replacement. The integration cases
are explicitly skipped when `NRC_TEST_PROJECTION_BUILDER` is unset.
