"""Readable candidate details stay reachable without committing or focusing."""

import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateDetailTests(unittest.TestCase):
    def setUp(self):
        from azookey.tree_panel import TreePanel

        self.commits = []
        self.panel = TreePanel(lambda *selection: self.commits.append(selection))
        self.long_text = "日本語の長い候補👩‍💻ABC" * 20
        self.long_reading = "ニホンゴノナガイコウホ" * 20
        self.snapshot = {
            "nodes": [
                {"id": 0, "text": "語", "reading": "ゴ", "parent": None, "terminals": [0]},
                {"id": 1, "text": self.long_text, "reading": self.long_reading, "parent": None, "terminals": [1]},
            ],
            "columns": [[0, 1]], "selectedPath": [0], "selection": 0, "focusedNode": 0,
            "generation": 1,
        }

    def tearDown(self):
        self.panel.destroy()
        self.flush()

    @staticmethod
    def flush():
        from gi.repository import GLib

        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def test_large_text_preserves_font_size_and_full_details_without_committing(self):
        for size, minimum in [("standard", 18), ("large", 24)]:
            self.panel.update({**self.snapshot, "candidateTextSize": size, "focusedNode": 1})
            self.flush()
            self.assertGreaterEqual(self.panel.font_size, minimum)
            self.assertIn(self.long_text, self.panel.details.displayed_text)
            self.assertIn(self.long_reading, self.panel.details.displayed_text)
            self.assertFalse(self.panel.get_accept_focus())
            self.assertEqual(self.commits, [])

    def test_small_document_columns_fall_back_to_readable_layout(self):
        self.panel.update({**self.snapshot, "wordGeometry": {"widths": [6], "fontSize": 6}})
        self.assertFalse(self.panel.aligned)
        self.assertGreaterEqual(self.panel.rectangles[0][4], self.panel.font_size + 8)

    def test_keyboard_can_scroll_all_of_a_long_candidate(self):
        self.panel.update({**self.snapshot, "focusedNode": 1})
        self.flush()
        adjustment = self.panel.details.get_vadjustment()
        self.assertGreater(adjustment.get_upper(), adjustment.get_page_size())
        self.assertTrue(self.panel.scroll_details(True))
        self.assertGreater(adjustment.get_value(), 0)
        self.assertTrue(self.panel.scroll_details(False))
        self.assertEqual(adjustment.get_value(), 0)
        self.assertEqual(self.commits, [])

    def test_changing_keyboard_target_replaces_old_reading(self):
        self.panel.update({**self.snapshot, "focusedNode": 1})
        self.panel.update(self.snapshot)
        self.assertIn("ゴ", self.panel.details.displayed_text)
        self.assertNotIn(self.long_reading, self.panel.details.displayed_text)


if __name__ == "__main__":
    unittest.main()
