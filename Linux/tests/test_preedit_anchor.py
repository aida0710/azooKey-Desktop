import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.preedit_anchor import PreeditAnchor


class PreeditAnchorTests(unittest.TestCase):
    def test_tracks_start_instead_of_end_and_uses_measured_advance(self):
        anchor = PreeditAnchor(lambda text: len(text) * 10)
        anchor.locate((100, 200, 1, 24))
        anchor.update("このように確率的に", 9)
        anchor.locate((280, 200, 1, 24))
        geometry = anchor.geometry(["このように", "確率的に"])
        self.assertEqual(geometry["widths"], [100, 80])
        self.assertEqual(anchor.position, (100, 200, 1, 24))
        anchor.update("このように確率的に中", 10)
        self.assertEqual(anchor.position[0], 100)
        anchor.locate((300, 200, 1, 24))
        self.assertEqual(anchor.geometry(["このように", "確率的に", "中"])["widths"], [100, 80, 20])

    def test_cursor_inside_preedit_does_not_become_new_start(self):
        anchor = PreeditAnchor(lambda text: len(text) * 10)
        anchor.locate((100, 200, 1, 24))
        anchor.update("日本語", 3)
        anchor.locate((160, 200, 1, 24))
        anchor.update("日本語", 1)
        anchor.locate((120, 200, 1, 24))
        self.assertEqual(anchor.geometry(["日本", "語"])["widths"], [40, 20])

    def test_japanese_fallback_font_height_and_duplicate_caret_notifications(self):
        anchor = PreeditAnchor(lambda text: 8 if text == "k" else len(text) * 13)
        anchor.locate((31, 246, 0, 18))
        anchor.update("k", 1)
        anchor.locate((31, 246, 0, 18))
        anchor.locate((40, 245, 0, 18))
        anchor.update("こ", 1)
        anchor.locate((46, 245, 0, 23))
        self.assertEqual(anchor.position, (31, 245, 0, 23))
        self.assertAlmostEqual(anchor.geometry(["こ"])["widths"][0], 15)

    def test_wrap_focus_reset_and_partial_commit_discard_stale_geometry(self):
        anchor = PreeditAnchor(lambda text: len(text) * 10)
        anchor.locate((100, 200, 1, 24))
        anchor.update("日本語", 3)
        anchor.locate((120, 224, 1, 24))
        self.assertIsNone(anchor.geometry(["日本", "語"]))
        self.assertEqual(anchor.position, (120, 224, 1, 24))
        anchor.update("", 0)
        anchor.locate((400, 300, 1, 24))
        anchor.update("次", 1)
        anchor.locate((420, 300, 1, 24))
        self.assertEqual(anchor.position[0], 400)
        anchor.update("続き", 2, committed=True)
        self.assertIsNone(anchor.geometry(["続き"]))

    def test_mismatching_candidate_and_no_location_do_not_claim_alignment(self):
        anchor = PreeditAnchor(lambda text: len(text) * 10)
        anchor.update("にほん", 3)
        self.assertIsNone(anchor.geometry(["日本"]))
        self.assertIsNone(anchor.geometry(["にほん"]))

