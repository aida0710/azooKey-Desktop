"""Contrast measurements and live desktop-appearance changes."""
import json
import os
from pathlib import Path
import subprocess
import sys
import time
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Linux"))

from azookey.candidate_palette_data import PALETTES


def luminance(color):
    components = (int(color[index:index + 2], 16) / 255 for index in (1, 3, 5))
    linear = [value / 12.92 if value <= 0.04045 else ((value + 0.055) / 1.055) ** 2.4 for value in components]
    return sum(value * weight for value, weight in zip(linear, (0.2126, 0.7152, 0.0722)))


def contrast(first, second):
    low, high = sorted((luminance(first), luminance(second)))
    return (high + 0.05) / (low + 0.05)


class CandidatePaletteTests(unittest.TestCase):
    def test_all_renderer_palettes_are_generated_from_the_same_srgb_values(self):
        subprocess.run([sys.executable, str(ROOT / "Tools/generate-candidate-palettes.py"), "--check"], check=True)

    def test_text_selection_and_each_score_badge_meet_the_design_contrast_target(self):
        measurements = {}
        pairs = [("text", "background"), ("text", "surface"), ("secondaryText", "background"),
                 ("secondaryText", "surface"), ("selectionText", "selection"),
                 ("scoreText", "scoreLow"), ("scoreText", "scoreHigh"), ("scoreText", "scoreUnknown")]
        for mode, palette in PALETTES.items():
            measurements[mode] = {}
            for foreground, background in pairs:
                ratio = contrast(palette[foreground], palette[background])
                measurements[mode][foreground + "/" + background] = ratio
                with self.subTest(mode=mode, foreground=foreground, background=background):
                    self.assertGreaterEqual(ratio, 4.5)
            self.assertGreaterEqual(contrast(palette["border"], palette["background"]), 3)
        if output := os.environ.get("AZOOKEY_TREE_SNAPSHOT_DIR"):
            Path(output, "contrast-srgb.json").write_text(json.dumps(measurements, indent=2) + "\n")


@unittest.skipUnless(os.environ.get("DISPLAY") and os.environ.get("GSETTINGS_BACKEND") == "memory",
                     "requires an isolated Xvfb display and the memory GSettings backend")
