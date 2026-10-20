#!/usr/bin/python3
"""GTK4 fixture for real password, PIN, PRIVATE and read-only input fields."""
from functools import partial

import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gdk, Gio, Gtk

from protected_fixture_state import (
    FIELD_LABELS, READ_ONLY_TEXT, WINDOW_HEIGHT, WINDOW_WIDTH,
    ProtectedFixtureRecorder,
)


class ProtectedInputWindow(Gtk.ApplicationWindow):
    def __init__(self, *, application, recorder):
        super().__init__(
            application=application, title="azooKey protected input — GTK4",
            default_width=WINDOW_WIDTH, default_height=WINDOW_HEIGHT,
        )
        self.recorder = recorder
        self.editors = {}
        self.preedits = {}
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        for side in ("top", "bottom", "start", "end"):
            getattr(layout, f"set_margin_{side}")(24)
        layout.append(Gtk.Label(
            label="Synthetic text only. Tab / Shift+Tab moves between fields.",
            xalign=0,
        ))
        for field_id, label in FIELD_LABELS.items():
            editor = self.create_editor(field_id=field_id, label=label)
            layout.append(Gtk.Label(label=label, xalign=0))
            layout.append(editor)
            self.editors[field_id] = editor
            self.preedits[field_id] = ""
        self.set_child(layout)
        self.connect("notify::is-active", self.record)
        self.connect("notify::focus-widget", self.record)
        self.present()
        self.editors["normal"].grab_focus()
        self.record()

    def create_editor(self, *, field_id, label):
        editor = Gtk.Entry()
        editor.update_property([Gtk.AccessibleProperty.LABEL], [label])
        if field_id in ("password", "pin"):
            editor.set_visibility(False)
            purpose = Gtk.InputPurpose.PIN if field_id == "pin" else Gtk.InputPurpose.PASSWORD
            editor.set_input_purpose(purpose)
        elif field_id == "private":
            editor.set_input_hints(Gtk.InputHints.PRIVATE)
        elif field_id == "read-only":
            editor.set_text(READ_ONLY_TEXT)
            editor.set_editable(False)
        editor.connect("changed", self.record)
        editor.connect("notify::cursor-position", self.record)
        editor.connect("notify::selection-bound", self.record)
        editor.get_delegate().connect(
            "preedit-changed", partial(self.observe_preedit, field_id=field_id)
        )
        editor.get_buffer().connect(
            "inserted-text", partial(self.observe_insert, field_id=field_id)
        )
        editor.get_buffer().connect(
            "deleted-text", partial(self.observe_delete, field_id=field_id)
        )
        return editor

    def observe_preedit(self, _text, preedit, *, field_id):
        self.preedits[field_id] = preedit
        self.recorder.events.append("preedit", fieldId=field_id, text=preedit)
        self.record()

    def observe_insert(self, _buffer, position, text, length, *, field_id):
        self.recorder.events.append(
            "inserted-text", fieldId=field_id, text=text,
            positionScalar=position, lengthScalar=length,
        )

    def observe_delete(self, _buffer, position, length, *, field_id):
        self.recorder.events.append(
            "deleted-text", fieldId=field_id,
            positionScalar=position, lengthScalar=length,
        )

    def record(self, *_arguments):
        focused_widget = self.get_focus()
        fields = []
        for field_id, editor in self.editors.items():
            selected = editor.get_selection_bounds()
            start, end = selected if selected else (editor.get_position(), editor.get_position())
            fields.append({
                "id": field_id,
                "label": FIELD_LABELS[field_id],
                "text": editor.get_text(),
                "focused": self.is_active() and focused_widget is not None
                and (focused_widget == editor or focused_widget.is_ancestor(editor)),
                "preedit": self.preedits[field_id],
                "cursorScalar": editor.get_position(),
                "selection": {"startScalar": start, "endScalar": end},
                "attributes": {
                    "editable": editor.get_editable(),
                    "visibleText": editor.get_visibility(),
                    "inputPurpose": editor.get_input_purpose().value_nick,
                    "inputPurposeValue": int(editor.get_input_purpose()),
                    "inputHints": int(editor.get_input_hints()),
                    "privateHint": bool(editor.get_input_hints() & Gtk.InputHints.PRIVATE),
                },
            })
        display = Gdk.Display.get_default()
        self.recorder.record(
            fields=fields, window_active=self.is_active(),
            toolkit={
                "name": "GTK4",
                "version": f"{Gtk.get_major_version()}.{Gtk.get_minor_version()}.{Gtk.get_micro_version()}",
                "platform": "wayland" if "Wayland" in type(display).__name__ else "x11",
            },
        )


def main():
    recorder = ProtectedFixtureRecorder.from_arguments()
    application = Gtk.Application(
        application_id="org.azookey.Validation.ProtectedInput",
        flags=Gio.ApplicationFlags.NON_UNIQUE,
    )
    application.connect(
        "activate", lambda app: ProtectedInputWindow(application=app, recorder=recorder)
    )
    return application.run([])


if __name__ == "__main__":
    raise SystemExit(main())
