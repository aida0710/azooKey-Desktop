"""Observe a real input widget and its UI heartbeat during delayed IBus replies."""
import argparse
import json
from pathlib import Path
import time


HEARTBEAT_MILLISECONDS = 25


class Observation:
    def __init__(self, path):
        self.path = Path(path)
        self.started = time.monotonic()
        self.heartbeats = []
        self.events = []

    def event(self, name, **values):
        now = time.monotonic()
        self.events.append({
            "event": name, "seconds": now - self.started, "monotonic": now, **values,
        })

    def heartbeat(self):
        self.heartbeats.append(time.monotonic() - self.started)

    def write(self, **values):
        snapshot = {**values, "heartbeats": self.heartbeats, "events": self.events}
        staged = self.path.with_suffix(".staged")
        staged.write_text(json.dumps(snapshot, ensure_ascii=False))
        staged.replace(self.path)


def gtk_editor(observation, initial_text):
    import gi
    gi.require_version("Gtk", "4.0")
    gi.require_version("GdkX11", "4.0")
    from gi.repository import Gio, GLib, Gtk, GdkX11

    class Window(Gtk.ApplicationWindow):
        def __init__(self, application):
            super().__init__(application=application, title="azooKey native GTK4",
                             default_width=500, default_height=180)
            self.editor = Gtk.Entry()
            self.editor.set_text(initial_text)
            self.editor.set_position(len(initial_text))
            self.preedit = ""
            self.set_child(self.editor)
            self.editor.get_delegate().connect("preedit-changed", self.preedit_changed)
            self.editor.get_buffer().connect("inserted-text", self.inserted)
            self.editor.get_buffer().connect("deleted-text", self.deleted)
            self.present()
            self.editor.grab_focus()
            GLib.timeout_add(HEARTBEAT_MILLISECONDS, self.heartbeat)

        def preedit_changed(self, _editor, value):
            self.preedit = value
            observation.event("preedit", text=value)

        def inserted(self, _buffer, position, text, _length):
            observation.event("insert", text=text, position=position)

        def deleted(self, _buffer, position, count):
            observation.event("delete", position=position, count=count)

        def heartbeat(self):
            observation.heartbeat()
            observation.write(
                toolkit="GTK4", window=GdkX11.X11Surface.get_xid(self.get_surface()),
                text=self.editor.get_text(), cursor=self.editor.get_position(),
                anchor=self.editor.get_delegate().get_property("selection-bound"),
                positionUnit="unicode-scalar",
                preedit=self.preedit, active=self.is_active(),
                focused=self.editor.get_delegate().has_focus(),
            )
            return GLib.SOURCE_CONTINUE

    application = Gtk.Application(application_id="org.azookey.Validation.NativeKeys",
                                  flags=Gio.ApplicationFlags.NON_UNIQUE)
    application.connect("activate", lambda app: Window(app))
    return application.run([])


def qt_editor(observation, initial_text):
    from PyQt6.QtCore import QTimer
    from PyQt6.QtWidgets import QApplication, QTextEdit
    from PyQt6.QtGui import QTextCursor

    class Editor(QTextEdit):
        def __init__(self):
            super().__init__()
            self.preedit = ""
            self.setPlainText(initial_text)
            self.moveCursor(QTextCursor.MoveOperation.End)
            self.setWindowTitle("azooKey native Qt")
            self.resize(500, 180)
            self.show()
            self.setFocus()
            self.timer = QTimer(self)
            self.timer.timeout.connect(self.heartbeat)
            self.timer.start(HEARTBEAT_MILLISECONDS)

        def inputMethodEvent(self, event):
            self.preedit = event.preeditString()
            observation.event(
                "input-method", commit=event.commitString(), preedit=self.preedit,
                replacementStart=event.replacementStart(), replacementLength=event.replacementLength(),
            )
            super().inputMethodEvent(event)

        def keyPressEvent(self, event):
            observation.event("key-press", key=event.key(), text=event.text(),
                              modifiers=event.modifiers().value)
            super().keyPressEvent(event)

        def heartbeat(self):
            observation.heartbeat()
            observation.write(
                toolkit="Qt", window=int(self.winId()), text=self.toPlainText(),
                cursor=self.textCursor().position(), preedit=self.preedit,
                anchor=self.textCursor().anchor(), positionUnit="utf16",
                active=self.isActiveWindow(), focused=self.hasFocus(),
            )

    application = QApplication([])
    editor = Editor()
    return application.exec()


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("toolkit", choices=("gtk4", "qt"))
    parser.add_argument("state")
    parser.add_argument("--text", default="")
    options = parser.parse_args()
    launch = gtk_editor if options.toolkit == "gtk4" else qt_editor
    raise SystemExit(launch(Observation(options.state), options.text))
