"""Native IBus test client that distinguishes original replies from forwarding."""
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus


WAIT_SECONDS = 15
RESPONSIVE_SECONDS = 0.1
# Fixtures use the X11 hardware code for A; the explicit keyval supplies meaning.
SYNTHETIC_KEYCODE = 38


def wait_for(predicate, message="native-key IBus observation did not complete"):
    deadline = time.monotonic() + WAIT_SECONDS
    while not predicate():
        assert time.monotonic() < deadline, message
        GLib.MainContext.default().iteration(False)
        time.sleep(.005)
    while GLib.MainContext.default().pending():
        GLib.MainContext.default().iteration(False)


class Field:
    def __init__(self, bus, name):
        self.context = bus.create_input_context(name)
        self.context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS)
        self.preedit = ""
        self.commits = []
        self.forwarded = []
        self.deliveries = []
        self.replies = []
        self.document = ""
        self.cursor = 0
        self.context.connect("commit-text", self.commit)
        self.context.connect("forward-key-event", self.forward)
        self.context.connect("update-preedit-text", self.preedit_changed)

    def focus(self):
        self.context.focus_in()
        self.context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                               Gio.DBusCallFlags.NONE, 5000, None)
        assert self.context.get_engine()

    def commit(self, _context, text):
        self.commits.append(text.get_text())
        self.insert(text.get_text())

    def insert(self, text):
        self.document = self.document[:self.cursor] + text + self.document[self.cursor:]
        self.cursor += len(text)

    def forward(self, _context, keyval, keycode, state):
        self.forwarded.append((keyval, keycode, state))
        self.deliver_native(keyval, state, route="forward")

    def deliver_native(self, keyval, state, *, route):
        self.deliveries.append({"keyval": keyval, "state": int(state), "route": route})
        if state & IBus.ModifierType.RELEASE_MASK:
            return
        if keyval == IBus.KEY_Home:
            self.cursor = 0
        elif keyval == IBus.KEY_Left:
            self.cursor = max(0, self.cursor - 1)
        elif keyval == IBus.KEY_Return:
            self.insert("\n")
        elif 32 <= keyval <= 126 and not state & IBus.ModifierType.CONTROL_MASK:
            self.insert(chr(keyval))

    def preedit_changed(self, _context, text, _cursor, visible):
        self.preedit = text.get_text() if visible else ""

    def send(self, keyval, state=0):
        started = time.monotonic()
        def completed(context, response, _user_data):
            consumed = context.process_key_event_async_finish(response)
            self.replies.append({"keyval": keyval, "state": int(state), "consumed": consumed,
                                 "elapsedSeconds": time.monotonic() - started})
            if not consumed:
                # This fixture models delivery of the saved original event,
                # distinctly from receiving an Engine.ForwardKeyEvent signal.
                self.deliver_native(keyval, state, route="original-reply")
        self.context.process_key_event_async(keyval, SYNTHETIC_KEYCODE, state, -1, None, completed, None)
