#!/usr/bin/env python3
"""Run the subscribed-user simulator on a disposable, CPU-pinned NRC server.

No sysctl, IRQ, governor, cgroup or persistent affinity changes are made.
All data, reports and logs stay in a new run directory for inspection.
"""

import argparse
import base64
import hashlib
import json
import math
import os
from pathlib import Path
import resource
import secrets
import signal
import socket
import subprocess
import sys
import time


ROOT = Path(__file__).resolve().parent.parent
MANIFEST = "TlJDTAABAAAAAAAAAAAAAQIBAAAAAAAAAAABAAABAACsNnTeRP92XA=="


def cpu_plan(workers, generators):
    cores = {}
    for cpu in sorted(os.sched_getaffinity(0)):
        topology = Path(f"/sys/devices/system/cpu/cpu{cpu}/topology")
        key = (int((topology / "physical_package_id").read_text()),
               int((topology / "core_id").read_text()))
        cores.setdefault(key, []).append(cpu)
    groups = sorted(cores.values(), key=lambda group: group[0])
    needed = 3 + workers + generators  # OS, service, storage, workers, generators
    if len(groups) < needed:
        raise ValueError(f"need {needed} allowed physical cores, found {len(groups)}; reduce workers/generators")
    return {"physical_cores": groups, "housekeeping": groups[0],
            "service": groups[1][0], "storage": groups[2][0],
            "workers": [g[0] for g in groups[3:3 + workers]],
            "generators": [g[0] for g in groups[-generators:]],
            "isolation": "process affinity only; unrelated tasks and IRQs are not excluded"}


def initialize(data):
    data.mkdir()
    generation = data / "sharded-00000000000000000001"
    for shard in range(256):
        directory = generation / f"shard_{shard:03}"
        directory.mkdir(parents=True)
        (directory / "active.wal").touch()
    (data / "storage-layout.manifest").write_bytes(base64.b64decode(MANIFEST))


def read_optional(path):
    try:
        return Path(path).read_text().strip()
    except (OSError, ProcessLookupError):
        return None


