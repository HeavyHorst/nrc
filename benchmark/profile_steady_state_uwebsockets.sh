#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

DEFAULT_OUT_DIR="$ROOT_DIR/.amp/in/artifacts/perf"
OUT_DIR="$DEFAULT_OUT_DIR"

SERVER_PID=""
SERVER_URL="ws://127.0.0.1:8082"

USERS=2000
WORKSPACES=1
CONVERSATIONS=10
CONVS_PER_USER=3

AUTH=true
RAMP_UP="15s"
BENCH_DURATION="75s"
MSG_INTERVAL="1s"
MSG_SIZE=128
FANOUT_SAMPLE_RATE=0

PROFILE_DELAY_SECS=20
PROFILE_DURATION_SECS=30

CAPTURE_LLC_PROFILE=true
CAPTURE_MEM_PROFILE=true
LLC_EVENT="cpu_core/LLC-load-misses/u"

# CPU affinity for benchmark tool
BENCH_CORES=""

usage() {
    cat <<EOF
Steady-state profiler for uWebSockets single-core benchmarking.

Usage:
  $0 --server-pid <pid> [options]

Required:
  --server-pid <pid>           PID of running uWebSockets server process

Options:
  --server <url>               Benchmark target URL (default: $SERVER_URL)
  --users <n>                  Concurrent users (default: $USERS)
  --workspaces <n>             Workspace count (default: $WORKSPACES)
  --conversations <n>          Conversations per workspace (default: $CONVERSATIONS)
  --convs-per-user <n>         Conversations per user (default: $CONVS_PER_USER)
  --auth | --no-auth           Enable/disable auth header (default: --auth)
  --ramp-up <duration>         Ramp duration (default: $RAMP_UP)
  --duration <duration>        Total benchmark duration (default: $BENCH_DURATION)
  --msg-interval <duration>    Message interval per user (default: $MSG_INTERVAL)
  --msg-size <bytes>           Message size in bytes (default: $MSG_SIZE)
  --fanout-sample-rate <n>     Sample every N NEW messages for fanout lag (default: $FANOUT_SAMPLE_RATE, 0 disables)
  --profile-delay <secs>       Seconds after benchmark start to begin perf (default: $PROFILE_DELAY_SECS)
  --profile-duration <secs>    Perf capture duration in seconds (default: $PROFILE_DURATION_SECS)
  --llc-event <event>          perf event for cache-miss stack sampling (default: $LLC_EVENT)
  --no-llc-profile             Disable LLC-miss perf record capture
  --no-mem-profile             Disable perf mem capture/report generation
  --out-dir <path>             Output directory (default: $OUT_DIR)
  --bench-cores <cores>        CPU cores for benchmark
  -h, --help                   Show help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server-pid)
            SERVER_PID="$2"
            shift 2
            ;;
        --server)
            SERVER_URL="$2"
            shift 2
            ;;
        --users)
            USERS="$2"
            shift 2
            ;;
        --workspaces)
            WORKSPACES="$2"
            shift 2
            ;;
        --conversations)
            CONVERSATIONS="$2"
            shift 2
            ;;
        --convs-per-user)
            CONVS_PER_USER="$2"
            shift 2
            ;;
        --auth)
            AUTH=true
            shift
            ;;
        --no-auth)
            AUTH=false
            shift
            ;;
        --ramp-up)
            RAMP_UP="$2"
            shift 2
            ;;
        --duration)
            BENCH_DURATION="$2"
            shift 2
            ;;
        --msg-interval)
            MSG_INTERVAL="$2"
            shift 2
            ;;
        --msg-size)
            MSG_SIZE="$2"
            shift 2
            ;;
        --fanout-sample-rate)
            FANOUT_SAMPLE_RATE="$2"
            shift 2
            ;;
        --profile-delay)
            PROFILE_DELAY_SECS="$2"
            shift 2
            ;;
        --profile-duration)
            PROFILE_DURATION_SECS="$2"
            shift 2
            ;;
        --llc-event)
            LLC_EVENT="$2"
            shift 2
            ;;
        --no-llc-profile)
            CAPTURE_LLC_PROFILE=false
            shift
            ;;
        --no-mem-profile)
            CAPTURE_MEM_PROFILE=false
            shift
            ;;
        --out-dir)
            OUT_DIR="$2"
            shift 2
            ;;
        --bench-cores)
            BENCH_CORES="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$SERVER_PID" ]]; then
    echo "--server-pid is required" >&2
    usage
    exit 1
fi

if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "Server PID $SERVER_PID is not running" >&2
    exit 1
fi

