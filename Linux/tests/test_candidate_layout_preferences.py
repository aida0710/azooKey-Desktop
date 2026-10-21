"""Display-count preferences do not change candidate pagination or saved data."""
import pathlib
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.candidate_layout_preferences import visible_candidate_rows
from azookey.settings_schema import input_defaults, validate_settings
from azookey.settings_store import SettingsStore


class CandidateLayoutPreferencesTests(unittest.TestCase):
    def test_supported_counts_survive_save_reload_and_missing_new_field(self):
        with tempfile.TemporaryDirectory() as directory:
            store = SettingsStore(pathlib.Path(directory) / "settings.json")
            original = {"profile": "保持する", "candidateVisibleRows": 7}
            for count in (5, 7, 9):
                with self.subTest(count=count):
                    store.save({**original, "candidateVisibleRows": count})
                    self.assertEqual(store.load(original).values, {**original, "candidateVisibleRows": count})
            store.save({"profile": "以前の設定"})
            self.assertEqual(store.load(original).values, {"profile": "以前の設定", "candidateVisibleRows": 7})

    def test_invalid_counts_are_rejected_before_writing_and_render_safely(self):
        for count in (True, False, 0, 4, 6, 8, 10, "7", 7.0, None):
            with self.subTest(count=count):
                with self.assertRaises(ValueError):
                    validate_settings({"candidateVisibleRows": count})
                self.assertEqual(visible_candidate_rows(count), 7)
        self.assertEqual([visible_candidate_rows(count) for count in (5, 7, 9)], [5, 7, 9])

    def test_reset_restores_seven_rows_without_changing_other_persistent_settings(self):
        values = {"candidateVisibleRows": 9, "profile": "保持する", "learning": "nothing", "customTable": ""}
        restored = input_defaults(values)
        self.assertEqual(restored["candidateVisibleRows"], 7)
        for key in ("profile", "learning", "customTable"):
            self.assertEqual(restored[key], values[key])


if __name__ == "__main__":
    unittest.main()
