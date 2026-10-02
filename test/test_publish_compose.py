"""Render the publishing overlay with synthetic, conflicting credential sources."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class PublishComposeTest(unittest.TestCase):
    def test_shared_credentials_ignore_shell_overrides(self):
        compose = [os.environ["COMPOSE_BIN"]] if "COMPOSE_BIN" in os.environ else ["docker", "compose"]
        if not shutil.which(compose[0]):
            self.skipTest("Docker Compose is not installed")
        if subprocess.run(compose + ["version"], capture_output=True).returncode:
            self.skipTest("Docker Compose is not installed")
        repo = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory(prefix="nrc-publish-compose-") as directory:
            root = Path(directory)
            docker = root / "docker"
            docker.mkdir()
            for name in ("docker-compose.yml", "compose.publish.yml"):
                shutil.copyfile(repo / "docker" / name, docker / name)
            credentials = {
                "NRC_JWT_SECRET": "fixture-file-signing-key",
                "NRC_JWT_ISSUER": "fixture-file-issuer",
                "NRC_BOT_SECRET": "fixture-file-bot-secret",
            }
            env_file = root / ".env"
            env_file.write_text("".join(f"{key}={value}\n" for key, value in credentials.items()))
            environment = {
                **os.environ,
                **{key: "fixture-shell-conflict" for key in credentials},
                "NRC_PUBLISH_WORKSPACE": "fixture-workspace",
                "PUBLISH_ADMIN_USER": "fixture-reviewer",
                "PUBLISH_ADMIN_PASSWORD": "fixture-reviewer-password",
                "TS_AUTHKEY": "fixture-tailnet-key",
            }
            result = subprocess.run(
                compose + ["--env-file", str(env_file), "-f", "docker-compose.yml",
                           "-f", "compose.publish.yml", "config", "--format", "json"],
                cwd=docker, env=environment, capture_output=True, text=True, check=True,
            )
            services = json.loads(result.stdout)["services"]
            for service in ("websocket-server", "tailscale-proxy", "publish"):
                for key, value in credentials.items():
                    self.assertEqual(services[service]["environment"][key], value, f"{service}: {key}")
            self.assertEqual(services["publish"]["environment"]["PUBLISH_ADMIN_USER"], "fixture-reviewer")
            proxy_env = services["tailscale-proxy"]["environment"]
            self.assertEqual(proxy_env["TS_AUTHKEY"], "fixture-tailnet-key")
            self.assertEqual(proxy_env["NRC_PUBLISH_BACKEND"], "http://publish:8094")
            self.assertEqual(proxy_env["NRC_PUBLISH_WORKSPACE"], "fixture-workspace")
            for service in ("websocket-server", "tailscale-proxy"):
                self.assertNotIn("PUBLISH_ADMIN_PASSWORD", services[service]["environment"])


if __name__ == "__main__":
    unittest.main()
