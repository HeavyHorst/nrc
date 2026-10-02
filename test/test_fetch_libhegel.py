"""Exercise download/cache failures and test-wrapper wiring without network or Odin."""

import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SHA256 = "1ceb1636f3dd8e939fef88e99e3417b9da23675c7847e4cb22717ca8834c699b"


class FetchLibhegelTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix="nrc fetch ")
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / "test").mkdir()
        for name in ("fetch_libhegel.sh", "run_odin_tests.sh"):
            shutil.copy2(ROOT / "test" / name, self.root / "test" / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.env = {**os.environ, "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
                    "FETCH_TEST_ROOT": str(self.root)}
        self.env.pop("HEGEL_LIBHEGEL_PATH", None)
        self.library = self.root / ".hegel/libhegel-0.33.3/libhegel-linux-amd64.so"
        self.command("uname", 'import sys; print("Linux" if sys.argv[1] == "-s" else "x86_64")')
        self.command("curl", '''import os, pathlib, sys
assert "https://github.com/hegeldev/hegel-rust/releases/download/v0.33.3/libhegel-linux-amd64.so" in sys.argv
assert sys.argv[sys.argv.index("--proto") + 1] == "=https"
assert sys.argv[sys.argv.index("--proto-redir") + 1] == "=https"
root = pathlib.Path(os.environ["FETCH_TEST_ROOT"])
with (root / "downloads").open("a") as log:
    log.write("download\\n")
pathlib.Path(sys.argv[sys.argv.index("--output") + 1]).write_bytes(os.environ.get("FETCH_PAYLOAD", "fixture library").encode())
sys.exit(int(os.environ.get("FETCH_CURL_EXIT", "0")))
''')
        # Stand in for SHA256's pinned digest, with an independent tiny fixture.
        # This checks that both cache hits and downloads actually verify the pin.
        self.command("sha256sum", f'''import pathlib, sys
assert "--check" in sys.argv and "--status" in sys.argv
digest, path = sys.stdin.read().strip().split("  ", 1)
assert digest == "{SHA256}"
sys.exit(0 if pathlib.Path(path).read_bytes() == b"fixture library" else 1)
''')

    def command(self, name, body):
        path = self.bin / name
        path.write_text("#!/usr/bin/env python3\n" + body + "\n")
        path.chmod(0o755)

    def fetch(self, **env):
        return subprocess.run([str(self.root / "test/fetch_libhegel.sh")], cwd=self.root,
                              env={**self.env, **env}, capture_output=True, text=True)

    def test_download_then_offline_cache(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(self.library) + "\n")
        self.assertEqual(self.library.read_bytes(), b"fixture library")
        self.assertFalse(list(self.library.parent.glob(".download.*")))
        result = self.fetch(FETCH_CURL_EXIT="7")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "downloads").read_text(), "download\n")

    def test_corrupt_download_and_partial_transfer_are_not_installed(self):
        for env in ({"FETCH_PAYLOAD": "wrong library"}, {"FETCH_CURL_EXIT": "7"}):
            with self.subTest(env=env):
                result = self.fetch(**env)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertFalse(self.library.exists())
                self.assertFalse(list(self.library.parent.glob(".download.*")))

    def test_corrupt_cache_fails_without_download_or_replacement(self):
        self.library.parent.mkdir(parents=True)
        self.library.write_bytes(b"tampered")
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Cached libhegel failed SHA256", result.stderr)
        self.assertFalse((self.root / "downloads").exists())
        self.assertEqual(self.library.read_bytes(), b"tampered")

    def test_explicit_path_is_absolute_and_missing_override_fails(self):
        override = self.root / "custom library.so"
        override.write_bytes(b"user supplied")
        result = self.fetch(HEGEL_LIBHEGEL_PATH=override.name)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, str(override) + "\n")
        result = self.fetch(HEGEL_LIBHEGEL_PATH="missing.so")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "downloads").exists())

    def test_unsupported_platform_does_not_download(self):
        self.command("uname", 'import sys; print("Darwin" if sys.argv[1] == "-s" else "arm64")')
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Linux amd64", result.stderr)
        self.assertFalse((self.root / "downloads").exists())

    def test_wrapper_exports_absolute_library_preserves_cwd_and_requires_hegel(self):
        self.command("odin", '''import os, pathlib, sys
root = pathlib.Path(os.environ["FETCH_TEST_ROOT"])
assert pathlib.Path.cwd() == root / "test"
assert os.environ["HEGEL_LIBHEGEL_PATH"] == str(root / ".hegel/libhegel-0.33.3/libhegel-linux-amd64.so")
assert sys.argv.count("-define:HEGEL_REQUIRED=true") == 1
output = pathlib.Path(next(arg.removeprefix("-out:") for arg in sys.argv if arg.startswith("-out:")))
output.write_text("#!/usr/bin/env bash\\ntest -f \\\"$HEGEL_LIBHEGEL_PATH\\\"\\n")
output.chmod(0o755)
''')
        for flags in ([], ["-define:HEGEL_REQUIRED=true"]):
            result = subprocess.run([str(self.root / "test/run_odin_tests.sh"), ".", *flags],
                                    cwd=self.root / "test", env={**self.env, "ODIN_BIN": str(self.bin / "odin")},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_wrapper_does_not_compile_after_download_failure(self):
        self.command("odin", 'import os, pathlib; pathlib.Path(os.environ["FETCH_TEST_ROOT"], "compiled").touch()')
        result = subprocess.run([str(self.root / "test/run_odin_tests.sh"), "."], cwd=self.root,
                                env={**self.env, "ODIN_BIN": str(self.bin / "odin"), "FETCH_CURL_EXIT": "7"},
                                capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.root / "compiled").exists())


if __name__ == "__main__":
    unittest.main()
