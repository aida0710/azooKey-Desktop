#!/usr/bin/python3
"""Actual AT recovery activation must permit native Escape and an explicit later restore."""
import unittest

from gtk_dialog_atspi_support import GtkDialogAtspiTestCase
from native_toolkit_support import CONTROL, ESCAPE


class SettingsDialogAtspiTests(GtkDialogAtspiTestCase):
    fixture_name = "settings_dialog_fixture.py"
    product_paths = ("azookey/settings.py", "azookey/settings_recovery.py")

    def exercise_recovery(self, name, *, defaults):
        self.focus_window(self.observation()["editorWindow"])
        self.wait_for(lambda: self.application() is not None, "at-registration")
        self.send_key(CONTROL)
        self.wait_for(lambda: any(event["keyval"] == CONTROL for event in self.key_events),
                      "at-key-delivery-ready")
        original = self.observation()["settingsSHA256"]
        self.activate(self.application(), name)
        self.wait_for(lambda: len(self.observation()["dialogs"]) == 1
                      and self.observation()["dialogs"][0]["mapped"], "confirmation-visible")
        self.focus_window(self.observation()["dialogs"][0]["window"])
        self.send_key(ESCAPE)
        self.wait_for(lambda: not self.observation()["dialogs"], "escape-cancelled")
        self.assertEqual(self.observation()["settingsSHA256"], original)
        self.assertEqual(self.observation()["archives"], [])
        self.assertTrue(self.observation()["recoveryVisible"])

        self.activate(self.application(), name)
        self.wait_for(lambda: len(self.observation()["dialogs"]) == 1, "confirmation-reopened")
        self.activate(self.application(), "OK")
        self.wait_for(lambda: not self.observation()["dialogs"]
                      and not self.observation()["recoveryVisible"], "explicit-restore-completed")
        restored = self.observation()
        self.assertEqual(restored["archives"], [original])
        self.assertEqual(restored["settings"]["userDictionary"], restored["originalDictionary"])
        self.assertEqual(restored["settings"]["learning"], "nothing")
        self.assertFalse(restored["settings"]["includeContext"])
        self.assertEqual(restored["settings"]["live"], defaults)
        self.assertIn("設定を復旧しました。", restored["message"])

    def test_at_current_restore_allows_escape_then_preserves_dictionary_on_confirmation(self):
        self.exercise_recovery("正常な設定で復旧", defaults=False)

    def test_at_default_restore_allows_escape_then_preserves_dictionary_on_confirmation(self):
        self.exercise_recovery("入力・表示を既定に戻して復旧", defaults=True)


if __name__ == "__main__":
    unittest.main()