class CandidateThemeTests(unittest.TestCase):
    def test_gtk_theme_and_dark_preference_work_without_gnome_preferences(self):
        from azookey.candidate_theme import appearance_name
        for theme, prefer_dark, expected in [
            ("Adwaita", False, "light"), ("Adwaita-dark", False, "dark"), ("Adwaita", True, "dark"),
            ("HighContrast", False, "highContrastLight"), ("HighContrastInverse", False, "highContrastDark"),
        ]:
            self.assertEqual(appearance_name(color_scheme="default", theme_name=theme, prefer_dark=prefer_dark,
                                             high_contrast=False, dark_background=False), expected)

    def test_desktop_appearance_changes_preserve_candidate_actions_focus_and_details(self):
        import cairo
        from candidate_core import core_tree_panel
        from gi.repository import Gdk, GLib, Gtk, Pango
        submitted = []
        document = Gtk.Window()
        entry = Gtk.Entry()
        document.add(entry)
        document.show_all()
        entry.grab_focus()
        panel = core_tree_panel(lambda *args: submitted.append(args))
        self.addCleanup(panel.destroy)
        self.addCleanup(document.destroy)
        snapshot = {
            "nodes": [
                {"id": 0, "text": "日本", "reading": "にほん", "parent": None, "terminals": [], "relativeScore": 90},
                {"id": 1, "text": "語", "reading": "ご", "parent": 0, "terminals": [0], "relativeScore": 60},
                {"id": 2, "text": "画", "reading": "が", "parent": 0, "terminals": [1], "relativeScore": None},
            ],
            "columns": [[0], [1, 2]], "selectedPath": [0, 1], "focusedNode": 1, "selection": 0,
            "contextId": "synthetic-theme", "generation": 1, "showRelativeScores": True, "inputState": "selecting",
            "candidatePage": {"position": 1, "totalCount": 2, "start": 0, "items": [
                {"index": 0, "text": "日本語", "reading": "にほんご"},
                {"index": 1, "text": "日本画", "reading": "にほんが"},
            ]},
        }
        # The roles Core gives these scores.
        for node, role in zip(snapshot["nodes"], ("scoreHigh", "scoreLow", "scoreUnknown")):
            score = node["relativeScore"]
            node["scorePresentation"] = {
                "label": str(score) if score is not None else "—", "role": role,
                "detailDescription": f"相対スコア {score}" if score is not None else "未評価",
            }
        panel.update(snapshot)
        panel.disclosure_actions["tree"].clicked()
        panel.disclosure_actions["details"].clicked()
        original_actions = dict(panel.actions)
        original_rows = list(panel.navigation.row_buttons)
        original_details = panel.details.displayed_text
        settings = panel.get_settings()
        previous_theme = settings.get_property("gtk-theme-name")
        self.addCleanup(settings.set_property, "gtk-theme-name", previous_theme)
        self.addCleanup(settings.set_property, "gtk-enable-animations", settings.get_property("gtk-enable-animations"))
        self.addCleanup(panel.theme.interface.set_string, "color-scheme", panel.theme.interface.get_string("color-scheme"))
        self.addCleanup(panel.theme.accessibility.set_boolean, "high-contrast",
                        panel.theme.accessibility.get_boolean("high-contrast"))
        settings.set_property("gtk-theme-name", "Adwaita")
        settings.set_property("gtk-enable-animations", True)
        for dark, high_contrast, mode in [
            (False, False, "light"), (True, False, "dark"),
            (False, True, "highContrastLight"), (True, True, "highContrastDark"),
        ]:
            panel.theme.interface.set_string("color-scheme", "prefer-dark" if dark else "prefer-light")
            panel.theme.accessibility.set_boolean("high-contrast", high_contrast)
            self.wait_for_paint(panel, GLib)
            self.assertEqual(panel.theme.mode, mode)
            self.assertEqual(panel.actions, original_actions)
            self.assertEqual(panel.navigation.row_buttons, original_rows)
            self.assertEqual(panel.details.displayed_text, original_details)
            self.assertIs(document.get_focus(), entry)
            self.assertFalse(panel.get_accept_focus())
            self.assertFalse(panel.get_focus_on_map())
            for label in (panel.composition.label, panel.remaining.label, panel.details.label):
                foreground = label.get_style_context().get_color(label.get_state_flags())
                expected = Gdk.RGBA()
                expected.parse(PALETTES[mode]["text"])
                self.assertEqual(foreground.to_string(), expected.to_string())
            for row, role in zip(original_rows, ("selectionText", "text")):
                foreground = row.get_style_context().get_color(row.get_state_flags())
                expected = Gdk.RGBA()
                expected.parse(PALETTES[mode][role])
                self.assertEqual(foreground.to_string(), expected.to_string())
                self.assertFalse(row.get_can_focus())
            width, height = panel.canvas.get_size_request()
            surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
            panel.draw(panel.canvas, cairo.Context(surface))
            surface.flush()
            # These points avoid glyphs and antialiasing; test actual Cairo fills,
            # including two differently scored nodes with the same selection.
            frames = {item[1]: item[2:6] for item in panel.rectangles}
            for identifier in (0, 1):
                x, y, _, _ = frames[identifier]
                self.assert_pixel(surface, int(x + 6), int(y + 5), PALETTES[mode]["selection"])
            x, y, _, _ = frames[2]
            self.assert_pixel(surface, int(x + 6), int(y + 5), PALETTES[mode]["surface"])
            image = Gdk.pixbuf_get_from_window(panel.get_window(), 0, 0, panel.get_allocated_width(),
                                              panel.get_allocated_height())
            # Check the second line on the actual scrolled window. A label's
            # offscreen drawing alone misses an opaque GTK undershoot overlay.
            if output := os.environ.get("AZOOKEY_TREE_SNAPSHOT_DIR"):
                image.savev(str(Path(output, f"gtk-{mode}.png")), "png", [], [])
                surface.write_to_png(str(Path(output, f"cairo-{mode}.png")))
            label = panel.details.label
            reading_index = len((snapshot["nodes"][1]["text"] + "\n").encode("utf-8"))
            reading = label.get_layout().index_to_pos(reading_index)
            offset_x, offset_y = label.get_layout_offsets()
            left, top = label.translate_coordinates(
                panel, offset_x + reading.x // Pango.SCALE, offset_y + reading.y // Pango.SCALE)
            width, height = reading.width // Pango.SCALE, reading.height // Pango.SCALE
            pixels = image.get_pixels()
            foreground = bytes.fromhex(PALETTES[mode]["text"][1:])
            background = bytes.fromhex(PALETTES[mode]["background"][1:])
            painted_reading = 0
            for row in range(max(0, top), min(top + height, image.get_height())):
                for column in range(max(0, left), min(left + width, image.get_width())):
                    offset = row * image.get_rowstride() + column * image.get_n_channels()
                    pixel = pixels[offset:offset + 3]
                    # Antialiased glyph edges need not equal the foreground color.
                    if sum(abs(value - ink) for value, ink in zip(pixel, foreground)) < sum(
                        abs(value - paper) for value, paper in zip(pixel, background)
                    ):
                        painted_reading += 1
            self.assertGreater(painted_reading, 4, "The reading below the first line must remain visible")
        self.assertEqual(submitted, [])
        panel.actions[("node", 2)].clicked()
        self.assertEqual(submitted, [("node", 2, False)])
        panel.update({**snapshot, "selection": 1, "selectedPath": [0, 2], "focusedNode": 2})
        self.assertFalse(hasattr(panel.navigation, "confirm"))
        self.assertEqual(submitted, [("node", 2, False)])

    @staticmethod
    def assert_pixel(surface, x, y, color):
        offset = y * surface.get_stride() + x * 4
        blue, green, red, alpha = bytes(surface.get_data()[offset:offset + 4])
        expected = bytes.fromhex(color[1:])
        if (red, green, blue, alpha) != (*expected, 255):
            raise AssertionError(f"pixel ({x}, {y}) is {(red, green, blue, alpha)}, expected {color}")

    @staticmethod
    def wait_for_paint(window, main_loop):
        # Synchronize with GTK rendering rather than assuming a fixed sleep is enough.
        timeout_seconds = 3
        poll_interval_seconds = 0.005
        painted = []
        clock = window.get_frame_clock()
        connection = clock.connect("after-paint", lambda _clock: painted.append(True))
        window.queue_draw()
        deadline = time.monotonic() + timeout_seconds
        try:
            while not painted:
                if time.monotonic() > deadline:
                    raise AssertionError("GTK did not paint the changed appearance")
                main_loop.MainContext.default().iteration(False)
                time.sleep(poll_interval_seconds)
        finally:
            clock.disconnect(connection)


if __name__ == "__main__":
    unittest.main()
