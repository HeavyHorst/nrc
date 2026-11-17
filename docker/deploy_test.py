"""Exercise deploy's storage guard with real Compose rendering and an isolated host."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parent
DOCKER = shutil.which("docker")


class DeploymentStorageTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        root = Path(self.temp.name)
        self.repo = root / "repo"
        self.remote = root / "remote"
        self.bin = root / "bin"
        for path in (self.repo / "docker", self.remote / "docker", self.bin):
            path.mkdir(parents=True)
        for name in ("deploy.sh", "docker-compose.yml"):
            shutil.copyfile(SOURCE / name, self.repo / "docker" / name)
        for args in (
            ("init", "-q", "-b", "main"),
            ("add", "."),
            ("-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "commit", "-qm", "fixture"),
            ("update-ref", "refs/remotes/origin/main", "HEAD"),
        ):
            subprocess.run(["git", *args], cwd=self.repo, check=True)
        self.env = dict(os.environ)
        for name in ("NRC_TASK_DATA_VOLUME", "COMPOSE_PROJECT_NAME", "COMPOSE_FILE"):
            self.env.pop(name, None)
        self.env.update(
            PATH=f"{self.bin}:{os.environ['PATH']}",
            NRC_DEPLOY_HOST="isolated-host",
            NRC_DEPLOY_DIR=str(self.remote),
            ACTIVE_VOLUME="docker_sqlite-migrated",
            REAL_DOCKER=DOCKER,
            MUTATIONS=str(root / "mutations"),
        )
        # Run only read-only remote commands, even if the guard regresses.
        # Compose itself parses the actual file; no Docker daemon is needed.
        self.tool("ssh", '''
case "$2" in
  "if test -f "*|"docker ps "*|"bash -s"|*" && bash -s"|*" config --format json")
    exec bash -c "$2" ;;
  *) echo "$2" >> "$MUTATIONS"; exit 1 ;;
esac
''')
        self.tool("rsync", 'cat >/dev/null; echo docker/docker-compose.yml')
        self.tool("docker", r'''
case "$1" in
  compose) exec "$REAL_DOCKER" "$@" ;;
  ps)
    [[ "$*" == *service=newsletter* ]] && exit 0
    if [[ "$*" == *service=incidents* ]]; then
      [[ ${MONITORING_RUNNING:-true} == true ]] && echo incidents-id
      exit 0
    fi
    if [[ $ACTIVE_VOLUME == *$'\n'* ]]; then
      printf 'server-one\nserver-two\n'
    elif [[ -n $ACTIVE_VOLUME ]]; then
      echo server-id
    fi
    ;;
  inspect)
    case "$*" in
      *Mounts*) printf '%s\n' "$ACTIVE_VOLUME" ;;
      *Config.Image*) echo nrc-server:fixture ;;
      *Image*) echo sha256:fixture ;;
      *) exit 1 ;;
    esac
    ;;
  image) echo sha256:fixture ;;
  *) echo "$*" >> "$MUTATIONS"; exit 1 ;;
esac
''')

    def tool(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env bash\nset -euo pipefail\n" + body + "\n")
        path.chmod(0o755)

    def configure(self, volume=None):
        text = "NRC_JWT_SECRET=fixture-jwt\nNRC_BOT_SECRET=fixture-bot\n"
        if volume is not None:
            text += f"NRC_TASK_DATA_VOLUME={volume}\n"
        (self.remote / ".env").write_text(text)

    def deploy(self, *args):
        before = (self.remote / ".env").read_bytes()
        result = subprocess.run(
            ["bash", "docker/deploy.sh", *args], cwd=self.repo,
            env=self.env, capture_output=True, text=True,
        )
        self.assertEqual((self.remote / ".env").read_bytes(), before)
        self.assertFalse(Path(self.env["MUTATIONS"]).exists())
        return result

    def test_migrated_volume_and_project_default_are_preserved(self):
        for volume, configured in (
            ("docker_sqlite-migrated", "docker_sqlite-migrated"),
            ("docker_task-data", None),
        ):
            with self.subTest(volume=volume):
                self.env["ACTIVE_VOLUME"] = volume
                self.configure(configured)
                result = self.deploy("--dry-run")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Verified production data volume: {volume}", result.stdout)
                self.assertIn("production was not changed", result.stdout)

    def test_missing_override_or_wrong_volume_blocks_real_deployment(self):
        for configured in (None, "docker_task-data", "docker_sqlite-typo"):
            with self.subTest(configured=configured):
                self.configure(configured)
                result = self.deploy("--skip-tests")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("differs from running 'docker_sqlite-migrated'", result.stderr)

    def test_unverifiable_live_storage_blocks_deployment(self):
        self.configure("docker_sqlite-migrated")
        for active in ("", "docker_sqlite-migrated\ndocker_sqlite-migrated", "/bind/path"):
            with self.subTest(active=active):
                self.env["ACTIVE_VOLUME"] = active
                result = self.deploy("--skip-tests")
                self.assertNotEqual(result.returncode, 0)
                self.assertRegex(result.stderr, "cannot verify production storage|expected one named")

    def test_guard_checks_the_actual_incoming_mount(self):
        self.configure("docker_sqlite-migrated")
        compose = self.repo / "docker/docker-compose.yml"
        compose.write_text(compose.read_text().replace(
            "task-data:/app/data", "attachments:/app/data", 1,
        ))
        subprocess.run(
            ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid",
             "commit", "-qam", "change mount"], cwd=self.repo, check=True,
        )
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                       cwd=self.repo, check=True)
        result = self.deploy("--skip-tests")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("incoming task-data volume 'docker_attachments'", result.stderr)

    def test_deleted_source_is_backed_up_without_removing_host_files(self):
        self.configure("docker_sqlite-migrated")
        obsolete = ("shard_compaction.odin", "removed/package/old.go", "old[1].odin")
        for name in obsolete:
            path = self.repo / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("obsolete source")
        subprocess.run(["git", "add", "."], cwd=self.repo, check=True)
        identity = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid"]
        subprocess.run(["git", *identity, "commit", "-qm", "old source"],
                       cwd=self.repo, check=True)
        shutil.copytree(self.repo, self.remote, dirs_exist_ok=True,
                        ignore=shutil.ignore_patterns(".git"))
        subprocess.run(["git", "rm", "-q", *obsolete], cwd=self.repo, check=True)
        subprocess.run(["git", *identity, "commit", "-qm", "remove old source"],
                       cwd=self.repo, check=True)
        subprocess.run(["git", "update-ref", "refs/remotes/origin/main", "HEAD"],
                       cwd=self.repo, check=True)
        private = ("host.env", "data/retained.wal", "removed/package/private.env",
                   "old1.odin")
        for name in private:
            path = self.remote / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("host-only data")
        # A local untracked copy of old source must not be sent either.
        (self.repo / obsolete[0]).write_text("local scratch")
        saved_filter = Path(self.temp.name) / "source.filter"
        self.env.update(REAL_RSYNC=shutil.which("rsync"), SAVED_FILTER=str(saved_filter))
        self.tool("rsync", r'''
args=("$@")
for arg in "$@"; do
  if [[ $arg == --filter=merge\ * ]]; then
    cp "${arg#--filter=merge }" "$SAVED_FILTER"
  fi
done
last=$((${#args[@]} - 1))
args[$last]=${args[$last]#isolated-host:}
exec "$REAL_RSYNC" "${args[@]}"
''')
        result = self.deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Services to rebuild: websocket-server", result.stdout)
        for name in obsolete:
            self.assertIn(f"deleting {name}", result.stdout)
            self.assertTrue((self.remote / name).exists())
        backup = Path(self.temp.name) / "rollback"
        subprocess.run(
            [self.env["REAL_RSYNC"], "-rlt", "--delete", "--backup",
             f"--backup-dir={backup}", f"--filter=merge {saved_filter}",
             f"{self.repo}/", f"{self.remote}/"], check=True, capture_output=True,
        )
        for name in obsolete:
            self.assertFalse((self.remote / name).exists())
            self.assertEqual((backup / name).read_text(), "obsolete source")
        for name in private:
            self.assertEqual((self.remote / name).read_text(), "host-only data")
        parity = self.deploy("--dry-run")
        self.assertEqual(parity.returncode, 0, parity.stderr)
        self.assertIn("nothing to deploy", parity.stdout)

    def test_compose_uses_custom_project_and_graceful_shutdown(self):
        self.configure()
        result = subprocess.run(
            [DOCKER, "compose", "--project-name", "nrc-fixture",
             "--project-directory", str(self.remote / "docker"),
             "--env-file", str(self.remote / ".env"),
             "-f", str(self.repo / "docker/docker-compose.yml"),
             "config", "--format", "json"],
            env=self.env, capture_output=True, text=True, check=True,
        )
        model = json.loads(result.stdout)
        self.assertEqual(model["volumes"]["task-data"]["name"], "nrc-fixture_task-data")
        self.assertEqual(model["services"]["websocket-server"]["stop_signal"], "SIGINT")

    def test_monitoring_deploy_preserves_gateway_and_selects_changed_services(self):
        self.configure("docker_sqlite-migrated")
        shutil.copyfile(SOURCE / "compose.monitoring.yml",
                        self.remote / "docker/compose.monitoring.yml")
        (self.remote / "monitoring.env").write_text(
            "NRC_MONITOR_WORKSPACE=workspace1\nNRC_HISTORY_SECRET=" + "a" * 64 + "\n")
        for changed, services in (
            ("services/bots/nrc-incidents/main.go", "incidents"),
            ("docker/compose.monitoring.yml", "tailscale-proxy incidents"),
            ("protocol-go/monitoring.go", "websocket-server search ai metrics-bot incidents"),
        ):
            with self.subTest(changed=changed):
                self.tool("rsync", f"cat >/dev/null; echo {changed}")
                result = self.deploy("--dry-run")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(f"Services to rebuild: {services}\n", result.stdout)
        self.env["MONITORING_RUNNING"] = "false"
        self.tool("rsync", "cat >/dev/null")
        result = self.deploy("--dry-run")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Services to rebuild: tailscale-proxy incidents\n", result.stdout)
        # Render the same overlay with publishing enabled: its !override must
        # not remove the history gateway, and neither service exposes history.
        shutil.copyfile(SOURCE / "compose.publish.yml",
                        self.remote / "docker/compose.publish.yml")
        self.env.update(NRC_PUBLISH_WORKSPACE="docs", PUBLISH_ADMIN_USER="test",
                        PUBLISH_ADMIN_PASSWORD="fixture-password")
        result = subprocess.run(
            [DOCKER, "compose", "--project-directory", str(self.remote / "docker"),
             "--env-file", str(self.remote / ".env"),
             "--env-file", str(self.remote / "monitoring.env"),
             "-f", str(self.repo / "docker/docker-compose.yml"),
             "-f", str(self.remote / "docker/compose.publish.yml"),
             "-f", str(self.remote / "docker/compose.monitoring.yml"),
             "config", "--format", "json"],
            env=self.env, capture_output=True, text=True, check=True,
        )
        model = json.loads(result.stdout)
        proxy = model["services"]["tailscale-proxy"]
        self.assertEqual(proxy["environment"]["NRC_PUBLISH_BACKEND"], "http://publish:8094")
        self.assertEqual(proxy["environment"]["NRC_MONITOR_HISTORY_BACKEND"], "http://incidents:8095")
        self.assertEqual(proxy["environment"]["NRC_MONITOR_HISTORY_WORKSPACE"], "workspace1")
        self.assertEqual(proxy["environment"]["NRC_HISTORY_SECRET"], "a" * 64)
        evaluator = model["services"]["incidents"]
        self.assertFalse(evaluator.get("ports"))
        self.assertTrue(evaluator["read_only"])
        self.assertEqual(evaluator["environment"]["NRC_BOT_SECRET"], "fixture-bot")
        mount, = evaluator["volumes"]
        self.assertEqual((mount["type"], mount["source"], mount["target"]),
                         ("volume", "monitoring-history", "/data"))
        self.assertIn("ws://websocket-server:8080", evaluator["command"])
        self.assertNotIn("-monitors", evaluator["command"])


if __name__ == "__main__":
    unittest.main()
