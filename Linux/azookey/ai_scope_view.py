"""GTK controls showing what Core will send for one AI request."""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .i18n import text as message


class AIRequestScopeView(Gtk.Box):
    # Keep long targets scrollable and the send controls in view.
    TARGET_HEIGHT = 90

    def __init__(self, *, target, destination, include_context, on_context_changed):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.on_context_changed = on_context_changed
        shown_destination = destination or message("ai.destination.invalid")
        label = Gtk.Label(label=f'{message("ai.scope.destination")}: {shown_destination}', xalign=0, wrap=True, selectable=True)
        self.pack_start(label, False, False, 0)
        self.pack_start(Gtk.Label(label=message("ai.scope.target"), xalign=0), False, False, 0)
        target_view = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        target_view.get_buffer().set_text(target)
        target_view.get_accessible().set_name(message("ai.scope.target"))
        scroll = Gtk.ScrolledWindow(min_content_height=self.TARGET_HEIGHT, max_content_height=self.TARGET_HEIGHT)
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(target_view)
        self.pack_start(scroll, True, True, 0)
        self.context = Gtk.CheckButton(label=message("ai.scope.include-context"), active=include_context)
        self.context.connect("toggled", lambda button: self.on_context_changed(button.get_active()))
        self.pack_start(self.context, False, False, 0)

    @property
    def include_context(self):
        return self.context.get_active()

    def toggle_context(self):
        self.context.set_active(not self.context.get_active())
