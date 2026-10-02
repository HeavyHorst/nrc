#!/usr/bin/env python3
"""Run under `amp orb service start`: fresh servers, calibrated, rotated samples."""
import argparse
import itertools
import json
import math
import os
from pathlib import Path
import signal
import socket
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("server", type=Path)
    parser.add_argument("redis", type=Path)
    parser.add_argument("client", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--repetitions", type=int, default=10)
    parser.add_argument("--variant", action="append", default=[], metavar="LABEL=BINARY",
                        help="Compare NRC policy binaries instead of Redis")
    parser.add_argument("--payload", action="append", type=int, choices=[64, 1024, 16384])
    args = parser.parse_args()
    variants = dict(item.split("=", 1) for item in args.variant)
    cases = list(itertools.product([64, 1024, 16384],
                                  ["single", "pipeline", "batch", "batch-pipeline"],
                                  list(variants) if variants else ["nrc", "always", "everysec"]))
    if args.payload:
        cases = [case for case in cases if case[0] in args.payload]
    # Preserve failed attempts if the supervisor restarts the campaign.
    args.output.mkdir(parents=True, exist_ok=False)

    def sample(case, rounds, label):
        size, shape, mode = case
        stem = args.output / f"{label}-{size}-{shape}-{mode}"
        is_nrc = bool(variants) or mode == "nrc"
        port = 18089 if is_nrc else 18090
        with tempfile.TemporaryDirectory(prefix="nrc-redis-comparison-") as scratch:
            env = os.environ.copy()
            if is_nrc:
                env.update(NRC_PORT=str(port), NRC_THREAD_COUNT="1",
                           NRC_DISABLE_CPU_AFFINITY="1", NRC_JWT_SECRET="dev-insecure-nrc-jwt-secret")
                command = [variants[mode] if variants else str(args.server)]
            else:
                command = [str(args.redis), "--bind", "127.0.0.1", "--port", str(port),
                           "--save", "", "--appendonly", "yes", "--appendfsync", mode,
                           "--auto-aof-rewrite-percentage", "0", "--io-threads", "1",
                           "--no-appendfsync-on-rewrite", "no"]
            with open(str(stem) + "-server.log", "w") as log:
                server = subprocess.Popen(["taskset", "-c", "0"] + command,
                                          cwd=scratch, env=env, stdout=log, stderr=log)
                try:
                    deadline = time.monotonic() + 30
                    while True:
                        if server.poll() is not None:
                            raise RuntimeError(f"server exited: {stem}")
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                                break
                        except OSError:
                            if time.monotonic() > deadline:
                                raise TimeoutError(f"server readiness: {stem}")
                            time.sleep(.05)
                    env.update(KV_COMPARE_BACKEND="nrc" if is_nrc else "redis",
                               KV_COMPARE_SHAPE=shape, KV_COMPARE_BYTES=str(size),
                               KV_COMPARE_ROUNDS=str(rounds), KV_COMPARE_OUTPUT=str(stem) + ".json")
                    with open(str(stem) + "-client.log", "w") as client_log:
                        subprocess.run(["taskset", "-c", "2", str(args.client),
                                        "-test.run", "^TestRedisComparison$", "-test.v", "-test.timeout=2m"],
                                       env=env, stdout=client_log, stderr=client_log, check=True, timeout=150)
                finally:
                    server.send_signal(signal.SIGINT)
                    try:
                        server.wait(timeout=30)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait()
                        raise
                    # io_uring can retain the listening socket briefly after exit.
                    # Do not mistake that old listener for the next server's readiness.
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            with socket.create_connection(("127.0.0.1", port), timeout=.1):
                                pass
                        except OSError:
                            break
                        if time.monotonic() > deadline:
                            raise TimeoutError(f"listener did not close: {stem}")
                        time.sleep(.05)
        result = json.loads(Path(str(stem) + ".json").read_text())
        result.update(mode=mode, sample=label, rounds=rounds, shape=shape)
        Path(str(stem) + ".json").write_text(json.dumps(result, indent=2))
        print(label, case, round(result["updates_per_sec"]), flush=True)
        return result

    rounds = {}
    for case in cases:
        pilot = sample(case, 256, "pilot")
        rounds[case] = max(100, math.ceil(256 * 1000 / pilot["duration_ms"]))
    results = []
    for rep in range(args.repetitions):
        order = cases[rep:] + cases[:rep]
        if rep % 2:
            order = list(reversed(order))
        for case in order:
            results.append(sample(case, rounds[case], f"sample-{rep}"))
            (args.output / "results.json").write_text(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
