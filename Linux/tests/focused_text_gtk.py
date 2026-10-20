#!/usr/bin/python3
"""Read real GTK selections over a private AT-SPI bus, without external AI."""
from dataclasses import replace
import json
import pathlib
import sys
import threading
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.ai_transform_target import InputSelection, PendingTransformation, TransformationTarget
from azookey.focused_text import inspect_focused_text


# Daemon/GTK registration is asynchronous; wait for observed state, not a fixed delay.
TEST_TIMEOUT_SECONDS = 5
POLL_INTERVAL_SECONDS = 0.005


def wait_until(predicate, description):
    deadline = time.monotonic() + TEST_TIMEOUT_SECONDS
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if predicate():
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(description)


class TextFields:
    def __init__(self):
        self.window = Gtk.Window(title="azooKey AI target fixture")
        self.window.set_default_size(500, 160)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.fields = [Gtk.Entry(text="前 原文 後"), Gtk.Entry(text="前 原文 後")]
        for index, field in enumerate(self.fields):
            field.get_accessible().set_name(f"fixture field {index + 1}")
            box.add(field)
        self.window.add(box)
        self.window.show_all()

    def focus(self, index):
        self.window.present()
        self.window.get_window().focus(Gdk.CURRENT_TIME)
        field = self.fields[index]
        field.grab_focus()
        field.select_region(2, 4)
        wait_until(lambda: self.window.is_active() and field.has_focus(), "GTK field did not receive focus")

    def close(self):
        self.window.destroy()


def inspect(selection):
    replies = []
    threading.Thread(target=lambda: replies.append(inspect_focused_text(selection)), daemon=True).start()
    wait_until(lambda: replies, "accessibility read did not complete")
    return replies[0]


def main():
    fields = TextFields()
    selection = InputSelection.capture(("/fixture/context", "gnome-shell"), "前 原文 後", cursor=4, anchor=2)
    try:
        fields.focus(0)
        original = inspect(selection)
        assert original is not None, "active GTK field was not available through AT-SPI"
        fields.focus(1)
        second = inspect(selection)
        assert second and second.identity != original.identity
        assert second.window_identity == original.window_identity
        target = TransformationTarget(selection, original)
        assert PendingTransformation(target, "変更済み").take(selection, second) is None
        fields.focus(0)
        returned = inspect(selection)
        assert returned == original
        pending = PendingTransformation(target, "変更済み")
        assert pending.take(selection, returned) == "変更済み"
        assert pending.take(selection, returned) is None
        fields.fields[0].set_editable(False)
        assert inspect(selection) is None
        fields.fields[0].set_editable(True)
        fields.fields[0].set_visibility(False)
        assert inspect(selection) is None
        fields.fields[0].set_visibility(True)
        fields.fields[0].set_text("前 別文 後")
        fields.fields[0].select_region(2, 4)
        assert inspect(selection) is None
        changed_selection = replace(selection, selected="別文")
        changed = inspect(changed_selection)
        assert changed and PendingTransformation(target, "変更済み").take(changed_selection, changed) is None
        print(json.dumps({"status": "PASS", "checks": 8, "same_context_different_objects": True,
                          "identity": "AT-SPI bus GUID + unique bus name + object path",
                          "window_identity_verified": True, "external_ai_requests": 0}))
    finally:
        fields.close()


if __name__ == "__main__":
    main()
