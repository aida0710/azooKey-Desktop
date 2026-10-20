"""The observation fixture must report native events without applying them twice."""
import importlib.util
import json
import os
import pathlib
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch


TOOLS = pathlib.Path(__file__).resolve().parents[2] / "Tools/tests"
sys.path.insert(0, str(TOOLS))
HAS_DISPLAY = bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))


def observations(path):
    return [json.loads(line) for line in path.read_text().splitlines()]


@unittest.skipUnless(HAS_DISPLAY and importlib.util.find_spec("gi"), "isolated GTK display required")
class GTKEditorObservationTests(unittest.TestCase):
    def test_native_insert_and_delete_keep_the_actual_field_and_offsets(self):
        import gi
        gi.require_version("Gtk", "3.0")
        from gi.repository import Gtk
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "state.json"
            events = pathlib.Path(temporary) / "events.jsonl"
            arguments = ["gtk-editor.py", "--output", str(output), "--events", str(events)]
            with patch.object(sys, "argv", arguments), patch.object(Gtk, "main"):
                fixture = runpy.run_path(str(TOOLS / "gtk-editor.py"))
            try:
                buffer = fixture["editors"][1].get_buffer()
                buffer.insert(buffer.get_end_iter(), "変換した本文")
                buffer.delete(buffer.get_iter_at_offset(0), buffer.get_iter_at_offset(2))
                recorded = observations(events)
                inserted = [event for event in recorded if event["event"] == "insert-text"]
                self.assertEqual(len(inserted), 1)
                self.assertEqual((inserted[0]["fieldIndex"], inserted[0]["text"], inserted[0]["positionScalar"]),
                                 (1, "変換した本文", 0))
                deleted = [event for event in recorded if event["event"] == "delete-range"]
                self.assertEqual((deleted[0]["startScalar"], deleted[0]["endScalar"]), (0, 2))
                self.assertEqual(json.loads(output.read_text())["fields"][1]["text"], "した本文")
            finally:
                fixture["window"].disconnect_by_func(Gtk.main_quit)
                fixture["window"].destroy()


@unittest.skipUnless(
    HAS_DISPLAY and os.geteuid() != 0 and importlib.util.find_spec("PyQt6")
    and importlib.util.find_spec("PyQt6.QtWebEngineWidgets"),
    "non-root isolated Qt/QtWebEngine display required",
)
class QtEditorObservationTests(unittest.TestCase):
    def test_native_commit_is_observed_once_and_the_widget_applies_it_unchanged(self):
        from PyQt6.QtGui import QInputMethodEvent
        from PyQt6.QtWidgets import QApplication
        with tempfile.TemporaryDirectory() as temporary:
            output = pathlib.Path(temporary) / "state.json"
            events = pathlib.Path(temporary) / "events.jsonl"
            arguments = ["qt-editor.py", "--output", str(output), "--events", str(events)]
            with patch.object(sys, "argv", arguments), patch.object(QApplication, "exec", return_value=0), patch("sys.exit"):
                fixture = runpy.run_path(str(TOOLS / "qt-editor.py"))
            try:
                event = QInputMethodEvent()
                event.setCommitString("変換した本文")
                QApplication.sendEvent(fixture["editors"][1], event)
                committed = [item for item in observations(events) if item["event"] == "input-method"]
                self.assertEqual(len(committed), 1)
                self.assertEqual((committed[0]["fieldIndex"], committed[0]["commit"]), (1, "変換した本文"))
                self.assertEqual(json.loads(output.read_text())["fields"][1]["text"], "変換した本文")
            finally:
                fixture["window"].close()


if __name__ == "__main__":
    unittest.main()
