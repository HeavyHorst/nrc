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
Select a Prometheus data source. Use its `thread_id` and `wal_kind` filters to
inspect individual workers and persistence metrics.

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
worker memory and buffer pools, io_uring, WAL and compaction statistics.
Interpret these metrics carefully:

- `send_queue_*` and `send_backpressure` describe the bot connection, not all
  user connections on that worker.
- `nrc_thread_wal_*` contains aggregate WAL metrics.
  `nrc_thread_wal_kind_*` separates telemetry by `wal_kind=task|asset|edge`.
- `nrc_thread_shard_sweep_{input,dirty}_bytes_total` reports processed and
  reclaimed WAL bytes. Prefix, latest, measure, copy and replay read-byte counters
  report reads separately. Sum their rates and divide by the input-byte rate to
  calculate read amplification. Aggregate workers with `sum(...)`.
- `nrc_thread_shard_sweep_metadata_fallbacks_total` counts cases requiring the
  strict WAL fallback. `nrc_thread_shard_sweep_metadata_written_bytes_total`
  counts successfully published metadata bytes.
- Sweep counters reset when NRC restarts. Use rates rather than treating totals
  as permanent history.

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
