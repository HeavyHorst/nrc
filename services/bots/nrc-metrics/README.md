# nrc-metrics

Metrics reads NRC worker statistics through bot WebSocket connections and exports
them in Prometheus format. It does not subscribe to chat rooms or change work
records. Use it to monitor worker coverage, connections, queues, I/O and persistence.

## Start

First set up the [core deployment](../../../README.md#quickstart).
Use the same `NRC_BOT_SECRET` for the server and Metrics.
The example `.env` binds the exporter to host loopback. Keep that binding unless
you intend to allow remote access; the exporter has no HTTP authentication.

Run from the repository root:

```sh
docker compose --env-file .env -f docker/docker-compose.yml --profile metrics up -d --build
docker compose --env-file .env -f docker/docker-compose.yml logs metrics-bot
docker compose --env-file .env -f docker/docker-compose.yml exec metrics-bot curl -fsS http://localhost:8092/health
```

The supplied Compose configuration uses `thread-targeted` mode to cover all workers.
Read the health response's `status` and `missing_thread_ids`. HTTP 200 alone does
not mean coverage is complete.

## Use

Configure Prometheus to scrape the exporter's `GET /metrics` endpoint on port 8092.
The default host binding is reachable only on the Docker host. If Prometheus runs
elsewhere, configure an address it can reach and restrict access to that address.
Do not expose the endpoint to untrusted users.

Import [the supplied dashboard](grafana/nrc-metrics-dashboard.json) into Grafana.
Select a Prometheus data source, job and instance, then use the Worker filter
to inspect one or more workers. Scrape health, overall coverage and process RSS
remain instance-wide. Set the data source's scrape interval to match collection;
rate queries use Grafana's `$__rate_interval`.

The dashboard shows SQLite throughput, credit utilization, admission refusals,
latency histograms, group size and pager activity, followed by worker I/O and
collector diagnostics. Panel descriptions explain each measurement's limits.
Missing telemetry is not filled with zero; an idle histogram has no percentile.
The retired entity-WAL and compaction panels are no longer included.

`GET /health` reports connections and worker coverage. `status: "degraded"` means
no bot connection is up, an expected worker is missing, or the configured worker
count differs from the count reported by NRC. This response still uses HTTP 200.

## Worker coverage and metric meaning

Each bot connection sees the worker that owns its workspace. One connection
cannot observe every worker. There are two planning modes:

- **thread-targeted:** read the worker count from a bootstrap connection, then
  generate workspace IDs that reach the requested workers. Compose uses this mode.
- **static:** connect to the workspace IDs you supply. This is the standalone
  default; those IDs may not cover all workers.

Routing uses `xxhash(workspace_id) % 256` for the logical shard, then
`logical_shard % worker_count` for the worker. Generated IDs follow that mapping.
Metrics uses stats requests, not room subscriptions or room creation.

The exporter reports collector coverage, connection liveness, queue pressure,
worker memory and buffer pools, io_uring and SQLite executor statistics.
Interpret these metrics carefully:

- `send_queue_*` and `send_backpressure` describe the bot connection, not all
  user connections on that worker.
- `nrc_thread_wal_*`, `nrc_thread_wal_kind_*` and `nrc_thread_shard_sweep_*`
  are retired entity-WAL compatibility fields. SQLite builds return zero.
  They do not measure SQLite WAL files or retained chat-message storage.

## SQLite telemetry

Upgrade the server before this exporter: polling opts into stats extension v2
with a ninth request byte. Ordinary eight-byte stats requests retain their old
response format. `nrc_db_metrics_available{thread_id}` reports whether the latest
worker sample contains ordered telemetry. The server still supports v1 requests,
but this exporter needs v2 identity fields; v1 DB metrics are unavailable.
Missing data is not exported as zero.
Counters reset on server restart. All SQLite series use only `thread_id`; multiple
monitoring workspaces on one worker are deduplicated. Shared executor threads
charge each request/group to its submitting worker, so summing workers does not
multiply executor totals.

Each server start creates a random 128-bit process generation. Each worker numbers
its snapshots across all connections. The exporter rejects duplicate and older
sequences, regardless of response arrival order or counter values. A generation
change invalidates every worker's old DB sample; retired generations cannot return.
An unseen generation on a poll already outstanding at the last transition is
ignored until a newer poll confirms it. This can delay restart detection by a poll.
Poll tokens are local serials echoed by the server, not synchronized clocks.
Run one exporter against one NRC process, not a load-balanced pool. Generation
and sequence are internal freshness metadata, not Prometheus labels.

If the connection supplying a worker's newest sample disconnects, older DB
samples from other connections are suppressed until a new poll arrives.
`nrc_db_metrics_available` is zero during that gap; counters and histograms are
absent. A new process can restart its sequence and counters at lower values.

The dashboard labels executor throughput as reader/writer **jobs/s**, not reads
or writes to disk. Writer jobs include background maintenance, polling and jobs
that change no data. Completed jobs include failures. The separate **SQLite page
activity** panel counts pages; its page writes are not physical IOPS or fsyncs.

| Series | Meaning |
| --- | --- |
| `nrc_db_in_flight`, `charged_bytes`, `capacity`, `byte_budget` | Credits held by admitted jobs, including completed results not yet released, and their limits. Each name has the `nrc_db_` prefix. |
| `nrc_db_writer_in_flight`, `writer_bytes`, `read_reserved_requests`, `read_reserved_bytes` | Writer credit usage and reserved reader capacity; same prefix convention. |
| `nrc_db_admitted_{write,read}_total`, `nrc_db_completed_{write,read}_total` | Admission and first completion publication; streamed chunks do not count as new jobs. |
| `nrc_db_rejected_{connection,worker,unavailable}_total` | Connection fairness/limit, worker capacity/bytes, and unavailable/invalid executor submission. Only the first two are retryable overload. |
| `nrc_db_errors_total`, `nrc_db_busy_total` | Non-OK job results at first publication, with SQLite BUSY as a subset. A failed group counts its failed jobs, not one error per transaction. Later streaming delivery failures are not counted. |
| `nrc_db_group_transactions_total`, `nrc_db_group_jobs_total` | Attempted groups and jobs in those groups, including failures. Their rate ratio is mean group size, not fsync savings. |
| `nrc_db_cache_{hits,misses,writes}_total` | SQLite pager counters, sampled/reset on the owning executor after each job/group. Includes first-request connection initialization. These are page operations, not disk bytes or OS cache misses. |
| `nrc_db_{writer,reader}_queue_seconds` | Admission until execution starts, including FIFO dependencies, lazy open and group collection. |
| `nrc_db_{writer,reader}_execution_seconds` | BEGIN/savepoint and handler/output preparation, before commit/release. The outer group BEGIN belongs to its first job, including failed BEGIN attempts. |
| `nrc_db_{writer,reader}_publication_seconds` | Admission until first completion publication, including group commit. Not WebSocket ACK latency or full streamed delivery. |
| `nrc_db_projection_finalize_seconds`, `nrc_db_commit_seconds` | Projection finalization and SQL COMMIT attempts, once per writer transaction, not once per grouped job. |

The seconds series are Prometheus histograms with boundaries from 50 µs to 1 s
and an overflow bucket. Samples are captured for every operation, not just when
the exporter polls. Snapshots use atomic counters but are not transactionally
consistent across fields. Queue/execution samples require reaching execution;
failed lazy opens still increment completion/error counters. Rollback/cleanup
time is included in publication, not execution.

Example writer p99:

```promql
histogram_quantile(0.99, sum by (le) (rate(nrc_db_writer_publication_seconds_bucket[5m])))
```

Compare queue, execution, finalization and commit histograms separately; their
percentiles cannot be added. For mean group size:

```promql
sum(rate(nrc_db_group_jobs_total[5m])) / sum(rate(nrc_db_group_transactions_total[5m]))
```

COMMIT time includes any synchronous auto-checkpoint SQLite runs inside COMMIT.
This instrumentation does not replace SQLite's WAL hook or run extra checkpoints.
Separate checkpoint duration/backlog, fsync latency, prepare time, per-query
statistics and client retry exhaustion are not yet measured. Retained chat has
its own storage path and is not covered by `nrc_db_*`. The dashboard lists these
gaps in its measurement-boundaries panel rather than substituting unrelated data.

## Configuration

These are standalone defaults. Compose sets service addresses, the nickname and
`thread-targeted` mode. Set host binding and port with `NRC_METRICS_BIND_ADDRESS`
and `NRC_METRICS_HOST_PORT` in `.env`; the example binds `127.0.0.1:8092`.

| Variable | Default | Meaning |
| --- | --- | --- |
| `NRC_SERVER` | `ws://localhost:8080` | NRC WebSocket endpoint |
| `NRC_BOT_SECRET` | None | Must match the server's bot secret |
| `NRC_NICKNAME` | `metrics-{hostname}` | Bot nickname |
| `NRC_METRICS_WORKSPACE_MODE` | `static` | `static` or `thread-targeted` |
| `NRC_METRICS_WORKSPACE_PREFIX` | `metrics-thread` | Generated workspace ID prefix |
| `NRC_METRICS_TARGET_THREADS` | `all` | Number of workers to target |
| `NRC_METRICS_EXPECT_THREADS` | `all` | Expected worker count; a mismatch degrades health |
| `NRC_METRICS_BOOTSTRAP_WORKSPACE` | `metrics-bootstrap` | Workspace for count discovery |
| `NRC_METRICS_BOOTSTRAP_TIMEOUT` | `20s` | Count-discovery timeout |
| `NRC_WORKSPACES` | None | Required comma-separated workspace IDs in static mode |
| `NRC_WORKSPACE` | None | Static-mode fallback if `NRC_WORKSPACES` is unset |
| `METRICS_PORT` | `8092` | Internal HTTP port |
| `PING_INTERVAL` | `5s` | Stats request interval per connection |
| `READ_TIMEOUT` | `60s` | Read timeout, raised to at least three request intervals |

## Development

Requires Go 1.26 or newer. No native libraries are required.
Run from this directory:

```sh
CGO_ENABLED=0 go build -o nrc-metrics .
go test ./...
```

For a local run, first set `NRC_SERVER` to a running test server and export its
`NRC_BOT_SECRET`. Do not use production credentials in a disposable test.

```sh
NRC_METRICS_WORKSPACE_MODE=thread-targeted go run .
```
