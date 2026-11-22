# Development

## Toolchains and build

The core requires Linux 6.6+ with usable io_uring and `IORING_SETUP_NO_SQARRAY`.
There is no fallback below Linux 6.6. NRC also requests `IORING_SETUP_SQ_REWIND`
(Linux 7.0+); if setup returns `EINVAL`, it retries once without that optional
flag, preserving the required flags. Other setup errors retain their existing
handling. The successful ring's flags select the submission path.
Tested locally with Odin
`dev-2026-09-nightly:a2fb372`, Go `1.26.8` and Node `24.21.0`.
Go module requirements are in each `go.mod`; the proxy requires at least Go 1.26.6.
The server Docker build pins Odin to `7e313bd6f1fa9ae887c7b522611481cbf2da4cac`
(`dev-2026-10`), the compiler used for the WAL-to-SQLite migration rehearsal.

For the reviewed baseline of newer Odin escape-analysis warnings, see
[the escape-analysis audit](ODIN_ESCAPE_ANALYSIS_AUDIT.md). Its lifetime arguments
apply only to the recorded code/compiler revisions and must be revisited when
the affected ownership paths change; it is not a warning-suppression list.

Install an Odin compiler, Go and Node.js before you build.
On Debian/Ubuntu, also install `libopus-dev` and `libzstd-dev`.
The server, SQLite package tests and root worker-integration tests require `libsqlite3-dev`
(SQLite 3.37.0 or newer with FTS5 and its trigram tokenizer; locally checked with 3.54.0).
Workspace handlers use SQLite executors in normal builds.
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

### Server image and SQLite pin

