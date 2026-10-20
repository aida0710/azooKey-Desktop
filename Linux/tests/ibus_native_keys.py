"""Verify original native replies, ordering and cancellation on real IBus."""
import json
import os
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus
from ibus_support import crash_converter


WAIT_SECONDS = 15
RESPONSIVE_SECONDS = 0.1


def wait_for(predicate):
    deadline = time.monotonic() + WAIT_SECONDS
    while not predicate():
        assert time.monotonic() < deadline, "native-key IBus observation did not complete"
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
        self.context.process_key_event_async(keyval, 38, state, -1, None, completed, None)


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
control = IBus.ModifierType.CONTROL_MASK
shift = IBus.ModifierType.SHIFT_MASK

field = Field(bus, "azookey-native-original")
field.focus()
field.send(IBus.KEY_Home, control)
wait_for(lambda: len(field.replies) == 1)
assert not field.replies[0]["consumed"] and not field.forwarded

field.send(IBus.KEY_Muhenkan)
field.send(ord("A"), shift)
field.send(IBus.KEY_Left)
field.send(ord("B"), shift)
wait_for(lambda: len(field.replies) == 5)
assert field.document == "BA" and field.cursor == 1, field.document
assert not field.commits and not field.forwarded
assert [reply["consumed"] for reply in field.replies[1:]] == [True, False, False, False]

field.send(IBus.KEY_Henkan)
field.send(ord("a"))
field.send(IBus.KEY_Return)
field.send(IBus.KEY_Control_L)
field.send(IBus.KEY_Home, control)
field.send(IBus.KEY_Home, control | IBus.ModifierType.RELEASE_MASK)
field.send(IBus.KEY_Control_L, control | IBus.ModifierType.RELEASE_MASK)
# The daemon and both endpoints' main loops remain available while a native
# reply waits for preceding work. This is separate from reply latency.
start = time.monotonic()
assert field.context.get_engine().get_name() == "azookey-tree"
bus_query_seconds = time.monotonic() - start
assert bus_query_seconds < RESPONSIVE_SECONDS, bus_query_seconds
wait_for(lambda: len(field.replies) == 12)
assert field.commits == ["a"] and field.document == "BaA" and field.cursor == 0
assert not field.replies[-1]["consumed"] and not field.forwarded
assert [reply["keyval"] for reply in field.replies[-3:]] == [
    IBus.KEY_Home, IBus.KEY_Home, IBus.KEY_Control_L,
]

field.context.focus_out()
old = Field(bus, "azookey-native-focus-old")
new = Field(bus, "azookey-native-focus-new")
old.focus()
old.send(IBus.KEY_Muhenkan)
old.send(ord("A"), shift)
wait_for(lambda: old.preedit == "A")
old.context.focus_out()
new.focus()
wait_for(lambda: len(old.replies) == 2)
assert old.commits == ["A"] and old.replies[-1]["consumed"]
assert not old.forwarded and not new.commits and new.document == ""

new.send(IBus.KEY_Henkan)
new.send(ord("a"))
new.send(IBus.KEY_Return)
new.send(IBus.KEY_Home, control)
new.send(ord("b"))
wait_for(lambda: new.preedit == "ab")
new.context.focus_out()
old.focus()
wait_for(lambda: len(new.replies) == 5)
assert new.commits == ["ab"] and not new.forwarded
assert all(reply["consumed"] for reply in new.replies)
old.context.focus_out()
new.focus()
new.replies.clear()
new.commits.clear()

new.send(IBus.KEY_Muhenkan)
new.send(ord("A"), shift)
wait_for(lambda: new.preedit == "A")
new.context.reset()
wait_for(lambda: len(new.replies) == 2)
assert new.commits == ["A"] and new.replies[-1]["consumed"]
assert not new.forwarded
new.send(IBus.KEY_Henkan)
wait_for(lambda: len(new.replies) == 3)
document_before_failure, cursor_before_failure = new.document, new.cursor
delivery_count = len(new.deliveries)
new.send(ord("h"))
new.send(IBus.KEY_Return)
new.send(IBus.KEY_Home, control)
wait_for(lambda: len(new.replies) == 6)
assert not new.replies[-1]["consumed"]
assert all(key[0] != IBus.KEY_Home for key in new.forwarded)
failure_deliveries = new.deliveries[delivery_count:]
assert [event["keyval"] for event in failure_deliveries] == [ord("h"), IBus.KEY_Return, IBus.KEY_Home]
assert new.document == (document_before_failure[:cursor_before_failure]
                        + "h\n" + document_before_failure[cursor_before_failure:])
assert new.cursor == 0
reply_count = len(new.replies)
crash_converter(Gio.bus_get_sync(Gio.BusType.SESSION, None), "delayed_bridge.py")
new.send(IBus.KEY_Henkan)
wait_for(lambda: len(new.replies) == reply_count + 1)
assert not old.forwarded and old.commits == ["A"] and len(old.replies) == 2
print(json.dumps({
    "status": "PASS", "delaySeconds": float(os.environ["AZOOKEY_TEST_DELAY"]),
    "nativeReplyUsesOriginalEvent": True, "duplicateReplies": 0,
    "daemonQueryWhileWaitingSeconds": bus_query_seconds, "replies": field.replies,
    "failureDeliveries": failure_deliveries,
}))
