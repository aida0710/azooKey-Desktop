import pathlib
import sys
import tempfile
import time
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge


class TransportTests(unittest.TestCase):
    def test_stopped_converter_recovers_on_the_next_request(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / "echo-json"
            executable.write_text('#!/usr/bin/env python3\nimport sys\nfor line in sys.stdin:\n print(line.strip(), flush=True)\n')
            executable.chmod(0o700)
            bridge = Bridge(str(executable), timeout=1)
            try:
                self.assertEqual(bridge.request("snapshot")["operation"], "snapshot")
                bridge.process.kill()
                bridge.process.wait(timeout=2)
                self.assertEqual(bridge.request("settings")["operation"], "settings")
                self.assertEqual(bridge.restarts, 1)
            finally:
                bridge.close()

    def test_unresponsive_converter_has_a_bounded_timeout(self):
        with tempfile.TemporaryDirectory() as directory:
            executable = pathlib.Path(directory) / "unresponsive"
            executable.write_text("#!/usr/bin/env python3\nimport time\ntime.sleep(10)\n")
            executable.chmod(0o700)
            bridge = Bridge(str(executable), timeout=0.1)
            start = time.monotonic()
            try:
                with self.assertRaisesRegex(RuntimeError, "timed out"):
                    bridge.request("snapshot")
                self.assertLess(time.monotonic() - start, 2)
            finally:
                bridge.close()
