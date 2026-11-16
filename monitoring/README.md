# Monitoring domain foundation

An allocation-free Odin state machine evaluates instance lifecycles.
SQLite persists instance state and episode lifecycles.
Server commands bind those records to Monitor and Incident assets.
The Go sidecar implements HTTP/TCP and Victoria instant-vector checks; shared
Victoria sources are configurable through `nrc monitor source`.
See [the sidecar contract](../services/bots/nrc-incidents/README.md).
The web client provides a status register and shared Monitor/Incident Inspector;
configuration and instance lifecycle controls remain in the CLI. The approved concept is in
[NRC Monitoring-Konzept](https://ampcode.com/artifacts/nrc-monitoring-konzept-1c0e9163-edfc-43d6-82bd-0ffacc660056)
and NRC note 5956, referenced from
[the implementation thread](https://ampcode.com/threads/T-01a1d69e-091a-716d-b6e8-08fc17f434e1).

## Evaluation contract

`evaluate` operates on one instance selected by its canonical identity. It returns
episode transitions separately from the latest observation and its freshness.
Callers must persist state, incident changes and webhook outbox changes atomically.
An episode ordinal is not an Incident asset ID. Human acknowledgment and assignment
belong to the incident record; evaluation does not own or overwrite them.

Only a successfully admitted, complete regular evaluation may supply `Absent` or
reactivate a retired instance. Test queries do not call this mutating API. A failed
or incomplete query supplies `Evaluation_Error`, never inferred absent rows. The
server command described below admits complete runs; adapters still own label
canonicalization and query execution.

The default thresholds are five failures, five recoveries and three missing
observations. Staleness is three intervals plus timeout, in nanoseconds. All
timestamps are supplied by the server caller, which uses the repository clock.
Passing/Failing/Between are already classified results; threshold comparisons and
multi-condition evaluation are not implemented here. The numeric last value is
retained across missing observations and errors, but is not a history store.
`last_observation` describes the latest accepted evaluation, including absence and
query errors; `last_value` and `last_seen_at` describe the last present sample.
An absent result after that sample expires remains `No_Data`, even before the
missing-count threshold or the next maintenance tick.

New runs must have a positive increasing sequence and nondecreasing evaluation
time. Duplicate/older sequences are ignored. This is only a state-machine guard,
not durable idempotency: the command layer adds receipts and revision/identity
checks. Instance controls fence old runs through the Monitor revision.
Server maintenance persists staleness independently of the sidecar. New
observations also break expired streaks even if maintenance did not run during
an outage.

## Initial choices for previously open cases

- Between trigger and recovery thresholds, reset both consecutive streaks while
  keeping an open episode. Equality must be classified by the rule evaluator.
- Errors and absent observations reset failure/recovery streaks. Errors also reset
  the consecutive absence counter. No missing-data incident is created by default.
- Pause resets streaks without closing an incident. Resume shows unknown freshness
  until a new observation. Persistent counters are intended to survive a restart;
  elapsed staleness breaks them before counting a new observation.
- Retirement closes as removed, never recovered. The next admitted present result
  reactivates the same instance with fresh streaks; a later qualified failure opens
  a new episode. Reactivation by itself is not an alarm-notification event.

These are initial implementation choices, not additional UI requirements. Pause,
snooze and retirement UI availability remains undecided. Rules, sources and routes
are configured through the CLI; incident acknowledgment/assignment will be available
through both CLI and UI. Technical recovery remains evaluation-driven.

## Verification and remaining integration

Run `./test/run_odin_tests.sh monitoring/`. Tests cover asymmetric thresholds and
independent instances, interrupted recovery, missing/error paths, the exact stale
boundary, pauses, retirement/reactivation and rejection without mutation. The package
is included in `test/run_all_tests.sh`.

`workspace_db.apply_monitor_evaluations` applies up to 1,024 supplied observations
inside an existing write transaction with a batch savepoint. Identity is scoped by
workspace and monitor ID; callers supply canonical label bytes. A durable instance
ID is allocated once. State and episode open/recovery records commit together.
Each monitor/identity pair may appear only once per batch; duplicates are rejected
before any writes, including exact duplicate observations.
Floating-point last values are stored as eight-byte IEEE bits, without text conversion.
The explicit schema-4-to-5 migration and the offline WAL importer use the same SQL.

One fixed-size receipt per instance preserves the latest evaluation (including its
policy) and transition result. Exact retries return `replayed=true`; callers must
not send its events again. Conflicting or older sequences are rejected. This is not
a run-level ACK protocol and does not promise replay of arbitrary historical runs.
Late errors in a batch undo its changes and ID allocations without undoing earlier
work in the outer transaction. All output remains provisional until outer commit.

Run `./test/run_odin_tests.sh workspace_db/` for persistence tests. The monitoring
cases exercise reopen, isolation, exact/conflicting retries, injected episode-write
failure, outer rollback, duplicate-instance rejection and episode recovery. The schema
upgrade test covers rejection of old files, atomic migration failure and reapply.

## Asset and server contract

Asset types 15 (Monitor) and 16 (Incident) use the existing asset read/list and
subscription paths. Monitor configuration uses generic create/update commands or
revision-guarded transactions. Monitor preview version 1 requires `name`,
`evaluator` (exact authenticated username), `enabled`, `interval_ns`, `timeout_ns`,
`failures`, `recoveries` and `missing`. Its plain JSON-object payload holds the
adapter-owned check definition; typed adapter validation comes with the sidecar.
Monitor configuration is shared workspace data, under the existing asset access
model. The evaluator check is not a new workspace administrator role.

`C_ApplyMonitorRun` (68) accepts one complete result or a failed query for an
existing, enabled Monitor at its exact `updated_at` revision. Only its configured
evaluator may submit. The worker supplies workspace and authenticated identity;
the server timestamps accepted observations. Sequences increase across revisions.
Changing the config breaks old streaks before the next accepted run.

Successful runs infer `Absent` for omitted active instances; failed runs supply
`Evaluation_Error` instead and must carry no rows. Empty success is not zero.
Identity bytes are opaque and must be canonicalized by the adapter. A run may
cover at most 1,024 identities in the union of active and returned instances.
Retired and paused instances remain stored but are excluded from the active scan
and inferred absence/errors. Returning retired identities count toward the budget
again and reactivate with the same ID; returned paused identities count but stay
paused. Missing instances remain active until explicitly retired. Exceeding the
budget rejects the whole run without truncation or history deletion. A partial
index keeps the active scan independent of retained history.

The latest complete request, excluding correlation ID, is retained per monitor.
An exact retry under the same current revision returns only the ACK, with no
repeated history or broadcasts. Reordered rows are a different payload. Older or
conflicting sequences are rejected. ACK follows the executor's durable commit.
This receipt is bounded deduplication state, not measurement history.

Opening/recovering episodes creates/updates Incident assets and appends history
in the same transaction as instance state and the run receipt. Episode rows point
to those assets. Human fields exist only on the Incident asset. Generic commands
cannot create, edit or delete Incidents. Monitors cannot yet be deleted either;
disable them instead. Both types are root assets, so deleting an unrelated parent
cannot cascade into monitoring state. Other records link through ordinary edges.

Run `test_sqlite_monitor_run_assets_and_guards` in the root test package for the
command path, including failed-write rollback and retry after reopening SQLite.
Go and Odin codecs share a fixed wire fixture in their protocol tests.

## Instance pause, resume and retirement

`C_ControlMonitorInstance` (69) changes one existing instance by its stable ID,
scoped to the authenticated workspace and supplied Monitor ID. Workspace members
may act, as with shared Monitor configuration; the evaluator-only restriction
applies to observations, not these manual actions. Disabled monitors can still
have their instances controlled.

- Pause clears consecutive counters and marks freshness unknown. It keeps the
  last sample and an open incident. Subsequent runs skip the paused instance.
- Resume clears the pause but does not claim a fresh observation or recovery.
  It rejects admission if the active budget is full. Other instances' counters
  remain unchanged.
- Retire closes an open episode with reason `2` and Incident status `removed`,
  never `recovered`. It replaces any pause, retains identity/history and frees
  active capacity. Only a subsequent complete, present observation reactivates
  it; pause/resume reject retired instances. Reactivation starts new streaks and
  cannot reopen the removed incident.

Every accepted action advances the Monitor asset's `updated_at` revision. Clients
must supply its current revision. This rejects results started before the action
without inventing a second run generation. The sidecar must fetch the new revision
and perform a new check, not relabel an old result. Manual revision changes preserve
other instances' streaks; a pending configuration-change reset remains pending.
Actions do not consume run sequences or replace the last observation. Even a
same-state action under a fresh revision advances this fence and records the action.

One latest action receipt per monitor supports exact retries by the same
authenticated actor/subject, excluding correlation ID. It survives reconnects
and reopen. While that resulting Monitor revision is current, retries return the
original revision with `replayed=true`, without writes, history or broadcasts.
This is an acknowledgment of the old action, not a fresh state snapshot: retrying
retirement after automatic reactivation must not retire the new episode. A later
manual action or configuration edit invalidates that retry. Clients must read the
current Monitor revision before a new action.

Instance/episode state, Incident closure, revision, action receipt and an actor-stamped
Monitor history event commit together. Monitor revision and Incident changes use
the existing asset broadcasts. `S_MonitorInstanceControlled` (175) is sent only
after commit. Retirement does not generate an outbound recovery event.
Use `nrc monitor pause|resume|retire <monitor-id> <instance-id>`; retirement requires
`--confirm`. The CLI reads the current Monitor revision and does not retry an
unconfirmed action automatically. Bulk actions and web UI lifecycle controls are
not implemented. See the [CLI guide](../cli/README.md#pause-resume-and-retire-instances).

Run `test_sqlite_monitor_instance_controls` for pause/resume, interrupted recovery,
workspace/monitor isolation, old-run rejection, unaffected neighboring streaks,
late-write rollback, durable retries, retirement/reactivation/new episodes, pending
config resets and resume at the active-capacity boundary.

## Incident acknowledgment and assignment

`C_ActOnIncident` (70) lets workspace members acknowledge or assign an Incident.
Acknowledgment records that someone has seen the incident, not that the problem
has recovered. The first acknowledgment stores the authenticated actor and server
timestamp; later acknowledgment cannot replace them. Assignment is independent:
it can change or be cleared, using a UTF-8 name of up to 32 bytes, as with tasks.
Neither action pauses monitoring or changes technical status. They apply to open
and closed incidents. Recovery and retirement preserve these fields; a new episode
starts with empty human fields.

Clients supply the current Incident revision, not the Monitor revision. Every
fresh accepted action advances it, including same-state actions. Only changed
human fields append an actor-stamped history event. The asset update, history and
latest receipt commit together; broadcasts and `S_IncidentActionApplied` (176)
follow commit. Human actions leave monitor and instance state unchanged.

One latest receipt per Incident binds the request bytes excluding correlation to
the authenticated actor/subject. Exact retries return only the ACK while the
resulting Incident revision is current. A later human action, recovery or retirement
invalidates the receipt. Tests in `test_sqlite_incident_human_actions` cover reopen,
retry, conflicting edits, late-write rollback, audit identity and lifecycle changes.
`nrc incident ack` and `nrc incident assign` expose these actions in the CLI;
the web client's Incident Inspector provides the same revision-fenced operations.

## Background freshness maintenance

The worker's 100ms maintenance tick starts a burst of at most eight internal SQLite
writer jobs, with at most one executing/queued maintenance job per worker.
Completions submit the next job within that budget. Ready shards rotate in owner
order, including workspaces with no connected clients. Each job scans at
most 64 eligible instances using a seek cursor over shard-wide instance IDs.
A partial index excludes paused, retired and already-stale instances with reset
counters. This bounds each job; 64 is a page size, not an instance limit.
Each scan captures the instance sequence high-water mark in its first transaction.
Subsequent pages stay at or below that fixed boundary, so newly created instances
cannot postpone the next scan indefinitely. Cursor and boundary travel together.

At three current configured intervals plus timeout since the last present sample,
maintenance persists `No_Data` and clears failure/recovery streaks. It retains the
last measurement, last observation, sequence, receipts, episodes and Incident human
fields. It neither recovers nor retires an instance and emits no Incident update.
Disabled monitors' old measurements still age; paused/retired instances are skipped.

The batch commits atomically before the worker advances its cursor and boundary. Admission
pressure delays submission without accumulating jobs. Failed batches keep their
continuation for retry and log the error; other shards proceed. Completed scans
(including empty shards) and errors wait five monotonic seconds before becoming
eligible again. Unfinished scans remain eligible for the next job in the burst.
Shutdown stops new jobs and drains admitted ones. Cursors restart from zero after
restart; already persisted staleness is unchanged.

The staleness threshold is exact, but persistence follows on the next visit.
Ignoring execution time and queue pressure, visiting 256 ready shards takes 32
eight-job bursts (about 3.2 seconds instead of 25.6). Completed shards then stop
competing for five seconds. A 1,024-row shard needs 16 pages; the worker test drains
it alongside a one-row shard in three ticks (8 + 8 + 1 jobs), not 17 shard rounds.
These are scheduling counts, not measured latency guarantees. Busy executors and
many simultaneously large shards can still delay updates. Evaluations themselves
enforce staleness at their timestamp.

`test_sqlite_monitor_maintenance` covers the time boundary, distinct policies,
bounded continuation, rollback, reopen, retries and retained Incident fields.
`test_sqlite_monitor_maintenance_growing_scan` adds a full page before every step
and verifies that the scan completes and revisits the oldest samples anyway.
`test_worker_db_monitor_maintenance_without_clients` runs the worker maintenance
entry and real SQLite executor without sockets, checking shard ownership,
burst bounds, completed-scan backoff and shutdown. It does not exercise io_uring timer delivery.

## Direct measurement history and webhook outbox

The Go sidecar writes measurement history directly to its own DuckDB.
NRC has no measurement-export queue, run markers or history-delivery protocol.
The sidecar sends evaluations over the NRC protocol; it never opens NRC SQLite.
SQLite remains authoritative for rules, current instance state, Incident lifecycle
and human actions. Its record history remains intact.

DuckDB observations must be correlated by workspace, monitor, revision, run
sequence and canonical instance identity. Retries must not duplicate samples.
Keep NRC acceptance separate: confirmed, rejected or unknown. A timeout or lost
connection is unknown, not rejection; a stored measurement is not proof that NRC
accepted it. DuckDB and NRC have no shared atomic commit. DuckDB failures must
not prevent evaluation delivery; expose history gaps instead of blocking alerts.
Retention and aggregation stay in the sidecar. Maintenance does not invent samples;
history readers derive freshness from sample times and configuration snapshots.

SQLite commits webhook events with Incident transitions. Run replay does not
enqueue again.

Monitor previews accept an optional `webhooks` array of up to eight distinct route
references. References are 1–64 ASCII alphanumeric, `-`, `_` or `.` bytes.
Firing and recovery enqueue one immutable Incident snapshot per configured route.
Retirement and human acknowledgment/assignment do not notify. Events keep the
route reference selected when they were created, even if the Monitor changes.
The Go dispatcher resolves canonical decimal IDs of immutable `MonitorSource`
assets with kind `webhook`. The CLI validates their existence and kind; the
low-level protocol still accepts opaque references. Route updates and deletion
are refused by the server. Secrets resolve only in the sidecar environment.
Old route versions must remain resolvable until drained. No URLs or credentials
are stored in these event payloads.

The current evaluator can discover persisted webhook routes with action 6 of
`C_MonitorDelivery`, even for a disabled Monitor. Each page returns up to 32
distinct queued or dirty references, including old versions and dead-only lanes. The
empty route starts a scan; `next_route` continues it exclusively. Empty
`next_route` ends the pass. This reads the queue itself, not current configuration
or the consumer's local history. Consumers periodically restart the live scan
from empty to find concurrent inserts behind the cursor. Clean drained lanes disappear;
old settlement receipts alone do not keep a lane discoverable.

Each workspace permits 10,000 webhook entries or 16 MiB of payload; each event
permits 32 KiB. These bound queued payload, not total SQLite file/WAL size.
A full outbox does not reject evaluations or recovery. Existing entries stay;
new transitions update one durable loss marker per monitor/route version.
Configuration reserves this metadata, with at most 256 retained route versions
per monitor. Exhausting that limit rejects configuration, not evaluations.
Real database errors still roll back the command. Completed delivery frees the
budget; dead webhooks still count.

After a dirty lane drains, claim creates a leased `webhook_resync` token. Action 7
pages the current open-Incident IDs, 32 per page, under its `sync_version`.
Start with ID zero and continue with `next_id`; zero ends the pass. Stage the
whole set before sending it to the receiver, including an explicitly empty set.
State 7 invalidates the snapshot: discard staged pages and ACK the obsolete token
without publishing. Its newer marker remains and the next claim starts over.
Requests for an already replaced token fail instead of returning the replacement
token's settlement credentials. State 7 only describes the requested current token.
ACK only after receiver confirmation otherwise. Changes during paging or delivery
advance the marker, so ACK of an older token cannot clear them. Receivers/adapters
must support this replacement-set operation; it cannot reconstruct lost transitions.

Delivery is FIFO within `(workspace, monitor, stream, route)`. A waiting or dead
head blocks that lane; other monitors/routes can advance. `C_MonitorDelivery`
supports peek, claim, delivered, retry, permanent failure and explicit discard of
a dead webhook. Workspace members may inspect lanes and explicitly discard a
dead head by ID/generation. Only the currently configured evaluator may lease or
report delivery outcomes, including disabled Monitors and old route references.
Claims last 60 seconds, bind actor
and authenticated subject, and increment a generation on each new lease.
Repeating a live claim by the same owner returns it without extending the lease.
An expired/replaced lease cannot settle. The client must finish before expiry;
there is no lease renewal command.

Retry delays are 2, 4, 8, 16, 32, 64, 128, 256, then 300 seconds. A webhook becomes
dead after ten leases or an explicit permanent failure. It stays inspectable
until explicitly discarded; discard also marks the lane for resynchronization.
One latest settlement receipt per lane makes repeated
ACK/retry/discard commands idempotent; older receipts are replaced, not retained
as an unbounded ledger.
When configuration prunes a clean, drained, no-longer-configured route, its receipt
is removed in the same transaction. This ends that route's settlement replay window.
Configured, dirty or still queued routes retain their receipts.

Events are version-1 JSON. Outer IDs/revisions/timestamps are decimal strings;
opaque identities are arrays of byte values. Delivery IDs are shard-sequence IDs;
consumers must deduplicate by workspace plus delivery ID. There is no global
delivery order across monitors.

The sidecar acknowledges webhook delivery after receiver confirmation, independently
of DuckDB. A crash after HTTP delivery but before ACK causes redelivery.
Webhook receivers need the same idempotency key if duplicate HTTP requests are
unacceptable: this protocol provides at-least-once, not exactly-once delivery.

The server command, SQLite persistence, Odin/Go protocol codecs, HTTP dispatcher,
DuckDB ingestion and route configuration CLI are present. See the
[sidecar contract](../services/bots/nrc-incidents/README.md#outgoing-webhook-routes)
for HTTP status handling, resync limits and receiver requirements. Human CLI
outbox inspection/discard is available through `nrc monitor webhook`;
the sidecar contract documents history retention, aggregation and the web client.
No production migration
has been run. Schema 5 remains an unreleased development schema; databases made
with earlier versions of this work need recreation rather than automatic upgrade.
