"""Verify composition editing through the real IBus key and preedit signals."""
import time

import gi

gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus


# Allow a loaded CI machine to deliver the asynchronous IBus response.
RESPONSE_TIMEOUT_SECONDS = 5

IBus.init()
bus = IBus.Bus()
assert bus.is_connected(), "IBus daemon is unavailable"
context = bus.create_input_context("azookey-composition-editing-test")
context.set_capabilities(
    IBus.Capabilite.PREEDIT_TEXT
    | IBus.Capabilite.FOCUS
    | IBus.Capabilite.SURROUNDING_TEXT
)
committed = []
preedit = {"text": "", "cursor": 0}
context.connect("commit-text", lambda _context, text: committed.append(text.get_text()))


def update_preedit(_context, text, cursor, _visible):
    preedit.update(text=text.get_text(), cursor=cursor)


def wait_until(predicate, message):
    deadline = time.monotonic() + RESPONSE_TIMEOUT_SECONDS
    timeout = GLib.timeout_source_new(int(RESPONSE_TIMEOUT_SECONDS * 1000))
    timeout.set_callback(lambda *_: False)
    timeout.attach()
    try:
        while not predicate():
            assert time.monotonic() < deadline, f"{message}: preedit={preedit!r}, commits={committed!r}"
            GLib.MainContext.default().iteration(True)
    finally:
        timeout.destroy()


def key(keyval, modifiers=0):
    assert context.process_key_event(keyval, 0, modifiers), f"unhandled key: {keyval}"


def type_text(text):
    for character in text:
        key(ord(character))


context.connect("update-preedit-text", update_preedit)
context.focus_in()
# SetEngine is asynchronous at the high-level API; wait for its reply before typing.
context.call_sync(
    "SetEngine",
    GLib.Variant("(s)", ("azookey-tree",)),
    Gio.DBusCallFlags.NONE,
    int(RESPONSE_TIMEOUT_SECONDS * 1000),
    None,
)
context.set_cursor_location(40, 40, 2, 20)

type_text("nihongo")
key(IBus.KEY_Left)
wait_until(lambda: preedit == {"text": "にほんご", "cursor": 3}, "Left must move within the reading")
type_text("a")
wait_until(lambda: preedit == {"text": "にほんあご", "cursor": 4}, "Insertion must follow the displayed cursor")
key(IBus.KEY_BackSpace)
wait_until(lambda: preedit == {"text": "にほんご", "cursor": 3}, "Backspace must remove the preceding character")
key(IBus.KEY_Delete)
wait_until(lambda: preedit == {"text": "にほん", "cursor": 3}, "Delete must remove the following character")
key(IBus.KEY_Home)
wait_until(lambda: preedit["cursor"] == 0, "Home must move to the beginning")
key(IBus.KEY_End)
wait_until(lambda: preedit["cursor"] == 3, "End must move to the end")
key(IBus.KEY_Return)
wait_until(lambda: committed == ["にほん"], "Enter must commit the edited reading")

for function_key, expected_prefix in [(IBus.KEY_F10, "nihongo"), (IBus.KEY_F9, "ｎｉｈｏｎｇｏ")]:
    context.reset()
    type_text("nihongowobenkyou")
    for _ in range(6):
        key(IBus.KEY_Left, IBus.ModifierType.SHIFT_MASK)
    wait_until(
        lambda: preedit == {"text": "日本語をべんきょう", "cursor": 3},
        "Shift+Left must leave the unconverted suffix",
    )
    committed_count = len(committed)
    key(function_key)
    wait_until(
        lambda: len(committed) == committed_count + 1 and committed[-1] == expected_prefix,
        "Roman conversion must commit only the edited prefix",
    )
    key(IBus.KEY_BackSpace)
    wait_until(
        lambda: preedit == {"text": "をべんきょ", "cursor": 5},
        "The suffix must remain editable after the partial commit",
    )

context.reset()
context.focus_out()
print("PASS: real IBus caret editing, segment ranges, partial F9/F10 commits and suffix editing")
