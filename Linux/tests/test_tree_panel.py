"""Exercise the real GTK renderer and converter in an isolated Xvfb display."""
import os
import pathlib
import sys
import tempfile
import types
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY") and os.environ.get("AZOOKEY_BRIDGE"), "requires Xvfb and the Swift bridge")
class TreePanelTests(unittest.TestCase):
    def test_candidate_text_uses_ellipsis_instead_of_shrinking_below_readable_size(self):
        import cairo
        from azookey.tree_panel import TreePanel
        context = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 100, 40))
        for text, width in [("このように", 60), ("科学的", 36), ("が", 12)]:
            layout = TreePanel.fitted_layout(context, text, width, 18)
            self.assertEqual(layout.get_font_description().get_size(), 18 * 1024)
            self.assertTrue(layout.is_ellipsized(), text)

    def test_word_columns_stay_under_document_words(self):
        from azookey.tree_panel import TreePanel
        panel = TreePanel(lambda *_: None)
        panel.location = (100, 100, 1, 20)
        try:
            snapshot = {
                "nodes": [
                    {"id": 0, "text": "このように", "reading": "", "parent": None, "terminals": []},
                    {"id": 1, "text": "確率的に", "reading": "", "parent": 0, "terminals": [0]},
                    {"id": 2, "text": "このようにかくりつてきに", "reading": "", "parent": None, "terminals": [1]},
                ],
                "columns": [[0, 2], [1]], "selectedPath": [0, 1],
                "wordGeometry": {"widths": [75, 60], "fontSize": 15},
            }
            panel.update(snapshot)
            words = {r[1]: r for r in panel.rectangles if r[0] == "node"}
            self.assertEqual(words[1][2] - words[0][2], 75)
            self.assertEqual(words[0][2], words[2][2])
            self.assertLessEqual(words[2][4], 75, "Long alternatives must not cover the next word")
            panel.update({**snapshot, "showCandidateIndex": True})
            word = next(r for r in panel.rectangles if r[:2] == ("node", 1))
            number = next(r for r in panel.rectangles if r[:2] == ("select", 0))
            self.assertGreaterEqual(number[3], word[3] + word[5] + 12)
            panel.location = (2, 100, 1, 20)
            panel.update(snapshot)
            self.assertFalse(panel.aligned, "Screen-edge clamping must not pretend to retain document coordinates")
        finally:
            panel.destroy()

    def test_real_conversion_compact_rendering_and_single_click_commit(self):
        import cairo
        from gi.repository import GLib
        from azookey.bridge import Bridge
        from azookey.keymap import translate
        from azookey.tree_panel import TreePanel

        previous = os.environ.get("AZOOKEY_DATA_DIR")
        with tempfile.TemporaryDirectory() as directory:
            os.environ["AZOOKEY_DATA_DIR"] = directory
            bridge = Bridge()
            panel = None
            original_settings = bridge.request("settings")["settings"]
            try:
                bridge.request("configure", settings={**original_settings, "tree": True, "live": True})
                for character in "watashihanihongowobenkyoushiteimasu":
                    snapshot = bridge.request("key", event=translate(ord(character), 0))
                self.assertTrue(snapshot["columns"])
                submitted = []

                def choose(operation, index, submit):
                    self.assertTrue(submit, "Moving alternatives must commit on the first click")
                    response = bridge.request(operation, **{"node" if operation == "node" else "index": index},
                                              generation=snapshot["generation"], submit=submit)
                    submitted.extend(response["commits"])

                panel = TreePanel(choose)
                panel.update(snapshot)
                context = GLib.MainContext.default()
                while context.pending():
                    context.iteration(False)
                words = {item[1]: item for item in panel.rectangles if item[0] == "node"}
                self.assertLessEqual(len(words), len(snapshot["columns"]) * 3)
                self.assertEqual({words[column[0]][3] for column in snapshot["columns"]}, {6})
                width, height = panel.canvas.get_size_request()
                self.assertLessEqual(height, 200)
                surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
                panel.draw(panel.canvas, cairo.Context(surface))
                surface.flush()
                corner = (height - 1) * surface.get_stride() + (width - 1) * 4
                self.assertEqual(bytes(surface.get_data()[corner:corner + 4]), b"\0\0\0\0")
                self.assertEqual(surface.get_data()[10 * surface.get_stride() + 10 * 4 + 3], 255,
                                 "The candidate region must cover the document behind it")
                if output := os.environ.get("AZOOKEY_TREE_SNAPSHOT_DIR"):
                    surface.write_to_png(str(pathlib.Path(output) / "ubuntu-compact.png"))
                alternatives = [column[1] for column in snapshot["columns"] if len(column) > 1]
                self.assertTrue(alternatives)
                rect = words[alternatives[0]]
                self.assertTrue(panel.click(None, types.SimpleNamespace(button=1, x=rect[2] + 4, y=rect[3] + 4)))
                self.assertEqual(len(submitted), 1)
                self.assertIn(submitted[0], [candidate["text"] for candidate in snapshot["candidates"]])
            finally:
                if panel:
                    panel.destroy()
                bridge.request("configure", settings=original_settings)
                bridge.close()
                if previous is None:
                    os.environ.pop("AZOOKEY_DATA_DIR", None)
                else:
                    os.environ["AZOOKEY_DATA_DIR"] = previous


if __name__ == "__main__":
    unittest.main()
