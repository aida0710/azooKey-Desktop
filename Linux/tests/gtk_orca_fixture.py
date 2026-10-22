"""Manual Orca presentation fixture; the fixed candidates do not run a converter."""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import sys

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.tree_panel import TreePanel


class OrcaFixture:
    def __init__(self, output):
        self.output = output
        self.snapshot = json.loads(
            (Path(__file__).parent / "fixtures/candidate_announcements.json").read_text(),
        )
        self.window = Gtk.Window(title="azooKey synthetic reading fixture")
        self.window.set_default_size(680, 280)
        self.window.connect("destroy", Gtk.main_quit)
        content = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18, margin=24)
        content.pack_start(Gtk.Label(label="Presentation fixture: F6 open, Up/Down reading, "
                                          "Left/Right word, Enter commit, Escape close."), False, False, 0)
        self.fields = [Gtk.Entry(), Gtk.Entry()]
        for index, field in enumerate(self.fields):
            field.get_accessible().set_name(f"Synthetic field {index + 1}")
            field.connect("key-press-event", self.on_key)
            field.connect("changed", lambda *_: self.record("text"))
            content.pack_start(field, False, False, 0)
        self.window.add(content)
        self.panel = TreePanel(self.select)
        self.panel.location = (280, 370, 0, 24)
        self.window.connect("destroy", lambda *_: self.panel.destroy())
        self.window.show_all()
        self.fields[0].grab_focus()

    def record(self, event):
        record = {
            "at": datetime.now(timezone.utc).isoformat(), "event": event,
            "activeWindow": self.window.is_active(),
            "selection": self.snapshot["selection"],
            "focusedNode": self.snapshot["focusedNode"],
            "panelVisible": self.panel.get_visible(),
            "fields": [{"text": field.get_text(), "focused": field.has_focus()} for field in self.fields],
        }
        with self.output.open("a") as stream:
            stream.write(json.dumps(record, ensure_ascii=False) + "\n")

    def show(self):
        self.snapshot["generation"] += 1
        self.panel.update(self.snapshot)
        self.record("selection")

    def select(self, operation, index, submit):
        if operation == "node":
            self.snapshot["selection"] = 0 if index in (10, 12) else 1
        elif operation == "select":
            self.snapshot["selection"] = index
        if submit:
            candidate = self.snapshot["candidates"][self.snapshot["selection"]]
            self.fields[0].set_text(self.fields[0].get_text() + candidate["text"])
            self.fields[0].set_position(-1)
            self.panel.hide()
            self.record("commit")

    def on_key(self, _widget, event):
        if event.keyval == Gdk.KEY_F6:
            self.show()
        elif self.panel.get_visible() and event.keyval in (Gdk.KEY_Up, Gdk.KEY_Down):
            selection = 0 if event.keyval == Gdk.KEY_Up else 1
            self.snapshot.update(selection=selection, focusedNode=10 + selection,
                                 selectedPath=[10 + selection, 12 + selection])
            self.show()
        elif self.panel.get_visible() and event.keyval in (Gdk.KEY_Left, Gdk.KEY_Right):
            column = 0 if event.keyval == Gdk.KEY_Left else 1
            self.snapshot["focusedNode"] = self.snapshot["selectedPath"][column]
            self.show()
        elif self.panel.get_visible() and event.keyval == Gdk.KEY_Return:
            self.select("select", self.snapshot["selection"], True)
        elif event.keyval == Gdk.KEY_Escape:
            self.panel.hide()
            self.record("hide")
        else:
            return False
        return True


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    fixture = OrcaFixture(arguments.output)
    Gtk.main()
