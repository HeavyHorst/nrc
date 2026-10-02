#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORIGINAL_ARGS=("$@")

A_URL=""
A_LABEL=""
A_PID=""
A_BINARY=""
A_SOURCE_ID=""
A_TOPOLOGY=""
A_BUILD_MANIFEST=""
B_URL=""
B_LABEL=""
B_PID=""
B_BINARY=""
B_SOURCE_ID=""
B_TOPOLOGY=""
B_BUILD_MANIFEST=""
SERVER_CPUS=""
CLIENT_CPUS=""
OUT_DIR=""
PROFILE=""

CONCURRENCY=128
WORKSPACES=48
WARMUP_DURATION="15s"
MEASURE_DURATION="30s"
PAIRS=4

usage() {
  cat <<'EOF'
Usage: benchmark/run_connection_rate_comparison.sh [options]

Required:
  --a-url URL             WebSocket URL for implementation A
  --a-label LABEL         Stable label for implementation A
  --a-pid PID             Running local server PID for A
  --a-binary PATH         Exact server binary used for A
  --a-source-id ID        Immutable source revision/build identity for A
  --a-topology NAME       nrc-one-worker, uws-one-loop, or uws-two-loop
  --b-url URL             WebSocket URL for implementation B
  --b-label LABEL         Stable label for implementation B
  --b-pid PID             Running local server PID for B
  --b-binary PATH         Exact server binary used for B
  --b-source-id ID        Immutable source revision/build identity for B
  --b-topology NAME       nrc-one-worker, uws-one-loop, or uws-two-loop
  --server-cpus LIST      taskset CPU list shared by A and B, for example 2
  --client-cpus LIST      taskset CPU list for the Go generator, for example 4-11
  --out-dir PATH          New directory for all raw results and metadata
  --profile NAME          equal-one-cpu or production-two-cpu

Optional:
  --a-build-manifest PATH Build manifest to archive (required for uWS)
  --b-build-manifest PATH Build manifest to archive (required for uWS)
  --concurrency N         Parallel connection loops (default: 128)
  --workspaces N          Workspace names used by the loops (default: 48)
  --warmup DURATION       Warm-up per implementation (default: 15s)
  --duration DURATION     Duration of each measured run (default: 30s)
  --pairs N               Alternating A/B pairs; use an even value (default: 4)

The runner does not start or stop servers. Both endpoints must already be running with
the same CPU budget and isolated data directories. It pauses the inactive server with
SIGSTOP and resumes it with SIGCONT so both can share the exact server CPU mask without
idle wakeups. Odd pairs run A then B; even pairs run B then A. Every connection performs
JWT/header upgrade, validates ServerReady, completes a normal WebSocket close handshake, and closes TCP.
EOF
}

require_value() {
  if [[ $# -lt 2 || -z "$2" ]]; then
    echo "missing value for $1" >&2
    usage >&2
    exit 2
  fi
}

while [[ $# -gt 0 ]]; do
  if [[ "$1" == --*=* ]]; then
    option_name="${1%%=*}"
    option_value="${1#*=}"
    shift
    set -- "$option_name" "$option_value" "$@"
  fi
  case "$1" in
    --a-url) require_value "$@"; A_URL="$2"; shift 2 ;;
    --a-label) require_value "$@"; A_LABEL="$2"; shift 2 ;;
    --a-pid) require_value "$@"; A_PID="$2"; shift 2 ;;
    --a-binary) require_value "$@"; A_BINARY="$2"; shift 2 ;;
    --a-source-id) require_value "$@"; A_SOURCE_ID="$2"; shift 2 ;;
    --a-topology) require_value "$@"; A_TOPOLOGY="$2"; shift 2 ;;
    --a-build-manifest) require_value "$@"; A_BUILD_MANIFEST="$2"; shift 2 ;;
    --b-url) require_value "$@"; B_URL="$2"; shift 2 ;;
    --b-label) require_value "$@"; B_LABEL="$2"; shift 2 ;;
    --b-pid) require_value "$@"; B_PID="$2"; shift 2 ;;
    --b-binary) require_value "$@"; B_BINARY="$2"; shift 2 ;;
    --b-source-id) require_value "$@"; B_SOURCE_ID="$2"; shift 2 ;;
    --b-topology) require_value "$@"; B_TOPOLOGY="$2"; shift 2 ;;
    --b-build-manifest) require_value "$@"; B_BUILD_MANIFEST="$2"; shift 2 ;;
    --server-cpus) require_value "$@"; SERVER_CPUS="$2"; shift 2 ;;
    --client-cpus) require_value "$@"; CLIENT_CPUS="$2"; shift 2 ;;
    --out-dir) require_value "$@"; OUT_DIR="$2"; shift 2 ;;
    --profile) require_value "$@"; PROFILE="$2"; shift 2 ;;
    --concurrency) require_value "$@"; CONCURRENCY="$2"; shift 2 ;;
    --workspaces) require_value "$@"; WORKSPACES="$2"; shift 2 ;;
    --warmup) require_value "$@"; WARMUP_DURATION="$2"; shift 2 ;;
    --duration) require_value "$@"; MEASURE_DURATION="$2"; shift 2 ;;
    --pairs) require_value "$@"; PAIRS="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for value_name in A_URL A_LABEL A_PID A_BINARY A_SOURCE_ID A_TOPOLOGY B_URL B_LABEL B_PID B_BINARY B_SOURCE_ID B_TOPOLOGY SERVER_CPUS CLIENT_CPUS OUT_DIR PROFILE; do
  if [[ -z "${!value_name}" ]]; then
    echo "missing required option for $value_name" >&2
    usage >&2
    exit 2
  fi
