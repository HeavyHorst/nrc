#!/usr/bin/env python3
"""One-worker probe campaign; consumes prebuilt binaries, never builds Odin.

Production thresholds need substantial traffic (256MiB message segments,
500MiB shard WALs). Missing activity fails a case, never silently passes.
The optional asset workload demonstrates concurrent compaction, NOT queue depth:
production exposes no queue-residency telemetry. Use simulation for that claim.
"""
import argparse
import hashlib
import json
import pathlib
import shlex
import socket
import statistics
import subprocess
import tempfile
import time

from run import run


def positive(value):
    value = int(value)
    if value <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return value


def published_checkpoints(directory):
    """Record atomically published production manifests, never staging files."""
    found = {}
    for path in pathlib.Path(directory).rglob("shard.manifest"):
        data = path.read_bytes()
        if (len(data) == 56 and data[:6] == b"NRCK\x00\x01"
                and int.from_bytes(data[6:8], "big") & 1
                and int.from_bytes(data[24:32], "big") > 0
                # Rotation sets both equal; compaction publication changes
                # checkpoint generation while keeping the current active WAL.
                and data[24:32] != data[40:48]):
            found[str(path.relative_to(directory))] = data.hex()
    return found


def published_message_indexes(directory):
    """Ignore staged indexes: only sealed descriptors in published manifests."""
    found = set()
    for manifest in pathlib.Path(directory).glob("**/messages/manifest"):
        data = manifest.read_bytes()
        if len(data) < 64 or data[:6] != b"1GSM\x03\x00":
            raise RuntimeError("unexpected message manifest format")
        count = int.from_bytes(data[40:44], "little")
        frozen = int.from_bytes(data[44:48], "little")
        if len(data) != 64 + (count + frozen) * 48:
            raise RuntimeError("invalid message manifest length")
        for i in range(count):
            generation = int.from_bytes(data[64 + i * 48:72 + i * 48], "little")
            index = manifest.parent / f"segment-{generation:020d}.idx"
            if index.exists():
                found.add(str(index.relative_to(directory)))
    return found


def measured_activity(observations, start_ns, end_ns):
    """Only transitions between observations inside the timed probe window."""
    measured = [o for o in observations if start_ns <= o["unix_ns"] <= end_ns]
    sealed, removed, checkpoints = set(), set(), {}
    published = {index for o in observations if o["unix_ns"] <= start_ns for index in o["indexes"]}
    for before, after in zip(measured, measured[1:]):
        published.update(before["indexes"])
        sealed.update(set(after["indexes"]) - set(before["indexes"]))
        removed.update(published & (set(before["disk_indexes"]) - set(after["disk_indexes"])))
        checkpoints.update({k: v for k, v in after["checkpoints"].items()
                            if before["checkpoints"].get(k) != v})
    return {"sealed_during_probe": sorted(sealed), "removed_during_probe": sorted(removed),
            "published_checkpoint_manifests_hex": checkpoints}


