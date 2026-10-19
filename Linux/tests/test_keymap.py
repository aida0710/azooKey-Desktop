import pathlib
import sys
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.keymap import translate


class KeymapTests(unittest.TestCase):
    def test_release_is_not_inserted(self):
        self.assertIsNone(translate(ord("a"), 1 << 30))

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


if __name__ == "__main__":
    unittest.main()
