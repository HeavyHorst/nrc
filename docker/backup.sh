#!/usr/bin/env bash
set -euo pipefail
umask 077

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

MODE=backup
ROLLBACK_CONFIG=""
DEPLOY_SERVICES=()
if (($#)); then
  case "$1" in
    --prepare-deploy | --deploy)
      MODE=${1#--}
      (($# >= 2)) || { echo "Missing rollback configuration path" >&2; exit 2; }
      ROLLBACK_CONFIG=$2
      shift 2
      DEPLOY_SERVICES=("$@")
      ;;
    *) echo "Usage: nrc-backup [--prepare-deploy CONFIG | --deploy CONFIG SERVICE...]" >&2; exit 2 ;;
  esac
fi
cd "$COMPOSE_DIR"

COMPOSE_ARGS=(--env-file .env -f "$COMPOSE_FILE")
if [[ -f publish.env ]]; then
  COMPOSE_ARGS=(--env-file .env --env-file publish.env -f "$COMPOSE_FILE" -f docker/compose.publish.yml)
fi
if [[ -n $(docker ps --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=newsletter --format '{{.ID}}') ]]; then
  COMPOSE_ARGS+=(-f docker/compose.newsletter.yml)
fi
if [[ -f monitoring.env ]]; then
  COMPOSE_ARGS+=(--env-file monitoring.env -f docker/compose.monitoring.yml)
fi
if [[ -f chronicle.env ]]; then
  COMPOSE_ARGS+=(--env-file chronicle.env -f docker/compose.chronicle.yml)
fi
if [[ -n $(docker ps -aq --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=tickets) ]]; then
  COMPOSE_ARGS+=(-f docker/compose.tickets.yml)
  if [[ -n $(docker ps -aq --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=ticket-bot-tls) ]]; then
    COMPOSE_ARGS+=(-f docker/compose.ticket-bot-tls.yml)
  fi
fi
# Model every running profiled service, but restart only the captured set below.
COMPOSE_ARGS+=(--profile '*')
docker compose "${COMPOSE_ARGS[@]}" config -q
mapfile -t RUNNING_SERVICES < <(docker compose "${COMPOSE_ARGS[@]}" ps --services --filter status=running)
# Migrated/external data volumes need not have Compose labels. Include mounts
# from stopped containers too, without dropping existing labelled backups.
project_containers=$(docker ps -aq --filter label=com.docker.compose.project=docker)
mounted_volumes=""
if [[ -n $project_containers ]]; then
  mapfile -t container_ids <<< "$project_containers"
  mounted_volumes=$(docker inspect \
    --format '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}' \
    "${container_ids[@]}")
fi
labelled_volumes=$(docker volume ls \
  --filter label=com.docker.compose.project=docker \
  --format "{{.Name}}")
mapfile -t VOLUMES < <(printf '%s\n' "$labelled_volumes" "$mounted_volumes" | sed '/^$/d' | sort -u)

if ((${#RUNNING_SERVICES[@]} == 0)); then
  echo "no running NRC services found" >&2
  exit 1
fi
if ((${#VOLUMES[@]} == 0)); then
  echo "no NRC Docker volumes found" >&2
  exit 1
fi

if [[ $MODE == prepare-deploy ]]; then
  # Render before source sync. Pin actual running image IDs, not mutable tags.
  mkdir -p "$(dirname "$ROLLBACK_CONFIG")"
  docker compose "${COMPOSE_ARGS[@]}" config --format json > "$ROLLBACK_CONFIG"
  docker inspect "${container_ids[@]}" | python3 -c '
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    model = json.load(f)
containers = [c for c in json.load(sys.stdin) if c["State"]["Running"]]
# After a rollback, source still contains the failed candidate. Capture the
# configuration actually used to recreate the running containers instead.
config_files = {c["Config"]["Labels"].get("com.docker.compose.project.config_files", "")
                for c in containers}
if len(config_files) == 1:
    previous = next(iter(config_files))
    if previous != path and previous.endswith("/compose-rollback.json") and os.path.isfile(previous):
        with open(previous) as f:
            model = json.load(f)
running = []
for container in containers:
    name = container["Config"]["Labels"]["com.docker.compose.service"]
    service = model["services"][name]
    service["image"] = container["Image"]
    service.pop("build", None)
    running.append(name)
model["x-nrc-running-services"] = running
# Compose config already escapes literal dollars for reuse as Compose input.
with open(path, "w") as f:
    json.dump(model, f)
' "$ROLLBACK_CONFIG"
  echo "Saved rollback configuration and running image IDs: $ROLLBACK_CONFIG"
  exit 0
fi

if [[ $MODE == deploy ]]; then
  ((${#DEPLOY_SERVICES[@]})) || { echo "No deployment services supplied" >&2; exit 2; }
  # Validate rollback inputs before stopping anything, including image availability.
  docker compose --env-file /dev/null -f "$ROLLBACK_CONFIG" --profile '*' config -q
  docker inspect "${container_ids[@]}" | python3 -c '
import json, subprocess, sys
with open(sys.argv[1]) as f:
    model = json.load(f)
actual = {c["Config"]["Labels"]["com.docker.compose.service"]: c["Image"]
          for c in json.load(sys.stdin) if c["State"]["Running"]}
expected = {s: model["services"][s]["image"] for s in model["x-nrc-running-services"]}
if actual != expected:
    raise SystemExit("Running services/images changed since rollback capture; refusing deployment")
subprocess.run(["docker", "image", "inspect", *set(expected.values())],
               check=True, stdout=subprocess.DEVNULL)
' "$ROLLBACK_CONFIG"
fi

mkdir -p "$BACKUP_ROOT" "$PARTIAL"
chmod 700 "$BACKUP_ROOT" "$PARTIAL"

wait_for_services() {
  local deadline=$((SECONDS + 120)) all_ready service ids states state unready
  while :; do
    all_ready=true
    unready=""
    for service in "$@"; do
      ids=$(docker ps -aq --filter label=com.docker.compose.project=docker --filter "label=com.docker.compose.service=$service") || return 1
      if [[ -z $ids ]]; then
        all_ready=false
        unready+=" $service(missing)"
        continue
      fi
      states=$(docker inspect --format '{{.State.Running}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' $ids) || return 1
      while IFS= read -r state; do
        if [[ $state != 'true healthy' && $state != 'true none' ]]; then
          all_ready=false
          unready+=" $service($state)"
        fi
      done <<< "$states"
    done
    $all_ready && return 0
    if ((SECONDS >= deadline)); then
      echo "Services did not become ready within 120 seconds:$unready" >&2
      return 1
    fi
    sleep 1
  done
}

STACK_STOPPED=0
SWITCH_ATTEMPTED=0
restart_stack() {
  local status=$?
  trap - EXIT INT TERM
  if ((STACK_STOPPED)); then
    if ((SWITCH_ATTEMPTED)); then
      echo "Image switch failed; restoring previous configuration and image IDs" >&2
      docker compose "${COMPOSE_ARGS[@]}" stop "${DEPLOY_SERVICES[@]}" || status=1
      if docker compose --env-file /dev/null -f "$ROLLBACK_CONFIG" --profile '*' \
          up -d --no-deps --no-build --pull never "${RUNNING_SERVICES[@]}" &&
          wait_for_services "${RUNNING_SERVICES[@]}"; then
        echo "Previous images and configuration restored; services are ready"
      else
        echo "Rollback did not restore ready services; manual recovery required" >&2
        status=1
      fi
    else
      docker compose "${COMPOSE_ARGS[@]}" start "${RUNNING_SERVICES[@]}" || status=1
    fi
  fi
  if ((status != 0)); then
    if ((SWITCH_ATTEMPTED)); then
      echo "Preserving pre-switch volume copies for manual recovery: $PARTIAL" >&2
    else
      rm -rf -- "$PARTIAL"
    fi
  fi
  exit "$status"
}
trap restart_stack EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

{
  printf "timestamp=%s\n" "$TS"
  printf "host=%s\n" "$(hostname)"
  printf "compose_file=%s/%s\n" "$COMPOSE_DIR" "$COMPOSE_FILE"
  printf "publish_enabled=%s\n" "$(test -f publish.env && echo yes || echo no)"
  printf "monitoring_enabled=%s\n" "$(test -f monitoring.env && echo yes || echo no)"
  printf "chronicle_enabled=%s\n" "$(test -f chronicle.env && echo yes || echo no)"
  printf "mode=quiesced\n"
  printf "retention_days=7\n"
  printf "services=%s\n" "${RUNNING_SERVICES[*]}"
  printf "volumes=%s\n" "${VOLUMES[*]}"
} > "$PARTIAL/manifest.txt"
docker compose "${COMPOSE_ARGS[@]}" ps > "$PARTIAL/compose-ps-before.txt"

# Fetch the archive helper before entering the downtime window.
docker image inspect alpine >/dev/null 2>&1 || docker pull alpine
STACK_STOPPED=1
echo "Stopping NRC services for the consistent volume copy: $(date -u +%FT%TZ)"
docker compose "${COMPOSE_ARGS[@]}" stop "${RUNNING_SERVICES[@]}"

for volume in "${VOLUMES[@]}"; do
  echo "Backing up $volume"
  docker volume inspect "$volume" \
    --format "volume={{.Name}} mountpoint={{.Mountpoint}}" >> "$PARTIAL/manifest.txt"
  docker run --rm \
    -v "$volume:/volume:ro" \
    -v "$PARTIAL:/backup" \
    alpine sh -c "umask 077; cd /volume && tar -cf /backup/${volume}.tar ."
done

# Volume archives include SQLite DB, WAL and SHM together while all writers are
# stopped. Never restore personal memory by copying only an old DB into service:
# reconcile current deletion/approval guards with personal_memory/storage_ops.py.

if [[ $MODE == deploy ]]; then
  SWITCH_ATTEMPTED=1
  # Start the prepared images and the previously running services in one window.
  docker compose "${COMPOSE_ARGS[@]}" up -d --no-deps --no-build --pull never \
    "${RUNNING_SERVICES[@]}" "${DEPLOY_SERVICES[@]}"
  wait_for_services "${RUNNING_SERVICES[@]}" "${DEPLOY_SERVICES[@]}"
else
  docker compose "${COMPOSE_ARGS[@]}" start "${RUNNING_SERVICES[@]}"
fi
STACK_STOPPED=0
echo "NRC containers started; compressing and verifying backup online: $(date -u +%FT%TZ)"
docker compose "${COMPOSE_ARGS[@]}" ps > "$PARTIAL/compose-ps-after.txt"

cd "$PARTIAL"
for archive in ./*.tar; do
  gzip "$archive"
done
sha256sum ./*.tar.gz > SHA256SUMS
sha256sum -c SHA256SUMS
for archive in ./*.tar.gz; do
  tar -tzf "$archive" >/dev/null
done

cd "$COMPOSE_DIR"
mv "$PARTIAL" "$FINAL"
find "$BACKUP_ROOT" \
  -mindepth 1 -maxdepth 1 -type d \
  -name "20??????T??????Z" -mtime +6 \
  -exec rm -rf -- {} +

echo "NRC backup completed: $FINAL"
