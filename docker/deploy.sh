#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(git -C "$SCRIPT_DIR/.." rev-parse --show-toplevel)
COMPOSE_FILE=docker/docker-compose.yml
DEPLOY_HOST=${NRC_DEPLOY_HOST:-root@lti1}
REMOTE_DIR=${NRC_DEPLOY_DIR:-/root/nrc}
ODIN_BIN=${ODIN_BIN:-/home/rene/Code/Odin/odin}
COMPOSE_ARGS="--env-file .env -f $COMPOSE_FILE"
publish_enabled=false

dry_run=false
full=false
skip_tests=false

usage() {
    cat <<'EOF'
Usage: docker/deploy.sh [--dry-run] [--full] [--skip-tests]

Deploy the committed local main revision to NRC production. The script compares
tracked files with the production snapshot, runs relevant tests, takes a
quiesced volume backup for server deployments, synchronizes source with
rollback copies, and rebuilds only affected services.

Environment:
  NRC_DEPLOY_HOST  SSH destination (default: root@lti1)
  NRC_DEPLOY_DIR   Production source directory (default: /root/nrc)
  ODIN_BIN         Odin compiler path (default: /home/rene/Code/Odin/odin)
  NRC_CLI          Configured NRC CLI used for the final smoke test
EOF
}

while (($#)); do
    case "$1" in
        --dry-run) dry_run=true ;;
        --full) full=true ;;
        --skip-tests) skip_tests=true ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

cd "$ROOT_DIR"

if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "Refusing to deploy tracked or staged changes." >&2
    git status --short >&2
    exit 1
fi

branch=$(git branch --show-current)
if [[ $branch != main ]]; then
    echo "Refusing to deploy branch '$branch'; expected main." >&2
    exit 1
fi

head_revision=$(git rev-parse HEAD)
origin_revision=$(git rev-parse origin/main)
if [[ $head_revision != "$origin_revision" ]]; then
    echo "Refusing to deploy: local main does not match origin/main." >&2
    exit 1
fi

for command in git rsync ssh python3; do
    if ! command -v "$command" >/dev/null; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

