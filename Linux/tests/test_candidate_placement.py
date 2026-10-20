"""Caret exclusion and usable candidate controls in constrained GTK work areas."""
import copy
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from azookey.candidate_placement import popup_placement


def overlaps_caret(frame, cursor):
    x, y, width, height = frame
    caret_x, caret_y, caret_width, caret_height = cursor
    return (x < caret_x + max(1, caret_width) and x + width > caret_x
            and y < caret_y + caret_height and y + height > caret_y)


class CandidatePlacementTests(unittest.TestCase):
    def assert_safe(self, placement, *, cursor, area):
        self.assertIsNotNone(placement)
        self.assertGreater(placement.width, 0)
        self.assertGreater(placement.height, 0)
        self.assertGreaterEqual(placement.x, area[0])
        self.assertGreaterEqual(placement.y, area[1])
        self.assertLessEqual(placement.x + placement.width, area[0] + area[2])
        self.assertLessEqual(placement.y + placement.height, area[1] + area[3])
        self.assertFalse(overlaps_caret(
            (placement.x, placement.y, placement.width, placement.height), cursor))

    def test_vm_menu_moves_beside_the_caret_when_neither_vertical_side_fits(self):
        cursor, area = (936, 506, 0, 35), (0, 32, 1280, 768)
        placement = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 505),
                                    preferred_side="above")
        self.assert_safe(placement, cursor=cursor, area=area)
        self.assertEqual(placement.side, "left")
        self.assertEqual((placement.width, placement.height), (420, 505))

    def test_corners_zero_width_carets_and_oversized_popups_keep_a_safe_visible_region(self):
        for area in ((0, 32, 1280, 768), (-640, 20, 640, 320), (0, 0, 320, 320)):
            left, top, width, height = area
            for x in (left, left + width // 2, left + width):
                for y in (top, top + height // 2, top + height - 35):
                    cursor = (x, y, 0, 35)
                    for popup_size in ((240, 100), (420, 505), (1600, 1200)):
                        with self.subTest(area=area, cursor=cursor, popup_size=popup_size):
                            placement = popup_placement(cursor=cursor, work_area=area, popup_size=popup_size)
                            self.assert_safe(placement, cursor=cursor, area=area)

    def test_constrained_popup_keeps_readable_width_and_uses_the_larger_vertical_region(self):
        cursor, area = (320, 142, 0, 35), (0, 0, 640, 320)
        placement = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 505))
        self.assert_safe(placement, cursor=cursor, area=area)
        self.assertEqual((placement.width, placement.height, placement.side), (420, 143, "below"))

    def test_selection_size_changes_keep_the_usable_side(self):
        cursor, area = (936, 506, 0, 35), (0, 32, 1280, 768)
        placement = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 505))
        smaller = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 300),
                                  preferred_side=placement.side)
        self.assertEqual(smaller.side, placement.side)
        self.assert_safe(smaller, cursor=cursor, area=area)

    def test_alignment_anchor_does_not_replace_the_real_caret_exclusion(self):
        cursor, area = (600, 350, 0, 35), (0, 32, 1280, 768)
        placement = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 505),
                                    column_anchor_x=100)
        self.assert_safe(placement, cursor=cursor, area=area)
        self.assertEqual((placement.x, placement.side), (601, "right"))

    def test_a_caret_covering_the_whole_work_area_has_no_safe_placement(self):
        self.assertIsNone(popup_placement(cursor=(0, 0, 320, 320), work_area=(0, 0, 320, 320),
                                         popup_size=(200, 100)))

    def test_full_height_caret_leaves_its_horizontal_region_available(self):
        cursor, area = (100, 0, 0, 320), (0, 0, 320, 320)
        placement = popup_placement(cursor=cursor, work_area=area, popup_size=(420, 505))
        self.assert_safe(placement, cursor=cursor, area=area)
        self.assertEqual((placement.width, placement.height, placement.side), (219, 320, "right"))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidatePopupPlacementTests(unittest.TestCase):
    def setUp(self):
        from azookey.tree_panel import TreePanel
        from gi.repository import Gtk
        from Linux.tests.test_candidate_presentation import CandidatePresentationTests

        self.actions = []
        self.document = Gtk.Window()
        self.entry = Gtk.Entry()
        self.document.add(self.entry)
        self.document.show_all()
        self.entry.grab_focus()
        self.panel = TreePanel(lambda *action: self.actions.append(action))
        self.snapshot = CandidatePresentationTests.make_snapshot()
        self.snapshot["candidatePage"]["items"] *= 3
        for index, item in enumerate(self.snapshot["candidatePage"]["items"]):
            self.snapshot["candidatePage"]["items"][index] = {**item, "index": index}
        self.snapshot["candidatePage"]["totalCount"] = 9
        self.addCleanup(self.document.destroy)
        self.addCleanup(self.panel.destroy)

    def paint(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests
        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)

    def assert_visible_beside_caret(self, area, *, cursor=None):
        self.paint()
        self.paint()  # Observe allocation caused by a bounded viewport as well.
        x, y = self.panel.get_position()
        width, height = self.panel.get_size()
        self.assertGreaterEqual(x, area.x)
        self.assertGreaterEqual(y, area.y)
        self.assertLessEqual(x + width, area.x + area.width)
        self.assertLessEqual(y + height, area.y + area.height)
        cursor = cursor or self.panel.location
        self.assertFalse(overlaps_caret((x, y, width, height), cursor),
                         (cursor, (x, y, width, height)))
        self.assertEqual(self.panel.layout_diagnostics["popup"], [x, y, width, height])
        self.assertEqual(self.panel.layout_diagnostics["cursor"], cursor)
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertFalse(self.panel.get_accept_focus())
        self.assertFalse(self.panel.get_focus_on_map())

    def test_tall_menu_uses_actual_allocation_beside_the_caret(self):
        area = self.panel.get_display().get_monitor(0).get_workarea()
        self.panel.location = (area.x + area.width * 3 // 4, area.y + area.height * 3 // 5, 0, 35)
        self.panel.update(self.snapshot)
        self.assert_visible_beside_caret(area)
        self.assertEqual(self.actions, [])
        previous_confirm = self.panel.navigation.confirm
        self.panel.navigation.row_buttons[1].clicked()
        self.assertEqual(self.actions, [("select", 1, False)])
        self.panel.update({**self.snapshot, "selection": 1, "focusedNode": 1, "selectedPath": [1], "generation": 2})
        self.assert_visible_beside_caret(area)
        previous_confirm.clicked()
        self.assertEqual(self.actions, [("select", 1, False)])
        confirm = self.panel.navigation.confirm
        confirm.get_accessible().do_action(0)
        self.paint()
        confirm.get_accessible().do_action(0)
        self.paint()
        self.assertEqual(self.actions, [("select", 1, False), ("select", 1, True)])
        self.assertIs(self.document.get_focus(), self.entry)

    def test_large_text_at_each_corner_remains_readable_without_covering_the_caret(self):
        area = self.panel.get_display().get_monitor(0).get_workarea()
        for x in (area.x, area.x + area.width):
            for y in (area.y, area.y + area.height - 35):
                with self.subTest(x=x, y=y):
                    self.panel.dismiss()
                    self.panel.location = (x, y, 0, 35)
                    self.panel.update({**self.snapshot, "candidateTextSize": "large"})
                    self.assert_visible_beside_caret(area)
                    self.assertEqual(self.panel.font_size, 24)
        self.assertEqual(self.actions, [])

    def test_real_caret_remains_excluded_when_alignment_expires_and_the_work_area_changes(self):
        from azookey.engine import Engine
        from azookey.preedit_anchor import PreeditAnchor

        anchor = PreeditAnchor(lambda text: len(text) * 20)
        anchor.locate((100, 350, 0, 35))
        anchor.update(self.snapshot["preedit"], len(self.snapshot["preedit"]))
        anchor.locate((600, 350, 0, 35))
        engine = SimpleNamespace(anchor=anchor, panel=self.panel)
        snapshot = Engine.positioned_snapshot(engine, self.snapshot)
        self.assertIsNotNone(snapshot["wordGeometry"])
        self.assertEqual(self.panel.location, (100, 350, 0, 35))
        self.assertEqual(self.panel.caret_location, (600, 350, 0, 35))
        # Keep both vertical regions too short for the menu. A taller Xvfb
        # screen can correctly keep the popup aligned below.
        area = SimpleNamespace(x=0, y=0, width=1280, height=800)
        with patch.object(self.panel, "work_area", return_value=area):
            self.panel.update(snapshot)
            self.assert_visible_beside_caret(area, cursor=anchor.location)
            self.assertFalse(self.panel.aligned, "Moving sideways must not claim document alignment")
            self.assertEqual(self.panel.layout_diagnostics["side"], "right")

        area = SimpleNamespace(x=640, y=0, width=640, height=320)
        with patch.object(self.panel, "work_area", return_value=area):
            for cursor in ((960, 140, 0, 35), (1279, 260, 0, 35), (640, 0, 0, 35)):
                anchor.locate(cursor)
                snapshot = Engine.positioned_snapshot(engine, self.snapshot)
                self.assertIsNone(snapshot["wordGeometry"])
                self.assertEqual(self.panel.location, cursor)
                self.assertEqual(self.panel.caret_location, cursor)
                self.panel.update(snapshot)
                self.assert_visible_beside_caret(area, cursor=cursor)
        self.assertEqual(self.actions, [])

    def test_short_work_area_keeps_full_text_and_confirmation_reachable_without_focus(self):
        for width in (640, 320):
            for size in ("standard", "large"):
                with self.subTest(width=width, size=size):
                    self.assert_constrained_confirmation(width=width, size=size)

    def assert_constrained_confirmation(self, *, width, size):
        from gi.repository import Atk

        area = SimpleNamespace(x=0, y=0, width=width, height=320)
        with patch.object(self.panel, "work_area", return_value=area):
            self.panel.dismiss()
            self.panel.location = (width // 2, 142, 0, 35)
            self.panel.update({**self.snapshot, "candidateTextSize": size})
            self.assert_visible_beside_caret(area)
            self.assertEqual(self.panel.navigation.row_buttons[1].text_label.get_text(),
                             self.snapshot["candidatePage"]["items"][1]["text"])
            adjustment = self.panel.viewport.get_vadjustment()
            self.assertGreater(adjustment.get_upper(), adjustment.get_page_size())
            confirm = self.panel.navigation.confirm
            adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
            self.paint()
            rectangle = confirm.get_accessible().get_extents(Atk.CoordType.SCREEN)
            popup_x, popup_y = self.panel.get_position()
            width, height = self.panel.get_size()
            self.assertGreaterEqual(rectangle.y, popup_y)
            self.assertLessEqual(rectangle.y + rectangle.height, popup_y + height)
            self.assertGreaterEqual(rectangle.x, popup_x)
            self.assertLessEqual(rectangle.x + rectangle.width, popup_x + width)
            self.assertTrue(confirm.get_accessible().do_action(0))
            self.paint()
            self.assertEqual(self.actions, [("select", 0, True)])
            self.assertIs(self.document.get_focus(), self.entry)
            self.actions.clear()

    def test_constrained_scroll_survives_pending_but_new_context_starts_at_the_candidate(self):
        area = SimpleNamespace(x=0, y=0, width=640, height=320)
        with patch.object(self.panel, "work_area", return_value=area):
            self.panel.location = (320, 142, 0, 35)
            self.panel.update(self.snapshot)
            self.assert_visible_beside_caret(area)
            adjustment = self.panel.viewport.get_vadjustment()
            adjustment.set_value(adjustment.get_upper() - adjustment.get_page_size())
            self.paint()
            scroll = adjustment.get_value()
            self.assertGreater(scroll, 0)
            self.panel.update(copy.deepcopy(self.snapshot))
            self.assert_visible_beside_caret(area)
            self.assertEqual(adjustment.get_value(), scroll)
            self.panel.suspend()
            self.panel.update(self.snapshot)
            self.assert_visible_beside_caret(area)
            self.assertEqual(adjustment.get_value(), scroll)
            old_confirm = self.panel.navigation.confirm
            self.panel.update({**self.snapshot, "contextId": "other-document"})
            self.assert_visible_beside_caret(area)
            self.assertEqual(adjustment.get_value(), 0)
            old_confirm.clicked()
            self.assertEqual(self.actions, [])

    def test_same_candidate_update_and_suspend_keep_scroll_position_and_safe_side(self):
        area = self.panel.get_display().get_monitor(0).get_workarea()
        self.panel.location = (area.x + area.width * 3 // 4, area.y + area.height * 3 // 5, 0, 35)
        self.panel.update(self.snapshot)
        self.assert_visible_beside_caret(area)
        adjustment = self.panel.navigation.scroll.get_vadjustment()
        adjustment.set_value(50)
        self.paint()
        scroll = adjustment.get_value()
        side = self.panel.placement_side
        row = self.panel.navigation.row_buttons[1]
        self.panel.update(copy.deepcopy(self.snapshot))
        self.assert_visible_beside_caret(area)
        self.assertEqual(self.panel.placement_side, side)
        self.assertIs(self.panel.navigation.row_buttons[1], row)
        self.assertEqual(adjustment.get_value(), scroll)
        self.panel.suspend()
        self.panel.update(self.snapshot)
        self.assert_visible_beside_caret(area)
        self.assertEqual(self.panel.placement_side, side)
        self.assertEqual(adjustment.get_value(), scroll)
        self.assertEqual(self.actions, [])
