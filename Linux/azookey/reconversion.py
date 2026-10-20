"""Acknowledge surrounding-text replacement before restoring composition."""
from collections import deque

from .reconversion_strings import message


CONTEXT_LIMIT = 256
# A host that never acknowledges deletion must not hold later input indefinitely.
# Expiry reports uncertainty; it never repeats deletion or assumes success.
DELETION_ACK_TIMEOUT_MS = 3000


def utf16_count(text):
    return len(text.encode("utf-16-le")) // 2


def surrounding_context(text, cursor, anchor, *, can_replace, sensitive):
    if sensitive or not (0 <= cursor <= len(text) and 0 <= anchor <= len(text)):
        return None
    start, end = sorted((cursor, anchor))
    if end - start > CONTEXT_LIMIT:
        return None
    return {
        "before": text[:start][-CONTEXT_LIMIT:], "selected": text[start:end],
        "after": text[end:][:CONTEXT_LIMIT], "cursorUTF16": utf16_count(text[:cursor]),
        "anchorUTF16": utf16_count(text[:anchor]), "canReplace": can_replace, "isSensitive": False,
    }


def same_document(expected, current):
    if not current or not current["canReplace"] or current["isSensitive"]:
        return False
    keys = ("cursorUTF16", "anchorUTF16", "selected", "after")
    if any(expected[key] != current[key] for key in keys):
        return False
    before = expected["before"]
    return before == current["before"] or (
        len(before) < CONTEXT_LIMIT
        and utf16_count(before) < min(expected["cursorUTF16"], expected["anchorUTF16"])
        and current["before"].endswith(before)
    )


def removed_context(context, replacement):
    """Reject any plan that does not describe the exact captured text."""
    if not isinstance(replacement, dict):
        return None
    text, count, offset = (replacement.get(key) for key in ("text", "count", "offset"))
    if (
        not isinstance(text, str) or not text
        or type(count) is not int or type(offset) is not int
        or not isinstance(replacement.get("token"), str) or not replacement["token"]
    ):
        return None
    before, selected = context["before"], context["selected"]
    if count != len(text):
        return None
    if selected:
        expected_offset = -len(selected) if context["cursorUTF16"] > context["anchorUTF16"] else 0
        if selected != text or offset != expected_offset:
            return None
        cursor = min(context["cursorUTF16"], context["anchorUTF16"])
    else:
        if not before.endswith(text) or offset != -count:
            return None
        before = before[:-count]
        cursor = context["cursorUTF16"] - utf16_count(text)
    return {**context, "before": before, "selected": "", "cursorUTF16": cursor, "anchorUTF16": cursor}