def cleanup_attempt(processes, service, started, log_path):
    errors = []
    try:
        for process in processes:
            if process is None:
                continue
            try:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.communicate(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.communicate(timeout=10)
            except (OSError, subprocess.TimeoutExpired) as error:
                errors.append(str(error))
                try:
                    if process.poll() is None:
                        process.kill()
                    process.communicate(timeout=10)
                except (OSError, subprocess.TimeoutExpired) as error:
                    errors.append(str(error))
        if started:
            try:
                log_path.write_text(run(["amp", "orb", "service", "logs", service]).stdout)
            except (RuntimeError, OSError) as error:
                errors.append(str(error))
    finally:
        if started:
            try:
                run(["amp", "orb", "service", "stop", service])
            except (RuntimeError, OSError) as error:
                errors.append(str(error))
    return errors


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--server", type=pathlib.Path, required=True)
    p.add_argument("--client", type=pathlib.Path, required=True)
    p.add_argument("--asset-client", type=pathlib.Path,
                   help="optional concurrent create-only workload; no managed server")
    p.add_argument("--output", type=pathlib.Path, required=True)
    p.add_argument("--repetitions", type=positive, default=10)
    p.add_argument("--seconds", type=positive, default=60,
                   help="60s yields ~600 probes; p99 is descriptive, not a CI ceiling")
    p.add_argument("--port", type=positive, default=18089)
    p.add_argument("--rate", type=positive, default=20000)
    p.add_argument("--asset-ops", type=positive, default=300000)
    p.add_argument("--durability", required=True,
                   help="exact prebuilt server ACK/fsync/group-commit semantics and build defines")
    args = p.parse_args()
    if args.port > 65535:
        p.error("port must be <=65535")
    for name in ("server", "client", "asset_client"):
        path = getattr(args, name)
        if path:
            path = path.resolve()
            if not path.is_file():
                p.error(f"{name} binary does not exist")
            setattr(args, name, path)
    args.output.mkdir(parents=True, exist_ok=True)
    metadata = {
        "commit": run(["git", "rev-parse", "HEAD"]).stdout.strip(),
        "diff_sha256": hashlib.sha256(run(["git", "diff"]).stdout.encode()).hexdigest(),
        "binary_sha256": {n: hashlib.sha256(getattr(args, n).read_bytes()).hexdigest()
                          for n in ("server", "client", "asset_client") if getattr(args, n)},
        "source_sha256": {name: hashlib.sha256(pathlib.Path(name).read_bytes()).hexdigest()
                          for name in ("benchmark/cmd/retained-message-bench/main.go",
                                       "benchmark/retained-commit/responsiveness.py")},
        "cpu": run(["lscpu"]).stdout,
        "odin": run(["odin", "version"]).stdout.strip(),
        "go": run(["go", "version"]).stdout.strip(),
        "filesystem": run(["df", "-T", tempfile.gettempdir()]).stdout,
        "affinity": "not pinned; server, compactor and clients share the orb's exposed CPUs",
        "power_policy": "not controlled; record host policy separately",
        "durability": args.durability,
        "cache": "fresh disposable directory/server per sample; 1s warmup; page cache not dropped",
        "probe": "100ms sequential correlated ping; unloaded workspace on same single worker; includes client scheduling/socket work; missed ticks are not RTT samples",
        "queue_evidence": "unavailable: concurrent compaction is not proof of queued-job residency",
        "configuration": {k: str(v) if isinstance(v, pathlib.Path) else v for k, v in vars(args).items()},
    }
    samples, failures = [], []
    cases = ["baseline", "roll-seal", "retention"]
    if args.asset_client:
        cases.append("concurrent-compaction")
    service = "nrc-responsiveness-bench"
    for repetition in range(args.repetitions):
        for case in (cases if repetition % 2 == 0 else list(reversed(cases))):
            prefix = args.output / f"{repetition}-{case}"
            with tempfile.TemporaryDirectory(prefix="nrc-responsiveness-") as directory:
                retention = "5s" if case == "retention" else "24h"
                env = {"NRC_THREAD_COUNT": "1", "NRC_DISABLE_CPU_AFFINITY": "1",
                       "NRC_MESSAGE_RETENTION": retention, "NRC_MESSAGE_DEDUP_WINDOW": "1s"}
                command = "exec env NRC_PORT=$PORT NRC_JWT_SECRET=dev-insecure-nrc-jwt-secret " + " ".join(
                    f"{k}={shlex.quote(v)}" for k, v in env.items()) + " " + shlex.quote(str(args.server))
                asset = None
                client = None
                client_output = tempfile.TemporaryFile(mode="w+t")
                started = False
                observations = []
                candidate, failure = None, None
                try:
                    run(["amp", "orb", "service", "start", service, "--cwd", directory,
                         "--port", str(args.port), "--command", command])
                    started = True
                    deadline = time.monotonic() + 30
                    while True:
                        try:
                            with socket.create_connection(("127.0.0.1", args.port), timeout=1):
                                break
                        except OSError:
                            if time.monotonic() > deadline:
                                raise RuntimeError("server readiness timeout")
                            time.sleep(.1)
                    client_command = [str(args.client), f"-server=ws://127.0.0.1:{args.port}",
                                      "-workspace=responsiveness-load", "-probe", "-probe-workspace=responsiveness-idle",
                                      "-clients=64", "-depth=1", "-size=4096", "-subscribers=0", "-warmup=1s",
                                      f"-duration={args.seconds}s", f"-rate={100 if case == 'baseline' else args.rate}"]
                    asset_command = None
                    if case == "concurrent-compaction":
                        asset_command = [str(args.asset_client), "-backend=nrc", "-profile=create-only",
                                         "-auth", f"-server=ws://127.0.0.1:{args.port}",
                                         "-workspaces=1", "-concurrency=32", "-pipeline-depth=4",
                                         "-payload-size=4096", f"-ops={args.asset_ops}",
                                         f"-output={prefix.resolve()}.assets.json"]
                        asset = subprocess.Popen(asset_command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
                    client = subprocess.Popen(client_command, stdout=client_output, stderr=subprocess.PIPE, text=True)
                    begin = time.monotonic()
                    seen, removed = set(), set()
                    while client.poll() is None:
                        current = published_message_indexes(directory)
                        disk_indexes = {str(f.relative_to(directory)) for f in pathlib.Path(directory).glob("**/messages/*.idx") if f.is_file()}
                        removed |= seen - disk_indexes
                        seen |= current
                        current_checkpoints = {}
                        if case == "concurrent-compaction":
                            current_checkpoints = published_checkpoints(directory)
                        observations.append({"at_seconds": time.monotonic() - begin, "unix_ns": time.time_ns(),
                                             "indexes": sorted(current), "disk_indexes": sorted(disk_indexes), "checkpoints": current_checkpoints})
                        if time.monotonic() - begin > args.seconds + 120:
                            # Bounded termination/reaping belongs to the finally path.
                            raise RuntimeError("client timeout")
                        time.sleep(.1)
                    _, stderr = client.communicate()
                    if client.returncode:
                        raise RuntimeError(f"client failed: {stderr}")
                    client_output.seek(0)
                    result = json.load(client_output)
                    prefix.with_suffix(".json").write_text(json.dumps(result, indent=2) + "\n")
                    if asset:
                        _, error = asset.communicate(timeout=120)
                        if asset.returncode:
                            raise RuntimeError(f"asset workload failed: {error}")
                        assets = json.loads(pathlib.Path(f"{prefix.resolve()}.assets.json").read_text())["results"]
                        if len(assets) != 1 or assets[0]["errors"] != 0 or assets[0]["ops"] != args.asset_ops:
                            raise RuntimeError("asset workload recorded failed or missing operations")
                    # Exclude setup/warmup/post-measurement cleanup; the client's
                    # measured interval includes paced catch-up and ACK drain.
                    activity = measured_activity(observations, result["measured_start_ns"], result["measured_end_ns"])
                    evidence = {"observations": observations, "observed_indexes": sorted(seen),
                                "removed_indexes": sorted(removed), "case": case, **activity}
                    prefix.with_suffix(".evidence.json").write_text(json.dumps(evidence, indent=2) + "\n")
                    if case == "baseline" and seen:
                        raise RuntimeError("baseline unexpectedly sealed; reduce baseline rate/duration")
                    if case != "baseline" and not activity["sealed_during_probe"]:
                        raise RuntimeError("no runtime sealed index published during probe measurement; increase duration/rate")
                    if case == "retention" and not activity["removed_during_probe"]:
                        raise RuntimeError("no sealed index removed during probe measurement; retention not demonstrated")
                    if result.get("offered_messages") != result["ops"]:
                        raise RuntimeError("paced publication count mismatch")
                    if result["probe"]["sample_count"] == 0:
                        raise RuntimeError("no probe samples")
                    if case == "concurrent-compaction":
                        if not activity["published_checkpoint_manifests_hex"]:
                            raise RuntimeError("no compaction checkpoint published during probe measurement; workload insufficient")
                    candidate = {"repetition": repetition, "case": case, "result": result,
                                 "server_env": env, "client_command": client_command, "asset_command": asset_command}
                except (RuntimeError, OSError, ValueError, subprocess.TimeoutExpired) as error:
                    failure = {"repetition": repetition, "case": case, "error": str(error)}
                    failures.append(failure)
                    print(f"{repetition + 1}/{args.repetitions} {case}: FAILED: {error}", flush=True)
                finally:
                    cleanup_errors = cleanup_attempt((client, asset), service, started, prefix.with_suffix(".log"))
                    try:
                        client_output.close()
                    except OSError as error:
                        cleanup_errors.append(str(error))
                    if cleanup_errors:
                        if failure is None:
                            failure = {"repetition": repetition, "case": case}
                            failures.append(failure)
                        failure["cleanup_errors"] = cleanup_errors
                        print(f"{repetition + 1}/{args.repetitions} {case}: FAILED cleanup: {cleanup_errors}", flush=True)
                if candidate is not None and failure is None:
                    samples.append(candidate)
                    print(f"{repetition + 1}/{args.repetitions} {case}: probes={result['probe']['sample_count']} "
                          f"p99={result['probe']['p99_ms']:.3f}ms max={result['probe']['max_ms']:.3f}ms", flush=True)
                summary = {}
                for c in cases:
                    rows = [s["result"]["probe"] for s in samples if s["case"] == c]
                    if rows:
                        summary[c] = {"independent_samples": len(rows), "probe_samples": sum(r["sample_count"] for r in rows)}
                        for metric in ("p99_ms", "max_ms"):
                            values = [r[metric] for r in rows]
                            summary[c][metric] = {"median": statistics.median(values), "min": min(values), "max": max(values)}
                (args.output / "results.json").write_text(json.dumps(
                    {"metadata": metadata, "samples": samples, "failures": failures, "summary": summary}, indent=2) + "\n")
    if failures:
        raise SystemExit(f"{len(failures)} failed attempts; see results.json")


if __name__ == "__main__":
    main()
