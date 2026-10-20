#!/usr/bin/python3
"""Observe real dictionary widgets; the controller uses AT-SPI and X11 keys."""
import argparse
import json
from pathlib import Path
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkX11, GLib, Gtk

# Sampling observes GTK state; it never releases or changes a product operation.
OBSERVATION_INTERVAL_MILLISECONDS = 20


def entries_in(widget):
    if isinstance(widget, Gtk.Entry):
        return [{"text": widget.get_text(), "focused": widget.has_focus(),
                 "mapped": widget.get_mapped(), "realized": widget.get_realized(),
                 "selection": list(widget.get_selection_bounds())}]
    if isinstance(widget, Gtk.Container):
        return [entry for child in widget.get_children() for entry in entries_in(child)]
    return []


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("observation", type=Path)
    parser.add_argument("--source-root", type=Path, required=True)
    arguments = parser.parse_args()
    sys.path.insert(0, str(arguments.source_root))
    from azookey.user_dictionary_editor import UserDictionaryEditor
    from test_user_dictionary_model import original_entries

    saved = []
    editor = UserDictionaryEditor(original_entries(), validate=lambda _entries: (), save=saved.append)
    editor.show_all()
    editor.present()
    sequence = 0
    key_events = []
    observed_windows = set()

    def observe_keys(window):
        window_id = window.get_window().get_xid()
        if window_id in observed_windows:
            return
        observed_windows.add(window_id)

        def record_key(_window, event):
            if event.type in (Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE):
                key_events.append({"window": window_id, "type": int(event.type), "keyval": event.keyval})

        window.connect("event-after", record_key)

    def observe():
        nonlocal sequence
        sequence += 1
        choosers = [window for window in Gtk.Window.list_toplevels()
                    if isinstance(window, Gtk.FileChooserDialog) and window.get_visible()]
        for window in (editor, *choosers):
            observe_keys(window)
        observation = {
            "sequence": sequence, "editorWindow": editor.get_window().get_xid(),
            "entries": editor.model.entries, "saved": saved, "keyEvents": key_events,
            "choosers": [{"title": window.get_title(), "window": window.get_window().get_xid(),
                          "mapped": window.get_mapped(), "entries": entries_in(window)} for window in choosers],
        }
        temporary = arguments.observation.with_suffix(".tmp")
        temporary.write_text(json.dumps(observation, ensure_ascii=False))
        temporary.replace(arguments.observation)
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(OBSERVATION_INTERVAL_MILLISECONDS, observe)
    Gtk.main()


if __name__ == "__main__":
    main()
