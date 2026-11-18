# nrc-incidents

Monitoring sidecar: HTTP/TCP and Victoria instant-vector checks, bounded scheduling,
NRC protocol submission and direct DuckDB 2.0 history. The NRC web client displays
current state and reads history through the authenticated gateway.
Inbound webhooks are not implemented yet. An optional HTTP API reads local history.
Outgoing webhooks drain NRC's
transactional outbox independently of checks and DuckDB.

## Run locally

Requires Linux, Go 1.26+ and a C/C++ toolchain for the DuckDB CGO driver. The pinned
`duckdb-go/v2 v2.20000.0` dependency embeds DuckDB 2.0.0. From this directory:

```sh
go test -race ./...
go build -o nrc-incidents .
./nrc-incidents -server wss://nrc.example.net -workspace operations \
  -nickname nrc-incidents -history /private/data/history.duckdb
```

The real-server snapshot regression is opt-in. Build the matching NRC server
first, then run from this directory:

```sh
NRC_HISTORY_TEST_SERVER=/absolute/path/to/server NRC_HISTORY_LOAD_TEST=1 \
  go test -run '^TestHistorySnapshotOutboxIntegration$' -count=1 -timeout=12m -v
```

It uses isolated temporary databases and authenticated WebSockets. The load flag
enables two 90-second cases at 25 accepted runs/second, including concurrent
delivery of a 17-instance hot monitor, plus a 65-second normal-operation case
with 93 monitors, all three worker loops and discovery. Without the flag,
backlog, lost-ACK and disabled-monitor controls still run. Without the server
path, this test skips.

Provide `NRC_BOT_SECRET` through the process environment, not a command-line flag.
The evaluator name must match each Monitor's preview. By default, the sidecar
discovers assigned monitors at startup and 30 seconds after each discovery pass,
including disabled monitors for webhook draining and availability history.
Checks, outgoing webhooks and history-read authorization share the discovered set.
Checks, history, outgoing webhooks and discovery also share a limit of seven
in-flight NRC requests per process, independent of `-workers`. Waiting for a slot
counts against the request timeout and can be canceled. External checks and
DuckDB commits do not hold slots. This keeps the worker loops from exhausting
NRC's DB admission budget; server rejections remain errors, not silent retries.
The scheduler checks the set once per second; draining canceled work may delay
reconciliation. Unchanged monitor loops keep running.
Removed monitors are canceled and drained before replacement loops start.
An incomplete or failed pass retains the last complete set, initially empty.
Listing is live: concurrent edits may require the next pass to converge.
Each pass is bounded to 30 seconds, 128 pages, 16 MiB and 1024 assigned monitors;
exceeding a bound rejects the pass rather than publishing a partial set.
For a fixed deployment allowlist, pass `-monitors 123,456` (at most 1024 IDs).
These limits bound scheduler state, not retained instance history. Rules remain
in NRC; no SQLite file is opened by the sidecar.
Use one evaluator process per configured monitor set. The local data-file lock
only prevents accidental reuse of that path; it is not distributed leader election.

## Rule payload

The Monitor preview uses the server's version-1 policy, including nanosecond
interval/timeout fields and failure/recovery/missing thresholds. Its uncompressed
JSON payload describes the check:

```json
{
  "kind": "http",
  "url": "https://service.example.net/health",
  "conditions": [
    {"field": "status", "op": "==", "value": 200},
    {"field": "json", "path": "/healthy", "op": "==", "value": true},
    {"field": "latency_ns", "op": "<", "value": 2000000000}
  ]
}
```

All conditions must pass. There is no implicit 2xx condition. Numeric fields
support `==`, `!=`, `<`, `<=`, `>` and `>=`; strings/booleans support equality and
inequality only. Missing JSON fields and type mismatches fail even for `!=`.
Numbers are compared as exact decimals, without float64 rounding. Compared
numeric tokens are limited to 128 characters and explicit exponents to -308..308
to bound conversion work. Out-of-range rule values invalidate the rule;
out-of-range response values fail the condition, including `!=`.
JSON paths use JSON Pointer; `certificate_remaining_ns` compares the remaining
lifetime of the peer's leaf certificate. Redirects require `follow_redirects: true`;
disabling certificate verification requires `insecure_tls: true`. HTTP GET bodies
are limited to 1 MiB after decompression. Checks require access to their configured
targets, including private networks; configure trusted rules and network egress.

