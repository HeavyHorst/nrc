#!/usr/bin/env python3
"""Check targeted faults against committed HEAD in a disposable worktree."""

import argparse
import datetime
import difflib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
# Exact anchors intentionally fail closed when implementation or diagnostics drift.
MUTATIONS = [
    dict(name="ack-before-fsync", file="websocket_handler.odin",
         old="\treturn outbox_item_shard_is_durable(item) && outbox_item_message_is_durable(item)",
         new="\treturn true",
         test="test_shard_group_commit_holds_ack_broadcast_and_query_until_snapshot_fsync",
         failure="expected nrc_sim_client_frame_count(&ctx.sim, c.sock) to be 0, got 1"),
    dict(name="stale-socket", file="connection.odin",
         old="connection_from_io_context :: proc(ctx: Connection_IO_Context) -> ^NRC_Connection {\n\tconn := connection_get_by_handle(ctx.handle)",
         new="connection_from_io_context :: proc(ctx: Connection_IO_Context) -> ^NRC_Connection {\n\tconn := connection_get(ctx.sock)",
         test="test_io_context_rejects_stale_handle_after_socket_reuse",
         failure="stale context must not resolve to the replacement"),
    dict(name="checksum-bypass", file="shard_segment_catalog.odin",
         old="\tif magic != SHARD_SEGMENT_CATALOG_MAGIC || checksum != xxhash.XXH64(data[:checksum_offset]) do return",
         new="\tif magic != SHARD_SEGMENT_CATALOG_MAGIC do return",
         test="test_shard_segment_catalog_variable_roundtrip_and_corruption",
         failure="expected !corrupt_ok to be true"),
    dict(name="durable-record-omitted", file="shard_runtime_writer.odin",
         old="\tif ctx.apply && !visit_shard_transaction_mutations(&view, apply_shard_transaction_mutation, &view) do return false",
         new="\tif ctx.apply && ctx.previous.task != 0 && !visit_shard_transaction_mutations(&view, apply_shard_transaction_mutation, &view) do return false",
         test="test_hegel_mixed_semantic_history_recovers_exact_durable_prefix",
         failure="hegel native failure origin: semantic durable-prefix replay failed"),
    dict(name="dm-access-bypass", file="dm_handlers.odin",
         old="\treturn is_participant && is_user_in_dm(ws, username, conv_id)",
         new="\treturn true",
         test="test_simulation_dm_non_member_cannot_subscribe_leave_or_send",
         failure="expected nrc_sim_client_frame_count(&ctx.sim, alice.sock) to be 0, got 1"),
    dict(name="workspace-fanout-bypass", file="broadcast.odin",
         old="broadcast_new_message_with_workspace :: proc(msg: pr.NewMessageEvent, sender_sock: net.TCP_Socket, ws: ^Workspace_State) {",
         new="broadcast_new_message_with_workspace :: proc(msg: pr.NewMessageEvent, sender_sock: net.TCP_Socket, ws: ^Workspace_State) {\n"
             "\tfor _, target in td.workspaces {\n"
             "\t\tmutation_broadcast_in_workspace(msg, sender_sock, target)\n\t}\n}\n\n"
             "mutation_broadcast_in_workspace :: proc(msg: pr.NewMessageEvent, sender_sock: net.TCP_Socket, ws: ^Workspace_State) {",
         test="test_simulation_send_sink_captures_message_fanout_with_workspace_isolation",
         failure="expected nrc_sim_client_frame_count(&ctx.sim, conn_c.sock) to be 0, got 1"),
    # This test contains only generated histories, not the exact swarm fixtures.
    dict(name="generated-move-order", file="task_handlers.odin",
         old="\ttask.order_index = req.order_index",
         new="\ttask.order_index = req.order_index + 1",
         test="test_hegel_semantic_handler_graph_swarm",
         failure="hegel native failure origin: handler swarm task state differs from model"),
    # Requires updating or moving a task, then moving it again: retain its old
    # index entry while changing the task, without corrupting allocation counts.
    dict(name="generated-repeat-move-stale-index", file="state_store.odin",
         old="\tassert(task != nil && task != snapshot)\n"
             "\tremove_task_from_index(conv, task)\n"
             "\ttask.status = snapshot.status\n"
             "\ttask.order_index = snapshot.order_index\n"
             "\ttask.completed_at = snapshot.completed_at\n"
             "\ttask.updated_at = snapshot.updated_at\n"
             "\tindex_task(conv, task)",
         new="\tassert(task != nil && task != snapshot)\n"
             "\twas_updated := task.updated_at > task.created_at\n"
             "\tremove_task_from_index(conv, task)\n"
             "\tif was_updated do index_task(conv, task)\n"
             "\ttask.status = snapshot.status\n"
             "\ttask.order_index = snapshot.order_index\n"
             "\ttask.completed_at = snapshot.completed_at\n"
             "\ttask.updated_at = snapshot.updated_at\n"
             "\tif !was_updated do index_task(conv, task)",
         test="test_hegel_semantic_handler_graph_swarm",
         failure="hegel native failure origin: handler swarm task/index/floor state differs from model"),
]
FLAGS = ["-build-mode:test", "-o:speed", "-define:NRC_SIMULATION=true",
         "-define:HEGEL_REQUIRED=true", "-define:ODIN_TEST_THREADS=1",
         "-define:ODIN_TEST_RANDOM_SEED=12345", "-define:ODIN_TEST_LOG_LEVEL=error",
         "-define:ODIN_TEST_TRACK_MEMORY=true", "-define:ODIN_TEST_FAIL_ON_BAD_MEMORY=true"]


