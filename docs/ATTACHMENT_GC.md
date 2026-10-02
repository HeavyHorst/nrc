# Attachment garbage collection

NRC stores attachment blobs separately from the task and asset records that reference them. The
`attachment-gc` maintenance command replays the complete sharded database, marks every attachment ID
referenced by a live task or asset, and scans retained message contents for local
`/files/att_<32 lowercase hex>?...` links before quarantining unreferenced blobs. Ephemeral chat
messages are not persisted, so links that exist only in ephemeral messages cannot keep a file live.

The command is offline by design. It takes the same exclusive data-directory lock as the WebSocket
server. The Tailscale proxy holds a shared lock on the attachment directory for its entire lifetime,
so GC also refuses to run while uploads or downloads are available.

Before an applied sweep, GC uses `syncfs` on the database directory to make the replayed state
durable. All canonical database files must therefore reside on that filesystem, as they do in the
Docker Compose deployment; do not mount shard directories from separate filesystems beneath it.

## Docker Compose procedure

Run these commands from the repository root. Before you run GC, check that the
database and its shard directories are on one filesystem.

Stop the server and proxy before you scan or change stored files:

```bash
docker compose --env-file .env -f docker/docker-compose.yml stop websocket-server tailscale-proxy
```

Run the default dry run and review its counts:

```bash
docker compose --env-file .env -f docker/docker-compose.yml --profile maintenance run --rm attachment-gc
```

**Back up the complete `task-data` and `attachments` volumes together before
you use `--apply`.** This option can permanently delete expired quarantine
batches. Files referenced only by ephemeral chat are not protected from GC.

If the dry-run counts are expected, run the scan with `--apply`:

```bash
docker compose --env-file .env -f docker/docker-compose.yml --profile maintenance run --rm attachment-gc \
  server attachment-gc --attachments-dir /data/files --apply
```

Then restart the stopped services:

```bash
docker compose --env-file .env -f docker/docker-compose.yml up -d websocket-server tailscale-proxy
```

Use `--retention-days DAYS` to change the default 30-day quarantine period.
Each run with `--apply` first restores quarantined blobs that have become referenced.
It then deletes completed batches older than the retention period. Finally, it
moves newly found unreferenced blobs into a quarantine batch with a manifest.
A dry run does not change database records or move, restore or delete blobs.
It may create the database's standard lock file if that file is missing.

Quarantine lives at `/data/files/.quarantine`. Incomplete or structurally unexpected batches are
never purged automatically.

## Backup consistency

Purging attachments can make an older database-only backup incomplete. Back up the task-data and
attachments volumes together, and retain them for the same period, before reducing quarantine
retention or permanently purging a batch.
