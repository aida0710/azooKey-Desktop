"""AI candidates advertise pointer actions, while digits keep editing the reading."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY") and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires Xvfb and the Swift bridge")
class CandidateSuggestionTests(unittest.TestCase):
    def test_ai_pages_hide_number_shortcuts_but_keep_original_reading_and_pointer_selection(self):
        from azookey.bridge import Bridge
        from azookey.keymap import translate
        from candidate_core import core_tree_panel
        from gi.repository import Gtk

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        bridge = Bridge(environment={**os.environ, "AZOOKEY_DATA_DIR": directory.name})
        self.addCleanup(bridge.close)
        original_settings = bridge.request("settings")["settings"]
        self.addCleanup(bridge.request, "configure", settings=original_settings)
        bridge.request("configure", settings={**original_settings, "tree": True, "live": True})
        document = Gtk.Window()
        entry = Gtk.Entry()
        document.add(entry)
        document.show_all()
        entry.grab_focus()
        self.addCleanup(document.destroy)
        commits = []

        def choose(operation, index, submit):
            response = bridge.request(operation, index=index, submit=submit,
                                      generation=panel.snapshot["generation"])
            commits.extend(response["commits"])
            panel.update(response)

        panel = core_tree_panel(choose)
        self.addCleanup(panel.destroy)
        for character in "nihongo":
            snapshot = bridge.request("key", event=translate(ord(character), 0))
        for _ in range(2):
            snapshot = bridge.request("key", event=translate(ord(" "), 0))
        panel.update(snapshot)
        self.assertTrue(snapshot["showCandidateIndex"])
        self.assertEqual(panel.navigation.row_buttons[0].number_label.get_text(), "1")

        original_reading = snapshot["reading"]
        suggestions = [f"AI提案{index}" for index in range(12)]
        snapshot = bridge.request("suggestions", suggestions=suggestions,
                                  reading=original_reading, generation=snapshot["generation"])
        panel.update(snapshot)
        self.assertEqual(snapshot["inputState"], "replaceSuggestion")
        self.assertFalse(snapshot["showCandidateIndex"])
        self.assertTrue(all(not button.number_label.get_text() for button in panel.navigation.row_buttons))
        self.assertEqual([button.text_label.get_text() for button in panel.navigation.row_buttons], suggestions[:9])
        panel.navigation.next.clicked()
        self.assertEqual(panel.snapshot["candidatePage"]["start"], 9)
        self.assertEqual([button.text_label.get_text() for button in panel.navigation.row_buttons], suggestions[9:])
        self.assertEqual(commits, [])
        self.assertIs(document.get_focus(), entry)
        self.assertFalse(panel.get_accept_focus())

        typed = bridge.request("key", event=translate(ord("1"), 0))
        panel.update(typed)
        self.assertEqual(typed["reading"], original_reading + "1")
        self.assertEqual(typed["inputState"], "composing")
        self.assertEqual(typed["commits"], [])
        snapshot = bridge.request("suggestions", suggestions=suggestions,
                                  reading=typed["reading"], generation=typed["generation"])
        panel.update(snapshot)
        panel.navigation.row_buttons[1].clicked()
        self.assertEqual(commits, [])
        panel.navigation.confirm.clicked()
        self.assertEqual(commits, [suggestions[1]])
        self.assertEqual(panel.snapshot["reading"], "")
        self.assertIs(document.get_focus(), entry)


if __name__ == "__main__":
    unittest.main()
