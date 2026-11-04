# Subscribed active-user simulation

`active-user-sim` keeps real authenticated WebSocket sessions open while users
read and edit workspace records and send retained chat messages. It checks
responses, live fanout and final server state. It does not measure browser
rendering, file upload services or production gateway authentication.

## Build and run

Run from the repository root with Go and Odin on PATH:

```sh
# Keep generated binaries and results local to this checkout.
exclude=$(git rev-parse --git-path info/exclude)
grep -Fxq '/.amp/in/' "$exclude" || printf '\n/.amp/in/\n' >> "$exclude"
mkdir -p .amp/in/artifacts
odin build . -o:speed -out:.amp/in/active-server
go -C benchmark build -o ../.amp/in/active-user-sim ./cmd/active-user-sim

# Default: 20,000 users, 200 workspaces, two server workers, two generators.
# Two-minute connection ramp, then ten minutes of measured activity.
python3 benchmark/run_active_users.py

# Escalate only after the previous level passes every verdict.
python3 benchmark/run_active_users.py --levels=20000,40000,60000,80000,100000
```

The harness creates a new disposable sharded installation and random JWT and bot
secrets for every run. It never opens the repository's `data/`. It starts and
stops only its own processes, preserves the disposable data and reports under
the output directory, and refuses an existing output directory. No secrets are
written into the reports. Use `--output` to choose a new run directory.

`--fixture-prefix` defaults to `active-benchmark`, independently of the output
directory. Keep this prefix, seed, workspace count and worker count unchanged
across paired runs so workspace names and shard placement remain identical.
Reusing the prefix is safe here because each run creates a separate installation.
SIGINT and SIGTERM stop and reap the child processes, including when repeated
during cleanup. SIGKILL and a coordinator crash cannot run this cleanup.

The server uses its normal wildcard listener on a free port; clients connect
over loopback. The random credentials are known only to the child processes.
Use `--port=18080` to choose a particular free port. No production service is
restarted or reconfigured.

For a quick correctness check, not a capacity result:

```sh
python3 benchmark/run_active_users.py --users=16 --workspaces=4 --ramp=1 --duration=8 \
  --sim-arg=--read-interval=1s --sim-arg=--mutation-interval=1s \
  --sim-arg=--chat-interval=1s --sim-arg=--ping-interval=1s
```

## Workload and subscriptions

Every user subscribes to workspace-data scope `0` and one chat room. Workspace
subscription readiness uses a ping/pong barrier; chat uses V2 subscription
negotiation. A dedicated reader dispatches all frames, including broadcasts
that arrive while a request is pending. Retention must be enabled: the harness
sets `NRC_MESSAGE_RETENTION=24h` and startup sends and retries a retained message.
Retention-disabled servers do not silently fall back to ephemeral chat.

Each workspace starts with up to eight tasks, one note, one slice and task/note
`MemberOf` edges to the slice. Records remain bounded during measured activity.
Users change shared records, including task status; they do not create a new
record for every operation. Incoming task, asset and edge changes update each
user's cache. The record IDs come from acknowledged creation and the initial
broadcast drain completes before measured actions start.

| Action | Mean per-user interval | Mix |
| --- | --- | --- |
| Read | 30 seconds | 75% task, 25% note |
| Mutation | 120 seconds | Two thirds task edit/status change, one third note edit |
| Retained chat | 120 seconds | 1% also retry the same message identity |
| Application ping | 30 seconds | Request/response latency probe |

Initial phases are randomized; later intervals range from 0.5 to 1.5 times the
configured mean. Schedules advance from intended deadlines, not response times.
An overloaded generator therefore accumulates visible scheduling lag rather
than quietly reducing the requested rate. Actions scheduled before the end of
the measured interval finish before reconciliation. Transport-level WebSocket
pings every 20 seconds also keep users alive during the ramp and final audits;
these are counted separately and are not application-ping latency samples.

All users consume live events throughout the run, including between actions.
There are four chat rooms per workspace by default, reduced for small fixtures
to keep at least two users per room. At 20k/200 there are 100 users per workspace
and 25 per room; at 100k/200 there are 500 and 125 respectively. Workspace-data
fanout still reaches the whole workspace. Each workspace stays within one
generator process so expected delivery sets can be checked without a second
networked coordination service. Workspace names are balanced using
`xxhash(workspace) % 256 % worker_count`, not hash modulo worker count directly.

The end-of-run audit stops mutations, drains expected live events, fences each
connection and compares every user cache with server reads. One user per chat
room then unsubscribes, checks exclusion, disconnects, misses a retained message,
reconnects, resubscribes and reads paginated history. Every acknowledged message
must appear once with the correct identity, content and sequence. Retry ACKs
must preserve the original sequence. NRC excludes the sending connection from
retained-message broadcasts; its ACK and history are checked instead.

Subscription and history boundaries are checked against acknowledged sequences,
and every page's continuation cursor is checked, including the final page.
High-water values are shard-wide, so unrelated workspaces can advance them;
the checker enforces lower bounds and monotonicity, not an exact room-local value.
The fresh, unexpired fixture expects subscription cutoff 0 and history cutoff 1.
Runs spanning the 24-hour retention window need a different expiration-aware audit.

Finally, the audit deletes membership edges, a note and a task, checks their
broadcasts, and reconciles the surviving records. Different workspaces and room
groups act as isolation controls: foreign or excluded deliveries fail the run.
Lifecycle actions are outside steady-state latency histograms; reconnect plus
history/cache recovery has its own latency measurement.

## CPU placement and capacity limits

