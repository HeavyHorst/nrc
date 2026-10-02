#!/usr/bin/env python3
"""Compare prebuilt NRC servers through the existing asset WebSocket benchmark.

Uses Amp-supervised services, isolated temporary data, and sequential samples.
Build instructions and measurement limitations are in docs/BENCHMARKS.md.
"""
import argparse
import json
import pathlib
import shlex
import socket
import statistics
import subprocess
import tempfile
import time


def run(args, **kwargs):
    return subprocess.run(args, check=True, text=True, capture_output=True, **kwargs)


def summarize(samples):
    output = {}
    for variant in sorted({s["variant"] for s in samples}):
        output[variant] = {}
        for case in sorted({s["case"] for s in samples}):
            rows = [s["result"] for s in samples if s["variant"] == variant and s["case"] == case]
            if not rows:
                continue
            rates = [r["ops_per_sec"] for r in rows]
            output[variant][case] = {
                "samples": len(rows),
                "ops_per_sec_median": statistics.median(rates),
                "ops_per_sec_min": min(rates),
                "ops_per_sec_max": max(rates),
                "p50_ms_median": statistics.median(r["latency_ms"]["p50"] for r in rows),
                "p99_ms_median": statistics.median(r["latency_ms"]["p99"] for r in rows),
                "shortest_sample_ms": min(r["duration_ms"] for r in rows),
            }
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binaries", type=pathlib.Path, required=True)
    parser.add_argument("--output", type=pathlib.Path, required=True)
    parser.add_argument("--variants", nargs="+", default=["before", "durable-5-131072", "durable-1-131072", "durable-2-131072", "durable-5-32768", "durable-5-524288"])
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--ops", type=int, default=30000, help="depth-1 operations; depth-32 uses twice this count")
    parser.add_argument("--connection-sweep", action="store_true", help="16/64/128/256/512 depth-1 clients plus a 16-client depth-32 control; --ops per case")
    parser.add_argument("--server-cpu", default="0")
    parser.add_argument("--client-cpu", default="2")
    parser.add_argument("--port", type=int, default=18089)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    binaries = args.binaries.resolve()
    service = "nrc-group-commit-benchmark"
    samples = []
    metadata = {
        "base_commit": run(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "odin": run(["odin", "version"]).stdout.strip(),
        "cpu": run(["lscpu"]).stdout,
        "filesystem": run(["df", "-T", tempfile.gettempdir()]).stdout,
        "server_cpu": args.server_cpu,
        "client_cpu": args.client_cpu,
        "cache": "512 untimed creates per case; new data directory per variant/repetition; page cache not dropped",
        "latency": "batch-start to correlated ACK (includes sending earlier requests in that client batch)",
        "durability": "before: kernel-accepted ACK; durable variants: ACK after fsync",
        "connection_sweep": args.connection_sweep,
    }
    for repetition in range(args.repetitions):
        # Alternate direction and rotate the starting variant to limit order bias.
        order = args.variants[repetition % len(args.variants):] + args.variants[:repetition % len(args.variants)]
        if repetition % 2:
            order.reverse()
        for variant in order:
            with tempfile.TemporaryDirectory(prefix="nrc-group-commit-") as directory:
                command = "env NRC_PORT=$PORT NRC_THREAD_COUNT=1 NRC_DISABLE_CPU_AFFINITY=1 NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret taskset -c " + shlex.quote(args.server_cpu) + " " + shlex.quote(str(binaries / variant))
                try:
                    run(["amp", "orb", "service", "start", service, "--cwd", directory, "--port", str(args.port), "--command", command])
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            with socket.create_connection(("127.0.0.1", args.port), timeout=1):
                                break
                        except OSError:
                            if time.monotonic() >= deadline:
                                raise RuntimeError("server did not listen within 30 seconds")
                            time.sleep(0.1)
                    cases = [(f"connections-{n}-depth-1", n, 1) for n in [16, 64, 128, 256, 512]] + [("connections-16-depth-32", 16, 32)] if args.connection_sweep else [("depth-1", 16, 1), ("depth-32", 16, 32)]
                    if args.connection_sweep:
                        cases = cases[repetition % len(cases):] + cases[:repetition % len(cases)]
                        if repetition % 2:
                            cases.reverse()
                    for case, concurrency, depth in cases:
                        base = ["taskset", "-c", args.client_cpu, str(binaries / "asset-kv-bench"), "--backend=nrc", "--auth", f"--server=ws://127.0.0.1:{args.port}", "--profile=create-only", "--workspaces=1", f"--concurrency={concurrency}", f"--pipeline-depth={depth}", "--payload-size=1024", "--preview-size=128"]
                        # The sweep retains six cases of creates in one process;
                        # spread them within the same shard to avoid per-room caps.
                        base.append(f"--conversations={64 if args.connection_sweep else 16}")
                        for warmup in [True, False]:
                            result_file = pathlib.Path(directory) / "result.json"
                            count = args.ops * (2 if depth == 32 and not args.connection_sweep else 1)
                            run(base + [f"--ops={512 if warmup else count}", f"--output={result_file}"], timeout=180)
                            result = json.loads(result_file.read_text())["results"][0]
                            if result["errors"] or result["operations_by_op"] != {"create": result["ops"]}:
                                raise RuntimeError(f"invalid sample: {result}")
                            if not warmup:
                                samples.append({"repetition": repetition, "variant": variant, "case": case, "result": result})
                                report = {"metadata": metadata, "samples": samples, "summary": summarize(samples)}
                                (args.output / "results.json").write_text(json.dumps(report, indent=2) + "\n")
                                print(f"{repetition + 1}/{args.repetitions} {variant} {case}: {result['ops_per_sec']:.0f} ops/s p99={result['latency_ms']['p99']:.3f}ms duration={result['duration_ms']:.0f}ms", flush=True)
                finally:
                    logs = run(["amp", "orb", "service", "logs", service]).stdout
                    (args.output / f"server-{variant}-{repetition}.log").write_text(logs)
                    run(["amp", "orb", "service", "stop", service])


if __name__ == "__main__":
    main()
