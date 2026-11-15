#!/usr/bin/env python3
"""Build once, then run isolated, strictly memory-checked Hegel seed campaigns."""

import argparse
import datetime
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import subprocess
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
TESTS = [
    "test_hegel_retained_expiry_cancel_rollover_crash_histories",
    "test_hegel_global_event_interleaving_campaign",
    "test_hegel_cached_dm_transport_authorization_and_ownership",
    "test_hegel_generated_stale_callback_completions_do_not_target_reused_sockets",
    "test_hegel_generated_stale_callback_buffer_ownership_is_released_once",
    "test_hegel_generated_pending_callback_interleavings_match_pool_model",
    "test_hegel_generated_pending_callback_error_interleavings_match_pool_model",
    "test_hegel_generated_graceful_close_lifetime_orderings",
    "test_hegel_generated_stale_recv_parser_state_lifetimes",
]


def positive(value):
    number = int(value)
    if number < 1:
        raise argparse.ArgumentTypeError("must be positive")
    return number


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=positive, default=900,
                        help="execution budget, excluding build (default: 900)")
    parser.add_argument("--run-timeout", type=positive, default=180)
    parser.add_argument("--runs", type=positive, help="optional maximum seed count")
    parser.add_argument("--seed", type=positive, default=secrets.randbelow(2**32 - 1) + 1)
    parser.add_argument("--output", type=Path, help="new directory for logs and reproduction data")
    args = parser.parse_args()
    if args.seed >= 2**64 or (args.runs and args.seed + args.runs > 2**64):
        parser.error("seeds must fit a nonzero unsigned 64-bit integer")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT / ".amp/in/artifacts" / f"hegel-campaign-{stamp}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    odin = os.environ.get("ODIN_BIN", "odin")
    fetch_env = {key: value for key, value in os.environ.items() if key != "HEGEL_LIBHEGEL_PATH"}
    library = subprocess.check_output([str(ROOT / "test/fetch_libhegel.sh")],
                                      env=fetch_env, text=True).strip()
    flags = ["-o:speed", "-build-mode:test", "-define:NRC_SIMULATION=true",
             "-define:HEGEL_REQUIRED=true", "-define:ODIN_TEST_THREADS=1",
             "-define:ODIN_TEST_RANDOM_SEED=12345", "-define:ODIN_TEST_LOG_LEVEL=error",
             "-define:ODIN_TEST_TRACK_MEMORY=true", "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true",
             "-define:ODIN_TEST_NAMES=" + ",".join("main." + name for name in TESTS)]
    metadata = {
        "commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "odin": subprocess.check_output([odin, "version"], cwd=ROOT, text=True).strip(),
        "seconds": args.seconds, "run_timeout": args.run_timeout,
        "first_seed": args.seed, "tests": TESTS, "build_flags": flags,
        "database": "empty at start of every process", "multiplier": 1,
    }
    untracked = subprocess.check_output(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"], cwd=ROOT)
    untracked_paths = [os.fsdecode(path) for path in untracked.split(b"\0") if path]
    metadata["source_snapshot"] = {
        "complete_for_git_visible_files": not untracked_paths,
        "untracked_paths_not_archived": untracked_paths,
        "ignored_files_archived": False,
    }
    source_warning = (
        "INCOMPLETE SOURCE SNAPSHOT: untracked files listed in metadata.json are NOT archived. "
        "Commit plus source.patch cannot reconstruct this run; retain the original working tree.\n"
        if untracked_paths else
        "Source snapshot covers Git-visible files only; ignored dependencies and toolchains are not archived.\n")
    (output / "SOURCE_SNAPSHOT.txt").write_text(source_warning)
    print(source_warning, end="", flush=True)
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    (output / "source.patch").write_bytes(subprocess.check_output(["git", "diff", "--binary", "--full-index", "HEAD"], cwd=ROOT))
    shutil.copy2(__file__, output / "runner.py")
    results = []
    with tempfile.TemporaryDirectory(prefix="nrc-hegel-campaign-") as scratch:
        binary = Path(scratch) / "nrc-tests"
        print(f"Building once; output: {output}", flush=True)
        with (output / "build.log").open("w") as log:
            build = subprocess.run([odin, "build", str(ROOT), *flags, f"-out:{binary}"],
                                   cwd=ROOT, stdout=log, stderr=subprocess.STDOUT)
        if build.returncode:
            print("Build failed; see build.log", flush=True)
            return build.returncode
        started = time.monotonic()
        status = "passed"
        while not args.runs or len(results) < args.runs:
            remaining = args.seconds - (time.monotonic() - started)
            # Do not start a run that is unlikely to finish within the budget.
            estimate = max((r["elapsed_seconds"] for r in results), default=0) * 1.2
            if remaining < max(1, estimate):
                break
            seed = args.seed + len(results)
            if seed >= 2**64:
                status = "seed_exhausted"
                break
            with tempfile.TemporaryDirectory(dir=scratch, prefix=f"seed-{seed}-") as work:
                work = Path(work)
                (work / "data").mkdir()
                env = {**os.environ, "HEGEL_SEED": str(seed), "HEGEL_DIAGNOSTICS": "1",
                       "HEGEL_TEST_CASE_MULTIPLIER": "1", "HEGEL_LIBHEGEL_PATH": library}
                limit = min(args.run_timeout, remaining)
                run_started = time.monotonic()
                log_path = output / f"seed-{seed}.log"
                with log_path.open("w") as log:
                    process = subprocess.Popen(["timeout", "--kill-after=5s", f"{limit}s", str(binary)],
                                               cwd=work, env=env, stdout=log, stderr=subprocess.STDOUT,
                                               start_new_session=True)
                    try:
                        returncode = process.wait()
                    except KeyboardInterrupt:
                        # Keep the work directory alive until every descendant is
                        # stopped and the database can be archived safely.
                        previous = signal.signal(signal.SIGINT, signal.SIG_IGN)
                        try:
                            try:
                                os.killpg(process.pid, signal.SIGTERM)
                            except ProcessLookupError:
                                pass
                            try:
                                process.wait(timeout=5)
                            except subprocess.TimeoutExpired:
                                pass
                            try:
                                os.killpg(process.pid, signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                            process.wait()
                        finally:
                            signal.signal(signal.SIGINT, previous)
                        returncode = 130
                text = log_path.read_text(errors="replace")
                starts = re.findall(r"\[hegel diag\] start .*?caller=(\S+).*? seed=(\d+) ", text)
                seen = {name.rsplit(".", 1)[-1] for name, _ in starts}
                finishes = re.findall(
                    r"\[hegel diag\] finish .*?caller=(\S+).*? executed=(\d+) interesting=(\d+) passed=(\w+) err=(\S+)", text)
                finished = {name.rsplit(".", 1)[-1] for name, *_ in finishes}
                coverage_ok = (
                    len(starts) == len(finishes) == len(TESTS)
                    and seen == finished == set(TESTS)
                    and all(int(value) == seed for _, value in starts)
                    and all(int(count) > 0 and int(interesting) == 0 and passed == "true" and error == "None"
                            for _, count, interesting, passed, error in finishes))
                run_status = "passed" if returncode == 0 and coverage_ok else "failed"
                if returncode == 124:
                    run_status = "budget_exhausted" if remaining < args.run_timeout else "timeout"
                elif returncode == 130:
                    run_status = "interrupted"
                elif returncode in (137, -signal.SIGKILL):
                    # SIGKILL can be timeout escalation or an external/OOM kill.
                    run_status = "killed"
                cases = sum(int(count) for _, count, *_ in finishes)
                result = {"seed": seed, "status": run_status, "exit_code": returncode,
                          "coverage_ok": coverage_ok, "executed_cases": cases,
                          "elapsed_seconds": round(time.monotonic() - run_started, 3)}
                results.append(result)
                (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
                print(json.dumps(result), flush=True)
                if run_status != "passed":
                    status = run_status
                    if (work / ".hegel").exists():
                        shutil.copytree(work / ".hegel", output / f"seed-{seed}-hegel")
                    (output / "REPRODUCE.txt").write_text(
                        source_warning + f"Commit: {metadata['commit']}; source.patch covers tracked changes only.\n"
                        "runner.py is a saved copy. Check SOURCE_SNAPSHOT.txt and metadata.json before reconstruction.\n"
                        "Copy runner.py to test/run_hegel_campaign.py if the checkout lacks it.\n"
                        "From that repository checkout (fresh example DB is automatic):\n"
                        f"python3 test/run_hegel_campaign.py --seed {seed} --runs 1 "
                        f"--seconds {args.run_timeout + 10} --run-timeout {args.run_timeout}\n"
                        "Logs include native minimized blobs and literal fixtures when available.\n"
                        "A timeout may interrupt minimization and is not a demonstrated invariant failure.\n")
                    break
        summary = {"status": status if results else "no_runs", "runs": len(results),
                   "completed_seeds": sum(r["status"] == "passed" for r in results),
                   "executed_cases": sum(r["executed_cases"] for r in results),
                   "elapsed_seconds": round(time.monotonic() - started, 3)}
        (output / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(json.dumps(summary), flush=True)
        return 0 if results and status == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
