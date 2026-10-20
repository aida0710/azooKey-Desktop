"""Exercise the real IBus service over a private D-Bus session."""
import time
import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus, GLib, Gio
import json
from ibus_support import crash_converter

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


def wait_for(predicate, message):
    deadline = time.monotonic() + 5
    while not predicate():
        assert time.monotonic() < deadline, message
        GLib.MainContext.default().iteration(False)
        time.sleep(0.005)


context.focus_in()
context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)), Gio.DBusCallFlags.NONE, 5000, None)
context.set_cursor_location(40, 40, 2, 20)
drain()
for character in "nihongo":
    assert context.process_key_event(ord(character), 0, 0), f"unhandled key: {character}"
    drain()
assert context.process_key_event(IBus.KEY_space, 0, 0)
drain()
assert context.process_key_event(IBus.KEY_Return, 0, 0)
wait_for(lambda: committed == ["日本語"], "conversion did not commit")
assert committed == ["日本語"], f"unexpected committed text: {committed!r}"
assert preedits, "IBus never received a preedit update"
context.reset()
context.set_content_type(IBus.InputPurpose.PASSWORD, IBus.InputHints.NONE)
drain()
assert not context.process_key_event(ord("x"), 0, 0), "password input must bypass the engine"
context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
drain()
assert context.process_key_event(ord("a"), 0, 0), "private text fields still support Japanese input"
assert context.process_key_event(IBus.KEY_Escape, 0, 0)
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
wait_for(lambda: updates and updates[-1].get("reading") == "にほんご" and updates[-1].get("showCandidateIndex"),
         "renderer never received the completed selection")
snapshot = updates[-1]
detail_scrolls = []
detail_subscription = connection.signal_subscribe(
    "org.azookey.Tree", "org.azookey.Tree", "ScrollDetails", "/org/azookey/Tree", None,
    Gio.DBusSignalFlags.NONE, lambda _c, _s, _p, _i, _n, values: detail_scrolls.append(values.unpack()[0]),
)
for detail_key in (IBus.KEY_Page_Down, IBus.KEY_Page_Up):
    assert context.process_key_event(detail_key, 0, 0), "candidate detail key must be consumed"
wait_for(lambda: detail_scrolls == [True, False], "detail keys did not reach the registered renderer")
assert committed == ["日本語"], "reading candidate details must not commit"
connection.signal_unsubscribe(detail_subscription)
candidate = next(item for item in snapshot["candidates"] if item["text"] == "日本語")
connection.call_sync("org.azookey.Tree", "/org/azookey/Tree", "org.azookey.Tree", "Select",
                     GLib.Variant("(sibis)", ("select", candidate["index"], True, snapshot["generation"], snapshot["contextId"])),
                     None, Gio.DBusCallFlags.NONE, 3000, None)
wait_for(lambda: committed == ["日本語", "日本語"], "renderer selection did not commit")
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
wait_for(lambda: committed[-1] == "nihongo", "double Muhenkan did not commit")
assert committed[-1] == "nihongo", "double Muhenkan must commit roman text even with AI disabled"

context.process_key_event(IBus.KEY_Henkan, 0, 0)
context.process_key_event(ord("a"), 0, 0)
drain()
count = len(committed)
crash_converter(connection, "azookey-desktop-bridge")
context.reset()
wait_for(lambda: len(committed) == count + 1, "reset did not recover preedit")
# IBus COMMIT mode commits before sending Reset/FocusOut to the engine:
# https://ibus.github.io/docs/ibus-1.5/IBusEngine.html#ibus-engine-update-preedit-text-with-mode
# Escape is the explicit cancellation path; Reset must not commit a second time.
assert len(committed) == count + 1, "IBus reset must recover preedit exactly once after a crash"
preedit_count = len(preedits)
context.process_key_event(ord("a"), 0, 0)
wait_for(lambda: len(preedits) > preedit_count and preedits[-1] == "あ",
         "fresh converter did not acknowledge the composition")
visible = preedits[-1]
assert visible
crash_converter(connection, "azookey-desktop-bridge")
context.process_key_event(ord("i"), 0, 0)
context.process_key_event(IBus.KEY_Return, 0, 0)
wait_for(lambda: committed[-2:] == [visible, "い"], "restarted converter did not recover input")
assert committed[-2:] == [visible, "い"], "recovery must preserve visible input once and accept new Japanese input"
context.focus_out()
print("PASS: real IBus input, conversion, privacy hints, renderer selection, double language key and crash recovery")
