"""Private session-bus connection to the GNOME candidate renderer."""
import json
import weakref
from gi.repository import Gio, GLib
from .async_bridge import AsyncBridge
from .word_definition_target import word_definition_target
from .word_definition_lookup import word_definition_worker, word_definition_availability_worker
from .word_definition_availability import WordDefinitionAvailability, page_definition_targets

NAME = "org.azookey.Tree"
PATH = "/org/azookey/Tree"
XML = """<node><interface name="org.azookey.Tree">
  <method name="ResetLearning"><arg type="b" direction="out"/></method>
  <method name="DescribeLayout"><arg type="s" direction="out"/></method>
  <method name="RendererStatus"><arg type="b" direction="out"/></method>
  <method name="SetRenderer"><arg type="b" direction="in"/></method>
  <method name="Select"><arg type="s" direction="in"/><arg type="i" direction="in"/>
    <arg type="b" direction="in"/><arg type="i" direction="in"/><arg type="s" direction="in"/></method>
  <method name="LookupWordDefinitions"><arg type="s" direction="in"/><arg type="i" direction="in"/>
    <arg type="s" direction="in"/><arg type="i" direction="in"/><arg type="s" direction="out"/></method>
  <method name="LookupWordDefinitionAvailability"><arg type="s" direction="in"/>
    <arg type="i" direction="in"/><arg type="s" direction="out"/></method>
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
        if name == "LookupWordDefinitions" and sender == self.renderer:
            self.lookup_word_definitions(sender, values, invocation)
            return
        if name == "LookupWordDefinitionAvailability" and sender == self.renderer:
            self.lookup_word_definition_availability(sender, values, invocation)
            return
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

    def lookup_word_definitions(self, sender, values, invocation):
        engine = self.engine() if self.engine else None
        context, generation, kind, index = values
        revision = object()
        self.definition_revision = revision
        if (not engine or not engine.focused or engine.input.pending or context != engine.context_id
                or generation != engine.snapshot.get("generation")
                or engine.snapshot.get("inputState") not in ("selecting", "previewing", "replaceSuggestion")
                or kind not in ("node", "candidate")):
            invocation.return_dbus_error(NAME + ".Stale", "The dictionary target is no longer active")
            return
        arguments = {"node_id" if kind == "node" else "candidate_index": index}
        target = word_definition_target(engine.snapshot, **arguments)
        if target is None:
            invocation.return_value(GLib.Variant("(s)", (json.dumps({"status": "noTarget"}),)))
            return
        focus_revision = engine.focus_revision
        input_epoch = engine.input.cancelled

        def completed(response):
            current = self.engine() if self.engine else None
            if (response.get("status") == "stale" or self.definition_revision is not revision
                    or current is not engine or self.renderer != sender or not engine.focused or engine.input.pending
                    or engine.focus_revision is not focus_revision or engine.input.cancelled is not input_epoch
                    or word_definition_target(engine.snapshot, **arguments) != target):
                invocation.return_dbus_error(NAME + ".Stale", "The dictionary target has changed")
                return
            invocation.return_value(GLib.Variant("(s)", (json.dumps(response, ensure_ascii=False),)))

        word_definition_worker().request(target, completed)

    def lookup_word_definition_availability(self, sender, values, invocation):
        engine = self.engine() if self.engine else None
        context, generation = values
        if (not engine or not engine.focused or engine.input.pending or context != engine.context_id
                or generation != engine.snapshot.get("generation")
                or engine.snapshot.get("inputState") not in ("selecting", "previewing", "replaceSuggestion")):
            invocation.return_dbus_error(NAME + ".Stale", "The candidate page is no longer active")
            return
        previous = getattr(self, "availability_request", None)
        if previous:
            previous[0].invalidate()
            previous[1].return_dbus_error(NAME + ".Stale", "The candidate page has changed")
        snapshot = {**engine.snapshot, "contextId": context}
        targets = page_definition_targets(snapshot)
        focus_revision = engine.focus_revision
        input_epoch = engine.input.cancelled

        def completed():
            self.availability_request = None
            current = self.engine() if self.engine else None
            if (current is not engine or self.renderer != sender or not engine.focused or engine.input.pending
                    or engine.focus_revision is not focus_revision or engine.input.cancelled is not input_epoch
                    or context != engine.context_id or generation != engine.snapshot.get("generation")
                    or engine.snapshot.get("inputState") not in ("selecting", "previewing", "replaceSuggestion")
                    or page_definition_targets({**engine.snapshot, "contextId": context}) != targets):
                invocation.return_dbus_error(NAME + ".Stale", "The candidate page has changed")
                return
            invocation.return_value(GLib.Variant("(s)", (json.dumps(sorted(lookup.found_indices)),)))

        lookup = WordDefinitionAvailability(word_definition_availability_worker(), lambda _indices: None,
                                            completed=completed)
        self.availability_request = (lookup, invocation)
        lookup.update(snapshot)

    def lost(self):
        self.renderer = None
        if self.watch:
            Gio.bus_unwatch_name(self.watch)
        self.watch = 0
        engine = self.engine() if self.engine else None
        # The visible preedit may already contain keys absent from this snapshot.
        # Their reply will restore the fallback renderer without losing input.
        if engine and not engine.input.has_pending_preview:
            engine.render(engine.snapshot)

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
