"""GTK labels keep their control relationships when settings move between pages."""
import gi
gi.require_version("Gtk", "3.0")
from gi.repository import Atk, Gtk


def label_control(parent, control, title, *, mnemonic=None):
    caption = title if mnemonic is None else f"{title} (_{mnemonic})"
    label = Gtk.Label(label=caption, use_underline=True, xalign=0, wrap=True)
    label.set_mnemonic_widget(control)
    control.get_accessible().set_name(title)
    control.get_accessible().add_relationship(Atk.RelationType.LABELLED_BY, label.get_accessible())
    label.get_accessible().add_relationship(Atk.RelationType.LABEL_FOR, control.get_accessible())
    parent.pack_start(label, False, False, 0)
    return label


class StatusMessage(Gtk.Label):
    """Publish save failures and other visible status updates as alerts."""

    def __init__(self):
        super().__init__(xalign=0, wrap=True)
        self.get_accessible().set_role(Atk.Role.ALERT)

    def set_text(self, message):
        super().set_text(message)
        self.get_accessible().set_name(message)
