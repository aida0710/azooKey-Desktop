"""Losing the renderer must not resend preedit through the real IBus service."""
import json

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus

from ibus_native_field import Field, wait_for


# Local service calls must fail promptly when the isolated fixture exits.
BUS_CALL_TIMEOUT_MS = 3000
TREE_NAME = "org.azookey.Tree"
TREE_PATH = "/org/azookey/Tree"


def tree_call(connection, method, parameters=None):
    return connection.call_sync(
        TREE_NAME, TREE_PATH, TREE_NAME, method, parameters, None,
        Gio.DBusCallFlags.NONE, BUS_CALL_TIMEOUT_MS, None,
    ).unpack()


def send_key(field, keyval, *, state=0):
    reply_count = len(field.replies)
    field.send(keyval, state)
    wait_for(lambda: len(field.replies) == reply_count + 1)
    return field.replies[-1]["consumed"]


IBus.init()
bus = IBus.Bus()
assert bus.is_connected(), "the isolated IBus daemon must be running"
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
field = Field(bus, "azookey-renderer-loss")
field.focus()
wait_for(lambda: connection.call_sync(
    "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
    "NameHasOwner", GLib.Variant("(s)", (TREE_NAME,)), None,
    Gio.DBusCallFlags.NONE, BUS_CALL_TIMEOUT_MS, None,
).unpack()[0])
# The renderer must own a separate connection so losing it keeps the client alive.
renderer = Gio.DBusConnection.new_for_address_sync(
    Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None),
    Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
    None, None,
)
updates = []
renderer.signal_subscribe(
    TREE_NAME, TREE_NAME, "Update", TREE_PATH, None, Gio.DBusSignalFlags.NONE,
    lambda _c, _s, _p, _i, _n, values: updates.append(json.loads(values.unpack()[0])),
)
tree_call(renderer, "SetRenderer", GLib.Variant("(b)", (True,)))

preedits = []
mode_updates = []
field.context.connect(
    "update-preedit-text",
    lambda _context, value, cursor, visible: preedits.append((value.get_text(), cursor, visible)),
)
field.context.connect("update-property", lambda _context, value: mode_updates.append(value.get_key()))
field.context.set_cursor_location(40, 40, 2, 20)
for character in "nihongo":
    assert send_key(field, ord(character))
assert send_key(field, IBus.KEY_space)
wait_for(lambda: updates and updates[-1].get("reading") == "にほんご"
         and updates[-1].get("showCandidateIndex"))
assert preedits and field.preedit
assert not field.commits
preedits_before_loss = list(preedits)
mode_updates_before_loss = list(mode_updates)
visible_before_loss = field.preedit

renderer.close_sync(None)
wait_for(lambda: not tree_call(connection, "RendererStatus")[0])
wait_for(lambda: json.loads(tree_call(connection, "DescribeLayout")[0]).get("renderer") == "gtk")
# This nonediting original reply follows the loss handler on the Engine's IBus
# connection. Await its callback to drain earlier client signals, not a sleep.
assert not send_key(field, IBus.KEY_Shift_L, state=IBus.ModifierType.RELEASE_MASK)
assert preedits == preedits_before_loss, "renderer loss resent the application's preedit"
assert mode_updates == mode_updates_before_loss, "renderer loss resent the input language"
assert field.preedit == visible_before_loss and not field.commits

assert send_key(field, IBus.KEY_Return)
wait_for(lambda: field.commits == ["日本語"] and not field.preedit)
assert send_key(field, ord("a"))
assert send_key(field, IBus.KEY_Return)
wait_for(lambda: field.commits == ["日本語", "あ"] and not field.preedit)
assert field.document == "日本語あ" and not field.forwarded
field.context.focus_out()
print(json.dumps({
    "result": "PASS", "preeditBeforeLoss": visible_before_loss,
    "preeditUpdatesBeforeLoss": len(preedits_before_loss),
    "preeditUpdatesFromLoss": 0, "modeUpdatesFromLoss": 0,
    "commits": field.commits, "document": field.document, "originalReplies": field.replies,
}, ensure_ascii=False))
