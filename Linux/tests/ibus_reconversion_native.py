"""Delayed real-Core reconversion preserves original native IBus key replies."""
import json
import os
from pathlib import Path
import time

from ibus_native_field import Field, IBus, RESPONSIVE_SECONDS, wait_for


CONTROL = IBus.ModifierType.CONTROL_MASK
SHIFT = IBus.ModifierType.SHIFT_MASK
RELEASE = IBus.ModifierType.RELEASE_MASK
ORIGINAL = "前ニホンゴ後"


class ReconversionField(Field):
    def __init__(self, bus, name, *, hold_ack=False, editable=True):
        super().__init__(bus, name)
        self.document = ORIGINAL
        self.cursor, self.anchor = 5, 1
        self.hold_ack = hold_ack
        self.editable = editable
        self.deletions = []
        self.events = []
        self.visible_preedits = []
        self.auxiliary = ""
        self.context.set_capabilities(
            IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS
            | IBus.Capabilite.SURROUNDING_TEXT | IBus.Capabilite.AUXILIARY_TEXT,
        )
        self.context.connect("require-surrounding-text", lambda *_: self.surrounding())
        self.context.connect("delete-surrounding-text", self.delete)
        self.context.connect("update-auxiliary-text", self.auxiliary_changed)

    def focus(self):
        super().focus()
        wait_for(self.context.needs_surrounding_text)
        self.surrounding()

    def surrounding(self):
        self.context.set_surrounding_text(IBus.Text.new_from_string(self.document), self.cursor, self.anchor)

    def delete(self, _context, offset, count):
        self.deletions.append((offset, count))
        self.events.append(("delete", offset, count))
        if not self.editable:
            return
        start = self.cursor + offset
        assert self.document[start:start + count] == "ニホンゴ"
        self.document = self.document[:start] + self.document[start + count:]
        self.cursor = self.anchor = start
        if not self.hold_ack:
            self.surrounding()

    def insert(self, text):
        start, end = sorted((self.cursor, self.anchor))
        self.document = self.document[:start] + text + self.document[end:]
        self.cursor = self.anchor = start + len(text)
        self.surrounding()

    def commit(self, context, text):
        self.events.append(("commit", text.get_text()))
        super().commit(context, text)

    def deliver_native(self, keyval, state, *, route):
        self.events.append(("native", keyval, int(state), route))
        super().deliver_native(keyval, state, route=route)
        self.anchor = self.cursor
        self.surrounding()

    def preedit_changed(self, context, text, cursor, visible):
        super().preedit_changed(context, text, cursor, visible)
        if self.preedit:
            self.visible_preedits.append(self.preedit)

    def auxiliary_changed(self, _context, text, _visible):
        self.auxiliary = text.get_text()

    def start(self):
        self.send(ord("r"), CONTROL | SHIFT)


def assert_original_replies(field, keys, consumed):
    assert [(reply["keyval"], reply["state"]) for reply in field.replies] == keys, field.replies
    assert [reply["consumed"] for reply in field.replies] == consumed, field.replies
    assert not field.forwarded, field.forwarded


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
observations = {}
field = ReconversionField(bus, "reconversion-ordered", hold_ack=True)
field.focus()
field.start()
keys = [
    (ord("r"), int(CONTROL | SHIFT)), (IBus.KEY_Return, 0), (IBus.KEY_Control_L, 0),
    (IBus.KEY_Home, int(CONTROL)), (IBus.KEY_Home, int(CONTROL | RELEASE)),
    (IBus.KEY_Control_L, int(CONTROL | RELEASE)), (ord("a"), 0), (IBus.KEY_Return, 0),
]
for keyval, state in keys[1:]:
    field.send(keyval, state)
