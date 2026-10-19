import pathlib
import sys
import tempfile
import unittest
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.prompts import PromptHistory, matches, parse_shortcut, shortcut_text


class PromptTests(unittest.TestCase):
    def test_shortcut_matches_only_the_same_key_and_modifiers(self):
        shortcut = parse_shortcut("Ctrl+Alt+E")
        self.assertEqual(shortcut_text(shortcut), "Ctrl+Alt+e")
        self.assertTrue(matches(shortcut, {"charactersIgnoringModifiers": "e", "modifierFlags": 6}))
        self.assertFalse(matches(shortcut, {"charactersIgnoringModifiers": "e", "modifierFlags": 2}))
        with self.assertRaises(ValueError):
            parse_shortcut("e")

    def test_pins_survive_recent_history_limit_and_shortcuts_are_unique(self):
        with tempfile.TemporaryDirectory() as directory:
            history = PromptHistory(directory)
            shortcut = parse_shortcut("Ctrl+Alt+e")
            history.save("敬語", pinned=True, shortcut=shortcut)
            for index in range(15):
                history.save(f"指示{index}")
            items = history.load()
            self.assertEqual(sum(not item["pinned"] for item in items), 10)
            self.assertIn("敬語", [item["prompt"] for item in items])
            self.assertEqual(history.path.stat().st_mode & 0o777, 0o600)
            with self.assertRaises(ValueError):
                history.save("重複", pinned=True, shortcut=shortcut)