done

if [[ "$PROFILE" != "equal-one-cpu" && "$PROFILE" != "production-two-cpu" ]]; then
  echo "--profile must be equal-one-cpu or production-two-cpu" >&2
  exit 2
fi

for topology_name in "$A_TOPOLOGY" "$B_TOPOLOGY"; do
  case "$topology_name" in
    nrc-one-worker|uws-one-loop|uws-two-loop) ;;
    *) echo "invalid topology: $topology_name" >&2; exit 2 ;;
  esac
done
for source_id in "$A_SOURCE_ID" "$B_SOURCE_ID"; do
  if ! [[ "$source_id" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
    echo "source IDs must be full lowercase 40- or 64-character hexadecimal identities" >&2
    exit 2
  fi
done
if [[ "$PROFILE" == "equal-one-cpu" && ( "$A_TOPOLOGY" == "uws-two-loop" || "$B_TOPOLOGY" == "uws-two-loop" ) ]]; then
  echo "equal-one-cpu does not permit uws-two-loop" >&2
  exit 2
fi
if [[ "$PROFILE" == "production-two-cpu" && ( "$A_TOPOLOGY" == "uws-one-loop" || "$B_TOPOLOGY" == "uws-one-loop" ) ]]; then
  echo "production-two-cpu does not permit uws-one-loop" >&2
  exit 2
fi
for side in A B; do
  topology_var="${side}_TOPOLOGY"
  manifest_var="${side}_BUILD_MANIFEST"
  if [[ "${!topology_var}" == uws-* && -z "${!manifest_var}" ]]; then
    echo "--${side,,}-build-manifest is required for uWebSockets" >&2
    exit 2
  fi
  if [[ -n "${!manifest_var}" && ! -f "${!manifest_var}" ]]; then
    echo "build manifest not found: ${!manifest_var}" >&2
    exit 2
  fi
done

if ! [[ "$CONCURRENCY" =~ ^[1-9][0-9]*$ && "$WORKSPACES" =~ ^[1-9][0-9]*$ && "$PAIRS" =~ ^[1-9][0-9]*$ ]]; then
  echo "--concurrency, --workspaces, and --pairs must be positive integers" >&2
  exit 2
fi
if (( PAIRS % 2 != 0 )); then
  echo "--pairs must be even so A→B and B→A orders are balanced" >&2
  exit 2
fi

for command in go python3 taskset sha256sum; do
  command -v "$command" >/dev/null || { echo "required command not found: $command" >&2; exit 2; }
done
for pid in "$A_PID" "$B_PID"; do
  [[ -d "/proc/$pid" ]] || { echo "server PID is not running: $pid" >&2; exit 2; }
done
for binary in "$A_BINARY" "$B_BINARY"; do
  [[ -f "$binary" ]] || { echo "server binary not found: $binary" >&2; exit 2; }
done
if [[ -e "$OUT_DIR" ]]; then
  echo "output path already exists: $OUT_DIR" >&2
  exit 2
fi

python3 - "$A_URL" "$B_URL" <<'PY'
import sys
import urllib.parse

def endpoint(value):
    parsed = urllib.parse.urlparse(value)
    if parsed.scheme != "ws" or parsed.hostname != "127.0.0.1" or parsed.port is None:
        raise SystemExit("server URLs must use explicit ws://127.0.0.1 ports")
    return parsed.hostname, parsed.port

if endpoint(sys.argv[1]) == endpoint(sys.argv[2]):
    raise SystemExit("A and B URLs must use distinct loopback endpoints")
PY

python3 - "$PROFILE" "$SERVER_CPUS" "$CLIENT_CPUS" <<'PY'
import pathlib
import sys

def parse_cpu_list(value):
    cpus = set()
    for part in value.split(','):
        if '-' in part:
            start, end = map(int, part.split('-', 1))
            cpus.update(range(start, end + 1))
        else:
            cpus.add(int(part))
    return cpus

profile = sys.argv[1]
server = parse_cpu_list(sys.argv[2])
client = parse_cpu_list(sys.argv[3])
expected_count = 1 if profile == "equal-one-cpu" else 2
if len(server) != expected_count:
    raise SystemExit(f"{profile} requires exactly {expected_count} server CPU(s), got {sorted(server)}")

for cpu in server:
    sibling_path = pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list")
    siblings = parse_cpu_list(sibling_path.read_text().strip())
    overlap = siblings & client
    if overlap:
        raise SystemExit(
            f"client CPU mask includes server CPU {cpu} or SMT sibling(s): {sorted(overlap)}"
        )

if profile == "production-two-cpu":
    first, second = sorted(server)
    first_siblings = parse_cpu_list(
        pathlib.Path(f"/sys/devices/system/cpu/cpu{first}/topology/thread_siblings_list").read_text().strip()
    )
    if second in first_siblings:
        raise SystemExit("production-two-cpu requires two physical cores, not SMT siblings")
PY

mkdir -p "$OUT_DIR"
GENERATOR="$OUT_DIR/connection-rate-bench"
(
  cd "$SCRIPT_DIR"
  go build -trimpath -o "$GENERATOR" ./cmd/connection-rate-bench
)

SOURCE_SNAPSHOT="$OUT_DIR/source-snapshot"
mkdir -p "$SOURCE_SNAPSHOT/benchmark/cmd/connection-rate-bench" "$SOURCE_SNAPSHOT/protocol-go"
cp "$BASH_SOURCE" "$SOURCE_SNAPSHOT/benchmark/run_connection_rate_comparison.sh"
cp "$SCRIPT_DIR"/cmd/connection-rate-bench/*.go "$SOURCE_SNAPSHOT/benchmark/cmd/connection-rate-bench/"
cp "$SCRIPT_DIR/go.mod" "$SCRIPT_DIR/go.sum" "$SOURCE_SNAPSHOT/benchmark/"
cp "$ROOT_DIR"/protocol-go/*.go "$SOURCE_SNAPSHOT/protocol-go/"
cp "$ROOT_DIR/protocol-go/go.mod" "$ROOT_DIR/protocol-go/go.sum" "$SOURCE_SNAPSHOT/protocol-go/"
if [[ "$A_TOPOLOGY" == uws-* || "$B_TOPOLOGY" == uws-* ]]; then
  mkdir -p "$SOURCE_SNAPSHOT/benchmark/uwebsockets"
  cp "$SCRIPT_DIR/uwebsockets/server.cpp" "$SCRIPT_DIR/uwebsockets/build-server.sh" \
    "$SOURCE_SNAPSHOT/benchmark/uwebsockets/"
fi
git -C "$ROOT_DIR" diff --binary HEAD >"$SOURCE_SNAPSHOT/working-tree.patch"
(
  cd "$SOURCE_SNAPSHOT"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum
) >"$SOURCE_SNAPSHOT/SHA256SUMS"
{
  printf '%q' "$BASH_SOURCE"
  printf ' %q' "${ORIGINAL_ARGS[@]}"
  printf '\n'
} >"$OUT_DIR/invocation.txt"
if [[ -n "$A_BUILD_MANIFEST" ]]; then
  cp "$A_BUILD_MANIFEST" "$OUT_DIR/a-build-manifest.txt"
fi
if [[ -n "$B_BUILD_MANIFEST" ]]; then
  cp "$B_BUILD_MANIFEST" "$OUT_DIR/b-build-manifest.txt"
fi

verify_process_binary() {
  local label="$1" pid="$2" expected_binary="$3"
  local running_binary expected_hash running_hash
  running_binary="$(readlink -f "/proc/$pid/exe")"
  expected_hash="$(sha256sum "$expected_binary" | awk '{print $1}')"
  running_hash="$(sha256sum "$running_binary" | awk '{print $1}')"
  if [[ "$expected_hash" != "$running_hash" ]]; then
    echo "$label PID $pid does not run the supplied binary" >&2
    echo "expected: $expected_binary ($expected_hash)" >&2
    echo "running:  $running_binary ($running_hash)" >&2
    exit 2
  fi
}

verify_process_binary "$A_LABEL" "$A_PID" "$A_BINARY"
verify_process_binary "$B_LABEL" "$B_PID" "$B_BINARY"

verify_uws_manifest() {
  local label="$1" topology="$2" source_id="$3" manifest="$4" binary="$5" pid="$6"
  [[ "$topology" == uws-* ]] || return 0
  python3 - "$label" "$source_id" "$manifest" "$binary" "$pid" \
    "$SOURCE_SNAPSHOT/benchmark/uwebsockets/server.cpp" <<'PY'
import hashlib
import pathlib
import sys

label, source_id, manifest_path, binary_path, pid, source_path = sys.argv[1:]
required = {"uwebsockets_revision", "server_source_sha256", "binary_sha256"}
values = {key: [] for key in required}
for line in pathlib.Path(manifest_path).read_text().splitlines():
    if "=" not in line:
        continue
    key, value = line.split("=", 1)
    if key in values:
        values[key].append(value)
for key, matches in values.items():
    if len(matches) != 1:
        raise SystemExit(f"server {label} manifest must contain exactly one {key}")

def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()

if values["uwebsockets_revision"][0] != source_id:
    raise SystemExit(f"server {label} source ID does not match its uWS manifest")
expected_binary_hash = values["binary_sha256"][0]
if sha256(binary_path) != expected_binary_hash or sha256(f"/proc/{pid}/exe") != expected_binary_hash:
    raise SystemExit(f"server {label} binary does not match its uWS manifest")
if sha256(source_path) != values["server_source_sha256"][0]:
    raise SystemExit(f"server {label} server.cpp does not match its uWS manifest")
PY
}

verify_uws_manifest "$A_LABEL" "$A_TOPOLOGY" "$A_SOURCE_ID" "$OUT_DIR/a-build-manifest.txt" \
  "$A_BINARY" "$A_PID"
verify_uws_manifest "$B_LABEL" "$B_TOPOLOGY" "$B_SOURCE_ID" "$OUT_DIR/b-build-manifest.txt" \
  "$B_BINARY" "$B_PID"

process_start_time() {
  python3 - "$1" <<'PY'
import pathlib
import sys

raw = pathlib.Path(f"/proc/{sys.argv[1]}/stat").read_text()
print(raw[raw.rfind(")") + 2:].split()[19])
PY
}

A_START_TIME="$(process_start_time "$A_PID")"
B_START_TIME="$(process_start_time "$B_PID")"

signal_pid() {
  local pid="$1" expected_start="$2" signal_name="$3"
  python3 - "$pid" "$expected_start" "$signal_name" <<'PY'
import os
import pathlib
import signal
import sys

pid = int(sys.argv[1])
expected_start = sys.argv[2]
pidfd = os.pidfd_open(pid)
try:
    raw = pathlib.Path(f"/proc/{pid}/stat").read_text()
    actual_start = raw[raw.rfind(")") + 2:].split()[19]
    if actual_start != expected_start:
        raise SystemExit(f"PID {pid} identity changed; refusing to signal it")
    signal.pidfd_send_signal(pidfd, getattr(signal, f"SIG{sys.argv[3]}"))
finally:
    os.close(pidfd)
PY
}

validate_side_runtime() {
  local label="$1" pid="$2" expected_start="$3" url="$4" topology="$5"
  python3 - "$label" "$pid" "$expected_start" "$url" "$topology" "$PROFILE" "$SERVER_CPUS" <<'PY'
import os
import pathlib
import sys
import urllib.parse

label, pid, expected_start, url, topology, profile, cpu_list = sys.argv[1:]
proc = pathlib.Path(f"/proc/{pid}")

def parse_cpu_list(value):
    cpus = set()
    for part in value.split(","):
        if "-" in part:
            start, end = map(int, part.split("-", 1))
            cpus.update(range(start, end + 1))
        else:
            cpus.add(int(part))
    return cpus

def start_time():
    raw = (proc / "stat").read_text()
    return raw[raw.rfind(")") + 2:].split()[19]

if start_time() != expected_start:
    raise SystemExit(f"server {label} PID identity changed")

server = parse_cpu_list(cpu_list)

def allowed_cpus(tid):
    status = pathlib.Path(f"/proc/{tid}/status").read_text()
    for line in status.splitlines():
        if line.startswith("Cpus_allowed_list:"):
            return parse_cpu_list(line.split(":", 1)[1].strip())
    raise SystemExit(f"Cpus_allowed_list missing for TID {tid}")

tids = sorted(path.name for path in (proc / "task").iterdir())
masks = {tid: allowed_cpus(tid) for tid in tids}
outside = [(tid, sorted(mask - server)) for tid, mask in masks.items() if mask - server]
if outside:
    raise SystemExit(f"server {label} thread affinity escapes {sorted(server)}: {outside}")
union = set().union(*masks.values())
if union != server:
    rendered = [(tid, sorted(mask)) for tid, mask in masks.items()]
    raise SystemExit(f"server {label} does not cover CPU budget {sorted(server)}; masks={rendered}")

environment = {}
for entry in (proc / "environ").read_bytes().split(b"\0"):
    if b"=" in entry:
        key, value = entry.split(b"=", 1)
        environment[key.decode(errors="replace")] = value.decode(errors="replace")

if topology.startswith("uws-"):
    expected_workers = 1 if topology == "uws-one-loop" else 2
    if environment.get("UWS_THREAD_COUNT", "1") != str(expected_workers):
        raise SystemExit(f"server {label} UWS_THREAD_COUNT does not match {topology}")
    worker_tids = [tid for tid in tids if tid != pid]
    if len(worker_tids) != expected_workers:
        raise SystemExit(f"server {label} expected {expected_workers} uWS worker TIDs, got {worker_tids}")
    worker_masks = [masks[tid] for tid in worker_tids]
    if any(len(mask) != 1 for mask in worker_masks) or set().union(*worker_masks) != server:
        raise SystemExit(f"server {label} uWS workers must be pinned one per core: {worker_masks}")
    expected_listeners = expected_workers
else:
    if environment.get("NRC_THREAD_COUNT") != "1":
        raise SystemExit(f"server {label} must set NRC_THREAD_COUNT=1")
    affinity_disabled = environment.get("NRC_DISABLE_CPU_AFFINITY", "").lower() in {"1", "true", "yes"}
    if profile == "equal-one-cpu" and not affinity_disabled:
        raise SystemExit(f"server {label} must set NRC_DISABLE_CPU_AFFINITY=1")
    if profile == "production-two-cpu":
        if affinity_disabled:
            raise SystemExit(f"server {label} must enable topology-aware affinity")
        try:
            service_cpu = int(environment["NRC_SERVICE_CPU"])
        except (KeyError, ValueError):
            raise SystemExit(f"server {label} must set a valid NRC_SERVICE_CPU")
        if service_cpu not in server:
            raise SystemExit(f"server {label} NRC_SERVICE_CPU is outside the server CPU budget")
        singleton_union = set().union(*(mask for mask in masks.values() if len(mask) == 1))
        if singleton_union != server:
            raise SystemExit(f"server {label} NRC roles are not pinned across both cores: {masks}")
    expected_listeners = 1

parsed = urllib.parse.urlparse(url)
if parsed.scheme != "ws" or parsed.hostname != "127.0.0.1" or parsed.port is None:
    raise SystemExit(f"server {label} URL must use an explicit ws://127.0.0.1 port")

table = "/proc/net/tcp"
accepted_addresses = {"0100007F", "00000000"}

listen_inodes = set()
for line in pathlib.Path(table).read_text().splitlines()[1:]:
    fields = line.split()
    address, port = fields[1].split(":")
    if fields[3] == "0A" and address in accepted_addresses and int(port, 16) == parsed.port:
        listen_inodes.add(fields[9])
owned_inodes = set()
for fd in (proc / "fd").iterdir():
    try:
        target = os.readlink(fd)
    except FileNotFoundError:
        continue
    if target.startswith("socket:["):
        owned_inodes.add(target[8:-1])
owned_listeners = listen_inodes & owned_inodes
if listen_inodes != owned_listeners or len(owned_listeners) != expected_listeners:
    raise SystemExit(
        f"server {label} endpoint is not exclusively owned: expected {expected_listeners}, "
        f"endpoint has {len(listen_inodes)}, process owns {len(owned_listeners)}"
    )
PY
}

validate_side_runtime "$A_LABEL" "$A_PID" "$A_START_TIME" "$A_URL" "$A_TOPOLOGY"
validate_side_runtime "$B_LABEL" "$B_PID" "$B_START_TIME" "$B_URL" "$B_TOPOLOGY"

resume_servers() {
  signal_pid "$A_PID" "$A_START_TIME" CONT 2>/dev/null || true
  signal_pid "$B_PID" "$B_START_TIME" CONT 2>/dev/null || true
}
trap resume_servers EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

activate_side() {
  local side="$1"
  if [[ "$side" == A ]]; then
    signal_pid "$B_PID" "$B_START_TIME" STOP
    signal_pid "$A_PID" "$A_START_TIME" CONT
  else
    signal_pid "$A_PID" "$A_START_TIME" STOP
    signal_pid "$B_PID" "$B_START_TIME" CONT
  fi
  sleep 0.2
  if [[ "$side" == A ]]; then
    validate_side_runtime "$A_LABEL" "$A_PID" "$A_START_TIME" "$A_URL" "$A_TOPOLOGY"
  else
    validate_side_runtime "$B_LABEL" "$B_PID" "$B_START_TIME" "$B_URL" "$B_TOPOLOGY"
  fi
}

capture_process_metadata() {
  local label="$1" pid="$2"
  python3 - "$label" "$pid" <<'PY'
import os
import pathlib
import shlex
import sys

label, pid = sys.argv[1:]
proc = pathlib.Path(f"/proc/{pid}")
safe_environment = {
    "AUTH_ENABLED",
    "NRC_DISABLE_CPU_AFFINITY",
    "NRC_PORT",
    "NRC_SERVICE_CPU",
    "NRC_THREAD_COUNT",
    "PORT",
    "UWS_THREAD_COUNT",
}
environment = {}
for entry in (proc / "environ").read_bytes().split(b"\0"):
    if b"=" in entry:
        key, value = entry.split(b"=", 1)
        key = key.decode(errors="replace")
        if key in safe_environment:
            environment[key] = value.decode(errors="replace")

print(f"server_{label}_process_begin")
print("cmdline=" + shlex.join(part.decode(errors="replace") for part in (proc / "cmdline").read_bytes().split(b"\0") if part))
print("cwd=" + os.readlink(proc / "cwd"))
for key in sorted(environment):
    print(f"env.{key}={environment[key]}")
for task in sorted((proc / "task").iterdir(), key=lambda path: int(path.name)):
    status = (task / "status").read_text().splitlines()
    allowed = next(line.split(":", 1)[1].strip() for line in status if line.startswith("Cpus_allowed_list:"))
    name = next(line.split(":", 1)[1].strip() for line in status if line.startswith("Name:"))
    print(f"thread tid={task.name} name={name} cpus_allowed={allowed}")
print("limits_begin")
print((proc / "limits").read_text(), end="")
print("limits_end")
print(f"server_{label}_process_end")
PY
}

{
  echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "repository=$ROOT_DIR"
  echo "git_head=$(git -C "$ROOT_DIR" rev-parse HEAD)"
  echo "git_status_begin"
  git -C "$ROOT_DIR" status --short
  echo "git_status_end"
  echo "go_version=$(go version)"
  echo "odin_version=$(odin version 2>&1 || true)"
  echo "cxx_version=$(${CXX:-g++} --version 2>/dev/null | head -1 || true)"
  echo "kernel=$(uname -a)"
  echo "kernel_cmdline=$(cat /proc/cmdline)"
  echo "loadavg=$(cat /proc/loadavg)"
  echo "profile=$PROFILE"
  echo "server_cpus=$SERVER_CPUS"
  echo "client_cpus=$CLIENT_CPUS"
  echo "a_label=$A_LABEL"
  echo "a_url=$A_URL"
  echo "a_pid=$A_PID"
  echo "a_binary=$A_BINARY"
  echo "a_binary_sha256=$(sha256sum "$A_BINARY" | awk '{print $1}')"
  echo "a_source_id=$A_SOURCE_ID"
  echo "a_topology=$A_TOPOLOGY"
  [[ -z "$A_BUILD_MANIFEST" ]] || echo "a_build_manifest_sha256=$(sha256sum "$OUT_DIR/a-build-manifest.txt" | awk '{print $1}')"
  echo "b_label=$B_LABEL"
  echo "b_url=$B_URL"
  echo "b_pid=$B_PID"
  echo "b_binary=$B_BINARY"
  echo "b_binary_sha256=$(sha256sum "$B_BINARY" | awk '{print $1}')"
  echo "b_source_id=$B_SOURCE_ID"
  echo "b_topology=$B_TOPOLOGY"
  [[ -z "$B_BUILD_MANIFEST" ]] || echo "b_build_manifest_sha256=$(sha256sum "$OUT_DIR/b-build-manifest.txt" | awk '{print $1}')"
  echo "generator_sha256=$(sha256sum "$GENERATOR" | awk '{print $1}')"
  echo "concurrency=$CONCURRENCY"
  echo "workspaces=$WORKSPACES"
  echo "warmup_duration=$WARMUP_DURATION"
  echo "measure_duration=$MEASURE_DURATION"
  echo "pairs=$PAIRS"
  echo "lscpu_begin"
  lscpu
  echo "lscpu_end"
  echo "cpu_layout_begin"
  lscpu -e=CPU,CORE,SOCKET,NODE,MAXMHZ,MINMHZ,ONLINE
  echo "cpu_layout_end"
  echo "governors_begin"
  cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null || true
  echo "governors_end"
  echo "no_turbo=$(cat /sys/devices/system/cpu/intel_pstate/no_turbo 2>/dev/null || true)"
  echo "sysctls_begin"
  for setting in \
    net/core/somaxconn \
    net/ipv4/tcp_max_syn_backlog \
    net/ipv4/ip_local_port_range \
    net/ipv4/tcp_tw_reuse \
    net/ipv4/tcp_fin_timeout; do
    printf '%s=%s\n' "${setting//\//.}" "$(cat "/proc/sys/$setting")"
  done
  echo "sysctls_end"
  echo "thermal_begin"
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -d "$zone" ]] || continue
    printf '%s type=%s temp=%s\n' "$zone" "$(cat "$zone/type")" "$(cat "$zone/temp")"
  done
  echo "thermal_end"
  echo "interrupts_begin"
  cat /proc/interrupts
  echo "interrupts_end"
  echo "server_threads_a_begin"
  ps -L -o pid,tid,psr,comm -p "$A_PID"
  echo "server_threads_a_end"
  echo "server_threads_b_begin"
  ps -L -o pid,tid,psr,comm -p "$B_PID"
  echo "server_threads_b_end"
  capture_process_metadata A "$A_PID"
  capture_process_metadata B "$B_PID"
} >"$OUT_DIR/environment.txt"

COMMON_ARGS=(
  "--concurrency=$CONCURRENCY"
  "--workspaces=$WORKSPACES"
  "--auth=true"
  "--websocket-close=true"
  "--require-zero-failures=true"
)

run_one() {
  local label="$1" url="$2" duration="$3" output="$4"
  taskset -c "$CLIENT_CPUS" "$GENERATOR" \
    "${COMMON_ARGS[@]}" \
    "--label=$label" \
    "--server=$url" \
    "--duration=$duration" \
    "--output=$output" \
    2>&1 | tee "${output%.json}.log"
}

echo "Warming $A_LABEL for $WARMUP_DURATION"
activate_side A
run_one "$A_LABEL" "$A_URL" "$WARMUP_DURATION" "$OUT_DIR/warmup-a.json"
echo "Warming $B_LABEL for $WARMUP_DURATION"
activate_side B
run_one "$B_LABEL" "$B_URL" "$WARMUP_DURATION" "$OUT_DIR/warmup-b.json"

printf 'pair\torder\tside\tlabel\tresult\n' >"$OUT_DIR/runs.tsv"
for ((pair = 1; pair <= PAIRS; pair++)); do
  if (( pair % 2 == 1 )); then
    sides=(A B)
  else
    sides=(B A)
  fi
  order=0
  for side in "${sides[@]}"; do
    ((order += 1))
    if [[ "$side" == A ]]; then
      label="$A_LABEL"; url="$A_URL"
    else
      label="$B_LABEL"; url="$B_URL"
    fi
    activate_side "$side"
    result_name="pair-$(printf '%02d' "$pair")-order-$order-side-${side,,}.json"
    echo "Pair $pair/$PAIRS order $order: $label"
    run_one "$label" "$url" "$MEASURE_DURATION" "$OUT_DIR/$result_name"
    printf '%d\t%d\t%s\t%s\t%s\n' "$pair" "$order" "$side" "$label" "$result_name" >>"$OUT_DIR/runs.tsv"
  done
done

python3 - "$OUT_DIR" "$PROFILE" <<'PY'
import csv
import json
import math
import pathlib
import statistics
import sys

out_dir = pathlib.Path(sys.argv[1])
profile = sys.argv[2]
rows = list(csv.DictReader((out_dir / "runs.tsv").open(), delimiter="\t"))
measurements = []
for row in rows:
    result = json.loads((out_dir / row["result"]).read_text())
    measurements.append({**row, **result})

by_side = {}
for side in ("A", "B"):
    values = [item for item in measurements if item["side"] == side]
    rates = [item["rate_per_second"] for item in values]
    by_side[side] = {
        "label": values[0]["label"],
        "runs": len(values),
        "successes": sum(item["successes"] for item in values),
        "failures": sum(item["failures"] for item in values),
        "close_write_failures": sum(item["close_write_failures"] for item in values),
        "close_read_failures": sum(item["close_read_failures"] for item in values),
        "rate_mean": statistics.mean(rates),
        "rate_median": statistics.median(rates),
        "rate_min": min(rates),
        "rate_max": max(rates),
        "p50_median_ms": statistics.median(item["latency_p50_ms"] for item in values),
        "p95_median_ms": statistics.median(item["latency_p95_ms"] for item in values),
        "p99_median_ms": statistics.median(item["latency_p99_ms"] for item in values),
    }

pair_ratios = []
for pair in sorted({int(item["pair"]) for item in measurements}):
    pair_values = {item["side"]: item for item in measurements if int(item["pair"]) == pair}
    pair_ratios.append(pair_values["B"]["rate_per_second"] / pair_values["A"]["rate_per_second"])

summary = {
    "profile": profile,
    "a": by_side["A"],
    "b": by_side["B"],
    "pair_rate_ratios_b_over_a": pair_ratios,
    "geometric_mean_rate_ratio_b_over_a": math.prod(pair_ratios) ** (1 / len(pair_ratios)),
    "geometric_mean_rate_delta_percent": (math.prod(pair_ratios) ** (1 / len(pair_ratios)) - 1) * 100,
}
(out_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2))
PY

{
  echo "captured_at_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "loadavg=$(cat /proc/loadavg)"
  echo "current_frequencies_begin"
  for frequency in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -f "$frequency" ]] || continue
    printf '%s=%s\n' "$frequency" "$(cat "$frequency")"
  done
  echo "current_frequencies_end"
  echo "thermal_begin"
  for zone in /sys/class/thermal/thermal_zone*; do
    [[ -d "$zone" ]] || continue
    printf '%s type=%s temp=%s\n' "$zone" "$(cat "$zone/type")" "$(cat "$zone/temp")"
  done
  echo "thermal_end"
  echo "interrupts_begin"
  cat /proc/interrupts
  echo "interrupts_end"
} >"$OUT_DIR/environment-after.txt"

echo "Results: $OUT_DIR"
