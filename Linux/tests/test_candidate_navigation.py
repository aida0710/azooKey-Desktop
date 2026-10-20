"""Full candidate pages expose all source indices without focusing or stale commits."""
import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateNavigationTests(unittest.TestCase):
    def setUp(self):
        from gi.repository import Gtk
        from azookey.candidate_navigation import CandidateNavigation

        self.actions = []
        self.previews = []
        self.selection = 0
        self.navigation = CandidateNavigation(self.select, self.refresh, self.previews.append)
        self.window = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.window.set_accept_focus(False)
        self.window.add(self.navigation)
        self.refresh()
        self.window.show_all()

    def tearDown(self):
        self.window.destroy()

    def snapshot(self, context="original"):
        start = self.selection // 9 * 9
        return {"contextId": context, "generation": 1, "selection": self.selection,
                "showCandidateIndex": True, "candidatePage": {
                    "position": self.selection + 1, "totalCount": 500, "start": start,
                    "previousIndex": max(0, start - 9) if start else None,
                    "nextIndex": start + 9 if start + 9 < 500 else None,
                    "items": [{"index": index, "text": f"候補{index}", "reading": f"コウホ{index}",
                               "detailDescription": f"確定予定: 候補{index}"}
                              for index in range(start, min(500, start + 9))]}}

    def refresh(self):
        self.navigation.update(self.snapshot(), font_size=18, list_height=160)

    def select(self, operation, index, submit):
        self.actions.append((operation, index, submit))
        if not submit:
            self.selection = index
            self.refresh()

    def test_pointer_reaches_last_candidate_without_expanding_hundreds_of_rows(self):
        self.assertIn("1 / 500", self.navigation.status.get_text())
        self.navigation.toggle.clicked()
        for _ in range(56):
            if not self.navigation.next.get_sensitive():
                break
            self.navigation.next.clicked()
            self.assertLessEqual(len(self.navigation.row_buttons), 9)
        self.assertFalse(self.navigation.next.get_sensitive())
        self.assertIn("496 / 500", self.navigation.status.get_text())
        last = self.navigation.row_buttons[-1]
        self.assertEqual(last.get_child().get_text(), "5. 候補499")
        self.assertFalse(last.get_can_focus())
        last.clicked()
        self.assertEqual(self.actions[-1], ("select", 499, True))
        self.assertEqual(sum(submit for _, _, submit in self.actions), 1)

    def test_removed_row_and_old_press_cannot_confirm_a_new_context(self):
        self.navigation.toggle.clicked()
        old = self.navigation.row_buttons[0]
        self.navigation.update(self.snapshot("new-context"), font_size=18, list_height=160)
        old.clicked()
        self.assertEqual(self.actions, [])
        current = self.navigation.row_buttons[0]
        current.pressed_token = ("original", 1, 0)
        current.clicked()
        self.assertEqual(self.actions, [])
        current.pressed_token = None
        current.clicked()
        self.assertEqual(self.actions, [("select", 0, True)])

    def test_selection_change_keeps_accessible_rows_and_rejects_an_old_press(self):
        self.navigation.toggle.clicked()
        first = self.navigation.row_buttons[0]
        second = self.navigation.row_buttons[1]
        first.pressed_token = first.activation_token
        self.selection = 1
        self.navigation.update({**self.snapshot(), "generation": 2}, font_size=18, list_height=160)
        self.assertIs(first, self.navigation.row_buttons[0])
        self.assertIs(second, self.navigation.row_buttons[1])
        self.assertFalse(first.selected)
        self.assertTrue(second.selected)
        first.clicked()
        self.assertEqual(self.actions, [])

    def test_list_can_close_without_committing_and_reading_is_accessible(self):
        self.navigation.toggle.clicked()
        first = self.navigation.row_buttons[0]
        self.assertIn("コウホ0", first.get_accessible().get_name())
        self.assertIn("確定予定", first.get_accessible().get_description())
        self.navigation.toggle.clicked()
        self.assertFalse(self.navigation.scroll.get_visible())
        self.navigation.next.clicked()
        self.assertEqual(self.actions, [])


if __name__ == "__main__":
    unittest.main()