started = time.monotonic()
assert field.context.get_engine().get_name() == "azookey-tree"
daemon_query_seconds = time.monotonic() - started
assert daemon_query_seconds < RESPONSIVE_SECONDS, daemon_query_seconds
wait_for(lambda: len(field.deletions) == 1)
assert len(field.replies) == 1 and not field.commits and not field.preedit, field.replies
assert field.document == "前後"
field.surrounding()
wait_for(lambda: len(field.replies) == len(keys) and len(field.commits) == 2)
assert_original_replies(field, keys, [True, True, False, False, False, False, True, True])
assert field.commits[0] in field.visible_preedits and field.commits[1] == "あ", field.commits
assert field.document == "あ前" + field.commits[0] + "後", field.document
assert field.cursor == field.anchor == 1
assert field.events.index(("commit", field.commits[0])) < field.events.index(
    ("native", IBus.KEY_Home, int(CONTROL), "original-reply"))
observations["ordered"] = {
    "document": field.document, "cursor": field.cursor, "commits": field.commits,
    "replies": field.replies, "events": field.events,
}
field.context.focus_out()

old = ReconversionField(bus, "reconversion-canceled")
other = ReconversionField(bus, "reconversion-other")
old.focus()
old.start()
old.send(IBus.KEY_Return)
old.send(IBus.KEY_Home, CONTROL)
old.context.focus_out()
other.focus()
wait_for(lambda: len(old.replies) == 3)
assert all(reply["consumed"] for reply in old.replies), old.replies
assert not old.commits and not old.deletions and not old.forwarded
assert other.document == ORIGINAL and not other.commits and not other.forwarded
observations["focusCancellation"] = {"replies": old.replies, "otherDocument": other.document}
other.context.focus_out()

ignored = ReconversionField(bus, "reconversion-ignored-deletion", editable=False)
ignored.focus()
ignored.start()
wait_for(lambda: len(ignored.deletions) == 1)
ignored.send(IBus.KEY_Home, CONTROL)
wait_for(lambda: len(ignored.replies) == 2)
assert_original_replies(ignored, [(ord("r"), int(CONTROL | SHIFT)), (IBus.KEY_Home, int(CONTROL))],
                        [True, False])
assert ignored.document == ORIGINAL and ignored.cursor == ignored.anchor == 0
assert len(ignored.deletions) == 1 and not ignored.commits and not ignored.preedit
observations["ignoredDeletion"] = {"replies": ignored.replies, "deletions": ignored.deletions}
ignored.context.focus_out()

changed = ReconversionField(bus, "reconversion-changed-document", hold_ack=True)
changed.focus()
changed.start()
changed.send(IBus.KEY_Home, CONTROL)
wait_for(lambda: len(changed.deletions) == 1)
changed.document, changed.cursor, changed.anchor = "別の本文", 0, 0
changed.surrounding()
wait_for(lambda: len(changed.replies) == 2)
assert_original_replies(changed, [(ord("r"), int(CONTROL | SHIFT)), (IBus.KEY_Home, int(CONTROL))],
                        [True, True])
assert changed.document == "別の本文" and not changed.commits and not changed.preedit
observations["changedDocument"] = {"document": changed.document, "replies": changed.replies}
changed.context.focus_out()

failure_file = Path(os.environ["AZOOKEY_TEST_RECONVERSION_FAILURE_FILE"])
failure_file.write_text("fail the next real-Core confirmation\n")
failed = ReconversionField(bus, "reconversion-worker-failure")
failed.focus()
failed.start()
failed.send(IBus.KEY_Home, CONTROL)
wait_for(lambda: len(failed.replies) == 2)
failure_file.unlink()
assert_original_replies(failed, [(ord("r"), int(CONTROL | SHIFT)), (IBus.KEY_Home, int(CONTROL))],
                        [True, False])
assert failed.document == ORIGINAL and failed.cursor == failed.anchor == 0
assert failed.commits == ["ニホンゴ"] and len(failed.deletions) == 1
assert failed.events.index(("commit", "ニホンゴ")) < failed.events.index(
    ("native", IBus.KEY_Home, int(CONTROL), "original-reply"))
observations["workerFailure"] = {"document": failed.document, "replies": failed.replies, "events": failed.events}
failed.context.focus_out()
print(json.dumps({
    "status": "PASS", "delaySeconds": float(os.environ["AZOOKEY_TEST_DELAY"]),
    "daemonQueryWhileWaitingSeconds": daemon_query_seconds, "cases": observations,
}, ensure_ascii=False))
