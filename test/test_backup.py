"""Run the backup script against disposable volume fixtures, without Docker."""

import os
from pathlib import Path
import shlex
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
        self.script = self.root / "backup.sh"
        self.script.write_text(script)
        bin_dir = self.root / "bin"
        bin_dir.mkdir()
        docker = bin_dir / "docker"
        docker.write_text('''#!/usr/bin/env python3
import os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["BACKUP_TEST_ROOT"])
args = sys.argv[1:]
if args[0] == "compose":
    if "ps" in args:
        print("websocket-server" if "--services" in args else "fixture service")
    elif "stop" in args:
        (root / "stopped").touch()
    elif "start" in args:
        (root / "stopped").unlink()
        for payload in (root / "volumes").glob("*/payload"):
            payload.write_text("changed after restart")
    elif "up" in args:
        raise SystemExit("backup must not recreate containers")
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
    if "running-container" in args:
        print("active-sqlite\\nshared")
    if "stopped-container" in args:
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

    def run_backup(self, **env):
        return subprocess.run(["bash", str(self.script)], env={**self.env, **env},
                              capture_output=True, text=True)

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
