"""Use real IBus calls and the registered renderer, without injecting Core state."""
import json
import os
from pathlib import Path
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus


WAIT_SECONDS = 5  # Diagnose a missing local acknowledgement, not a paint budget.
POLL_SECONDS = 0.005
SURFACE_NAME = "org.azookey.Tree"
SURFACE_PATH = "/org/azookey/Tree"


def wait_for(predicate, description):
    deadline = time.monotonic() + WAIT_SECONDS
    while not predicate():
        if time.monotonic() >= deadline:
            raise AssertionError(description)
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        time.sleep(POLL_SECONDS)


def surface_call(method, parameters):
    return connection.call_sync(SURFACE_NAME, SURFACE_PATH, SURFACE_NAME, method, parameters,
                                None, Gio.DBusCallFlags.NONE, 3000, None)


def select(snapshot, candidate, *, submit):
    surface_call("Select", GLib.Variant("(sibis)", (
        "select", candidate["index"], submit, snapshot["generation"], snapshot["contextId"],
    )))


def key(context, value):
    assert context.process_key_event(value, 0, 0), f"unhandled fixture key {value}"


def candidates_for(context, reading, raw):
    previous = len(updates)
    for character in raw:
        key(context, ord(character))
    key(context, IBus.KEY_space)
    wait_for(lambda: len(updates) > previous and updates[-1].get("reading") == reading
             and updates[-1].get("candidates"), "reading candidates did not arrive")
    snapshot = updates[-1]
    assert snapshot["inputState"] == "composing" and snapshot.get("selection") is None, snapshot
    assert snapshot["candidateDisplayMode"] == "menu" and snapshot["preedit"] == reading
    return snapshot


def make_context(label):
    context = bus.create_input_context(label)
    context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS | IBus.Capabilite.SURROUNDING_TEXT)
    commits, preedits = [], []
    context.connect("commit-text", lambda _context, text: commits.append(text.get_text()))
    context.connect("update-preedit-text", lambda _context, text, cursor, visible: preedits.append(text.get_text()))
    context.focus_in()
    context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)), Gio.DBusCallFlags.NONE, 5000, None)
    context.set_cursor_location(40, 40, 2, 20)
    return context, commits, preedits


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
updates = []
subscription = connection.signal_subscribe(
    SURFACE_NAME, SURFACE_NAME, "Update", SURFACE_PATH, None, Gio.DBusSignalFlags.NONE,
    lambda _connection, _sender, _path, _interface, _name, parameters: updates.append(json.loads(parameters.unpack()[0])),
)
first, first_commits, first_preedits = make_context("reading-candidate-first")
surface_call("SetRenderer", GLib.Variant("(b)", (True,)))
arrival = candidates_for(first, "にほんご", "nihongo")
assert first_commits == []
# IBus may publish empty preedit resets while activating the initial engine.
# Keep that history, then count every update from the first actual input onward.
input_start = next(index for index, value in enumerate(first_preedits) if value)
assert len(first_preedits[input_start:]) == len("nihongo") + 1, first_preedits
assert first_preedits[-2:] == ["にほんご", "にほんご"], first_preedits
candidate = next(item for item in arrival["candidates"] if item["text"] == "日本語")
select(arrival, candidate, submit=False)
wait_for(lambda: updates[-1].get("selection") == candidate["index"]
         and updates[-1]["inputState"] == "selecting", "explicit selection did not reach the reader")
selected = updates[-1]
assert first_commits == []
assert selected["candidates"][candidate["index"]]["candidateID"] == candidate["candidateID"]
select(arrival, candidate, submit=True)  # Retired generation cannot confirm.
select(selected, candidate, submit=True)
select(selected, candidate, submit=True)  # Same action cannot enqueue twice.
wait_for(lambda: first_commits == ["日本語"] and first_preedits[-1] == "", "atomic confirmation did not commit once")
key(first, ord("a"))
key(first, IBus.KEY_Return)
wait_for(lambda: first_commits == ["日本語", "あ"], "continuing input did not stay in the first field")

partial_snapshot = candidates_for(first, "きょうはにほんご", "kyouhanihongo")
partial = next(item for item in partial_snapshot["candidates"] if item["text"] == "今日")
assert partial["commitScope"]["remainingReading"] == "はにほんご"
select(partial_snapshot, partial, submit=True)
wait_for(lambda: first_commits == ["日本語", "あ", "今日"] and first_preedits[-1] == "はにほんご",
         "partial direct commit changed the formal suffix")
key(first, ord("a"))
key(first, IBus.KEY_Return)
wait_for(lambda: first_commits == ["日本語", "あ", "今日", "はにほんごあ"], "suffix editing did not preserve the exact reading")

first.focus_out()
second, second_commits, second_preedits = make_context("reading-candidate-second")
select(selected, candidate, submit=True)
key(second, ord("k"))
key(second, ord("a"))
key(second, IBus.KEY_Return)
wait_for(lambda: second_commits == ["か"], "next field did not receive its own input")
assert first_commits == ["日本語", "あ", "今日", "はにほんごあ"]
assert second_commits == ["か"]
second.focus_out()
surface_call("SetRenderer", GLib.Variant("(b)", (False,)))
connection.signal_unsubscribe(subscription)

evidence = os.environ.get("AZOOKEY_READING_CANDIDATE_EVIDENCE")
if evidence:
    Path(evidence).write_text(json.dumps({
        "firstCommits": first_commits, "firstPreedits": first_preedits,
        "secondCommits": second_commits, "secondPreedits": second_preedits,
        "arrival": arrival, "selected": selected, "partial": partial_snapshot,
        "inputEffectOnArrival": False, "staleGenerationAndFocusAccepted": False,
    }, ensure_ascii=False, indent=2) + "\n")
print("PASS: reading renderer arrival, exact-ID selection/atomic commit, partial suffix, stale actions and separate fields")
