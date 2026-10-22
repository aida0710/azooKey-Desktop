"""GTK controls for each kind of setting in Core's settings schema.

A control shows one setting's JSON value and reads the user's edit back.
Validation stays in Core; a control only converts text the user typed.
"""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .i18n import text as message
from .labeled_controls import label_control
from .prompts import parse_shortcut, shortcut_text

# Room for several rows of a custom input table without growing the window.
MULTILINE_MINIMUM_HEIGHT = 140


class ToggleControl:
    def __init__(self, parent, item):
        self.widget = Gtk.CheckButton(label=message(item["labelKey"]))
        parent.pack_start(self.widget, False, False, 0)

    def read(self):
        return self.widget.get_active()

    def show(self, value):
        self.widget.set_active(value)


class ChoiceControl:
    def __init__(self, parent, item):
        self.widget = Gtk.ComboBoxText()
        label_control(parent, self.widget, message(item["labelKey"]))
        # GTK identifies rows by text; keep each choice's JSON value, such as an integer.
        self.values = {}
        for choice in item["choices"]:
            identifier = str(choice["value"])
            self.values[identifier] = choice["value"]
            self.widget.append(identifier, message(choice["labelKey"]))
        parent.pack_start(self.widget, False, False, 0)

    def read(self):
        return self.values.get(self.widget.get_active_id())

    def show(self, value):
        self.widget.set_active_id(str(value))


class TextControl:
    def __init__(self, parent, item):
        self.widget = Gtk.Entry()
        label_control(parent, self.widget, message(item["labelKey"]))
        parent.pack_start(self.widget, False, False, 0)

    def read(self):
        return self.widget.get_text()

    def show(self, value):
        self.widget.set_text(str(value))


class IntegerControl(TextControl):
    def read(self):
        text = self.widget.get_text().strip()
        # Text that is not a number goes to Core as typed, so Core names the setting.
        try:
            return int(text)
        except ValueError:
            return text


class MultilineControl:
    def __init__(self, parent, item):
        self.widget = Gtk.TextView(monospace=True)
        label_control(parent, self.widget, message(item["labelKey"]))
        scroller = Gtk.ScrolledWindow(min_content_height=MULTILINE_MINIMUM_HEIGHT)
        scroller.add(self.widget)
        parent.pack_start(scroller, True, True, 0)

    def read(self):
        buffer = self.widget.get_buffer()
        return buffer.get_text(buffer.get_start_iter(), buffer.get_end_iter(), True)

    def show(self, value):
        self.widget.get_buffer().set_text(value)


class ShortcutControl:
    def __init__(self, parent, item):
        self.widget = Gtk.Entry()
        label_control(parent, self.widget, message(item["labelKey"]), mnemonic=item.get("accessKey"))
        parent.pack_start(self.widget, False, False, 0)

    def read(self):
        shortcut = parse_shortcut(self.widget.get_text())
        if shortcut is None:
            raise ValueError(message("ai.shortcut.required"))
        return shortcut

    def show(self, value):
        self.widget.set_text(shortcut_text(value))


CONTROLS = {
    "toggle": ToggleControl,
    "choice": ChoiceControl,
    "integer": IntegerControl,
    "text": TextControl,
    "multilineText": MultilineControl,
    "shortcut": ShortcutControl,
}
