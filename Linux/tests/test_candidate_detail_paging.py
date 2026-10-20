"""Every detail line becomes fully readable when paging in either direction."""
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Detect a stopped display; successful checks wait for the actual rendered frame.
FRAME_WAIT_TIMEOUT_MS = 5000


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidateDetailPagingTests(unittest.TestCase):
    def setUp(self):
        from azookey.candidate_detail import CandidateDetail
        from gi.repository import Gtk

        # Match the constrained detail height observed at 200% in the VM.
        self.detail = CandidateDetail(minimum_height=107, maximum_height=107)
        self.window = Gtk.Window(type=Gtk.WindowType.POPUP)
        self.window.set_accept_focus(False)
        self.window.add(self.detail)
        self.text = "\n".join(f"{number}行目の候補と読み" for number in range(1, 10))

    def tearDown(self):
        self.window.destroy()
        self.flush()

    @staticmethod
    def flush():
        from gi.repository import GLib

        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def draw_frame(self):
        from gi.repository import Gdk, GLib

        loop = GLib.MainLoop()
        frame_clock = self.window.get_frame_clock()
        painted = []

        def after_paint(_clock):
            painted.append(True)
            loop.quit()

        handler = frame_clock.connect("after-paint", after_paint)
        timeout = GLib.timeout_add(FRAME_WAIT_TIMEOUT_MS, loop.quit)
        self.window.queue_draw()
        frame_clock.request_phase(Gdk.FrameClockPhase.PAINT)
        loop.run()
        frame_clock.disconnect(handler)
        if painted:
            GLib.source_remove(timeout)
        self.assertTrue(painted, "GTK did not finish rendering the changed viewport")

    def visible_character_offsets(self):
        from gi.repository import Atk

        viewport = self.detail.get_child()
        # GtkViewport's ATK origin can be unavailable after scrolling its child.
        left, top = viewport.translate_coordinates(self.window, 0, 0)
        right = left + viewport.get_allocated_width()
        bottom = top + viewport.get_allocated_height()
        accessible = self.detail.label.get_accessible()
        visible = set()
        for offset, character in enumerate(self.text):
            if character.isspace():
                continue
            bounds = accessible.get_character_extents(offset, Atk.CoordType.WINDOW)
            if (bounds.x >= left and bounds.y >= top
                    and bounds.x + bounds.width <= right and bounds.y + bounds.height <= bottom):
                visible.add(offset)
        return visible

    def assert_every_character_is_readable(self, *, forward, font_size):
        self.detail.update(self.text, font_size=font_size, width=516)
        self.window.show_all()
        self.draw_frame()
        adjustment = self.detail.get_vadjustment()
        self.assertGreater(adjustment.get_upper(), adjustment.get_page_size())
        limit = adjustment.get_upper() - adjustment.get_page_size()
        adjustment.set_value(0 if forward else limit)
        self.draw_frame()
        visible = self.visible_character_offsets()
        positions = [adjustment.get_value()]
        while adjustment.get_value() != (limit if forward else 0):
            previous = adjustment.get_value()
            self.detail.scroll_page(forward)
            self.draw_frame()
            current = adjustment.get_value()
            self.assertNotEqual(current, previous, "paging must advance until the end")
            self.assertGreaterEqual(current, 0)
            self.assertLessEqual(current, limit)
            positions.append(current)
            visible.update(self.visible_character_offsets())
        expected = {offset for offset, character in enumerate(self.text) if not character.isspace()}
        self.assertEqual(expected - visible, set(), f"characters stay clipped at page boundaries: {positions}")
        self.assertEqual(self.detail.label.get_text(), self.text)
        self.assertFalse(self.window.get_accept_focus())
        self.assertFalse(self.detail.get_can_focus())

    def test_page_down_alone_shows_every_character_without_reducing_the_font(self):
        for font_size in (18, 24):
            with self.subTest(font_size=font_size):
                self.assert_every_character_is_readable(forward=True, font_size=font_size)

    def test_page_up_alone_shows_every_character_without_reducing_the_font(self):
        for font_size in (18, 24):
            with self.subTest(font_size=font_size):
                self.assert_every_character_is_readable(forward=False, font_size=font_size)


if __name__ == "__main__":
    unittest.main()