A TCP payload is `{"kind":"tcp","address":"service.example.net:443"}`. It tests
connection establishment, not TLS or application-level responses. HTTP and TCP
each produce one stable `{"target":"default"}` instance, with value 1 for pass
and 0 for failure. Network failures/timeouts are failures, not missing results.
Invalid configuration causes no submission. Rules are not edited by this process.

## Shared Victoria sources and multi-instance rules

Sources are shared `MonitorSource` assets (type 17), stored by NRC in SQLite.
Use the dedicated CLI commands; no browser editor is involved:

```sh
nrc monitor source create logs-short --kind victorialogs --url http://logs-short:9428 --retention 7d
nrc monitor source create logs-longterm --kind victorialogs --url http://logs-longterm:9428 --retention 90d
nrc monitor source list --human
nrc monitor source get 123
```

See the [CLI guide](../../../cli/README.md#victoria-monitors-and-sources) for
query creation, partial updates, dry runs and explicit source revision refresh.

Source configuration is the preview; payload is empty. Names need not be unique;
references use numeric asset IDs. `retention` is descriptive only, not a query
window, completeness guarantee or remote retention setting. `base_url` is the
Victoria service root; for a Metrics cluster include `/select/<tenant>/prometheus`.
The adapter appends `/api/v1/query` for Metrics or `/select/logsql/stats_query` for
Logs. Separate tenants can be represented by separate sources behind a proxy;
tenant-specific Logs headers are not supported yet.

Authentication is optional: omit `secret_ref` for Tailscale ACL-controlled access.
With `"secret_ref":"LOGS_READ"`, the sidecar requires the environment secret
`NRC_MONITOR_SECRET_LOGS_READ` and sends it as a Bearer token. Missing secrets fail
the evaluation before any query; there is no anonymous fallback. Secret references
use uppercase letters, digits and underscores, at most 64 characters. Raw secrets
must never be stored in assets. TLS verification remains on unless the source
explicitly sets `insecure_tls`. Redirects are refused, including when authenticated.

A Monitor references the source ID and its current `updated_at` as decimal strings:

```json
{
  "kind": "victoriametrics",
  "source_id": "123",
  "source_revision": "1794772800000000000",
  "query": "100 * node_filesystem_avail_bytes{fstype!~\"tmpfs|overlay\"} / node_filesystem_size_bytes{fstype!~\"tmpfs|overlay\"}",
  "identity_labels": ["instance", "mountpoint"],
  "trigger": {"op":"<", "value":10},
  "recovery": {"op":">", "value":15}
}
```

For Logs, use `kind: victorialogs` with a Logs source and a LogsQL stats query
containing its own explicit time window. The adapter does not add another window.
Both APIs must return a complete instant vector. Queries must include healthy rows
too: putting the alert comparison into the query would turn healthy targets into
missing rows. Use query grouping/filters to select the intended hosts and devices.

Selected identity labels must exist on every row. Only those labels, sorted into
canonical JSON, identify an instance within its Monitor; other labels and response
order do not affect identity. Duplicate identities fail the entire evaluation.
Changing identity labels can create new instances; old instances follow normal
missing-data handling and are not automatically retired.

Trigger comparisons produce failing observations. An optional opposite recovery
threshold produces passing observations; the gap, including uncovered boundaries,
produces `Between`. Without a recovery threshold, not triggering means passing.
Overlapping thresholds are rejected. NRC owns the consecutive failure/recovery
counts. Comparisons use exact decimals, but the protocol and DuckDB measurement
value remain float64 and can round large numbers.

An empty successful vector is complete and means missing instances, never zero or
recovery. HTTP/query errors, warnings, partial responses, malformed rows, NaN/Inf,
missing labels, result-limit violations and stale response timestamps send one
failed run with no rows. A valid prefix is never applied. Bounds: 4 MiB response,
1024 rows, 4096 bytes per identity and the 128 KiB protocol frame. Instant sample
timestamps must match the requested evaluation second within one second; they do
not prove the underlying scraped data is fresh. Express scrape freshness in the
query where needed. Metrics requests deny partial responses; Logs requests disable
them. Logs queries containing `allow_partial_response` are conservatively rejected
because query options override request parameters, even if the text is quoted.

Edit a Victoria source with `nrc monitor source update <id> --url <url>`. Any source
edit changes its revision and stops admission of runs pinned to the old revision,
including in-flight runs. Update affected Monitor payloads to the new revision
explicitly; this also resets their qualification streaks through the existing
Monitor revision fence. No automatic source failover or reference rewrite occurs.
Deleting a source makes referencing monitors unavailable until repaired. Monitors
and sources must be in the same workspace.

## Outgoing webhook routes

Routes reuse endpoint assets (`MonitorSource`, kind `webhook`). Each asset ID is
one immutable route version: neither ordinary asset commands nor transactions
can update or delete it, or convert a Victoria source into a route. Create a new
route to change the destination; existing queued events keep the old ID.

```sh
nrc monitor source create ops-v1 --kind webhook --url https://receiver.example.net/nrc
nrc monitor source get 789
nrc monitor update 456 --webhooks 789
```

Use the returned ID instead of `789`. `--secret-ref OPS` optionally resolves
`NRC_MONITOR_SECRET_OPS` as a Bearer token in the sidecar; no authentication is
required for ACL-protected receivers. Missing credentials stop the lane before
claiming a delivery. URLs follow the source URL contract (no userinfo, query or
fragment); no redirects are followed. TLS verification is enabled by default.
The CLI checks route existence and kind when setting `--webhooks`. The low-level
protocol still accepts opaque references; this dispatcher resolves only canonical
decimal route asset IDs. Legacy development references such as `ops-v1` remain
unresolvable and are not silently redirected to a new endpoint.

For every configured monitor, including disabled monitors, the dispatcher scans
the persisted lane directory. This finds removed route versions and dead lanes,
not just the monitor's current `webhooks` list. It attempts one head per lane per
pass, then polls again after five seconds. Dispatch has its own worker budget,
equal to `--workers`, so slow receivers do not occupy check workers.

POST bodies use version 1, with `kind`, `workspace`, `monitor_id`, `route` and
`delivery_id`. `incident_transition` includes the stored event snapshot under
`event`. `webhook_resync` includes `sync_version` and `incident_ids`: replace the
receiver's entire open-Incident set for that workspace/monitor/route, including
an explicitly empty `[]`. Normal transitions have `incident_ids: null`.
This is NRC's JSON contract, not a Slack/Teams payload adapter.

All resync pages are staged before sending. Invalidated snapshots are discarded
and their obsolete token acknowledged without HTTP delivery. Staging is bounded
to 65,536 IDs and must fit the lease time budget; it never publishes a partial
set. Exceeding either bound leaves the delivery unacknowledged. Repeated lease
expiry can make it dead, requiring operator intervention. No evaluation is blocked.

Each request has `Content-Type: application/json` and an `Idempotency-Key` equal
to SHA-256 of workspace, a NUL byte and delivery ID. Receivers must deduplicate
that key: a crash or lost settlement response can cause redelivery. A 2xx response
is acknowledged in NRC; network errors, 408, 429 and 5xx request the server's
bounded retry schedule. Other statuses, including redirects, mark the head dead.
Dead heads block their lane and are logged; they are never automatically discarded.
Workspace members can inspect lanes with `nrc monitor webhook list/get` and
discard one dead event with `nrc monitor webhook discard <monitor> <route>
--event <id> --generation <generation> --confirm`. The exact ID/generation fences
the action. Discard requests state resynchronization; it never resolves incidents.
Leasing and settlement other than explicit discard remain evaluator-only.

HTTP requests have a ten-second timeout. A delivery attempt has a 45-second total
budget, capped five seconds before the server's lease expiry; HTTP starts only
with at least twenty seconds left for sending and settlement. Keep clocks synced.
Settlement is sent once; an unknown result is not guessed or acknowledged locally.
Logs contain monitor/route IDs, not URLs, tokens or response bodies.

## Ordering, history and failures

Each cycle reads NRC's current Monitor revision and accepted sequence, then the
asset at that revision. NRC remains authoritative for thresholds and incidents.
Runs are sent once; a lost response is `unknown`, not `rejected`. The next cycle
reads the accepted sequence again, including after restart. Each request uses a
fresh authenticated WebSocket connection; persistent multiplexing is not implemented.
An older write may still be pending when that read occurs. If NRC then returns a
replay ACK for the fresh measurement, this attempt is recorded as `rejected`
(sequence collision), never `confirmed`. The older attempt stays `unknown`;
it is not rewritten from this reply. The next scheduled cycle reads state again
and takes a new measurement, without an immediate retry loop.

The default eight workers bound concurrent cycles. A monitor never overlaps
itself; missed intervals do not cause catch-up bursts, and cycles wait at least
one second before retrying. Shutdown cancellation is not submitted as a target failure.

After submission, measurements enter a disposable 256-run RAM buffer for the
DuckDB writer. A full buffer or failed DuckDB write loses history and logs a gap;
it never rejects an NRC evaluation. Shutdown can discard buffered history and
reports the remaining count. This applies to raw runs, samples and diagnostics;
availability snapshots have a separate durable NRC outbox described below.

The writer drains up to 32 already queued runs or eight completed snapshots into
one transaction, without waiting for more work. Retention metadata is read once
per batch and each affected hour is marked once. A failed batch rolls back and
its records are retried individually, so one rejected record does not discard
valid neighbours. Loss counters count failed records, not failed batch attempts.
Batching does not change observation times, sequence fences or gap accounting.

DuckDB stores each run's random attempt ID, workspace, Monitor revision/sequence,
observation time, duration, acceptance (`confirmed`, `rejected`, `unknown`) and
per-instance measurements. Queries must choose which acceptance states to include;
`unknown` does not imply NRC rejected the run. Run IDs deduplicate local retries;
samples have no index. No target URL, headers or full response bodies are stored.
HTTP diagnostics retain the scalar values selected by configured conditions;
choose fields safe for every workspace reader to see. Even a selected scalar can
contain sensitive data. Objects and arrays are never copied into diagnostics.
The writer uses DuckDB's default thread count and a 256 MiB memory limit. Files
created by the process use private permissions. Existing files must already be protected.

## Retention and aggregation

The writer runs maintenance at startup and once a minute, including while idle:

| Data | Retention |
| --- | --- |
| Raw runs and per-instance observations | 14 days |
| 5-minute UTC buckets | 90 days |
| Hourly UTC buckets | 13 calendar months |

Sample buckets store count, minimum, maximum, sum, last value/time and counts of
passing, failing and hysteresis-band observations. Run buckets retain run counts,
query failure counts and execution-duration sums/maxima, including empty results.
Workspace, monitor, revision, acceptance and instance identity remain separate.
Hourly aggregates sum counts and sums from the 5-minute stage; averages must use
sum/count, never an average of bucket averages. Equal last-value timestamps use
the attempt ID as a deterministic tie-breaker. There are no additional read indexes.

Each maintenance transaction recomputes one dirty raw-data hour and one dirty
availability hour. It then removes at most one expired raw hour and one expired
bucket timestamp per table/resolution. Each job has a five-second deadline. A
failed job rolls back aggregation, progress and deletion together and retries on
the next tick. Large backlogs or repeated failures therefore extend retention;
these are age targets, not a hard byte quota or a guaranteed cleanup deadline.
The boundary hour remains until wholly expired; 5-minute data retains its boundary
bucket. Calendar-month subtraction clamps month-end dates rather than using 390 days.

New observations mark their hour dirty in the same transaction as the raw insert.
Late observations within the retained raw window replace affected aggregates.
Once maintenance advances the persisted raw cutoff, older new entries are refused
and logged as history gaps, even after restart. They never recreate an expired
bucket from only part of its source data. Existing raw-only files are adopted once
on open. Back up sidecar files before upgrading; this does not migrate NRC SQLite.

Deleting rows makes space eligible for DuckDB reuse after checkpointing; it does
not promise an immediately smaller file. DuckDB retention does not delete
unacknowledged NRC availability snapshots.

## Observed uptime and coverage

Availability uses NRC's observed instance states, not Incident lifetime or the
fraction of successful checks. The schema-8 server captures complete immutable
pages in the same SQLite transaction as each accepted run. A capture failure
rejects the transaction instead of acknowledging a run without its snapshot.
Each snapshot includes non-retired instances, including paused ones. Sixteen
rows per page fit the protocol limit even with maximum-length identities.

Independent collectors use `C_MonitorHistory` (75) to read the oldest pending
snapshot and acknowledge its exact monitor/snapshot-ID/capture-time identity only
after the DuckDB transaction commits. Continuations read stored evidence, not
live rows; new runs, changed revisions and backward clock steps cannot invalidate
them. Disabled monitors capture bounded pause evidence on demand when the outbox
is empty. The existing live monitor-state API remains unchanged.

Each read has a ten-second budget and stages at most 4 MiB. The 1,024-instance
admission limit applies to active instances; snapshots also include paused ones.
The eight-slot completed-snapshot queue and collector count bound RAM use; the
writer batches up to eight snapshots. Read, write and acknowledgment failures
leave evidence pending for retry, including after restart. A lost acknowledgment
can replay an already committed snapshot; sink writes deduplicate it. Original
observation times and expiry deadlines never advance during retry.

Capture IDs come from a durable server sequence, not the wall clock. Equal
timestamps remain distinct captures; conflicting reuse of an ID fails instead
of acknowledging different evidence as a replay. On open, the sidecar atomically
adopts the old timestamp-keyed availability tables, preserving their rows under
legacy ID zero. Back up the DuckDB file before upgrading; this changes its schema.

Unacknowledged snapshots have no automatic TTL or overflow discard. An unavailable
sink therefore grows NRC's SQLite outbox on disk; exhausting storage can reject
new evaluations atomically. Operate disk capacity accordingly. Snapshots older
than DuckDB's retained raw window need operator attention rather than silent
acknowledgment. Raw run/sample/diagnostic buffering remains best-effort. Upgrade
server and sidecar together after the explicit
[schema migration](../../../docs/DEVELOPMENT.md#sqlite-schema-8).

Each instance contributes healthy, failing, unknown or paused nanoseconds to UTC
buckets. Passing/failing observations contribute directly; 5/5 qualification only
controls Incidents. Hysteresis-band values, missing results and evaluation errors
are unknown. A state is valid from snapshot time until the next snapshot or its
staleness deadline, whichever comes first. Pauses and disabled monitors are
excluded while confirmed; an unrefreshed pause also becomes unknown after its
evidence expires. Retirement ends the instance's expected time at the next complete
snapshot. A reappearing instance starts contributing again when observed.

- **Uptime:** healthy / (healthy + failing).
- **Coverage:** (healthy + failing) / (healthy + failing + unknown).
- Zero denominators produce SQL NULL, not 100%. Paused time is in neither denominator.

`uptime_summary` exposes both ratios as fractions, alongside their durations and
dimensions. Filter a single resolution; when combining buckets, instances or
revisions, sum the durations first and recalculate the ratios. Never average the
ratios. The 5-minute and hourly tiers use the same 90-day/13-month retention.

Raw availability snapshots follow the 14-day window, plus one predecessor snapshot
per monitor at the cleanup boundary. This anchor lets a long outage remain unknown
after raw cleanup instead of disappearing from coverage. Maintenance advances time
even without new observations, scheduling at most 24 additional hours and computing
one hour per transaction after downtime. Late snapshots repair affected retained
hours; data needed by unfinished aggregation is not deleted.

These are **sampled observations**, not an exact transition audit. Pauses or outages
entirely between snapshots may be missed; a change takes effect in history when
observed, not retroactively at an inferred action time. No uptime is fabricated for
older raw-only history or for time before an instance was first observed. The
web Inspector displays uptime together with coverage, scoped to the current revision.

## History read API

The listener is off by default. Enable it with `-history-listen 127.0.0.1:8095`
and a separate `NRC_HISTORY_SECRET` environment value of at least 32 characters.
Use a randomly generated token. Requests require `Authorization: Bearer <token>`.
Bind to loopback or a private network protected by ACLs; use TLS at the reverse
proxy outside a trusted encrypted network. The listener itself speaks plain HTTP.
Do not put this service token in browser code. It grants history access to the
deployment's workspace and current discovered or explicitly configured monitor
IDs, not individual NRC user rights. Removed IDs return 404 after discovery;
their stored history still follows retention and is not deleted by discovery.
The Tailscale proxy's `/monitoring/history/` gateway checks user workspace access
and supplies this token server-side; see its [configuration](../../auth/tailscale-proxy/README.md#monitoring-history).
No CORS is enabled on the sidecar.

Endpoints:

| GET path | Resolutions | Rows |
| --- | --- | --- |
| `/v1/history/<monitor-id>/samples` | `raw`, `5m`, `1h` | Measurements or per-instance buckets |
| `/v1/history/<monitor-id>/runs` | `raw`, `5m`, `1h` | Attempts, including failed/empty runs, or execution statistics |
| `/v1/history/<monitor-id>/uptime` | `5m`, `1h` | Healthy/failing/unknown/paused durations, uptime and coverage |
| `/v1/history/batch/uptime` | `5m`, `1h` | Uptime results for up to 16 monitor IDs in one read transaction |
| `/v1/history/<monitor-id>/inspector` | `raw` | Runs, identity-filtered samples and 24-hour uptime in one read transaction |

The Inspector endpoint requires `identity`, `acceptance=all`, and a raw `from`/`to`
window of at most one hour. It returns `kind: "inspector"`, the requested identity,
and `sections.runs`, `sections.samples`, `sections.uptime`. Each section contains
`status`, `rows`, `from`, `to`, and `pending_rollup_hours_global`. Runs are
monitor-wide; samples and uptime match the selected identity. Uptime covers the
24 hours ending at `to` rounded down to five minutes. Raw retention or the
5,000-row/section-byte limit produces section status 422 with no rows; other
sections remain available. The complete envelope is limited to 4 MiB (HTTP 422
if exceeded), one reader slot and one three-second deadline. Metadata and all
sections use the same database snapshot. Existing individual endpoints remain
available for narrower CLI reads.

The web Inspector uses two optional compact views. `view=checks` requires
canonical decimal `revision` (positive int64) and `sequence` (uint64, including
zero). It returns the latest 20 identity-matching samples in ascending time order,
their run diagnostics, the current confirmed evaluation if present in the raw
window, and the latest monitor-wide attempt as fallback. `view=chart` retains all
identity-matching samples and returns an empty runs section. Both views sum uptime
durations by revision before returning them; revisions are never combined.
Without `view`, the endpoint retains its full, bounded history response.

The uptime batch requires `ids=12,34,...`: one to 16 distinct, canonical positive
uint64 IDs. It rejects `identity` and `acceptance`. Its envelope has
`monitor_id: "batch"`, `monitor_ids` in request order, and `results` in the same
order. Each result contains `monitor_id`, `status` and `rows`: status 200 for a
complete result (including empty history), 404 for a monitor outside discovery,
or 422 if that monitor exceeds the row/byte limit. The batch shares one reader
slot, one transaction and the existing three-second deadline. The full response
is bounded to 4 MiB; HTTP 422 at the envelope level means callers should split
the batch. No partial response is published.

The web register requests history in batches of up to 16. It retains matching
workspace/revision/period/window results for five minutes; adding a page reads
only uncached monitors. Manual refresh renews history immediately and keeps old
results labelled while loading or after a failed update. Status polling runs
every 30 seconds while the connected status view is visible. It reloads the
server-ranked pages to the previously loaded depth before replacing the list;
this does not freeze server state between page reads. History never determines
status order. Deploy the sidecar and gateway batch support before the new client.

Every query requires `from`, `to` (RFC3339 timestamps with optional nanoseconds)
and `resolution`. The interval includes `from` and excludes `to`, spans at most
400 days, and uses nonnegative signed-64-bit Unix nanoseconds. Aggregate endpoints
require both boundaries aligned to their UTC bucket size; they never return a
whole bucket as though it described a shorter interval. No automatic tier mixing
or fallback occurs. Raw ranges before the persisted raw cutoff return HTTP 422.

Samples and runs also require `acceptance=confirmed|rejected|unknown|all`.
`all` keeps the states in separate rows; it does not reinterpret unknown attempts
as rejected. Samples and uptime accept an exact, URL-encoded `identity` filter.
Without it, they return all matching instances. Other parameters and duplicate
parameters are errors, including workspace overrides and filters that do not apply
to the endpoint.

For example, the following request reads one hour of confirmed sample buckets:

```text
GET /v1/history/123/samples?from=2026-11-16T00:00:00Z&to=2026-11-16T01:00:00Z&resolution=5m&acceptance=confirmed
Authorization: Bearer <service token>
```

Responses contain `version: 1`, workspace, monitor ID, query range/resolution and
a `rows` array. All integer data fields, including IDs, revisions, nanoseconds,
counts and HUGEINT duration sums, are decimal strings. Measurements and ratios
are JSON numbers; unavailable ratios are `null`. `condition` is `"0"` passing,
`"1"` failing or `"2"` between. Raw rows sort by observation time, attempt ID and
identity; buckets sort by time, revision, acceptance where present, then identity.
Revisions and instances are never combined implicitly. Use sums/counts for numeric
averages and summed durations for combined uptime; do not average bucket ratios.

Raw `runs` also include `diagnostics` for HTTP/TCP checks (null for older runs
and Victoria queries). Version 1 contains `conditions`, in configured order, with
zero-based `index`, `state` (`pass`, `fail`, `unavailable`), an optional fixed
`reason`, and typed scalar `actual` text. Decimal text retains its precision.
Numeric rules also carry `expected_number` as exact decimal text, so browsers
need not reconstruct thresholds through JavaScript floating-point numbers.
Diagnostic `version` and `index` are small JSON integers, unlike the decimal-string
IDs, sequences and nanosecond fields on their enclosing run.
Values longer than 256 Unicode characters are shortened and marked `truncated`;
comparison always uses the original value. Missing fields, invalid JSON and
unavailable certificates are explicit, and evaluation continues after a failed
condition. Request/body failures use a fixed top-level `error` and unavailable
condition rows; raw transport errors are not retained. TCP has no condition rows.

Diagnostics are historical observations, not authoritative current state. Join
condition indices to definitions only when the run revision matches that definition.
Display the attempt's acceptance and sequence; a matching confirmed run can describe
the current evaluation only when its revision and sequence match NRC's status.
Older, missing and unconfirmed diagnostics must stay distinguishable. Diagnostics
share the raw 14-day retention and atomic run write/delete, with no rollup.

Database metadata and rows come from one DuckDB transaction. Responses also report:

- `raw_floor_ns`: persisted cutoff for newly accepted raw history.
- `pending_rollup_hours_global`: dirty hours intersecting this range for the
  selected data family, across the whole DuckDB file, not just this monitor.
- `uptime_last_maintenance_ns`: latest persisted availability-maintenance time
  (monotonic maximum of its supplied wall-clock times; zero before its first
  active pass). This is neither a scheduling nor a completed-data watermark.
  After downtime, recent hours may not even be scheduled yet.
- `dropped_process_total`: history drops recorded by this process since startup,
  not a durable or per-range loss count.
- `availability_process` (also on batch responses): decimal-string counters
  `request_drops_total`, `snapshot_read_failures_total`,
  `snapshot_write_failures_total`, `backpressure_total` and
  `backpressure_ns_total`, plus current queue depths `requests_pending` and
  `snapshots_pending`. Backpressure counts waits, not losses; elapsed wait time
  is added when a queue wait ends. These process-local
  readings are independent of the database transaction and are not an atomic
  snapshot or completeness watermark. Pending depths exclude active collectors
  and the writer. The legacy `request_drops_total` and `requests_pending` keys
  are zero because no disposable availability-request queue remains. Read/write
  failures count retryable attempts, not lost snapshots. They do not measure
  the durable server backlog. Logs identify the affected monitor without source
  response bodies.

Rollups can lag writes or late corrections. Zero pending hours does not prove
complete history: collection gaps, retention, unscheduled availability catch-up
and missing snapshots still apply. Empty rows mean no retained matching data,
never zero values or 100% uptime. Reads do not synthesize missing buckets or
trigger aggregation.

At most two reads run concurrently, each with a three-second database deadline.
The shared pool permits a third connection for the serialized writer. Results
are buffered and limited to 5,000 rows and 4 MiB encoded JSON. HTTP 422 means
narrow the interval, select an identity or use a coarser resolution; there is no
truncation or pagination. HTTP 503 means busy, unavailable or a failed/timed-out
read. SQL errors and database paths are not exposed. Responses use `no-store`.
Checks and outgoing webhooks have no dependency on this API, although reads share
DuckDB's CPU and memory budget with history writes. Production-load latency has
not been measured.

## Current status reads (NRC protocol)

Authenticated workspace members can use `C_QueryMonitorStatus` (73), independent
of the evaluator-only availability snapshot endpoint. Monitor ID zero lists
monitors; a nonzero ID lists that monitor's instances. This reads NRC SQLite,
not DuckDB. No configuration payloads, source URLs or secrets are returned.

Instance pages include `config_revision`, the monitor asset's `updated_at` from
the same SQLite transaction as the rows. A row's `revision` identifies its
last evaluation and may be older. Monitor lists have no single configuration
revision and return an empty string.

The base request body is 31 bytes, big-endian: correlation ID u32, monitor ID
u64, cursor ID u64, cursor rank u8, page time i64 (Unix nanoseconds), limit u8,
include-retired u8 (0 or 1). Limit is 1–16. Start with cursor ID/rank/time zero;
continue with the previous page's cursor and time. Include-retired is only valid
for instance lists. Retired instances are otherwise omitted, not paused ones.

Monitor lists accept an optional suffix: state-filter u8 (0 all, 1 problems,
2 healthy, 3 paused), followed by up to 256 UTF-8 bytes of search text. Old
31-byte requests remain unfiltered. Search matches a literal name substring
(SQLite ASCII case-insensitive) or an exact numeric ID, optionally prefixed
with `#`. `%` and `_` are literal characters, not wildcards. Problems includes
firing, failing, error, no_data, unknown and between. Both filters apply across
the authorized workspace before pagination. Keep filters unchanged when
continuing a cursor; reset the cursor on changes.

The web monitor register sends these filters to NRC, debounces search by 250 ms,
and preserves them during polling and pagination. Its counters describe loaded
matches, not a server-wide total. Incident search remains client-side. Deploy
NRC server support before the updated client; older servers reject the suffix.

`S_MonitorStatusPage` (179) returns correlation ID u32 followed by version-1 JSON.
Go bindings are `EncodeQueryMonitorStatus` and `DecodeMonitorStatusPage` in
`protocol-go`. IDs, revisions and nanosecond timestamps are decimal strings;
an absent numeric measurement is null. Pages stop at 16 rows or approximately
120 KB, whichever comes first. `has_more` determines whether to continue.

Both lists sort by `firing`, `failing`, `error`, `no_data`, `unknown`, `between`,
`healthy`, `paused`, `retired`, then unsigned stable ID. Disabled monitors and
paused/retired instances override technical status. Open incidents otherwise
remain firing, including during missing data. Reads calculate staleness without
waiting for maintenance; a changed configuration is unknown until evaluated.
Monitor summaries include nine instance counts in that same status order and
the last run sequence/time. Failed runs remain visible even with no instances.
Instance rows include measurement/time, qualification counters and the latest
episode's incident ID, acknowledgment and assignment. `observation`, `freshness`
and instance `paused` are stored state; `status` also accounts for elapsed time
and disabled monitors. Summary `paused` describes its effective status.

Each page is transaction-consistent, but pagination is a live view, not a frozen
snapshot. The shared page time stabilizes elapsed-time classification only.
Concurrent writes can move rows across the cursor: refresh from page one for a
new view. Page time must be no more than five minutes old and cannot be in the
future. Output size is bounded; aggregation and sorting work still depends on
workspace size. Production-load latency has not been measured.

## Web client

MONITORING opens the status register and incident list in the existing workspace.
Monitor and instance pages retain the server's problem-first, stable-ID ordering.
The incident list reads its asset pages before sorting: unacknowledged firing,
acknowledged firing, then closed incidents, with stable IDs within each group.
REFRESH rereads NRC; the timestamp describes the displayed snapshot, not a live
stream. MORE continues the current cursor. Reopen or refresh an Inspector to read
new state. Configuration and lifecycle controls remain in the CLI.

The shared Inspector displays rule metadata, per-instance qualification counters
and incident links. Incident acknowledgment and assignment use revision-fenced
protocol actions and wait for a receipt. A timeout is not proof of failure;
refresh before retrying. Neither action changes the technical firing state.

Selecting an instance reads the last hour of runs/samples through the authenticated
history gateway in one Inspector request, including uptime, and displays the latest
20 samples. The client retains up to eight Inspector responses for five minutes,
keyed by workspace, monitor revision and identity. Every selection revalidates;
a retained response is displayed immediately as a previous result while waiting,
and remains explicitly marked if the refresh fails. Disconnect clears the cache.
Cached diagnostics are never labelled as matching the current evaluation. Deploy
the sidecar and gateway Inspector endpoint before this client. Diagnostics are labelled current
only when confirmed and matching the displayed configuration and instance revision
and sequence. Old definitions are not guessed. Uptime uses the current revision's
retained durations in the last complete 24-hour, five-minute-aligned window;
coverage uses that whole window minus recorded paused time. Missing buckets lower
coverage. Victoria checks call this condition satisfaction. History errors do not
erase NRC state; API range/size limits are shown explicitly rather than truncated.
