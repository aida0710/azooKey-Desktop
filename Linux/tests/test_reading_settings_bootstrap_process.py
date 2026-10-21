"""Read a saved custom table into real reading and candidate processes."""
import hashlib
import json
import os
from pathlib import Path
import sys
import unittest

from azookey.reading_settings_bootstrap import ReadingSettingsBootstrap
from reading_process_fixture import ReadingProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingSettingsBootstrapProcessTests(ReadingProcessTestCase):
    def prepare_worker_settings(self):
        directory = Path(self.environment["XDG_CONFIG_HOME"]) / "azookey-tree"
        directory.mkdir(parents=True)
        self.path = directory / "settings.json"
        self.saved = json.dumps({
            "live": False, "learning": "nothing", "halfSpace": True,
            "inputStyle": "custom", "customTable": "q\tにほんご\n",
            "aiEndpoint": "http://localhost:9999", "aiModel": "fixture-model", "includeContext": False,
        }).encode()
        self.path.write_bytes(self.saved)
        self.backup = directory / "settings.last-good.json"
        self.backup.write_bytes(b"preserve this synthetic backup")
        return {"settings_provider": ReadingSettingsBootstrap(path=self.path).load}

    def test_saved_custom_table_changes_real_reading_and_candidates_without_writing_preferences(self):
        agreement = self.coordinator._settings_agreement
        settings = agreement.reader["settings"]
        self.assertEqual(settings["inputStyle"], "custom")
        self.assertFalse(settings["live"])
        self.assertNotIn("aiEndpoint", settings)
        self.assertEqual(self.key(0x20)["commits"], [" "])
        self.assertEqual(self.type("q")["preedit"], "にほんご")
        self.key(0x20)
        self.drain_until(lambda: self.panels)
        batch = self.panels[-1].batch
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.assertEqual(self.key(0xff0d)["commits"], ["日本語"])
        self.flush_candidates()
        self.assertEqual(self.path.read_bytes(), self.saved)
        self.assertEqual(self.backup.read_bytes(), b"preserve this synthetic backup")
        self.record(saved_settings_sha256=hashlib.sha256(self.saved).hexdigest(),
                    custom_reading="にほんご", committed="日本語", settings_revision=agreement.reader["settingsRevision"],
                    original_replies=len(self.finished), preferences_unchanged=True)


if __name__ == "__main__":
    unittest.main()
