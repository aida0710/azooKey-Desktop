"""Read-only dictionary UI preserves live/menu layout and the document's focus."""
from pathlib import Path
import os
import json
import sys
import tempfile
import time
import unittest
from copy import deepcopy
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Linux.tests.test_word_definitions import dictionary
from azookey.word_definition_provider import WordDefinitionProvider, WORDNET_URL
from azookey.word_definition_lookup import WordDefinitionWorker
from azookey.word_definition_layout import word_definition_columns, pointer_in_definition_corridor


class WordDefinitionColumnLayoutTests(unittest.TestCase):
    def test_narrow_width_keeps_two_readable_columns_instead_of_stacking_or_shrinking_text(self):
        for font_size in (18, 24, 48):
            wide = word_definition_columns(candidate_width=420, font_size=font_size, available_width=960)
            narrow = word_definition_columns(candidate_width=420, font_size=font_size, available_width=320)
            if font_size <= 24:
                self.assertLessEqual(wide.width, 960)
            else:
                self.assertGreater(wide.width, 960)  # Enlarged readable cards use the horizontal viewport.
            self.assertGreaterEqual(narrow.candidate_width, round(240 * font_size / 18))
            self.assertGreaterEqual(narrow.definition_width, round(280 * font_size / 18))
            self.assertGreater(narrow.width, 320)
            self.assertEqual(narrow.gap, 10)

    def test_standard_cards_are_small_and_large_text_expands_both_readable_cards(self):
        standard = word_definition_columns(candidate_width=260, font_size=18, available_width=1200)
        large = word_definition_columns(candidate_width=round(260 * 24 / 18), font_size=24, available_width=1200)
        self.assertEqual((standard.candidate_width, standard.definition_width, standard.width), (260, 280, 550))
        self.assertGreater(large.candidate_width, standard.candidate_width)
        self.assertGreater(large.definition_width, standard.definition_width)

    def test_pointer_can_cross_the_gap_and_read_the_entry_but_not_leave_into_other_regions(self):
        rectangles = {"row": (100, 200, 300, 44), "definition": (420, 160, 320, 300)}
        for pointer in ((400, 220), (410, 220), (430, 180), (700, 430)):
            self.assertTrue(pointer_in_definition_corridor(pointer=pointer, **rectangles))
        for pointer in ((250, 246), (410, 100), (740, 220), (410, 470)):
            self.assertFalse(pointer_in_definition_corridor(pointer=pointer, **rectangles))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires isolated GTK display")
