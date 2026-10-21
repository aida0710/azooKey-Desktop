"""Recovery controls for a settings window opened with an invalid document."""
from gi.repository import Gtk, Pango

from .i18n import text


class SettingsRecoveryBar(Gtk.InfoBar):
    def __init__(self, problem, *, path, restore):
        super().__init__(message_type=Gtk.MessageType.WARNING)
        content = self.get_content_area()
        content.set_orientation(Gtk.Orientation.VERTICAL)
        content.set_spacing(10)
        label_text = text("settings.recovery_title") + "\n" + text(
            "settings.recovery_detail", reason=problem.reason, path=path,
        )
        label = Gtk.Label(label=label_text, xalign=0, wrap=True, selectable=True)
        label.set_max_width_chars(48)
        label.set_line_wrap_mode(Pango.WrapMode.WORD_CHAR)
        content.add(label)
        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.restore_button = Gtk.Button(label=text("settings.restore_current"))
        self.restore_button.connect("clicked", lambda _button: restore(False))
        actions.pack_start(self.restore_button, False, False, 0)
        defaults = Gtk.Button(label=text("settings.restore_defaults"))
        defaults.connect("clicked", lambda _button: restore(True))
        actions.pack_start(defaults, False, False, 0)
        content.add(actions)


class SettingsRestoreDialog(Gtk.MessageDialog):
    """Ask for a response without reentering the synchronous AT dispatch."""

    def __init__(self, parent):
        super().__init__(
            transient_for=parent, modal=True, destroy_with_parent=True,
            message_type=Gtk.MessageType.QUESTION, buttons=Gtk.ButtonsType.OK_CANCEL,
            text=text("settings.restore_question"),
        )
        self.format_secondary_text(text("settings.restore_explanation"))
        self.set_default_response(Gtk.ResponseType.CANCEL)
