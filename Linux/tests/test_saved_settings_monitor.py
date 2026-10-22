"""Atomic saves and first-run directories must reach the existing input owner."""
import os
from pathlib import Path
import tempfile
import unittest

try:
    from gi.repository import GLib
    from azookey.saved_settings_monitor import SavedSettingsMonitor
except ImportError:
    SavedSettingsMonitor = None


# A failed local filesystem observation must end the test, not hang the suite.
OBSERVATION_TIMEOUT_MILLISECONDS = 3000


@unittest.skipIf(SavedSettingsMonitor is None, "requires Gio file monitoring")
class SavedSettingsMonitorTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.path = self.root / "config/azookey-tree/settings.json"
        self.observations = []
        self.loop = GLib.MainLoop()
        self.monitor = SavedSettingsMonitor(self.path, changed=self.changed,
                                            unavailable=lambda: self.fail("settings monitoring failed"))
        self.addCleanup(self.monitor.close)

    def changed(self):
        self.observations.append(self.path.read_bytes() if self.path.exists() else None)
        self.loop.quit()

    def observe(self, operation):
        count = len(self.observations)
        timeout = GLib.timeout_add(OBSERVATION_TIMEOUT_MILLISECONDS, self.loop.quit)
        try:
            operation()
            while len(self.observations) == count:
                self.loop.run()
                self.assertGreater(len(self.observations), count, "the saved document was not observed")
        finally:
            context = GLib.MainContext.default()
            if context.find_source_by_id(timeout) is not None:
                GLib.source_remove(timeout)

    def save(self, content):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        staged = self.path.with_suffix(".staged")
        staged.write_bytes(content)
        os.replace(staged, self.path)

    def drain(self):
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def test_first_save_is_detected_without_creating_initial_directories(self):
        self.assertFalse(self.path.parent.exists())
        self.observe(lambda: self.save(b"synthetic first save"))
        self.assertEqual(self.observations[-1], b"synthetic first save")
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_repeated_atomic_replacements_and_recreated_directory_are_observed(self):
        self.observe(lambda: self.save(b"first"))
        self.drain()
        self.observe(lambda: self.save(b"replacement"))
        self.drain()

        def recreate():
            self.path.unlink()
            self.path.parent.rmdir()
            self.save(b"recreated")

        self.observe(recreate)
        self.assertEqual(self.observations[-1], b"recreated")
        self.drain()
        self.observe(lambda: self.save(b"after directory recreation"))
        self.assertEqual(self.path.read_bytes(), b"after directory recreation")

    def test_unrelated_files_and_a_closed_monitor_do_not_request_dictionary_refresh(self):
        self.observe(lambda: self.save(b"unchanged"))
        self.drain()
        count = len(self.observations)
        (self.path.parent / "unrelated").write_bytes(b"ignored")
        self.drain()
        self.assertEqual(len(self.observations), count)
        self.monitor.close()
        self.save(b"after close")
        self.drain()
        self.assertEqual(len(self.observations), count)


if __name__ == "__main__":
    unittest.main()
