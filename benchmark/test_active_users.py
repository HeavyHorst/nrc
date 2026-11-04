import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

from run_active_users import cpu_plan


class PlacementTest(unittest.TestCase):
    def test_smt_siblings_never_split_between_roles(self):
        # Deliberately use interleaved SMT numbering, unlike hx90's adjacent pairs.
        def topology(path, *args, **kwargs):
            cpu = int(str(path).split("/cpu")[-1].split("/")[0])
            return "0" if path.name == "physical_package_id" else str(cpu % 8)

        with patch("os.sched_getaffinity", return_value=set(range(16))), patch.object(Path, "read_text", topology):
            plan = cpu_plan(3, 2)
        roles = [plan["housekeeping"][0], plan["service"], plan["storage"],
                 *plan["workers"], *plan["generators"]]
        self.assertEqual(len({cpu % 8 for cpu in roles}), len(roles))
        self.assertEqual(len(plan["workers"]), 3)
        self.assertEqual(len(plan["generators"]), 2)

    def test_restricted_cpuset_does_not_oversubscribe(self):
        def topology(path, *args, **kwargs):
            cpu = int(str(path).split("/cpu")[-1].split("/")[0])
            return "0" if path.name == "physical_package_id" else str(cpu // 2)

        with patch("os.sched_getaffinity", return_value={2, 3, 6, 7}), patch.object(Path, "read_text", topology):
            with self.assertRaisesRegex(ValueError, "physical cores"):
                cpu_plan(2, 2)


class LifecycleTest(unittest.TestCase):
    def test_sigterm_reaps_children_and_preserves_fixture_placement(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            dummy = root / "dummy"
            dummy.write_text("#!/usr/bin/env python3\n" + '''
import json, os, signal, socket, sys, time
from pathlib import Path
role = 'generator' if '--disposable' in sys.argv else 'server'
base = Path(__file__).parent
def stop(sig, frame):
    (base / (role + '.stopping')).touch()
    time.sleep(.3)
    sys.exit(0)
signal.signal(signal.SIGINT, stop)
if role == 'server':
    sock = socket.socket()
    sock.bind(('127.0.0.1', int(os.environ['NRC_PORT'])))
    sock.listen()
record = base / (role + '.tmp')
record.write_text(json.dumps({'pid': os.getpid(), 'argv': sys.argv}))
record.rename(base / (role + '.json'))
while True: time.sleep(.05)
''')
            dummy.chmod(0o700)
            prefixes = []
            for name in ('first', 'second'):
                for role in ('server', 'generator'):
                    (root / (role + '.json')).unlink(missing_ok=True)
                    (root / (role + '.stopping')).unlink(missing_ok=True)
                # Tiny lifecycle fixture needs no separate performance cores.
                code = '''
import os, sys
import run_active_users as runner
cpu = min(os.sched_getaffinity(0))
runner.cpu_plan = lambda w, g: dict(service=cpu, storage=cpu, workers=[cpu], generators=[cpu])
sys.exit(runner.main())
'''
                command = [sys.executable, '-B', '-c', code, '--users=2', '--workspaces=1',
                           '--workers=1', '--generators=1', '--server-bin=' + str(dummy),
                           '--generator-bin=' + str(dummy), '--output=' + str(root / name)]
                proc = subprocess.Popen(command, cwd=Path(__file__).parent,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                children = []
                try:
                    deadline = time.monotonic() + 10
                    while not (root / 'generator.json').exists():
                        self.assertIsNone(proc.poll(), 'coordinator exited before children started')
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.02)
                    records = [json.loads((root / (role + '.json')).read_text())
                               for role in ('server', 'generator')]
                    children = [r['pid'] for r in records]
                    prefixes.append(next(a for a in records[1]['argv'] if a.startswith('--prefix=')))
                    proc.send_signal(signal.SIGTERM)
                    deadline = time.monotonic() + 5
                    while not (root / 'generator.stopping').exists():
                        self.assertLess(time.monotonic(), deadline)
                        time.sleep(.01)
                    proc.send_signal(signal.SIGTERM)
                    self.assertEqual(proc.wait(timeout=10), 1)
                    summary = json.loads((root / name / 'summary.json').read_text())
                    self.assertFalse(summary['passed'])
                    self.assertEqual(summary['harness_error'], 'interrupted')
                    for pid in children:
                        with self.assertRaises(ProcessLookupError):
                            os.kill(pid, 0)
                finally:
                    if proc.poll() is None:
                        proc.kill()
                        proc.wait()
                    for pid in children:
                        try:
                            os.kill(pid, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
            self.assertEqual(prefixes, ['--prefix=active-benchmark'] * 2)


if __name__ == "__main__":
    unittest.main()
