"""Quiesce/restart the dedicated VM's installed IME for preference recovery."""
from ai_fixture_processes import installed_processes, require_stopped, stop_installed_processes


ENGINE_NAME = "azookey-tree"
COMPONENT_NAME = "org.freedesktop.IBus.AzooKeyTree"
ENGINE_SERVICE = "org.azookey.Tree"
FALLBACK_ENGINE = "xkb:us::eng"
# Deadlines bound a missing signal; they are never a successful completion gate.
ACK_TIMEOUT_MS = 10000


class InstalledRuntime:
    def __init__(self, installed_root):
        import gi
        gi.require_version("IBus", "1.0")
        from gi.repository import Gio, GLib, IBus
        self.Gio, self.GLib, self.IBus = Gio, GLib, IBus
        self.session_connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        IBus.init()
        self.bus = IBus.Bus()
        if not self.bus.is_connected():
            raise RuntimeError("The dedicated desktop IBus session is unavailable")
        self.installed_root = installed_root
        self.context = None
        self.labels = []
        self.commits = []

    def session_bus_value(self, method, name, reply_type):
        reply = self.session_connection.call_sync(
            "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
            method, self.GLib.Variant("(s)", (name,)),
            self.GLib.VariantType.new(reply_type), self.Gio.DBusCallFlags.NONE, ACK_TIMEOUT_MS, None,
        )
        return reply.unpack()[0]

    def engine_pid(self):
        # IBus's private bus lacks GetConnectionUnixProcessID. The same engine
        # owns the candidate service on the desktop's full session bus.
        if not self.session_bus_value("NameHasOwner", ENGINE_SERVICE, "(b)"):
            return None
        owner = self.session_bus_value("GetNameOwner", ENGINE_SERVICE, "(s)")
        process_id = self.session_bus_value("GetConnectionUnixProcessID", owner, "(u)")
        if self.session_bus_value("GetNameOwner", ENGINE_SERVICE, "(s)") != owner:
            raise RuntimeError("The engine service changed owner during process identification")
        return process_id

    def stop(self):
        engine = self.bus.get_global_engine()
        if engine is None or engine.get_name() not in (ENGINE_NAME, FALLBACK_ENGINE):
            raise RuntimeError("The current engine is outside this AI trial")
        owner = self.engine_pid()
        registered = self.bus.name_has_owner(COMPONENT_NAME)
        if engine.get_name() == ENGINE_NAME and (owner is None or not registered):
            raise RuntimeError("The active azooKey engine could not be identified; it was not stopped")
        if registered and owner is None:
            raise RuntimeError("The IBus component has no identifiable engine process; it was not stopped")
        if owner is not None and installed_processes(self.installed_root).get(owner) != "engine":
            raise RuntimeError("IBus is using a different engine source; it was not stopped")
        if not self.bus.set_global_engine(FALLBACK_ENGINE):
            raise RuntimeError("IBus did not acknowledge switching away from azooKey")
        stopped = stop_installed_processes(self.installed_root)
        self.require_stopped()
        return {"stoppedProcesses": stopped}

    def require_stopped(self):
        require_stopped(self.installed_root)
        if self.engine_pid() is not None or self.bus.name_has_owner(COMPONENT_NAME):
            raise RuntimeError("The installed IBus component restarted during restoration")

    def restart(self):
        self.require_stopped()
        self.context = self.bus.create_input_context("azookey-ux-ai-restoration")
        self.context.set_capabilities(
            self.IBus.Capabilite.FOCUS | self.IBus.Capabilite.PREEDIT_TEXT | self.IBus.Capabilite.PROPERTY,
        )
        self.context.connect("update-property", self.observe_property)
        self.context.connect("commit-text", lambda _context, text: self.commits.append(text.get_text()))
        self.context.focus_in()
        self.context.call_sync(
            "SetEngine", self.GLib.Variant("(s)", (ENGINE_NAME,)), self.Gio.DBusCallFlags.NONE,
            ACK_TIMEOUT_MS, None,
        )
        self.barrier()
        owner = self.engine_pid()
        if installed_processes(self.installed_root).get(owner) != "engine":
            raise RuntimeError("The restarted engine is not the installed package")
        return {"restartedEnginePID": owner, "startupAcknowledgements": list(self.labels)}

    def observe_property(self, _context, input_property):
        if input_property.get_key() == "InputMode":
            self.labels.append(input_property.get_label().get_text())

    def await_label(self, label, after):
        loop = self.GLib.MainLoop()

        def observed(*_arguments):
            if label in self.labels[after:]:
                loop.quit()

        connection = self.context.connect("update-property", observed)
        expired = []

        def timeout():
            expired.append(True)
            loop.quit()
            return False

        deadline = self.GLib.timeout_add(ACK_TIMEOUT_MS, timeout)
        try:
            if label not in self.labels[after:]:
                loop.run()
        finally:
            self.context.disconnect(connection)
            if not expired:
                self.GLib.source_remove(deadline)
        if expired:
            raise RuntimeError("The restarted IME did not acknowledge its settings barrier")

    def barrier(self):
        # The initial settings callback may enqueue configure after the first
        # key. Waiting for a second key's render crosses that configure too.
        # This private context has no application document and never commits.
        for key, label in ((self.IBus.KEY_Muhenkan, "A"), (self.IBus.KEY_Henkan, "あ")):
            previous = len(self.labels)
            if not self.context.process_key_event(key, 0, 0):
                raise RuntimeError("The restarted IME rejected the recovery barrier")
            self.await_label(label, previous)
        if self.commits:
            raise RuntimeError("The recovery context unexpectedly committed text")

    def close(self):
        if self.context is not None:
            self.context.focus_out()
            self.context.destroy()
            self.context = None
