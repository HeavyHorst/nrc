#!/usr/bin/env python3
"""Run CPU-explicit NRC versus SQLite retained-history comparisons."""

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE_DIR = Path(__file__).resolve().parent


def command(args, *, cwd=ROOT, env=None, cpus=None, capture=True):
    def set_affinity():
        if cpus is not None:
            os.sched_setaffinity(0, set(cpus))

    return subprocess.run(
        args,
        cwd=cwd,
        env=env,
        text=True,
        capture_output=capture,
        check=True,
        preexec_fn=set_affinity if cpus is not None else None,
    )


def duration_seconds(value):
    match = re.fullmatch(r"([0-9.]+)(ns|µs|ms|s)", value)
    if not match:
        raise ValueError(f"invalid Odin duration: {value}")
    number, unit = match.groups()
    return float(number) * {"ns": 1e-9, "µs": 1e-6, "ms": 1e-3, "s": 1}[unit]


def build_binaries(build_dir):
    sqlite_binary = build_dir / "sqlite-history"
    command([
        "cc", "-O3", "-DNDEBUG", "-pthread", str(SOURCE_DIR / "sqlite_history.c"),
        "-lsqlite3", "-o", str(sqlite_binary),
    ])
    nrc_binaries = {}
    for workload, test_name, gate in (
        ("active", "benchmark_message_store_active_history", "BENCH_MESSAGE_HISTORY_ACTIVE"),
        ("sealed", "benchmark_message_store_history_under_live_traffic", "BENCH_MESSAGE_HISTORY_LIVE"),
    ):
        binary = build_dir / f"nrc-{workload}-history"
        env = os.environ.copy()
        env[gate] = "0"
        command([
            "odin", "test", ".", "-o:speed", "-keep-executable", f"-out:{binary}",
            "-define:NRC_SIMULATION=true", "-define:ODIN_TEST_THREADS=1",
            "-define:ODIN_TEST_TRACK_MEMORY=false", "-define:ODIN_TEST_LOG_LEVEL=info",
            f"-define:ODIN_TEST_NAMES={test_name}",
        ], env=env)
        nrc_binaries[workload] = binary
    return sqlite_binary, nrc_binaries


def nrc_environment(workload, rounds, readers, write_rate, duration_seconds, write_batch_records, writer_count):
    env = os.environ.copy()
    env["NRC_MESSAGE_BENCH_CONTENT_BYTES"] = "256" if workload == "active" else "1024"
    env["NRC_MESSAGE_WRITE_BATCH_RECORDS"] = str(write_batch_records)
    if workload == "active":
        env.update({
            "BENCH_MESSAGE_HISTORY_ACTIVE": "1",
            "NRC_MESSAGE_BENCH_ACTIVE_RECORDS": "10000",
            "NRC_MESSAGE_BENCH_ACTIVE_DISTRACTORS": "5",
            "NRC_MESSAGE_BENCH_HISTORY_ROUNDS": "1",
            "NRC_MESSAGE_BENCH_ACTIVE_CONCURRENT_ROUNDS": str(rounds),
            "NRC_MESSAGE_BENCH_ACTIVE_READERS": str(readers),
        })
    else:
        env.update({
            "BENCH_MESSAGE_HISTORY_LIVE": "1",
            "NRC_MESSAGE_BENCH_RECORDS": "100000",
            "NRC_MESSAGE_BENCH_HISTORY_ROUNDS": str(rounds),
            "NRC_MESSAGE_BENCH_HISTORY_READERS": str(readers),
            "NRC_MESSAGE_BENCH_LIVE_WRITERS": str(writer_count),
            "NRC_MESSAGE_BENCH_LIVE_WRITE_RATE": str(write_rate),
            "NRC_MESSAGE_BENCH_LIVE_DURATION_MS": str(round(duration_seconds * 1000)),
        })
    return env


