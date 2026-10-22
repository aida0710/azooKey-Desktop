"""A send-review window that leaves typing with the input client."""
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, Gtk

from .ai_scope_view import AIRequestScopeView
from .i18n import text as message


class AISuggestionConfirmationWindow(Gtk.Window):
    # Leave room for the complete destination and a scrollable target.
    DEFAULT_WIDTH = 480

    def __init__(self, scope, *, on_send, on_cancel, on_context_changed):
        # A toplevel does not require a parent surface from another application
        # on Wayland. show_all() avoids requesting keyboard activation.
        super().__init__(type=Gtk.WindowType.TOPLEVEL, title=message("ai.scope.confirm"))
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_default_size(self.DEFAULT_WIDTH, -1)
        self.connect("delete-event", lambda *_: on_cancel())
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=12)
        self.add(box)
        box.pack_start(Gtk.Label(label=message("ai.scope.confirm"), xalign=0), False, False, 0)
        self.scope_view = AIRequestScopeView(scope, on_context_changed)
        box.pack_start(self.scope_view, True, True, 0)
        self.message = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self.message, False, False, 0)
        box.pack_start(Gtk.Label(label=message("ai.scope.keyboard"), xalign=0, wrap=True), False, False, 0)
        buttons = Gtk.ButtonBox(orientation=Gtk.Orientation.HORIZONTAL)
        send = Gtk.Button(label=message("ai.scope.send"))
        send.connect("clicked", lambda _: on_send())
        cancel = Gtk.Button(label=message("ai.scope.cancel"))
        cancel.connect("clicked", lambda _: on_cancel())
        buttons.add(send)
        buttons.add(cancel)
        box.pack_start(buttons, False, False, 0)

    def context_save_failed(self):
        self.message.set_text(message("ai.scope.include-error"))

    def show_near(self, location):
        self.show_all()
        if "Wayland" in type(Gdk.Display.get_default()).__name__:
            return
        monitor = self.get_display().get_monitor_at_point(location[0], location[1])
        area = monitor.get_workarea()
        width, height = self.get_size()
        x = min(max(area.x, location[0]), max(area.x, area.x + area.width - width))
        below = location[1] + location[3]
        y = below if below + height <= area.y + area.height else max(area.y, location[1] - height)
        self.move(x, y)
