import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.ai_preview import AITransformationPreview


class AITransformationPreviewTests(unittest.TestCase):
    def test_repeated_submit_waits_for_the_current_request(self):
        preview = AITransformationPreview()
        request = preview.begin()
        self.assertIsNone(preview.begin())
        self.assertTrue(preview.complete(request, "本文"))
        self.assertEqual(preview.applicable_text, "本文")

    def test_regeneration_clears_the_previous_text_including_on_failure(self):
        for response in (None, ""):
            with self.subTest(response=response):
                preview = AITransformationPreview()
                preview.complete(preview.begin(), "前の本文")
                request = preview.begin()
                self.assertIsNone(preview.applicable_text)
                self.assertTrue(preview.is_loading)
                preview.complete(request, response)
                self.assertFalse(preview.is_loading)
                self.assertIsNone(preview.applicable_text)

    def test_old_reply_cannot_end_or_replace_the_new_request(self):
        preview = AITransformationPreview()
        first = preview.begin()
        preview.invalidate()
        second = preview.begin()
        self.assertFalse(preview.complete(first, "古い本文"))
        self.assertTrue(preview.is_loading)
        self.assertTrue(preview.complete(second, "新しい本文"))
        self.assertFalse(preview.complete(first, None))
        self.assertEqual(preview.applicable_text, "新しい本文")

    def test_edit_or_close_invalidates_a_completed_preview(self):
        preview = AITransformationPreview()
        request = preview.begin()
        preview.complete(request, "本文")
        preview.invalidate()
        self.assertIsNone(preview.applicable_text)
        self.assertFalse(preview.complete(request, "遅れた本文"))
