#!/usr/bin/python3
"""Guest-only native GTK input fixture; writes only its own synthetic test text."""
import argparse
import json
import pathlib

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=pathlib.Path)
arguments = parser.parse_args()
arguments.output.parent.mkdir(parents=True, exist_ok=True)

window = Gtk.Window(title="azooKey UX validation — GTK")
window.set_default_size(900, 600)
window.connect("destroy", Gtk.main_quit)
layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=16, margin=24)
layout.pack_start(Gtk.Label(label="GTK: type nihongo, select a candidate, then keep typing.", xalign=0), False, False, 0)
editors = []


def record(*_arguments):
    fields = []
    for editor in editors:
        buffer = editor.get_buffer()
        fields.append({
            "text": buffer.get_text(*buffer.get_bounds(), True),
            "focused": editor.has_focus(),
            "cursor": buffer.get_property("cursor-position"),
        })
    arguments.output.write_text(json.dumps({"fields": fields}, ensure_ascii=False), encoding="utf-8")
    return False


for index in range(2):
    editor = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
    editor.get_accessible().set_name(f"Test input {index + 1}")
    editor.get_buffer().connect("changed", record)
    editor.get_buffer().connect("notify::cursor-position", record)
    editor.connect("notify::has-focus", record)
    editors.append(editor)
    container = Gtk.ScrolledWindow()
    container.set_min_content_height(180)
    container.add(editor)
    layout.pack_start(container, True, True, 0)
style = Gtk.CssProvider()
style.load_from_data(b"textview { font-size: 24px; }")
Gtk.StyleContext.add_provider_for_screen(window.get_screen(), style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
window.add(layout)
window.show_all()
editors[0].grab_focus()
record()
Gtk.main()
