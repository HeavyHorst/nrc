#!/usr/bin/env python3
"""Run a prebuilt main.benchmark_wal_replay binary; retain every checked sample."""
import json
import os
from pathlib import Path
import re
import statistics
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
fixtures = Path(sys.argv[2]).resolve()
output = Path(sys.argv[3]).resolve()
output.mkdir(exist_ok=False, parents=True)
worker_counts = tuple(map(int, os.environ.get("NRC_REPLAY_BENCH_WORKER_COUNTS", "1 2 4 8 16").split()))
assert worker_counts and 1 in worker_counts and len(set(worker_counts)) == len(worker_counts)
assert all(1 <= n <= 16 for n in worker_counts)
cases = [(kind, workers) for kind in ("task", "asset", "mixed")
         for workers in worker_counts]
pattern = re.compile(r"REPLAY_RESULT kind=(\w+) workers=(\d+) records=(\d+) "
                     r"seconds=([\d.]+) records_per_second=([\d.]+)")
samples = []


def run(kind, workers, label):
    env = dict(os.environ, NRC_REPLAY_BENCH_DIR=str(fixtures / kind),
               NRC_REPLAY_BENCH_KIND=kind, NRC_REPLAY_BENCH_WORKERS=str(workers),
               NRC_REPLAY_BENCH_MODE="replay")
    result = subprocess.run([binary], env=env, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=300)
    (output / f"{label}-{kind}-{workers}.log").write_text(result.stdout)
    match = pattern.search(result.stdout)
    if result.returncode or not match or "The test was successful" not in result.stdout:
        raise RuntimeError(f"Failed {label}/{kind}/{workers}; inspect retained log")
    assert match[1] == kind and int(match[2]) == workers
    sample = dict(kind=kind, workers=workers, records=int(match[3]),
                  seconds=float(match[4]), records_per_second=float(match[5]))
    print(label, json.dumps(sample), flush=True)
    return sample


# Untimed pilots initialize managed manifests and exercise every CPU configuration.
for kind, workers in cases:
    run(kind, workers, "pilot")
for repetition in range(10):
    order = cases[repetition % len(cases):] + cases[:repetition % len(cases)]
    if repetition % 2:
        order = list(reversed(order))
    for kind, workers in order:
        sample = run(kind, workers, f"run-{repetition:02d}")
        sample["repetition"] = repetition
        sample["wal_bytes"] = sum(p.stat().st_size for p in (fixtures / kind).rglob("*.wal"))
        samples.append(sample)
        (output / "samples.json").write_text(json.dumps(samples, indent=2) + "\n")

summary = []
for kind, workers in cases:
    selected = [s for s in samples if s["kind"] == kind and s["workers"] == workers]
    rates = [s["records_per_second"] for s in selected]
    seconds = [s["seconds"] for s in selected]
    baseline = statistics.median(s["records_per_second"] for s in samples
                                 if s["kind"] == kind and s["workers"] == 1)
    row = dict(kind=kind, workers=workers, samples=len(selected),
               median_records_per_second=statistics.median(rates),
               min_records_per_second=min(rates), max_records_per_second=max(rates),
               median_seconds=statistics.median(seconds),
               wal_MB_per_second=selected[0]["wal_bytes"] / statistics.median(seconds) / 1e6,
               speedup=statistics.median(rates) / baseline)
    summary.append(row)
(output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
print(json.dumps(summary, indent=2), flush=True)
