#!/usr/bin/env python3
"""Benchmark NRC-compatible 256-bit hash chains using -o:speed builds."""

import argparse
import json
import os
import platform
import re
import statistics
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
ALGORITHMS = ("sha256", "sha512_256", "sha3_256", "blake2s_256", "blake2b_256", "sm3")
TARGET_MIB = {
    "sha256": 768,
    "sha512_256": 160,
    "sha3_256": 96,
    "blake2s_256": 320,
    "blake2b_256": 448,
    "sm3": 128,
}
RESULT_RE = re.compile(r"HASH_CHAIN_RESULT (?P<fields>.+)")
FIELD_RE = re.compile(r"(\w+)=([A-Za-z0-9_.]+)")


def run(command, *, env=None):
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        output = (result.stdout + result.stderr)[-4000:]
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(map(str, command))}\n{output}")
    return result


def parse_result(output, payload_bytes, repetition):
    match = RESULT_RE.search(output)
    if not match:
        raise RuntimeError(f"cannot parse hash benchmark output:\n{output[-4000:]}")
    fields = dict(FIELD_RE.findall(match.group("fields")))
    row = {
        "algorithm": fields["algorithm"],
        "payload_bytes": payload_bytes,
        "record_bytes": int(fields["record_bytes"]),
        "rounds": int(fields["rounds"]),
        "processed_bytes": int(fields["processed_bytes"]),
        "elapsed_ns": int(fields["elapsed_ns"]),
        "hashes_per_s": float(fields["hashes_per_s"]),
        "mib_per_s": float(fields["mib_per_s"]),
        "checksum": int(fields["checksum"]),
        "repetition": repetition,
    }
    return row


def summarize(rows):
    summaries = []
    for payload_bytes in sorted({row["payload_bytes"] for row in rows}):
        for algorithm in ALGORITHMS:
            group = [
                row for row in rows
                if row["payload_bytes"] == payload_bytes and row["algorithm"] == algorithm
            ]
            summary = {
                "algorithm": algorithm,
                "payload_bytes": payload_bytes,
                "record_bytes": group[0]["record_bytes"],
                "rounds": group[0]["rounds"],
                "samples": len(group),
            }
            for metric in ("hashes_per_s", "mib_per_s"):
                values = sorted(row[metric] for row in group)
                quartiles = (
                    statistics.quantiles(values, n=4, method="inclusive")
                    if len(values) > 1 else [values[0], values[0], values[0]]
                )
                summary[metric] = {
                    "median": statistics.median(values),
                    "min": values[0],
                    "q1": quartiles[0],
                    "q3": quartiles[2],
                    "max": values[-1],
                }
            summaries.append(summary)
    return summaries


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--sizes", default="64,256,1024,4096,16384")
    parser.add_argument(
        "--target-mib",
        type=int,
        default=0,
        help="override per-algorithm sample sizes with one MiB target",
    )
    args = parser.parse_args()
    payload_sizes = [int(value) for value in args.sizes.split(",")]
    args.output.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory(prefix="nrc-hash-chain-") as temp:
        binary = Path(temp) / "hash-chain-benchmark"
        build_flags = ["-o:speed", f"-out:{binary}"]
        run(["odin", "build", "benchmark/hash-chain", *build_flags])
        rows = []
        for repetition in range(args.runs):
            sizes = payload_sizes[repetition % len(payload_sizes):] + payload_sizes[:repetition % len(payload_sizes)]
            for size_index, payload_bytes in enumerate(sizes):
                record_bytes = payload_bytes + 52
                rotation = (repetition + size_index) % len(ALGORITHMS)
                algorithms = ALGORITHMS[rotation:] + ALGORITHMS[:rotation]
                for algorithm in algorithms:
                    target_mib = args.target_mib or TARGET_MIB[algorithm]
                    rounds = max(1, target_mib * 1024 * 1024 // record_bytes)
                    env = os.environ.copy()
                    env.update({
                        "NRC_HASH_BENCH_ALGORITHM": algorithm,
                        "NRC_HASH_BENCH_RECORD_BYTES": str(record_bytes),
                        "NRC_HASH_BENCH_ROUNDS": str(rounds),
                    })
                    result = run([str(binary)], env=env)
                    row = parse_result(result.stdout + result.stderr, payload_bytes, repetition + 1)
                    rows.append(row)
                    print(
                        f"run {repetition + 1}/{args.runs} {algorithm:13s} {payload_bytes:5d}B "
                        f"{row['mib_per_s']:8.1f} MiB/s {row['hashes_per_s']:10.0f} hash/s",
                        flush=True,
                    )

    cpu = run(["lscpu"]).stdout
    data = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "platform": platform.platform(),
        "cpu_model": next(
            (line.split(":", 1)[1].strip() for line in cpu.splitlines() if line.startswith("Model name:")),
            "unknown",
        ),
        "odin_version": run(["odin", "version"]).stdout.strip(),
        "build_flags": ["-o:speed"],
        "runs": args.runs,
        "payload_sizes": payload_sizes,
        "record_header_bytes": 52,
        "target_mib_override": args.target_mib,
        "target_mib_by_algorithm": TARGET_MIB,
        "algorithms": list(ALGORITHMS),
        "semantics": "fresh context per record; previous 32-byte digest copied into WAL header before hashing",
        "rows": rows,
        "summaries": summarize(rows),
    }
    (args.output / "hash-results.json").write_text(json.dumps(data, indent=2) + "\n")


if __name__ == "__main__":
    main()
