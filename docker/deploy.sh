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

for command in git rsync ssh; do
    if ! command -v "$command" >/dev/null; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

publish_enabled=$(ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/publish.env'; then echo true; else echo false; fi")
if $publish_enabled; then
    COMPOSE_ARGS="--env-file .env --env-file publish.env -f $COMPOSE_FILE -f docker/compose.publish.yml"
fi

echo "Deploying $head_revision from clean main to $DEPLOY_HOST:$REMOTE_DIR"

changed_output=$(git ls-files -z | rsync -rltcn --from0 --files-from=- \
    --out-format='%n' ./ "$DEPLOY_HOST:$REMOTE_DIR/")
mapfile -t changed_files < <(printf '%s\n' "$changed_output" | sed '/\/$/d; /^$/d')

if $full; then
    echo "Deployment mode: full stack"
elif ((${#changed_files[@]} == 0)); then
    echo "Production already matches all tracked files; nothing to deploy."
    exit 0
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
                ;;
            docker/compose.publish.yml)
                if $publish_enabled; then
                    publish=true
                    tailscale=true
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
                ;;
            services/bots/nrc-publish/*) publish=$publish_enabled ;;
            services/bots/nrc-search/*) search=true ;;
            services/bots/nrc-ai/*) ai=true ;;
            services/bots/nrc-metrics/*) metrics=true ;;
            services/auth/tailscale-proxy/*) tailscale=true ;;
        esac
    done
fi

services=()
$server && services+=(websocket-server)
$search && services+=(search)
$ai && services+=(ai)
$metrics && services+=(metrics-bot)
$tailscale && services+=(tailscale-proxy)
$nginx && services+=(nginx)
$publish && services+=(publish)

if ((${#services[@]})); then
    printf 'Services to rebuild: %s\n' "${services[*]}"
else
    echo "No image rebuild is required."
fi

if $dry_run; then
    git ls-files -z | rsync -anv --from0 --files-from=- ./ "$DEPLOY_HOST:$REMOTE_DIR/"
    echo "Dry run complete; production was not changed."
    exit 0
fi

if ! $skip_tests; then
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
        python3 -m unittest test.test_publish_compose -v
    fi
else
    echo "WARNING: local tests were explicitly skipped." >&2
fi

if $server || $publish; then
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
git ls-files -z | rsync -av --from0 --files-from=- \
    --backup --backup-dir="/root/nrc-deploy-backups/$stamp" \
    ./ "$DEPLOY_HOST:$REMOTE_DIR/"

ssh "$DEPLOY_HOST" "if test -f '$REMOTE_DIR/docker/backup.sh'; then bash -n '$REMOTE_DIR/docker/backup.sh' && install -m 0750 '$REMOTE_DIR/docker/backup.sh' /usr/local/sbin/nrc-backup; fi"
ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS config -q"

if ((${#services[@]})); then
    quoted_services=$(printf ' %q' "${services[@]}")
    ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS build$quoted_services"
    if $compose; then
        ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS up -d"
    else
        ssh "$DEPLOY_HOST" "cd '$REMOTE_DIR' && docker compose $COMPOSE_ARGS up -d --no-deps$quoted_services"
    fi
fi

if $nginx || $search || $ai; then
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

git ls-files -z | rsync -anrc --from0 --files-from=- \
    --out-format='%n' ./ "$DEPLOY_HOST:$REMOTE_DIR/" | \
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
