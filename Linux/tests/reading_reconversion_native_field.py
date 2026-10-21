"""Observe original key replies and deletion acknowledgements in one test field."""
import json
import time

from ibus_native_field import IBus, SYNTHETIC_KEYCODE, wait_for
from native_surrounding_field import SurroundingField


class ReadingReconversionField(SurroundingField):
    def __init__(self, bus, name, *, trace):
        super().__init__(bus, name)
        self.name = name
        self.trace = trace
        self.hold_ack = False
        self.pending_ack = False
        self.events = []
        self.calls = []
        self.deletions = []
        self.errors = []
        self.context_id = None

    def record(self, kind, **values):
        self.events.append({"kind": kind, "monotonic": time.monotonic(), **values})

    def focus(self):
        super().focus()
        self.context.set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.NONE)

    def surrounding(self, *, acknowledge=False):
        if self.pending_ack and not acknowledge:
            self.record("surrounding-withheld")
            return
        self.pending_ack = False
        self.record("surrounding", text=self.document, cursor=self.cursor, anchor=self.anchor,
                    deletionAck=acknowledge)
        super().surrounding()

    def set_document(self, text, *, cursor, anchor):
        self.document, self.cursor, self.anchor = text, cursor, anchor
        self.pending_ack = False
        self.surrounding()

    def delete(self, _context, offset, count):
        start = self.cursor + offset
        self.deletions.append({"offset": offset, "count": count, "text": self.document[start:start + count]})
        self.record("delete", **self.deletions[-1])
        assert 0 <= start <= start + count <= len(self.document), self.deletions[-1]
        self.document = self.document[:start] + self.document[start + count:]
        self.cursor = self.anchor = start
        self.pending_ack = self.hold_ack
        self.surrounding()

    def commit(self, context, text):
        self.record("commit", text=text.get_text())
        super().commit(context, text)

    def preedit_changed(self, context, text, cursor, visible):
        super().preedit_changed(context, text, cursor, visible)
        self.record("preedit", text=self.preedit, cursor=cursor)

    def auxiliary_changed(self, _context, text, visible):
        self.auxiliary = text.get_text() if visible else ""
        self.record("auxiliary", text=self.auxiliary)

    def deliver_native(self, keyval, state, *, route):
        self.record("native", keyval=keyval, state=int(state), route=route)
        super().deliver_native(keyval, state, route=route)

    def send(self, keyval, state=0):
        token = len(self.calls) + 1
        started = time.monotonic()
        self.calls.append({"token": token, "keyval": keyval, "state": int(state), "monotonic": started})

        def completed(context, response, _user_data):
            try:
                consumed = context.process_key_event_async_finish(response)
                self.replies.append({"token": token, "keyval": keyval, "state": int(state),
                                     "consumed": consumed, "monotonic": time.monotonic(),
                                     "elapsedSeconds": time.monotonic() - started})
                if not consumed:
                    self.deliver_native(keyval, state, route="original-reply")
            except Exception as error:
                self.errors.append({"token": token, "error": type(error).__name__, "message": str(error)})
        self.context.process_key_event_async(keyval, SYNTHETIC_KEYCODE, state, -1, None, completed, None)
        return token

    def key(self, keyval, state=0):
        token = self.send(keyval, state)
        wait_for(lambda: any(reply["token"] == token for reply in self.replies) or self.errors,
                 "original IBus key did not finish")
        assert not self.errors, self.errors
        assert len([reply for reply in self.replies if reply["token"] == token]) == 1
        return token

    def warm(self):
        self.focus()
        began = time.monotonic()
        self.key(ord("a"))
        wait_for(lambda: self.preedit == "あ", "reader was not ready for fixture input")
        records = self.trace.records(role="reading", operation="key", phase="response", since=began)
        assert records
        self.context_id = records[-1]["request"]["reference"]["context"]
        self.key(IBus.KEY_space)
        wait_for(lambda: self.trace.records(role="candidate", operation="retain", phase="response", since=began),
                 "real candidate batch was not retained")
        self.key(IBus.KEY_Escape)
        self.key(IBus.KEY_Escape)
        wait_for(lambda: self.preedit == "", "warmup composition did not cancel")
        assert not self.commits

    def assert_replies(self, tokens, *, consumed=True):
        for token in tokens:
            replies = [reply for reply in self.replies if reply["token"] == token]
            assert len(replies) == 1 and replies[0]["consumed"] is consumed, replies
        assert not self.errors and not self.forwarded, (self.errors, self.forwarded)

    def save(self, path):
        path.write_text(json.dumps({"name": self.name, "context": self.context.get_object_path(),
                                   "readingContext": self.context_id, "document": self.document,
                                   "cursor": self.cursor, "anchor": self.anchor, "preedit": self.preedit,
                                   "commits": self.commits, "deletions": self.deletions, "events": self.events,
                                   "calls": self.calls, "replies": self.replies, "errors": self.errors,
                                   "forwarded": self.forwarded}, ensure_ascii=False, indent=2) + "\n")