if ! command -v perf >/dev/null 2>&1; then
    echo "perf not found in PATH" >&2
    exit 1
fi

if [[ "$AUTH" == true ]]; then
    AUTH_FLAG="-auth"
else
    AUTH_FLAG=""
fi

mkdir -p "$OUT_DIR"
STAMP="$(date +%Y%m%d-%H%M%S)"
RUN_DIR="$OUT_DIR/steady-uwebsockets-$STAMP"
mkdir -p "$RUN_DIR"

BENCH_LOG="$RUN_DIR/benchmark.log"
PERF_STAT_OUT="$RUN_DIR/perf-stat.txt"
PERF_DATA_OUT="$RUN_DIR/perf.data"
PERF_SCRIPT_OUT="$RUN_DIR/perf.script"
PERF_LLC_DATA_OUT="$RUN_DIR/perf-llc.data"
PERF_LLC_SCRIPT_OUT="$RUN_DIR/perf-llc.script"
PERF_LLC_REPORT_OUT="$RUN_DIR/perf-llc.report.txt"
PERF_LLC_LOG_OUT="$RUN_DIR/perf-llc.log"
PERF_LLC_STATUS_OUT="$RUN_DIR/perf-llc.status.txt"
PERF_MEM_DATA_OUT="$RUN_DIR/perf-mem.data"
PERF_MEM_REPORT_OUT="$RUN_DIR/perf-mem.report.txt"
PERF_MEM_LOG_OUT="$RUN_DIR/perf-mem.log"
PERF_MEM_STATUS_OUT="$RUN_DIR/perf-mem.status.txt"
META_OUT="$RUN_DIR/run-meta.txt"

BENCH_BIN="$SCRIPT_DIR/uwebsockets-bench"

cat > "$META_OUT" <<EOF
timestamp=$STAMP
server_pid=$SERVER_PID
server_url=$SERVER_URL
users=$USERS
workspaces=$WORKSPACES
conversations=$CONVERSATIONS
convs_per_user=$CONVS_PER_USER
auth=$AUTH
ramp_up=$RAMP_UP
duration=$BENCH_DURATION
msg_interval=$MSG_INTERVAL
msg_size=$MSG_SIZE
fanout_sample_rate=$FANOUT_SAMPLE_RATE
profile_delay_secs=$PROFILE_DELAY_SECS
profile_duration_secs=$PROFILE_DURATION_SECS
capture_llc_profile=$CAPTURE_LLC_PROFILE
capture_mem_profile=$CAPTURE_MEM_PROFILE
llc_event=$LLC_EVENT
EOF

BENCH_CMD=(
    "$BENCH_BIN"
    "-server=$SERVER_URL"
    "$AUTH_FLAG"
    "-users=$USERS"
    "-workspaces=$WORKSPACES"
    "-conversations=$CONVERSATIONS"
    "-convs-per-user=$CONVS_PER_USER"
    "-duration=$BENCH_DURATION"
    "-ramp-up=$RAMP_UP"
    "-msg-interval=$MSG_INTERVAL"
    "-msg-size=$MSG_SIZE"
    "-fanout-sample-rate=$FANOUT_SAMPLE_RATE"
)

echo "Run directory: $RUN_DIR"

# Apply CPU affinity to benchmark if specified
if [[ -n "$BENCH_CORES" ]]; then
    echo "Pinning benchmark tool to CPU cores: $BENCH_CORES"
fi

echo "Starting uWebSockets benchmark..."

if [[ -n "$BENCH_CORES" ]]; then
    taskset -c "$BENCH_CORES" "${BENCH_CMD[@]}" > "$BENCH_LOG" 2>&1 &
else
    "${BENCH_CMD[@]}" > "$BENCH_LOG" 2>&1 &
fi
BENCH_PID=$!