def parse_nrc(workload, output):
    if "test was successful" not in output:
        raise RuntimeError(f"NRC benchmark failed:\n{output[-4000:]}")
    if workload == "active":
        throughput = re.search(r"active concurrent readers=(\d+) elapsed=(\S+) pages/s=([0-9.]+)", output)
        p95 = re.search(r"active concurrent descending .*?p95=(\S+)", output)
        if not throughput or not p95:
            raise RuntimeError(f"cannot parse NRC active output:\n{output[-4000:]}")
        messages_per_page = nrc_messages_per_page(output, "active concurrent")
        return {
            "readers": int(throughput.group(1)),
            "elapsed_s": duration_seconds(throughput.group(2)),
            "pages_s": float(throughput.group(3)),
            "descending_p95_us": duration_seconds(p95.group(1)) * 1e6,
            "achieved_msg_s": 0.0,
            "messages_per_page": messages_per_page,
        }
    throughput = re.search(
        r"baseline elapsed=(\S+) pages/s=([0-9.]+); loaded elapsed=(\S+) pages/s=([0-9.]+) "
        r"live_submitted=(\d+) achieved_live_rate=([0-9.]+) msg/s",
        output,
    )
    baseline_p95 = re.search(r"baseline descending .*?p95=(\S+)", output)
    loaded_p95 = re.search(r"loaded descending .*?p95=(\S+)", output)
    loaded_max = re.search(r"loaded descending .*?max=(\S+)", output)
    submit_commit_p95 = re.search(r"sealed profile loaded write_submit_commit_publish .*?p95=(\S+).*?max=(\S+)", output)
    commit_publish_p95 = re.search(r"sealed profile loaded write_commit_publish .*?p95=(\S+).*?max=(\S+)", output)
    wal_write = re.search(r"sealed profile loaded wal_write_syscall samples=(\d+) .*?p95=(\S+)", output)
    wal_fsync = re.search(r"sealed profile loaded wal_fsync samples=(\d+) .*?p95=(\S+)", output)
    if not throughput or not baseline_p95 or not loaded_p95 or not loaded_max or not submit_commit_p95 or not commit_publish_p95 or not wal_write:
        raise RuntimeError(f"cannot parse NRC sealed output:\n{output[-4000:]}")
    baseline_pages, baseline_messages_per_page = nrc_page_summary(output, "baseline")
    loaded_pages, loaded_messages_per_page = nrc_page_summary(output, "loaded")
    if baseline_messages_per_page != loaded_messages_per_page:
        raise RuntimeError("NRC sealed page size changed under write pressure")
    return {
        "baseline_elapsed_s": duration_seconds(throughput.group(1)),
        "baseline_pages": baseline_pages,
        "baseline_pages_s": float(throughput.group(2)),
        "loaded_elapsed_s": duration_seconds(throughput.group(3)),
        "loaded_pages": loaded_pages,
        "loaded_pages_s": float(throughput.group(4)),
        "live_submitted": int(throughput.group(5)),
        "achieved_msg_s": float(throughput.group(6)),
        "baseline_descending_p95_us": duration_seconds(baseline_p95.group(1)) * 1e6,
        "loaded_descending_p95_us": duration_seconds(loaded_p95.group(1)) * 1e6,
        "loaded_descending_max_us": duration_seconds(loaded_max.group(1)) * 1e6,
        "submit_commit_p95_us": duration_seconds(submit_commit_p95.group(1)) * 1e6,
        "submit_commit_max_us": duration_seconds(submit_commit_p95.group(2)) * 1e6,
        "commit_publish_p95_us": duration_seconds(commit_publish_p95.group(1)) * 1e6,
        "commit_publish_max_us": duration_seconds(commit_publish_p95.group(2)) * 1e6,
        "wal_write_samples": int(wal_write.group(1)),
        "wal_write_p95_us": duration_seconds(wal_write.group(2)) * 1e6,
        "wal_fsync_samples": int(wal_fsync.group(1)) if wal_fsync else 0,
        "wal_fsync_p95_us": duration_seconds(wal_fsync.group(2)) * 1e6 if wal_fsync else None,
        "messages_per_page": baseline_messages_per_page,
    }


def nrc_page_summary(output, label):
    matches = re.findall(rf"{re.escape(label)} (?:ascending|descending) pages=(\d+) messages=(\d+)", output)
    if len(matches) != 2:
        raise RuntimeError(f"cannot parse NRC {label} page cardinality:\n{output[-4000:]}")
    pages = sum(int(match[0]) for match in matches)
    messages = sum(int(match[1]) for match in matches)
    return pages, messages / pages


def nrc_messages_per_page(output, label):
    return nrc_page_summary(output, label)[1]


def run_nrc_single(binary, workload, rounds, readers, write_rate, duration_seconds, write_batch_records, writer_count, cpus):
    result = command(
        [str(binary)],
        env=nrc_environment(workload, rounds, readers, write_rate, duration_seconds, write_batch_records, writer_count),
        cpus=cpus,
    )
    return parse_nrc(workload, result.stdout + result.stderr)


