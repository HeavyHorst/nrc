#!/usr/bin/env python3
"""Run WAL, retained-message, task, and asset write sweeps with perf profiles."""

import argparse
import json
import os
import platform
import re
import shutil
import statistics
import subprocess
import tempfile
import time
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
WORKLOADS = ("wal", "retained", "task", "asset")
RETAINED_BATCH_RECORDS = 16
RESULT_RE = re.compile(r"(WAL|RETAINED|TASK|ASSET)_WRITE_RESULT (?P<fields>.+)")
FIELD_RE = re.compile(r"(\w+)=([0-9.]+)")


def run(command, *, env=None, capture=True):
    result = subprocess.run(
        command,
        cwd=ROOT,
        env=env,
        text=True,
        capture_output=capture,
        check=False,
    )
    if result.returncode != 0:
        output = ((result.stdout or "") + (result.stderr or ""))[-4000:]
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, command))}\n{output}")
    return result


def build_binaries(build_dir):
    wal = build_dir / "wal-write-benchmark"
    retained = build_dir / "retained-write-benchmark"
    entity = build_dir / "entity-write-benchmark"
    common = [
        "-o:speed",
        "-keep-executable",
        "-define:ODIN_TEST_THREADS=1",
        "-define:ODIN_TEST_TRACK_MEMORY=false",
        "-define:ODIN_TEST_LOG_LEVEL=info",
    ]
    run([
        "odin", "test", "persistence/", *common, f"-out:{wal}",
        "-define:ODIN_TEST_NAMES=persistence.benchmark_wal_write_throughput",
    ])
    run([
        "odin", "test", ".", *common, f"-out:{retained}",
        "-define:ODIN_TEST_NAMES=main.benchmark_message_store_write_throughput",
    ])
    run([
        "odin", "test", ".", *common, f"-out:{entity}",
        "-define:ODIN_TEST_NAMES=main.benchmark_entity_write_throughput",
    ])
    return {"wal": wal, "retained": retained, "task": entity, "asset": entity}


