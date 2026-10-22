"""Private session-bus connection to the GNOME candidate renderer."""
import json
import weakref
from gi.repository import Gio, GLib
from .async_bridge import AsyncBridge

NAME = "org.azookey.Tree"
PATH = "/org/azookey/Tree"
XML = """<node><interface name="org.azookey.Tree">
  <method name="ResetLearning"><arg type="b" direction="out"/></method>
  <method name="DescribeLayout"><arg type="s" direction="out"/></method>
  <method name="RendererStatus"><arg type="b" direction="out"/></method>
  <method name="SetRenderer"><arg type="b" direction="in"/></method>
  <method name="Select"><arg type="s" direction="in"/><arg type="i" direction="in"/>
    <arg type="b" direction="in"/><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <signal name="Update"><arg type="s"/></signal>
  <signal name="Hide"/>
  <signal name="Suspend"/>
  <signal name="ScrollDetails"><arg type="b"/></signal>
</interface></node>"""


class ShellSurface:
    def __init__(self):
        self.connection = None
        self.renderer = None
        self.watch = 0
        self.engine = None
        self.owner = Gio.bus_own_name(Gio.BusType.SESSION, NAME, Gio.BusNameOwnerFlags.NONE,
                                      self.acquired, None, None)

    def acquired(self, connection, _name):
        self.connection = connection
        info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
        self.registration = connection.register_object(PATH, info, self.method, None, None)

    def method(self, _connection, sender, _path, _interface, name, parameters, invocation):
        if name == "DescribeLayout":
            engine = self.engine() if self.engine else None
            description = engine.panel.layout_diagnostics if engine and engine.focused else {}
            invocation.return_value(GLib.Variant("(s)", (json.dumps(description),)))
            return
        if name == "RendererStatus":
            invocation.return_value(GLib.Variant("(b)", (self.renderer is not None,)))
            return
        if name == "ResetLearning":
            AsyncBridge.reset_shared_learning(
                lambda success: invocation.return_value(GLib.Variant("(b)", (success,))))
            return
        if self.renderer and sender != self.renderer:
            invocation.return_dbus_error(NAME + ".Busy", "Another renderer is registered")
            return
        values = parameters.unpack()
        if name == "SetRenderer":
            if self.watch:
                Gio.bus_unwatch_name(self.watch)
                self.watch = 0
            self.renderer = sender if values[0] else None
            if self.renderer:
                self.watch = Gio.bus_watch_name_on_connection(self.connection, sender, Gio.BusNameWatcherFlags.NONE,
                                                              None, lambda *_: self.lost())
        elif name == "Select" and sender == self.renderer:
            engine = self.engine() if self.engine else None
            operation, index, submit, generation, context = values
            if engine and engine.focused and context == engine.context_id and generation == engine.snapshot.get("generation"):
                if operation in ("node", "select"):
                    engine.choose(operation, index, submit)
        else:
            invocation.return_dbus_error(NAME + ".Invalid", "Invalid method")
            return
        invocation.return_value(GLib.Variant("()", ()))

    def lost(self):
        self.renderer = None
        if self.watch:
            Gio.bus_unwatch_name(self.watch)
        self.watch = 0
        engine = self.engine() if self.engine else None
        # The visible preedit may already contain keys absent from this snapshot.
        # Their reply will restore the fallback renderer without losing input.
        if engine and not engine.input.has_pending_preview:
            engine.render_candidates(engine.snapshot)

    def show(self, engine, snapshot, location):
        self.engine = weakref.ref(engine)
        if not self.connection or not self.renderer:
            return False
        data = {**snapshot, "location": location, "contextId": engine.context_id}
        # Typed text is sent only to the registered renderer, never broadcast.
        self.connection.emit_signal(self.renderer, PATH, NAME, "Update", GLib.Variant("(s)", (json.dumps(data, ensure_ascii=False),)))
        return True

    def hide(self, engine):
        self._emit_for_engine(engine, "Hide")

    def suspend(self, engine):
        self._emit_for_engine(engine, "Suspend")

    def scroll_details(self, engine, forward):
        return self._emit_for_engine(engine, "ScrollDetails", parameters=GLib.Variant("(b)", (forward,)))

    def _emit_for_engine(self, engine, signal, *, parameters=None):
        if not (self.connection and self.renderer and self.engine and self.engine() is engine):
            return False
        self.connection.emit_signal(self.renderer, PATH, NAME, signal, parameters)
        return True


_surface = None


def surface():
    global _surface
    if _surface is None:
        _surface = ShellSurface()
    return _surface
