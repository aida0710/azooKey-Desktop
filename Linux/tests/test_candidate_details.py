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

    def test_popup_near_right_edge_keeps_details_inside_the_work_area(self):
        monitor = self.panel.get_display().get_monitor(0)
        area = monitor.get_workarea()
        self.panel.location = (area.x + area.width - 110, area.y + 40, 1, 24)
        self.panel.update({**self.snapshot, "wordGeometry": {"widths": [80]}})
        self.flush()
        self.assertFalse(self.panel.aligned, "The detail panel must not shift aligned columns")
        description = self.panel.layout_diagnostics
        self.assertEqual(description["reason"], "outside-workarea")
        x, y, width, height = description["popup"]
        self.assertGreaterEqual(x, area.x)
        self.assertGreaterEqual(y, area.y)
        self.assertLessEqual(x + width, area.x + area.width)
        self.assertLessEqual(y + height, area.y + area.height)
        self.assertNotIn("語", str(description))
        self.assertEqual(self.commits, [])

    def test_number_targets_do_not_overlap_and_scaled_digits_fit(self):
        from gi.repository import Pango

        settings = self.panel.get_settings()
        previous_dpi = settings.get_property("gtk-xft-dpi")
        self.panel.location = (100, 100, 1, 20)
        try:
            for size, base_size in [("standard", 18), ("large", 24)]:
                for scale in [1, 1.5, 2]:
                    settings.set_property("gtk-xft-dpi", round(96 * Pango.SCALE * scale))
                    self.assert_number_geometry(size=size, column_width=base_size * scale + 8)
                    self.assert_number_geometry(size=size, column_width=base_size * scale + 14)
        finally:
            settings.set_property("gtk-xft-dpi", previous_dpi)

    def assert_number_geometry(self, *, size, column_width):
        import cairo

        self.panel.update({
            **self.snapshot, "columns": [[0], [1]], "showCandidateIndex": True,
            "candidateTextSize": size, "wordGeometry": {"widths": [column_width] * 2},
        })
        self.flush()
        numbers = [item for item in self.panel.rectangles if item[0] == "select"]
        self.assertEqual(len(numbers), 2)
        self.assertLessEqual(numbers[0][2] + numbers[0][4], numbers[1][2])
        context = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
        for _, _, _, _, width, height, number, _ in numbers:
            layout = self.panel.fitted_layout(context, number, width - 4, max(14, self.panel.font_size - 4))
            ink, logical = layout.get_pixel_extents()
            top = (height - logical.height) / 2 + ink.y
            self.assertGreaterEqual(top, 0)
            self.assertLessEqual(top + ink.height, height)

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

    def test_preview_and_annotation_follow_the_hovered_candidate_without_committing(self):
        preview = "確定予定: 日本画鑑賞\n確定する読み: にほんがかんしょう\n後続の変更: 入力 → 鑑賞\n全角英数"
        self.snapshot["nodes"][1]["previewDescription"] = preview
        self.panel.update(self.snapshot)
        self.panel.show_details(1)
        self.assertIn(preview, self.panel.details.displayed_text)
        self.assertIn(preview, self.panel.actions[("node", 1)].get_accessible().get_description())
        self.assertEqual(self.commits, [])
        self.panel.show_details(0)
        self.assertNotIn("全角英数", self.panel.details.displayed_text)

    def test_hovering_a_number_previews_its_partial_candidate_and_commits_it_once(self):
        from copy import deepcopy
        from gi.repository import Gdk

        partial = "確定予定: 日本語\n確定する読み: にほんご\n残る読み: にゅうりょく"
        full = "確定予定: 日本語入力\n確定する読み: にほんごにゅうりょく\n全文の注釈"
        snapshot = {
            "contextId": "editor", "generation": 1, "selection": 1, "focusedNode": 0,
            "columns": [[0], [1]], "selectedPath": [0, 1], "showCandidateIndex": True,
            "nodes": [
                {"id": 0, "text": "日本語", "reading": "ニホンゴ", "terminals": [0],
                 "previewDescription": full},
                {"id": 1, "text": "入力", "reading": "ニュウリョク", "terminals": [1],
                 "previewDescription": full},
            ],
            "candidatePage": {"start": 0, "position": 2, "totalCount": 2, "items": [
                {"index": 0, "text": "日本語", "reading": "ニホンゴ", "detailDescription": partial},
                {"index": 1, "text": "日本語入力", "reading": "ニホンゴニュウリョク",
                 "detailDescription": full},
            ]},
        }
        original = deepcopy(snapshot)
        self.panel.update(snapshot)
        word = self.panel.actions[("node", 0)]
        number = self.panel.actions[("select", 0)]
        entered = Gdk.Event.new(Gdk.EventType.ENTER_NOTIFY)
        word.emit("enter-notify-event", entered)
        self.assertIn(full, self.panel.details.displayed_text)
        number.emit("enter-notify-event", entered)
        self.assertIn(partial, self.panel.details.displayed_text)
        self.assertNotIn("全文の注釈", self.panel.details.displayed_text)
        self.assertIn(partial, number.get_accessible().get_description())
        word.emit("enter-notify-event", entered)
        self.assertIn(full, self.panel.details.displayed_text)
        number.emit("enter-notify-event", entered)
        self.assertEqual(snapshot, original)
        self.assertEqual(self.commits, [])
        self.assertFalse(self.panel.get_accept_focus())
        number.clicked()
        self.assertEqual(self.commits, [("select", 0, True)])


if __name__ == "__main__":
    unittest.main()
