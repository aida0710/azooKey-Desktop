"""Process recovery must leave unrelated applications and settings windows alone."""
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).parents[2] / "Tools/tests"))
from ai_fixture_processes import installed_processes, require_stopped, stop_installed_processes


class FixtureProcessTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.installed = pathlib.Path(self.temporary.name)
        self.entrypoint = self.installed / "ibus-azookey-tree.py"
        self.entrypoint.write_text("print('ready', flush=True)\ninput()\n")
        self.children = []

    def tearDown(self):
        for process in self.children:
            if process.poll() is None:
                process.terminate()
            process.wait(timeout=5)
            process.stdout.close()
            process.stdin.close()
        self.temporary.cleanup()

    def start(self, arguments):
        process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        self.children.append(process)
        self.assertEqual(process.stdout.readline(), "ready\n")
        return process

    def test_only_the_matching_engine_is_stopped_and_exit_is_observed(self):
        engine = self.start([sys.executable, str(self.entrypoint), "--ibus"])
        unrelated = self.start([sys.executable, "-c", "print('ready', flush=True); input()"])
        self.assertEqual(installed_processes(self.installed), {engine.pid: "engine"})
        with self.assertRaises(RuntimeError):
            require_stopped(self.installed)
        stopped = stop_installed_processes(self.installed)
        self.assertEqual(stopped, {engine.pid: "engine"})
        self.assertIsNotNone(engine.poll())
        self.assertIsNone(unrelated.poll())
        require_stopped(self.installed)

    def test_an_open_settings_window_refuses_restoration_without_being_stopped(self):
        settings = self.start([sys.executable, str(self.entrypoint), "--setup"])
        with self.assertRaisesRegex(RuntimeError, "settings window"):
            stop_installed_processes(self.installed)
        self.assertIsNone(settings.poll())


if __name__ == "__main__":
    unittest.main()
