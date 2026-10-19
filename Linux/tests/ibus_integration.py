"""Exercise the real IBus service over a private D-Bus session."""
import time
import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus, GLib

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
context.focus_out()
print("PASS: real IBus key input, preedit, candidate conversion and commit")
