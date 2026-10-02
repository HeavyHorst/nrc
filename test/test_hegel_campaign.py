"""Exercise campaign orchestration without compiling or invoking Hegel."""

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import Mock, call, patch

import run_hegel_campaign as campaign


class CampaignTests(unittest.TestCase):
    def exercise(self, output, codes, wrong_seed=False, seconds=900):
        builds, seeds, workdirs = [], [], []
        processes = []

        def run(command, **kwargs):
            if command[1] == "build":
                builds.append(command)
                return subprocess.CompletedProcess(command, 0)
            work = kwargs["cwd"]
            self.assertFalse((work / ".hegel").exists())
            self.assertTrue((work / "data").is_dir())
            self.assertEqual(kwargs["env"]["HEGEL_LIBHEGEL_PATH"], "/tmp/pinned-libhegel.so")
            workdirs.append(work)
            seed = int(kwargs["env"]["HEGEL_SEED"])
            seeds.append(seed)
            (work / ".hegel").mkdir()
            (work / ".hegel" / "example").write_text("minimized example")
            for name in campaign.TESTS:
                kwargs["stdout"].write(
                    f"[hegel diag] start pid=1 caller={name} seed={seed + wrong_seed} derandomize=false\n"
                    f"[hegel diag] finish pid=1 caller={name} executed=7 interesting=0 passed=true\n")
            process = Mock(pid=123456)
            code = codes[len(seeds) - 1]
            process.wait.side_effect = [KeyboardInterrupt(), 0, 0] if code == "interrupt" else [code]
            processes.append(process)
            self.assertTrue(kwargs["start_new_session"])
            self.assertLessEqual(float(command[2][:-1]), seconds)
            return process

        args = ["campaign", "--runs", str(len(codes)), "--seed", "91", "--output", str(output),
                "--seconds", str(seconds)]
        with patch.object(sys, "argv", args), \
                patch.object(campaign.subprocess, "check_output", side_effect=lambda command, **kw:
                             "/tmp/pinned-libhegel.so\n" if command[0].endswith("fetch_libhegel.sh")
                             else "version" if kw.get("text") else b"diff"), \
                patch.object(campaign.subprocess, "run", side_effect=run), \
                patch.object(campaign.subprocess, "Popen", side_effect=run), \
                patch.object(campaign.os, "killpg") as killpg, \
                contextlib.redirect_stdout(io.StringIO()):
            status = campaign.main()
        if codes[0] == "interrupt":
            self.assertEqual(killpg.call_args_list, [call(123456, campaign.signal.SIGTERM),
                                                    call(123456, campaign.signal.SIGKILL)])
            self.assertEqual(processes[0].wait.call_args_list, [call(), call(timeout=5), call()])
        self.assertEqual(len(builds), 1)
        self.assertEqual(len(set(workdirs)), len(workdirs))
        self.assertTrue(all(not work.exists() for work in workdirs))
        return status, seeds, json.loads((output / "summary.json").read_text())

    def test_build_once_distinct_generation_seeds_and_case_totals(self):
        with tempfile.TemporaryDirectory() as directory:
            status, seeds, summary = self.exercise(Path(directory) / "output", [0, 0])
            self.assertEqual(status, 0)
            self.assertEqual(seeds, [91, 92])
            self.assertEqual(summary["completed_seeds"], 2)
            self.assertEqual(summary["executed_cases"], 2 * len(campaign.TESTS) * 7)

    def test_failure_stops_and_preserves_reproduction(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            status, seeds, summary = self.exercise(output, [1, 0])
            self.assertEqual(status, 1)
            self.assertEqual(seeds, [91])
            self.assertEqual(summary["status"], "failed")
            self.assertEqual((output / "seed-91-hegel/example").read_text(), "minimized example")
            self.assertIn("--seed 91 --runs 1", (output / "REPRODUCE.txt").read_text())

    def test_success_exit_with_wrong_generation_seed_is_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            status, _, summary = self.exercise(Path(directory) / "output", [0], wrong_seed=True)
            self.assertEqual(status, 1)
            self.assertEqual(summary["status"], "failed")

    def test_timeout_is_not_reported_as_property_failure_or_success(self):
        with tempfile.TemporaryDirectory() as directory:
            status, _, summary = self.exercise(Path(directory) / "output", [124])
            self.assertEqual(status, 1)
            self.assertEqual(summary["status"], "timeout")

    def test_sigkill_does_not_claim_a_known_timeout_cause(self):
        for code in (137, -9):
            with self.subTest(code=code), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                status, _, summary = self.exercise(output, [code])
                self.assertEqual(status, 1)
                self.assertEqual(summary["status"], "killed")
                self.assertEqual(json.loads((output / "results.json").read_text())[0]["exit_code"], code)

    def test_interrupt_reaps_process_and_preserves_database_and_summary(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            status, seeds, summary = self.exercise(output, ["interrupt", 0])
            self.assertEqual(status, 1)
            self.assertEqual(seeds, [91])
            self.assertEqual(summary["status"], "interrupted")
            self.assertEqual((output / "seed-91-hegel/example").read_text(), "minimized example")
            self.assertIn("--seed 91 --runs 1", (output / "REPRODUCE.txt").read_text())

    def test_remaining_budget_caps_timeout(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(campaign.time, "monotonic", side_effect=[0, 0, 0, 10, 10]):
            status, _, summary = self.exercise(Path(directory) / "output", [124], seconds=10)
            self.assertEqual(status, 1)
            self.assertEqual(summary["status"], "budget_exhausted")

    def test_does_not_start_seed_that_is_unlikely_to_fit(self):
        with tempfile.TemporaryDirectory() as directory, \
                patch.object(campaign.time, "monotonic", side_effect=[0, 0, 0, 3, 9, 9]):
            status, seeds, summary = self.exercise(Path(directory) / "output", [0, 0], seconds=10)
            self.assertEqual(status, 0)
            self.assertEqual(seeds, [91])
            self.assertEqual(summary["completed_seeds"], 1)


if __name__ == "__main__":
    unittest.main()
