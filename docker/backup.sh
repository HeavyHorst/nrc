#!/usr/bin/env bash
set -euo pipefail

exec 9>/run/lock/nrc-backup.lock
flock -n 9 || {
  echo "another NRC backup is already running" >&2
  exit 1
}

COMPOSE_DIR=/root/nrc
COMPOSE_FILE=docker/docker-compose.yml
BACKUP_ROOT=/root/backups/nrc-daily
TS=$(date -u +%Y%m%dT%H%M%SZ)
PARTIAL="$BACKUP_ROOT/$TS.partial"
FINAL="$BACKUP_ROOT/$TS"

mkdir -p "$BACKUP_ROOT" "$PARTIAL"
cd "$COMPOSE_DIR"

COMPOSE_ARGS=(--env-file .env -f "$COMPOSE_FILE")
if [[ -f publish.env ]]; then
  COMPOSE_ARGS=(--env-file .env --env-file publish.env -f "$COMPOSE_FILE" -f docker/compose.publish.yml)
fi
docker compose "${COMPOSE_ARGS[@]}" config -q
mapfile -t RUNNING_SERVICES < <(docker compose "${COMPOSE_ARGS[@]}" ps --services --filter status=running)
mapfile -t VOLUMES < <(docker volume ls \
  --filter label=com.docker.compose.project=docker \
  --format "{{.Name}}" | sort)

if ((${#RUNNING_SERVICES[@]} == 0)); then
  echo "no running NRC services found" >&2
  exit 1
fi
if ((${#VOLUMES[@]} == 0)); then
  echo "no NRC Docker volumes found" >&2
  exit 1
fi

STACK_STOPPED=0
restart_stack() {
  local status=$?
  trap - EXIT INT TERM
  if ((STACK_STOPPED)); then
    docker compose "${COMPOSE_ARGS[@]}" up -d "${RUNNING_SERVICES[@]}" || status=1
  fi
  if ((status != 0)); then
    rm -rf -- "$PARTIAL"
  fi
  exit "$status"
}
trap restart_stack EXIT INT TERM

{
  printf "timestamp=%s\n" "$TS"
  printf "host=%s\n" "$(hostname)"
  printf "compose_file=%s/%s\n" "$COMPOSE_DIR" "$COMPOSE_FILE"
  printf "publish_enabled=%s\n" "$(test -f publish.env && echo yes || echo no)"
  printf "mode=quiesced\n"
  printf "retention_days=7\n"
  printf "services=%s\n" "${RUNNING_SERVICES[*]}"
  printf "volumes=%s\n" "${VOLUMES[*]}"
} > "$PARTIAL/manifest.txt"
docker compose "${COMPOSE_ARGS[@]}" ps > "$PARTIAL/compose-ps-before.txt"

STACK_STOPPED=1
docker compose "${COMPOSE_ARGS[@]}" stop "${RUNNING_SERVICES[@]}"

for volume in "${VOLUMES[@]}"; do
  echo "Backing up $volume"
  docker volume inspect "$volume" \
    --format "volume={{.Name}} mountpoint={{.Mountpoint}}" >> "$PARTIAL/manifest.txt"
  docker run --rm \
    -v "$volume:/volume:ro" \
    -v "$PARTIAL:/backup" \
    alpine sh -c "cd /volume && tar -czf /backup/${volume}.tar.gz ."
done

cd "$PARTIAL"
sha256sum ./*.tar.gz > SHA256SUMS
sha256sum -c SHA256SUMS
for archive in ./*.tar.gz; do
  tar -tzf "$archive" >/dev/null
done

cd "$COMPOSE_DIR"
docker compose "${COMPOSE_ARGS[@]}" up -d "${RUNNING_SERVICES[@]}"
STACK_STOPPED=0
docker compose "${COMPOSE_ARGS[@]}" ps > "$PARTIAL/compose-ps-after.txt"

mv "$PARTIAL" "$FINAL"
find "$BACKUP_ROOT" \
  -mindepth 1 -maxdepth 1 -type d \
  -name "20??????T??????Z" -mtime +6 \
  -exec rm -rf -- {} +

echo "NRC backup completed: $FINAL"
