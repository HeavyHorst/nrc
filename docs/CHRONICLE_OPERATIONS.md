# Chronicle operations

The operator approved rollout on 17 November 2026, limited to `workspace1`, and
confirmed that the existing OpenAI approval covers automatic note-change
processing. Check the release record and live status for activation state;
approval alone does not mean deployment succeeded. OpenAI `store=false` does not
establish a data region or zero data retention.

The read-only production inspection on that date found 256 shard databases at
schema 5, no Chronicle environment in the server or AI container, and a successful
backup service result. Recheck before rollout. A successful backup job is not a
restore test.

## Release prerequisites

- Commit and publish the reviewed source; deploy requires clean `main` matching
  `origin/main`. Run the full local test matrix on that exact source first.
- Recheck actual-token settlement through the synthetic Terra process test;
  earlier paid p9 runs predate that accounting change. Never use production notes
  for the test. Keep paid tests separate from ordinary provider-free tests.
- Name the pilot workspace, dedicated service subject, permitted human deletion
  subjects and on-call operator. Do not enable every workspace as a shortcut.
- Verify the current production data volume and selected generation. Keep
  monitoring/newsletter/publication overlays when constructing Compose commands.
- Approve a maintenance window, a quiesced backup and a tested restore location.
  Do not start the schema-7 binary against older storage.

## Credentials and Compose

`docker/compose.chronicle.yml` defines a separate `chronicle` process with the AI
image. It has no published port, no general bot/signing secret, no personal-memory
volume and no access to attachments or server storage. The filesystem and both
credential mounts are read-only. It runs as UID/GID 65532; credentials must be
readable by that identity, not by other users.

Provision outside Git, through the existing private credential system:

- `openai-key`: a regular file, owner 65532:65532, mode 0600. A dedicated provider
  key is preferred. The `workspace1` pilot uses the existing approved Sullivan
  OpenAI key in a separate private file; revoking it affects both processes.
  The service JWT is separate and restricted even when the provider key is shared.
- `service-tokens.json`: a private JSON object mapping exact workspace IDs to
  dedicated service JWTs. Same owner and mode; at most 16 workspaces. Each JWT
  needs the exact workspace, allowlisted subject, `user_type:"bot"` and
  `capability:"chronicle"`, signed by the existing trusted issuer. Do not give the
  worker a signing key. Plan renewal before expiry; it cannot renew tokens itself.
- A directory such as `/etc/nrc/chronicle`, mode 0700, owner 65532:65532. Keep the
  credentials in the private recovery system; volume backups do not include
  these host bind mounts. Never print rendered environment or token files in logs.

The server's private `.env` carries exact `NRC_CHRONICLE_WORKSPACES`,
`NRC_CHRONICLE_SERVICE_SUBJECTS` and, if needed, `NRC_CHRONICLE_DELETE_SUBJECTS`.
Use JSON workspace-to-subject arrays for the latter two, as in `.env.example`.
Keep all three empty during migration. Legacy bot credentials grant no service
or deletion rights.

Copy the reviewed overlay to the host before rendering an incoming deployment.
Provision `/root/nrc/chronicle.env` from `docker/chronicle.env.example` only at
approved activation: **its presence opts future deploy and backup commands into
the overlay**. It contains only the absolute credential directory, no secrets.
Without this file, the base stack and deploy path remain unchanged. Deploy and
backup preserve this overlay after activation; backup restarts only services
that were running before it stopped the stack. Deploy rebuilds Chronicle whenever
the shared AI image changes. A deliberate stop is not a permanent disable across
later deployments.

On an isolated fixture or during the approved maintenance window, validate the
complete Compose model with `docker compose ... config -q`. Include
`--env-file chronicle.env -f docker/compose.chronicle.yml --profile chronicle`
alongside the base and already active overlays. Do not use plain `config` output
in tickets: it can contain unrelated secrets. Do not start the worker yet.

## Parallel worker and schema 10

