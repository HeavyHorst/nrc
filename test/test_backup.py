"""Run backup/deploy fixtures with real Compose rendering, without a Docker daemon."""

import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tarfile
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent


class BackupTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory(prefix="nrc backup ")
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)
        self.backups = self.root / "backups"
        self.volumes = ("legacy", "shared", "active-sqlite", "stopped-sqlite")
        for name in self.volumes:
            directory = self.root / "volumes" / name
            directory.mkdir(parents=True)
            (directory / "payload").write_bytes((name + " snapshot").encode())
        script = (ROOT / "docker/backup.sh").read_text()
        script = script.replace("/run/lock/nrc-backup.lock", str(self.root / "backup.lock"))
        script = script.replace("exec 9>" + str(self.root / "backup.lock"),
                                "exec 9>" + shlex.quote(str(self.root / "backup.lock")))
        script = script.replace("COMPOSE_DIR=/root/nrc", "COMPOSE_DIR=" + shlex.quote(str(self.root)))
        script = script.replace("BACKUP_ROOT=/root/backups/nrc-daily", "BACKUP_ROOT=" + shlex.quote(str(self.backups)))
        script = script.replace("deadline=$((SECONDS + 120))", "deadline=$((SECONDS + 2))")
        self.script = self.root / "backup.sh"
        self.script.write_text(script)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text('''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["BACKUP_TEST_ROOT"])
args = sys.argv[1:]
old_image = "sha256:" + "1" * 64
new_image = "sha256:" + "2" * 64
images_path = root / "images.json"
images = json.loads(images_path.read_text()) if images_path.exists() else {"websocket-server": old_image}
def resumed():
    (root / "stopped").unlink(missing_ok=True)
    for payload in (root / "volumes").glob("*/payload"):
        payload.write_text("changed after restart")
if args[0] == "compose":
    if "ps" in args:
        print("websocket-server" if "--services" in args else "fixture service")
    elif "config" in args and "json" in args:
        print(json.dumps({"name": "docker", "services": {"websocket-server": {
            "image": "mutable:latest", "build": {"context": str(root)},
            "environment": {"SECRET": os.environ.get("CURRENT_CONFIG_SECRET", "literal$$VALUE")}}}}))
    elif "stop" in args:
        (root / "stopped").touch()
    elif "start" in args:
        assert not (root / "switched").exists(), "old containers must not start before switch"
        resumed()
    elif "up" in args:
        assert "--no-build" in args and "never" in args
        if "/dev/null" in args:
            model = json.loads(pathlib.Path(args[args.index("-f") + 1]).read_text())
            images = {s: model["services"][s]["image"] for s in model["x-nrc-running-services"]}
            if os.environ.get("BACKUP_TEST_FAILURE") == "rollback":
                sys.exit(12)
            (root / "running-config").write_text(args[args.index("-f") + 1])
        else:
            assert (root / "stopped").exists(), "switch must happen while stopped"
            (root / "switched").touch()
            images = {"websocket-server": new_image, "new-sidecar": new_image}
        images_path.write_text(json.dumps(images))
        resumed()
        if "/dev/null" not in args and os.environ.get("BACKUP_TEST_FAILURE") in ("switch", "rollback"):
            sys.exit(11)
elif args[:2] == ["image", "inspect"]:
    pass
elif args[0] == "ps":
    if "label=com.docker.compose.service=newsletter" not in args:
        print("running-container")
        if "--all" in args or any(a.startswith("-") and not a.startswith("--") and "a" in a for a in args):
            print("stopped-container")
elif args[0] == "inspect":
    if os.environ.get("BACKUP_TEST_FAILURE") == "inspect":
        sys.exit(7)
    if any(".State.Running" in arg for arg in args):
        probe_path = root / "health-probes"
        probes = int(probe_path.read_text()) if probe_path.exists() else 0
        probe_path.write_text(str(probes + 1))
        failure = os.environ.get("BACKUP_TEST_FAILURE")
        unhealthy = (failure == "unhealthy" and images["websocket-server"] == new_image) or (failure == "transient-health" and probes == 0)
        print("true unhealthy" if unhealthy else "true healthy")
    elif "--format" not in args:
        print(json.dumps([{"State": {"Running": True}, "Image": image,
            "Config": {"Labels": {"com.docker.compose.service": name,
                "com.docker.compose.project.config_files":
                (root / "running-config").read_text() if (root / "running-config").exists() else ""}}}
            for name, image in images.items()]))
    elif "running-container" in args:
        print("active-sqlite\\nshared")
    if any(".Mounts" in arg for arg in args) and "stopped-container" in args:
        print("stopped-sqlite\\nshared")
elif args[:2] == ["volume", "ls"]:
    if os.environ.get("BACKUP_TEST_FAILURE") == "catalog":
        sys.exit(8)
    print("legacy\\nshared")
elif args[:2] == ["volume", "inspect"]:
    print("volume=" + args[2] + " mountpoint=" + str(root / "volumes" / args[2]))
elif args[0] == "run":
    assert (root / "stopped").exists(), "live volumes must only be copied while stopped"
    if os.environ.get("BACKUP_TEST_FAILURE") == "copy":
        sys.exit(9)
    volume = next(x.removesuffix(":/volume:ro") for x in args if x.endswith(":/volume:ro"))
    backup = next(x.removesuffix(":/backup") for x in args if x.endswith(":/backup"))
    assert "tar -cf " in args[-1], "volume copies must be uncompressed"
    subprocess.run(["tar", "-cf", str(pathlib.Path(backup) / (volume + ".tar")),
                    "-C", str(root / "volumes" / volume), "."], check=True)
else:
    raise SystemExit("unsupported fixture command")
''')
        docker.chmod(0o755)
        gzip = bin_dir / "gzip"
        gzip.write_text('''#!/usr/bin/env bash
set -euo pipefail
test ! -f "$BACKUP_TEST_ROOT/stopped"
if [[ ${BACKUP_TEST_FAILURE:-} == compression ]]; then exit 10; fi
exec /usr/bin/gzip "$@"
''')
        gzip.chmod(0o755)
        self.env = {**os.environ, "PATH": str(bin_dir) + os.pathsep + os.environ["PATH"],
                    "BACKUP_TEST_ROOT": str(self.root)}

    def run_backup(self, *args, **env):
        return subprocess.run(["bash", str(self.script), *map(str, args)], env={**self.env, **env},
                              capture_output=True, text=True)

    def prepare_deploy(self):
        config = self.root / "compose-rollback.json"
        result = self.run_backup("--prepare-deploy", config)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        model = json.loads(config.read_text())
        self.assertEqual(model["services"]["websocket-server"]["image"], "sha256:" + "1" * 64)
        self.assertNotIn("build", model["services"]["websocket-server"])
        self.assertEqual(config.stat().st_mode & 0o777, 0o600)
        # Real Compose must recover literal dollars, not reinterpret environment.
        rendered = subprocess.run([shutil.which("docker"), "compose", "--env-file", "/dev/null",
                                   "-f", str(config), "config", "--format", "json"],
                                  env={**os.environ, "VALUE": "not-the-original"},
                                  capture_output=True, text=True)
        self.assertEqual(rendered.returncode, 0, rendered.stderr)
        self.assertEqual(json.loads(rendered.stdout)["services"]["websocket-server"]["environment"]["SECRET"],
                         "literal$$VALUE")  # config re-escapes the unchanged literal dollar.
        return config

    def test_deployment_switches_directly_to_new_images(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server", "new-sidecar")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads((self.root / "images.json").read_text()),
                         {"websocket-server": "sha256:" + "2" * 64,
                          "new-sidecar": "sha256:" + "2" * 64})
        self.assertFalse((self.root / "stopped").exists())
        self.assertEqual(len(list(self.backups.glob("*/*.tar.gz"))), len(self.volumes))

    def test_failed_image_switch_restores_old_images_and_keeps_snapshot(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server", "new-sidecar",
                                 BACKUP_TEST_FAILURE="switch")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(json.loads((self.root / "images.json").read_text()),
                         {"websocket-server": "sha256:" + "1" * 64})
        self.assertFalse((self.root / "stopped").exists())
        self.assertEqual(len(list(self.backups.glob("*.partial/*.tar"))), len(self.volumes))
        # A second attempt must capture the restored config, not failed source.
        next_config = self.root / "retry/compose-rollback.json"
        result = self.run_backup("--prepare-deploy", next_config, CURRENT_CONFIG_SECRET="wrong-config")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(json.loads(next_config.read_text())["services"]["websocket-server"]["environment"]["SECRET"],
                         "literal$$VALUE")

    def test_changed_running_images_refuse_deployment_before_stop(self):
        config = self.prepare_deploy()
        images = self.root / "images.json"
        images.write_text(json.dumps({"websocket-server": "sha256:" + "3" * 64}))
        result = self.run_backup("--deploy", config, "websocket-server")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "stopped").exists())
        self.assertFalse((self.root / "switched").exists())

    def test_transient_unhealthy_status_is_allowed_to_recover_before_deadline(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server",
                                 BACKUP_TEST_FAILURE="transient-health")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertGreater(int((self.root / "health-probes").read_text()), 1)
        self.assertEqual(json.loads((self.root / "images.json").read_text())["websocket-server"],
                         "sha256:" + "2" * 64)

    def test_persistent_unhealthy_status_rolls_back_after_deadline(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server",
                                 BACKUP_TEST_FAILURE="unhealthy")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not become ready", result.stderr)
        self.assertEqual(json.loads((self.root / "images.json").read_text()),
                         {"websocket-server": "sha256:" + "1" * 64})
        self.assertFalse((self.root / "stopped").exists())

    def test_failed_rollback_reports_failure_and_keeps_recovery_copies(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server",
                                 BACKUP_TEST_FAILURE="rollback")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.root / "stopped").exists())
        self.assertEqual(len(list(self.backups.glob("*.partial/*.tar"))), len(self.volumes))

    def test_deployment_copy_failure_restarts_old_containers_without_switch(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server",
                                 BACKUP_TEST_FAILURE="copy")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "stopped").exists())
        self.assertFalse((self.root / "switched").exists())

    def test_post_switch_compression_failure_does_not_revert_live_images(self):
        config = self.prepare_deploy()
        result = self.run_backup("--deploy", config, "websocket-server",
                                 BACKUP_TEST_FAILURE="compression")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "stopped").exists())
        self.assertEqual(json.loads((self.root / "images.json").read_text())["websocket-server"],
                         "sha256:" + "2" * 64)
        self.assertEqual(len(list(self.backups.glob("*.partial/*.tar"))), len(self.volumes))

    def test_archives_labelled_and_unlabelled_running_and_stopped_volumes_once(self):
        result = self.run_backup()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        completed, = [p for p in self.backups.iterdir() if not p.name.endswith(".partial")]
        self.assertEqual({p.name for p in completed.glob("*.tar.gz")},
                         {name + ".tar.gz" for name in self.volumes})
        for name in self.volumes:
            with tarfile.open(completed / (name + ".tar.gz")) as archive:
                self.assertEqual(archive.extractfile("./payload").read(), (name + " snapshot").encode())
        verified = subprocess.run(["sha256sum", "-c", "SHA256SUMS"], cwd=completed,
                                  capture_output=True, text=True)
        self.assertEqual(verified.returncode, 0, verified.stderr)
        manifest = dict(line.split("=", 1) for line in (completed / "manifest.txt").read_text().splitlines())
        self.assertEqual(manifest["volumes"].split(), sorted(self.volumes))
        self.assertFalse((self.root / "stopped").exists())
        self.assertEqual((self.root / "volumes/active-sqlite/payload").read_text(),
                         "changed after restart")

    def test_copy_and_compression_failures_leave_services_running_and_no_backup(self):
        for failure in ("copy", "compression"):
            with self.subTest(failure=failure):
                result = self.run_backup(BACKUP_TEST_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "stopped").exists())
                self.assertEqual(list(self.backups.iterdir()), [])

    def test_discovery_failure_cannot_produce_a_successful_incomplete_backup(self):
        for failure in ("inspect", "catalog"):
            with self.subTest(failure=failure):
                result = self.run_backup(BACKUP_TEST_FAILURE=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(list(self.backups.rglob("*.tar.gz")))


if __name__ == "__main__":
    unittest.main()
