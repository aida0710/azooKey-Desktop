#!/usr/bin/python3
"""Guest-only native GTK input fixture; writes only its own synthetic test text."""
import argparse
from functools import partial
import json
import pathlib
import time

import gi
from fixture_events import FixtureEvents

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk


parser = argparse.ArgumentParser()
parser.add_argument("--output", required=True, type=pathlib.Path)
parser.add_argument("--events", type=pathlib.Path)
arguments = parser.parse_args()
arguments.output.parent.mkdir(parents=True, exist_ok=True)
event_log = FixtureEvents(arguments.events)

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
        selection = buffer.get_selection_bounds()
        start, end = [position.get_offset() for position in selection] if selection else (
            buffer.get_property("cursor-position"), buffer.get_property("cursor-position"),
        )
        fields.append({
            "text": buffer.get_text(*buffer.get_bounds(), True),
            "focused": window.is_active() and editor.has_focus(),
            "cursor": buffer.get_property("cursor-position"),
            "selection": {"startScalar": start, "endScalar": end},
            "preedit": editor.preedit,
        })
    state = {
        "observedAt": time.time(), "monotonicNS": time.monotonic_ns(),
        "windowActive": window.is_active(),
        "gtk_version": f"{Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}",
        "platform": "wayland" if "Wayland" in type(Gdk.Display.get_default()).__name__ else "x11",
        "fields": fields,
    }
    pending_output = arguments.output.with_suffix(arguments.output.suffix + ".pending")
    pending_output.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
    pending_output.replace(arguments.output)
    event_log.append("state", state=state)
    return False


def record_preedit(editor, preedit):
    editor.preedit = preedit
    record()


def observe_insert(_buffer, position, inserted_text, *_byte_length, field_index):
    # GTK also supplies a byte count; the observed text is already decoded.
    event_log.append("insert-text", fieldIndex=field_index, text=inserted_text,
                     positionScalar=position.get_offset())


def observe_delete(_buffer, start, end, *, field_index):
    event_log.append("delete-range", fieldIndex=field_index,
                     startScalar=start.get_offset(), endScalar=end.get_offset())


for index in range(2):
    editor = Gtk.TextView(wrap_mode=Gtk.WrapMode.WORD_CHAR)
    editor.preedit = ""
    editor.get_accessible().set_name(f"Test input {index + 1}")
    editor.get_buffer().connect("changed", record)
    editor.get_buffer().connect("insert-text", partial(observe_insert, field_index=index))
    editor.get_buffer().connect("delete-range", partial(observe_delete, field_index=index))
    editor.get_buffer().connect("notify::cursor-position", record)
    editor.get_buffer().connect("notify::has-selection", record)
    editor.connect("notify::has-focus", record)
    editor.connect("preedit-changed", record_preedit)
    editors.append(editor)
    container = Gtk.ScrolledWindow()
    container.set_min_content_height(180)
    container.add(editor)
    layout.pack_start(container, True, True, 0)
style = Gtk.CssProvider()
style.load_from_data(b"textview { font-size: 24px; }")
Gtk.StyleContext.add_provider_for_screen(window.get_screen(), style, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
window.add(layout)
window.connect("notify::is-active", record)
window.show_all()
editors[0].grab_focus()
record()
Gtk.main()
