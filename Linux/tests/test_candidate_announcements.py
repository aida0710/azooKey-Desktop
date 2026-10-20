"""Selection speech excludes scores and never changes document focus."""
import copy
import json
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.candidate_announcements import CandidateAnnouncements, candidate_announcement

FIXTURE = Path(__file__).parent / "fixtures/candidate_announcements.json"


class CandidateAnnouncementTests(unittest.TestCase):
    def setUp(self):
        self.snapshot = json.loads(FIXTURE.read_text())
        self.spoken = []
        self.announcements = CandidateAnnouncements(self.spoken.append)

    def test_opening_and_moving_to_another_reading_or_word_speaks_the_real_commit(self):
        self.announcements.update(self.snapshot)
        self.announcements.update({**self.snapshot, "selection": 1, "focusedNode": 11, "selectedPath": [11, 13]})
        self.announcements.update({**self.snapshot, "focusedNode": 12})
        self.assertEqual(self.spoken, [
            "変換候補 1 / 2。日本。読み ニホン。語 1 / 2。確定予定 日本に行く",
            "変換候補 2 / 2。日本。読み ニッポン。語 1 / 2。確定予定 日本に行く",
            "変換候補 1 / 2。に行く。読み ニイク。語 2 / 2。確定予定 日本に行く",
        ])

    def test_repainting_or_changing_scores_does_not_repeat_the_selection(self):
        self.announcements.update(self.snapshot)
        self.announcements.update({**self.snapshot, "generation": 2, "location": [20, 30, 0, 18]})
        changed = copy.deepcopy(self.snapshot)
        changed["nodes"][0]["scorePresentation"]["detailDescription"] = "変更した相対値"
        self.announcements.update(changed)
        self.assertEqual(len(self.spoken), 1)
        self.assertNotIn("スコア", self.spoken[0])

    def test_typing_does_not_announce_each_live_candidate_and_reopening_does_announce(self):
        for state in ("none", "composing", "suggesting", "previewing"):
            self.announcements.update({**self.snapshot, "inputState": state})
        self.assertEqual(len(self.spoken), 1)
        self.announcements.update({**self.snapshot, "nodes": []})
        self.announcements.update(self.snapshot)
        self.assertEqual(len(self.spoken), 2)
        self.announcements.update({**self.snapshot, "contextId": "another-synthetic-field"})
        self.assertEqual(len(self.spoken), 3)

    def test_partial_commit_reports_the_remaining_reading_without_inventing_text(self):
        snapshot = copy.deepcopy(self.snapshot)
        snapshot["candidates"][0] = {
            "index": 0, "text": "日本", "commitScope": {"consumedReading": "にほん", "remainingReading": "にいく"},
        }
        self.assertEqual(candidate_announcement(snapshot),
                         "変換候補 1 / 2。日本。読み ニホン。語 1 / 2。残る読み にいく")

    def test_invalid_selection_and_missing_focus_are_silent(self):
        for changes in ({"selection": 8}, {"focusedNode": 99}, {"inputState": "unknown"}):
            self.assertIsNone(candidate_announcement({**self.snapshot, **changes}))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateAnnouncementGTKTests(unittest.TestCase):
    def test_native_notification_preserves_document_focus_and_at_action_commits_once(self):
        from gi.repository import Atk, Gtk
        from azookey.tree_panel import TreePanel
        from Linux.tests.test_candidate_accessibility import CandidateAccessibilityTests

        document = Gtk.Window()
        entry = Gtk.Entry()
        document.add(entry)
        document.show_all()
        entry.grab_focus()
        committed = []
        panel = TreePanel(lambda *selection: committed.append(selection))
        self.addCleanup(document.destroy)
        self.addCleanup(panel.destroy)
        spoken = []
        panel.get_accessible().connect("notification", lambda _accessible, text, priority: spoken.append((text, priority)))
        snapshot = json.loads(FIXTURE.read_text())
        panel.update(snapshot)
        panel.update({**snapshot, "generation": 2})
        panel.update({**snapshot, "selection": 1, "focusedNode": 11, "selectedPath": [11, 13]})
        CandidateAccessibilityTests.flush_events()
        self.assertEqual(len(spoken), 2)
        self.assertIn("読み ニッポン", spoken[-1][0])
        self.assertEqual(spoken[-1][1], Atk.Live.POLITE)
        self.assertIs(document.get_focus(), entry)
        self.assertFalse(panel.get_accept_focus())
        button = panel.actions[("node", 11)]
        self.assertFalse(button.get_can_focus())
        self.assertTrue(button.get_accessible().do_action(0))
        CandidateAccessibilityTests.flush_events()
        self.assertEqual(committed, [("node", 11, True)])
        self.assertIs(document.get_focus(), entry)
        panel.hide()
        panel.update(snapshot)
        self.assertEqual(len(spoken), 3)


if __name__ == "__main__":
    unittest.main()