def record_count(workload, size, target_mib):
    # Fixed record overheads for these benchmark fixtures, including the outer
    # WAL header and, for task/asset writes, the shard transaction envelope.
    overhead = {"wal": 52, "retained": 164, "task": 250, "asset": 183}[workload]
    target_bytes = target_mib * 1024 * 1024
    records = max(1, target_bytes // (size + overhead))
    # Keep the retained workload in one active segment. At very small payloads,
    # its 64 MiB active-index budget is reached before a 128 MiB WAL is built.
    if workload == "retained":
        records = min(records, 100_000)
    return records


def benchmark_environment(workload, size, records):
    env = os.environ.copy()
    if workload == "wal":
        env.update({
            "BENCH_WAL_WRITE": "1",
            "NRC_WAL_BENCH_PAYLOAD_BYTES": str(size),
            "NRC_WAL_BENCH_RECORDS": str(records),
        })
    elif workload == "retained":
        env.update({
            "BENCH_MESSAGE_STORE_WRITE": "1",
            "NRC_MESSAGE_BENCH_CONTENT_BYTES": str(size),
            "NRC_MESSAGE_BENCH_RECORDS": str(records),
            "NRC_MESSAGE_WRITE_BATCH_RECORDS": str(RETAINED_BATCH_RECORDS),
        })
    else:
        env.update({
            "BENCH_ENTITY_WRITE": "1",
            "NRC_ENTITY_BENCH_KIND": workload,
            "NRC_ENTITY_BENCH_PAYLOAD_BYTES": str(size),
            "NRC_ENTITY_BENCH_RECORDS": str(records),
        })
    return env


def parse_result(output, workload, size, repetition):
    match = RESULT_RE.search(output)
    if not match:
        raise RuntimeError(f"cannot parse {workload} benchmark output:\n{output[-4000:]}")
    fields = {name: float(value) for name, value in FIELD_RE.findall(match.group("fields"))}
    integer_fields = {
        "payload_bytes", "content_bytes", "record_bytes", "records", "wal_bytes",
        "elapsed_ns", "write_calls", "fsyncs", "batch_records",
    }
    for name in integer_fields & fields.keys():
        fields[name] = int(fields[name])
    fields.update({"workload": workload, "size_bytes": size, "repetition": repetition})
    return fields


def summarize(rows):
    summaries = []
    for workload in WORKLOADS:
        for size in sorted({row["size_bytes"] for row in rows}):
            group = [row for row in rows if row["workload"] == workload and row["size_bytes"] == size]
            summary = {
                "workload": workload,
                "size_bytes": size,
                "samples": len(group),
                "record_bytes": group[0]["record_bytes"],
                "records_per_sample": group[0]["records"],
                "write_calls_per_sample": statistics.median(row["write_calls"] for row in group),
                "fsyncs_per_sample": statistics.median(row["fsyncs"] for row in group),
            }
            for metric in ("messages_per_s", "mib_per_s"):
                values = sorted(row[metric] for row in group)
                quartiles = statistics.quantiles(values, n=4, method="inclusive")
                summary[metric] = {
                    "median": statistics.median(values),
                    "min": values[0],
                    "q1": quartiles[0],
                    "q3": quartiles[2],
                    "max": values[-1],
                }
            summaries.append(summary)
    return summaries


def perf_profile(binary, workload, size, target_mib, output_dir):
    records = record_count(workload, size, target_mib)
    data_path = output_dir / f"perf-{workload}-{size}.data"
    report_path = output_dir / f"perf-{workload}-{size}.txt"
    env = benchmark_environment(workload, size, records)
    barrier = output_dir / f"perf-barrier-{workload}-{size}"
    ready = Path(f"{barrier}-ready-write-throughput")
    start = Path(f"{barrier}-start-write-throughput")
    ready.unlink(missing_ok=True)
    start.unlink(missing_ok=True)
    if workload == "wal":
        env["NRC_WAL_BENCH_READY_PREFIX"] = f"{barrier}-ready"
        env["NRC_WAL_BENCH_START_PREFIX"] = f"{barrier}-start"
    elif workload == "retained":
        env["NRC_MESSAGE_BENCH_READY_PREFIX"] = f"{barrier}-ready"
        env["NRC_MESSAGE_BENCH_START_PREFIX"] = f"{barrier}-start"
    else:
        env["NRC_ENTITY_BENCH_READY_PREFIX"] = f"{barrier}-ready"
        env["NRC_ENTITY_BENCH_START_PREFIX"] = f"{barrier}-start"

    benchmark = subprocess.Popen(
        [str(binary)], cwd=ROOT, env=env, text=True,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )
    deadline = time.monotonic() + 30
    while not ready.exists():
        if benchmark.poll() is not None:
            raise RuntimeError(f"{workload} benchmark exited before perf barrier:\n{benchmark.stdout.read()}")
        if time.monotonic() >= deadline:
            benchmark.terminate()
            raise TimeoutError(f"timed out waiting for {ready}")
        time.sleep(0.01)
    # Hardware PMU events are commonly unavailable in Amp orbs. cpu-clock:u is
    # still perf sampling and gives useful user-space self-time attribution.
    perf = subprocess.Popen([
        "perf", "record", "-q", "-e", "cpu-clock:u", "-F", "999", "-g",
        "--call-graph", "dwarf", "-o", str(data_path), "-p", str(benchmark.pid),
    ], cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    time.sleep(0.2)
    start.write_bytes(b"")
    benchmark_output = benchmark.communicate(timeout=120)[0]
    perf_output = perf.communicate(timeout=30)[0]
    ready.unlink(missing_ok=True)
    start.unlink(missing_ok=True)
    if benchmark.returncode != 0:
        raise RuntimeError(f"profiled {workload} benchmark failed:\n{benchmark_output[-4000:]}")
    if perf.returncode != 0:
        raise RuntimeError(f"perf failed for {workload} {size}:\n{perf_output[-4000:]}")
    report = run([
        "perf", "report", "--stdio", "-i", str(data_path), "--no-children",
        "-g", "none", "--sort=symbol,dso", "--percent-limit", "0.2",
    ]).stdout
    report_path.write_text(report)
    hotspots = []
    line_re = re.compile(r"^\s*([0-9.]+)%\s+\[.\]\s+(.+)$")
    for line in report.splitlines():
        match = line_re.match(line)
        if not match:
            continue
        columns = re.split(r"\s{2,}", match.group(2).strip())
        if len(columns) < 2:
            continue
        hotspots.append({
            "percent": float(match.group(1)),
            "symbol": columns[0],
            "object": columns[1],
        })
        if len(hotspots) == 12:
            break
    return {
        "workload": workload,
        "size_bytes": size,
        "event": "cpu-clock:u",
        "frequency_hz": 999,
        "records": records,
        "hotspots": hotspots,
        "report": report_path.name,
    }


def git_output(*args):
    return run(["git", *args]).stdout.strip()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--sizes", default="64,256,1024,4096,16384")
    parser.add_argument("--target-mib", type=int, default=128)
    parser.add_argument("--perf-target-mib", type=int, default=192)
    parser.add_argument("--skip-perf", action="store_true")
    args = parser.parse_args()
    sizes = [int(value) for value in args.sizes.split(",")]
    args.output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="nrc-wal-retained-") as temp:
        binaries = build_binaries(Path(temp))
        rows = []
        # Rotate size order on each repetition to reduce monotonic-order bias.
        for repetition in range(args.runs):
            ordered_sizes = sizes[repetition % len(sizes):] + sizes[:repetition % len(sizes)]
            for size in ordered_sizes:
                for workload in WORKLOADS:
                    records = record_count(workload, size, args.target_mib)
                    result = run(
                        [str(binaries[workload])],
                        env=benchmark_environment(workload, size, records),
                    )
                    rows.append(parse_result(result.stdout + result.stderr, workload, size, repetition + 1))
                    print(
                        f"run {repetition + 1}/{args.runs} {workload:8s} {size:5d}B "
                        f"{rows[-1]['mib_per_s']:8.1f} MiB/s {rows[-1]['messages_per_s']:10.0f} msg/s",
                        flush=True,
                    )

        profiles = []
        if not args.skip_perf:
            for workload in WORKLOADS:
                for size in (sizes[0], sizes[-1]):
                    profiles.append(perf_profile(
                        binaries[workload], workload, size, args.perf_target_mib, args.output,
                    ))

    cpu = run(["lscpu"]).stdout
    data = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "commit": git_output("rev-parse", "--short", "HEAD"),
        "worktree_dirty": bool(git_output("status", "--short")),
        "platform": platform.platform(),
        "cpu_model": next(
            (line.split(":", 1)[1].strip() for line in cpu.splitlines() if line.startswith("Model name:")),
            "unknown",
        ),
        "logical_cpus": len(os.sched_getaffinity(0)),
        "odin_version": run(["odin", "version"]).stdout.strip(),
        "runs": args.runs,
        "sizes_bytes": sizes,
        "target_mib_per_sample": args.target_mib,
        "retained_record_cap": 100_000,
        "retained_batch_records": RETAINED_BATCH_RECORDS,
        "perf_target_mib": args.perf_target_mib,
        "perf_hardware_events_available": False,
        "durability": "production 100 MiB / 1 s threshold fsync; final shutdown fsync excluded",
        "cache_state": "new files; OS page cache not dropped",
        "rows": rows,
        "summaries": summarize(rows),
        "profiles": profiles,
    }
    (args.output / "results.json").write_text(json.dumps(data, indent=2) + "\n")
    shutil.copy2(Path(__file__).with_name("render_portal.py"), args.output / "render_portal.py")
    run(["python3", str(Path(__file__).with_name("render_portal.py")), str(args.output / "results.json"), str(args.output)])


if __name__ == "__main__":
    main()
