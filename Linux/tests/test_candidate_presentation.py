"""Selection and popup lifecycle boundaries on real GTK widgets."""
import copy
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidatePresentationTests(unittest.TestCase):
    def setUp(self):
        from azookey.tree_panel import TreePanel
        from gi.repository import Gtk

        self.actions = []
        self.document = Gtk.Window()
        self.entry = Gtk.Entry()
        self.document.add(self.entry)
        self.document.show_all()
        self.entry.grab_focus()
        self.panel = TreePanel(self.choose)
        self.snapshot = self.make_snapshot()
        self.panel.update(self.snapshot)
        self.flush()

    def tearDown(self):
        self.panel.destroy()
        self.document.destroy()
        self.flush()

    @staticmethod
    def flush():
        from gi.repository import GLib

        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    @staticmethod
    def make_snapshot():
        sentences = [
            "私は日本語を勉強しています。",
            "私は日本語の文章を読みながら、候補を省略せずに最後まで確認して選びます。",
            "私",
        ]
        return {
            "contextId": "document", "generation": 1, "selection": 0, "focusedNode": 0, "inputState": "composing",
            "preedit": sentences[0], "reading": "わたしはにほんごをべんきょうしています",
            "showCandidateIndex": True, "columns": [[0, 1, 2]], "selectedPath": [0],
            "nodes": [{"id": index, "text": sentence, "reading": "ワタシ", "parent": None,
                       "terminals": [index]} for index, sentence in enumerate(sentences)],
            "candidates": [{"index": index, "text": sentence,
                            "commitScope": {"consumedReading": "わたし", "remainingReading": "はにほんごをべんきょうしています"}
                            if index == 2 else {"consumedReading": "わたしはにほんごをべんきょうしています", "remainingReading": ""}}
                           for index, sentence in enumerate(sentences)],
            "candidatePage": {"start": 0, "position": 1, "totalCount": 3,
                              "items": [{"index": index, "text": sentence, "reading": "ワタシ",
                                         "detailDescription": "候補の補足 " + sentence}
                                        for index, sentence in enumerate(sentences)]},
        }

    def choose(self, operation, index, submit):
        self.actions.append((operation, index, submit))
        if not submit:
            self.snapshot = {**self.snapshot, "selection": index, "focusedNode": index,
                             "selectedPath": [index], "generation": self.snapshot["generation"] + 1,
                             "inputState": "selecting"}
            self.snapshot["candidatePage"] = {**self.snapshot["candidatePage"], "position": index + 1}
            self.panel.update(self.snapshot)

    def test_full_sentences_are_primary_and_wrap_without_changing_focus(self):
        from gi.repository import Pango

        self.assertTrue(self.panel.navigation.expanded)
        self.assertFalse(self.panel.scroll.get_visible())
        self.assertFalse(self.panel.details.get_visible())
        self.assertEqual(self.panel.composition.displayed_text, self.snapshot["candidates"][0]["text"])
        long_label = self.panel.navigation.row_buttons[1].text_label
        self.assertEqual(long_label.get_text(), self.snapshot["candidates"][1]["text"])
        self.assertEqual(long_label.get_ellipsize(), Pango.EllipsizeMode.NONE)
        self.assertGreater(long_label.get_layout().get_line_count(), 1)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.actions, [])

    def test_unselected_composition_previews_the_candidate_without_claiming_enter_will_commit_it(self):
        self.panel.update({**self.snapshot, "preedit": self.snapshot["reading"]})
        self.assertEqual(self.panel.composition_title.get_text(), "候補のプレビュー")
        self.assertEqual(self.panel.composition.get_accessible().get_name(), "候補のプレビュー")
        self.assertEqual(self.panel.composition.displayed_text, self.snapshot["candidates"][0]["text"])
        self.assertEqual(self.panel.navigation.confirm.get_label(), "この候補を確定")
        self.assertNotIn("↵", self.panel.navigation.confirm.get_accessible().get_name())
        self.panel.navigation.confirm.clicked()
        self.assertEqual(self.actions, [("select", 0, True)])
        self.assertIs(self.document.get_focus(), self.entry)

    def test_enter_label_matches_selection_state_and_retires_previous_state_confirmation(self):
        for state in ("selecting", "previewing", "replaceSuggestion"):
            with self.subTest(state=state):
                self.panel.update({**self.snapshot, "inputState": "composing"})
                old_confirm = self.panel.navigation.confirm
                self.panel.update({**self.snapshot, "inputState": state})
                self.assertEqual(self.panel.composition_title.get_text(), "確定する文章")
                self.assertEqual(self.panel.composition.get_accessible().get_name(), "確定する文章")
                self.assertEqual(self.panel.navigation.confirm.get_label(), "確定  ↵")
                old_confirm.clicked()
                self.assertEqual(self.actions, [])
        self.panel.update({**self.snapshot, "inputState": "composing"})
        self.assertEqual(self.panel.navigation.confirm.get_label(), "この候補を確定")
        self.assertEqual(self.actions, [])

    def test_compact_rows_keep_readable_text_and_a_large_activation_area(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests

        for size, expected_font_size in (("standard", 18), ("large", 24)):
            with self.subTest(size=size):
                self.panel.update({**self.snapshot, "candidateTextSize": size})
                CandidateThemeTests.wait_for_paint(self.panel, GLib)
                self.assertEqual(self.panel.font_size, expected_font_size)
                for button in (*self.panel.navigation.row_buttons, self.panel.navigation.confirm):
                    self.assertGreaterEqual(button.get_allocation().height, 44)
                area = self.panel.get_display().get_monitor(0).get_workarea()
                width, height = self.panel.get_size()
                self.assertLessEqual(width, area.width)
                self.assertLessEqual(height, area.height)
        self.assertEqual(self.actions, [])

    def test_selection_updates_commit_preview_and_remaining_reading_before_confirming_once(self):
        self.panel.navigation.row_buttons[2].clicked()
        self.assertEqual(self.actions, [("select", 2, False)])
        self.assertEqual(self.panel.composition.displayed_text, "私")
        self.assertEqual(self.panel.remaining.displayed_text, "残る読み はにほんごをべんきょうしています")
        self.assertEqual(self.panel.composition.label.get_accessible().get_name(), "私")
        self.assertEqual(self.panel.remaining.label.get_accessible().get_name(), self.panel.remaining.displayed_text)
        self.assertTrue(self.panel.remaining.get_visible())
        self.assertFalse(self.panel.details.get_visible())
        self.assertFalse(self.panel.scroll.get_visible())
        confirm = self.panel.navigation.confirm
        confirm.clicked()
        confirm.clicked()
        self.assertEqual(self.actions, [("select", 2, False), ("select", 2, True)])
        self.assertIs(self.document.get_focus(), self.entry)

    def test_hover_changes_details_without_changing_selection_or_commit_preview(self):
        navigation = self.panel.navigation
        navigation.preview_current(self.snapshot["candidatePage"]["items"][1], navigation.row_buttons[1])
        self.assertIn(self.snapshot["candidates"][1]["text"], self.panel.details.displayed_text)
        self.assertEqual(self.panel.composition.displayed_text, self.snapshot["candidates"][0]["text"])
        self.assertTrue(navigation.row_buttons[0].selected)
        self.assertFalse(navigation.row_buttons[1].selected)
        self.assertEqual(self.actions, [])

    def test_short_candidate_page_shows_all_rows_when_the_work_area_has_room(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests

        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        adjustment = self.panel.navigation.scroll.get_vadjustment()
        self.assertEqual(adjustment.get_page_size(), adjustment.get_upper())
        self.assertEqual(len(self.panel.navigation.row_buttons), 3)

    def test_pending_at_confirm_does_not_confirm_the_next_selection_or_replaced_text(self):
        from gi.repository import GLib

        for replace_text in (False, True):
            with self.subTest(replace_text=replace_text):
                old = self.panel.navigation.confirm
                accessible = old.get_accessible()
                # Model a request still awaiting delivery, not an already
                # completed synchronous native do_action on the valid target.
                GLib.idle_add(lambda: accessible.do_action(0) and GLib.SOURCE_REMOVE)
                changed = copy.deepcopy(self.snapshot)
                if replace_text:
                    changed["candidates"][0]["text"] = "別の確定内容"
                    changed["candidatePage"]["items"][0]["text"] = "別の確定内容"
                else:
                    changed["selection"] = 1
                self.panel.update(changed)
                self.flush()
                self.assertIsNot(old, self.panel.navigation.confirm)
                self.assertEqual(self.actions, [])
                self.panel.update(self.snapshot)
                self.flush()

    def test_suspend_retires_pending_actions_and_hover_but_preserves_open_list_and_tree(self):
        from gi.repository import GLib

        self.panel.disclosure_actions["tree"].clicked()
        navigation = self.panel.navigation
        old_row = navigation.row_buttons[1]
        old_word = self.panel.actions[("node", 1)]
        old_confirm = navigation.confirm
        navigation.preview_current(self.snapshot["candidatePage"]["items"][1], old_row)
        for button in (old_row, old_word, old_confirm):
            accessible = button.get_accessible()
            GLib.idle_add(lambda accessible=accessible: accessible.do_action(0) and GLib.SOURCE_REMOVE)
        self.panel.suspend()
        self.assertFalse(self.panel.get_visible())
        self.assertTrue(navigation.expanded)
        self.assertTrue(self.panel.tree_expanded)
        self.assertIsNone(navigation.hovered_item)
        self.assertEqual(self.panel.actions, {})
        self.panel.update(self.snapshot)
        self.flush()
        self.assertTrue(navigation.scroll.get_visible())
        self.assertTrue(self.panel.scroll.get_visible())
        self.assertIsNot(old_row, navigation.row_buttons[1])
        self.assertIsNot(old_word, self.panel.actions[("node", 1)])
        self.assertEqual(self.actions, [])

    def test_closed_list_stays_closed_while_pending_but_dismiss_resets_even_when_hidden(self):
        navigation = self.panel.navigation
        navigation.toggle.clicked()
        old_confirm = navigation.confirm
        self.panel.suspend()
        self.panel.update(self.snapshot)
        self.assertFalse(navigation.expanded)
        self.panel.suspend()
        self.panel.hide()
        self.assertEqual(navigation.page, {})
        self.assertIsNone(navigation.token)
        self.panel.update(self.snapshot)
        self.flush()
        self.assertTrue(navigation.expanded)
        old_confirm.clicked()
        self.assertEqual(self.actions, [])

    def test_new_context_retires_hover_and_old_tree_actions(self):
        self.panel.disclosure_actions["tree"].clicked()
        old_word = self.panel.actions[("node", 1)]
        self.panel.hover_action(("node", 1), old_word)
        self.panel.update({**self.snapshot, "contextId": "another-document"})
        old_word.clicked()
        self.assertIsNone(self.panel.hovered_action)
        self.assertFalse(self.panel.tree_expanded)
        self.assertEqual(self.actions, [])

    def test_same_candidates_keep_a_closed_list_during_selection_and_generation_updates(self):
        self.panel.navigation.toggle.clicked()
        self.panel.update({**self.snapshot, "generation": 2, "selection": 1, "inputState": "selecting"})
        self.assertFalse(self.panel.navigation.expanded)
        self.assertFalse(self.panel.navigation.scroll.get_visible())
        self.assertEqual(self.actions, [])

    def test_a_different_document_reading_or_candidate_set_starts_with_the_list_open_and_supplements_closed(self):
        for change in ("context", "reading", "candidate"):
            with self.subTest(change=change):
                self.panel.dismiss()
                self.panel.update(self.snapshot)
                self.panel.disclosure_actions["tree"].clicked()
                self.panel.disclosure_actions["details"].clicked()
                old_word = self.panel.actions[("node", 0)]
                self.panel.navigation.toggle.clicked()
                changed = copy.deepcopy(self.snapshot)
                if change == "context":
                    changed["contextId"] = "another-document"
                elif change == "reading":
                    changed["reading"] += "つづき"
                else:
                    changed["candidates"][0]["text"] = "同じ文書の更新された候補"
                    changed["candidatePage"]["items"][0]["text"] = changed["candidates"][0]["text"]
                self.panel.update(changed)
                self.flush()
                self.assertTrue(self.panel.navigation.expanded)
                self.assertTrue(self.panel.navigation.scroll.get_visible())
                self.assertEqual(len(self.panel.navigation.row_buttons), 3)
                self.assertFalse(self.panel.tree_expanded)
                self.assertFalse(self.panel.details_expanded)
                old_word.clicked()
                self.assertEqual(self.actions, [])

    def test_page_and_scroll_survive_pending_without_restoring_old_hover(self):
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["candidatePage"]["start"] = 9
        snapshot["candidatePage"]["position"] = 10
        snapshot["candidatePage"]["totalCount"] = 18
        snapshot["candidatePage"]["items"] = [
            {"index": index, "text": "長い文章を最後まで読むための候補です。" * 4, "reading": "コウホ"}
            for index in range(9, 18)
        ]
        snapshot["selection"] = 9
        self.panel.update(snapshot)
        self.flush()
        navigation = self.panel.navigation
        adjustment = navigation.scroll.get_vadjustment()
        self.assertGreater(adjustment.get_upper(), adjustment.get_page_size())
        adjustment.set_value(60)
        self.panel.suspend()
        self.flush()
        self.panel.suspend()
        self.panel.update(snapshot)
        self.flush()
        self.assertEqual(navigation.page["start"], 9)
        self.assertEqual(adjustment.get_value(), 60)
        self.assertEqual(navigation.row_buttons[0].number_label.get_text(), "1")
        self.assertEqual(self.actions, [])

    def test_long_commit_remaining_reading_and_expanded_details_stay_in_the_work_area(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests

        snapshot = copy.deepcopy(self.snapshot)
        snapshot["candidates"][0]["text"] *= 30
        snapshot["candidates"][0]["commitScope"]["remainingReading"] = "のこりのよみ" * 100
        snapshot["nodes"][0]["reading"] *= 100
        snapshot["showRelativeScores"] = True
        self.panel.update(snapshot)
        self.panel.disclosure_actions["tree"].clicked()
        self.panel.disclosure_actions["details"].clicked()
        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        self.flush()
        area = self.panel.get_display().get_monitor(0).get_workarea()
        width, height = self.panel.get_size()
        self.assertLessEqual(width, area.width)
        self.assertLessEqual(height, area.height)
        self.assertTrue(self.panel.details.get_visible())
        self.assertTrue(self.panel.remaining.get_visible())
        for pane in (self.panel.composition, self.panel.remaining, self.panel.details):
            self.assertGreater(pane.get_vadjustment().get_upper(), pane.get_vadjustment().get_page_size())
        self.assertEqual(self.actions, [])

    def test_destroyed_panel_rejects_retained_candidate_and_confirm_actions(self):
        row = self.panel.navigation.row_buttons[1]
        confirm = self.panel.navigation.confirm
        self.panel.destroy()
        row.clicked()
        confirm.clicked()
        self.flush()
        self.assertEqual(self.actions, [])

    def test_enabled_scores_remain_available_without_opening_details_by_default(self):
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["showRelativeScores"] = True
        snapshot["nodes"][0]["scorePresentation"] = {"label": "100", "detailDescription": "相対スコア 100"}
        self.panel.update(snapshot)
        self.assertFalse(self.panel.details.get_visible())
        self.assertFalse(self.panel.scroll.get_visible())
        self.panel.disclosure_actions["details"].clicked()
        # Programmatic clicks do not move Xvfb's pointer from a candidate row
        # to the disclosure button as a real pointer click would.
        self.panel.navigation.clear_preview()
        self.assertTrue(self.panel.details.get_visible())
        self.assertIn("相対スコア 100", self.panel.details.displayed_text)
        self.panel.update({**snapshot, "showRelativeScores": False})
        self.assertNotIn("相対スコア 100", self.panel.details.displayed_text)
        self.assertEqual(self.actions, [])

    def test_keyboard_word_focus_opens_the_tree_without_confirming_the_sentence(self):
        snapshot = {**self.snapshot, "selectedPath": [0, 1], "columns": [[0], [1, 2]]}
        self.panel.update(snapshot)
        self.assertFalse(self.panel.scroll.get_visible())
        self.panel.suspend()
        self.panel.update({**snapshot, "focusedNode": 1, "generation": 2})
        self.assertTrue(self.panel.scroll.get_visible())
        self.assertIn(("node", 1), self.panel.actions)
        self.assertEqual(self.actions, [])

    def test_keyboard_candidate_selection_scrolls_the_selected_row_into_view(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests

        snapshot = copy.deepcopy(self.snapshot)
        snapshot["candidatePage"]["items"] = [
            {"index": index, "text": "候補の文章を最後まで確認します。" * 3}
            for index in range(9)
        ]
        snapshot["candidatePage"]["totalCount"] = 9
        self.panel.update(snapshot)
        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        self.panel.suspend()
        self.panel.update({**snapshot, "selection": 7, "generation": 2})
        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        self.flush()
        navigation = self.panel.navigation
        adjustment = navigation.scroll.get_vadjustment()
        frame = navigation.row_buttons[7].get_allocation()
        self.assertGreater(adjustment.get_value(), 0)
        self.assertGreaterEqual(frame.y, adjustment.get_value())
        self.assertLess(frame.y, adjustment.get_value() + adjustment.get_page_size())
        self.assertTrue(navigation.row_buttons[7].selected)
        self.assertEqual(self.actions, [])


if __name__ == "__main__":
    unittest.main()