publish_enabled=$(ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/publish.env'; then echo true; else echo false; fi")
if $publish_enabled; then
    COMPOSE_ARGS="--env-file .env --env-file publish.env -f $COMPOSE_FILE -f docker/compose.publish.yml"
fi

# Preserve the active newsletter gateway configuration when recreating services.
newsletter_enabled=$(ssh "$DEPLOY_HOST" "docker ps --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=newsletter --format '{{.ID}}'")
if [[ -n $newsletter_enabled ]]; then
    COMPOSE_ARGS+=" -f docker/compose.newsletter.yml"
fi
# Keep the evaluator and authenticated history gateway in every later deployment.
monitoring_enabled=$(ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/monitoring.env'; then echo true; else echo false; fi")
if $monitoring_enabled; then
    COMPOSE_ARGS+=" --env-file monitoring.env -f docker/compose.monitoring.yml"
fi
chronicle_enabled=$(ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/chronicle.env'; then echo true; else echo false; fi")
if $chronicle_enabled; then
    COMPOSE_ARGS+=" --env-file chronicle.env -f docker/compose.chronicle.yml --profile chronicle"
fi
monitoring_running=$(ssh "$DEPLOY_HOST" "docker ps --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=incidents --format '{{.ID}}'")
# Keep managed sidecars in the model, including newsletter's search dependency.
COMPOSE_ARGS+=" --profile search --profile ai --profile metrics"

# Render the incoming base Compose file against the host's private environment
# before installing anything or stopping services. A migrated installation must
# never fall back to its old project-scoped WAL volume on the next source sync.
active_volume=$(ssh "$DEPLOY_HOST" "bash -s" <<'REMOTE'
set -euo pipefail
ids=$(docker ps -q --filter label=com.docker.compose.project=docker --filter label=com.docker.compose.service=websocket-server)
[[ -n $ids && $ids != *$'\n'* ]] || { echo "Expected one running websocket-server; cannot verify production storage." >&2; exit 1; }
docker inspect --format '{{range .Mounts}}{{if and (eq .Destination "/app/data") (eq .Type "volume")}}{{.Name}}{{end}}{{end}}' $ids
REMOTE
)
if [[ ! $active_volume =~ ^[a-zA-Z0-9][a-zA-Z0-9_.-]*$ ]]; then
    echo "Refusing to deploy: expected one named production data volume." >&2
    exit 1
fi
candidate_args=${COMPOSE_ARGS/-f $COMPOSE_FILE/--project-directory docker -f -}
candidate_volume=$(ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $candidate_args config --format json" < "$COMPOSE_FILE" |
    python3 -c 'import json, sys
model = json.load(sys.stdin)
mount, = (v for v in model["services"]["websocket-server"]["volumes"] if v["target"] == "/app/data" and v["type"] == "volume")
print(model["volumes"][mount["source"]]["name"])')
if [[ $candidate_volume != "$active_volume" ]]; then
    echo "Refusing to deploy: incoming task-data volume '$candidate_volume' differs from running '$active_volume'." >&2
    echo "Set NRC_TASK_DATA_VOLUME in the host .env to the verified migrated volume; do not switch storage through deploy.sh." >&2
    exit 1
fi
echo "Verified production data volume: $active_volume"

echo "Deploying $head_revision from clean main to $DEPLOY_HOST:$REMOTE_DIR"

# Include current source on both sides and obsolete source only on the receiver.
# The final exclusion protects host-only files (.env, data, etc.) from deletion.
# Earlier deployments did not record a source manifest, so use Git history.
source_filter=$(mktemp)
trap 'rm -f "$source_filter"' EXIT
python3 - > "$source_filter" <<'PY'
import subprocess

def paths(*args):
    return set(filter(None, subprocess.check_output(["git", *args]).split(b"\0")))

current = paths("ls-files", "-z")
historical = paths("log", "HEAD", "--format=", "--name-only", "-z")
all_paths = current | historical
directories = set()
for path in all_paths:
    parts = path.split(b"/")
    directories.update(b"/".join(parts[:i]) for i in range(1, len(parts)))

def rule(prefix, path, suffix=b""):
    # rsync filters are line-based wildmatch patterns, not literal paths.
    if b"\n" in path or b"\r" in path:
        raise SystemExit("Cannot deploy source paths containing newlines")
    for char in (b"\\", b"*", b"?", b"["):
        path = path.replace(char, b"\\" + char)
    print((prefix + b"/" + path + suffix).decode())

for path in sorted(directories):
    rule(b"+ ", path, b"/")
for path in sorted(current):
    rule(b"+ ", path)
for path in sorted(historical - current):
    rule(b"+r ", path)
print("- *")
PY

sync_source() {
    rsync -rlt --delete --filter="merge $source_filter" "$@" ./ "$DEPLOY_HOST:$REMOTE_DIR/"
}

source_changes() {
    # Protected host files can keep an obsolete directory nonempty. Only file
    # changes matter for rebuild selection and parity, not those directories.
    sync_source -cn --out-format='%n' |
        sed 's/^deleting //; /^cannot delete non-empty directory: /d; /\/$/d; /^$/d'
}

changed_output=$(source_changes)
mapfile -t changed_files < <(printf '%s\n' "$changed_output" | sed '/^$/d')

if $full; then
    echo "Deployment mode: full stack"
elif ((${#changed_files[@]} == 0)); then
    echo "Production source matches; checking running images."
else
    printf 'Changed tracked files:\n'
    printf '  %s\n' "${changed_files[@]}"
fi

server=false
search=false
ai=false
metrics=false
tailscale=false
client=false
nginx=false
compose=false
protocol_go=false
publish=false
newsletter=false
incidents=false

if $full; then
    server=true
    search=true
    ai=true
    metrics=true
    tailscale=true
    client=true
    nginx=true
    compose=true
    protocol_go=true
    publish=$publish_enabled
    [[ -z $newsletter_enabled ]] || newsletter=true
    incidents=$monitoring_enabled
else
    for path in "${changed_files[@]}"; do
        case "$path" in
            client/*)
                client=true
                nginx=true
                ;;
            docker/nginx/*) nginx=true ;;
            docker/docker-compose.yml)
                compose=true
                server=true
                search=true
                ai=true
                metrics=true
                tailscale=true
                nginx=true
                publish=$publish_enabled
                [[ -z $newsletter_enabled ]] || newsletter=true
                incidents=$monitoring_enabled
                ;;
            docker/compose.publish.yml)
                if $publish_enabled; then
                    publish=true
                    tailscale=true
                    compose=true
                fi
                ;;
            docker/compose.newsletter.yml)
                if [[ -n $newsletter_enabled ]]; then
                    newsletter=true
                    tailscale=true
                    compose=true
                fi
                ;;
            docker/compose.monitoring.yml)
                if $monitoring_enabled; then
                    incidents=true
                    tailscale=true
                    compose=true
                fi
                ;;
            docker/compose.chronicle.yml)
                if $chronicle_enabled; then
                    ai=true
                    compose=true
                fi
                ;;
            docker/Dockerfile | *.odin | nbio/* | byte_pool/* | persistence/* | storage_io/* | websocket/* | protocol/*.odin)
                server=true
                ;;
            protocol-go/*)
                protocol_go=true
                server=true
                search=true
                ai=true
                metrics=true
                publish=$publish_enabled
                [[ -z $newsletter_enabled ]] || newsletter=true
                incidents=$monitoring_enabled
                ;;
            services/bots/nrc-incidents/*) incidents=$monitoring_enabled ;;
            services/bots/nrc-newsletter/*) [[ -z $newsletter_enabled ]] || newsletter=true ;;
            services/bots/nrc-publish/*) publish=$publish_enabled ;;
            services/bots/nrc-search/*) search=true ;;
            services/bots/nrc-ai/*) ai=true ;;
            services/bots/nrc-metrics/*) metrics=true ;;
            services/auth/tailscale-proxy/*) tailscale=true ;;
        esac
    done
fi

# First enablement must also configure the gateway even when the operator has
# already provisioned the overlay for the storage preflight above.
if $monitoring_enabled && [[ -z $monitoring_running ]]; then
    incidents=true
    tailscale=true
    compose=true
fi

services=()
$server && services+=(websocket-server)
$search && services+=(search)
$ai && services+=(ai)
$metrics && services+=(metrics-bot)
$tailscale && services+=(tailscale-proxy)
$nginx && services+=(nginx)
$publish && services+=(publish)
$newsletter && services+=(newsletter)
$incidents && services+=(incidents)
# Chronicle shares the AI image, but never Sullivan's runtime or credentials.
if $ai && $chronicle_enabled; then services+=(chronicle); fi

# Source parity does not imply that containers use the latest built images.
stale_services=$(ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && bash -s" <<'REMOTE'
set -euo pipefail
for id in $(docker ps -q --filter label=com.docker.compose.project=docker); do
    ref=$(docker inspect --format '{{.Config.Image}}' "$id")
    running=$(docker inspect --format '{{.Image}}' "$id")
    built=$(docker image inspect --format '{{.Id}}' "$ref")
    if [[ $running != "$built" ]]; then
        docker inspect --format '{{index .Config.Labels "com.docker.compose.service"}}' "$id"
    fi
done
REMOTE
)
update_services=("${services[@]}")
while IFS= read -r service; do
    [[ -n $service ]] || continue
    if [[ " ${update_services[*]} " != *" $service "* ]]; then
        update_services+=("$service")
    fi
done <<< "$stale_services"

if ((${#services[@]})); then
    printf 'Services to rebuild: %s\n' "${services[*]}"
else
    echo "No image rebuild is required."
fi
printf 'Services to update: %s\n' "${update_services[*]}"

if ! $full && ((${#changed_files[@]} == 0 && ${#update_services[@]} == 0)); then
    echo "Production source and running images are current; nothing to deploy."
    exit 0
fi

if $dry_run; then
    sync_source -nv
    echo "Dry run complete; production was not changed."
    exit 0
fi

if ! $skip_tests; then
    # Validate the backup installed below before it can stop production services.
    python3 test/test_backup.py
    if $server; then
        if [[ ! -x $ODIN_BIN ]]; then
            ODIN_BIN=$(command -v odin || true)
        fi
        if [[ -z $ODIN_BIN ]]; then
            echo "Odin compiler not found; set ODIN_BIN." >&2
            exit 1
        fi
        ODIN_BIN="$ODIN_BIN" ./test/run_odin_tests.sh . -define:ODIN_TEST_LOG_LEVEL=error
        ODIN_BIN="$ODIN_BIN" ./test/run_odin_tests.sh . -define:NRC_SIMULATION=true -define:ODIN_TEST_LOG_LEVEL=error
    fi

    if $client; then
        npm ci --prefix client --no-audit --no-fund
        node --test client/*.test.mjs
        node --check client/service-worker.js
        npm run test:build --prefix client
    fi

    if $protocol_go; then
        (cd protocol-go && go test ./...)
    fi
    if $search; then
        if ldconfig -p 2>/dev/null | grep -q libtokenizers; then
            (cd services/bots/nrc-search && go test ./...)
        else
            echo "Skipping local nrc-search tests: libtokenizers is unavailable; the production image supplies it." >&2
        fi
    fi
    if $ai; then
        (cd services/bots/nrc-ai && go test ./...)
    fi
    if $metrics; then
        (cd services/bots/nrc-metrics && go test ./...)
    fi
    if $tailscale; then
        (cd services/auth/tailscale-proxy && go test ./...)
    fi
    if $publish; then
        (cd services/bots/nrc-publish && go test -race ./... && go vet ./...)
    fi
    if $newsletter; then
        (cd services/bots/nrc-newsletter && go test -race ./... && go vet ./...)
    fi
    if $incidents; then
        (cd services/bots/nrc-incidents && go test -race ./... && go vet ./...)
    fi
else
    echo "WARNING: local tests were explicitly skipped." >&2
fi

if $server || $publish || $newsletter || $incidents; then
    # The backup must understand newly enabled overlays before stopping services.
    ssh "$DEPLOY_HOST" 'set -eu; tmp=$(mktemp); trap '\''rm -f "$tmp"'\'' EXIT; cat > "$tmp"; bash -n "$tmp"; install -m 0750 "$tmp" /usr/local/sbin/nrc-backup' < docker/backup.sh
    echo "Taking a quiesced backup of production volumes..."
    ssh "$DEPLOY_HOST" 'systemctl start nrc-backup.service'
    backup_result=$(ssh "$DEPLOY_HOST" 'systemctl show nrc-backup.service --property=Result --value')
    if [[ $backup_result != success ]]; then
        echo "Production backup failed with result: $backup_result" >&2
        exit 1
    fi
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
echo "Synchronizing tracked source; rollback copies: /root/nrc-deploy-backups/$stamp"
sync_source -pv --backup --backup-dir="/root/nrc-deploy-backups/$stamp"

ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/docker/backup.sh'; then bash -n '$REMOTE_DIR/docker/backup.sh' && install -m 0750 '$REMOTE_DIR/docker/backup.sh' /usr/local/sbin/nrc-backup; fi"
ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS config -q"

if ((${#services[@]})); then
    quoted_services=$(printf ' %q' "${services[@]}")
    ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS build$quoted_services"
fi
if ((${#update_services[@]})); then
    quoted_services=$(printf ' %q' "${update_services[@]}")
    if $compose; then
        ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS up -d$quoted_services"
    else
        ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS up -d --no-deps$quoted_services"
    fi
    ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && bash -s --$quoted_services" <<'REMOTE'
set -euo pipefail
for service in "$@"; do
    ids=$(docker ps -q --filter label=com.docker.compose.project=docker --filter "label=com.docker.compose.service=$service")
    [[ -n $ids ]] || { echo "Service is not running: $service" >&2; exit 1; }
    for id in $ids; do
        ref=$(docker inspect --format '{{.Config.Image}}' "$id")
        running=$(docker inspect --format '{{.Image}}' "$id")
        built=$(docker image inspect --format '{{.Id}}' "$ref")
        [[ $running == "$built" ]] || { echo "Stale image: $service" >&2; exit 1; }
    done
done
REMOTE
fi

if $nginx || $search || $ai || [[ " ${update_services[*]} " == *" search "* ]] || [[ " ${update_services[*]} " == *" ai "* ]]; then
    ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && \
        docker compose $COMPOSE_ARGS exec -T nginx nginx -t && \
        docker compose $COMPOSE_ARGS exec -T nginx nginx -s reload"
fi

echo "Waiting for sidecar health checks..."
ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && \
    for attempt in \$(seq 1 60); do \
        docker compose $COMPOSE_ARGS exec -T search curl -fsS http://localhost:8090/health >/dev/null && \
        docker compose $COMPOSE_ARGS exec -T ai curl -fsS http://localhost:8091/health >/dev/null && \
        curl -fsS http://localhost:8092/health >/dev/null && exit 0; \
        sleep 2; \
    done; \
    exit 1"

if $publish_enabled; then
    ssh "$DEPLOY_HOST" 'curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 2 http://127.0.0.1:8093/health'
fi
if [[ -n $newsletter_enabled ]]; then
    ssh "$DEPLOY_HOST" 'curl --fail --silent --show-error --retry 30 --retry-connrefused --retry-delay 2 http://127.0.0.1:8097/health'
fi

source_changes | \
    if read -r mismatch; then
        echo "Tracked-source parity check failed; first mismatch: $mismatch" >&2
        exit 1
    fi

ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && \
    docker compose $COMPOSE_ARGS ps && \
    ! docker compose $COMPOSE_ARGS logs --since=10m websocket-server | \
        grep -E '(ERROR|FATAL|EINVAL|ENOBUFS|corrupt)'"

if [[ -n ${NRC_CLI:-} ]]; then
    nrc_cli=$NRC_CLI
elif [[ -x ./cli/nrc ]]; then
    nrc_cli=./cli/nrc
else
    nrc_cli=$(command -v nrc || true)
fi
if [[ -z $nrc_cli ]]; then
    echo "A configured NRC CLI is required for the final WebSocket smoke test; set NRC_CLI." >&2
    exit 1
fi
"$nrc_cli" room list >/dev/null

ssh "$DEPLOY_HOST" "printf '%s\n' '$head_revision' > '$REMOTE_DIR/.nrc-deployed-revision'"

echo "Deployment complete: $head_revision"
echo "Source rollback directory: /root/nrc-deploy-backups/$stamp"