The ten-lane worker requires the matching schema-10 server. This feature is
local and has not been deployed to production. Follow the
[stopped schema-9-to-10 migration](DEVELOPMENT.md#sqlite-schema-10), with a fresh
quiesced backup and restore rehearsal, before switching binaries.

The worker admits at most ten steps globally; the server independently limits
each workspace to ten running jobs plus completed, unpublished receipts.
Responses can finish out of order. `staged` confirms that the result and budget
settlement are durable; it must not trigger another provider call. Publication
waits for earlier sources to finish, expire or be explicitly deleted. A parked
head can therefore leave nine completed results waiting, but cannot grow an
unbounded queue behind it. Polling resumes immediately after progress and waits
five seconds after idle, full-window, budget or failure outcomes.

Completed receipts survive worker/server restarts and raw-input expiry. Accepted
terminal receipts also survive capture disable, like existing history; disable
still fences unfinished inputs and old writers. Startup and expiry maintenance
publish source-ready receipts without a running worker, including after disable.
Only explicit Chronicle deletion
removes completed prose, including staged prose. `pending` counts unfinished
inputs, not staged results; a falling pending count does not imply that every
finished summary is already visible. Old immutable claim IDs remain valid for
exact receipt replay; history cursors use separately assigned publication IDs.

## Schema 6 to 7

The 128,000-token input limit needs the explicit
[schema-7 migration](DEVELOPMENT.md#sqlite-schema-7) on every shard. Stop server
and worker, back up the complete selected generation, and rehearse on an isolated
copy before production approval. This rebuilds the jobs table with foreign-key
enforcement disabled outside the transaction; the migration checks foreign keys
before commit. Preserve active reservations, completed/deleted receipts, source
memberships, canonical/history records and daily counters. Require version 7,
clean integrity/foreign-key checks and unchanged records across all shards before
starting the schema-7 server. Nothing is enabled or replayed by the migration.
The older 5-to-6 step below is still required for pre-Chronicle installations.

## Schema 5 to 6 and restore rehearsal

Follow [the offline SQL procedure](DEVELOPMENT.md#sqlite-schema-6). The migration
is explicit, additive and starts Chronicle tables empty, with no historical
backfill or capture opt-in. Monitoring stays at its existing schema-5 layout.

1. Restore a verified quiesced backup into a disposable, isolated volume. Include
   SQLite DB/WAL/SHM together. Do not attach this copy to a live writer.
2. Inventory every shard in the selected generation. Verify application ID
   `0x4e524351`, `user_version=5`, `PRAGMA integrity_check` returning `ok`, and no
   `PRAGMA foreign_key_check` rows. Record canonical/history row counts per shard.
3. With all writers stopped, apply `workspace_db/chronicle.sql` to each shard in
   an explicit transaction using `sqlite3 -bail`, as documented. Require exit 0,
   version 6, matching canonical/history counts, empty Chronicle tables and clean
   integrity/foreign-key checks. Do not continue after a partial migration.
4. Start the schema-6 server on the isolated copy with capture policies empty.
   Confirm ordinary reads/writes and monitoring, restart it and repeat reads.
   No worker or real provider is needed for the migration rehearsal.
5. Restore the original backup into another isolated volume and verify the old
   binary can reopen it. Record backup identity, checksums, source revision,
   shard inventory, timings and the exact complete Compose invocation.

Only repeat this procedure on production after explicit approval and a fresh
quiesced backup. If any shard fails, keep every writer stopped and restore the
whole pre-upgrade generation. Never change `user_version` to force acceptance.
There is no supported downgrade. After new writes, restoring an old backup loses
those writes; prefer disabling Chronicle while retaining the schema-6 server.
Do not replay deleted Chronicle text or stale processing claims from a backup.
Logical SQL deletion is not erasure from SQLite WAL, snapshots or backups.

## Pilot and read-only checks

After approved migration, first start with capture disabled. Then enable only
the approved pilot workspace and subjects, restart the server to load policy,
and start exactly one Chronicle worker. Do not run Fake on real data: its outputs
and gaps are terminal records. Keep the ordinary Sullivan process unchanged.

Build the matching CLI from `cli/`; an older installed CLI may lack `chronicle`.
Configure a separate operator CLI identity for the intended workspace using its
existing config/auth mechanism. Do not use the worker's JWT as an operator login.
Read `nrc chronicle status` and verify `enabled=true` before checking progress.
The following pipeline makes only a public status read; Python performs no I/O
to NRC or OpenAI:

```sh
set -o pipefail
nrc chronicle status | python3 docker/chronicle_check.py
```

Exit 0 means no detected warning, 1 means operational warning, 2 means invalid or
incompatible status. Retain complete status JSON snapshots privately if needed.
For two snapshots of the **same workspace and UTC day**, at least ten minutes
apart, pass `--previous /private/previous-status.json --elapsed-seconds 600`.
The checker never saves snapshots or reads histories, gaps, credentials or notes.

Check every minute in the pilot (scheduling/notification is not installed here):

| Signal | Response |
| --- | --- |
| Container absent, restarting, or stopped | Inspect Compose state and bounded logs; never infer provider readiness from a running PID. |
| Status command fails | Check CLI auth, server version and workspace; preserve the nonzero exit code. |
| Failed/parked inputs | Inspect sanitized `chronicle step` status. `backoff` after five reservations retries automatically after 15 minutes plus jitter; `parked` requires investigation of a permanent provider failure. Check JWT expiry and provider quota. Do not reset attempts in SQL. |
| Pending with no observed progress for 10 minutes | Check process, service auth, budget and parked global head. This is an investigation threshold, not proof of a dead worker. |
| New lost-input count | Read paginated `nrc chronicle gaps` privately; distinguish `token_limit`, TTL, disabled capture and quota causes. |
| Expired inputs | They are already unreadable by the worker; investigate cleaner health if they persist over a full shard sweep plus batch backlog. |
| 90% daily token budget | Notify the operator; do not silently raise limits. |

`processing` and `failed` are subsets of `pending`; do not add them together.
Gap count counts lost inputs, not compacted gap rows. A single snapshot cannot
prove progress, credential validity or provider availability. Gap compaction can
reduce the count, so use gaps/history inspection to resolve ambiguous comparisons.
Cross-midnight snapshots are not valid for the simple stall comparison.

For HTTP rejections, refusals, usage failures and invalid responses, the worker
emits `chronicle provider failure` before releasing the call. Its `reason`
distinguishes `http`, `refusal`, `missing_usage`, `usage_profile`,
`usage_reservation`, response encoding/envelope/shape failures and `invalid_output`.
HTTP diagnostics contain the numeric `http_status` and an allowlisted `category`
(`other` for unknown provider codes). Invalid-output categories are fixed local
validator messages. Other diagnostics contain only numeric counts/bounds.
No provider message, refusal prose,
request body, note text, transport error or credential is logged. Older worker
versions did not retain this distinction; a historical `parked` status alone
cannot establish which failure caused it.

The decoder accepts a unique final answer alongside explicitly marked assistant
commentary. Multiple unmarked answers or multiple `final_answer` messages remain
invalid: never recover them by concatenating text or publishing the first/last
message blindly. Source IDs, JSON validation and usage settlement still apply.

Budgets are 8,000,000 input and 500,000 output tokens per workspace/UTC day, with
no daily call-count cap. Each call reserves up to 128,000/1,000; confirmed usage
credits unused reservation in the original day. Unknown outcomes retain the
reservation. The per-input attempt counter saturates at five without blocking
future attempts. At that level, temporary failures, timeouts and invalid output
retry after 15 minutes plus up to 499 ms of jitter. Reservation persists the pause
before calling the provider, so an abandoned call also observes it after restart.
Each later call requires fresh daily budget; calls remain exact telemetry even
when `attempts` is saturated. The `failed` status count includes these repeatedly
failing inputs while unleased, not only permanently parked inputs. Previously
exhausted inputs resume once their stored retry time is due, without a migration
or manual counter reset. The 72-hour TTL still applies: prolonged outages can
still expire raw inputs; this is not unlimited retention or a guarantee of
provider availability. Oversized single inputs can become gaps without inference.
Terra first checks oversized byte estimates with OpenAI's free input-token
counting endpoint, using the full request input and output schema. Only counts
above 128,000 trigger rebatching or a single-input `token_limit` gap.
A counting outage creates no gap and consumes no attempt or reservation;
the claim remains until lease expiry before retry.
The counting request still sends the note text to OpenAI. Daily budgets are
unchanged; the higher per-call limit requires schema 7 as described above.

## Rotation, stop and recovery

For planned rotation, stop `chronicle`, replace private files atomically, verify
ownership/mode and restart/recreate only that service. Files load only at startup;
an atomic file replacement also requires a new container bind mount. Revoke the
old service credential after confirming the new identity. A stopped worker's
claim may remain until its five-minute lease expires; do not clear it by hand.

Stopping the worker stops new calls but capture continues, and pending raw inputs
expire after 72 hours. It does not undo calls already sent. To disable capture
and invalidate old claims, remove the workspace from the server allowlist and
restart the server. Existing results remain; disabled changes are not backfilled.
For immediate provider access revocation use the provider key's issuer controls;
stopping a process does not recall data already delivered to OpenAI.

To prevent automatic restart on a later deploy, remove the activation
`chronicle.env` only after stopping/removing its container with the full overlay
model, and disable server capture policy as appropriate. Preserve credentials in
the recovery system until revocation is confirmed. Do not delete canonical notes,
run Chronicle deletion, restore an old database or reset epochs as a shutdown step.

Successful pilot acceptance requires observed results/Acks, unchanged canonical
notes, bounded pending/raw bytes, restart without duplicates, correct token
settlement and inspected UI/CLI output. It does not grant further workspace opt-in.
