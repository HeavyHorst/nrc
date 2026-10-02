#!/usr/bin/env bash

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

export ODIN_BIN="${ODIN_BIN:-odin}"
odin_bin="$ODIN_BIN"
odin_tests="$repo_root/test/run_odin_tests.sh"
odin_common=(-o:speed -define:ODIN_TEST_LOG_LEVEL=error)
odin_hegel=(-define:HEGEL_REQUIRED=true)

run() {
	printf '\n==> '
	printf '%q ' "$@"
	printf '\n'
	"$@"
}

# Local verification runners (unit tests only; no campaigns or mutations).
run env PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test -p 'test_*.py'

# Main package in both production and deterministic-simulation configurations.
run "$odin_tests" . "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" . "${odin_common[@]}" -define:NRC_SIMULATION=true "${odin_hegel[@]}"

# Odin subpackages containing tests. Persistence has simulation-specific coverage.
run "$odin_tests" websocket/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" protocol/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" persistence/ "${odin_common[@]}"
run "$odin_tests" persistence/ "${odin_common[@]}" -define:NRC_SIMULATION=true
run "$odin_tests" storage_io/ "${odin_common[@]}"
run "$odin_tests" storage_io/ "${odin_common[@]}" -define:NRC_SIMULATION=true
run "$odin_tests" btree/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" byte_pool/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" spsc/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" ulid/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" nbio/ "${odin_common[@]}"
run "$odin_tests" hegel/ "${odin_common[@]}" "${odin_hegel[@]}"

# Go protocol, CLI, and real-process server tests.
run go -C protocol-go test -v -count=1 -timeout=5m ./...
# The AI sidecar reads the same protocol enums as the server: its relation mask
# and its asset names follow the protocol table, so it is tested with it.
# nrc-search is not here: it links libtokenizers, which is not a build
# dependency of this repository.
run go -C services/bots/nrc-ai test -count=1 -timeout=5m ./...
# Publication snapshots and the anonymous/private serving boundary.
run go -C services/auth/tailscale-proxy test -race -count=1 -timeout=5m ./...
run go -C services/bots/nrc-publish test -race -count=1 -timeout=5m ./...
# The CLI's own unit tests. Its end-to-end tests are opt-in behind
# NRC_CUSTOMER_CLI_TEST_URL and skip when that is unset.
run go -C cli test -count=1 -timeout=5m ./...
run go -C test/e2e mod download
run go -C test/e2e test -v -count=1 -timeout=15m .

# Client unit tests also import build dependencies such as acorn.
run npm ci --prefix client
run node --test client/*.test.mjs

# Production client CSS/font build and generated service-worker contract.
run npm run test:build --prefix client
run npm run build --prefix client

# Browser E2E. This requires Playwright and its Chromium browser to be installed.
run node services/bots/nrc-publish/browser.e2e.mjs
run node client/build/production.e2e.mjs
run env ODIN_BIN="$odin_bin" node client/command-palette.e2e.mjs
run node client/virtual-list.e2e.mjs
run node client/entity-tables.e2e.mjs
run node client/dialog.e2e.mjs
run node client/attachment-list.e2e.mjs
run node client/custom-select.e2e.mjs
run node client/link-picker.e2e.mjs
run node client/page-loader.e2e.mjs
run node client/slices-keyboard.e2e.mjs
run node client/slice-filters.e2e.mjs
run node client/task-status.e2e.mjs
run node client/task-assignee.e2e.mjs
run node client/note-surfaces.e2e.mjs
run node client/record-document.e2e.mjs
run node client/mobile-shell.e2e.mjs
run node client/reminder-notify.e2e.mjs
run node client/attention.e2e.mjs

printf '\nAll test suites passed.\n'
