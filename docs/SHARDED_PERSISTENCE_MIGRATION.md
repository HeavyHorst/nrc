# Migrating Legacy Persistence to Sharded_V1

> **Pinned historical runbook.** Current NRC builds are sharded-only and do not contain
> the migration commands below. This procedure is retained solely for the remaining
> one-shot installation cutovers and must be executed from the explicitly pinned commit
> `70d3da1`. Do not substitute the current binary or current file-layout assumptions.

This is the one-shot operational runbook for converting an NRC installation from worker-number
task/asset/edge WALs to the fixed 256-shard layout. It deliberately uses the existing offline commands
instead of adding online migration, resumability, or dual writes.

The examples assume the repository's Docker Compose service and mount names. Set deployment-specific
values explicitly rather than copying values from another installation.

## Result

The active manifest changes from `Legacy_Worker_V1` generation 1 to `Sharded_V1` generation 2. The
new files are:

```text
data/
├── storage-layout.manifest
├── storage-layout.lock
└── sharded-00000000000000000002/
    ├── migration-origin.manifest
    ├── shard_000/active.wal
    ├── ...
    └── shard_255/active.wal
```

Legacy `tasks_thread_N.log`, `assets_thread_N.log`, and `edges_thread_N.log` files remain at the data
root as rollback-only material. Sharded workspace placement is
`XXH64(workspace bytes, seed 0) % 256`; runtime worker ownership is `shard_id % worker_count`.

## Safety boundaries

- Use the pinned image commit `70d3da1` for bootstrap, migration, and cutover. Newer server images are
  sharded-only and intentionally do not contain the one-shot migration commands.
- Build and push the immutable target image before stopping production.
- Stop the WebSocket server before bootstrap, migration, or cutover. The directory lock is a guard,
  not permission to perform an online migration.
- Determine the legacy worker count from the deployment configuration and WAL inventory. Pass that
  exact count to every command.
- Make a fresh stopped-server backup and verify its checksum before changing the manifest.
- Never run `layout-bootstrap-legacy` when `storage-layout.manifest` already exists.
- The parent of `--stage-dir` must exist and be writable by the image user, but the final stage path
  itself must not exist. The migration creates it exclusively.
- Before cutover, a failed migration leaves the legacy manifest authoritative and the old server may
  be restarted. After cutover, do not start a legacy image against the volume.
- Never edit or replace `storage-layout.manifest` manually.

## 1. Prepare and validate the image

From a clean checkout pinned to `70d3da1`:

```bash
odin test . -define:ODIN_TEST_LOG_LEVEL=error
odin test . -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error
odin build . -vet

test "$(git rev-parse --short HEAD)" = 70d3da1
TAG=70d3da1
IMAGE="<registry>/nrc/websocket:${TAG}"
docker build -f docker/Dockerfile -t "$IMAGE" .
docker push "$IMAGE"
```

Record the pushed digest. Use the immutable tag throughout the migration; do not substitute `latest`.

The release must include the lifecycle test covering legacy replay, migration, cutover, a sharded
mutation, and restart with a different worker count.

## 2. Resolve deployment values

On the target host:

```bash
COMPOSE_DIR=<absolute-compose-directory>
SERVICE=websocket-server
WORKER_COUNT=<exact-legacy-worker-count>
IMAGE=<registry>/nrc/websocket:<commit-tag>
TAG=${IMAGE##*:}

cd "$COMPOSE_DIR"
CONTAINER=$(docker compose ps -q "$SERVICE")
test -n "$CONTAINER"
DATA_VOLUME=$(docker inspect "$CONTAINER" \
  --format '{{range .Mounts}}{{if eq .Destination "/app/data"}}{{.Name}}{{end}}{{end}}')
test -n "$DATA_VOLUME"
docker pull "$IMAGE"
docker compose ps "$SERVICE"
docker inspect "$CONTAINER" --format '{{.Config.Image}} {{.State.Status}}'
```

Confirm sufficient free space for the stopped-volume archive, external staging tree, and prepared
generation. Inspect the root inventory without changing it:

```bash
docker run --rm -v "$DATA_VOLUME":/app/data:ro alpine:3.20 \
  find /app/data -maxdepth 1 -type f -print | sort
```

The legacy inventory must match `WORKER_COUNT`: each worker index has canonical task, asset, and edge
WALs. Resolve unexpected `.compact`, `.overflow`, recovery-marker, symlink, or non-regular artifacts
before proceeding; the migration intentionally fails closed on unsafe layouts.

## 3. Stop and make the authoritative backup

```bash
cd "$COMPOSE_DIR"
docker compose stop "$SERVICE"
test "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" = false

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP="<absolute-backup-root>/sharded-cutover-${STAMP}"
mkdir -p "$BACKUP"
docker inspect "$CONTAINER" > "$BACKUP/websocket-container-inspect.json"
cp docker-compose.yml "$BACKUP/"
test ! -f .env || cp .env "$BACKUP/compose.env"

docker run --rm \
  -v "$DATA_VOLUME":/source:ro \
  -v "$BACKUP":/backup \
  alpine:3.20 tar czf /backup/task-data.tgz -C /source .
sync
(cd "$BACKUP" && sha256sum task-data.tgz | tee SHA256SUMS && sha256sum -c SHA256SUMS)
```

Copy `task-data.tgz` and `SHA256SUMS` to a second machine or backup store and verify the checksum
there. This stopped-server archive—not an older live backup—is the rollback source.

