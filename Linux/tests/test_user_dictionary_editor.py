"""Exercise real GTK dictionary widgets using synthetic callbacks under Xvfb."""

import copy
import os
import pathlib
import sys
import threading
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_model import DictionarySaveError, DictionaryValidationIssue
from test_user_dictionary_model import ENTRY_ID, original_entries


# Bound missing-callback failures without adding sleeps to production behavior.
CALLBACK_DEADLINE_SECONDS = 5


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class UserDictionaryEditorTests(unittest.TestCase):
    def setUp(self):
        from gi.repository import GLib
        from azookey.user_dictionary_editor import UserDictionaryEditor

        self.GLib = GLib
        self.editor_type = UserDictionaryEditor
        self.source = original_entries()
        self.saved = []
        self.windows = []

    def tearDown(self):
        for window in self.windows:
            window.destroy()
        self.flush()

    def create_editor(self, **callbacks):
        callbacks.setdefault("validate", lambda _entries: ())
        callbacks.setdefault("save", self.saved.append)
        editor = self.editor_type(self.source, **callbacks)
        editor.show_all()
        self.windows.append(editor)
        self.flush()
        return editor

    def flush(self):
        context = self.GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def wait_for(self, predicate):
        context = self.GLib.MainContext.default()
        expired = threading.Event()
        deadline = self.GLib.timeout_add(
            int(CALLBACK_DEADLINE_SECONDS * 1000), lambda: expired.set() or self.GLib.SOURCE_REMOVE,
        )
        try:
            while not predicate() and not expired.is_set():
                context.iteration(True)
            self.assertTrue(predicate(), "GTK callback did not complete")
        finally:
            if not expired.is_set():
                self.GLib.source_remove(deadline)

    def test_add_then_cancel_or_close_never_persists_an_empty_entry(self):
        for close in ("cancel", "close"):
            with self.subTest(close=close):
                editor = self.create_editor()
                editor.add_button.clicked()
                self.assertEqual(len(editor.model.entries), 2)
                if close == "cancel":
                    editor.cancel_button.clicked()
                else:
                    editor.close()
                    self.flush()
                self.assertTrue(editor.closed)
                self.assertEqual(editor.model.entries, original_entries())
                self.assertEqual(self.source, original_entries())
                self.assertEqual(self.saved, [])

    def test_cancel_restores_existing_edits_and_deletions(self):
        editor = self.create_editor()
        editor.fields["word"].set_text("編集だけ")
        editor.remove_button.clicked()
        editor.cancel_button.clicked()
        self.assertEqual(editor.model.entries, original_entries())
        self.assertEqual(self.source, original_entries())
        self.assertEqual(self.saved, [])

    def test_validation_displays_row_and_reason_and_preserves_the_draft(self):
        def validate(entries):
            return [
                DictionaryValidationIssue(entries[-1]["id"], "word", "empty"),
                DictionaryValidationIssue(entries[-1]["id"], "reading", "unsupportedCharacter", "A"),
            ]

        editor = self.create_editor(validate=validate)
        editor.add_button.clicked()
        editor.fields["reading"].set_text("A")
        editor.save_button.clicked()
        self.wait_for(lambda: not editor.model.is_saving)
        self.assertIn("2行目の単語", editor.issue_label.get_text())
        self.assertIn("単語を入力", editor.issue_label.get_text())
        self.assertIn("読みに対応していない文字", editor.issue_label.get_text())
        self.assertEqual(editor.fields["reading"].get_text(), "A")
        self.assertEqual(len(editor.model.entries), 2)
        self.assertEqual(self.saved, [])

    def test_slow_save_keeps_gtk_responsive_and_rejects_duplicate_edits_and_close(self):
        entered = threading.Event()
        release = threading.Event()
        callback_threads = []
        notifications = []
        ui_thread = threading.get_ident()

        def save(entries):
            callback_threads.append(threading.get_ident())
            entered.set()
            if not release.wait(CALLBACK_DEADLINE_SECONDS):
                raise RuntimeError("test_gate_timeout")
            self.saved.append(copy.deepcopy(entries))

        def notify(entries):
            notifications.append((threading.get_ident(), entries))

        editor = self.create_editor(save=save, on_saved=notify)
        editor.fields["word"].set_text("保存する語")
        editor.save_button.clicked()
        try:
            self.assertTrue(entered.wait(CALLBACK_DEADLINE_SECONDS))
            heartbeat = []
            self.GLib.idle_add(lambda: heartbeat.append(True) and self.GLib.SOURCE_REMOVE)
            self.flush()
            self.assertEqual(heartbeat, [True])
            self.assertFalse(editor.save_button.get_sensitive())
            self.assertFalse(editor.form.get_sensitive())
            editor.save_button.clicked()
            editor.add_button.clicked()
            editor.close()
            self.flush()
            self.assertFalse(editor.closed)
            self.assertEqual(len(editor.model.entries), 1)
        finally:
            release.set()
        self.wait_for(lambda: editor.closed)
        self.assertEqual(len(self.saved), 1)
        self.assertNotEqual(callback_threads[0], ui_thread)
        self.assertEqual(notifications, [(ui_thread, self.saved[0])])
        self.assertEqual(self.source, original_entries())

    def test_failed_save_shows_safe_reason_and_retry_uses_same_ids(self):
        attempts = []

        def save(entries):
            attempts.append(copy.deepcopy(entries))
            if len(attempts) == 1:
                raise DictionarySaveError("persistence")
            self.saved.append(entries)

        editor = self.create_editor(save=save)
        editor.fields["word"].set_text("再試行する語")
        editor.save_button.clicked()
        self.wait_for(lambda: not editor.model.is_saving)
        self.assertIn("保存先を確認", editor.status_label.get_text())
        self.assertEqual(editor.fields["word"].get_text(), "再試行する語")
        self.assertTrue(editor.save_button.get_sensitive())
        editor.save_button.clicked()
        self.wait_for(lambda: editor.closed)
        self.assertEqual(attempts[0], attempts[1])
        self.assertEqual(self.saved[0][0]["id"], ENTRY_ID)

    def test_unknown_error_does_not_display_exception_contents(self):
        def save(_entries):
            raise OSError("PRIVATE_TEST_SENTINEL")

        editor = self.create_editor(save=save)
        editor.save_button.clicked()
        self.wait_for(lambda: not editor.model.is_saving)
        self.assertNotIn("PRIVATE_TEST_SENTINEL", editor.status_label.get_text())
        self.assertIn("保存を確認できません", editor.status_label.get_text())

    def test_rollback_failure_keeps_the_warning_and_blocks_further_saves(self):
        calls = []

        def save(entries):
            calls.append(entries)
            raise DictionarySaveError("rollback")

        editor = self.create_editor(save=save)
        editor.fields["word"].set_text("保管したい下書き")
        editor.save_button.clicked()
        self.wait_for(lambda: not editor.model.is_saving)
        self.assertTrue(editor.model.needs_recovery)
        self.assertIn("再保存を停止", editor.status_label.get_text())
        self.assertFalse(editor.save_button.get_sensitive())
        editor.fields["word"].set_text("編集後も残る下書き")
        self.assertIn("再保存を停止", editor.status_label.get_text())
        editor.save_button.clicked()
        self.flush()
        self.assertEqual(len(calls), 1)
        self.assertEqual(editor.model.entry(ENTRY_ID)["word"], "編集後も残る下書き")
        self.assertTrue(editor.cancel_button.get_sensitive())

    def test_multiline_hint_roundtrips_without_replacing_the_row_id(self):
        editor = self.create_editor()
        hint = "1行目\n2行目\t補足"
        editor.hint.get_buffer().set_text(hint)
        editor.save_button.clicked()
        self.wait_for(lambda: editor.closed)
        self.assertEqual(self.saved[0][0]["hint"], hint)
        self.assertEqual(self.saved[0][0]["id"], ENTRY_ID)

    def test_many_invalid_rows_keep_reasons_reachable_in_a_bounded_window(self):
        self.source = [
            {"id": f"{index:08X}-ABCD-1234-ABCD-123456789ABC", "word": f"試験語{index}", "reading": "", "hint": ""}
            for index in range(50)
        ]

        def validate(entries):
            return [DictionaryValidationIssue(entry["id"], "reading", "empty") for entry in entries]

        editor = self.create_editor(validate=validate)
        editor.save_button.clicked()
        self.wait_for(lambda: not editor.model.is_saving)
        from gi.repository import Gtk

        editor.tree.get_selection().select_path(Gtk.TreePath.new_from_indices([49]))
        self.flush()
        self.assertEqual(len(editor.rows), 50)
        self.assertIn("50行目の読み", editor.issue_label.get_text())
        self.assertNotIn("1行目", editor.issue_label.get_text())
        self.assertLess(editor.get_allocated_height(), 800)


if __name__ == "__main__":
    unittest.main()
