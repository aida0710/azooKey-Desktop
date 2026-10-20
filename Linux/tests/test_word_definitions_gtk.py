"""Read-only dictionary UI preserves live/menu layout and the document's focus."""
from pathlib import Path
import os
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from Linux.tests.test_word_definitions import dictionary
from azookey.word_definition_provider import WordDefinitionProvider, WORDNET_URL
from azookey.word_definition_lookup import WordDefinitionWorker


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
        self.commits = []
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
        self.worker.close()
        if self.worker.thread:
            self.worker.thread.join(3)
        self.flush()
        self.temporary.cleanup()

    def flush(self):
        context = self.GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

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
        self.assertIn("意味・用例", toggle.get_label())
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
        self.assertIn("保障", self.panel.definitions.summary.displayed_text)
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
                                   [("長い用例を読んでいる位置を保つ。" * 10, index) for index in range(2, 30)])
        self.panel.update(self.snapshot); self.wait_found()
        old_toggle = self.panel.definitions.toggle
        old_source_action = self.panel.definitions.source.do_activate_link
        self.panel.definitions.toggle.clicked(); self.flush()
        self.assertTrue(self.panel.definitions.expanded)
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        scroll = self.panel.definitions.details.get_vadjustment()
        scroll.set_value(30)
        reading_position = scroll.get_value()
        self.assertGreater(reading_position, 0)
        self.panel.suspend(); self.flush()
        self.assertFalse(self.panel.get_visible())
        self.assertIsNone(self.panel.definition_lookup.target)
        self.panel.update({**self.snapshot, "generation": 2}); self.wait_found()
        CandidateThemeTests.wait_for_paint(self.panel, self.GLib)
        self.assertIn("保証", self.panel.definitions.summary.displayed_text)
        self.assertEqual(scroll.get_value(), reading_position)
        self.assertTrue(self.panel.definitions.expanded)
        self.panel.definitions.toggle_details(old_toggle)
        self.assertTrue(self.panel.definitions.expanded)
        with patch("azookey.word_definition_view.Gio.AppInfo.launch_default_for_uri") as opened:
            old_source_action()
            opened.assert_not_called()
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
