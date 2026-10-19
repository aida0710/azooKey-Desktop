"""Exercise the real IBus service over a private D-Bus session."""
import time
import os
import pathlib
import signal
import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus, GLib, Gio
import json

IBus.init()
bus = IBus.Bus()
assert bus.is_connected(), "IBus daemon is unavailable"
context = bus.create_input_context("azookey-integration-test")
context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS | IBus.Capabilite.SURROUNDING_TEXT)
committed = []
preedits = []
context.connect("commit-text", lambda _context, text: committed.append(text.get_text()))
context.connect("update-preedit-text", lambda _context, text, cursor, visible: preedits.append(text.get_text()))


def drain():
    limit = time.monotonic() + 0.15
    while time.monotonic() < limit:
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        time.sleep(0.005)


context.focus_in()
context.set_engine("azookey-tree")
context.set_cursor_location(40, 40, 2, 20)
drain()
for character in "nihongo":
    assert context.process_key_event(ord(character), 0, 0), f"unhandled key: {character}"
    drain()
assert context.process_key_event(IBus.KEY_space, 0, 0)
drain()
assert context.process_key_event(IBus.KEY_Return, 0, 0)
drain()
assert committed == ["日本語"], f"unexpected committed text: {committed!r}"
assert preedits, "IBus never received a preedit update"
context.reset()
context.set_content_type(IBus.InputPurpose.PASSWORD, IBus.InputHints.NONE)
drain()
assert not context.process_key_event(ord("x"), 0, 0), "password input must bypass the engine"
context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
drain()
assert context.process_key_event(ord("a"), 0, 0), "private text fields still support Japanese input"
context.reset()
context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.NONE)

# A renderer receives a private snapshot and returns the original candidate
# index with both the input-context ID and the composition generation.
updates = []
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
subscription = connection.signal_subscribe("org.azookey.Tree", "org.azookey.Tree", "Update", "/org/azookey/Tree", None,
                                          Gio.DBusSignalFlags.NONE, lambda _c, _s, _p, _i, _n, values: updates.append(json.loads(values.unpack()[0])))
connection.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "SetRenderer",
                     GLib.Variant("(b)", (True,)), None, Gio.DBusCallFlags.NONE, 3000, None)
for character in "nihongo":
    context.process_key_event(ord(character), 0, 0)
context.process_key_event(IBus.KEY_space, 0, 0)
drain()
snapshot = updates[-1]
candidate = next(item for item in snapshot["candidates"] if item["text"] == "日本語")
connection.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "Select",
                     GLib.Variant("(sibis)", ("select", candidate["index"], True, snapshot["generation"], snapshot["contextId"])),
                     None, Gio.DBusCallFlags.NONE, 3000, None)
drain()
assert committed == ["日本語", "日本語"], "renderer did not commit the selected original candidate"
connection.signal_unsubscribe(subscription)
connection.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "SetRenderer",
                     GLib.Variant("(b)", (False,)), None, Gio.DBusCallFlags.NONE, 3000, None)
context.focus_out()
context.focus_in()
for character in "nihongo":
    context.process_key_event(ord(character), 0, 0)
context.process_key_event(IBus.KEY_Muhenkan, 0, 0)
context.process_key_event(IBus.KEY_Muhenkan, 0, 0)
drain()
assert committed[-1] == "nihongo", "double Muhenkan must commit roman text even with AI disabled"

def crash_test_converter():
    # Only the child of this private test bus's renderer owner can be killed.
    pid = connection.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
                               "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.azookey.Tree",)),
                               GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None).unpack()[0]
    children = pathlib.Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
    targets = [int(child) for child in children
               if b"azookey-desktop-bridge" in pathlib.Path(f"/proc/{child}/cmdline").read_bytes()]
    assert len(targets) == 1, "test must identify exactly one converter belonging to its own service"
    os.kill(targets[0], signal.SIGKILL)
    drain()

context.process_key_event(IBus.KEY_Henkan, 0, 0)
context.process_key_event(ord("a"), 0, 0)
drain()
count = len(committed)
crash_test_converter()
context.reset()
drain()
assert len(committed) == count, "explicit reset must discard, not commit, preedit after a crash"
context.process_key_event(ord("a"), 0, 0)
drain()
visible = preedits[-1]
assert visible
crash_test_converter()
context.process_key_event(ord("i"), 0, 0)
context.process_key_event(IBus.KEY_Return, 0, 0)
drain()
assert committed[-2:] == [visible, "い"], "recovery must preserve visible input once and accept new Japanese input"
context.focus_out()
print("PASS: real IBus input, conversion, privacy hints, renderer selection, double language key and crash recovery")
