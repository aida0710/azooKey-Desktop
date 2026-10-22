import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.keymap import translate


class KeymapTests(unittest.TestCase):
    def test_release_is_not_inserted(self):
        self.assertIsNone(translate(ord("a"), 1 << 30))

    def test_physical_modifier_presses_and_releases_do_not_edit_composition(self):
        keyvals = {
            "Shift_L": 0xFFE1, "Shift_R": 0xFFE2,
            "Control_L": 0xFFE3, "Control_R": 0xFFE4,
            "Caps_Lock": 0xFFE5, "Shift_Lock": 0xFFE6,
            "Meta_L": 0xFFE7, "Meta_R": 0xFFE8,
            "Alt_L": 0xFFE9, "Alt_R": 0xFFEA,
            "Super_L": 0xFFEB, "Super_R": 0xFFEC,
            "Hyper_L": 0xFFED, "Hyper_R": 0xFFEE,
            "Num_Lock": 0xFF7F, "ISO_Level3_Shift": 0xFE03, "ISO_Level5_Shift": 0xFE11,
        }
        for name, keyval in keyvals.items():
            for state in (0, 1, 4, 8, 1 << 6, 1 << 30):
                with self.subTest(key=name, state=state):
                    self.assertIsNone(translate(keyval, state, 0))

    def test_physical_navigation_and_modifiers(self):
        self.assertEqual(translate(0xFF51, 1)["keyCode"], 123)
        self.assertEqual(translate(0xFF51, 1)["modifierFlags"], 1)
        self.assertEqual(translate(ord("h"), 4)["modifierFlags"], 2)
        self.assertEqual(translate(ord("a"), 1 << 26)["modifierFlags"], 8)

    def test_unicode_and_function_keys(self):
        self.assertEqual(translate(0x0101F600, 0)["characters"], "😀")
        self.assertIsNone(translate(0xFF51, 0)["characters"])
        self.assertEqual(translate(0xFFC7, 0)["keyCode"], 109)
        self.assertEqual(translate(ord("9"), 0)["keyCode"], 25)

    def test_home_end_and_forward_delete_reach_the_composition_editor(self):
        self.assertEqual(translate(0xFF50, 0)["keyCode"], 0x73)
        self.assertEqual(translate(0xFF57, 0)["keyCode"], 0x77)
        self.assertEqual(translate(0xFFFF, 0)["keyCode"], 0x75)

    def test_keypad_enter_reaches_the_core_enter_action(self):
        self.assertEqual(translate(0xFF8D, 0)["keyCode"], 0x4C)

    def test_encoded_fullwidth_unicode_is_text_not_a_function_key(self):
        self.assertEqual(translate(0x0100FF21, 0)["characters"], "Ａ")
        self.assertEqual(translate(0x0100FF76, 0)["characters"], "ｶ")
        self.assertIsNone(translate(0x0100D800, 0)["characters"])

    def test_legacy_kana_keysym_uses_platform_unicode_translation(self):
        self.assertEqual(translate(0x04B6, 0, 0x30AB)["characters"], "カ")
        self.assertIsNone(translate(0xFF0D, 0, 13)["characters"])


if __name__ == "__main__":
    unittest.main()