cleanup() {
    if kill -0 "$BENCH_PID" 2>/dev/null; then
        kill "$BENCH_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

echo "Waiting ${PROFILE_DELAY_SECS}s before steady-state perf capture..."
sleep "$PROFILE_DELAY_SECS"

if ! kill -0 "$BENCH_PID" 2>/dev/null; then
    echo "Benchmark process exited before perf capture window" >&2
    exit 1
fi

echo "Collecting perf stat + perf record for ${PROFILE_DURATION_SECS}s..."
perf stat -d -d -p "$SERVER_PID" -- sleep "$PROFILE_DURATION_SECS" 2> "$PERF_STAT_OUT" &
PERF_STAT_PID=$!

perf record -F 199 -g --call-graph dwarf -p "$SERVER_PID" -o "$PERF_DATA_OUT" -- sleep "$PROFILE_DURATION_SECS" >/dev/null 2>&1 &
PERF_RECORD_PID=$!

PERF_LLC_PID=""
if [[ "$CAPTURE_LLC_PROFILE" == true ]]; then
    echo "Collecting LLC-miss perf record using event '$LLC_EVENT'..."
    (
        if perf record -e "$LLC_EVENT" -g --call-graph dwarf -p "$SERVER_PID" -o "$PERF_LLC_DATA_OUT" -- sleep "$PROFILE_DURATION_SECS" >/dev/null 2> "$PERF_LLC_LOG_OUT"; then
            echo "ok" > "$PERF_LLC_STATUS_OUT"
        else
            echo "failed (see $(basename "$PERF_LLC_LOG_OUT"))" > "$PERF_LLC_STATUS_OUT"
        fi
    ) &
    PERF_LLC_PID=$!
fi

PERF_MEM_PID=""
if [[ "$CAPTURE_MEM_PROFILE" == true ]]; then
    echo "Collecting perf mem profile..."
    (
        if perf mem record -p "$SERVER_PID" -o "$PERF_MEM_DATA_OUT" -- sleep "$PROFILE_DURATION_SECS" >/dev/null 2> "$PERF_MEM_LOG_OUT"; then
            echo "ok" > "$PERF_MEM_STATUS_OUT"
        else
            echo "failed (platform/permissions may not support perf mem; see $(basename "$PERF_MEM_LOG_OUT"))" > "$PERF_MEM_STATUS_OUT"
        fi
    ) &
    PERF_MEM_PID=$!
fi

wait "$PERF_STAT_PID"
wait "$PERF_RECORD_PID"
if [[ -n "$PERF_LLC_PID" ]]; then
    wait "$PERF_LLC_PID"
fi
if [[ -n "$PERF_MEM_PID" ]]; then
    wait "$PERF_MEM_PID"
fi

echo "Converting perf.data to perf script..."
perf script -i "$PERF_DATA_OUT" > "$PERF_SCRIPT_OUT"

if [[ "$CAPTURE_LLC_PROFILE" == true && -s "$PERF_LLC_DATA_OUT" ]]; then
    echo "Converting perf-llc.data to script/report..."
    perf script -i "$PERF_LLC_DATA_OUT" > "$PERF_LLC_SCRIPT_OUT" 2>> "$PERF_LLC_LOG_OUT" || true
    perf report -i "$PERF_LLC_DATA_OUT" --stdio --no-children --sort symbol --percent-limit 0.5 > "$PERF_LLC_REPORT_OUT" 2>> "$PERF_LLC_LOG_OUT" || true
fi

if [[ "$CAPTURE_MEM_PROFILE" == true && -s "$PERF_MEM_DATA_OUT" ]]; then
    echo "Generating perf-mem report..."
    perf mem report -i "$PERF_MEM_DATA_OUT" --stdio > "$PERF_MEM_REPORT_OUT" 2>> "$PERF_MEM_LOG_OUT" || true
fi

echo "Waiting for benchmark completion..."
wait "$BENCH_PID"
trap - EXIT

echo "Done. Artifacts written to: $RUN_DIR"
echo "- $BENCH_LOG"
echo "- $PERF_STAT_OUT"
echo "- $PERF_DATA_OUT"
echo "- $PERF_SCRIPT_OUT"
if [[ -f "$PERF_LLC_STATUS_OUT" ]]; then
    echo "- $PERF_LLC_STATUS_OUT"
fi
if [[ -f "$PERF_LLC_DATA_OUT" ]]; then
    echo "- $PERF_LLC_DATA_OUT"
fi
if [[ -f "$PERF_LLC_SCRIPT_OUT" ]]; then
    echo "- $PERF_LLC_SCRIPT_OUT"
fi
if [[ -f "$PERF_LLC_REPORT_OUT" ]]; then
    echo "- $PERF_LLC_REPORT_OUT"
fi
if [[ -f "$PERF_LLC_LOG_OUT" ]]; then
    echo "- $PERF_LLC_LOG_OUT"
fi
if [[ -f "$PERF_MEM_STATUS_OUT" ]]; then
    echo "- $PERF_MEM_STATUS_OUT"
fi
if [[ -f "$PERF_MEM_DATA_OUT" ]]; then
    echo "- $PERF_MEM_DATA_OUT"
fi
if [[ -f "$PERF_MEM_REPORT_OUT" ]]; then
    echo "- $PERF_MEM_REPORT_OUT"
fi
if [[ -f "$PERF_MEM_LOG_OUT" ]]; then
    echo "- $PERF_MEM_LOG_OUT"
fi
echo "- $META_OUT"
