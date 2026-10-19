import gi
gi.require_version("IBus", "1.0")
gi.require_version("Gtk", "3.0")
from gi.repository import IBus, Gdk
from .bridge import Bridge
from .keymap import translate
from .tree_panel import TreePanel


class Engine(IBus.Engine):
    __gtype_name__ = "AzooKeyTreeEngine"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.bridge = Bridge()
        self.panel = TreePanel(self.choose)
        self.snapshot = {}
        self.private = False
        self.left = ""
        self.right = ""
        self.table = IBus.LookupTable.new(9, 0, True, True)
        self.table.set_orientation(IBus.Orientation.VERTICAL)

    def request(self, operation, **values):
        result = self.bridge.request(operation, leftContext=self.left, rightContext=self.right, **values)
        self.render(result)
        return result.get("consumed", False)

    def do_process_key_event(self, keyval, keycode, state):
        event = translate(keyval, state)
        if event is None or self.private:
            return False
        try:
            return self.request("key", event=event)
        except (OSError, RuntimeError, ValueError):
            self.panel.hide()
            self.hide_preedit_text()
            self.hide_lookup_table()
            return False

    def do_set_content_type(self, purpose, hints):
        self.private = purpose in (IBus.InputPurpose.PASSWORD, IBus.InputPurpose.PIN)
        if self.private:
            self.request("reset", submit=False)

    def do_set_surrounding_text(self, text, cursor, anchor):
        value = text.get_text()
        self.left = value[:min(cursor, anchor)][-100:]
        self.right = value[max(cursor, anchor):][:100]

    def do_set_cursor_location(self, x, y, width, height):
        self.panel.location = (x, y, width, height)
        if self.panel.get_visible():
            self.panel.position()

    def do_focus_in(self):
        self.get_surrounding_text()

    def do_focus_out(self):
        # No composition is allowed to leak into the next input context.
        self.request("reset", submit=True)
        self.panel.hide()

    def do_reset(self):
        self.request("reset", submit=False)

    def do_disable(self):
        self.request("reset", submit=True)
        self.panel.hide()

    def do_destroy(self):
        self.panel.destroy()
        self.bridge.close()
        super().do_destroy()

    def do_candidate_clicked(self, index, button, state):
        if button == 1:
            self.choose("select", self.table.get_current_page_start() + index, True)

    def choose(self, operation, index, submit):
        key = "node" if operation == "node" else "index"
        self.request(operation, **{key: index, "generation": self.snapshot.get("generation", -1), "submit": submit})

    def render(self, snapshot):
        self.snapshot = snapshot
        for text in snapshot.get("commits", []):
            self.commit_text(IBus.Text.new_from_string(text))
        preedit = snapshot.get("preedit", "")
        self.update_preedit_text(IBus.Text.new_from_string(preedit), snapshot.get("cursor", 0), bool(preedit))
        self.table.clear()
        for candidate in snapshot.get("candidates", []):
            self.table.append_candidate(IBus.Text.new_from_string(candidate["text"]))
        self.table.set_cursor_pos(snapshot.get("selection") or 0)
        # GNOME/Wayland requires compositor integration for custom popup geometry.
        # Keep the native lookup usable while that integration is developed.
        is_wayland = "Wayland" in type(Gdk.Display.get_default()).__name__
        if is_wayland:
            self.panel.hide()
            self.update_lookup_table(self.table, bool(snapshot.get("candidates")))
        else:
            self.hide_lookup_table()
            self.panel.update(snapshot)
