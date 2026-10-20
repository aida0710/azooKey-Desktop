"""Exercise reconversion through actual IBus deletion and preedit signals."""
import time

import gi

gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus


RESPONSE_TIMEOUT_SECONDS = 5
CONTROL_SHIFT = IBus.ModifierType.CONTROL_MASK | IBus.ModifierType.SHIFT_MASK

IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
context = bus.create_input_context("azookey-reconversion-test")
context.set_capabilities(
    IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.AUXILIARY_TEXT
    | IBus.Capabilite.FOCUS | IBus.Capabilite.SURROUNDING_TEXT
)
document = {"text": "前日本語後", "cursor": 4, "anchor": 1, "editable": True}
preedit = {"text": "", "cursor": 0}
auxiliary = {"text": ""}
commits = []
deletions = []


def surrounding():
    context.set_surrounding_text(IBus.Text.new_from_string(document["text"]), document["cursor"], document["anchor"])


def update_preedit(_context, text, cursor, _visible):
    preedit.update(text=text.get_text(), cursor=cursor)


def commit(_context, text):
    value = text.get_text()
    start, end = sorted((document["cursor"], document["anchor"]))
    document["text"] = document["text"][:start] + value + document["text"][end:]
    document["cursor"] = document["anchor"] = start + len(value)
    commits.append(value)
    surrounding()


def delete(_context, offset, count):
    deletions.append((offset, count))
    if not document["editable"]:
        return
    start = document["cursor"] + offset
    assert 0 <= start <= len(document["text"]) and start + count <= len(document["text"])
    document["text"] = document["text"][:start] + document["text"][start + count:]
    document["cursor"] = document["anchor"] = start
    surrounding()


def wait_until(predicate, reason):
    deadline = time.monotonic() + RESPONSE_TIMEOUT_SECONDS
    timeout = GLib.timeout_source_new(int(RESPONSE_TIMEOUT_SECONDS * 1000))
    timeout.set_callback(lambda *_: False)
    timeout.attach()
    try:
        while not predicate():
            assert time.monotonic() < deadline, f"{reason}: {document!r}, {preedit!r}, {auxiliary!r}, {commits!r}, {deletions!r}"
            GLib.MainContext.default().iteration(True)
    finally:
        timeout.destroy()


def key(keyval, modifiers=0):
    assert context.process_key_event(keyval, 0, modifiers), f"unhandled: {keyval}"


def type_text(text):
    for character in text:
        key(ord(character))


context.connect("update-preedit-text", update_preedit)
context.connect("update-auxiliary-text", lambda _context, text, _visible: auxiliary.update(text=text.get_text()))
context.connect("commit-text", commit)
context.connect("delete-surrounding-text", delete)
context.connect("require-surrounding-text", lambda _context: surrounding())
context.focus_in()
context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                  Gio.DBusCallFlags.NONE, int(RESPONSE_TIMEOUT_SECONDS * 1000), None)
context.set_cursor_location(40, 40, 2, 20)
wait_until(context.needs_surrounding_text, "The engine must request surrounding text before the first key")
surrounding()

key(ord("r"), CONTROL_SHIFT)
wait_until(lambda: "読みを入力" in auxiliary["text"], "Unknown reading must use the local prompt")
assert document["text"] == "前日本語後" and deletions == [] and preedit["text"] == ""
type_text("nihongo")
key(IBus.KEY_Return)
wait_until(lambda: len(deletions) == 1 and preedit["text"] == "日本語", "Selection must be replaced only after reading submission")
assert document["text"] == "前後"
# Later Esc presses are native once an earlier press ends composition.
# The original replies now report that decision instead of acknowledging early.
cancellation_replies = [context.process_key_event(IBus.KEY_Escape, 0, 0) for _ in range(3)]
assert cancellation_replies[0], cancellation_replies
wait_until(lambda: commits == ["日本語"] and preedit["text"] == "", "Cancel must restore original once")
assert document["text"] == "前日本語後"

# A subsequent real commit is undoable only at the same surrounding position.
type_text("hashi")
key(IBus.KEY_F10)
wait_until(lambda: commits[-1] == "hashi", "F10 must commit the original Roman spelling")
key(IBus.KEY_BackSpace, CONTROL_SHIFT)
wait_until(lambda: len(deletions) == 2 and bool(preedit["text"]), "Commit undo must restore composition")
key(IBus.KEY_F10)
wait_until(lambda: commits.count("hashi") == 2 and preedit["text"] == "", "Restored raw input must commit once")
assert document["text"] == "前日本語hashi後"

# A read-only client may advertise surrounding text but ignore deletion.
document.update(text="前ニホンゴ後", cursor=5, anchor=1, editable=False)
surrounding()
key(ord("r"), CONTROL_SHIFT)
wait_until(lambda: len(deletions) == 3, "Known kana should prepare a range")
wait_until(lambda: "置換を確認できません" in auxiliary["text"], "Ignored deletion must report unavailable")
assert document["text"] == "前ニホンゴ後" and preedit["text"] == ""
assert len(deletions) == 3

context.focus_out()
print("PASS: real IBus local reading prompt, selection cancel, raw-input commit undo, and ignored deletion")
