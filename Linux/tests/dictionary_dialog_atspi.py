#!/usr/bin/python3
"""Keep actual AT activation followed by Ctrl+L responsive in a real GTK chooser."""
import unittest

from gtk_dialog_atspi_support import Atspi, CONTROL_MODIFIER_MASK, GtkDialogAtspiTestCase, descendants
from native_toolkit_support import BACKSPACE, CONTROL
from test_user_dictionary_model import original_entries


CHOOSER_PATH = "/tmp/azookey-file-dialog.json"


class DictionaryDialogAtspiTests(GtkDialogAtspiTestCase):
    fixture_name = "dictionary_dialog_fixture.py"
    product_paths = ("azookey/user_dictionary_editor.py", "azookey/user_dictionary_exchange_dialogs.py")

    def focused_text(self, text=None, *, allow_completion=False):
        observed = self.observation()
        if len(observed["choosers"]) != 1:
            return False
        for entry in observed["choosers"][0]["entries"]:
            if not (entry["focused"] and entry["realized"] and entry["mapped"]):
                continue
            if text is None or entry["text"] == text:
                return True
            # GTK selects its suggested suffix. Only that selected suffix may
            # extend the typed prefix; the final path must still match exactly.
            if allow_completion and entry["text"].startswith(text) and entry["selection"] == [len(text), len(entry["text"])]:
                return True
        return False

    def exercise_chooser(self, name):
        self.focus_window(self.observation()["editorWindow"])
        self.wait_for(lambda: self.application() is not None, "at-registration")
        self.send_key(CONTROL)
        self.wait_for(lambda: any(event["keyval"] == CONTROL for event in self.key_events),
                      "at-key-delivery-ready")
        self.activate(self.application(), name)
        self.wait_for(lambda: len(self.observation()["choosers"]) == 1
                      and self.observation()["choosers"][0]["mapped"], "chooser-visible")
        self.focus_window(self.observation()["choosers"][0]["window"])
        self.send_key(ord("l"), modifiers=(CONTROL,))
        self.wait_for(lambda: self.focused_text(), "location-focused-after-ctrl-l")
        self.send_key(ord("a"), modifiers=(CONTROL,))
        self.send_key(BACKSPACE)
        self.wait_for(lambda: self.focused_text(""), "empty-location")
        for index, character in enumerate(CHOOSER_PATH, start=1):
            self.send_key(ord(character))
            self.wait_for(lambda: self.focused_text(CHOOSER_PATH[:index], allow_completion=True),
                          "location-prefix-" + str(index))
        self.wait_for(lambda: self.focused_text(CHOOSER_PATH), "exact-location")
        self.assertTrue(any(event["keyval"] == ord("l") and event["modifiers"] & CONTROL_MODIFIER_MASK
                            for event in self.key_events), "the AT listener did not observe Ctrl+L")
        dialogs = [item for item in descendants(self.application())
                   if item.get_name() == name and item.get_role() == Atspi.Role.FILE_CHOOSER]
        self.assertEqual(len(dialogs), 1)
        self.activate(dialogs[0], "キャンセル")
        self.wait_for(lambda: not self.observation()["choosers"], "chooser-cancelled")
        self.assertEqual(self.observation()["entries"], original_entries())
        self.assertEqual(self.observation()["saved"], [])

    def test_at_import_action_then_location_keys_and_cancel_preserve_the_draft(self):
        self.exercise_chooser("ファイルから取り込む")

    def test_at_export_action_then_location_keys_and_cancel_preserve_the_draft(self):
        self.exercise_chooser("JSONを書き出す")



if __name__ == "__main__":
    unittest.main()
