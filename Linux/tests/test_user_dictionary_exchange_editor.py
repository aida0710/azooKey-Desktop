"""Exercise GTK file actions with synthetic services and real preview widgets."""

import copy
from dataclasses import replace
import os
import pathlib
import sys
import threading
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_exchange_service import UserDictionaryExchangeService
from azookey.user_dictionary_model import DictionaryExchangeError
from test_user_dictionary_editor import CALLBACK_DEADLINE_SECONDS, DictionaryEditorTestSupport
from test_user_dictionary_exchange_model import preview_for
from test_user_dictionary_exchange_service import SyntheticExchangeBridge, preview_response
from test_user_dictionary_model import ENTRY_ID, OTHER_ID, original_entries


class SyntheticFileDialogs:
    def __init__(self):
        self.import_selection = {"path": "/synthetic.txt", "format_name": "mozc", "encoding": "shiftJIS"}
        self.export_selection = "/synthetic-output.json"
        self.confirmed = False
        self.previews = []

    def choose_import(self):
        return self.import_selection

    def choose_export(self):
        return self.export_selection

    def confirm_import(self, preview):
        self.previews.append(preview)
        return self.confirmed


class SyntheticFileService:
    def __init__(self):
        self.import_calls = []
        self.export_calls = []
        self.failure = None

    def preview(self, path, *, format_name, encoding, entries):
        self.import_calls.append((threading.get_ident(), path, format_name, encoding, copy.deepcopy(entries)))
        if self.failure:
            raise self.failure
        return preview_for(entries)

    def export(self, entries, *, destination):
        self.export_calls.append((threading.get_ident(), copy.deepcopy(entries), destination))
        if self.failure:
            raise self.failure


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class UserDictionaryExchangeEditorTests(DictionaryEditorTestSupport, unittest.TestCase):
    def create_file_editor(self, *, service=None):
        self.file_service = service if service is not None else SyntheticFileService()
        self.file_dialogs = SyntheticFileDialogs()
        return self.create_editor(exchange_service=self.file_service, file_dialogs=self.file_dialogs)

    def test_canceling_either_file_chooser_leaves_the_current_draft_unchanged(self):
        editor = self.create_file_editor()
        editor.fields["word"].set_text("すでにある下書き")
        before = editor.model.entries
        self.file_dialogs.import_selection = None
        self.file_dialogs.export_selection = None
        for button in (editor.import_button, editor.export_button):
            button.clicked()
            self.flush()
        self.assertEqual(editor.model.entries, before)
        self.assertEqual(self.file_service.import_calls, [])
        self.assertEqual(self.file_service.export_calls, [])
        self.assertEqual(self.saved, [])

    def test_slow_import_keeps_gtk_responsive_and_cancel_preserves_prior_edits(self):
        entered = threading.Event()
        release = threading.Event()
        service = SyntheticFileService()
        original_preview = service.preview

        def slow_preview(*args, **kwargs):
            entered.set()
            if not release.wait(CALLBACK_DEADLINE_SECONDS):
                raise RuntimeError("test_gate_timeout")
            return original_preview(*args, **kwargs)

        service.preview = slow_preview
        editor = self.create_file_editor(service=service)
        editor.fields["word"].set_text("変更前からある下書き")
        before = editor.model.entries
        editor.import_button.clicked()
        try:
            self.wait_for(entered.is_set)
            heartbeat = []
            self.GLib.idle_add(lambda: heartbeat.append(True) and self.GLib.SOURCE_REMOVE)
            self.flush()
            self.assertEqual(heartbeat, [True])
            for widget in (editor.save_button, editor.import_button, editor.export_button, editor.form):
                self.assertFalse(widget.get_sensitive())
            editor.import_button.clicked()
            editor.save_button.clicked()
            editor.close()
            self.flush()
            self.assertFalse(editor.closed)
        finally:
            release.set()
        self.wait_for(editor.import_button.get_sensitive)
        self.assertEqual(editor.model.entries, before)
        self.assertEqual(len(service.import_calls), 1)
        self.assertNotEqual(service.import_calls[0][0], threading.get_ident())
        self.assertEqual(len(self.file_dialogs.previews), 1)
        self.assertEqual(self.saved, [])

    def test_confirmed_import_only_changes_the_draft_and_window_cancel_undoes_it(self):
        editor = self.create_file_editor()
        self.file_dialogs.confirmed = True
        editor.fields["word"].set_text("既存の編集")
        editor.search_entry.set_text("既存")
        editor.import_button.clicked()
        self.wait_for(editor.import_button.get_sensitive)
        self.assertEqual(editor.model.entries[0]["word"], "既存の編集")
        self.assertEqual(editor.model.entries[-1]["id"], OTHER_ID)
        self.assertEqual(editor.search_entry.get_text(), "")
        self.assertEqual(editor.fields["word"].get_text(), "追加語")
        self.assertTrue(editor.model.has_changes)
        self.assertEqual(self.source, original_entries())
        self.assertEqual(self.saved, [])
        editor.cancel_button.clicked()
        self.assertEqual(editor.model.entries, original_entries())

    def test_export_runs_on_a_worker_and_does_not_mark_the_draft_saved(self):
        editor = self.create_file_editor()
        editor.fields["word"].set_text("書き出す下書き")
        editor.export_button.clicked()
        self.wait_for(editor.export_button.get_sensitive)
        self.assertTrue(editor.model.did_export)
        self.assertTrue(editor.model.has_changes)
        self.assertFalse(editor.closed)
        self.assertIn("まだ保存されていません", editor.status_label.get_text())
        thread, entries, destination = self.file_service.export_calls[0]
        self.assertNotEqual(thread, threading.get_ident())
        self.assertEqual(entries, editor.model.entries)
        self.assertEqual(destination, self.file_dialogs.export_selection)
        self.assertEqual(self.saved, [])
        editor.cancel_button.clicked()
        self.assertEqual(editor.model.entries, original_entries())

    def test_failed_import_and_export_keep_the_draft_and_show_only_public_messages(self):
        editor = self.create_file_editor()
        editor.fields["word"].set_text("残す下書き")
        before = editor.model.entries
        self.file_service.failure = OSError("PRIVATE_TEST_SENTINEL")
        for button in (editor.import_button, editor.export_button):
            button.clicked()
            self.wait_for(button.get_sensitive)
            self.assertNotIn("PRIVATE_TEST_SENTINEL", editor.status_label.get_text())
            self.assertEqual(editor.model.entries, before)
            self.assertTrue(editor.form.get_sensitive())
        self.file_service.failure = DictionaryExchangeError("unknownEncoding")
        editor.import_button.clicked()
        self.wait_for(editor.import_button.get_sensitive)
        self.assertIn("文字コードを判定できません", editor.status_label.get_text())
        self.assertEqual(self.file_dialogs.previews, [])

    def test_preview_for_a_stale_draft_is_rejected_before_confirmation(self):
        service = SyntheticFileService()
        service.preview = lambda *args, **kwargs: preview_for(original_entries())
        editor = self.create_file_editor(service=service)
        editor.fields["word"].set_text("現在の下書き")
        editor.import_button.clicked()
        self.wait_for(editor.import_button.get_sensitive)
        self.assertEqual(editor.model.entry(ENTRY_ID)["word"], "現在の下書き")
        self.assertIn("確認中に下書きが変わりました", editor.status_label.get_text())
        self.assertEqual(self.file_dialogs.previews, [])

    def test_real_preview_shows_counts_source_lines_reasons_and_full_multiline_details(self):
        from azookey.user_dictionary_editor import _message
        from azookey.user_dictionary_exchange_dialogs import UserDictionaryImportPreviewDialog
        from gi.repository import Gtk

        service = UserDictionaryExchangeService(bridge_factory=lambda: SyntheticExchangeBridge(preview_response()))
        preview = service.preview("/synthetic.txt", format_name="mozc", encoding="utf8", entries=self.source)
        parent = self.create_file_editor()
        dialog = UserDictionaryImportPreviewDialog(preview, parent=parent, message=_message)
        self.windows.append(dialog)
        self.flush()
        self.assertIn("追加 1件・重複 1件・衝突 1件・除外 2件", dialog.counts_label.get_text())
        self.assertEqual(dialog.rows[0][1], "2行目")
        self.assertIn("既存の項目を残します", dialog.rows[2][6])
        self.assertIn("この品詞は取り込めません", dialog.rows[3][6])
        detail = dialog.details.get_buffer()
        self.assertIn("1行目\n2行目\t補足", detail.get_text(detail.get_start_iter(), detail.get_end_iter(), True))
        dialog.tree.get_selection().select_path(Gtk.TreePath.new_from_indices([3]))
        self.assertIn("元の品詞：動詞", detail.get_text(detail.get_start_iter(), detail.get_end_iter(), True))
        no_additions = replace(preview, rows=preview.rows[1:], entries_after_import=preview.original_entries)
        empty_dialog = UserDictionaryImportPreviewDialog(no_additions, parent=parent, message=_message)
        self.windows.append(empty_dialog)
        self.assertFalse(empty_dialog.apply_button.get_sensitive())
        self.assertEqual(parent.model.entries, original_entries())
        self.assertEqual(self.saved, [])


if __name__ == "__main__":
    unittest.main()
