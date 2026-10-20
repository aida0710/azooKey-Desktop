"""Settings recovery through real GTK controls and the real Swift converter."""
import copy
import json
import os
import pathlib
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

# Drawing must complete before a screenshot is evidence of the layout.
FRAME_PAINT_TIMEOUT_SECONDS = 3
FRAME_POLL_INTERVAL_SECONDS = 0.005


@unittest.skipUnless(os.environ.get("DISPLAY") and os.environ.get("AZOOKEY_BRIDGE"), "requires Xvfb and the Swift bridge")
class SettingsWindowTests(unittest.TestCase):
    def setUp(self):
        from azookey.bridge import Bridge
        from azookey.settings_store import SettingsStore
        self.directory = tempfile.TemporaryDirectory(prefix="azookey-settings-window-")
        self.addCleanup(self.directory.cleanup)
        root = pathlib.Path(self.directory.name)
        self.environment = patch.dict(os.environ, {"XDG_CONFIG_HOME": str(root / "config"),
                                                   "AZOOKEY_DATA_DIR": str(root / "data")})
        self.environment.start()
        self.addCleanup(self.environment.stop)
        bridge = Bridge()
        try:
            self.values = bridge.request("settings")["settings"]
            self.values.update({"live": False, "tree": False, "learning": "nothing", "includeContext": False})
            self.values["userDictionary"] = {"items": [{
                "id": "6c5fce13-fb0f-4b59-9281-f7347ae8f91c", "reading": "てすと", "word": "試験", "hint": "回復用",
            }]}
            # Initial migration reads the already persisted dictionary. Later
            # edits use the explicit dictionary transaction instead of configure.
            SettingsStore().save(self.values)
            self.assertFalse(bridge.request("configure", settings=self.values).get("error"))
            self.values = bridge.request("settings")["settings"]
        finally:
            bridge.close()
        self.store = SettingsStore()
        self.store.save(self.values)
        self.path = self.store.path

    def window(self):
        from azookey.settings import SettingsWindow
        window = SettingsWindow()
        self.addCleanup(window.destroy)
        window.show_all()
        self.wait_for_paint(window)
        return window

    @staticmethod
    def wait_for_paint(window):
        from gi.repository import GLib
        painted = []
        frame_clock = window.get_frame_clock()
        handler = frame_clock.connect("after-paint", lambda _clock: painted.append(True))
        window.queue_draw()
        # Await GTK's completed frame, not merely its pending layout events.
        deadline = time.monotonic() + FRAME_PAINT_TIMEOUT_SECONDS
        while not painted:
            if time.monotonic() > deadline:
                raise AssertionError("settings window did not paint")
            GLib.MainContext.default().iteration(False)
            time.sleep(FRAME_POLL_INTERVAL_SECONDS)
        frame_clock.disconnect(handler)

    def test_invalid_json_type_unknown_value_and_unreadable_file_open_recovery_controls(self):
        cases = [("{", False), ('{"live":"yes"}', False), ('{"learning":"unknown"}', False),
                 ('{"unknown":true}', False)]
        # Root can read mode 000. The non-root desktop VM covers the real
        # permission failure; root containers still run the remaining cases.
        if os.geteuid() != 0:
            cases.append(("{}", True))
        for document, unreadable in cases:
            with self.subTest(document=document, unreadable=unreadable):
                self.path.chmod(0o600)
                self.path.write_text(document)
                if unreadable:
                    self.path.chmod(0)
                try:
                    window = self.window()
                    self.assertIsNotNone(window.recovery_bar)
                    self.assertTrue(window.recovery_bar.get_visible())
                    labels = window.recovery_bar.get_content_area().get_children()
                    self.assertIn(str(self.path), labels[0].get_text())
                    self.assertEqual(window.values["userDictionary"], self.values["userDictionary"])
                    self.assertFalse(window.widgets["live"].get_active())
                    if document == "{" and os.environ.get("AZOOKEY_SETTINGS_SCREENSHOT"):
                        from gi.repository import Gdk
                        image = Gdk.pixbuf_get_from_window(window.get_window(), 0, 0,
                                                          window.get_allocated_width(), window.get_allocated_height())
                        image.savev(os.environ["AZOOKEY_SETTINGS_SCREENSHOT"], "png", [], [])
                    window.destroy()
                finally:
                    self.path.chmod(0o600)
                self.assertEqual(self.path.read_text(), document)

    def test_explicit_default_recovery_preserves_dictionary_and_never_calls_keyring_save(self):
        from gi.repository import Gtk
        from azookey.settings_store import SettingsRecoveryRequired
        original = b"{ synthetic invalid JSON"
        self.path.write_bytes(original)
        window = self.window()
        with patch.object(window.bridge, "request", wraps=window.bridge.request) as bridge:
            with self.assertRaises(SettingsRecoveryRequired):
                window.apply_settings(window.values)
            bridge.assert_not_called()
        self.assertEqual(self.path.read_bytes(), original)
        with patch("azookey.settings.save_key") as keyring:
            window.restore_settings(True)
            self.assertEqual(self.path.read_bytes(), original)
            window.recovery_dialog.response(Gtk.ResponseType.OK)
        keyring.assert_not_called()
        self.assertFalse(window.recovery_bar.get_visible())
        self.assertTrue(window.widgets["live"].get_active())
        saved = json.loads(self.path.read_text())
        self.assertEqual(saved["userDictionary"], self.values["userDictionary"])
        self.assertEqual(saved["learning"], "nothing")
        self.assertFalse(saved["includeContext"])
        backups = list(self.path.parent.glob("settings.recovered-*"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].read_bytes(), original)
        self.assertEqual(window.bridge.request("settings")["settings"]["userDictionary"], self.values["userDictionary"])
        window.widgets["live"].set_active(False)
        window.save(None)
        self.assertFalse(json.loads(self.path.read_text())["live"])

    def test_recovery_cancel_and_save_failure_keep_original(self):
        from gi.repository import Gtk
        self.path.write_bytes(b"{ original")
        window = self.window()
        window.restore_settings(False)
        window.recovery_dialog.response(Gtk.ResponseType.CANCEL)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        with patch.object(window.settings_store, "save_with_backend", side_effect=OSError("synthetic disk full")):
            window.restore_settings(True)
            window.recovery_dialog.response(Gtk.ResponseType.OK)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        self.assertTrue(window.recovery_bar.get_visible())
        self.assertIn("synthetic disk full", window.message.get_text())
        self.assertFalse(window.bridge.request("settings")["settings"]["live"])
        window.restore_settings(False)
        window.recovery_dialog.response(Gtk.ResponseType.OK)
        self.assertFalse(window.recovery_bar.get_visible())
        self.assertFalse(json.loads(self.path.read_text())["live"])

    def test_repeated_restore_keeps_first_confirmation_and_applies_only_once(self):
        from gi.repository import Gtk
        self.path.write_bytes(b"{ original")
        window = self.window()
        window.restore_settings(False)
        dialog = window.recovery_dialog
        window.restore_settings(True)
        self.assertIs(window.recovery_dialog, dialog)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        with patch.object(window, "apply_settings", wraps=window.apply_settings) as apply:
            dialog.response(Gtk.ResponseType.OK)
            dialog.response(Gtk.ResponseType.OK)
            window.restore_settings(True)
        apply.assert_called_once()
        self.assertFalse(json.loads(self.path.read_text())["live"], "The first request kept current settings")
        self.assertIsNone(window.recovery_dialog)
        self.assertEqual(len(list(self.path.parent.glob("settings.recovered-*"))), 1)

    def test_dismissed_confirmation_cannot_authorize_a_later_restore(self):
        from gi.repository import Gtk
        self.path.write_bytes(b"{ original")
        window = self.window()
        window.restore_settings(True)
        dismissed = window.recovery_dialog
        dismissed.response(Gtk.ResponseType.DELETE_EVENT)
        window.restore_settings(False)
        current = window.recovery_dialog
        self.assertIsNot(current, dismissed)
        with patch.object(window, "apply_settings", wraps=window.apply_settings) as apply:
            dismissed.response(Gtk.ResponseType.OK)
            self.assertIs(window.recovery_dialog, current)
            current.destroy()
        apply.assert_not_called()
        self.assertIsNone(window.recovery_dialog)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        self.assertFalse(list(self.path.parent.glob("settings.recovered-*")))

    def test_destroying_parent_cancels_confirmation_without_saving(self):
        from gi.repository import Gtk
        self.path.write_bytes(b"{ original")
        window = self.window()
        window.restore_settings(True)
        dialog = window.recovery_dialog
        self.assertTrue(dialog.get_destroy_with_parent())
        with patch.object(window, "apply_settings", wraps=window.apply_settings) as apply:
            window.destroy()
            dialog.response(Gtk.ResponseType.OK)
            window.restore_settings(True)
        apply.assert_not_called()
        self.assertIsNone(window.recovery_dialog)
        self.assertFalse(dialog.get_visible())
        self.assertEqual(self.path.read_bytes(), b"{ original")
        self.assertFalse(list(self.path.parent.glob("settings.recovered-*")))

    def test_parent_closed_during_confirmation_retirement_does_not_apply_settings(self):
        from gi.repository import Gtk
        self.path.write_bytes(b"{ original")
        window = self.window()
        window.restore_settings(True)
        dialog = window.recovery_dialog
        dialog.connect("destroy", lambda _dialog: window.destroy())
        with patch.object(window, "apply_settings", wraps=window.apply_settings) as apply:
            dialog.response(Gtk.ResponseType.OK)
        apply.assert_not_called()
        self.assertTrue(window.closed)
        self.assertEqual(self.path.read_bytes(), b"{ original")

    def test_concurrent_save_leaves_latest_file_and_shows_conflict(self):
        window = self.window()
        latest = copy.deepcopy(self.values)
        latest["profile"] = "別の画面"
        self.path.write_text(json.dumps(latest, ensure_ascii=False))
        window.widgets["live"].set_active(True)
        with patch.object(window.bridge, "request", wraps=window.bridge.request) as bridge:
            window.save(None)
            bridge.assert_not_called()
        self.assertIn("変わりました", window.message.get_text())
        self.assertEqual(json.loads(self.path.read_text()), latest)

    def test_dictionary_cancel_and_general_save_preserve_saved_entries_and_ids(self):
        window = self.window()
        original = self.path.read_bytes()
        window.dictionary_button.clicked()
        editor = window.dictionary_editor
        self.assertTrue(editor.get_modal())
        self.assertTrue(window.close_requested(window, None))
        editor.add_button.clicked()
        self.assertEqual(len(editor.model.entries), 2)
        editor.cancel_button.clicked()
        self.assertTrue(editor.closed)
        self.assertEqual(self.path.read_bytes(), original)
        window.widgets["live"].set_active(True)
        window.save(None)
        self.assertEqual(json.loads(self.path.read_text())["userDictionary"], self.values["userDictionary"])

    def test_dictionary_save_updates_parent_stamp_and_survives_later_settings_save_and_restart(self):
        from azookey.bridge import Bridge
        window = self.window()
        window.dictionary_button.clicked()
        editor = window.dictionary_editor
        editor.fields["word"].set_text("安全保存確認語")
        self.finish_dictionary_save(editor)
        self.assertTrue(editor.closed)
        entry = json.loads(self.path.read_text())["userDictionary"]["items"][0]
        self.assertEqual(entry["word"], "安全保存確認語")
        self.assertEqual(entry["id"].lower(), self.values["userDictionary"]["items"][0]["id"].lower())
        window.widgets["live"].set_active(True)
        window.save(None)
        self.assertEqual(json.loads(self.path.read_text())["userDictionary"]["items"][0], entry)
        connection = Bridge()
        try:
            self.assertEqual(connection.request("settings")["settings"]["userDictionary"]["items"][0]["word"], entry["word"])
        finally:
            connection.close()

    def test_invalid_dictionary_stays_in_editor_and_never_changes_saved_settings(self):
        window = self.window()
        original = self.path.read_bytes()
        window.dictionary_button.clicked()
        editor = window.dictionary_editor
        editor.fields["reading"].set_text("てすと🦊")
        self.finish_dictionary_save(editor)
        self.assertFalse(editor.closed)
        self.assertTrue(editor.model.issues)
        self.assertEqual(self.path.read_bytes(), original)
        editor.cancel_button.clicked()

    def test_dictionary_save_reports_backup_failure_after_persisting_the_new_dictionary(self):
        from azookey import settings_store
        window = self.window()
        window.dictionary_button.clicked()
        editor = window.dictionary_editor
        editor.fields["word"].set_text("控え失敗確認語")
        write_atomic = settings_store._write_atomic

        def backup_unavailable(path, values):
            if path.name == "settings.last-good.json":
                raise PermissionError("SYNTHETIC_PRIVATE_FAILURE")
            return write_atomic(path, values)

        with patch("azookey.settings_store._write_atomic", side_effect=backup_unavailable):
            self.finish_dictionary_save(editor)
        self.assertTrue(editor.closed)
        self.assertEqual(json.loads(self.path.read_text())["userDictionary"]["items"][0]["word"], "控え失敗確認語")
        self.assertIn("控え", window.message.get_text())
        self.assertNotIn("SYNTHETIC_PRIVATE_FAILURE", window.message.get_text())

    @staticmethod
    def finish_dictionary_save(editor):
        from gi.repository import GLib
        loop = GLib.MainLoop()
        expired = []

        def finished(*_arguments):
            if editor.closed or not editor.model.is_saving:
                loop.quit()

        def deadline():
            expired.append(True)
            loop.quit()
            return GLib.SOURCE_REMOVE

        # This bounds a failed worker; successful saves wake on GTK signals.
        worker_deadline_seconds = 10
        timer = GLib.timeout_add_seconds(worker_deadline_seconds, deadline)
        status_handler = editor.status_label.connect("notify::label", finished)
        destroy_handler = editor.connect("destroy", finished)
        try:
            editor.save_button.clicked()
            if not editor.closed and editor.model.is_saving:
                loop.run()
            if expired:
                raise AssertionError("dictionary worker did not report a result")
        finally:
            if not expired:
                GLib.source_remove(timer)
            if editor.status_label.handler_is_connected(status_handler):
                editor.status_label.disconnect(status_handler)
            if editor.handler_is_connected(destroy_handler):
                editor.disconnect(destroy_handler)

    def test_failed_publication_and_failed_core_restore_require_restore_before_another_save(self):
        window = self.window()
        original = self.path.read_bytes()
        original_backup = self.store.backup.read_bytes()
        real_request = window.bridge.request
        configured = []

        def reject_restore(operation, **payload):
            if operation == "configure":
                configured.append(payload["settings"]["live"])
                if payload["settings"]["live"] is False:
                    return {"error": "synthetic rollback failure"}
            return real_request(operation, **payload)

        window.widgets["live"].set_active(True)
        with patch.object(window.bridge, "request", side_effect=reject_restore), \
                patch.object(pathlib.Path, "replace", side_effect=PermissionError("synthetic publication failure")):
            window.save(None)
            self.assertEqual(configured, [True, False])
            self.assertTrue(window.backend_recovery_pending)
            self.assertIn("復元に失敗", window.message.get_text())
            self.assertTrue(real_request("settings")["settings"]["live"])
            window.save(None)
            self.assertEqual(configured, [True, False, False], "Only the pending restore may run on retry")
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.store.backup.read_bytes(), original_backup)
        with patch.object(window.bridge, "request", wraps=real_request) as requests:
            window.save(None)
        self.assertEqual([call.kwargs["settings"]["live"] for call in requests.call_args_list
                          if call.args[0] == "configure"], [False, True])
        self.assertFalse(window.backend_recovery_pending)
        self.assertTrue(json.loads(self.path.read_text())["live"])

    def test_repair_during_queued_core_rejection_applies_new_settings_without_a_stale_warning(self):
        from azookey.engine import Engine
        pending = []
        warnings = []
        input_queue = types.SimpleNamespace(submit=lambda operation, **options: pending.append((operation, options)))
        engine = types.SimpleNamespace(
            settings=self.values, settings_store=self.store, settings_stamp=None, pending_settings_stamp=None,
            settings_problem_stamp=None, input=input_queue, update_auxiliary_text=lambda *args: warnings.append(args),
        )
        engine.notify_settings_problem = types.MethodType(Engine.notify_settings_problem, engine)
        self.path.write_text(json.dumps({**self.values, "customTable": "synthetic invalid table"}))
        Engine.reload_settings(engine)
        self.path.write_text(json.dumps({**self.values, "live": True}))
        pending[0][1]["completion"]({"error": "invalid_request"})
        self.assertEqual(warnings, [])
        Engine.reload_settings(engine)
        self.assertEqual(len(pending), 2)
        pending[1][1]["completion"]({})
        self.assertTrue(engine.settings["live"])
        self.assertEqual(warnings, [])


if __name__ == "__main__":
    unittest.main()