def wait_for_barrier(processes, ready_paths, start_path, timeout=180):
    deadline = time.monotonic() + timeout
    while not all(path.exists() for path in ready_paths):
        failed = [process for process in processes if process.poll() not in (None, 0)]
        if failed:
            raise RuntimeError("NRC scale-out worker exited before the barrier")
        if time.monotonic() >= deadline:
            raise TimeoutError(f"timed out waiting for {start_path.name}")
        time.sleep(0.01)
    start_path.write_bytes(b"")


def run_nrc_scale_out(binary, workload, rounds, worker_count, total_write_rate, duration_seconds, write_batch_records, writer_count, cpus, scratch):
    barrier_dir = scratch / "barrier"
    barrier_dir.mkdir()
    start_prefix = barrier_dir / "start"
    processes = []
    for worker in range(worker_count):
        worker_write_rate = total_write_rate // worker_count + (worker < total_write_rate % worker_count)
        env = nrc_environment(workload, rounds, 1, worker_write_rate, duration_seconds, write_batch_records, writer_count)
        env["NRC_MESSAGE_BENCH_READY_PREFIX"] = str(barrier_dir / f"ready-{worker}")
        env["NRC_MESSAGE_BENCH_START_PREFIX"] = str(start_prefix)

        def set_affinity(cpu=cpus[worker]):
            os.sched_setaffinity(0, {cpu})

        processes.append(subprocess.Popen(
            [str(binary)], cwd=ROOT, env=env, text=True,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, preexec_fn=set_affinity,
        ))
    phases = ["active"] if workload == "active" else ["baseline", "loaded"]
    for phase in phases:
        wait_for_barrier(
            processes,
            [barrier_dir / f"ready-{worker}-{phase}" for worker in range(worker_count)],
            Path(f"{start_prefix}-{phase}"),
        )
    outputs = [process.communicate(timeout=180)[0] for process in processes]
    if any(process.returncode != 0 for process in processes):
        raise RuntimeError("NRC scale-out worker failed:\n" + "\n".join(output[-2000:] for output in outputs))
    rows = [parse_nrc(workload, output) for output in outputs]
    for owner, row in enumerate(rows):
        row["owner"] = owner
        row["cpu_id"] = cpus[owner]
        row["offered_msg_s"] = (
            total_write_rate // worker_count + (owner < total_write_rate % worker_count)
            if workload == "sealed" else 0
        )
    if any(row["messages_per_page"] != rows[0]["messages_per_page"] for row in rows):
        raise RuntimeError("NRC scale-out workers returned different page cardinalities")
    if workload == "active":
        elapsed = max(row["elapsed_s"] for row in rows)
        return {
            "workers": worker_count,
            "readers": worker_count,
            "elapsed_s": elapsed,
            "pages_s": worker_count * rounds / elapsed,
            "descending_p95_us": statistics.median(row["descending_p95_us"] for row in rows),
            "achieved_msg_s": 0.0,
            "messages_per_page": rows[0]["messages_per_page"],
        }
    baseline_elapsed = max(row["baseline_elapsed_s"] for row in rows)
    loaded_elapsed = max(row["loaded_elapsed_s"] for row in rows)
    wal_fsync_p95s = [row["wal_fsync_p95_us"] for row in rows if row["wal_fsync_p95_us"] is not None]
    return {
        "workers": worker_count,
        "readers": worker_count,
        "baseline_elapsed_s": baseline_elapsed,
        "baseline_pages": sum(row["baseline_pages"] for row in rows),
        "baseline_pages_s": sum(row["baseline_pages"] for row in rows) / baseline_elapsed,
        "loaded_elapsed_s": loaded_elapsed,
        "loaded_pages": sum(row["loaded_pages"] for row in rows),
        "loaded_pages_s": sum(row["loaded_pages"] for row in rows) / loaded_elapsed,
        "live_submitted": sum(row["live_submitted"] for row in rows),
        "achieved_msg_s": sum(row["live_submitted"] for row in rows) / loaded_elapsed,
        "baseline_descending_p95_us": statistics.median(row["baseline_descending_p95_us"] for row in rows),
        "loaded_descending_p95_us": statistics.median(row["loaded_descending_p95_us"] for row in rows),
        "loaded_descending_max_us": max(row["loaded_descending_max_us"] for row in rows),
        "submit_commit_p95_us": statistics.median(row["submit_commit_p95_us"] for row in rows),
        "submit_commit_max_us": max(row["submit_commit_max_us"] for row in rows),
        "commit_publish_p95_us": statistics.median(row["commit_publish_p95_us"] for row in rows),
        "commit_publish_max_us": max(row["commit_publish_max_us"] for row in rows),
        "wal_write_samples": sum(row["wal_write_samples"] for row in rows),
        "wal_write_p95_us": statistics.median(row["wal_write_p95_us"] for row in rows),
        "wal_fsync_samples": sum(row["wal_fsync_samples"] for row in rows),
        "wal_fsync_p95_us": statistics.median(wal_fsync_p95s) if wal_fsync_p95s else None,
        "messages_per_page": rows[0]["messages_per_page"],
        "owner_results": rows,
    }


