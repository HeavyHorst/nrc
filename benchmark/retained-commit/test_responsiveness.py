import json
import pathlib
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

from responsiveness import cleanup_attempt, main, measured_activity, published_checkpoints, published_message_indexes


class ActivityTests(unittest.TestCase):
    def test_message_manifest_excludes_unpublished_and_frozen_indexes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            messages = root / "data/shard-001/messages"
            messages.mkdir(parents=True)
            published = messages / "segment-00000000000000000007.idx"
            published.touch()
            (messages / "segment-00000000000000000009.idx").touch()
            (messages / "segment-00000000000000000011.idx").touch()
            # Production message manifests are little-endian, unlike shard manifests.
            data = bytearray(64 + 2 * 48)
            data[:6] = b"1GSM\x03\x00"
            data[40:44] = (1).to_bytes(4, "little")
            data[44:48] = (1).to_bytes(4, "little")
            data[64:72] = (7).to_bytes(8, "little")
            data[112:120] = (9).to_bytes(8, "little")
            (messages / "manifest").write_bytes(data)
            self.assertEqual(published_message_indexes(root), {str(published.relative_to(root))})
            published.unlink()
            self.assertEqual(published_message_indexes(root), set())

    def test_checkpoint_requires_published_flag_and_generation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            data = bytearray(56)
            data[:6] = b"NRCK\x00\x01"
            data[24:32] = (17).to_bytes(8, "big")
            (root / "shard.manifest").write_bytes(data)
            self.assertEqual(published_checkpoints(root), {})
            data[6:8] = (1).to_bytes(2, "big")
            (root / "shard.manifest.tmp").write_bytes(data)
            self.assertEqual(published_checkpoints(root), {})
            # A real rotation has equal checkpoint/active generations.
            data[40:48] = (17).to_bytes(8, "big")
            (root / "shard.manifest").write_bytes(data)
            self.assertEqual(published_checkpoints(root), {})
            # Compaction advances checkpoint generation, not the active WAL.
            data[24:32] = (19).to_bytes(8, "big")
            (root / "shard.manifest").write_bytes(data)
            self.assertEqual(published_checkpoints(root), {"shard.manifest": data.hex()})

    def test_only_transitions_inside_probe_window_count(self):
        def observation(at, indexes, checkpoint):
            return {"unix_ns": at, "indexes": indexes, "disk_indexes": indexes,
                    "checkpoints": {"shard.manifest": checkpoint}}

        samples = [observation(9, [], "before"), observation(10, ["warmup.idx"], "warmup"),
                   observation(15, ["warmup.idx", "timed.idx"], "timed"),
                   observation(20, ["timed.idx"], "timed"), observation(21, [], "drain")]
        self.assertEqual(measured_activity(samples, 10, 20), {
            "sealed_during_probe": ["timed.idx"], "removed_during_probe": ["warmup.idx"],
            "published_checkpoint_manifests_hex": {"shard.manifest": "timed"}})
        self.assertEqual(measured_activity(samples, 10, 10), {
            "sealed_during_probe": [], "removed_during_probe": [], "published_checkpoint_manifests_hex": {}})

    def test_retention_requires_physical_unlink_inside_window(self):
        samples = [{"unix_ns": 10, "indexes": ["old.idx"], "disk_indexes": ["old.idx"], "checkpoints": {}},
                   {"unix_ns": 15, "indexes": [], "disk_indexes": ["old.idx"], "checkpoints": {}},
                   {"unix_ns": 20, "indexes": [], "disk_indexes": [], "checkpoints": {}}]
        self.assertEqual(measured_activity(samples, 10, 19)["removed_during_probe"], [])
        self.assertEqual(measured_activity(samples, 10, 20)["removed_during_probe"], ["old.idx"])

    def test_rotation_only_and_outside_compaction_do_not_count(self):
        samples = [{"unix_ns": 9, "indexes": [], "disk_indexes": [], "checkpoints": {"manifest": "warmup"}},
                   {"unix_ns": 10, "indexes": [], "disk_indexes": [], "checkpoints": {}},
                   {"unix_ns": 15, "indexes": [], "disk_indexes": [], "checkpoints": {}},
                   {"unix_ns": 20, "indexes": [], "disk_indexes": [], "checkpoints": {"manifest": "compacted"}}]
        self.assertEqual(measured_activity(samples, 10, 19)["published_checkpoint_manifests_hex"], {})
        self.assertEqual(measured_activity(samples, 10, 20)["published_checkpoint_manifests_hex"], {"manifest": "compacted"})

    def test_cleanup_timeout_kills_reaps_and_stops_service(self):
        process = Mock()
        process.poll.return_value = None
        process.communicate.side_effect = [subprocess.TimeoutExpired("client", 10), ("", "")]
        with patch("responsiveness.run") as run:
            self.assertEqual(cleanup_attempt((process,), "service", True, Mock()), [])
            process.kill.assert_called_once()
            self.assertEqual(process.communicate.call_count, 2)
            self.assertEqual(run.call_args.args[0], ["amp", "orb", "service", "stop", "service"])

    def test_cleanup_child_and_log_errors_cannot_skip_other_child_or_service(self):
        first, second, log_path = Mock(), Mock(), Mock()
        first.poll.return_value = second.poll.return_value = None
        first.terminate.side_effect = OSError("terminate failed")
        log_path.write_text.side_effect = OSError("log failed")
        with patch("responsiveness.run") as run:
            self.assertEqual(cleanup_attempt((first, second), "service", True, log_path), ["terminate failed", "log failed"])
            first.kill.assert_called_once()
            first.communicate.assert_called_once()
            second.terminate.assert_called_once()
            second.communicate.assert_called_once()
            self.assertEqual(run.call_args.args[0], ["amp", "orb", "service", "stop", "service"])

    def test_valid_result_with_cleanup_failure_is_not_accepted(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            binary = root / "binary"
            binary.write_bytes(b"mocked binary")
            output = root / "results"
            result = {"ops": 1, "offered_messages": 1, "measured_start_ns": 10, "measured_end_ns": 20,
                      "probe": {"sample_count": 1, "p99_ms": .1, "max_ms": .2}}

            def client(*args, **kwargs):
                json.dump(result, kwargs["stdout"])
                process = Mock(returncode=0)
                process.poll.return_value = 0
                process.communicate.return_value = ("", "")
                return process

            argv = ["responsiveness.py", "--server", str(binary), "--client", str(binary),
                    "--output", str(output), "--repetitions", "1", "--seconds", "1", "--durability", "mock"]
            with patch("sys.argv", argv), patch("responsiveness.run", return_value=Mock(stdout="mock")), \
                    patch("responsiveness.socket.create_connection"), \
                    patch("responsiveness.subprocess.Popen", side_effect=client), \
                    patch("responsiveness.cleanup_attempt", return_value=["stop failed"]), patch("builtins.print"):
                with self.assertRaises(SystemExit):
                    main()
            saved = json.loads((output / "results.json").read_text())
            self.assertEqual(saved["samples"], [])
            self.assertEqual(saved["summary"], {})
            self.assertEqual(len(saved["failures"]), 3)
            # Baseline passes result validation; only cleanup rejects it.
            self.assertNotIn("error", saved["failures"][0])
            self.assertEqual(saved["failures"][0]["cleanup_errors"], ["stop failed"])


if __name__ == "__main__":
    unittest.main()