def execute(command, cwd, log, env, timeout):
    """Stop the entire process group before releasing its working directory."""
    with log.open("w") as stream:
        process = subprocess.Popen(command, cwd=cwd, env=env, stdout=stream,
                                   stderr=subprocess.STDOUT, start_new_session=True)
        try:
            return process.wait(timeout=timeout)
        finally:
            # Also stop descendants when their parent exits first.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()


def classify(code, log, mutation=None):
    if re.search(r"\[FATAL\]|Caught signal|Segmentation_Fault|panic:|\+\+\+", log, re.I):
        return "invalid-failure"
    count = 1 if mutation else len({m["test"] for m in MUTATIONS})
    if code == 0:
        success = "The test was successful." if count == 1 else "All tests were successful."
        if not re.search(rf"Finished {count} tests? in .*" + re.escape(success), log):
            return "invalid-output"
        return "survived" if mutation else "passed"
    if mutation and code == 1 and re.search(r"Finished 1 test in .*The test failed\.", log):
        if (mutation["failure"] in log and
                re.search(r"^ - main\." + re.escape(mutation["test"]) + r"\s", log, re.M)):
            return "detected"
    return "unexpected-failure"


def mutate(source, mutation):
    if source.count(mutation["old"]) != 1:
        raise ValueError(f"{mutation['name']}: expected exactly one source anchor")
    return source.replace(mutation["old"], mutation["new"], 1)


def audit(work, output, odin, env, timeout, results):
    for mutation in [None, *MUTATIONS]:
        name = mutation["name"] if mutation else "baseline"
        case = output / name
        case.mkdir()
        path = work / mutation["file"] if mutation else None
        original = path.read_text() if path else None
        record = {"name": name, "status": "incomplete"}
        results.append(record)
        try:
            if mutation:
                changed = mutate(original, mutation)
                path.write_text(changed)
                (case / "mutation.patch").write_text("".join(difflib.unified_diff(
                    original.splitlines(True), changed.splitlines(True),
                    fromfile="a/" + mutation["file"], tofile="b/" + mutation["file"])))
            tests = [mutation["test"]] if mutation else list(dict.fromkeys(m["test"] for m in MUTATIONS))
            binary = work / "mutation-tests"
            build = [odin, "build", ".", *FLAGS, "-out:" + str(binary),
                     "-define:ODIN_TEST_NAMES=" + ",".join("main." + test for test in tests)]
            record["build_command"] = build
            print(f"{name}: building", flush=True)
            code = execute(build, work, case / "build.log", env, timeout)
            record["build_exit"] = code
            if code:
                record["status"] = "build-failed"
                return False
            # Each process starts with a fresh Hegel database and disposable data.
            with tempfile.TemporaryDirectory(prefix="mutation-run-", dir=work) as run:
                run = Path(run)
                (run / "data").mkdir()
                try:
                    code = execute([str(binary)], run, case / "test.log", env, timeout)
                    record["test_exit"] = code
                    record["status"] = classify(code, (case / "test.log").read_text(), mutation)
                finally:
                    if (run / ".hegel").exists():
                        shutil.copytree(run / ".hegel", case / "hegel")
            print(f"{name}: {record['status']}", flush=True)
            if record["status"] != ("detected" if mutation else "passed"):
                return False
        except subprocess.TimeoutExpired:
            record["status"] = "timeout"
            return False
        finally:
            if path:
                path.write_text(original)
    return True


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, help="new directory for logs, patches and metadata")
    parser.add_argument("--timeout", type=int, default=300, help="seconds per build/test (default: 300)")
    args = parser.parse_args()
    if args.timeout < 1:
        parser.error("timeout must be positive")
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    output = (args.output or ROOT / ".amp/in/artifacts" / f"mutation-audit-{stamp}").resolve()
    output.mkdir(parents=True, exist_ok=False)
    odin = shutil.which(os.environ.get("ODIN_BIN", "odin"))
    if not odin:
        parser.error("Odin not found; set ODIN_BIN")
    commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip()
    env = {**os.environ, "HEGEL_SEED": "12345", "HEGEL_DIAGNOSTICS": "1",
           "HEGEL_TEST_CASE_MULTIPLIER": "1"}
    env.pop("HEGEL_LIBHEGEL_PATH", None)
    env["HEGEL_LIBHEGEL_PATH"] = subprocess.check_output(
        [str(ROOT / "test/fetch_libhegel.sh")], env=env, text=True).strip()
    report = {"commit": commit, "source": "committed HEAD; working-tree changes excluded",
              "seed": 12345, "timeout": args.timeout, "mutations": MUTATIONS,
              "odin": subprocess.check_output([odin, "version"], text=True).strip(),
              "status": "incomplete", "results": []}
    shutil.copy2(__file__, output / "runner.py")
    print(f"Auditing committed HEAD {commit}; output: {output}", flush=True)
    try:
        with tempfile.TemporaryDirectory(prefix="nrc-mutation-audit-") as scratch:
            work = Path(scratch) / "repo"
            subprocess.run(["git", "worktree", "add", "--detach", str(work), commit], cwd=ROOT, check=True)
            try:
                passed = audit(work, output, odin, env, args.timeout, report["results"])
                report["status"] = "passed" if passed else "failed"
            finally:
                subprocess.run(["git", "worktree", "remove", "--force", str(work)], cwd=ROOT, check=True)
    except KeyboardInterrupt:
        report["status"] = "interrupted"
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        report["status"] = "error"
        report["error"] = str(error)
    finally:
        (output / "summary.json").write_text(json.dumps(report, indent=2) + "\n")
    print(f"Audit {report['status']}; see {output / 'summary.json'}", flush=True)
    return 0 if report["status"] == "passed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
