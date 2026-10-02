#!/usr/bin/env bash
set -euo pipefail

# Prebuild transaction-bench with `go -C benchmark test -c ...`; server must be
# the optimized durable-ACK build. CPU 0 and CPU 2 must be distinct physical cores.
binaries="$(realpath "${1:-/tmp/nrc-group-bench}")"
output="$(realpath -m "${2:-/tmp/nrc-group-bench/transactions}")"
repetitions="${3:-10}"
mkdir -p "$output"
scratch=""
cleanup() {
    amp orb service stop nrc-transaction-benchmark >/dev/null
    if [[ -n "$scratch" ]]; then rm -rf "$scratch"; fi
}
trap cleanup EXIT

for ((rep=0; rep<repetitions; rep++)); do
    for ((offset=0; offset<8; offset++)); do
        case_id=$(((rep + offset) % 8))
        if ((rep % 2)); then case_id=$((7 - case_id)); fi
        # Optional space-separated case IDs, e.g. "6 7" for populated pipeline comparisons.
        if [[ -n "${NRC_TRANSACTION_BENCH_CASES:-}" && " $NRC_TRANSACTION_BENCH_CASES " != *" $case_id "* ]]; then
            continue
        fi
        scratch="$(mktemp -d /tmp/nrc-transaction-bench.XXXXXX)"
        amp orb service start nrc-transaction-benchmark --cwd "$scratch" --port 18089 \
            --command "env NRC_PORT=\$PORT NRC_THREAD_COUNT=1 NRC_DISABLE_CPU_AFFINITY=1 NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret taskset -c 0 '$binaries/durable-1-131072'" >/dev/null
        log="$output/sample-$rep-$case_id.log"
        if ! env NRC_TRANSACTION_BENCH=1 NRC_TRANSACTION_BENCH_CASE="$case_id" \
            NRC_TRANSACTION_BENCH_OUTPUT="$output/sample-$rep-$case_id.json" \
            taskset -c 2 "$binaries/transaction-bench" -test.run '^TestTransactionThroughput$' \
            -test.v -test.timeout=10m >"$log" 2>&1; then
            cat "$log"
            amp orb service logs nrc-transaction-benchmark >"$output/sample-$rep-$case_id-server.log" 2>&1 || true
            exit 1
        fi
        cleanup
        scratch=""
        printf 'repetition %d/%d, case %d: ' "$((rep+1))" "$repetitions" "$case_id"
        grep 'mutations_per_sec' "$log"
    done
done
trap - EXIT