def snapshot(processes):
    result = {"time_ns": time.time_ns(), "loadavg": read_optional("/proc/loadavg"),
              "cpu_stat": read_optional("/proc/stat"), "processes": {}}
    for name, proc in processes.items():
        base = Path(f"/proc/{proc.pid}")
        result["processes"][name] = {
            "pid": proc.pid, "status": read_optional(base / "status"),
            "stat": read_optional(base / "stat"), "io": read_optional(base / "io"),
            "smaps_rollup": read_optional(base / "smaps_rollup"),
        }
    result["temperatures_millidegrees"] = {
        str(p): read_optional(p) for p in Path("/sys/class/hwmon").glob("hwmon*/temp*_input")}
    result["frequency_khz"] = {
        str(p): read_optional(p) for p in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_cur_freq")}
    server = processes.get("server")
    if server is not None:
        result["server_threads"] = {
            p.name: {"stat": read_optional(p / "stat"), "status": read_optional(p / "status")}
            for p in Path(f"/proc/{server.pid}/task").glob("*")}
    return result


def stop(proc):
    if proc.poll() is None:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=60)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def run(args):
    plan = cpu_plan(args.workers, args.generators)
    if args.workspaces < args.generators or args.users < args.workspaces * 2:
        raise ValueError("need at least one workspace/generator and two users/workspace")
    soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    needed = args.users * 2 + 4096
    if hard < needed:
        raise ValueError(f"hard descriptor limit {hard} < required {needed}; raise it before this run")
    resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, needed), hard))
    low, high = map(int, Path("/proc/sys/net/ipv4/ip_local_port_range").read_text().split())
    ips_per_generator = math.ceil(args.users / args.generators / ((high - low + 1) * 0.6))
    if ips_per_generator > 254:
        raise ValueError("too many source addresses requested")
    output = Path(args.output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    server_bin = Path(args.server_bin).resolve()
    generator_bin = Path(args.generator_bin).resolve()
    for binary in (server_bin, generator_bin):
        if not binary.is_file():
            raise ValueError(f"build {binary} first")
    metadata = {"args": vars(args), "cpu_plan": plan, "nofile": resource.getrlimit(resource.RLIMIT_NOFILE),
                "ephemeral_ports": [low, high], "source_ips_per_generator": ips_per_generator,
                "uname": list(os.uname()), "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
                "git_status": subprocess.check_output(["git", "status", "--short"], cwd=ROOT, text=True),
                "binary_sha256": {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in (server_bin, generator_bin)},
                "cpuinfo": read_optional("/proc/cpuinfo"),
                "governors": {str(p): read_optional(p) for p in Path("/sys/devices/system/cpu").glob("cpu*/cpufreq/scaling_governor")}}
    (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps(plan, indent=2), flush=True)
    print(f"Results: {output}", flush=True)
    server_dir = output / "server"
    server_dir.mkdir()
    initialize(server_dir / "data")
    # Never reuse a running server or a repository data directory.
    with socket.socket() as sock:
        # NRC binds all interfaces. Probe the same scope so a source socket on
        # another loopback IP cannot make an apparently free port unusable.
        sock.bind(("0.0.0.0", args.port))
        port = sock.getsockname()[1]
    env = os.environ.copy()
    for key in list(env):
        if key.startswith("NRC_"):
            del env[key]
    secret = secrets.token_hex(32)
    env.update(NRC_JWT_SECRET=secret, NRC_SIM_JWT_SECRET=secret, NRC_PORT=str(port),
               NRC_BOT_SECRET=secrets.token_hex(32),
               NRC_THREAD_COUNT=str(args.workers), NRC_SERVICE_CPU=str(plan["service"]),
               NRC_STORAGE_BULK_CPUS=str(plan["storage"]), NRC_STORAGE_BULK_EXECUTORS="2",
               NRC_MESSAGE_RETENTION="24h", NRC_LOG_LEVEL="warn")
    metadata["server_configuration"] = {k: v for k, v in env.items()
                                         if k.startswith("NRC_") and "SECRET" not in k}
    (output / "environment.json").write_text(json.dumps(metadata, indent=2) + "\n")
    processes = {}
    handles = []
    reports = []
    failure = None
    interrupted = False

    def request_stop(signum, frame):
        nonlocal interrupted
        # Do not raise inside Popen before its child has been registered.
        interrupted = True

    previous_handlers = {sig: signal.signal(sig, request_stop)
                         for sig in (signal.SIGTERM, signal.SIGINT)}
    try:
        log = (output / "server.log").open("w"); handles.append(log)
        cpus = [plan["service"], plan["storage"], *plan["workers"]]
        processes["server"] = subprocess.Popen(
            ["taskset", "-c", ",".join(map(str, cpus)), str(server_bin)],
            cwd=server_dir, env=env, stdout=log, stderr=subprocess.STDOUT)
        deadline = time.monotonic() + 30
        while True:
            if interrupted:
                raise KeyboardInterrupt
            if processes["server"].poll() is not None:
                raise RuntimeError("server exited during startup; inspect server.log")
            try:
                with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise RuntimeError("server startup timeout")
                time.sleep(0.1)
        for partition, cpu in enumerate(plan["generators"]):
            if interrupted:
                raise KeyboardInterrupt
            report = output / f"generator-{partition}.json"; reports.append(report)
            log = (output / f"generator-{partition}.log").open("w"); handles.append(log)
            sources = ",".join(f"127.{partition + 1}.{args.source_octet}.{j + 1}" for j in range(ips_per_generator))
            command = ["taskset", "-c", str(cpu), str(generator_bin), "--disposable",
                       f"--server=ws://127.0.0.1:{port}", f"--users={args.users}",
                       f"--workspaces={args.workspaces}", f"--workers={args.workers}",
                       f"--rooms={args.rooms}", f"--partition={partition}", f"--partitions={args.generators}",
                       f"--prefix={args.fixture_prefix}", f"--source-ip={sources}",
                       f"--duration={args.duration}s", f"--ramp={args.ramp}s", f"--seed={args.seed}",
                       f"--output={report}", f"--trace={output / f'trace-{partition}.jsonl'}",
                       f"--start-file={output / 'start'}", *args.sim_arg]
            processes[f"generator-{partition}"] = subprocess.Popen(command, env={**env, "GOMAXPROCS": "1"}, stdout=log, stderr=subprocess.STDOUT)
        start_written = False
        deadline = time.monotonic() + args.ramp + args.duration + 600
        with (output / "resources.jsonl").open("w") as samples:
            while True:
                if interrupted:
                    raise KeyboardInterrupt
                samples.write(json.dumps(snapshot(processes)) + "\n"); samples.flush()
                generators = [p for name, p in processes.items() if name != "server"]
                if not start_written:
                    if any(p.poll() is not None for p in generators):
                        raise RuntimeError("generator exited before the start barrier; inspect generator logs")
                    if all(Path(str(p) + ".ready").exists() for p in reports):
                        (output / "start").write_text(str(time.time_ns() + 2_000_000_000))
                        start_written = True
                        print("All users subscribed; starting measured workload", flush=True)
                if all(p.poll() is not None for p in generators):
                    break
                if processes["server"].poll() is not None:
                    raise RuntimeError("server exited during the simulation")
                if time.monotonic() > deadline:
                    raise RuntimeError("simulation exceeded its wall-clock budget")
                time.sleep(1)
    except (Exception, KeyboardInterrupt) as exc:
        failure = str(exc) or "interrupted"
    finally:
        for name, proc in reversed(list(processes.items())):
            stop(proc)
        for handle in handles:
            handle.close()
        for sig, handler in previous_handlers.items():
            signal.signal(sig, handler)
    if interrupted:
        failure = "interrupted"
    results = [json.loads(p.read_text()) for p in reports if p.exists()]
    verdicts = {key: len(results) == args.generators and all(r["verdicts"][key] for r in results)
                for key in ("correctness", "reliability", "performance", "measurement_valid")}
    passed = failure is None and all(verdicts.values()) and all(p.returncode == 0 for p in processes.values())
    summary = {"passed": passed, "harness_error": failure, "verdicts": verdicts,
               "exit_codes": {name: p.returncode for name, p in processes.items()},
               "reports": [str(p) for p in reports],
               "latency_gate": "Every generator must meet each per-operation target; percentiles are not averaged."}
    (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(json.dumps(summary, indent=2), flush=True)
    return 0 if passed else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server-bin", default=str(ROOT / ".amp/in/active-server"))
    parser.add_argument("--generator-bin", default=str(ROOT / ".amp/in/active-user-sim"))
    parser.add_argument("--output", default=str(ROOT / ".amp/in/artifacts" / f"active-{time.time_ns()}"))
    parser.add_argument("--users", type=int, default=20000)
    parser.add_argument("--workspaces", type=int, default=200)
    parser.add_argument("--workers", type=int, default=2)
    parser.add_argument("--generators", type=int, default=2)
    parser.add_argument("--rooms", type=int, default=4)
    parser.add_argument("--duration", type=float, default=600, help="Steady-state seconds")
    parser.add_argument("--ramp", type=float, default=120, help="Connection-ramp seconds")
    parser.add_argument("--port", type=int, default=0, help="0 chooses a free local port")
    parser.add_argument("--source-octet", type=int, default=1, help="Change between overlapping runs to avoid TIME_WAIT exhaustion")
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--fixture-prefix", default="active-benchmark",
                        help="Stable workspace/shard placement across disposable runs")
    parser.add_argument("--levels", help="Optional staircase, e.g. 20000,40000,60000,80000,100000; stops at first non-pass")
    parser.add_argument("--sim-arg", action="append", default=[], help="Extra generator option, e.g. --sim-arg=--chat-interval=1s")
    args = parser.parse_args()
    if min(args.workers, args.generators, args.workspaces, args.users, args.rooms) < 1 or args.duration <= 0 or args.ramp < 0 or not 0 <= args.source_octet <= 255:
        parser.error("invalid counts, duration or source octet")
    allowed = {"--read-interval", "--mutation-interval", "--chat-interval", "--ping-interval",
               "--deadline", "--p95", "--p99", "--lag-limit", "--recovery"}
    if any(value.partition("=")[0] not in allowed or "=" not in value for value in args.sim_arg):
        parser.error("--sim-arg accepts only interval, deadline and verdict thresholds as --name=value")
    try:
        if args.levels:
            levels = [int(level) for level in args.levels.split(",")]
            if not levels or any(n < 2 * args.workspaces for n in levels) or levels != sorted(set(levels)):
                raise ValueError("levels must be strictly increasing and have at least two users/workspace")
            output = args.output
            for users in levels:
                args.users = users
                args.output = str(Path(output) / f"users-{users}")
                code = run(args)
                if code:
                    return code
            return 0
        return run(args)
    except (OSError, ValueError, RuntimeError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