def run_sqlite(binary, workload, rounds, readers, write_rate, duration_seconds, cpus, scratch):
    records = 10000 if workload == "active" else 100000
    content_bytes = 256 if workload == "active" else 1024
    distractors = 5 if workload == "active" else 0

    def run_phase(name, target_rate, phase_duration_seconds=0):
        result = command([
            str(binary), str(scratch / f"sqlite-{name}.db"), str(records), str(content_bytes),
            str(rounds), str(readers), str(target_rate), str(distractors), str(round(phase_duration_seconds * 1000)),
        ], cpus=cpus)
        row = json.loads(result.stdout)
        row["observed_affinity_cpu_count"] = row.pop("affinity_cpus")
        return row

    idle = run_phase("idle", 0)
    if workload == "active":
        return idle
    loaded = run_phase("loaded", write_rate, duration_seconds)
    if idle["messages_per_page"] != loaded["messages_per_page"]:
        raise RuntimeError("SQLite sealed page size changed under write pressure")
    return {
        "readers": readers,
        "writer_threads": loaded["writer_threads"],
        "observed_affinity_cpu_count": loaded["observed_affinity_cpu_count"],
        "baseline_elapsed_s": idle["elapsed_s"],
        "baseline_pages": idle["pages"],
        "baseline_pages_s": idle["pages_s"],
        "loaded_elapsed_s": loaded["elapsed_s"],
        "loaded_pages": loaded["pages"],
        "loaded_pages_s": loaded["pages_s"],
        "achieved_msg_s": loaded["achieved_msg_s"],
        "baseline_descending_p95_us": idle["descending_p95_us"],
        "loaded_descending_p95_us": loaded["descending_p95_us"],
        "checksum": loaded["checksum"],
        "messages_per_page": loaded["messages_per_page"],
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--logical-cpus", type=int, default=4)
    parser.add_argument("--cpu-list", help="explicit comma-separated logical CPU IDs; overrides --logical-cpus")
    parser.add_argument("--rounds", type=int, default=1000)
    parser.add_argument("--write-rate", type=int, default=25000)
    parser.add_argument("--duration-seconds", type=float, default=2.0, help="fixed duration for the sealed loaded phase")
    parser.add_argument("--nrc-batch-records", type=int, default=16, help="NRC retained-message records per group commit; 0 disables the record cap")
    parser.add_argument("--nrc-writers", type=int, default=8, help="NRC writer connections per owning worker")
    parser.add_argument(
        "--topology",
        choices=("all", "hot_owner_parallel_sqlite", "hot_owner_single_cpu", "scale_out_matched_cpus"),
        default="all",
    )
    parser.add_argument("--workload", choices=("active", "sealed", "all"), default="all")
    parser.add_argument("--output", type=Path, default=ROOT / ".benchmark-results/message-history-cpu.json")
    args = parser.parse_args()
    if args.duration_seconds < 0.001 or args.duration_seconds > 10:
        parser.error("--duration-seconds must be at least 0.001 and at most 10")
    if args.nrc_batch_records < 0 or args.nrc_batch_records > 1024:
        parser.error("--nrc-batch-records must be between 0 and 1024")
    if args.nrc_writers < 1 or args.nrc_writers > 14:
        parser.error("--nrc-writers must be between 1 and 14")
    args.duration_seconds = round(args.duration_seconds * 1000) / 1000
    allowed_cpus = sorted(os.sched_getaffinity(0))
    if args.cpu_list:
        try:
            cpus = [int(cpu) for cpu in args.cpu_list.split(",")]
        except ValueError:
            parser.error("--cpu-list must contain comma-separated integer CPU IDs")
        if not cpus or len(cpus) > 8 or len(set(cpus)) != len(cpus) or not set(cpus) <= set(allowed_cpus):
            parser.error(f"--cpu-list must contain 1-8 unique CPUs from {allowed_cpus}")
    else:
        if args.logical_cpus < 1 or args.logical_cpus > min(8, len(allowed_cpus)):
            parser.error(f"--logical-cpus must be between 1 and {min(8, len(allowed_cpus))}")
        cpus = allowed_cpus[:args.logical_cpus]
    cpu_count = len(cpus)
    if args.nrc_writers > 15 - cpu_count:
        parser.error(f"--nrc-writers must be at most {15 - cpu_count} with {cpu_count} readers")
    workloads = ("active", "sealed") if args.workload == "all" else (args.workload,)
    topologies = (
        ("hot_owner_parallel_sqlite", "hot_owner_single_cpu", "scale_out_matched_cpus")
        if args.topology == "all" else (args.topology,)
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    rows = []
    with tempfile.TemporaryDirectory(prefix="nrc-message-history-") as temporary:
        build_dir = Path(temporary)
        sqlite_binary, nrc_binaries = build_binaries(build_dir)
        for workload in workloads:
            for run in range(1, args.runs + 1):
                for topology in topologies:
                    scratch = build_dir / f"{workload}-{run}-{topology}"
                    scratch.mkdir()
                    if topology == "scale_out_matched_cpus":
                        nrc = run_nrc_scale_out(
                            nrc_binaries[workload], workload, args.rounds, cpu_count,
                            args.write_rate, args.duration_seconds, args.nrc_batch_records, args.nrc_writers, cpus, scratch,
                        )
                        nrc_cpus = cpus
                    else:
                        nrc = run_nrc_single(
                            nrc_binaries[workload], workload, args.rounds, cpu_count,
                            args.write_rate, args.duration_seconds, args.nrc_batch_records, args.nrc_writers, cpus[:1],
                        )
                        nrc_cpus = cpus[:1]
                    sqlite_cpus = cpus[:1] if topology == "hot_owner_single_cpu" else cpus
                    sqlite = run_sqlite(
                        sqlite_binary, workload, args.rounds, cpu_count,
                        args.write_rate, args.duration_seconds, sqlite_cpus, scratch,
                    )
                    expected_messages_per_page = 100.0 if workload == "active" else 91.0
                    for backend, result in (("NRC", nrc), ("SQLite", sqlite)):
                        if result["messages_per_page"] != expected_messages_per_page:
                            raise RuntimeError(
                                f"{backend} {workload} returned {result['messages_per_page']} messages/page; "
                                f"expected {expected_messages_per_page}"
                            )
                    for backend, result, affinity in (("nrc", nrc, nrc_cpus), ("sqlite", sqlite, sqlite_cpus)):
                        rows.append({
                            "run": run,
                            "workload": workload,
                            "topology": topology,
                            "backend": backend,
                            "cpu_ids": affinity,
                            **result,
                        })
                    print(f"completed workload={workload} run={run} topology={topology}", flush=True)
    commit = command(["git", "rev-parse", "HEAD"]).stdout.strip()
    source_files = [
        ROOT / "message_store_benchmark.odin",
        ROOT / "retained_message_handlers.odin",
        ROOT / "message_store.odin",
        ROOT / "message_store_runtime.odin",
        ROOT / "runtime_simulation.odin",
        SOURCE_DIR / "run_comparison.py",
        SOURCE_DIR / "sqlite_history.c",
        SOURCE_DIR / "render_portal.py",
    ]
    source_hash = hashlib.sha256()
    for source in source_files:
        source_hash.update(source.relative_to(ROOT).as_posix().encode())
        source_hash.update(source.read_bytes())
    payload = {
        "schema": 1,
        "base_commit": commit,
        "worktree_dirty": bool(command(["git", "status", "--porcelain"]).stdout),
        "benchmark_source_sha256": source_hash.hexdigest(),
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "logical_cpus": cpus,
        "rounds": args.rounds,
        "runs": args.runs,
        "write_rate": args.write_rate,
        "nrc_write_batch_records": args.nrc_batch_records,
        "nrc_writer_connections_per_owner": args.nrc_writers,
        "loaded_duration_seconds": args.duration_seconds,
        "topologies": {
            "hot_owner_parallel_sqlite": "one NRC owning worker on one logical CPU versus SQLite reader threads on all listed logical CPUs",
            "hot_owner_single_cpu": "one NRC owning worker and all SQLite reader threads restricted to the same one logical CPU",
            "scale_out_matched_cpus": "independent NRC workers/workspaces versus SQLite reader threads, both using the same logical CPU count",
        },
        "rows": rows,
    }
    args.output.write_text(json.dumps(payload, indent=2) + "\n")
    print(args.output)


if __name__ == "__main__":
    main()
