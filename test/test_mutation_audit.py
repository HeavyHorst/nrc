"""Test mutation sensitivity classification and orchestration without Odin."""

import contextlib
import io
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

import run_mutation_audit as audit


def failure_log(mutation):
    return (mutation["failure"] + "\nFinished 1 test in 0.1s. The test failed.\n"
            f" - main.{mutation['test']} \tassertion failed\n")


class MutationAuditTests(unittest.TestCase):
    def test_detection_requires_expected_failure_and_normal_exit(self):
        for mutation in audit.MUTATIONS:
            log = failure_log(mutation)
            self.assertEqual(audit.classify(1, log, mutation), "detected")
            for code in [0, -11, 124, 137, 2]:
                self.assertNotEqual(audit.classify(code, log, mutation), "detected")
            for bad in ["[FATAL] signal", "+++ leak 16B", "panic: broken", "Caught signal"]:
                self.assertEqual(audit.classify(1, log + bad, mutation), "invalid-failure")
            for altered in [log.replace(mutation["failure"], "unrelated assertion"),
                            log.replace("main." + mutation["test"], "main.other_test"),
                            log.replace("Finished 1 test", "Finished 2 tests")]:
                self.assertNotEqual(audit.classify(1, altered, mutation), "detected")

    def test_baseline_and_survivor_require_completed_test_counts(self):
        total = len({m["test"] for m in audit.MUTATIONS})
        self.assertEqual(audit.classify(0, f"Finished {total} tests in 1s. All tests were successful."), "passed")
        for count in [0, 1, total - 1, total + 1]:
            self.assertEqual(audit.classify(0, f"Finished {count} tests in 1s. All tests were successful."), "invalid-output")
        self.assertEqual(audit.classify(0, "Finished 1 test in 1s. The test was successful.", audit.MUTATIONS[0]), "survived")
        self.assertNotEqual(audit.classify(1, f"Finished {total} tests in 1s. All tests were successful."), "passed")

    def test_anchor_drift_and_ambiguity_are_errors(self):
        mutation = audit.MUTATIONS[1]
        self.assertEqual(audit.mutate(mutation["old"], mutation), mutation["new"])
        for source in ["wrong source", mutation["old"] * 2]:
            with self.assertRaises(ValueError):
                audit.mutate(source, mutation)

    def exercise(self, fault=None):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory) / "work"
            output = Path(directory) / "output"
            work.mkdir()
            output.mkdir()
            for mutation in audit.MUTATIONS:
                (work / mutation["file"]).write_text(mutation["old"] + "\n")
            results, builds, runs = [], [], []

            def execute(command, cwd, log, env, timeout):
                name = log.parent.name
                if log.name == "build.log":
                    builds.append(name)
                    selection = next(arg for arg in command if arg.startswith("-define:ODIN_TEST_NAMES="))
                    selected = selection.split("=", 1)[1].split(",")
                    if name == "baseline":
                        self.assertEqual(len(selected), len(set(selected)))
                        self.assertEqual(set(selected), {"main." + m["test"] for m in audit.MUTATIONS})
                    else:
                        target = next(m["test"] for m in audit.MUTATIONS if m["name"] == name)
                        self.assertEqual(selected, ["main." + target])
                    # Exactly one mutation at a time, never contamination from a prior run.
                    for mutation in audit.MUTATIONS:
                        expected = mutation["new"] if name == mutation["name"] else mutation["old"]
                        self.assertEqual((work / mutation["file"]).read_text(), expected + "\n")
                    log.write_text("compiler output")
                    return 1 if fault == "build" and name != "baseline" else 0
                runs.append(cwd)
                self.assertTrue((cwd / "data").is_dir())
                self.assertEqual(env["HEGEL_LIBHEGEL_PATH"], "/tmp/pinned-libhegel.so")
                self.assertFalse((cwd / ".hegel").exists())
                (cwd / ".hegel").mkdir()
                (cwd / ".hegel/example").write_text("reproducer")
                if name == "baseline":
                    log.write_text(f"Finished {len({m['test'] for m in audit.MUTATIONS})} tests in 1s. All tests were successful.")
                    return 1 if fault == "baseline" else 0
                log.write_text(failure_log(next(m for m in audit.MUTATIONS if m["name"] == name)))
                if fault == "timeout":
                    raise subprocess.TimeoutExpired(command, timeout)
                if fault == "interrupt":
                    raise KeyboardInterrupt()
                if fault == "survived":
                    log.write_text("Finished 1 test in 1s. The test was successful.")
                    return 0
                return 1

            with patch.object(audit, "execute", side_effect=execute), contextlib.redirect_stdout(io.StringIO()):
                if fault == "interrupt":
                    with self.assertRaises(KeyboardInterrupt):
                        audit.audit(work, output, "odin", {"HEGEL_LIBHEGEL_PATH": "/tmp/pinned-libhegel.so"}, 1, results)
                else:
                    self.assertEqual(audit.audit(work, output, "odin", {"HEGEL_LIBHEGEL_PATH": "/tmp/pinned-libhegel.so"}, 1, results), fault is None)
            for mutation in audit.MUTATIONS:
                self.assertEqual((work / mutation["file"]).read_text(), mutation["old"] + "\n")
            self.assertTrue(all(not run.exists() for run in runs))
            self.assertEqual(len(builds), len(audit.MUTATIONS) + 1 if fault is None else 1 if fault == "baseline" else 2)
            if fault not in ["baseline", "build"]:
                self.assertEqual((output / "ack-before-fsync/hegel/example").read_text(), "reproducer")
            if fault is None:
                self.assertEqual([r["status"] for r in results], ["passed"] + ["detected"] * len(audit.MUTATIONS))
                self.assertTrue((output / "workspace-fanout-bypass/mutation.patch").exists())
            elif fault != "interrupt":
                expected = {"build": "build-failed", "timeout": "timeout", "survived": "survived",
                            "baseline": "unexpected-failure"}[fault]
                self.assertEqual(results[-1]["status"], expected)

    def test_all_mutants_are_isolated_and_artifacts_preserved(self):
        self.exercise()

    def test_failures_stop_and_restore_sources(self):
        for fault in ["baseline", "build", "timeout", "interrupt", "survived"]:
            with self.subTest(fault=fault):
                self.exercise(fault)

    def test_timeout_and_interrupt_kill_group_and_reap_before_return(self):
        for error in [subprocess.TimeoutExpired("test", 1), KeyboardInterrupt()]:
            with tempfile.TemporaryDirectory() as directory:
                process = Mock(pid=123)
                process.wait.side_effect = [error, -9]
                with patch.object(audit.subprocess, "Popen", return_value=process) as popen, \
                        patch.object(audit.os, "killpg") as kill:
                    with self.assertRaises(type(error)):
                        audit.execute(["test"], Path(directory), Path(directory) / "log", {}, 1)
                    self.assertTrue(popen.call_args.kwargs["start_new_session"])
                    kill.assert_called_once_with(123, audit.signal.SIGKILL)
                    self.assertEqual(process.wait.call_count, 2)


if __name__ == "__main__":
    unittest.main()
