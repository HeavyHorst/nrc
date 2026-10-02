#!/usr/bin/env python3
"""Paired retained-message ACK benchmark on fresh Amp-supervised servers."""
import argparse
import hashlib
import json
import os
import pathlib
import re
import shlex
import socket
import statistics
import subprocess
import tempfile
import time


def run(args, **kwargs):
    result = subprocess.run(args, text=True, capture_output=True, **kwargs)
    if result.returncode:
        raise RuntimeError(f"command failed ({result.returncode}): {args}\n{result.stdout}\n{result.stderr}")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--keep-going", action="store_true", help="record failed samples and finish remaining attempts; still exit nonzero if any failed")
    workloads = parser.add_mutually_exclusive_group()
    workloads.add_argument("--connection-sweep", action="store_true", help="128 depth-1 control, then 64/128/256/512 depth-4 clients; 256-byte messages")
    workloads.add_argument("--rotation", action="store_true", help="512 depth-4 clients, 256-byte messages, 1s warmup and 6s timed traffic to exercise segment rotation")
    workloads.add_argument("--cumulative-ingestion", action="store_true", help="64/128/512 publishers at depths 1 and 4")
    workloads.add_argument("--fanout", action="store_true", help="16 depth-1 publishers at 1000 messages/s, 1/16/64/128 subscribers")
    workloads.add_argument("--sustained", action="store_true", help="35s rotation traffic: 512x4 ingestion and 64x1 at 8000/s with 16 subscribers")
    parser.add_argument("--duration", help="override timed duration, including for pilot runs")
    parser.add_argument("--durability", default="before: write-completion ACK; after: fsync-completion ACK, 1ms/128KiB group commit; retention 24h", help="Record the compared binaries' durability and queue policies")
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    binaries = args.binaries.resolve()
    cases = [(1, 1, 256), (16, 1, 256), (128, 1, 256), (16, 4, 256), (16, 1, 4096), (16, 4, 4096)]
    if args.connection_sweep:
        cases = [(128, 1, 256)] + [(n, 4, 256) for n in [64, 128, 256, 512]]
    if args.rotation:
        cases = [(512, 4, 256)]
    if args.cumulative_ingestion:
        cases = [(n, d, 256) for n in [64, 128, 512] for d in [1, 4]]
    cases = [(n, d, size, 0, 0) for n, d, size in cases]
    if args.fanout:
        cases = [(16, 1, 256, subscribers, 1000) for subscribers in [1, 16, 64, 128]]
    if args.sustained:
        cases = [(512, 4, 256, 0, 0), (64, 1, 256, 16, 8000)]
    warmup = "1s" if args.rotation or args.sustained else "200ms"
    duration = args.duration or ("35s" if args.sustained else "6s" if args.rotation else "1s")
    metadata = {
        "cases": cases,
        "base_commit": run(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "source_diff_sha256": hashlib.sha256(run(["git", "diff"]).stdout.encode()).hexdigest(),
        "binary_sha256": {name: hashlib.sha256((binaries / name).read_bytes()).hexdigest() for name in ["before", "after", "retained-message-bench"]},
        "odin": run(["odin", "version"]).stdout.strip(),
        "go": run(["go", "version"]).stdout.strip(),
        "cpu": run(["lscpu"]).stdout,
        "filesystem": run(["df", "-T", tempfile.gettempdir()]).stdout,
        "file_descriptor_limit": 8192,
        "clock_ticks_per_second": os.sysconf("SC_CLK_TCK"),
        "affinity": "server CPU 0, client CPU 1; one NRC worker; CPUs are exposed SMT siblings",
        "cache": f"new server and storage directory per sample; {warmup} untimed warmup on same connections; page cache not dropped",
        "workload": f"one workspace/conversation; unique SendMessageV2 IDs; cases are publishers/depth/bytes/subscribers/rate; {duration} timed waves plus drain; depth <=4",
        "receiver_backlog": "published minus observed deliveries across all subscribers, including transport/client scheduling; NOT server send-queue depth",
        "probe": "100ms same-worker ping RTT for fanout/sustained; includes client/socket latency; not isolated worker stall time",
        "latency": "per-request websocket write-start to correlated ACK read; includes client scheduling/earlier ACK processing",
        "durability": args.durability,
        "build": "odin build . -o:speed; no allocation instrumentation",
    }
    samples = []
    failures = []
    summary = {}
    service = "nrc-retained-commit-benchmark"
    for repetition in range(args.repetitions):
        for clients, depth, size, subscribers, rate in cases:
            case = f"{clients}x{depth}-{size}B" + (f"-subs{subscribers}-rate{rate}" if subscribers else "")
            for variant in (["before", "after"] if repetition % 2 == 0 else ["after", "before"]):
                with tempfile.TemporaryDirectory(prefix="nrc-retained-commit-") as directory:
                    command = "exec prlimit --nofile=8192:8192 -- env NRC_PORT=$PORT NRC_THREAD_COUNT=1 NRC_DISABLE_CPU_AFFINITY=1 NRC_MESSAGE_RETENTION=24h NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret taskset -c 0 " + shlex.quote(str(binaries / variant))
                    pid = None
                    try:
                        run(["amp", "orb", "service", "start", service, "--cwd", directory, "--port", "18089", "--command", command])
                        deadline = time.monotonic() + 30
                        while True:
                            try:
                                with socket.create_connection(("127.0.0.1", 18089), timeout=1):
                                    break
                            except OSError:
                                if time.monotonic() >= deadline:
                                    raise RuntimeError("server did not become ready")
                                time.sleep(0.1)
                        pid = int(run(["pgrep", "-f", "^" + re.escape(str(binaries / variant)) + "$"]).stdout.strip())
                        def cpu_ticks():
                            values = pathlib.Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
                            return int(values[11]) + int(values[12])
                        ticks_before = cpu_ticks()
                        resource_path = args.output.resolve() / f"{repetition}-{case}-{variant}-client-resource.txt"
                        client_command = ["/usr/bin/time", "-v", "-o", str(resource_path), "prlimit", "--nofile=8192:8192", "--", "taskset", "-c", "1", str(binaries / "retained-message-bench"), f"--clients={clients}", f"--depth={depth}", f"--size={size}", f"--warmup={warmup}", f"--duration={duration}", f"--subscribers={subscribers}", f"--rate={rate}"]
                        if args.fanout or args.sustained:
                            client_command.append("--probe")
                        proc = run(client_command, timeout=180)
                        result = json.loads(proc.stdout)
                        result["server_cpu_ticks"] = cpu_ticks() - ticks_before
                        resources = resource_path.read_text()
                        result["client_user_seconds"] = float(re.search(r"User time \(seconds\): ([0-9.]+)", resources)[1])
                        result["client_system_seconds"] = float(re.search(r"System time \(seconds\): ([0-9.]+)", resources)[1])
                        result["sealed_segments"] = len(list(pathlib.Path(directory).rglob("*.idx")))
                        (args.output / f"{repetition}-{case}-{variant}.json").write_text(json.dumps(result, indent=2) + "\n")
                        if rate and result["ops"] != result["offered_messages"]:
                            raise RuntimeError(f"rate-targeted workload published {result['ops']}/{result['offered_messages']} scheduled messages")
                        if (args.rotation or args.sustained) and not args.duration and result["sealed_segments"] == 0:
                            raise RuntimeError("rotation workload did not seal a segment")
                        samples.append({"repetition": repetition, "variant": variant, "case": case, "result": result})
                        summary = {}
                        for v in ["before", "after"]:
                            summary[v] = {}
                            for c in sorted({s["case"] for s in samples}):
                                rows = [s["result"] for s in samples if s["variant"] == v and s["case"] == c]
                                if not rows:
                                    continue
                                rates = [r["ops_per_sec"] for r in rows]
                                summary[v][c] = {"samples": len(rows), "ops_median": statistics.median(rates), "ops_min": min(rates), "ops_max": max(rates), "p50_ms": statistics.median(r["latency_ms"]["p50"] for r in rows), "p99_ms": statistics.median(r["latency_ms"]["p99"] for r in rows)}
                        (args.output / "results.json").write_text(json.dumps({"metadata": metadata, "samples": samples, "summary": summary, "failures": failures}, indent=2) + "\n")
                        print(f"{repetition+1}/{args.repetitions} {variant} {case}: {result['ops_per_sec']:.0f}/s p99={result['latency_ms']['p99']:.3f}ms", flush=True)
                    except (RuntimeError, subprocess.TimeoutExpired, OSError, ValueError) as error:
                        if not args.keep_going:
                            raise
                        failures.append({"repetition": repetition, "variant": variant, "case": case, "error": str(error)})
                        (args.output / "results.json").write_text(json.dumps({"metadata": metadata, "samples": samples, "summary": summary, "failures": failures}, indent=2) + "\n")
                        print(f"{repetition+1}/{args.repetitions} {variant} {case}: FAILED: {error}", flush=True)
                    finally:
                        logs = run(["amp", "orb", "service", "logs", service]).stdout
                        if pid is not None:
                            logs = "\n".join(line for line in logs.splitlines() if f"[{pid}]" in line) + "\n"
                        (args.output / f"{repetition}-{case}-{variant}.log").write_text(logs)
                        run(["amp", "orb", "service", "stop", service])
    if failures:
        raise SystemExit(f"{len(failures)} benchmark attempts failed; see results.json")


if __name__ == "__main__":
    main()
