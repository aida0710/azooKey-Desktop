"""Check the recovery preview against actual Core snapshots, without AI calls."""
import os
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.input_preview import InputPreview
from azookey.keymap import translate


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "requires the Swift bridge with input-state metadata")
class BridgePreviewTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="azookey-bridge-preview-")
        self.addCleanup(self.directory.cleanup)
        self.bridge = Bridge(environment={
            **os.environ, "AZOOKEY_DATA_DIR": self.directory.name, "XDG_CONFIG_HOME": self.directory.name,
        })
        self.addCleanup(self.bridge.close)
        self.settings = {**self.bridge.request("settings")["settings"], "live": False, "learning": "nothing"}
        self.assertFalse(self.bridge.request("configure", settings=self.settings).get("error"))
        for character in "nihongo":
            self.bridge.request("key", event=translate(ord(character), 0))

    def test_acknowledged_conversion_and_reading_cursor_reach_the_recovery_preview(self):
        converted = self.bridge.request("key", event=translate(32, 0))
        self.assertEqual(converted["inputState"], "previewing")
        self.assertEqual(converted["readingCursor"], 4)
        preview = InputPreview(converted, settings=self.settings)
        self.assertTrue(preview.apply(translate(0xFF1B, 0)))
        self.assertEqual(preview.visible_text, "にほんご")
        self.bridge.request("key", event=translate(0xFF1B, 0))
        moved = self.bridge.request("key", event=translate(0xFF51, 0))
        self.assertEqual(moved["readingCursor"], 3)
        preview = InputPreview(moved, settings=self.settings)
        self.assertTrue(preview.apply(translate(ord("a"), 0)))
        self.assertEqual(preview.visible_text, "にほんaご")

    def test_typing_after_actual_suggestion_snapshot_restores_original_reading(self):
        reading = self.bridge.request("snapshot")
        suggestion = self.bridge.request(
            "suggestions", suggestions=["人工知能の候補"], reading=reading["reading"], generation=reading["generation"],
        )
        self.assertEqual(suggestion["inputState"], "replaceSuggestion")
        self.assertEqual(suggestion["preedit"], "人工知能の候補")
        self.assertEqual(suggestion["readingCursor"], 4)
        preview = InputPreview(suggestion, settings=self.settings)
        self.assertTrue(preview.apply(translate(ord("a"), 0)))
        self.assertEqual(preview.visible_text, "にほんごa")
        completed = self.bridge.request("key", event=translate(ord("a"), 0))
        self.assertEqual(completed["reading"], "にほんごあ")
        self.assertEqual(completed["commits"], [])


if __name__ == "__main__":
    unittest.main()
