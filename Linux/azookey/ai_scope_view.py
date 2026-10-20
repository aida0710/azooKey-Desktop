"""GTK controls for inspecting an immutable AI request scope."""
import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gtk

from .i18n import text as message


class AIRequestScopeView(Gtk.Box):
    # Keep long targets scrollable and the send controls in view.
    TARGET_HEIGHT = 90

    def __init__(self, scope, on_context_changed):
        super().__init__(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        self.scope = scope
        self.on_context_changed = on_context_changed
        destination = Gtk.Label(
            label=f'{message("ai.scope.destination")}: {scope.configuration.destination}',
            xalign=0, wrap=True, selectable=True,
        )
        self.pack_start(destination, False, False, 0)
        self.pack_start(Gtk.Label(label=message("ai.scope.target"), xalign=0), False, False, 0)
        target = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        target.get_buffer().set_text(scope.target)
        target.get_accessible().set_name(message("ai.scope.target"))
        scroll = Gtk.ScrolledWindow(min_content_height=self.TARGET_HEIGHT, max_content_height=self.TARGET_HEIGHT)
        scroll.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        scroll.add(target)
        self.pack_start(scroll, True, True, 0)
        self.context = Gtk.CheckButton(label=message("ai.scope.include-context"), active=scope.include_context)
        self.context.connect("toggled", self.context_changed)
        self.pack_start(self.context, False, False, 0)

    def context_changed(self, button):
        self.scope = self.scope.with_context(button.get_active())
        self.on_context_changed(self.scope)

    def toggle_context(self):
        self.context.set_active(not self.context.get_active())
