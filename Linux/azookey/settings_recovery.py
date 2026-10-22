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


def confirm_restore(window):
    dialog = Gtk.MessageDialog(
        transient_for=window, modal=True, message_type=Gtk.MessageType.QUESTION,
        buttons=Gtk.ButtonsType.OK_CANCEL, text=text("settings.restore_question"),
    )
    dialog.format_secondary_text(text("settings.restore_explanation"))
    response = dialog.run()
    dialog.destroy()
    return response == Gtk.ResponseType.OK