The Linux harness reads the current allowed CPU set and physical package/core
IDs from sysfs. It assigns one logical CPU per physical core, never placing
different roles on SMT siblings. It refuses a topology with too few allowed
physical cores rather than oversubscribing silently.

On the eight-core Ryzen 9 5900HX runner, the default placement is:

| Role | CPU IDs |
| --- | --- |
| Left for OS/desktop | 0–1 |
| NRC service/control | 2 |
| Two storage bulk executors sharing one physical core | 4 |
| Two NRC workers | 6, 8 |
| Two generator processes, each with `GOMAXPROCS=1` | 12, 14 |
| Spare physical core | 10–11 |

`--workers=3` uses CPU 10 as well. The baseline does not use worker or generator
SMT siblings. Affinity is process-local: it does **not** exclude other desktop
processes, kernel work or interrupts. This is not an isolated-hardware benchmark.
The environment report and resource samples include topology, frequency,
temperature, process CPU/RSS/I/O, huge-page accounting and server thread affinity.

The harness raises only its inherited soft descriptor limit, within the existing
hard limit, and refuses an insufficient hard limit. It spreads connections over
multiple `127/8` source addresses before exhausting the ephemeral port range.
It changes no sysctls, governors, cgroups or IRQ affinity. Use a different
`--source-octet` for overlapping runs, although concurrent capacity runs on this
machine would invalidate their isolation assumptions.

For remote generators, invoke the Go binary directly with `--disposable`, a
fresh shared `--prefix`, `--partition`, `--partitions`, and the actual server
`--workers` count. Set `NRC_SIM_JWT_SECRET` through the process environment.
`--source-ip` accepts a comma-separated list of addresses already usable on
that machine. The Python harness intentionally runs only a local disposable
server. Coordinate remote start barriers externally; the local harness uses
readiness files and a common future start timestamp.

## Verdicts and evidence

The command exits nonzero if any verdict does not pass. `summary.json` requires
every generator to pass; it never averages percentiles. Incomplete audits cannot
produce a pass. Read `complete`, `failures` and `failure_examples` to distinguish
an observed failure from checks that could not finish.

| Verdict | Failure conditions |
| --- | --- |
| Correctness | Wrong data/identity/scope, duplicate live delivery or stored message, missing acknowledged history, divergent caches, missing expected live events after drain |
| Reliability | Unexpected disconnect, rejected operation, request with unknown outcome |
| Performance | Per-operation p95 > 250 ms or p99 > 1 s; request timeout at 5 s; reconnect/reconciliation > 10 s |
| Measurement validity | Global or per-operation scheduling p99 > 100 ms, missing primary operation samples, failed trace output, or incomplete offered workload/audit |

Thresholds are provisional, configurable with `--sim-arg=--p99=2s` and the
corresponding other options. Latency histograms report sample counts, p50, p95,
p99 and maximum. Small samples do not establish a stable p99. Delivery latency
starts immediately before the originating operation is submitted and ends when
the receiving generator decodes and validates it, so it includes generator work.

Request histograms measure submission to response, excluding scheduling lag.
`schedule_lag_<operation>` measures the delay before starting each action;
`scheduled_<operation>` measures its intended deadline to completion (including
an optional retained retry). These latter histograms are diagnostic and do not
use the request-latency thresholds. Failed actions also contribute to these
action-level histograms. No individual latency histogram isolates server time.
Every generator needs samples for task/note reads, task/note edits, retained sends,
pings and scheduling lag. `missing_measurements` lists gaps; a short run with no
samples is invalid, not a pass. Randomly selected retained retries are optional.

A timeout does not prove that a write failed. Retained-message expectations
remain available for history reconciliation; the report counts unknown writes
found there. It still fails reliability because the original request did not
complete normally. Non-idempotent record creates are never blindly retried.

Each run preserves:

- `environment.json`: configuration, CPU plan, limits, Git state and binary hashes.
- `generator-N.json`: verdicts, operation/delivery counts and latency histograms.
- `trace-N.jsonl`: user/request IDs, operations and times, plus action errors.
- `resources.jsonl`: one-second server/generator and host resource samples.
- Server/generator logs and disposable WAL data.

Counts named `measured_*` and histogram sample counts describe steady-state
operations. Total byte and delivery counters also include setup and audits;
byte counters count NRC protocol bytes, not TCP/WebSocket overhead. A seed
reproduces action choices, not OS/network scheduling. Expected message/event
metadata grows with duration so final reconciliation can check the complete run;
inspect generator RSS during long soaks.

## Check the checker

```sh
go -C benchmark test ./cmd/active-user-sim
python3 -B -m unittest discover -s benchmark -p test_active_users.py -v
NRC_SIM_SERVER_BIN="$PWD/.amp/in/active-server" NRC_SIM_RACE=1 \
  go -C benchmark test -race ./cmd/active-user-sim -v
```

The opt-in real-server tests run the CLI through a WebSocket proxy. They verify
a healthy run with history pagination, then deliberately drop a live message,
corrupt history, disconnect a subscriber, delay an ACK past the request deadline,
corrupt subscription/replay/live-page boundaries, send a delayed duplicate ACK,
and set an unattainable latency target. The healthy case must finish multi-page
history traversals, not merely count messages across rooms.
Each fault must fail. The topology tests include nonadjacent SMT numbering and
a restricted CPU set. Python subprocess tests send repeated SIGTERM to the
coordinator and verify its children have exited.

This version does not inject server restarts, slow-reader overload, DM membership
changes or external service failures into the large workload. Its correctness
claim covers the exercised task/note/slice/room-message paths, not every NRC API.
Use a separate fault campaign for those cases rather than interpreting a clean
20k-user run as proof of crash durability or maximum capacity.
