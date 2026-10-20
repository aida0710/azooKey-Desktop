"""A failed recovery message must not prevent validated input settings."""
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest

try:
    from gi.repository import GLib
    from azookey.reading_engine import ReadingEngine
except (ImportError, ValueError):
    ReadingEngine = None

from azookey.reading_settings_bootstrap import ReadingSettingsBootstrap
from azookey.worker_settings import UnsupportedWorkerSettings
from worker_settings_fixture import settings_values


@unittest.skipIf(ReadingEngine is None, "requires the IBus and GTK Python bindings")
class ReadingEngineSettingsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "settings.json"
        self.path.write_bytes(b"broken synthetic settings")
        self.notices = []
        self.engine = SimpleNamespace(
            settings_bootstrap=ReadingSettingsBootstrap(path=self.path),
            notice=self.notices.append,
        )

    def test_failed_toolkit_notice_keeps_recovered_settings_and_the_original_file(self):
        def unavailable(notice):
            self.notices.append(notice)
            raise GLib.Error("injected recovery display failure")

        self.engine.notice = unavailable
        defaults = settings_values(halfSpace=True)
        with self.assertLogs("azookey.reading_engine", level="ERROR"):
            loaded = ReadingEngine.load_settings(self.engine, defaults)
        self.assertEqual(loaded, defaults)
        self.assertEqual([notice.code for notice in self.notices], ["reading_settings_recovery"])
        self.assertEqual(self.path.read_bytes(), b"broken synthetic settings")
        self.assertEqual(list(self.path.parent.iterdir()), [self.path])

    def test_unsupported_fallback_never_announces_a_successful_recovery(self):
        with self.assertRaises(UnsupportedWorkerSettings):
            ReadingEngine.load_settings(self.engine, settings_values(live=True))
        self.assertEqual(self.notices, [])
        self.assertEqual(self.path.read_bytes(), b"broken synthetic settings")


if __name__ == "__main__":
    unittest.main()