class ReconversionCoordinator:
    def __init__(self, inputs, *, context, delete, status, replay, forward,
                 schedule_timeout, remove_timeout):
        self.inputs = inputs
        self.context = context
        self.delete = delete
        self.status = status
        self.replay = replay
        self.forward = forward
        self.schedule_timeout = schedule_timeout
        self.remove_timeout = remove_timeout
        self.phase = None
        self.source = None
        self.expected = None
        self.replacement = None
        self.queued = deque()
        self.epoch = 0
        self.timeout_source = None

    @property
    def active(self):
        return self.phase is not None

    def process(self, event, key):
        if self.active:
            if event is not None and self.phase == "reading":
                self._request("reconversion-reading", event=event)
            elif event is not None:
                self.queued.append(key)
            return True
        if event is None or event.get("modifierFlags") != 3:
            return False
        if event.get("keyCode") == 51:
            self.start(undo=True)
            return True
        if event.get("charactersIgnoringModifiers") == "r":
            self.start(undo=False)
            return True
        return False

    def start(self, *, undo):
        pending_input = any(pending.operation not in ("settings", "configure") for pending in self.inputs.pending)
        if self.active or pending_input or self.inputs.snapshot.get("preedit"):
            self.status(message("composition_active"))
            return
        source = self.context()
        if not source or not source["canReplace"] or source["isSensitive"]:
            self.status(message("replacement_unavailable"))
            return
        self.source = dict(source)
        self._request("undo-commit" if undo else "reconvert")

    def _request(self, operation, **payload):
        if not same_document(self.source, self.context()):
            self._fail("changed_context")
            return
        self.phase = "requesting"
        epoch = self.epoch
        self.inputs.submit(operation, payload={"reconversionContext": self.source, **payload},
                           completion=lambda snapshot: self._reply(epoch, snapshot))

    def _reply(self, epoch, snapshot):
        if epoch != self.epoch:
            return
        if not same_document(self.source, self.context()):
            self._fail("changed_context")
            return
        if "reconversionReading" in snapshot:
            self.phase = "reading"
            self.status(message("reading_input", reading=snapshot["reconversionReading"]))
            self._drain()
        elif snapshot.get("reconversion"):
            self._replace(snapshot["reconversion"])
        elif snapshot.get("reconversionError") or snapshot.get("error"):
            self._fail(snapshot.get("reconversionError", "replacement_unavailable"))
        else:
            self.cancel(replay=True)
            self.status("")

    def _replace(self, replacement):
        expected = removed_context(self.source, replacement)
        if expected is None:
            self._fail("changed_context")
            return
        self.phase = "deleting"
        self.expected = expected
        self.replacement = replacement
        self.timeout_source = self.schedule_timeout(DELETION_ACK_TIMEOUT_MS, self._expired)
        self.delete(replacement["offset"], replacement["count"])

    def surrounding_changed(self):
        if self.phase == "confirming":
            self._validate_confirmation(self.epoch)
            return
        if self.phase != "deleting":
            return
        current = self.context()
        if same_document(self.expected, current):
            self._stop_timeout()
            self.phase = "confirming"
            # From this acknowledgement onward the original text exists as
            # visible preedit. Recovery is safe only while its target matches.
            original = self.replacement["text"]
            epoch = self.epoch
            self.inputs.publish({
                "preedit": original, "cursor": len(original), "reading": original,
                "readingCursor": len(original), "inputState": "composing",
            })
            if not self._validate_confirmation(epoch):
                return
            self.inputs.submit(
                "confirm-reconversion",
                payload={"reconversionToken": self.replacement["token"], "reconversionContext": current},
                completion=lambda snapshot: self._confirmed(epoch, snapshot),
            )
        elif not same_document(self.source, current):
            self._fail("changed_context")

    def _confirmed(self, epoch, snapshot):
        if not self._validate_confirmation(epoch):
            return
        if snapshot.get("reconversionError") or snapshot.get("error"):
            self.status(message(snapshot.get("reconversionError", "replacement_unavailable")))
            self.inputs.recover_pending()
            return
        self.inputs.publish(snapshot)
        if not self._validate_confirmation(epoch):
            return
        self.phase = None
        self.source = self.expected = self.replacement = None
        self.status("")
        self._drain()

    def _validate_confirmation(self, epoch):
        if epoch != self.epoch or self.phase != "confirming":
            return False
        if same_document(self.expected, self.context()):
            return True
        self.cancel()
        self.inputs.cancel()
        self.inputs.recover("")
        self.status(message("changed_context"))
        return False

    def take_recovery(self, text):
        """Consume recovery text and buffered keys only for the same target."""
        changed = self.phase == "confirming" and not same_document(self.expected, self.context())
        queued = self.cancel()
        if changed:
            self.status(message("changed_context"))
            return "", deque()
        return text, queued

    def _drain(self):
        while self.queued and self.phase in (None, "reading"):
            self.replay(*self.queued.popleft())

    def cancel(self, *, replay=False):
        self.epoch += 1
        self._stop_timeout()
        self.phase = None
        self.source = self.expected = self.replacement = None
        queued, self.queued = self.queued, deque()
        if replay:
            for key in queued:
                self.forward(*key)
        return queued

    def _fail(self, reason):
        self.cancel(replay=True)
        self.inputs.cancel()
        self.status(message(reason))

    def _stop_timeout(self):
        if self.timeout_source is not None:
            self.remove_timeout(self.timeout_source)
            self.timeout_source = None

    def _expired(self):
        self.timeout_source = None
        self._fail("replacement_unavailable")
        return False
