#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -lt 4 || $# -gt 5 ]]; then
  echo "usage: $0 <nrc|uws> <workers:1|2|4> <label> <sequence> [users-per-workspace=3000]" >&2
  exit 2
fi

impl=$1
workers=$2
label=$3
sequence=$4
users_per_workspace=${5:-3000}

[[ "$impl" == "nrc" || "$impl" == "uws" ]] || { echo "invalid implementation: $impl" >&2; exit 2; }
[[ "$workers" == "1" || "$workers" == "2" || "$workers" == "4" ]] || { echo "workers must be 1, 2, or 4" >&2; exit 2; }
[[ "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "label contains unsupported characters" >&2; exit 2; }
[[ "$sequence" =~ ^[0-9]+$ ]] || { echo "sequence must be a non-negative integer" >&2; exit 2; }
[[ "$users_per_workspace" =~ ^[0-9]+$ && "$users_per_workspace" -gt 0 ]] || { echo "invalid users/workspace" >&2; exit 2; }
((users_per_workspace <= 4000)) || { echo "users/workspace exceeds method maximum 4000" >&2; exit 2; }
((users_per_workspace * 3 / 10 <= 1200)) || { echo "MAX_ROOM_USERS=1200 would be exceeded" >&2; exit 2; }

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(cd "$script_dir/.." && pwd)
results_root=${FANOUT_RESULTS_ROOT:-$repo_root/.benchmark-results/fanout-capacity}
nrc_server=${NRC_SERVER_BIN:-$repo_root/nrc-server}
nrc_bench=${NRC_BENCH_BIN:-$script_dir/bin/nrc-bench}
uws_server=${UWS_SERVER_BIN:-$script_dir/uwebsockets/uwebsockets-bench-server}
uws_bench=${UWS_BENCH_BIN:-$script_dir/bin/uwebsockets-bench}
nrc_data=${NRC_BENCH_DATA_DIR:-$repo_root/data}

IFS=, read -r -a worker_cpus <<< "${FANOUT_WORKER_CPUS:-0,2,4,6}"
service_cpu=${FANOUT_SERVICE_CPU:-8}
client_cpus=${FANOUT_CLIENT_CPUS:-10-47}
expected_online=${FANOUT_EXPECTED_ONLINE_CPUS:-}
expected_numa=${FANOUT_EXPECTED_NUMA_NODES:-}
min_client_idle=${FANOUT_MIN_CLIENT_IDLE_PERCENT:-5}
max_client_steal=${FANOUT_MAX_CLIENT_STEAL_PERCENT:-0.1}
total_users=$((workers * users_per_workspace))

((${#worker_cpus[@]} >= workers)) || { echo "not enough worker CPUs configured" >&2; exit 2; }
selected_workers=$(IFS=,; echo "${worker_cpus[*]:0:workers}")
server_mask="$selected_workers,$service_cpu"

for tool in mpstat pidstat python3 sha256sum ss taskset; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
if [[ "$impl" == "nrc" ]]; then
  required_paths=("$nrc_server" "$nrc_bench")
else
  required_paths=("$uws_server" "$uws_bench")
fi
for path in "${required_paths[@]}"; do
  [[ -x "$path" ]] || { echo "missing executable: $path" >&2; exit 2; }
done
if [[ "$impl" == "nrc" && ! -d "$nrc_data" ]]; then
  echo "missing NRC benchmark data directory: $nrc_data" >&2
  exit 2
fi

assert_hash() {
  local path=$1 expected=$2 label=$3
  [[ -z "$expected" ]] && return
  local actual
  actual=$(sha256sum "$path" | awk '{print $1}')
  [[ "$actual" == "$expected" ]] || { echo "$label hash mismatch: $actual != $expected" >&2; exit 2; }
}
if [[ "$impl" == "nrc" ]]; then
  assert_hash "$nrc_server" "${FANOUT_EXPECTED_NRC_SERVER_SHA256:-}" "NRC server"
  assert_hash "$nrc_bench" "${FANOUT_EXPECTED_NRC_BENCH_SHA256:-}" "NRC generator"
else
  assert_hash "$uws_server" "${FANOUT_EXPECTED_UWS_SERVER_SHA256:-}" "uWebSockets server"
  assert_hash "$uws_bench" "${FANOUT_EXPECTED_UWS_BENCH_SHA256:-}" "uWebSockets generator"
fi

[[ -z "$expected_online" || "$(cat /sys/devices/system/cpu/online)" == "$expected_online" ]] || {
  echo "online CPU topology changed" >&2
  exit 2
}
[[ -z "$expected_numa" || "$(cat /sys/devices/system/node/online)" == "$expected_numa" ]] || {
  echo "NUMA topology changed" >&2
  exit 2
}

python3 - "$selected_workers" "$service_cpu" "$client_cpus" <<'PY'
import pathlib, sys

def expand(spec):
    cpus = set()
    for part in spec.split(','):
        bounds = [int(value) for value in part.split('-', 1)]
        cpus.update(range(bounds[0], bounds[-1] + 1))
    return cpus

worker_values = sys.argv[1].split(',')
if any(not value.isdecimal() for value in worker_values) or not sys.argv[2].isdecimal():
    raise SystemExit("worker and service CPUs must be singleton decimal IDs")
workers = [int(value) for value in worker_values]
service = int(sys.argv[2])
if len(set(workers)) != len(workers):
    raise SystemExit("worker CPU IDs must be unique")
servers = set(workers) | {service}
if len(servers) != len(workers) + 1:
    raise SystemExit("service CPU must differ from every worker CPU")
clients = expand(sys.argv[3])
online = expand(pathlib.Path("/sys/devices/system/cpu/online").read_text().strip())
if not clients:
    raise SystemExit("client CPU mask is empty")
missing = (servers | clients) - online
if missing:
    raise SystemExit(f"selected CPUs are not online: {sorted(missing)}")
if servers & clients:
    raise SystemExit(f"server/client CPU masks overlap: {sorted(servers & clients)}")
server_siblings = {}
for cpu in servers:
    siblings = expand(pathlib.Path(f"/sys/devices/system/cpu/cpu{cpu}/topology/thread_siblings_list").read_text().strip())
    server_siblings[cpu] = siblings
    overlap = siblings & clients
    if overlap:
        raise SystemExit(f"client mask contains CPU{cpu} sibling(s): {sorted(overlap)}")
for cpu, siblings in server_siblings.items():
    overlap = (siblings & servers) - {cpu}
    if overlap:
        raise SystemExit(f"server roles CPU{cpu} and {sorted(overlap)} share a physical core")
PY

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
run_id=$(printf '%03d-%s-%s-%dw-%su-%s' "$sequence" "$timestamp" "$impl" "$workers" "$total_users" "$label")
run_dir=$results_root/runs/$run_id
mkdir -p "$results_root/runs"
mkdir "$run_dir" || { echo "run directory already exists: $run_dir" >&2; exit 2; }

server_pids=()
monitor_pids=()
client_pid=
cpu_monitor_pid=
cleanup() {
  set +e
  [[ -n "${client_pid:-}" ]] && kill -TERM "$client_pid" 2>/dev/null
  [[ -n "${cpu_monitor_pid:-}" ]] && kill -TERM "$cpu_monitor_pid" 2>/dev/null
  for pid in "${monitor_pids[@]:-}"; do kill -TERM "$pid" 2>/dev/null; done
  for pid in "${server_pids[@]:-}"; do
    [[ "$impl" == "nrc" ]] && kill -INT "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
  done
  sleep 0.5
  for pid in "${server_pids[@]:-}"; do kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; done
}
trap cleanup EXIT INT TERM
ulimit -n 100000

exec > >(tee "$run_dir/commands.txt") 2>&1
echo "run_id=$run_id"
echo "utc_start=$(date --iso-8601=ns)"
echo "impl=$impl workers=$workers users_per_workspace=$users_per_workspace total_users=$total_users"
echo "worker_cpus=$selected_workers service_cpu=$service_cpu client_cpus=$client_cpus"
sha256sum "${required_paths[@]}" > "$run_dir/binary-hashes.txt"
lscpu > "$run_dir/lscpu.txt"
cat /proc/softirqs > "$run_dir/softirqs-before.txt"

wait_port() {
  local port=$1
  for _ in $(seq 1 100); do
    ss -ltn | grep -q ":$port " && return
    sleep 0.1
  done
  return 1
}

port_count=$workers
[[ "$impl" == "nrc" ]] && port_count=1
for ((i = 0; i < port_count; i++)); do
  port=$([[ "$impl" == "nrc" ]] && echo 8080 || echo $((8082 + i)))
  ! ss -ltn | grep -q ":$port " || { echo "port already in use: $port" >&2; exit 2; }
done

urls=()
if [[ "$impl" == "nrc" ]]; then
  cp -a "$nrc_data" "$run_dir/data"
  (
    cd "$run_dir"
    exec env NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret NRC_THREAD_COUNT="$workers" NRC_SERVICE_CPU="$service_cpu" \
      taskset -c "$server_mask" "$nrc_server"
  ) > "$run_dir/server-nrc.log" 2>&1 &
  server_pids+=("$!")
  wait_port 8080 || { cat "$run_dir/server-nrc.log"; echo "NRC readiness failed" >&2; exit 2; }
  urls+=("ws://127.0.0.1:8080")
else
  for ((i = 0; i < workers; i++)); do
    cpu=${worker_cpus[$i]}
    port=$((8082 + i))
    env PORT="$port" AUTH_ENABLED=1 UWS_THREAD_COUNT=1 taskset -c "$cpu" "$uws_server" \
      > "$run_dir/server-uws-$i.log" 2>&1 &
    server_pids+=("$!")
    wait_port "$port" || { cat "$run_dir/server-uws-$i.log"; echo "uWS readiness failed" >&2; exit 2; }
    urls+=("ws://127.0.0.1:$port")
  done
fi

servers=$(IFS=,; echo "${urls[*]}")
[[ "$impl" == "nrc" || ${#urls[@]} -eq workers ]] || { echo "uWS requires one endpoint per workspace" >&2; exit 2; }

{
  echo "servers=$servers"
  for pid in "${server_pids[@]}"; do
    echo "=== pid=$pid ==="
    taskset -apc "$pid"
    ps -L -p "$pid" -o pid,tid,psr,pcpu,stat,comm
    for task in /proc/"$pid"/task/*; do
      tid=${task##*/}
      printf 'tid=%s ' "$tid"
      grep Cpus_allowed_list "$task/status"
    done
  done
} > "$run_dir/affinity-before.txt"

if [[ "$impl" == "nrc" ]]; then
  declare -A singleton_counts=()
  for task in /proc/"${server_pids[0]}"/task/*; do
    allowed=$(awk '/Cpus_allowed_list/{print $2}' "$task/status")
    [[ "$allowed" != *-* && "$allowed" != *,* ]] || { echo "NRC TID is not singleton-pinned: $allowed" >&2; exit 2; }
    singleton_counts[$allowed]=$(( ${singleton_counts[$allowed]:-0} + 1 ))
  done
  for ((i = 0; i < workers; i++)); do
    cpu=${worker_cpus[$i]}
    [[ ${singleton_counts[$cpu]:-0} -eq 1 ]] || { echo "expected one NRC worker TID on CPU$cpu" >&2; exit 2; }
  done
  [[ ${singleton_counts[$service_cpu]:-0} -ge 1 ]] || { echo "NRC service/helper missing from CPU$service_cpu" >&2; exit 2; }
  for cpu in "${!singleton_counts[@]}"; do
    [[ ",$server_mask," == *",$cpu,"* ]] || { echo "unexpected NRC TID CPU: $cpu" >&2; exit 2; }
  done
else
  for ((i = 0; i < workers; i++)); do
    for task in /proc/"${server_pids[$i]}"/task/*; do
      allowed=$(awk '/Cpus_allowed_list/{print $2}' "$task/status")
      [[ "$allowed" == "${worker_cpus[$i]}" ]] || { echo "uWS TID affinity mismatch: $allowed" >&2; exit 2; }
    done
  done
fi

pids_csv=$(IFS=,; echo "${server_pids[*]}")
pidstat -t -u -w -p "$pids_csv" 1 90 > "$run_dir/pidstat-server.txt" 2>&1 & monitor_pids+=("$!")
mpstat -P ALL 1 76 > "$run_dir/mpstat-cpus.txt" 2>&1 & cpu_monitor_pid=$!
mpstat -P ALL -I SCPU 1 90 > "$run_dir/mpstat-softirq.txt" 2>&1 & monitor_pids+=("$!")

generator=$([[ "$impl" == "nrc" ]] && echo "$nrc_bench" || echo "$uws_bench")
taskset -c "$client_cpus" "$generator" --servers="$servers" --users="$total_users" --workspaces="$workers" \
  --conversations=10 --convs-per-user=3 --duration=75s --ramp-up=15s --msg-interval=1s --msg-size=128 \
  --fanout-sample-rate=100 --seed=11 --auth --output="$run_dir/result.json" > "$run_dir/client.log" 2>&1 &
client_pid=$!
pidstat -t -u -w -p "$client_pid" 1 85 > "$run_dir/pidstat-client.txt" 2>&1 & monitor_pids+=("$!")

set +e
wait "$client_pid"
client_rc=$?
set -e
client_pid=
for pid in "${monitor_pids[@]}"; do kill -TERM "$pid" 2>/dev/null || true; done
for pid in "${monitor_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
monitor_pids=()
wait "$cpu_monitor_pid"
cpu_monitor_pid=
cat /proc/softirqs > "$run_dir/softirqs-after.txt"

[[ $client_rc -eq 0 ]] || { echo "generator exit=$client_rc" >&2; exit 3; }
[[ -s "$run_dir/result.json" ]] || { echo "missing result JSON" >&2; exit 3; }

python3 - "$run_dir" "$total_users" "$workers" "$client_cpus" "$min_client_idle" "$max_client_steal" <<'PY'
import json, re, sys
from collections import defaultdict
from pathlib import Path

run_dir = Path(sys.argv[1])
users = int(sys.argv[2])
workspaces = int(sys.argv[3])
client_spec = sys.argv[4]
minimum_idle = float(sys.argv[5])
maximum_steal = float(sys.argv[6])
result = json.loads((run_dir / "result.json").read_text())
errors = []

if result["active_connections"] != users:
    errors.append(f"active={result['active_connections']} expected={users}")
for key in ("failed_connections", "total_errors", "steady_state_disconnects"):
    if result[key] != 0:
        errors.append(f"{key}={result[key]}")
if result["messages_acknowledged"] < result["messages_sent"] * .98:
    errors.append(f"ack_attainment={result['messages_acknowledged']/result['messages_sent']:.4f}")

points = {}
pattern = re.compile(r"^\[(?:(\d+)m)?(\d+)s\].*Msgs: (\d+) sent, (\d+) recv")
for line in (run_dir / "client.log").read_text().splitlines():
    match = pattern.match(line)
    if match:
        second = int(match.group(1) or 0) * 60 + int(match.group(2))
        points[second] = (int(match.group(3)), int(match.group(4)))
if 15 not in points or max(points) < 70:
    errors.append("missing post-ramp checkpoints")
    post_ramp_sent = post_ramp_fanout = attainment = 0
else:
    end = max(points)
    elapsed = end - 15
    post_ramp_sent = (points[end][0] - points[15][0]) / elapsed
    post_ramp_fanout = (points[end][1] - points[15][1]) / elapsed
    if post_ramp_sent < users * .98:
        errors.append(f"offered_send_attainment={post_ramp_sent/users:.4f}")
    if any(points[t][1] <= points[t - 5][1] for t in sorted(points) if t >= 25 and t - 5 in points):
        errors.append("receive progress stopped")
    users_per_workspace = users // workspaces
    occupancy = [0] * 10
    for workspace_user_id in range(users_per_workspace):
        for offset in range(3):
            occupancy[(workspace_user_id + offset) % 10] += 1
    recipients = sum(count * (count - 1) for count in occupancy) / (users_per_workspace * 3)
    expected = post_ramp_sent * recipients
    attainment = post_ramp_fanout / expected if expected else 0
    if attainment < .98:
        errors.append(f"fanout_attainment={attainment:.4f}")

def expand(spec):
    cpus = set()
    for part in spec.split(','):
        bounds = [int(value) for value in part.split('-', 1)]
        cpus.update(range(bounds[0], bounds[-1] + 1))
    return cpus

samples = defaultdict(list)
for line in (run_dir / "mpstat-cpus.txt").read_text().splitlines():
    fields = line.split()
    if len(fields) >= 12 and fields[0] != "Average:" and fields[-11].isdigit():
        try:
            samples[int(fields[-11])].append((float(fields[-1]), float(fields[-4])))
        except ValueError:
            pass
client_cpus = expand(client_spec)
steady = {cpu: rows[15:75] for cpu, rows in samples.items() if cpu in client_cpus}
if set(steady) != client_cpus or any(len(rows) < 60 for rows in steady.values()):
    errors.append("missing client CPU samples")
    idle = steal = {}
else:
    idle = {cpu: sum(row[0] for row in rows) / len(rows) for cpu, rows in steady.items()}
    steal = {cpu: sum(row[1] for row in rows) / len(rows) for cpu, rows in steady.items()}
    if min(idle.values()) < minimum_idle:
        errors.append(f"generator_cpu_reserve={min(idle.values()):.2f}% below {minimum_idle}%")
    if max(steal.values()) > maximum_steal:
        errors.append(f"generator_cpu_steal={max(steal.values()):.2f}% above {maximum_steal}%")

validation = {
    "post_ramp_sent_per_second": post_ramp_sent,
    "post_ramp_fanout_per_second": post_ramp_fanout,
    "expected_recipients_per_message": recipients if "recipients" in locals() else 0,
    "fanout_attainment": attainment,
    "ack_attainment": result["messages_acknowledged"] / result["messages_sent"],
    "client_cpu_mean_idle_percent": idle,
    "client_cpu_mean_steal_percent": steal,
    "teardown_errors": result["teardown_errors"],
    "teardown_disconnects": result["teardown_disconnects"],
    "errors": errors,
}
(run_dir / "validation.json").write_text(json.dumps(validation, indent=2) + "\n")
if errors:
    raise SystemExit("; ".join(errors))
PY

for pid in "${server_pids[@]}"; do
  [[ "$impl" == "nrc" ]] && kill -INT "$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null
done
for pid in "${server_pids[@]}"; do wait "$pid" 2>/dev/null || true; done
server_pids=()
echo "utc_end=$(date --iso-8601=ns)"
echo "$run_dir"
