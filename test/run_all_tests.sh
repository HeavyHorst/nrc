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

# Frozen offline importer against the current schema and real Odin parsers.
# The builder is an explicit-file tool; these tests use synthetic sources only.
(
	builder_dir="$(mktemp -d)"
	trap 'rm -rf "$builder_dir"' EXIT
	run cmp workspace_db/schema.sql tools/wal-to-sqlite/schema.sql
	run cmp workspace_db/slice_summaries.sql tools/wal-to-sqlite/slice_summaries.sql
	run cmp workspace_db/slice_incremental.sql tools/wal-to-sqlite/slice_incremental.sql
	run cmp workspace_db/slice_pagination.sql tools/wal-to-sqlite/slice_pagination.sql
	run cmp workspace_db/monitoring.sql tools/wal-to-sqlite/monitoring.sql
	run cmp workspace_db/chronicle.sql tools/wal-to-sqlite/chronicle.sql
	run cmp workspace_db/chronicle_input_budget.sql tools/wal-to-sqlite/chronicle_input_budget.sql
	run cmp workspace_db/ticket_trigram.sql tools/wal-to-sqlite/ticket_trigram.sql
	run cmp workspace_db/reviews.sql tools/wal-to-sqlite/reviews.sql
	run cmp workspace_db/portal_accounts.sql tools/wal-to-sqlite/portal_accounts.sql
	run "$odin_bin" build . -vet -o:speed -define:NRC_SQLITE_PROJECTION_BUILDER=true -out:"$builder_dir/projection-builder"
	run env NRC_TEST_PROJECTION_BUILDER="$builder_dir/projection-builder" PYTHONDONTWRITEBYTECODE=1 \
		python3 -W error::ResourceWarning -m unittest discover -s tools/wal-to-sqlite -v
)

# Odin subpackages containing tests. Persistence has simulation-specific coverage.
run "$odin_tests" websocket/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" protocol/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" persistence/ "${odin_common[@]}"
run "$odin_tests" persistence/ "${odin_common[@]}" -define:NRC_SIMULATION=true
run "$odin_tests" storage_io/ "${odin_common[@]}"
run "$odin_tests" storage_io/ "${odin_common[@]}" -define:NRC_SIMULATION=true
run "$odin_tests" sqlite/ "${odin_common[@]}"
run "$odin_tests" workspace_db/ "${odin_common[@]}"
run "$odin_tests" btree/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" work_order/ "${odin_common[@]}"
run "$odin_tests" monitoring/ "${odin_common[@]}"
run "$odin_tests" vendor/tlsf/ "${odin_common[@]}"
run "$odin_tests" byte_pool/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" spsc/ "${odin_common[@]}" "${odin_hegel[@]}"
run "$odin_tests" clock/ "${odin_common[@]}"
run "$odin_tests" nbio/ "${odin_common[@]}"
run "$odin_tests" hegel/ "${odin_common[@]}" "${odin_hegel[@]}"
# The fuzz target's own package: it checks that every client opcode is dispatched.
run "$odin_tests" test/protocol_fuzz/ "${odin_common[@]}"
# The fuzz corpus is generated from the protocol serializers; this fails when a
# wire change leaves it stale. It needs Odin only, not the fuzzing toolchain.
run ./test/run_protocol_fuzz.sh --check-seeds

# Go protocol, CLI, and real-process server tests.
run go -C protocol-go test -v -count=1 -timeout=5m ./...
# The AI sidecar reads the same protocol enums as the server: its relation mask
# and its asset names follow the protocol table, so it is tested with it.
# nrc-search is not here: it links libtokenizers, which is not a build
# dependency of this repository.
run go -C services/bots/nrc-ai test -count=1 -timeout=5m ./...
# SQLite telemetry decoding, histogram exposition and worker deduplication.
run go -C services/bots/nrc-metrics test -race -count=1 -timeout=5m ./...
run go -C services/bots/nrc-incidents test -race -count=1 -timeout=5m ./...
# Publication snapshots and the anonymous/private serving boundary.
run go -C services/auth/tailscale-proxy test -race -count=1 -timeout=5m ./...
run go -C services/bots/nrc-publish test -race -count=1 -timeout=5m ./...
# Newsletter consent, durable delivery and Mailjet contract (local fake provider only).
run go -C services/bots/nrc-newsletter test -race -count=1 -timeout=5m ./...
run go -C services/bots/nrc-tickets test -race -count=1 -timeout=5m ./...
run go -C services/calls test -race -count=1 -timeout=5m ./...
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
run env NRC_CHRONICLE_CLIENT_ACCEPTANCE=1 go -C test/e2e test -v -count=1 -timeout=5m -run '^TestChronicleFakeWorkerProcess$' .
run node services/bots/nrc-publish/browser.e2e.mjs
run node services/bots/nrc-tickets/browser.e2e.mjs
run node services/bots/nrc-tickets/reviews.browser.e2e.mjs
run node client/build/production.e2e.mjs
run env ODIN_BIN="$odin_bin" node client/command-palette.e2e.mjs
run node client/virtual-list.e2e.mjs
run node client/entity-tables.e2e.mjs
run node client/dialog.e2e.mjs
run node client/attachment-list.e2e.mjs
run node client/file-details.e2e.mjs
run node client/custom-select.e2e.mjs
run node client/link-picker.e2e.mjs
run node client/page-loader.e2e.mjs
run node client/slices-keyboard.e2e.mjs
run node client/slice-filters.e2e.mjs
run node client/task-status.e2e.mjs
run node client/task-assignee.e2e.mjs
run node client/task-description.e2e.mjs
run node client/note-surfaces.e2e.mjs
run node client/note-html.e2e.mjs
run node client/record-document.e2e.mjs
run node client/mobile-shell.e2e.mjs
run node client/subsystems.e2e.mjs
run node client/reminder-notify.e2e.mjs
run node client/attention.e2e.mjs
run node client/overview.e2e.mjs
run node client/history.e2e.mjs
run node client/chronicle.e2e.mjs
run node client/newsletter.e2e.mjs
run node client/calls.e2e.mjs
run node client/appointments.e2e.mjs

printf '\nAll test suites passed.\n'