class WordDefinitionGtkTests(unittest.TestCase):
    def setUp(self):
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk, GLib
        from azookey.tree_panel import TreePanel
        self.GLib = GLib
        self.temporary = tempfile.TemporaryDirectory()
        self.path = Path(self.temporary.name) / "wnjpn.db"
        dictionary(self.path)
        def dispatch(callback):
            def deliver():
                callback()
                return GLib.SOURCE_REMOVE
            GLib.idle_add(deliver)
        self.worker = WordDefinitionWorker(provider=WordDefinitionProvider(self.path), dispatch=dispatch)
        self.availability_worker = WordDefinitionWorker(provider=WordDefinitionProvider(self.path), dispatch=dispatch)
        self.addCleanup(self.availability_worker.close)
        self.commits = []
        self.availability_patch = patch("azookey.tree_panel.word_definition_availability_worker", return_value=self.availability_worker)
        self.availability_patch.start()
        self.addCleanup(self.availability_patch.stop)
        with patch("azookey.tree_panel.word_definition_worker", return_value=self.worker):
            self.panel = TreePanel(lambda *arguments: self.commits.append(arguments))
        self.document = Gtk.Window()
        self.entry = Gtk.Entry()
        self.document.add(self.entry)
        self.document.show_all()
        self.entry.grab_focus()
        words = ("保証", "保障", "補償")
        self.snapshot = {"contextId": "field", "generation": 1, "inputState": "selecting", "selection": 0,
                         "focusedNode": 0, "selectedPath": [0], "columns": [[0, 1, 2]], "showCandidateIndex": True,
                         "nodes": [{"id": index, "text": word, "reading": "ホショウ", "depth": 0,
                                    "parent": None, "terminals": [index], "preview": {"candidateIndex": index}}
                                   for index, word in enumerate(words)],
                         "candidates": [{"index": index, "text": word, "tokens": [{"text": word, "reading": "ホショウ"}]}
                                        for index, word in enumerate(words)],
                         "candidatePage": {"start": 0, "position": 1, "totalCount": 3,
                                           "items": [{"index": index, "text": word, "reading": "ホショウ"}
                                                     for index, word in enumerate(words)]}}

    def tearDown(self):
        self.panel.destroy()
        self.document.destroy()
        self.availability_worker.close()
        if self.availability_worker.thread:
            self.availability_worker.thread.join(3)
        self.worker.close()
        if self.worker.thread:
            self.worker.thread.join(3)
        self.flush()
        self.temporary.cleanup()

    def flush(self):
        context = self.GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def paint(self):
        from Linux.tests.test_candidate_theme import CandidateThemeTests
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        # A style update can schedule a measured relayout after this frame.
        self.flush()
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)

    def assert_widget_inside_popup(self, widget):
        x, y, width, height = self.panel.screen_rectangle(widget)
        popup_x, popup_y = self.panel.get_position()
        popup_width, popup_height = self.panel.get_size()
        self.assertGreaterEqual(x, popup_x)
        self.assertGreaterEqual(y, popup_y)
        self.assertLessEqual(x + width, popup_x + popup_width)
        self.assertLessEqual(y + height, popup_y + popup_height)

    def reveal_widget(self, widget):
        x, y = widget.translate_coordinates(self.panel.card, 0, 0)
        self.panel.viewport.get_hadjustment().clamp_page(x, x + widget.get_allocated_width())
        self.panel.viewport.get_vadjustment().clamp_page(y, y + widget.get_allocated_height())
        self.paint()

    def wait_found(self):
        deadline = time.monotonic() + 4
        while self.panel.definition_lookup.result.get("status") == "loading":
            self.flush()
            if time.monotonic() >= deadline:
                self.fail("Dictionary fixture did not complete")
            time.sleep(.005)
        self.flush()
        self.assertEqual(self.panel.definition_lookup.result["status"], "found")

    def test_live_tree_does_not_start_dictionary_io_or_add_a_large_panel(self):
        self.panel.update({**self.snapshot, "inputState": "composing"})
        self.flush()
        self.assertFalse(self.panel.definitions.get_visible())
        self.assertIsNone(self.worker.thread)
        self.assertTrue(self.panel.tree_expanded)
        self.assertFalse(self.panel.navigation.expanded)

    def test_missing_meaning_hides_right_card_and_reserved_width_and_can_return(self):
        self.panel.update(self.snapshot)
        self.wait_found()
        self.paint()
        found_width = self.panel.popup_content_width
        self.assertTrue(self.panel.definition_column.get_mapped())
        missing = json.loads(json.dumps(self.snapshot))
        missing["generation"] += 1
        missing["nodes"][0]["text"] = "未収録の単語"
        self.panel.update(missing)
        deadline = time.monotonic() + 4
        while self.panel.definition_lookup.result["status"] == "loading":
            self.flush()
            self.assertLess(time.monotonic(), deadline)
        self.paint()
        self.assertFalse(self.panel.definition_column.get_visible())
        self.assertFalse(self.panel.definitions.get_visible())
        self.assertEqual(self.panel.definition_width, 0)
        self.assertEqual(self.panel.card.get_spacing(), 0)
        self.assertEqual(self.panel.popup_content_width, self.panel.candidate_width)
        self.assertLess(self.panel.popup_content_width, found_width)
        self.assertEqual(self.commits, [])
        self.panel.update({**self.snapshot, "generation": 3})
        self.wait_found()
        self.paint()
        self.assertTrue(self.panel.definition_column.get_mapped())
        self.assertEqual(self.panel.popup_content_width, found_width)

    def test_only_candidates_with_meanings_show_book_icons_without_replacing_rows(self):
        snapshot = json.loads(json.dumps(self.snapshot))
        snapshot["nodes"][1]["text"] = "未収録の単語"
        snapshot["candidatePage"]["items"][1]["text"] = "未収録の単語"
        self.panel.update(snapshot)
        rows = list(self.panel.navigation.row_buttons)
        deadline = time.monotonic() + 4
        while self.panel.definition_availability.found_indices != {0, 2}:
            self.flush()
            self.assertLess(time.monotonic(), deadline)
        self.paint()
        self.assertEqual([row.definition_icon.get_visible() for row in rows], [True, False, True])
        self.assertEqual(self.panel.navigation.row_buttons, rows)
        self.assertEqual(self.snapshot["selection"], 0)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_menu_shows_real_short_meaning_without_selecting_or_committing(self):
        self.panel.update(self.snapshot)
        identity = self.panel.candidate_identity
        original_rows = list(self.panel.navigation.row_buttons)
        self.wait_found()
        self.assertIn("義務が果たされるという保証", self.panel.definitions.summary.displayed_text)
        self.assertEqual(self.panel.candidate_identity, identity)
        self.assertEqual(self.panel.navigation.row_buttons, original_rows)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertFalse(self.panel.get_accept_focus())
        self.assertEqual(self.commits, [])

    def test_dictionary_details_can_be_opened_from_the_visible_nonfocusable_action(self):
        self.panel.update(self.snapshot); self.wait_found()
        from Linux.tests.test_candidate_theme import CandidateThemeTests
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        toggle = self.panel.definitions.toggle
        self.assertTrue(toggle.get_mapped())
        self.assertIn("詳しく", toggle.get_label())
        self.assertGreaterEqual(toggle.get_allocated_height(), 44)
        self.assertEqual(self.panel.definitions.source.get_label(), "WordNet 1.1")
        self.assertEqual(self.panel.definitions.source.get_accessible().get_name(), "日本語ワードネット 1.1")
        self.assertTrue(toggle.get_child().get_mapped())
        self.assertTrue(toggle.get_accessible().do_action(0))
        self.flush()
        self.assertTrue(self.panel.definitions.expanded)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_full_details_include_real_examples_synonyms_reading_note_and_source(self):
        self.panel.update(self.snapshot); self.wait_found()
        self.panel.definitions.toggle.clicked(); self.flush()
        self.assertTrue(self.panel.definitions.expanded)
        details = self.panel.definitions.details.displayed_text
        self.assertIn("保証を求める", details)
        self.assertIn("実在類語", details)
        self.assertIn("読みの区別", details)
        self.assertIn("NICT", details)
        self.assertEqual(self.panel.definitions.source.get_uri(), WORDNET_URL)
        self.assertFalse(self.panel.definitions.toggle.get_can_focus())
        self.assertFalse(self.panel.definitions.source.get_can_focus())
        self.assertEqual(self.commits, [])

    def test_old_definition_controls_cannot_expand_a_different_word(self):
        self.panel.update(self.snapshot); self.wait_found()
        old_toggle = self.panel.definitions.toggle
        old_source_action = self.panel.definitions.source.do_activate_link
        self.panel.update({**self.snapshot, "selection": 1, "focusedNode": 1, "selectedPath": [1]})
        self.wait_found()
        self.panel.definitions.toggle_details(old_toggle); self.flush()
        self.assertFalse(self.panel.definitions.expanded)
        self.assertTrue(old_source_action())
        self.assertIn("保障", self.panel.definitions.word_heading.get_text())
        self.assertEqual(self.commits, [])

    def test_source_link_only_opens_after_the_current_visible_explicit_action(self):
        self.panel.update(self.snapshot); self.wait_found()
        current_source = self.panel.definitions.source
        old_source_action = current_source.do_activate_link
        with patch("azookey.word_definition_view.Gio.AppInfo.launch_default_for_uri") as opened:
            self.assertTrue(current_source.emit("activate-link"))
            opened.assert_called_once_with(WORDNET_URL, None)
            opened.reset_mock()
            self.panel.update({**self.snapshot, "selection": 1, "focusedNode": 1, "selectedPath": [1]})
            self.wait_found()
            self.assertTrue(old_source_action())
            self.panel.suspend()
            self.assertTrue(self.panel.definitions.source.emit("activate-link"))
            opened.assert_not_called()

    def test_suspend_keeps_dictionary_hidden_until_the_same_target_is_restored(self):
        import sqlite3
        from Linux.tests.test_candidate_theme import CandidateThemeTests
        with sqlite3.connect(self.path) as connection:
            connection.executemany("INSERT INTO synset_ex VALUES('assurance','jpn',?,?)",
                                   [(f"{index}. " + "長い用例を読んでいる位置を保つ。" * 10, index)
                                    for index in range(2, 30)])
        self.panel.update(self.snapshot); self.wait_found()
        old_toggle = self.panel.definitions.toggle
        old_source_action = self.panel.definitions.source.do_activate_link
        self.panel.definitions.toggle.clicked(); self.flush()
        self.assertTrue(self.panel.definitions.expanded)
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        scroll = self.panel.definitions.details.get_vadjustment()
        self.assertGreater(scroll.get_upper(), scroll.get_page_size())
        scroll.set_value(30)
        reading_position = scroll.get_value()
        summary_before = self.panel.definitions.summary.displayed_text
        self.assertGreater(reading_position, 0)
        self.panel.suspend(); self.flush()
        self.assertFalse(self.panel.get_visible())
        self.assertIsNone(self.panel.definition_lookup.target)
        self.panel.update({**self.snapshot, "generation": 2})
        self.assertEqual(self.panel.definitions.summary.displayed_text, summary_before)
        self.assertTrue(self.panel.definitions.source.get_visible())
        self.wait_found()
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        self.assertIn("保証", self.panel.definitions.summary.displayed_text)
        self.assertEqual(scroll.get_value(), reading_position)
        self.assertTrue(self.panel.definitions.expanded)
        self.panel.definitions.toggle_details(old_toggle)
        self.assertTrue(self.panel.definitions.expanded)
        with patch("azookey.word_definition_view.Gio.AppInfo.launch_default_for_uri") as opened:
            old_source_action()
            opened.assert_not_called()
        self.panel.update({**self.snapshot, "contextId": "different-input-field", "generation": 3})
        self.assertEqual(self.panel.definitions.response["status"], "loading")
        self.assertNotEqual(self.panel.definitions.summary.displayed_text, summary_before)
        self.wait_found()
        self.assertEqual(self.commits, [])

    def test_large_text_and_full_entry_stay_inside_the_available_screen(self):
        self.panel.update({**self.snapshot, "candidateTextSize": "large"}); self.wait_found()
        self.panel.definitions.toggle.clicked(); self.flush()
        self.assertGreaterEqual(self.panel.font_size, 24)
        area = self.panel.work_area()
        popup = self.panel.layout_diagnostics["popup"]
        self.assertGreaterEqual(popup[0], area.x)
        self.assertGreaterEqual(popup[1], area.y)
        self.assertLessEqual(popup[0] + popup[2], area.x + area.width)
        self.assertLessEqual(popup[1] + popup[3], area.y + area.height)
        self.assertEqual(self.commits, [])

    def test_dictionary_is_right_of_the_candidate_list_at_both_text_sizes_and_both_detail_states(self):
        area = self.panel.work_area()
        self.panel.location = (area.x + area.width - 24, area.y + 40, 1, 24)
        for size in ("standard", "large"):
            self.panel.update({**self.snapshot, "candidateTextSize": size}); self.wait_found()
            for expanded in (False, True):
                with self.subTest(size=size, expanded=expanded):
                    if self.panel.definitions.expanded != expanded:
                        self.panel.definitions.toggle.clicked()
                    self.paint()
                    left = self.panel.screen_rectangle(self.panel.navigation)
                    right = self.panel.screen_rectangle(self.panel.definition_column)
                    self.assertGreaterEqual(right[0], left[0] + left[2])
                    self.assertLessEqual(abs(right[1] - left[1]), 1)
                    self.assert_widget_inside_popup(self.panel.definitions.header)
                    x, y = self.panel.get_position()
                    width, height = self.panel.get_size()
                    self.assertGreaterEqual(x, area.x)
                    self.assertGreaterEqual(y, area.y)
                    self.assertLessEqual(x + width, area.x + area.width)
                    self.assertLessEqual(y + height, area.y + area.height)
                    self.assertGreaterEqual(self.panel.navigation.confirm.get_allocated_height(), 28)
                    self.assertFalse(self.panel.navigation.confirm.get_can_focus())
                    for control in (self.panel.definitions.toggle, self.panel.definitions.source):
                        self.assertGreaterEqual(control.get_allocated_height(), 44)
                        self.assertFalse(control.get_can_focus())
                    self.assertIs(self.document.get_focus(), self.entry)
                    self.assertEqual(self.commits, [])

    def test_long_word_heading_does_not_push_the_wrapped_meaning_out_of_the_summary(self):
        import sqlite3
        word = "保証という非常に長い語名" * 20
        with sqlite3.connect(self.path) as connection:
            connection.execute("UPDATE word SET lemma=? WHERE lemma='保証'", (word,))
            connection.execute("UPDATE synset_def SET def=? WHERE synset='assurance' AND lang='jpn'",
                               ("義務が果たされるという保証。詳しい語釈を読みやすく折り返す。" * 5,))
        snapshot = deepcopy(self.snapshot)
        snapshot["nodes"][0]["text"] = word
        snapshot["candidates"][0]["text"] = word
        snapshot["candidatePage"]["items"][0]["text"] = word
        self.panel.update({**snapshot, "candidateTextSize": "large"}); self.wait_found(); self.paint()
        heading = self.panel.definitions.word_heading
        summary = self.panel.definitions.summary
        self.assertEqual(heading.get_layout().get_line_count(), 1)
        self.assertTrue(heading.get_layout().is_ellipsized())
        self.assertIn("義務が果たされるという保証", summary.displayed_text)
        self.assertGreater(summary.label.get_layout().get_line_count(), 1)
        layout = summary.label.create_pango_layout("あ")
        layout.set_attributes(heading.get_attributes())
        self.assertGreaterEqual(summary.get_allocated_height(), layout.get_pixel_size()[1] * 2)
        self.assertGreaterEqual(self.panel.font_size, 24)
        self.assertEqual(self.commits, [])

    def test_system_text_scaling_keeps_header_controls_inside_the_right_column_and_confirm_visible(self):
        from gi.repository import Pango
        settings = self.panel.get_settings()
        previous_dpi = settings.get_property("gtk-xft-dpi")
        try:
            for size in ("standard", "large"):
                for scale in (1, 2):
                    with self.subTest(size=size, scale=scale):
                        settings.set_property("gtk-xft-dpi", round(96 * Pango.SCALE * scale))
                        self.panel.update({**self.snapshot, "candidateTextSize": size}); self.wait_found(); self.paint()
                        right = self.panel.screen_rectangle(self.panel.definition_column)
                        for control in (self.panel.definitions.toggle, self.panel.definitions.source):
                            x, y, width, height = self.panel.screen_rectangle(control)
                            self.assertGreaterEqual(x, right[0])
                            self.assertLessEqual(x + width, right[0] + right[2])
                            self.assertGreaterEqual(height, 44)
                            self.assertFalse(control.get_can_focus())
                        self.assert_widget_inside_popup(self.panel.navigation.confirm)
                        self.assertIs(self.document.get_focus(), self.entry)
                        self.assertEqual(self.commits, [])
        finally:
            settings.set_property("gtk-xft-dpi", previous_dpi)

    def test_narrow_viewport_scrolls_to_each_column_and_keeps_confirm_and_source_reachable(self):
        from gi.repository import Gdk
        area = self.panel.work_area()
        narrow = Gdk.Rectangle()
        narrow.x, narrow.y, narrow.width, narrow.height = area.x, area.y, 320, min(400, area.height)
        self.panel.location = (area.x + 100, area.y + 20, 1, 24)
        with patch.object(self.panel, "work_area", return_value=narrow):
            for size in ("standard", "large"):
                self.panel.update({**self.snapshot, "candidateTextSize": size}); self.wait_found()
                if not self.panel.definitions.expanded:
                    self.panel.definitions.toggle.clicked()
                self.paint()
                horizontal = self.panel.viewport.get_hadjustment()
                self.assertGreater(horizontal.get_upper(), horizontal.get_page_size())
                self.assertGreaterEqual(self.panel.candidate_width, round(240 * self.panel.font_size / 18))
                self.assertGreaterEqual(self.panel.definition_width, 280)
                horizontal.set_value(horizontal.get_upper() - horizontal.get_page_size()); self.paint()
                self.assert_widget_inside_popup(self.panel.definitions.source)
                self.reveal_widget(self.panel.navigation.confirm)
                self.assert_widget_inside_popup(self.panel.navigation.confirm)
                x, y = self.panel.get_position()
                width, height = self.panel.get_size()
                self.assertGreaterEqual(x, narrow.x)
                self.assertGreaterEqual(y, narrow.y)
                self.assertLessEqual(x + width, narrow.x + narrow.width)
                self.assertLessEqual(y + height, narrow.y + narrow.height)
                self.assertIs(self.document.get_focus(), self.entry)
            self.panel.navigation.confirm.clicked()
            self.panel.navigation.confirm.clicked()
            self.assertEqual(self.commits, [("select", 0, True)])

    def snapshot_with_candidates(self, count):
        snapshot = deepcopy(self.snapshot)
        for index in range(3, count):
            word = f"候補{index}"
            snapshot["nodes"].append({"id": index, "text": word, "reading": "コウホ", "depth": 0,
                                      "parent": None, "terminals": [index], "preview": {"candidateIndex": index}})
            snapshot["candidates"].append({"index": index, "text": word, "tokens": [{"text": word, "reading": "コウホ"}]})
        snapshot["columns"] = [[node["id"] for node in snapshot["nodes"]]]
        snapshot["candidatePage"].update({"totalCount": count, "items": [
            {"index": item["index"], "text": item["text"], "reading": item["tokens"][0]["reading"]}
            for item in snapshot["candidates"][:9]]})
        return snapshot

    def test_small_default_card_prioritizes_numbers_and_words_with_seven_compact_rows(self):
        self.panel.update(self.snapshot_with_candidates(9)); self.wait_found(); self.paint()
        navigation = self.panel.navigation
        self.assertGreaterEqual(self.panel.candidate_width, 240)
        self.assertLessEqual(self.panel.candidate_width, 280)
        for widget in (self.panel.composition_title, self.panel.composition, navigation.header,
                       navigation.hint, self.panel.disclosures):
            self.assertFalse(widget.get_visible())
        self.assertTrue(navigation.confirm.get_mapped())
        self.assertTrue(self.panel.disclosure_actions["options"].get_mapped())
        self.assertEqual(navigation.row_buttons[0].number_label.get_text(), "1")
        self.assertEqual(navigation.row_buttons[0].text_label.get_text(), "保証")
        self.assertEqual(navigation.row_buttons[0].selection_label.get_text(), "✓")
        first_seven = navigation.row_buttons[:7]
        first_eight = navigation.row_buttons[:8]
        seven_rows_height = sum(row.get_allocated_height() for row in first_seven) + 6 * navigation.rows.get_spacing()
        eight_rows_height = sum(row.get_allocated_height() for row in first_eight) + 7 * navigation.rows.get_spacing()
        self.assertGreaterEqual(navigation.scroll.get_allocated_height(), seven_rows_height)
        self.assertLess(navigation.scroll.get_allocated_height(), eight_rows_height)
        for row in navigation.row_buttons:
            self.assertGreaterEqual(row.get_allocated_height(), 32)
            self.assertLessEqual(row.get_allocated_height(), 40)
        self.assertGreater(navigation.scroll.get_vadjustment().get_upper(),
                           navigation.scroll.get_vadjustment().get_page_size())
        self.assertFalse(navigation.previous.get_mapped())
        self.assertFalse(navigation.next.get_mapped())
        self.assertEqual(self.commits, [])

    def test_visible_row_choices_change_the_viewport_without_replacing_or_renumbering_candidates(self):
        snapshot = self.snapshot_with_candidates(9)
        original_rows = None
        for count in (5, 7, 9):
            with self.subTest(count=count):
                self.panel.update({**snapshot, "candidateVisibleRows": count}); self.wait_found(); self.paint()
                navigation = self.panel.navigation
                if original_rows is None:
                    original_rows = tuple(navigation.row_buttons)
                self.assertEqual(tuple(navigation.row_buttons), original_rows)
                self.assertEqual([row.number_label.get_text() for row in original_rows], list(map(str, range(1, 10))))
                self.assertEqual([row.text_label.get_text() for row in original_rows],
                                 [item["text"] for item in snapshot["candidatePage"]["items"]])
                first_rows = original_rows[:count]
                rows_height = sum(row.get_allocated_height() for row in first_rows) + (count - 1) * navigation.rows.get_spacing()
                self.assertGreaterEqual(navigation.scroll.get_allocated_height(), rows_height)
                if count < 9:
                    next_height = rows_height + navigation.rows.get_spacing() + original_rows[count].get_allocated_height()
                    self.assertLess(navigation.scroll.get_allocated_height(), next_height)
                else:
                    adjustment = navigation.scroll.get_vadjustment()
                    self.assertEqual(adjustment.get_upper(), adjustment.get_page_size())
                self.assertEqual(self.panel.font_size, 18)
                self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_a_smaller_viewport_reveals_the_selected_ninth_candidate_and_invalid_values_use_seven(self):
        snapshot = self.snapshot_with_candidates(9)
        snapshot.update({"selection": 8, "focusedNode": 8, "selectedPath": [8], "candidateVisibleRows": 9})
        self.panel.update(snapshot); self.paint()
        navigation = self.panel.navigation
        original_rows = tuple(navigation.row_buttons)
        for count, expected in ((5, 5), (True, 7)):
            with self.subTest(count=count):
                self.panel.update({**snapshot, "candidateVisibleRows": count}); self.paint()
                self.assertEqual(navigation.visible_rows, expected)
                self.assertEqual(tuple(navigation.row_buttons), original_rows)
                self.assertTrue(original_rows[8].selected)
                adjustment = navigation.scroll.get_vadjustment()
                _x, y = original_rows[8].translate_coordinates(navigation.rows, 0, 0)
                self.assertGreaterEqual(y, adjustment.get_value())
                self.assertLessEqual(y + original_rows[8].get_allocated_height(),
                                     adjustment.get_value() + adjustment.get_page_size())
                self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_shrinking_before_the_next_allocation_still_reveals_the_selected_last_candidate(self):
        snapshot = self.snapshot_with_candidates(9)
        snapshot.update({"selection": 8, "focusedNode": 8, "selectedPath": [8], "candidateVisibleRows": 9})
        self.panel.update(snapshot); self.paint()
        navigation = self.panel.navigation
        adjustment = navigation.scroll.get_vadjustment()
        previous_height = adjustment.get_page_size()
        pending_reveals = []
        original_idle_add = self.GLib.idle_add

        def capture_reveal(callback, *arguments, **keywords):
            if callback.__name__ == "position_list":
                pending_reveals.append(callback)
                return 0
            return original_idle_add(callback, *arguments, **keywords)

        with patch("azookey.candidate_navigation.GLib.idle_add", side_effect=capture_reveal):
            self.panel.update({**snapshot, "candidateVisibleRows": 5})
        self.assertEqual(len(pending_reveals), 1)
        self.assertEqual(adjustment.get_page_size(), previous_height)
        self.assertGreater(previous_height, navigation.list_height_limit)
        pending_reveals[0]()
        self.paint()
        last = navigation.row_buttons[8]
        _x, y = last.translate_coordinates(navigation.rows, 0, 0)
        self.assertLessEqual(y + last.get_allocated_height(),
                             adjustment.get_value() + adjustment.get_page_size())
        self.assertTrue(last.selected)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_visible_row_preference_does_not_resize_the_live_branch_tree(self):
        snapshot = {**self.snapshot_with_candidates(9), "inputState": "composing"}
        self.panel.update(snapshot); self.paint()
        rectangles = list(self.panel.rectangles)
        size = self.panel.get_size()
        for count in (5, 9):
            self.panel.update({**snapshot, "candidateVisibleRows": count}); self.paint()
            self.assertEqual(self.panel.rectangles, rectangles)
            self.assertEqual(self.panel.get_size(), size)
            self.assertTrue(all(frame[5] >= 44 for frame in self.panel.rectangles))
            self.assertIsNone(self.worker.thread)
        self.assertEqual(self.commits, [])

    def test_opening_full_explanation_changes_only_the_independent_right_card(self):
        import sqlite3
        with sqlite3.connect(self.path) as connection:
            connection.execute("UPDATE synset_def SET def=? WHERE synset='assurance' AND lang='jpn'",
                               ("義務が果たされるという保証。" * 200,))
        self.panel.update(self.snapshot); self.wait_found(); self.paint()
        left_before = (self.panel.content.get_allocated_width(), self.panel.content.get_allocated_height(),
                       self.panel.navigation.scroll.get_allocated_height())
        rows_before = tuple(self.panel.navigation.row_buttons)
        self.assertEqual(self.panel.definitions.word_heading.get_text(), "保証")
        self.panel.definitions.toggle.clicked(); self.paint()
        self.assertTrue(self.panel.definitions.expanded)
        self.assertEqual(left_before, (self.panel.content.get_allocated_width(), self.panel.content.get_allocated_height(),
                                       self.panel.navigation.scroll.get_allocated_height()))
        self.assertEqual(tuple(self.panel.navigation.row_buttons), rows_before)
        self.assertGreaterEqual(self.panel.definition_column.get_allocated_height(), 280)
        self.assertLessEqual(self.panel.definition_column.get_allocated_height(), 340)
        scroll = self.panel.definitions.details.get_vadjustment()
        self.assertGreater(scroll.get_upper(), scroll.get_page_size())
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_footer_keeps_paging_confirmation_and_optional_word_controls_separate_from_selection(self):
        from gi.repository import Gtk

        snapshot = self.snapshot_with_candidates(18)
        snapshot["candidatePage"].update({"previousIndex": None, "nextIndex": 9})
        self.panel.update(snapshot); self.wait_found(); self.paint()
        navigation = self.panel.navigation
        old_next = navigation.next
        old_confirm = navigation.confirm
        old_options = self.panel.disclosure_actions["options"]
        for control in (navigation.next, navigation.confirm, old_options):
            self.assertIs(control.get_parent(), navigation.footer)
            self.assertGreaterEqual(control.get_allocated_height(), 28)
            self.assertLessEqual(control.get_allocated_height(), 36)
            style = control.get_style_context()
            border = style.get_border(Gtk.StateFlags.NORMAL)
            self.assertEqual((border.top, border.bottom, border.left, border.right), (0, 0, 0, 0))
            self.assertEqual(style.get_background_color(Gtk.StateFlags.NORMAL).alpha, 0)
            self.assertFalse(control.get_can_focus())
            self.assert_widget_inside_popup(control)
        self.assertEqual(navigation.next.get_accessible().get_name(), "次へ")
        navigation.next.clicked()
        self.assertEqual(self.commits, [("select", 9, False)])
        old_options.clicked(); self.paint()
        self.assertTrue(self.panel.disclosures.get_visible())
        self.assertFalse(self.panel.scroll.get_visible())
        self.assertFalse(self.panel.details.get_visible())
        old_tree = self.panel.disclosure_actions["tree"]
        old_options.clicked(); self.paint()
        old_tree.clicked()
        self.assertFalse(self.panel.tree_expanded)
        self.assertFalse(self.panel.disclosures.get_visible())
        self.panel.update({**snapshot, "contextId": "another-field", "generation": 2}); self.paint()
        old_next.clicked(); old_confirm.clicked(); old_options.clicked()
        self.assertEqual(self.commits, [("select", 9, False)])
        self.assertFalse(self.panel.options_expanded)
        self.assertFalse(self.panel.disclosures.get_visible())
        navigation.confirm.clicked(); navigation.confirm.clicked()
        self.assertEqual(self.commits, [("select", 9, False), ("select", 0, True)])
        self.assertIs(self.document.get_focus(), self.entry)

    def test_flat_footer_hover_stays_readable_on_each_actual_gtk_palette(self):
        from gi.repository import Gtk
        from azookey.candidate_palette_data import PALETTES
        from Linux.tests.test_candidate_theme import contrast

        snapshot = self.snapshot_with_candidates(18)
        snapshot["candidatePage"].update({"previousIndex": None, "nextIndex": 9})
        self.panel.update(snapshot); self.wait_found(); self.paint()
        controls = (self.panel.navigation.next, self.panel.navigation.confirm,
                    self.panel.disclosure_actions["options"])
        for mode, palette in PALETTES.items():
            self.panel.navigation.apply_palette(palette)
            self.paint()
            for control in controls:
                with self.subTest(mode=mode, control=control.get_label()):
                    style = control.get_style_context()
                    foreground = style.get_color(Gtk.StateFlags.PRELIGHT)
                    color = "#" + "".join(f"{round(channel * 255):02X}" for channel in
                                           (foreground.red, foreground.green, foreground.blue))
                    self.assertEqual(foreground.alpha, 1)
                    self.assertGreaterEqual(contrast(color, palette["background"]), 4.5)
                    self.assertEqual(style.get_background_color(Gtk.StateFlags.PRELIGHT).alpha, 0)
                    border = style.get_border(Gtk.StateFlags.PRELIGHT)
                    self.assertEqual((border.top, border.bottom, border.left, border.right), (0, 0, 0, 0))
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_optional_metadata_exposes_full_commit_text_without_restoring_default_clutter(self):
        self.panel.update(self.snapshot); self.wait_found(); self.paint()
        self.panel.disclosure_actions["options"].clicked()
        self.panel.disclosure_actions["details"].clicked(); self.paint()
        self.assertTrue(self.panel.composition.get_visible())
        self.assertEqual(self.panel.composition.displayed_text, self.snapshot["candidates"][0]["text"])
        self.assertTrue(self.panel.details.get_visible())
        self.panel.disclosure_actions["details"].clicked(); self.paint()
        self.assertFalse(self.panel.composition.get_visible())
        self.assertFalse(self.panel.details.get_visible())
        self.assertFalse(self.panel.navigation.hint.get_visible())
        self.assertEqual(self.commits, [])

    def test_gap_and_space_below_the_short_card_leave_the_common_parent_transparent(self):
        import cairo
        from gi.repository import Gtk
        self.panel.update(self.snapshot_with_candidates(9)); self.wait_found(); self.paint()
        left_x, left_y = self.panel.content.translate_coordinates(self.panel, 0, 0)
        right_x, right_y = self.panel.definition_column.translate_coordinates(self.panel, 0, 0)
        left_right = left_x + self.panel.content.get_allocated_width()
        left_bottom = left_y + self.panel.content.get_allocated_height()
        right_bottom = right_y + self.panel.definition_column.get_allocated_height()
        self.assertGreater(right_x, left_right)
        self.assertGreater(left_bottom, right_bottom)
        width, height = self.panel.get_size()
        surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
        context = cairo.Context(surface)
        context.set_source_rgba(1, 0, 0, 1)
        context.paint()  # A redraw must clear an existing opaque backing pixel too.
        Gtk.Widget.draw(self.panel, context)
        surface.flush()
        pixels = surface.get_data()
        gap = ((left_right + right_x) // 2, max(left_y, right_y) + 8)
        below = (right_x + self.panel.definition_column.get_allocated_width() // 2,
                 (right_bottom + left_bottom) // 2)
        for x, y in (gap, below):
            pixel = bytes(pixels[y * surface.get_stride() + x * 4:y * surface.get_stride() + x * 4 + 4])
            self.assertEqual(int.from_bytes(pixel, sys.byteorder) >> 24, 0, (x, y))
        row = self.panel.navigation.row_buttons[0]
        row_x, row_y = row.translate_coordinates(self.panel, row.get_allocated_width() // 2,
                                                 row.get_allocated_height() // 2)
        offset = row_y * surface.get_stride() + row_x * 4
        self.assertEqual(int.from_bytes(bytes(pixels[offset:offset + 4]), sys.byteorder) >> 24, 255)
        self.assertTrue(self.panel.get_app_paintable())

    def enter_definition_from_alternative(self):
        from gi.repository import Gdk
        self.panel.update(self.snapshot); self.wait_found(); self.paint()
        row = self.panel.navigation.row_buttons[1]
        row.emit("enter-notify-event", Gdk.Event.new(Gdk.EventType.ENTER_NOTIFY))
        self.wait_found(); self.paint()
        x, y, width, height = self.panel.screen_rectangle(row)
        right = self.panel.screen_rectangle(self.panel.definition_column)
        event = Gdk.Event.new(Gdk.EventType.LEAVE_NOTIFY)
        event.x_root = (x + width + right[0]) / 2
        event.y_root = y + height / 2
        row.emit("leave-notify-event", event)
        self.assertTrue(self.panel.definition_pointer_active)
        return right

    def test_pointer_crossing_the_real_gap_and_reading_the_right_column_preserves_the_word_until_exit(self):
        from gi.repository import Gdk
        right = self.enter_definition_from_alternative()
        motion = Gdk.Event.new(Gdk.EventType.MOTION_NOTIFY)
        motion.x_root, motion.y_root = right[0] + 20, right[1] + 20
        self.panel.definition_column.emit("motion-notify-event", motion)
        self.wait_found()
        self.assertEqual(self.panel.definition_lookup.result["word"], "保障")
        self.assertEqual(self.panel.snapshot["selection"], 0)
        left = Gdk.Event.new(Gdk.EventType.LEAVE_NOTIFY)
        popup_x, popup_y = self.panel.get_position()
        popup_width, _ = self.panel.get_size()
        left.x_root, left.y_root = popup_x + popup_width + 1, popup_y + 20
        self.panel.emit("leave-notify-event", left)
        self.wait_found()
        self.assertEqual(self.panel.definition_lookup.result["word"], "保証")
        self.assertFalse(self.panel.definition_pointer_active)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertEqual(self.commits, [])

    def test_retained_dictionary_preview_is_retired_by_generation_word_context_changes_and_suspend(self):
        for update in ({"generation": 2}, {"focusedNode": 2, "selectedPath": [2]}, {"contextId": "other"}):
            with self.subTest(update=update):
                self.enter_definition_from_alternative()
                self.panel.update({**self.snapshot, **update}); self.wait_found()
                self.assertFalse(self.panel.definition_pointer_active)
                self.assertIsNone(self.panel.navigation.hovered_item)
        self.enter_definition_from_alternative()
        self.panel.suspend(); self.flush()
        self.assertFalse(self.panel.definition_pointer_active)
        self.assertIsNone(self.panel.navigation.hovered_item)
        self.assertFalse(self.panel.get_visible())
        self.assertEqual(self.commits, [])

    @unittest.skipUnless(os.environ.get("AZOOKEY_WORDNET_TEST_DB"), "requires fixed official WordNet")
    def test_official_dictionary_definition_is_rendered_by_the_actual_widget(self):
        self.worker.provider = WordDefinitionProvider(os.environ["AZOOKEY_WORDNET_TEST_DB"])
        self.panel.update(self.snapshot); self.wait_found()
        response = self.panel.definition_lookup.result
        first = response["senses"][0]["definitions"][0]
        self.assertIn(first[:96], self.panel.definitions.summary.displayed_text)
        self.panel.definitions.toggle.clicked(); self.flush()
        self.assertIn(first, self.panel.definitions.details.displayed_text)
        if output := os.environ.get("AZOOKEY_WORD_DEFINITION_IMAGE_DIR"):
            from gi.repository import Gdk
            from Linux.tests.test_candidate_theme import CandidateThemeTests
            CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
            width, height = self.panel.get_size()
            image = Gdk.pixbuf_get_from_window(self.panel.get_window(), 0, 0, width, height)
            Path(output).mkdir(parents=True, exist_ok=True)
            image.savev(str(Path(output) / "wordnet-guarantee-gtk.png"), "png", [], [])
        self.assertEqual(self.commits, [])


if __name__ == "__main__":
    unittest.main()
