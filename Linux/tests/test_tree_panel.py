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
                self.assertLessEqual(height, 100)
                surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
                panel.draw(panel.canvas, cairo.Context(surface))
                surface.flush()
                corner = (height - 1) * surface.get_stride() + (width - 1) * 4
                self.assertEqual(bytes(surface.get_data()[corner:corner + 4]), b"\0\0\0\0")
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
