"""Keep a file chooser outside its activating GTK/AT callback and bound to its editor."""
import os
import unittest

from test_user_dictionary_editor import CALLBACK_DEADLINE_SECONDS, DictionaryEditorTestSupport
from test_user_dictionary_exchange_editor import SyntheticFileDialogs, SyntheticFileService
from test_user_dictionary_model import original_entries


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class UserDictionaryFileDispatchTests(DictionaryEditorTestSupport, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.file_service = SyntheticFileService()
        self.file_dialogs = SyntheticFileDialogs()
        self.choices = []
        self.file_dialogs.choose_import = lambda: self.choices.append("import")
        self.file_dialogs.choose_export = lambda: self.choices.append("export")
        self.editor = self.create_editor(exchange_service=self.file_service, file_dialogs=self.file_dialogs)

    def assert_no_file_or_save_requests(self):
        self.assertEqual(self.file_service.import_calls, [])
        self.assertEqual(self.file_service.export_calls, [])
        self.assertEqual(self.saved, [])

    def test_file_click_returns_before_opening_and_duplicate_actions_open_one_chooser(self):
        self.editor.import_button.clicked()
        self.assertEqual(self.choices, [])
        for button in (self.editor.import_button, self.editor.export_button, self.editor.save_button):
            self.assertFalse(button.get_sensitive())
            button.clicked()
        self.flush()
        self.assertEqual(self.choices, ["import"])
        self.assertTrue(self.editor.import_button.get_sensitive())
        self.assert_no_file_or_save_requests()

    def test_actions_delivered_while_the_chooser_runs_do_not_open_or_save_again(self):
        def choose_import():
            self.choices.append("import")
            for button in (self.editor.import_button, self.editor.export_button, self.editor.save_button):
                button.clicked()
            self.flush()

        self.file_dialogs.choose_import = choose_import
        self.editor.import_button.clicked()
        self.flush()
        self.assertEqual(self.choices, ["import"])
        self.assert_no_file_or_save_requests()

    def test_cancel_before_dispatch_discards_the_draft_without_opening_the_chooser(self):
        self.editor.fields["word"].set_text("保存しない下書き")
        self.editor.import_button.clicked()
        self.editor.cancel_button.clicked()
        self.flush()
        self.assertTrue(self.editor.closed)
        self.assertEqual(self.choices, [])
        self.assertEqual(self.editor.model.entries, original_entries())
        self.assert_no_file_or_save_requests()

    def test_close_before_dispatch_cancels_the_reserved_chooser(self):
        self.editor.import_button.clicked()
        self.editor.emit("delete-event", None)
        self.flush()
        self.assertTrue(self.editor.closed)
        self.assertEqual(self.choices, [])
        self.assert_no_file_or_save_requests()

    def test_destroy_before_dispatch_cancels_the_reserved_chooser(self):
        self.editor.export_button.clicked()
        self.editor.destroy()
        self.flush()
        self.assertTrue(self.editor.closed)
        self.assertEqual(self.choices, [])
        self.assert_no_file_or_save_requests()

    def test_destroy_during_the_chooser_rejects_the_returned_selection(self):
        def choose_import():
            self.editor.destroy()
            return self.file_dialogs.import_selection

        self.file_dialogs.choose_import = choose_import
        self.editor.import_button.clicked()
        self.flush()
        self.assertTrue(self.editor.closed)
        self.assert_no_file_or_save_requests()

    def test_chooser_cancel_preserves_edits_and_allows_the_next_file_action(self):
        self.editor.fields["word"].set_text("保持する下書き")
        before = self.editor.model.entries
        self.editor.import_button.clicked()
        self.flush()
        self.editor.export_button.clicked()
        self.flush()
        self.assertEqual(self.choices, ["import", "export"])
        self.assertEqual(self.editor.model.entries, before)
        self.assertTrue(self.editor.form.get_sensitive())
        self.assert_no_file_or_save_requests()

    def test_chooser_exception_preserves_edits_and_releases_the_next_file_action(self):
        def fail_choice():
            raise OSError("PRIVATE_TEST_SENTINEL")

        self.editor.fields["word"].set_text("保持する下書き")
        before = self.editor.model.entries
        self.file_dialogs.choose_import = fail_choice
        self.editor.import_button.clicked()
        self.flush()
        self.assertEqual(self.editor.model.entries, before)
        self.assertNotIn("PRIVATE_TEST_SENTINEL", self.editor.status_label.get_text())
        self.assertTrue(self.editor.import_button.get_sensitive())
        self.assertTrue(self.editor.form.get_sensitive())
        self.editor.export_button.clicked()
        self.flush()
        self.assertEqual(self.choices, ["export"])
        self.assert_no_file_or_save_requests()

    def test_destroying_the_parent_closes_the_actual_file_chooser_without_io(self):
        from gi.repository import Gtk
        from azookey.user_dictionary_editor import _message
        from azookey.user_dictionary_exchange_dialogs import UserDictionaryFileDialogs

        self.editor._file_dialogs = UserDictionaryFileDialogs(self.editor, message=_message)
        opened = []
        expired = []

        def destroy_parent():
            choosers = [window for window in Gtk.Window.list_toplevels()
                        if isinstance(window, Gtk.FileChooserDialog) and window.get_visible()]
            self.assertEqual(len(choosers), 1)
            opened.extend(choosers)
            self.editor.destroy()
            return self.GLib.SOURCE_REMOVE

        def rescue_if_parent_did_not_close():
            expired.append(True)
            for window in Gtk.Window.list_toplevels():
                if isinstance(window, Gtk.FileChooserDialog):
                    window.response(Gtk.ResponseType.CANCEL)
            return self.GLib.SOURCE_REMOVE

        deadline = self.GLib.timeout_add(int(CALLBACK_DEADLINE_SECONDS * 1000), rescue_if_parent_did_not_close)
        try:
            self.editor.import_button.clicked()
            self.GLib.idle_add(destroy_parent)
            self.flush()
        finally:
            if not expired:
                self.GLib.source_remove(deadline)
        self.assertEqual(expired, [])
        self.assertEqual(len(opened), 1)
        self.assertTrue(self.editor.closed)
        self.assertFalse(opened[0].get_visible())
        self.assert_no_file_or_save_requests()


if __name__ == "__main__":
    unittest.main()
