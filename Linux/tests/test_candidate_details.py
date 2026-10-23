"""Readable candidate details stay reachable without committing or focusing."""

import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateDetailTests(unittest.TestCase):
    def setUp(self):
        from candidate_core import core_tree_panel

        self.commits = []
        self.panel = core_tree_panel(lambda *selection: self.commits.append(selection))
        self.long_text = "日本語の長い候補👩‍💻ABC" * 20
        self.long_reading = "ニホンゴノナガイコウホ" * 20
        self.snapshot = {
            "nodes": [
                {"id": 0, "text": "語", "reading": "ゴ", "parent": None, "terminals": [0]},
                {"id": 1, "text": self.long_text, "reading": self.long_reading, "parent": None, "terminals": [1]},
            ],
            "columns": [[0, 1]], "selectedPath": [0], "selection": 0, "focusedNode": 0,
            "generation": 1, "inputState": "selecting",
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
        for size, minimum in [("standard", 14), ("large", 18)]:
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

    def test_words_fit_inside_nodes_without_number_badges_at_the_configured_text_scales(self):
        from gi.repository import Pango

        settings = self.panel.get_settings()
        previous_dpi = settings.get_property("gtk-xft-dpi")
        self.panel.location = (100, 100, 1, 20)
        try:
            for size, base_size in [("standard", 14), ("large", 18)]:
                for scale in [1, 1.5, 2]:
                    settings.set_property("gtk-xft-dpi", round(96 * Pango.SCALE * scale))
                    self.assert_word_geometry(size=size, column_width=base_size * scale + 8)
                    self.assert_word_geometry(size=size, column_width=base_size * scale + 14)
        finally:
            settings.set_property("gtk-xft-dpi", previous_dpi)

    def assert_word_geometry(self, *, size, column_width):
        import cairo

        self.panel.update({
            **self.snapshot, "nodes": [{**node, "preview": {"candidateIndex": node["id"]}}
                                       for node in self.snapshot["nodes"]],
            "columns": [[0], [1]], "showCandidateIndex": True,
            "candidateTextSize": size, "wordGeometry": {"widths": [column_width] * 2},
        })
        self.flush()
        words = [item for item in self.panel.rectangles if item[0] == "node"]
        self.assertFalse(any(item[0] == "select" for item in self.panel.rectangles))
        self.assertLessEqual(words[0][2] + words[0][4], words[1][2])
        context = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 1, 1))
        tree = self.panel.layout["tree"]
        texts = {node["id"]: node["text"] for node in self.snapshot["nodes"]}
        for node in tree["nodes"]:
            frame, text_frame = node["frame"], node["textFrame"]
            self.assertNotIn("numberFrame", node)
            self.assertGreaterEqual(frame["width"], 24)
            self.assertGreaterEqual(frame["height"], 24)
            layout = self.panel.fitted_layout(context, texts[node["id"]], text_frame["width"], tree["metrics"]["fontSize"])
            ink, logical = layout.get_pixel_extents()
            top = text_frame["y"] - frame["y"] + (text_frame["height"] - logical.height) / 2 + ink.y
            self.assertGreaterEqual(top, 0)
            self.assertLessEqual(top + ink.height, frame["height"])

    def test_keyboard_can_scroll_all_of_a_long_candidate(self):
        self.panel.update({**self.snapshot, "focusedNode": 1})
        self.panel.disclosure_actions["details"].clicked()
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
        self.panel.disclosure_actions["tree"].clicked()
        self.panel.show_details(1)
        self.assertIn(preview, self.panel.details.displayed_text)
        self.assertIn(preview, self.panel.actions[("node", 1)].get_accessible().get_description())
        self.assertEqual(self.commits, [])
        self.panel.show_details(0)
        self.assertNotIn("全角英数", self.panel.details.displayed_text)

    @staticmethod
    def shared_word_snapshot(selection=1):
        partial = "確定予定: 日本語\n確定する読み: にほんご\n残る読み: にゅうりょく"
        full = "確定予定: 日本語入力\n確定する読み: にほんごにゅうりょく\n全文の注釈"
        alternative = full.replace("全文の注釈", "別の全文注釈")
        return {
            "contextId": "editor", "generation": selection, "selection": selection, "focusedNode": 0,
            "inputState": "selecting",
            "columns": [[0], [1]], "selectedPath": [0, 1], "showCandidateIndex": True,
            "nodes": [
                {"id": 0, "text": "日本語", "reading": "ニホンゴ", "terminals": [0],
                 "preview": {"candidateIndex": selection},
                 "previewDescription": full if selection == 1 else alternative},
                {"id": 1, "text": "入力", "reading": "ニュウリョク", "terminals": [1, 2],
                 "preview": {"candidateIndex": selection},
                 "previewDescription": full if selection == 1 else alternative},
            ],
            "candidatePage": {"start": 0, "position": selection + 1, "totalCount": 3, "items": [
                {"index": 0, "text": "日本語", "reading": "ニホンゴ", "detailDescription": partial},
                {"index": 1, "text": "日本語入力", "reading": "ニホンゴニュウリョク",
                 "detailDescription": full},
                {"index": 2, "text": "日本語入力", "reading": "ニホンゴニュウリョク",
                 "detailDescription": alternative},
            ]},
        }

    def test_node_badge_keeps_node_preview_while_the_sentence_list_exposes_the_partial_candidate(self):
        from copy import deepcopy
        from gi.repository import Gdk

        snapshot = self.shared_word_snapshot()
        partial, full = [item["detailDescription"] for item in snapshot["candidatePage"]["items"][:2]]
        original = deepcopy(snapshot)
        self.panel.update(snapshot)
        self.panel.disclosure_actions["tree"].clicked()
        word = self.panel.actions[("node", 0)]
        partial_row = self.panel.navigation.row_buttons[0]
        self.assertNotIn(("select", 0), self.panel.actions)
        entered = Gdk.Event.new(Gdk.EventType.ENTER_NOTIFY)
        word.emit("enter-notify-event", entered)
        self.assertIn(full, self.panel.details.displayed_text)
        partial_row.emit("enter-notify-event", entered)
        self.assertIn(partial, self.panel.details.displayed_text)
        self.assertNotIn("全文の注釈", self.panel.details.displayed_text)
        self.assertIn(partial, partial_row.get_accessible().get_description())
        partial_row.emit("leave-notify-event", Gdk.Event.new(Gdk.EventType.LEAVE_NOTIFY))
        word.emit("enter-notify-event", entered)
        self.assertIn(full, self.panel.details.displayed_text)
        partial_row.emit("enter-notify-event", entered)
        self.assertEqual(snapshot, original)
        self.assertEqual(self.commits, [])
        self.assertFalse(self.panel.get_accept_focus())
        partial_row.clicked()
        self.assertEqual(self.commits, [("select", 0, False)])
        self.panel.update({**snapshot, "selection": 0})
        self.panel.navigation.confirm.clicked()
        self.assertEqual(self.commits, [("select", 0, False), ("select", 0, True)])

    def test_stationary_hover_stays_on_its_target_after_keyboard_updates_and_leave_restores_selection(self):
        from gi.repository import Gdk

        entered = Gdk.Event.new(Gdk.EventType.ENTER_NOTIFY)
        left = Gdk.Event.new(Gdk.EventType.LEAVE_NOTIFY)
        for kind in ("node", "list"):
            with self.subTest(kind=kind):
                original = self.shared_word_snapshot()
                self.panel.update(original)
                self.panel.navigation.expanded = True
                self.panel.tree_expanded = True
                self.panel.update(original)
                target = (self.panel.navigation.row_buttons[0] if kind == "list"
                          else self.panel.actions[(kind, 0)])
                target.emit("enter-notify-event", entered)
                for selection in (2, 1):
                    updated = self.shared_word_snapshot(selection)
                    self.panel.update(updated)
                    current = (self.panel.navigation.row_buttons[0] if kind == "list"
                               else self.panel.actions[(kind, 0)])
                    self.assertIs(current, target, "The pointer did not enter a different control")
                    expected = (updated["nodes"][0]["previewDescription"] if kind == "node"
                                else updated["candidatePage"]["items"][0]["detailDescription"])
                    self.assertIn(expected, self.panel.details.displayed_text)
                target.emit("leave-notify-event", left)
                self.assertIn(original["nodes"][0]["previewDescription"], self.panel.details.displayed_text)
                self.assertNotIn("残る読み", self.panel.details.displayed_text)
                self.assertEqual(self.commits, [])
                self.assertFalse(self.panel.get_accept_focus())

    def test_replacing_the_context_retires_the_hover_target_and_collapsing_the_list_restores_selection(self):
        from gi.repository import Gdk

        entered = Gdk.Event.new(Gdk.EventType.ENTER_NOTIFY)
        for kind in ("node", "list"):
            with self.subTest(kind=kind):
                self.panel.update(self.shared_word_snapshot())
                self.panel.navigation.expanded = True
                self.panel.tree_expanded = True
                self.panel.update(self.shared_word_snapshot())
                target = (self.panel.navigation.row_buttons[0] if kind == "list"
                          else self.panel.actions[(kind, 0)])
                target.emit("enter-notify-event", entered)
                updated = {**self.shared_word_snapshot(2), "contextId": "another-editor"}
                self.panel.update(updated)
                self.assertIn("別の全文注釈", self.panel.details.displayed_text)
                target.emit("enter-notify-event", entered)
                self.assertIn("別の全文注釈", self.panel.details.displayed_text)
                self.panel.navigation.expanded = True
                self.panel.update(updated)
                self.panel.navigation.row_buttons[0].emit("enter-notify-event", entered)
                self.assertIn("残る読み", self.panel.details.displayed_text)
                self.panel.navigation.collapse()
                self.assertIn("別の全文注釈", self.panel.details.displayed_text)
                self.assertEqual(self.commits, [])


if __name__ == "__main__":
    unittest.main()
