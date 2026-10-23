"""X11 IBus coordinates and GTK work areas must use the same pixel units."""
import copy
import os
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class CandidateCoordinateTests(unittest.TestCase):
    def test_unit_scale_preserves_global_cursor_origin_and_dimensions(self):
        from azookey.ibus_coordinates import logical_cursor_rectangle
        for rectangle in ((936, 506, 0, 35), (-1280, -720, 1, 24), (1920, 100, 3, 29)):
            with self.subTest(rectangle=rectangle):
                self.assertEqual(logical_cursor_rectangle(rectangle, scale_factor=1), rectangle)

    def test_double_scale_includes_odd_pixels_and_negative_global_origins(self):
        from azookey.ibus_coordinates import logical_cursor_rectangle
        examples = (
            ((1632, 660, 0, 70), (816, 330, 0, 35)),
            ((1633, 661, 0, 71), (816, 330, 0, 36)),
            ((-1919, -719, 3, 31), (-960, -360, 2, 16)),
            ((3201, 101, 3, 29), (1600, 50, 2, 15)),
        )
        for physical, logical in examples:
            with self.subTest(physical=physical):
                self.assertEqual(logical_cursor_rectangle(physical, scale_factor=2), logical)


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidateScalingTests(unittest.TestCase):
    def setUp(self):
        from candidate_core import core_tree_panel
        from gi.repository import Gtk
        from Linux.tests.test_candidate_presentation import CandidatePresentationTests

        self.actions = []
        self.document = Gtk.Window()
        self.entry = Gtk.Entry()
        self.document.add(self.entry)
        self.document.show_all()
        self.entry.grab_focus()
        self.panel = core_tree_panel(lambda *action: self.actions.append(action))
        self.snapshot = CandidatePresentationTests.make_snapshot()
        self.scale = self.panel.get_scale_factor()
        self.area = self.panel.get_display().get_monitor(0).get_workarea()
        self.addCleanup(self.panel.destroy)
        self.addCleanup(self.document.destroy)

    def paint(self):
        from gi.repository import GLib
        from Linux.tests.test_candidate_theme import CandidateThemeTests
        CandidateThemeTests.wait_for_paint(self.panel, GLib)
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        CandidateThemeTests.wait_for_paint(self.panel, GLib)

    def place_physical_caret(self, logical):
        physical = tuple(value * self.scale for value in logical)
        self.panel.location = physical
        self.panel.caret_location = physical
        return physical

    def assert_physical_placement(self, cursor):
        from Linux.tests.test_candidate_placement import overlaps_caret
        self.paint()
        x, y = self.panel.get_position()
        width, height = self.panel.get_size()
        self.assertGreaterEqual(x, self.area.x)
        self.assertGreaterEqual(y, self.area.y)
        self.assertLessEqual(x + width, self.area.x + self.area.width)
        self.assertLessEqual(y + height, self.area.y + self.area.height)
        physical_popup = tuple(value * self.scale for value in (x, y, width, height))
        self.assertFalse(overlaps_caret(physical_popup, cursor), (physical_popup, cursor))
        self.assertIs(self.document.get_focus(), self.entry)
        self.assertFalse(self.panel.get_accept_focus())
        self.assertEqual(self.panel.location, cursor, "GTK must not rewrite the location sent to GNOME")

    def test_live_and_menu_exclude_the_physical_caret_at_standard_and_large_sizes(self):
        logical = (self.area.x + self.area.width * 4 // 5,
                   self.area.y + self.area.height * 3 // 5, 0, 35)
        cursor = self.place_physical_caret(logical)
        for size in ("standard", "large"):
            for state in ("composing", "selecting"):
                with self.subTest(scale=self.scale, size=size, state=state):
                    self.panel.update({**self.snapshot, "inputState": state, "candidateTextSize": size})
                    self.assert_physical_placement(cursor)
                    self.assertEqual(self.panel.current_caret, logical)
        self.assertEqual(self.actions, [])

    def test_alignment_uses_logical_word_widths_without_modifying_shared_geometry(self):
        # Fit below the cursor on both 1280x800@100% and 1920x1080@200%.
        logical_start = (self.area.x + 80, self.area.y + 20, 0, 30)
        logical_caret = (logical_start[0] + 300, logical_start[1], 0, 30)
        self.panel.location = tuple(value * self.scale for value in logical_start)
        self.panel.caret_location = tuple(value * self.scale for value in logical_caret)
        geometry = {"widths": [300 * self.scale], "fontSize": 24}
        snapshot = {**self.snapshot, "wordGeometry": copy.deepcopy(geometry), "inputState": "composing"}
        self.panel.update(snapshot)
        self.paint()
        self.assertTrue(self.panel.aligned)
        # The word starts at its document word and leaves Core's gap before the next one.
        self.assertEqual(self.panel.rectangles[0][4], 300 - 6)
        first_word = self.panel.layout["tree"]["nodes"][0]["frame"]
        self.assertEqual(self.panel.get_position()[0] + first_word["x"], logical_start[0])
        self.assertEqual(snapshot["wordGeometry"], geometry)
        self.assertEqual(self.panel.location, tuple(value * self.scale for value in logical_start))
        self.assertEqual(self.panel.caret_location, tuple(value * self.scale for value in logical_caret))

    def test_scaled_selection_preserves_focus_and_commits_only_once(self):
        cursor = self.place_physical_caret((
            self.area.x + self.area.width * 4 // 5, self.area.y + self.area.height * 3 // 5, 0, 35))
        self.panel.update(self.snapshot)
        self.assert_physical_placement(cursor)
        old_confirm = self.panel.navigation.confirm
        self.panel.navigation.row_buttons[1].clicked()
        self.assertEqual(self.actions, [("select", 1, False)])
        self.panel.update({**self.snapshot, "selection": 1, "focusedNode": 1,
                           "selectedPath": [1], "generation": 2})
        self.assert_physical_placement(cursor)
        old_confirm.clicked()
        self.assertEqual(self.actions, [("select", 1, False)])
        confirm = self.panel.navigation.confirm.get_accessible()
        confirm.do_action(0)
        self.paint()
        confirm.do_action(0)
        self.paint()
        self.assertEqual(self.actions, [("select", 1, False), ("select", 1, True)])

    def test_monitor_lookup_converts_global_origins_before_choosing_the_work_area(self):
        # Model monitor origins separately from the actual single-display GTK test.
        display = type("X11Display", (), {})()
        for logical_x, logical_y in ((-1200, -600), (100, 200), (1700, 100)):
            with self.subTest(logical=(logical_x, logical_y)):
                expected_area = SimpleNamespace(x=logical_x - 100, y=logical_y - 20, width=960, height=540)
                display.get_monitor_at_point = lambda x, y: (
                    SimpleNamespace(get_workarea=lambda: expected_area)
                    if (x, y) == (logical_x, logical_y) else None)
                self.panel.caret_location = (logical_x * 2, logical_y * 2, 0, 70)
                with patch.object(self.panel, "get_display", return_value=display), \
                     patch.object(self.panel, "get_scale_factor", return_value=2):
                    self.assertIs(self.panel.work_area(), expected_area)

    def test_non_x11_locations_are_not_divided_by_the_gtk_window_scale(self):
        self.panel.caret_location = (400, 200, 0, 35)
        display = type("WaylandDisplay", (), {})()
        with patch.object(self.panel, "get_display", return_value=display), \
             patch.object(self.panel, "get_scale_factor", return_value=2):
            self.assertEqual(self.panel.current_caret, (400, 200, 0, 35))

    def test_current_scale_is_used_without_reusing_a_previous_conversion(self):
        self.panel.caret_location = (1600, 660, 0, 70)
        with patch.object(self.panel, "get_scale_factor", return_value=1):
            self.assertEqual(self.panel.current_caret, (1600, 660, 0, 70))
        with patch.object(self.panel, "get_scale_factor", return_value=2):
            self.assertEqual(self.panel.current_caret, (800, 330, 0, 35))
        self.assertEqual(self.panel.caret_location, (1600, 660, 0, 70))

    def test_display_change_repositions_visible_candidates_without_restoring_pending_candidates(self):
        self.place_physical_caret((self.area.x + 80, self.area.y + 20, 0, 35))
        self.panel.update(self.snapshot)
        self.paint()
        with patch.object(self.panel, "update") as update:
            self.panel.get_screen().emit("monitors-changed")
            update.assert_called_once_with(self.panel.snapshot)
            update.reset_mock()
            self.panel.suspend()
            self.panel.get_screen().emit("monitors-changed")
            update.assert_not_called()