`docker/Dockerfile` pins its Ubuntu 24.04 base by digest and builds SQLite 3.54.1
from the official `sqlite-autoconf-3540100.tar.gz` archive. The build checks its
SHA3-256 against the value published on the [SQLite download page](https://www.sqlite.org/download.html):
`b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4`.
A mismatch stops the build. The builder and runtime use the same shared library
under `/opt/sqlite/lib`; neither installs Ubuntu's SQLite package.
The SQLite CLI is `/opt/sqlite/bin/sqlite3`.

```sh
docker build -f docker/Dockerfile -t nrc-server:local .
docker run --rm --network none --entrypoint /opt/sqlite/bin/sqlite3 nrc-server:local --version
docker run --rm --network none --entrypoint ldd nrc-server:local /usr/local/bin/server
```

Check that `ldd` resolves `libsqlite3.so` under `/opt/sqlite/lib`.
Updating the pin requires a new official checksum, a successful image build and
storage/migration tests against that library. The remaining apt packages still
follow Ubuntu's repositories; these pins do not make the entire image
bit-for-bit reproducible. Building an image does not migrate data or deploy it.

### Preserve production storage on deployment

After an offline migration into a new Docker volume, set `NRC_TASK_DATA_VOLUME`
in the host's private `.env` to that verified volume name. Both the server and
attachment GC use it. Without an override, Compose retains its normal
`<project>_task-data` name for fresh installations.

Before tests, backup, source synchronization or service changes, `docker/deploy.sh`
renders the incoming base Compose file with the host's environment and enabled
overlays. It refuses to proceed unless its data volume matches the running
server's named `/app/data` mount. A missing server, bind mount or multiple server
mounts also blocks deployment. Use the offline migration procedure to switch
storage; deployment is not a migration command. `--dry-run` performs this check
without changing production. Python 3 is required locally for the config check.
Run its regression checks with `python3 docker/deploy_test.py` (Docker Compose
required; no Docker daemon or production access).

Compose sends `SIGINT` to the server on stop, matching its graceful shutdown
handler. Keep this setting for quiesced backups; Docker's default `SIGTERM` does
not request the server's graceful shutdown.

Daily backups stop running services only for uncompressed volume copies, then
restart the same containers. Compression, checksums and archive verification run
online against those frozen copies. Allow free backup space for all uncompressed
archives plus the largest archive's compressed output.

Deployments needing a backup use one combined restart window. Before source sync,
`nrc-backup --prepare-deploy CONFIG` saves the rendered old Compose configuration
and actual running image IDs in a mode-0600 file under the source rollback directory.
This file contains resolved secrets; keep it restricted. Deploy builds the new
images while services are still running, then starts a transient systemd unit
running `nrc-backup --deploy CONFIG SERVICE...`. The unit takes the same backup
lock as the daily service. It copies stopped volumes and starts the prepared images
directly, with no build or pull during downtime. Previously running services are
also restarted; previously stopped, unrelated services stay stopped.

The startup check polls for up to 120 seconds until services are running and,
where configured, healthy. A transient unhealthy state during dependency startup
does not fail immediately; a service still unhealthy at the deadline does.
A failed switch stops the selected deployment services and attempts to
recreate the previously running set from the saved configuration and immutable
image IDs. Changes to that set or its images since capture block the operation
before stopping services. Copy failures restart the existing containers without
attempting an image switch. SIGINT and SIGTERM also trigger recovery.

This is an image/configuration rollback, not a database restore. New binaries may
already have written data; incompatible schema changes still need an explicit
migration/recovery procedure. Failures after the switch retain the pre-switch
copies as `.partial` for manual recovery and return failure. A later compression
failure does not roll back healthy new containers. Once the startup check
succeeds, later deployment smoke-test failures are reported but do not automatically
roll back. Services without a healthcheck are checked for running state only.

Backup logs timestamp the stop and startup-check boundaries. Run
`python3 test/test_backup.py` and `python3 docker/deploy_test.py` for the isolated
regression tests; deploy runs the backup suite unless `--skip-tests` is set.

The standalone server listens on port 8080 and expects authenticated upgrades.
Serving static `client/` alone does not provide browser authentication.
Use the [Compose deployment](../README.md#quickstart) for the complete web application.
Production serves the complete generated `client/dist/`, not the source directory.
After frontend changes, rebuild the Nginx image and reload open browser tabs.

## SQLite schema 11

Standalone review forms use schema 11. Startup rejects older databases without
modifying them. New databases include `workspace_db/reviews.sql`; the upgrade
adds private run, participant, invitation and answer indexes without rewriting
existing records. See [review operations](REVIEWS.md) for the protocol and access rules.

Stop every writer, back up the complete stopped data directory and rehearse on
a disposable copy. For every schema-10 shard in the active generation, run
`sqlite3 -bail "$SHARD"` from the repository root:

```sql
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
.read workspace_db/reviews.sql
COMMIT;
PRAGMA user_version;
PRAGMA integrity_check;
PRAGMA foreign_key_check;
```

Require version 11, `ok`, no foreign-key violations and unchanged existing
records. The guard rejects a foreign application ID, wrong starting version
or repeated upgrade. On failure, roll back or close without committing and
keep writers stopped. Upgrade all shards before starting the new binary.
Restore the stopped backup for rollback; do not run an older binary on schema 11.

## SQLite schema 10

Schema 10 is a local development feature for Chronicle parallel durable
publication; it is not deployed to production. This is the prerequisite for
the schema-11 upgrade above, not the current startup schema.

Stop every writer, back up the complete stopped data directory, and rehearse on
a disposable copy before changing any installation. For each schema-9 shard,
run from the repository root with `sqlite3 -bail "$SHARD"`:

```sql
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
.read workspace_db/chronicle_parallel.sql
COMMIT;
PRAGMA user_version;
PRAGMA integrity_check;
PRAGMA foreign_key_check;
```

Expect version 10, `ok`, and no foreign-key violations. The migration requires
the NRC application ID and exactly schema 9; repeating it is refused. On any
error, roll back the transaction (or close the connection without committing).
Compare active receipts, membership, reservations and summaries with the backup
before switching binaries. Restore the stopped backup to roll back; an older
binary must not open schema 10.

Receipt `generation` stays immutable. Existing terminal jobs in states 1, 2
and 4 receive the same `publication_generation` as their generation, preserving
public history IDs. Active jobs and their membership are unchanged. Each
workspace's publication floor starts at the maximum of its claim floor and all
existing job generations, including deleted receipts, so future publication
cannot reuse old IDs. Multiple active jobs are now allowed. New terminal
receipts with a NULL publication ID are durable staged results, invisible to
history until publication; their inputs have already been terminalized and raw
input removed. The service must bound running jobs plus unpublished results to
10; the indexes support this window but do not enforce it themselves.

## SQLite schema 9

Ticket activity searches use a case-sensitive trigram index over text already
lowercased by NRC. Tickets and entries are separate documents. Substrings of
fewer than three Unicode code points and terms containing NUL use the scanner.
The index stores normalized, uncompressed text: allow extra disk space for the
database, the rebuild transaction and its WAL.

Stop writers, take a quiesced backup, and rehearse on a disposable copy. For
each schema-8 shard apply `workspace_db/ticket_trigram.sql` with `sqlite3 -bail`
inside `BEGIN IMMEDIATE` / `COMMIT`. Run the schema-9 `projection-builder`
on that shard before switching server binaries. A shard with old ticket rows
uses the scanner until the builder commits. Verify `PRAGMA integrity_check`,
`PRAGMA foreign_key_check`, `PRAGMA user_version` (9), an empty
`ticket_search_backfill` and as many `ticket_search_docs` as ticket and entry
metadata rows combined. Restore the stopped backup to roll back.

## SQLite schema 8

Schema 8 appends
`workspace_db/monitor_snapshots.sql` after schema 7. It adds the immutable
availability outbox: accepted evaluations and their complete snapshot pages
commit together. History acknowledges a snapshot only after its DuckDB commit.
No old history is reconstructed. Startup rejects older schemas without changing them.

Stop all writers, take a quiesced backup and rehearse on an isolated copy first.
For every schema-7 shard in the selected generation, run from the repository root:

```sh
sqlite3 -bail /absolute/offline-copy/shard_000/workspace.sqlite3 <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
.read workspace_db/monitor_snapshots.sql
COMMIT;
PRAGMA integrity_check;
PRAGMA foreign_key_check;
PRAGMA user_version;
SELECT count(*) FROM monitor_snapshots;
SQL
```

Require exit 0, integrity `ok`, no foreign-key violations, version 8, an empty
outbox and unchanged existing records on every shard. The guard rejects foreign
application IDs, wrong versions and repeated upgrades. Keep writers stopped on
failure. Upgrade the server and incidents sidecar together; do not deploy the
schema-8 server against schema-7 data. The migration is additive, but a rollback
to the old server requires an explicit storage rollback while all writers are stopped.

## SQLite schema 7

Schema 7 appends
`workspace_db/chronicle_input_budget.sql` to the schema-6 initialization below.
It raises only the per-call Chronicle input-token constraint from 16,000 to
128,000; daily budgets, output allowance and existing records remain unchanged.
This upgrade does not replace the schema-8 step above.

Stop all writers, take a quiesced backup and rehearse on an isolated copy first.
For every schema-6 shard in the selected generation, run:

```sh
sqlite3 -bail /absolute/offline-copy/shard_000/workspace.sqlite3 <<'SQL'
PRAGMA foreign_keys=OFF;
BEGIN IMMEDIATE;
.read workspace_db/chronicle_input_budget.sql
COMMIT;
PRAGMA foreign_keys=ON;
PRAGMA integrity_check;
PRAGMA foreign_key_check;
PRAGMA user_version;
SQL
```

Foreign-key enforcement must be disabled **before** the transaction because the
migration rebuilds the jobs table. Its guard rejects enforcement being enabled,
foreign application IDs, wrong versions and repeated upgrades. It checks foreign
keys before committing. Require exit 0, version 7, integrity `ok`, no foreign-key
violations, and unchanged canonical records, Chronicle receipts, job memberships
and budget counters on every shard. Keep all writers stopped on any failure.
Older installations must complete the migrations below before this final step.

## SQLite schema 6

New databases use `workspace_db/schema.sql` followed by
`workspace_db/slice_summaries.sql`, `workspace_db/slice_incremental.sql`,
`workspace_db/slice_pagination.sql`, `workspace_db/monitoring.sql` and
`workspace_db/chronicle.sql`. Schema 4 adds Slice ordering indexes; schema 5
adds monitoring instance state, bounded last-evaluation receipts and episode
lifecycle records. Schema 6 adds
note-chronicle inputs, epochs, claims, results, deletion receipts and budgets
without historical text backfill.
Startup rejects older versions; it does not upgrade files implicitly.

Stop the server and back up the complete data directory before migrating.
Test on an offline copy first. From the repository root, run the following for
each schema-5 `workspace.sqlite3` in the selected generation, replacing the example
path. Keep all writers stopped until every shard has been migrated:

```sh
sqlite3 -bail /absolute/offline-copy/shard_000/workspace.sqlite3 <<'SQL'
PRAGMA foreign_keys=ON;
BEGIN IMMEDIATE;
.read workspace_db/chronicle.sql
COMMIT;
SQL
```

The migration requires the NRC application ID and exactly schema 5; foreign
versions and repeated upgrades fail. With `-bail`, an error exits before commit
and the transaction rolls back. Check the exit status and `PRAGMA user_version`
for every shard before starting the schema-6 server. Canonical records and
Retained files are unchanged. The new chronicle tables start empty; neither this
migration nor the frozen legacy importer invents inputs or opts workspaces in.

For schema 4, run `monitoring.sql` before `chronicle.sql`. For schema 3, run
`slice_finalize.sql` then `slice_pagination.sql` before those two migrations
inside the same transaction. For schema 2, first run
`slice_incremental.sql`; for schema 1, also run `slice_summaries.sql` before it.
These earlier steps rebuild derived Slice data offline; measure that backfill
separately from ordinary requests. Startup rejects prior versions and never
performs a silent upgrade.

Capture, the authenticated Chronicle API, the processing worker, and the
History client/CLI are implemented locally. Processing is default-off; the
Terra adapter requires explicit configuration and has not been activated in production.
The existing OpenAI approval covers automatic note-change processing; deployment
and workspace activation still require approval. Use the
[operations runbook](CHRONICLE_OPERATIONS.md) for Compose, migration and read-only
checks. Keep `NRC_CHRONICLE_WORKSPACES` empty until operational activation is approved.
The setting accepts comma-separated,
exact workspace IDs (trimmed, no wildcard expansion). Server startup applies this
operator allowlist once per shard and advances existing workspace epochs. Removing
a workspace on restart atomically fences its pending inputs through a persistent
disabled-epoch boundary. A bounded first cleanup pass runs in that transaction;
remaining raw rows are removed by the executor. Re-enabling cannot make those old
inputs readable or publishable, even before cleanup, and does not backfill changes.

Capture shares the canonical mutation's transaction for single writes, batches
and cascades. Title/content/format changes retain ordered decoded images; tag,
project and attachment-only changes remain technical history. The capture ceiling
is 256 KiB for decoded before+after content including titles. The existing 65,535
decoded-byte per-note protocol limit remains unchanged. Pending raw quota defaults
to 64 MiB per workspace, counting stored title/body/format bytes. Exceeding quota
stores a text-free gap without rejecting the note write; a failure to store either
capture or gap rolls back the complete mutation. Each input records a 72-hour
expiry. Internal raw-chunk reads (at most 16 KiB) and terminal transitions check
expiry, current epoch, opt-in and the disabled-epoch boundary in their transaction.
The expiry boundary is exclusive: at `expires_at` neither reading nor new success
is allowed, regardless of cleaner progress. Callers must supply server wall time
at execution, not an earlier admission timestamp. Chronicle API operations use
fresh server execution time and check service rights separately.

Each production SQLite writer visits one assigned shard per second, including
while idle and under sustained request load. One transaction terminally gaps at
most 128 expired/disabled inputs and removes their raw bytes through accounting
triggers. This is not a physical deletion deadline or a cleanup throughput SLA.
Errors roll back the batch and retry on a later sweep. Input identities and
terminal reasons remain durable; processed/Ack states, canonical notes, technical
history and ID floors are not aged out. Terminal states cannot return to pending.
Pending metadata also has a separate default limit of 4096 inputs per workspace,
with actor ID/name each bounded to 256 bytes. Exhaustion produces an `input_quota`
gap; oversized actor metadata produces `metadata_size`, without truncating it or
rejecting the canonical note write. Terminal transitions release the slot atomically.
Gap inputs immediately lose their full metadata row. `chronicle_gaps` retains only
workspace, exact unsigned source endpoints, note ID, a reason of at most 64 bytes,
capture-time min/max and count. Only consecutive IDs of the same note/reason merge,
up to 4096 inputs per range; successes, different notes/reasons and missing IDs split
ranges. Indexed receipt lookup and an insert guard prevent reuse after compaction.
This bounds pending metadata, individual gap rows and compaction work, not total
disk usage: arbitrary alternating gaps require separate durable receipts. No loss
of source identities is allowed to satisfy a global storage limit.
SQL deletion is logical, not erasure from WAL pages, held snapshots or backups.

### Chronicle service boundary

`NRC_CHRONICLE_SERVICE_SUBJECTS` and `NRC_CHRONICLE_DELETE_SUBJECTS` are JSON maps
from exact workspace IDs to arrays of verified JWT subjects. Empty maps deny
these rights; malformed configuration prevents startup. Service JWTs require
`capability:"chronicle"`, `user_type:"bot"`, an exact nonempty `workspace`, and
an allowlisted `sub`. That capability restricts the entire connection to
`C_Chronicle` and ping, including executor admission/execution; it grants no
canonical task/note/chat writes. A legacy bot secret does not grant Chronicle
rights. Explicit invalid, empty or duplicate auth headers cannot fall back to it.
Deletion requires a separately allowlisted verified human subject, never service
or bot classification. Current authenticated workspace readers may read results
and status. This adds no per-note ACL or general workspace-role system.

The [Chronicle wire contract](../protocol/README.md#chronicle-interface) describes
the multiplexed JSON API and precise decimal-string IDs. All operations use the
SQLite writer lane. One active claim per workspace takes at most 32 inputs from
one note's prefix of the global pending order, without skipping another note.
Its immutable sources/hashes, authenticated owner, consumer version, monotonic
epoch/generation and at most five-minute lease fence chunk reads and commits.
Restart advances the epoch; an expired claim can be reclaimed without resetting
attempt counters. Disable/re-enable cannot revive fenced inputs.

`reserve` charges the current UTC-day budget before a provider attempt: at most
8,000,000 input tokens and 500,000 output tokens per workspace/day. The daily call
count is telemetry, not a separate limit.
Each call reserves 1–128,000 input tokens and exactly 1,000 output tokens. The
worker must count the complete request, including instructions/serialization.
Reservations are never refunded on unknown outcomes or restart. Exact repeats
do not charge twice. Confirmed provider input/output usage settles the reservation
atomically with Result/Ack or a retry release. Only the unused portion is credited
to its original UTC day; it cannot increase a later day's budget. Missing usage
keeps the full reservation. Result replay includes usage in its fingerprint and
cannot credit the budget twice. Calls are never refunded. The input's `attempts`
counter saturates at five; it is a backoff level, not a lifetime call count.
Retries use exponential backoff plus jitter for the first four reservations,
then 15 minutes plus up to 499 ms of jitter from the fifth reservation onward.
The pause is persisted at reservation and renewed on retry release, so an
abandoned call cannot bypass it through lease expiry or restart. Once due, claims
retry the same inputs rather than returning `exhausted`. Every new call still
requires daily token budget. An unreserved `rebatch` release does not charge an
attempt. Later inputs cannot skip the unresolved head. The 72-hour TTL is unchanged;
retry exhaustion itself never deletes raw input or creates a gap. No migration or
manual attempt reset is needed for previously exhausted inputs.
A singleton that cannot fit the token budget may commit a `token_limit` gap
without a provider reservation; silent truncation is not supported.
Deterministic provider failures may release a reserved claim with
`retry/permanent`: the input remains pending with `retry_at=expires_at`, and
future claims return `parked` until TTL or authorized deletion, including restart.
No artificial attempts are charged to express that permanent state.

The AI sidecar has an isolated, default-off [Chronicle worker mode](../services/bots/nrc-ai/README.md#chronicle-worker).
It uses dedicated service JWT sockets and server-side reservations, not Sullivan's
general-purpose connection. Fake entries are visibly synthetic but commit real
terminal state; use disposable workspaces. The Terra adapter is wired separately;
fake mode does not invoke it or require an external provider key. This does not
authorize external processing of workspace data.

The Linux Chronicle crash acceptance test compiles a test-only C interposer with
`cc` and SQLite development headers. It stops the real server immediately before
or after an armed SQLite COMMIT, then sends SIGKILL and checks recovered SQL and
public replay state. From the repository root, run:

```sh
go -C test/e2e test -v -count=1 -run '^TestChronicleCrashAtCommitBoundary$' .
```

The interposer
is never linked into the application or container. This tests process crashes,
not power failure or physical erasure from WAL/snapshots/backups.
For the full client path, run the fake-process test with
`NRC_CHRONICLE_CLIENT_ACCEPTANCE=1`. It builds the CLI and opens the real History
client through a disposable JWT-injecting HTTP/WebSocket proxy. Browser/CLI reads
use the same real server, SQLite result and token-limit gap as the fake worker;
no service response is mocked. This needs Node, Playwright and Chromium and is
included in the browser section of `test/run_all_tests.sh`.

`commit` accepts exactly the claim's ordered sources. Result insertion or a
no-relevant-change Ack, terminal receipt and raw deletion commit together.
Successful retries return the stored result; different content conflicts.
Results have no age expiry. Source deletion keeps them with an unavailable
source link. Explicit Chronicle deletion atomically records a source watermark,
removes result prose and suppresses pending/claimed inputs through that boundary.
Replay then returns `deleted`, never former prose. Later note mutations above
the watermark may produce new entries. These guarantees concern logical SQL
state, not erasure from WAL files or backups.

Unfiltered and owner-filtered Slice pages select IDs from the ordering index
before loading page fields. Open-only pages restrict the range to `closed=0`.
Project-filtered totals and overflow checks start at
`slice_projects_filter(workspace,project,slice_id)`. If the qualifying project
fits within `limit+1` records, page selection sorts its narrow keys directly.
Larger projects retain the ordering-index seek with residual membership checks
to avoid sorting every match. Such pages can still examine more than `limit+1`
index keys, especially when matches are sparse. Field loading remains bounded
by the page limit. Missing-summary validation still checks the owner/closed
scope outside the selected project, so even an absent project's request is not
constant-time. Unicode substring searches retain their existing scan path.
Sort-key triggers run in the mutation transaction; no reader repairs ordering
state.

`slice_members` stores membership and narrow contributions independently of
Slice metadata edits. Triggers collect changed identities in `slice_pending`;
`workspace_db.commit` drains them and applies grouped counter/project deltas in
the same transaction. Indexed member timestamps supply extrema. Slice age is
the earliest nonzero creation time of an active task, or zero if none is known;
zero timestamps no longer make the result depend on edge order. Workspace
status/coverage counts and Slice summaries serve the overview without member scans.

All writers must finalize before committing; do not commit raw SQL changes and
assume derived tables are current. Runtime Slice/overview readers reject pending
offline writes rather than repairing them on their read-only connections. Offline
writers must finalize explicitly before handing the database to the server. The projection builder
rebuilds parsed metadata and then all Slice derivations from canonical records.
Finalization failures require rolling back the transaction. Its queue, temporary
tables and derived writes participate in savepoint/transaction rollback; no ACK
or event is published after a failed commit.

## Deletion limits

A request may delete at most 16 Slices and 1,024 distinct records in total.
The total includes Tasks, Assets and Edges, including descendants and incident
edges removed by cascades. Shared edges count once. These limits apply to
standalone deletes and across all delete operations in one transaction.
Exceeding either limit rejects the entire request before deletion; the server
does not split it into partial commits. A standalone request returns an error;
an apply-transaction request returns a rejected transaction result.

These limits bound deletion counts, not elapsed time or bytes. A single root
with too many descendants or incident edges must be reduced through separate
requests before it can be deleted. Slice members connected only by membership
edges are not deleted along with the Slice; those edges count toward the limit.

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
libhegel 0.47.1 build. Explicit overrides are not checked against the Linux digest;
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

Coverage-guided protocol fuzzing is a separate, opt-in tier because it needs a
clang toolchain in addition to Odin: `./test/run_protocol_fuzz.sh` builds a
libFuzzer + AddressSanitizer binary from the Odin parsers. The JS client's
shared decoders (`client/protocol.js` and `client/frames.js`) have their own
opt-in tier: `./test/run_js_protocol_fuzz.sh` drives every client-handled
server-to-client frame through Jazzer.js from the same server-frame corpus. See
[TEST_MATRIX.md](TEST_MATRIX.md#protocol-fuzzing-coverage-guided) and
[TEST_MATRIX.md](TEST_MATRIX.md#js-client-decoder-fuzzing).

## SQLite workspace-store development

`sqlite/` and `workspace_db/` provide the disk-backed workspace backend.
Startup bootstraps SQLite only in an empty data directory and rejects existing
WAL layouts; no existing data is automatically migrated. The base schema defines canonical tasks, assets, edges,
ordered attachments, history with immutable ACL/endpoint columns, DM membership
and persistent ID floors. Derived tables cover notes/tags, reminders, appointments,
customers, tickets, slices and room mappings. Server and importer use
[schema 10](#sqlite-schema-10), including the Slice migrations, monitoring, chronicle capture and ticket search tables.
Recreate test databases after schema
changes during development; there is no automatic migration. Workspace tables and their projections use workspace/ID
keys without a scope column. Protocol scope fields must still be zero; storage
entry points reject nonzero scopes rather than alias them to public records.
The offline importer merges legacy public scopes with origin-conflict checks
and refuses DM-scoped tasks/assets/edges. DM membership and retained-message
conversation identities remain unchanged.

All SQLite calls are synchronous and belong on DB executors, never
on network workers. The store opens only an explicitly supplied path; creation
must be requested and only initializes an empty database. Unrecognized schema
versions and other database formats are refused. It uses WAL, FULL synchronous
commits, foreign keys and a 4 MiB suggested page-cache budget per connection.
That budget is not a hard memory limit. Local builds use the system SQLite
library; the [server image](#server-image-and-sqlite-pin) uses its pinned release.

The layout manifest uses mode 3 (`SQLite_V1`) with the existing 256-shard hash
and generation naming. Each `sharded-<generation>/shard_<number>/workspace.sqlite3`
holds workspace records; retained-message files keep their existing names and
format in the same shard directory. Fresh startup creates no workspace `active.wal`.
The manifest is published only after the databases and directory entries are synced.
A partial bootstrap, missing shard, unsupported schema or invalid database blocks
startup rather than triggering repair. Existing WAL layout mode 2 remains readable
by offline tooling but is refused by normal server startup. Imported flat shard
files are **not activated automatically**. The offline `tools/wal-to-sqlite/activate_import.py`
command assembles a new data directory from a verified import and its unchanged WAL
source. It preserves the original generation and copies retained files unchanged;
it never replaces an existing data directory. External attachment blobs must remain
available separately. See the importer's README before using this development cutover.

Attachment GC requires exclusive storage access and a valid SQLite layout. It opens
each shard read-only, validates integrity and foreign keys, and streams attachment
IDs from task and asset attachment tables. Retained-message references use the
existing retained scanner. Only unique live attachment IDs remain in memory; no
workspace records are replayed. All shards must pass before quarantine or purge
can begin. The existing dry-run, quarantine and restore behavior remains unchanged.

The coordinator starts up to four DB executor pairs before starting network workers.
Each pair has one writer and one reader thread. Each worker gets one port;
a shard's owner remains `shard % worker_count`.
Executors validate their assigned databases before reporting readiness, then open
handles lazily for requests. Workers initialize retained storage without replaying
workspace WALs. The listener opens only after all workers are ready. On shutdown,
workers stop submissions and release completions before the coordinator joins and
destroys executors. Startup tests cover all shard routes, worker-count changes,
persisted rows, exclusive locking, corrupt/missing shards and legacy-layout refusal.

Mutations require an explicit transaction. On any storage error, roll back the
entire operation. These are storage primitives, not replacements for handler
authorization, validation, history or cascades. Reads return owned task data
that must be freed with `workspace_db.destroy_task`; no SQLite row pointer
escapes. IDs and unsigned attachment sizes use eight-byte big-endian BLOBs so
values above `max(i64)` survive without losing precision or unsigned ordering.

```sh
./test/run_odin_tests.sh sqlite/ -vet
./test/run_odin_tests.sh workspace_db/ -vet
```

The store tests create and remove unique temporary directories. They cover
reopening committed records, workspace separation, nonzero-scope rejection, attachment replacement,
rollback and visibility between connections, sequence floors and overflow, and
rejection of foreign schemas and malformed attachments. They do not yet prove
power-loss durability or whole-server memory scaling.

On Linux, `workspace_db.start_executor` starts a writer/reader pair for an explicit
list of shard paths and a fixed number of worker ports. Each thread lazily opens,
uses and closes its own connections. Readers open main read-only and use deferred
read transactions; connection-local TEMP tables remain writable. Writers retain
Group Commit, WAL/FULL durability and projection finalization before commit.

Each port has separate bounded request, completion and output-return SPSC queues
for each thread, with one shared admission budget. Sequence barriers preserve
FIFO execution and response delivery per connection across both lanes, including
streamed results. The full generational connection handle is the ordering key;
internal requests with key zero share one default ordering stream per port.
Blocked connections are skipped in bounded pending lists, so an independent
connection can read committed snapshots while the writer works on the same port.
Ordering state is reference-counted through queued requests and spool cleanup;
the worker removes idle map entries after releasing the last result.
Read transactions end before output streaming,
so a slow network consumer does not pin the WAL. A long read still delays other
reads on that reader thread; a long write still delays other writes on its writer.
The 4 MiB cache target applies to each opened connection, not to the pair together.
Opening a handle uses SQLite's 100 ms busy timeout for transient WAL initialization
locks. The timeout is reset before returning the handle; ordinary requests do not
inherit that wait. It bounds each busy-handler invocation, not the entire open.

Get, Put and Remove remain internal storage primitives. The domain operation
Create_Task allocates an ID, finds the end of the workspace/status column
through a disk index, and writes task, attachments, sequence floors and history
in one transaction. The shared history JSON contract and label normalization
live in `protocol/history.odin`. Mutations commit before their completion is
published. There is no connection pointer in a request.
Submission copies input data with an explicitly supplied thread-safe allocator;
the submitting worker may reuse its input immediately. A rejected submission
has no DB effect and consumes no credit.

Each port limits both in-flight operations and charged bytes. Admission reserves
input storage and the maximum owned Get result or command-output RAM chunk.
Each WebSocket connection additionally has at most four outstanding DB requests
and 8 MiB of charged bytes, shared across reader and writer lanes. Both limits
are checked before copying inputs. A saturated connection cannot consume the
whole server port budget (64 requests / 16 MiB); other connections can still
submit if the shared budget permits. Runtime ports reserve 16 slots and 6 MiB
for the reader lane: writers can occupy at most 48 slots and 10 MiB. Readers
may use otherwise idle write capacity. Reservations use the existing
`read_eligible` classification; writes followed by reads on the same connection
still obey FIFO.

When a connection already has a write outstanding, another write must fit
within the first half of the port's writer allowance (24 slots / 5 MiB).
The remaining half admits first writes from other connections. This refusal
uses `db_connection_overloaded`; exhausted writer or shared budgets use
`db_worker_overloaded`. This is admission headroom, not a FIFO queue or a
starvation guarantee between clients. Refused requests are not stored.

The internal ordering key zero is exempt
from connection quotas, but remains subject to the port limits. These quotas
limit queued work, not query execution time or traffic across multiple sockets.
Credits remain occupied until the final chunk's `release_completion`, including
when a recipient disconnects.

Admission refusals use the exact error strings `db_connection_overloaded` and
`db_worker_overloaded` in the existing response envelopes. These codes mean the
request was not accepted and had no DB effect. ApplyTransaction uses a correlated
`S_ErrorResponse` for these two codes; domain rejection still uses TransactionResult.
Other failures, including unavailable storage, are not classified as overload.

The web client and CLI retry these refusals at most three times within a two-second
retry window, with exponential backoff and 0–50% jitter. Initial delays are 50 ms
for the connection limit and 150 ms for the worker limit. Bytes and correlation
IDs stay unchanged. Timeouts and disconnects never trigger a replay. The window
limits retry initiation, not the duration of an accepted DB operation. The web
client retains at most 128 retry candidates / 8 MiB; requests beyond that budget
still send normally and surface refusals without automatic retry.

`protocol-go` exposes `DatabaseOverload`, `DatabaseRetryDelay` and
`RetryDatabaseRequest`. The latter takes a context, request opcode, correlation
ID and an exchange callback on one connection. The callback must return the
matching response and honor cancellation; transport errors are returned unchanged.
CLI `Session.SendAndRecv` uses this helper, including slice pagination, and reports
the distinct code with `retryable: true` after exhaustion. Raw chat/watch streams
are unchanged. Rejected requests are outside server FIFO: callers requiring a
particular mutation order must await each result before sending the next mutation.

Result limits are checked before copying variable fields out of SQLite; an
oversized result returns `SQLITE_TOOBIG` without a partial task. These limits do
not cap SQLite's own heap, allocator overhead, thread stacks or fixed queues.
The limits used by tests are not production defaults or new protocol limits.

Command output stays in RAM by default (currently a 1 MiB per-job budget at server
startup). When another frame would exceed that budget, the executor spills the
prepared frames into a mode-0600 temporary file beside the shard database and
immediately unlinks its name. Serialize each reserved frame before reserving the
next one; spill may release earlier buffers. Before commit, the executor writes
the last frames, syncs the file and loads the first bounded chunk. Failures here
roll back the transaction and discard its output. A single frame and auxiliary
DM/ticket state must still fit the RAM budget; spilling is not protocol pagination.

The worker returns consumed chunks through the return SPSC. All file reads and
the final close remain on the executor. Later requests from that connection wait
until the stream is released; independent reads can progress even on the same port.
Mutating spools additionally hold the writer lane of their port until delivery
finishes, preserving cross-connection broadcast order. Shutdown
and disconnected initiators still drain streams so committed subscriber events
are not lost. A post-commit read failure closes workspace connections for resync
instead of claiming the mutation rolled back. This is a temporary delivery buffer,
not a crash-recoverable outbox. Disk use scales with the prepared output; OS page
cache and SQLite memory remain outside admission credits.

The worker event loop passes `port.wake.fd` as a second external wake source to
`nbio.tick`, alongside the connection-handoff eventfd. After draining a bounded
batch, `rearm_completions` runs before sleeping. It drains the eventfd,
atomically rearms notification and rechecks the queue. The executor uses the
same exchange/recheck protocol across all of its request queues. Wakeup errors
other than EINTR/EAGAIN are invariant failures, not silently ignored signals.

Shutdown calls `finish_submissions` on each submitting worker after its final
request, drains and releases all output chunks, then calls `join_executor` and
`destroy_executor`. Joining before a spooled result is drained would wait for
its return SPSC. No request is cancelled just because the caller stops waiting.

Executor tests use real threads and temporary files: concurrent FIFO traffic,
input-buffer reuse, count/byte admission, a stalled completion consumer, full
completion queues at shutdown, SQL errors with rollback, failed opens and result
size boundaries. Exhaustive wakeup interleavings remain unproven.

`worker_db.odin` attaches a port explicitly, tracks bounded pending requests by
internal ID, and keeps client correlation IDs and generational connection handles
on the worker. Submission takes the workspace from the authenticated connection.
Completion routing checks handle generation, connection state, workspace and
the captured username, stable subject and user type. The callback receives a nil
connection when the recipient is gone or no longer matches; it still runs so a
committed mutation can eventually publish its domain events. Callback payloads
are borrowed and automatically released on return. This is transport plumbing,
not domain authorization: handlers for private records must validate DB ACLs
and recheck read visibility.

`C_GetTask` / `S_TaskFull` uses the attached SQLite port in normal server builds
as well as tests. The path list is indexed by the existing logical workspace hash,
and empty entries reject admission rather than opening a temporary SQLite DB.
The handler accepts authenticated public scope-0 reads only, takes the workspace
from the connection and never falls back to RAM after a SQLite submission,
missing record or error. Public tasks have no additional per-record ACL today.
Task fields and attachments come from one read snapshot. The worker serializes
the borrowed result into its normal pooled WebSocket frame before releasing it.
Admission failures, storage errors and invalid/oversized responses return a
correlated failure; stale or disconnected recipients receive no response.

`C_CreateTask` uses the same attached port and authenticated public scope.
The worker supplies the verified actor and copies the request into the queue.
The executor validates response representability before writing, then commits
the complete creation. Its completion takes ownership of the already charged
input task; no second task allocation is required after commit. The worker sends
the correlated ACK and then the existing subscriber broadcast, even if the
initiator disconnected. Workspace records and history have no worker RAM maps.
Errors and admission rejection do not broadcast; there is no RAM/WAL fallback.

`C_ApplyTransaction` now routes to the attached executor for mixed task, asset and
edge batches. It reserves create IDs before resolving
forward references and checks version guards against the initial DB snapshot.
Repeated mutations of the same existing task are rejected. Completion consumes
dependencies against the complete set of task post-images, independent of patch
order; history separates user edits from system unblocks. Task deletion reuses
the disk-backed asset cascade and its organizer checks, and rejects surviving
dependents. Batch deletion sends no individual ACKs to the initiator.

Asset patches preserve omitted payloads and attachments. Parent and edge
references resolve against the complete post-image set; cycles and references
into the initial deletion closure reject the batch. That closure stores only
entity IDs in a disk-backed temp table and expands through the parent index.
Explicit edge deletions precede edge creations, allowing atomic membership
replacement while preserving unordered `MemberOf` uniqueness. Overlapping
explicit and cascading deletions emit each deletion once.

A savepoint rolls back semantic rejection together with ID floors and history;
prepared broadcasts are discarded before returning `S_TransactionResult` with
the failing operation index. Storage/output failures roll back the outer executor
transaction. Existing task copies have a cumulative budget based on the admitted
result credit; new fields borrow the queued request. Fixed operation arrays are
bounded by the protocol's 256-operation limit. This is not a hard process-memory
limit, and large batches can still exceed the development response budget.
Asset pre-images are read one at a time in a reusable arena. Tests exercise forward references,
cycles, stale guards, mixed cascades, private reminders, membership replacement,
history failure and output limits through the worker/SPSC path, and check
rollback and ID reuse in SQLite.

`C_StartDM`, `C_ListDMs`, and `C_LeaveDM` use SQLite executors.
Membership is durable independently of message retention in this backend;
leaving clears the actor's bit without deleting the pair or retained messages.
Starting an established pair restores both members even if the partner is
offline. New pairs require the target to be online at worker admission.
The list uses the two partial user indexes, never a workspace-wide replay.
Owned membership results and list serialization must fit the admitted response
budget; an oversized list fails without partially installing subscriptions.
The count probe stops after the budget-derived row capacity plus one, rather
than counting every membership before rejecting a large list.

Only successful completions install the touched DM metadata in the worker's
authorization/subscription state. Direct sends, subscriptions and retained
history requests load the requested memberships by primary key before dispatch,
so reconnecting clients need not call `ListDMs` or `StartDM` first. The lookup
does not change either participant's membership. It also runs with a warm cache:
membership mutations, membership lists and authorization requests use the writer
lane, with FIFO dependencies per connection. Thus `LeaveDM; Send` denies the send and `StartDM; Send` admits it
after a successful start. DM unsubscribe uses the same queue to avoid overtaking
a pending subscription. Completion checks the original handle and identity
before resuming the request. V1 subscriptions still skip unauthorized rooms;
V2 subscriptions reject the whole request.

Retained sends admitted before leave may finish afterward. Retained history
checks membership/subscription again before delivery and withholds the page
after revocation. Tests exercise these boundaries with real temporary retained
files and io_uring, including a cold send without reactivating the other member,
cold V1/V2 subscriptions, identity changes and a read still in flight at leave.
Online/authentication flags come from the worker's live connection indexes,
not SQLite. Start and leave update all live devices even if the initiating
connection closed before completion. Retained-message durability checks accept
the committed membership without consulting the legacy workspace WAL.
SQLite-loaded conversations own their participant names and allocate no workspace
record indexes. After the callback/presence wave, touched DMs with no subscribers
release their conversation, membership-list entries and names. Subscribed DMs
stay loaded until their last unsubscribe or disconnect. Retained I/O resolves
conversation IDs on completion rather than keeping these cache pointers alive.
Synthetic worker tests cover both membership-index arms, access denial,
multi-device revocation, empty membership masks, lazy reload, offline reopening,
failed writes, queue rejection, oversized lists, repeated subscribe/unsubscribe
cycles, last-disconnect cleanup and reopening the SQLite file.

`C_UpdateTask` and `C_MoveTask` use executor commands when a handler-enabled port
is attached. A command prepares bounded ACK/broadcast frames before commit;
failure discards every frame and rolls back the mutation, history and floors.
Task completion clears dependents with indexed, one-record-at-a-time seeks.
Partial-update sentinels, attachment preservation, append order and completion
identity follow the existing protocol. Large cascades spill prepared frames to
the executor-owned output file; test output budgets are not new product limits.

The executor groups eligible writes from one worker port to the same shard
into one SQLite transaction. When no next request is queued, it waits once for
1 ms before beginning; shutdown skips that wait. This is a collection delay,
not a maximum request latency. Each group stops at 32 requests or 100 MiB of
admitted charges, whichever comes first. Existing port admission credits remain
in force and can impose a smaller upper bound on group size. Requests blocked by
their connection's earlier read are skipped. A ready shard change, non-groupable
writer command or spooled response ends a group. Per-connection order is preserved.

Each request has its own savepoint. Constraint and output-size failures roll
back that request while preserving the others, provided SQLite still has an
active transaction. Other storage failures abort the group. Slice projections
are finalized once, then the group commits with WAL/FULL durability. Only after
that commit may responses and broadcasts leave the executor. A failed shared
commit discards every prepared response and rolls back the whole group. Groups
never span SQLite files; this does not batch Retained message writes.

`C_ListHistory` uses the same executor path. Each entity/endpoint index contributes
at most one page plus lookahead, with duplicate edges removed before serialization.
Immutable owner ACLs filter deleted personal records; current record availability
is checked within the same DB transaction. Pages obey count and byte budgets,
including unsigned cursors through `max(u64)`. Workers hold only the bounded
response, never the history collection. Authentication and malformed requests
retain their existing history error envelope.

`C_ListTaskDependents` checks parent existence and seeks the `tasks_blocker`
index within the same transaction. It reads at most one page plus lookahead,
ordered by unsigned task ID, without loading the parent body or a RAM index.
An absent parent remains distinct from an empty page. Count and byte limits,
exclusive cursors and attachments are exercised through the worker protocol.

`C_ListTasksPaged` reads a bounded page and count in the same transaction.
Done tasks sort by completion time; other tasks sort by update time, with
unsigned IDs breaking ties. The `tasks_page` expression index is selected
explicitly. Cursor queries split equal-time IDs and older timestamps into two
bounded seeks: the simpler tuple inequality did not produce an index range
seek in the checked SQLite query plan. Status masks, attachments, empty pages
and byte-limited continuation are covered through serialized worker requests.

`C_QueryTasks` uses the attached executor for all eight scalar sorts and WorkOrder.
Scalar queries count matching rows and sort narrow keys in SQLite, then load only
the response page's task bodies. IDs break ties in ascending unsigned order even
for descending sorts; zero due dates remain last. These queries can scan and sort
matching metadata; they are not constant-cost cursor seeks. WorkOrder builds a
disk-backed temporary priority queue with indexed dependency release, preserving
ready/unresolved/Done ordering and cursor reanchoring. Each page rebuilds that
order. No workspace-sized task or dependency array is retained in Odin.

`C_ListTaskSlices` reads persistent summaries and coverage counts; see
[SQLite schema 6](#sqlite-schema-6) for index-based paging and filter scan limits.
Unicode name searches stage matching rows in `temp.nrc_slices`, which is emptied
on success and failure, not dropped. Odin keeps only the bounded response page.
Counts include closed-slice coverage on the first unfiltered page, and project
filters select whole slices. Both handlers
obey output credits; SQLite caches and temporary-sort memory are outside those
credits. Tests exercise serialized worker requests, filters, paging, unsigned
ties, WorkOrder cycles/missing parents and connection reuse after output failure.

`C_GetTasks` now uses the executor too. It retains priority-descending/order-ascending
sorting and refuses lists exceeding the response budget with the existing advice
to use paged queries. SQL selects only enough candidate IDs to fill one response;
the handler does not collect the complete workspace before detecting overflow.
Equal priority/order ties use ID order, where the old map traversal had no stable tie order.
`C_ListTaskProjects` and `C_ListTaskAssignees` stream distinct nonempty BLOB names
from covering indexes in byte order. They copy at most 128 names per serialized
chunk, retaining the protocol's correlation and `has_more` semantics. Multi-frame
results larger than the RAM credit spill to the output file. Serialization or
spool failures before commit discard all prepared chunks.

`C_ListSliceOwners`, `C_ListTicketAssignees` and `C_ListCalendarPeople` use the
same bounded metadata chunks. Calendar people merge appointment projections with
all task assignees, including Done tasks and tasks without deadlines. The checked
query plan merges the two covering indexes without a temporary sort. Note-project
and note-tag facets keep their existing single-frame format: one index pass counts
bytes, and a second pass in the same snapshot encodes directly into the admitted
frame. They do not retain a separate array of names. Oversized results fail rather
than returning a truncated list. Worker tests cover duplicates, empty names, scope
and workspace isolation, chunk boundaries, and output-credit rejection.

`C_QueryCalendar` uses the attached executor for tasks, reminders, appointments
and recurring occurrences. Point events seek `tasks_due` / `reminder_deadline`;
appointments seek the existing power-of-two interval buckets. Checked SQLite
plans use range seeks and primary-key joins, with no workspace scan or temporary
sort. Appointment parsing and recurrence expansion use one-record arenas and
the existing timezone/exception rules. The handler retains at most 101 sorted
rows (100 results plus lookahead), copying only their text out of SQLite views
and temporary arenas. It does not rebuild the worker calendar indexes.

Personal-reminder visibility is applied before the point-stream limit. Person
and project filters, half-open intervals, overlap clamping, unsigned ID ordering
and cursor semantics match the existing wire format. Pages also stop at their
admitted byte budget; an individually oversized first row fails with a correlated
calendar error rather than returning an empty continuation. Worker tests cover
mixed-kind pagination, recurrence cancellation/rescheduling and exception-specific
participants, a full page displaced by a later-discovered appointment, byte
limits, ACLs, admission rejection and storage errors. Query work can still grow
with the number of overlapping appointment candidates; bounded result memory is
not a bound on executor latency.

`C_QueryTickets` uses the attached executor for lists, entries, attention polling
and read-cursor uploads. Existing Odin parsers retain Unicode search, body
decompression, visibility and activity rules. General queries stream one canonical
candidate at a time into a temporary SQLite table of sortable fields and activity;
only the response page retains asset bodies. Exact totals and body searches can
still scan all matching tickets and their entries. The attention polling path
without totals or search merges assignee-index ranges and stops after one page
plus lookahead. Two unsigned ranges preserve the existing signed-ID cursor order.

Read cursors remain connection-local metadata. Admission copies a snapshot into
the request; the executor prunes uploaded IDs against canonical Ticket assets.
Upload generations prevent an older completion from overwriting a newer upload,
even when a client reuses its snapshot token. A failed chunk invalidates the upload
so a queued end cannot certify it. Cursor copies and upload results consume the
transport byte credits; large snapshots remain subject to those development
limits. Worker tests compare serialized pages with the existing collector for
all sort orders, filters, search, entries and attention, and exercise superseded
uploads, storage failures and oversized entries. They assert that worker asset
maps and ticket indexes remain empty. No schema-version change is needed.

`C_GetTasksByIDs`, `C_GetAssetsByIDs`, and `C_GetAsset` use the attached executor.
Batch reads deduplicate IDs in request order and omit missing or invisible records
from both results and counts. Both passes run in the same SQLite transaction:
the first keeps only IDs and encoded sizes, and the second copies one protocol
chunk into a scoped arena before serialization. Header-only asset reads omit
the payload in SQL. Personal-reminder visibility, attachment order, binary payloads,
and correlation IDs retain their existing protocol semantics. Worker asset maps
remain empty. Tests cover empty batches, chunked output and atomic rejection when
total output credit is exhausted; large multi-frame output is tested through the
transaction callback, not through the worker's small test credit budget.
`C_ListAssets`, `C_ListAssetsPaged`, and the project/tag page variants also use the
executor. Exact counts scan matching metadata through the existing visibility and
active-contact parsers; only response-sized IDs and records are retained. Typed
and project/tag queries stream their ordered indexes. This bounds application
memory, not count-query latency. Pages stop at either the item or byte budget and
return the last serialized record's cursor. Untyped legacy lists use ID order
instead of the old unspecified map order.

Asset create/update and asset/task delete commands commit canonical rows, attachments, projections,
ID floors and history together, before publishing responses or broadcasts. They
preserve personal-reminder audiences, organizer checks, immutable room mappings,
normalized room-name idempotence and the single-agenda update behavior. Deletion
collects descendant IDs and child counts in a disk-backed temporary table, validates
the whole cascade, then removes incident edges and assets with one-record scratch
space. Edge history captures endpoint labels before asset deletion. Cyclic imported
components terminate through set-based discovery; deletion breaks their cycles in
ID order rather than recursing indefinitely. Large cascades spill their prepared
events to the output file. Preparation failures roll back the whole operation,
including history and events; committed chunks preserve child-before-parent order
and private-reminder audiences even if the initiator disconnects.

`C_DeleteTask` shares the asset cascade: task-owned descendants and all incident
edges are removed before the task, while linked endpoints survive. Task and asset
IDs remain separate namespaces, including when their numeric values match.
Deleting a task does not clear other tasks' `blocked_by` fields; only completion
does that, matching the existing behavior. Child deletion events include the
requester, while the root deletion has its correlated ACK and subscriber event.

Edge create/delete and all four edge-list operations use executor commands.
Creation checks both endpoint identities and visibility, refuses personal-reminder
relations and self-links, and treats `MemberOf` as an unordered set. Canonical edges,
ID floors and endpoint-labelled history commit before ACKs or broadcasts. Lists
use ascending unsigned ID order; unpaged lists reject oversized responses rather
than truncate. Incident pages seek `edges_source_page` and `edges_target_page`,
each limited to one page plus lookahead. Only these bounded candidate sets are
merged; legacy self-links appear once. Counts share the page transaction but still
visit matching edges. These paging indexes supplement the relation-first indexes
used for relation filters. Server and importer use the same schema and migrations;
see [SQLite schema 6](#sqlite-schema-6).
Membership preflight uses two explicitly indexed endpoint seeks rather than a
workspace-wide `OR` scan. The unique normalized membership index still enforces
the invariant. `room_mapping_asset` is unique on workspace/asset: one mapping asset
supplies one name. It also lets projection cleanup and foreign-key cascades find
the mapping by asset without scanning every room or requiring planner statistics.

`C_GraphDegree` and `C_GraphCommonNeighbors` use the attached executor. Degree
aggregates endpoint counts in SQLite and copies at most 100 ranked entries into
Odin. It still visits matching workspace edges. Counts above 65,535 return a
correlated error instead of wrapping the protocol's u16 field. Common-neighbor
queries seek both endpoint indexes, intersect neighbors in disk-backed temporary
tables, and fetch only the result edges by primary key. Direction, relation masks,
parallel edges and unsigned ordering retain their existing semantics; dangling
endpoints are not discarded. These shared-edge queries do not load entity bodies.
Common-neighbor replies have no truncation flag, so exceeding the response budget
fails the whole request. Tests cover exact byte limits, the degree overflow
boundary, identical endpoints, workspace isolation and scratch-table cleanup.

`C_GraphQuery`, `C_GraphShortestPath` and `C_GraphRank` also use the executor.
Traversal retains at most 500 visited nodes per search/anchor, shortest paths
at most 2,000, matching the existing protocol limits. These bounded frontiers
stay in Odin; selected edge IDs and ranking arcs stay in SQLite temporary tables.
Adjacency scans merge the two endpoint/ID indexes in unsigned edge-ID order.
This makes equal-length path choices deterministic instead of depending on legacy
adjacency insertion order. Ranking streams the selected arcs for each of its
existing score iterations, retaining at most 2,500 node scores. It preserves
anchor weights, requested-candidate order, explanation paths and zero scores
outside the selected graph. Results exceeding the response budget fail atomically.
Tests cover scores against an independent edge-list oracle, directions, path depth,
the 500/2,000-node boundaries and temporary-table cleanup after output failure.
The synthetic timing workload and its limits are in [BENCHMARKS.md](BENCHMARKS.md#sqlite-graph-queries-and-workorder).

`C_GetWorkspaceOverview` aggregates task status and unique slice coverage in the
executor transaction. Closed slices still assign work; only open slices contribute
to size, blocked and age buckets. Valid slice projections exclude malformed previews.
The handler keeps fixed counters and one aggregate row, not task bodies or a set
of assigned IDs. Endpoint lookups explicitly select the relation-first indexes:
the unhinted plan scanned workspace edges for each task or slice. Exact overview
counts still visit workspace tasks and matching memberships; this is bounded
application memory, not constant query time. Tests cover bucket boundaries,
reversed/shared memberships, reopen, invalid statuses, and 65,536 tasks with
25,601 slices beyond the register's page and u16 counter limits.
Admission and executor failures return an unsuccessful overview frame with the
original correlation, so the overview client completes the request immediately.

`C_SearchCustomers` streams customer projections in unsigned company-ID order.
It preserves Unicode-lowered substring matching, decimal unsigned ID search,
company archive filtering, and contact matches through either membership direction.
Archived contacts remain searchable, as before; contact IDs and activity records
do not match companies. Contact probes seek the existing endpoint/relation indexes
and stop at the first match. Exact totals still scan metadata, while canonical
headers are loaded only for one bounded page plus a possible byte-limit candidate.
The checked query plans need neither a full edge scan nor a temporary sort.

The worker fixture covers late history failures, output-credit rollback, private
reminder reads/events/deletion, descendant organizer protection, project/tag cursor
ties, active-contact filtering and binary payload/attachment preservation. Task
reorders now record `order_index` in history, including reorder-only moves; repeated
no-op moves create no extra history. Legacy RAM handlers and indexes have been
removed; tests exercise the SQLite path with disposable databases.

The standalone [offline importer](../tools/wal-to-sqlite/README.md) reads frozen
Sharded-V1 formats and publishes a new, verified but **not activated** directory.
It requires an explicitly supplied Odin projection builder, built with
`odin build . -define:NRC_SQLITE_PROJECTION_BUILDER=true -out:projection-builder`.
The builder takes one existing SQLite shard path and rebuilds projections in
one transaction using the server parsers. The importer also validates deleted
and overwritten Appointment/Ticket/TicketEntry postimages through that builder.
Retained message files remain in their original generation. The separate
`activate_import.py` command copies them into a new SQLite data directory; it
never replaces the source installation. The full test matrix compares the frozen
schema and runs all importer tests with a freshly built real builder; this
requires Python 3.11+, Python SQLite 3.37+ and `libxxhash.so.0`.
The real-process `TestRetainedImportActivationAndRestart` test generates active,
sealed and frozen retained data with the Odin writer, imports and activates an
offline layout, reads messages over WebSocket before and after restart, and runs
attachment GC before startup and after restart. All inputs and blobs are disposable.

Pre-tick and post-I/O phases drain at most 64 completions per invocation and
rearm the wake even when more work remains. Worker shutdown closes admission,
drains pending operations before detaching, and retains routing state until the
last callback. The coordinator must join/destroy an attached executor only after
all its workers have finished. Server startup initializes the database executors
before starting workers; shutdown stops them after the workers finish.

The root `test_worker_db_*` fixtures use real io_uring, a worker-local TLSF heap,
a separate DB thread and temporary databases without invoking WAL replay. They
cover live result routing, stale connection reuse, changed authenticated subject,
bounded drain/rearm, and committed writes surviving disconnect and worker shutdown.
The task-handler fixture also feeds serialized requests through the real opcode
dispatcher and parses queued WebSocket replies. It checks attachments, missing
records, workspace isolation, private-scope rejection, authentication, backpressure,
unassigned shards, failed opens, result limits and invalid stored fields without
populating entity maps. Create tests inspect ACK/broadcast correlation, copied
attachments, disconnected initiators, cross-workspace delivery and rejection
under backpressure. Executor tests inject a failure at history insertion to
check rollback of the task, attachments and both floors; they also cover sparse
column ordering, the last valid u16 position, history-ID overflow, service actors
and reopening committed data. These tests do not use a real WebSocket client,
simulate power loss, exercise a production migration or establish whole-server
memory scaling.

## Architecture

The main thread accepts connections and routes an owned HTTP upgrade request to
a workspace worker. That worker validates authentication/upgrade and owns its
connections, state, subscriptions and persistence I/O through io_uring.
`NRC_THREAD_COUNT` counts workers, not all process threads. By default a service
core is reserved when possible, and workers use the remaining physical cores.

The storage bulk pool executes retained-message seals and obsolete retained WAL
cleanup. Configure it at startup with `NRC_STORAGE_BULK_EXECUTORS` (1–64,
default 2) and `NRC_STORAGE_BULK_CPUS` (comma-separated logical CPU IDs/ranges,
for example `24-29`). With no CPU list, executors retain the existing behavior
of sharing the service CPU; increasing their count alone adds no CPU capacity.
With a list, executors are pinned round-robin in list order. The list must be
unique, inside the process's allowed cpuset, and no longer than the executor
count. Bulk physical cores, including allowed SMT siblings, are excluded from
worker/control placement when topology is known; otherwise only the listed
logical CPUs are excluded. At least two non-bulk physical cores must remain
(two logical CPUs when topology is unknown). The automatic worker count accounts
for the reservation; an explicit `NRC_THREAD_COUNT` can still oversubscribe the
remaining worker CPUs. An overlapping `NRC_SERVICE_CPU`, invalid reservation or
combination with `NRC_DISABLE_CPU_AFFINITY` exits with status 2 before opening
storage. CPU IDs must be chosen from the actual host topology, not core labels.

For example, on a suitable 32-core host, reserve six bulk CPUs:

```sh
NRC_STORAGE_BULK_EXECUTORS=6 NRC_STORAGE_BULK_CPUS=24-29 ./server
```

The control thread remains separate from an explicit bulk pool. Ownership,
one outstanding seal per shard, fsync-before-ACK and recovery formats are
unchanged. More executors increase concurrent memory and I/O demand; benchmark
throughput, queue age, latency and RSS rather than assuming linear scaling.

Workspace bytes hash to one of 256 logical shards; the shard maps to a worker.
Changing worker count changes ownership, not storage identity. Task, asset and
edge mutations share atomic SQLite transactions. The server no longer contains
workspace WAL writers, replay, compaction, or full-record RAM indexes. The offline
importer's frozen readers handle old workspace WALs, manifests and checkpoints.
Retained message files and lifecycle are unchanged.

Transient asynchronous send buffers
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

Graph queries run on the database executors. Common-neighbor results
have no truncation flag, so results exceeding the protocol byte/count limits return
a correlated error rather than a partial result or no response. Narrow the relation
filter for these requests; larger complete results need a paginated protocol.

Retained-message append batches use io_uring. The worker retains each immutable
batch until write completion. ACKs still wait for fsync. Admission permits at
most 512 live send contexts per store, including duplicate retries, and at most
256 unique deferred requests. Contexts retire after write completion; ACKs
waiting for fsync remain in separately bounded connection outboxes, outside this
context limit.

Retained-message history and sealed dedup lookups open, read and close their read descriptors
asynchronously. The service thread samples RSS and disk space; requests consume
cached values. Disk-space probes refresh after one second, and samples older than
two seconds or failed probes cause write-admission backpressure, reported to
protocol clients with WebSocket close code 1013 (retry later). Concurrent lazy
history opens reserve cache capacity; duplicate opens and descriptor exhaustion
return a retryable capacity error rather than poisoning the store. Startup takes
the initial sample synchronously.

### Retained DMs

Positive `NRC_MESSAGE_RETENTION` retains V2 messages in both rooms and DMs;
there is no separate DM setting. The setting takes effect at startup; DMs share room retention,
deduplication, per-shard quota and storage. The web client negotiates each DM via
`C_SubscribeConvsV2`; the CLI can send explicitly with
`nrc chat send --room <unsigned-DM-ID> --retained "message"`.
V1 messages remain ephemeral, including from older clients.

SQLite stores canonical participant pairs and membership before retained bodies
can be admitted. The bounded worker cache receives only committed membership;
inactive pairs and revocations remain in SQLite. Established DMs survive restart and can
be reopened with an offline partner; starting an unknown pair still requires the
partner online. Presence and unread counters remain session-scoped.

Leaving revokes membership on every device, not message storage. Starting the
same pair again re-adds both participants, as before, and restores access to its
unexpired history. Leave is not Block or an invitation/consent mechanism.
Already admitted sends may finish after leave, but subsequent sends and history
delivery require current access; history also requires a current subscription.

`NRC_MESSAGE_RETENTION=0` disables retention for both rooms and DMs, with the
existing store-wide purge-floor behavior: disable/re-enable does not resurrect
old room or DM history. Existing persistent DM membership changes remain durable
while retention is disabled.
Message retention is bounded; persistent pair metadata is not automatically
garbage-collected when both users leave. Older workspace-WAL binaries cannot read
the SQLite layout; downgrading requires restoring a pre-migration backup.
The network formats are unchanged.

Retained WAL rotation, segment publication and retention cleanup
run on the storage service through a separate bounded control queue. Bulk sealing
and obsolete-source deletion use two bounded executors that share the
reserved service CPU, overlapping IO waits without taking a worker core. Bulk
completions return through a bounded multi-producer channel; the service retains
backpressured results and remains the sole producer of each worker's SPSC result
queue. Shutdown joins all producers before draining jobs and completions.
Workers submit detached, backing-allocator-owned
snapshots and gate the affected shard until the durable publication result is
adopted. No worker indexes, arenas, connection handles or live WAL file objects
cross this boundary. Snapshots carry buffer-free WAL metadata, not the 128 KiB
append buffer; frozen sources carry only a segment descriptor. Job-owned
segment metadata and WAL paths transfer ownership without
another deep copy. WAL paths retain their allocator across adoption. The worker's
still-authoritative retained segment descriptors remain detached
copies. Rotation drains write/fsync leases before submission;
retention also drains history readers. Sealed publication preserves already
borrowed frozen snapshots and the active WAL's outstanding fsync boundary.
Publication results wait for completion-queue capacity rather than being
dropped. Shutdown never overwrites a manifest while its publication is pending.
Startup, recovery, standalone stores without a service, and shutdown retain
synchronous filesystem operations.

Retained-message WALs rotate at UTC day boundaries, or earlier at the existing
size/index limits. Worker maintenance also rotates nonempty idle WALs at the day
boundary, or once all their messages have expired for shorter retention periods;
no new append is required. Empty WALs do not produce daily segments. Rotation
uses the same write/fsync and reader drain gates as append-triggered rotation.
History hides expired messages at the retention cutoff; physical cleanup removes
a whole sealed segment only after its newest message expires and readers drain.

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
| `shard_*.odin`, `persistence/`, `storage_io/` | Durable writes and legacy recovery |
| `storage_service.odin`, `storage_lifecycle.odin`, `message_seal.odin` | Retained maintenance, publication and cleanup |
| `nbio/`, `byte_pool/`, `spsc/` | Networking, buffers and handoff queues |
| `client/`, `cli/`, `protocol-go/` | Web client, CLI and shared Go wire codecs |
| `services/` | Tailscale gateway and optional processors |

See [persistence](SHARDED_PERSISTENCE.md), [simulation](DETERMINISTIC_SIMULATOR_PLAN.md)
and [benchmarks](BENCHMARKS.md) for deeper engineering details.
