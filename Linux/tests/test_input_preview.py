import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_preview import InputPreview
from azookey.keymap import translate


class InputPreviewTests(unittest.TestCase):
    def preview(self, snapshot, keys, *, settings=None):
        preview = InputPreview(snapshot, settings=settings)
        for keyval, state in keys:
            self.assertTrue(preview.apply(translate(keyval, state)))
        return preview

    def test_escape_undoes_pending_conversion_and_preserves_reading(self):
        snapshot = {"preedit": "にほんご", "reading": "にほんご", "inputState": "composing"}
        preview = self.preview(snapshot, [(32, 0), (0xFF1B, 0)])
        self.assertEqual(preview.visible_text, "にほんご")
        self.assertFalse(preview.discarded)
        self.assertEqual(preview.state, "composing")

    def test_modified_escape_preserves_composition(self):
        for modifier in (4, 8, 1 << 26):
            with self.subTest(modifier=modifier):
                preview = self.preview({"preedit": "にほんご"}, [(ord("a"), 0), (0xFF1B, modifier)])
                self.assertEqual(preview.visible_text, "にほんごa")

    def test_escape_does_not_discard_text_submitted_by_an_earlier_enter(self):
        preview = self.preview({}, [
            (ord("a"), 0), (0xFF0D, 0), (ord("b"), 0), (0xFF1B, 0),
        ])
        self.assertEqual(preview.visible_text, "a")
        self.assertTrue(preview.discarded)

    def test_cursor_and_control_h_apply_in_order_before_focus_loss(self):
        preview = self.preview({"language": "english"}, [
            (ord("a"), 0), (0xFF51, 0), (ord("b"), 0),
        ])
        self.assertEqual((preview.visible_text, preview.visible_cursor), ("ba", 1))
        preview = self.preview({"preedit": "あ", "cursor": 1}, [
            (ord("b"), 0), (ord("h"), 4),
        ])
        self.assertEqual(preview.visible_text, "あ")

    def test_editing_converted_text_uses_the_reading_cursor(self):
        preview = self.preview({
            "preedit": "日本語", "reading": "にほんご", "cursor": 3,
            "readingCursor": 3, "inputState": "composing",
        }, [(0xFF51, 0), (ord("a"), 0)])
        self.assertEqual(preview.visible_text, "にほaんご")

    def test_cursor_and_backspace_keep_combining_and_emoji_clusters_whole(self):
        for cluster in ("e\u0301", "👩\u200d🚀", "🇯🇵", "か\u3099"):
            with self.subTest(cluster=cluster):
                preview = self.preview({"preedit": cluster + "a"}, [(0xFF51, 0), (0xFF08, 0)])
                self.assertEqual(preview.visible_text, "a")
                self.assertEqual(preview.visible_cursor, 0)

    def test_native_edit_outside_the_recovery_buffer_requires_application_delivery(self):
        preview = InputPreview({"language": "english"})
        self.assertFalse(preview.apply(translate(0xFF51, 0)))

    def test_home_exits_selection_and_moves_to_the_start_of_the_full_reading(self):
        preview = InputPreview({
            "preedit": "日本語", "reading": "にほんご", "readingCursor": 4, "inputState": "selecting",
        })
        self.assertTrue(preview.apply({"keyCode": 115, "modifierFlags": 1}))
        self.assertTrue(preview.apply(translate(ord("a"), 0)))
        self.assertEqual(preview.visible_text, "aにほんご")

    def test_up_does_not_turn_composition_cancellation_into_candidate_cancellation(self):
        preview = self.preview({"preedit": "あ", "inputState": "composing"}, [(0xFF52, 0), (0xFF1B, 0)])
        self.assertEqual(preview.visible_text, "")


if __name__ == "__main__":
    unittest.main()