## 4. Bootstrap the legacy manifest only when absent

Check existence without printing the binary manifest as text:

```bash
docker run --rm -v "$DATA_VOLUME":/app/data:ro alpine:3.20 \
  sh -c 'if test -f /app/data/storage-layout.manifest; then echo present; else echo absent; fi'
```

If and only if the result is `absent`, run:

```bash
docker run --rm --privileged \
  -v "$DATA_VOLUME":/app/data \
  "$IMAGE" server layout-bootstrap-legacy \
  --worker-count "$WORKER_COUNT" \
  --data-dir /app/data
```

Expected output confirms installation of an audited legacy manifest. If the manifest was already
present, skip bootstrap; the migration command will validate that it is a coherent legacy manifest.

## 5. Build and verify the dormant sharded generation

Create only the work parent. Do not create `stage`:

```bash
WORK="<absolute-work-root>/sharded-migration-${TAG}"
mkdir -p "$WORK"
test ! -e "$WORK/stage"
IMAGE_UID=$(docker run --rm "$IMAGE" id -u)
IMAGE_GID=$(docker run --rm "$IMAGE" id -g)
chown "$IMAGE_UID:$IMAGE_GID" "$WORK"

docker run --rm --privileged \
  -v "$DATA_VOLUME":/app/data \
  -v "$WORK":/work \
  "$IMAGE" server migrate-sharded-offline \
  --worker-count "$WORKER_COUNT" \
  --data-dir /app/data \
  --stage-dir /work/stage
```

Success must report that it prepared a **dormant** sharded generation after replay-equivalence proof
and that the legacy manifest remains active. Do not proceed on any nonzero exit or missing success
message. Preserve failed artifacts and logs for diagnosis; remove only a known migration-owned stage
path before a deliberate retry.

At this point failure recovery is simple: do not run cutover, and restart the old service. The dormant
generation is not authoritative while the manifest remains legacy.

## 6. Publish the sharded manifest

Cutover re-acquires the lock, rebuilds the legacy plan, audits the prepared generation, and only then
atomically replaces the manifest:

```bash
docker run --rm --privileged \
  -v "$DATA_VOLUME":/app/data \
  "$IMAGE" server layout-cutover-sharded \
  --worker-count "$WORKER_COUNT" \
  --data-dir /app/data
```

Require the success message `Activated sharded storage generation ...` before deployment. This is the
rollback boundary: after this command succeeds, only a sharded-capable image may open the volume.

## 7. Deploy and verify

The repository Compose file reads `NRC_WEBSOCKET_IMAGE` from `$COMPOSE_DIR/.env` for image selection:

```bash
cd "$COMPOSE_DIR"
if grep -q '^NRC_WEBSOCKET_IMAGE=' .env; then
  sed -i "s|^NRC_WEBSOCKET_IMAGE=.*|NRC_WEBSOCKET_IMAGE=$IMAGE|" .env
else
  printf '\nNRC_WEBSOCKET_IMAGE=%s\n' "$IMAGE" >> .env
fi

docker compose pull "$SERVICE"
docker compose up -d --no-deps --force-recreate "$SERVICE"
sleep 10
docker compose ps "$SERVICE"
docker compose logs --no-color --tail=150 "$SERVICE"
```

Require all of the following:

- The container uses the intended immutable image and remains `Up` without restart loops.
- Every worker reports startup and the server publishes `Listening on 0.0.0.0:8080` only afterward.
- Logs contain no persistence, replay, assertion, panic, or allocation errors.
- Sidecars and normal clients reconnect.
- The public endpoint and an authenticated application operation succeed.
- Exactly one active generation contains 256 shard directories and 256 regular `active.wal` files.

```bash
docker run --rm -v "$DATA_VOLUME":/app/data:ro alpine:3.20 sh -c '
  find /app/data -maxdepth 1 -type d -name "sharded-*" -print
  test "$(find /app/data -mindepth 1 -maxdepth 1 -type d -name "sharded-*" | wc -l)" -eq 1
  test "$(find /app/data -mindepth 2 -maxdepth 2 -type d -name "shard_*" | wc -l)" -eq 256
  test "$(find /app/data -mindepth 3 -maxdepth 3 -type f -name active.wal | wc -l)" -eq 256
'
```

Finally perform one controlled restart and repeat the startup, reconnection, and application checks.
This proves the deployed process can replay the active sharded generation rather than merely continue
with migration-time state.

## Failure handling

### Before successful manifest cutover

The legacy manifest remains authoritative. Keep migration artifacts for investigation and restart the
old service. If production resumes and accepts mutations, make another fresh stopped-server backup and
rerun migration from the new legacy state; never reuse an older staged generation.

### After successful manifest cutover

Do not start the old legacy image and do not hand-edit the manifest. First diagnose the sharded-capable
image while the service remains stopped. If rollback is required, obtain explicit operator approval,
restore the entire verified pre-cutover volume archive as one unit, restore the corresponding image
selection/configuration, and then start the old service. Restoring only selected WALs or only the
manifest can create a mixed generation and is unsupported.

## Cleanup

Keep the pre-cutover archive and legacy WALs through the agreed rollback window. After both NRC
installations have run and restarted successfully in sharded mode and rollback is no longer required,
plan removal of legacy migration commands and files as a separate reviewed change. Do not delete
backups, staging trees, dormant generations, or rollback WALs as part of the migration itself.
