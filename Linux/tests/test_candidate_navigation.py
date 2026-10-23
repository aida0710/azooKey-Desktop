"""Full candidate pages expose all source indices without focusing or stale commits."""
import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateNavigationTests(unittest.TestCase):
    def setUp(self):
        from azookey.candidate_navigation import CandidateNavigation
        from gi.repository import Gtk

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

    def snapshot(self, context="original", *, numbers=True):
        from candidate_core import displayed

        start = self.selection // 9 * 9
        return displayed({"contextId": context, "generation": 1, "selection": self.selection,
                "inputState": "selecting", "showCandidateIndex": numbers, "candidatePage": {
                    "position": self.selection + 1, "totalCount": 500, "start": start,
                    "previousIndex": max(0, start - 9) if start else None,
                    "nextIndex": start + 9 if start + 9 < 500 else None,
                    "items": [{"index": index, "text": f"候補{index}", "reading": f"コウホ{index}",
                               "detailDescription": f"確定予定: 候補{index}"}
                              for index in range(start, min(500, start + 9))]}})

    def refresh(self):
        self.navigation.update(self.snapshot(), font_size=18, list_height=160)

    def select(self, operation, index, submit):
        self.actions.append((operation, index, submit))
        if not submit:
            self.selection = index
            self.refresh()

    def test_footer_contains_only_right_aligned_position_and_pages_keep_row_selection(self):
        self.assertEqual(self.navigation.footer.get_children(), [self.navigation.status])
        self.assertEqual(self.navigation.status.get_xalign(), 1)
        self.assertEqual(self.navigation.status.get_text(), "1/500")
        self.assertIn("1 / 500", self.navigation.rows.get_accessible().get_name())
        self.assertEqual(set(self.navigation.controls), {"toggle"})
        for name in ("confirm", "previous", "next"):
            self.assertFalse(hasattr(self.navigation, name))
        for start in range(0, 500, 9):
            self.selection = start
            self.refresh()
            self.assertLessEqual(len(self.navigation.row_buttons), 9)
            self.assertEqual(self.navigation.status.get_text(), f"{start + 1}/500")
        last = self.navigation.row_buttons[-1]
        self.assertEqual(last.text_label.get_text(), "候補499")
        self.assertEqual(last.number_label.get_text(), "5")
        self.assertFalse(last.get_can_focus())
        last.clicked()
        self.assertEqual(self.actions, [("select", 499, False)])

    def test_removed_row_and_old_press_cannot_confirm_a_new_context(self):
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
        self.assertEqual(self.actions, [("select", 0, False)])

    def test_selection_change_keeps_accessible_rows_and_rejects_an_old_press(self):
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
        first = self.navigation.row_buttons[0]
        self.assertIn("コウホ0", first.get_accessible().get_name())
        self.assertIn("確定予定", first.get_accessible().get_description())
        self.navigation.toggle.clicked()
        self.assertFalse(self.navigation.scroll.get_visible())
        self.assertFalse(hasattr(self.navigation, "next"))
        self.assertEqual(self.actions, [])

    def test_disabling_number_shortcuts_removes_prefixes_without_changing_pointer_actions(self):
        self.assertEqual(self.navigation.row_buttons[0].number_label.get_text(), "1")
        old = self.navigation.row_buttons[0]
        self.navigation.update(self.snapshot(numbers=False), font_size=18, list_height=160)
        self.assertEqual([button.text_label.get_text() for button in self.navigation.row_buttons],
                         [f"候補{index}" for index in range(9)])
        old.clicked()
        self.assertEqual(self.actions, [])
        self.navigation.row_buttons[1].clicked()
        self.assertEqual(self.actions, [("select", 1, False)])


if __name__ == "__main__":
    unittest.main()
