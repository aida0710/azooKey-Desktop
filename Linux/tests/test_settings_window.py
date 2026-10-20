"""Settings recovery through real GTK controls and the real Swift converter."""
import copy
import json
import os
import pathlib
import sys
import tempfile
import time
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
        from azookey.settings_store import SettingsRecoveryRequired
        original = b"{ synthetic invalid JSON"
        self.path.write_bytes(original)
        window = self.window()
        with patch.object(window.bridge, "request", wraps=window.bridge.request) as bridge:
            with self.assertRaises(SettingsRecoveryRequired):
                window.apply_settings(window.values)
            bridge.assert_not_called()
        self.assertEqual(self.path.read_bytes(), original)
        with patch("azookey.settings.confirm_restore", return_value=True), patch("azookey.settings.save_key") as keyring:
            window.restore_settings(True)
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
        self.path.write_bytes(b"{ original")
        window = self.window()
        with patch("azookey.settings.confirm_restore", return_value=False):
            window.restore_settings(False)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        with patch("azookey.settings.confirm_restore", return_value=True), \
                patch.object(window.settings_store, "save_with_backend", side_effect=OSError("synthetic disk full")):
            window.restore_settings(True)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        self.assertTrue(window.recovery_bar.get_visible())
        self.assertIn("synthetic disk full", window.message.get_text())
        self.assertFalse(window.bridge.request("settings")["settings"]["live"])

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
            editor.status_label.disconnect(status_handler)
            editor.disconnect(destroy_handler)


if __name__ == "__main__":
    unittest.main()
