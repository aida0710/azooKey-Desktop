"""Acknowledge surrounding-text replacement before restoring composition."""
from collections import deque

from .input_preview import ENTER_KEYS
from .reconversion_key import ReconversionKey, ReconversionRecovery
from .reconversion_strings import message


CONTEXT_LIMIT = 256
# A host that never acknowledges deletion must not hold later input indefinitely.
# Expiry reports uncertainty; it never repeats deletion or assumes success.
DELETION_ACK_TIMEOUT_MS = 3000


def reconversion_operation(event):
    if event is None or event.get("modifierFlags") != 3:
        return None
    if event.get("keyCode") == 51:
        return "undo-commit"
    if event.get("charactersIgnoringModifiers") == "r":
        return "reconvert"
    return None


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
        self.start_reply = None
        self.menu_operation = None

    @property
    def active(self):
        return self.phase is not None

    def process(self, event, key, *, key_reply=None):
        if self.phase == "menu-confirmation":
            return self._confirm_menu(event, key, key_reply=key_reply)
        if self.active:
            if self.phase == "reading":
                # Reading entry consumes even unsupported keys. It never
                # turns a reading command into a native document edit.
                if event is not None:
                    self.start_reply = key_reply.defer() if key_reply else None
                    self._request("reconversion-reading", event=event)
            else:
                self.queued.append(ReconversionKey(
                    key, key_reply.defer() if key_reply else None,
                ))
            return True
        operation = reconversion_operation(event)
        if operation is None:
            return False
        self.start(undo=operation == "undo-commit", key_reply=key_reply)
        return True

    def _available_context(self):
        pending_input = any(pending.operation not in ("settings", "configure") for pending in self.inputs.pending)
        if self.active or pending_input or self.inputs.snapshot.get("preedit"):
            self.status(message("composition_active"))
            return None
        source = self.context()
        if not source or not source["canReplace"] or source["isSensitive"]:
            self.status(message("replacement_unavailable"))
            return None
        return dict(source)

    def prompt_menu(self, *, undo):
        source = self._available_context()
        if source is None:
            return
        # A menu callback owns no key reply. Starting deletion here can
        # deadlock a synchronous client's next key against its deletion ACK.
        self.epoch += 1
        self.source = source
        self.phase = "menu-confirmation"
        self.menu_operation = "undo-commit" if undo else "reconvert"
        self.status(message("confirm_undo" if undo else "confirm_selection"))

    def _confirm_menu(self, event, key, *, key_reply):
        if event is None:
            return False
        if event["keyCode"] in ENTER_KEYS and event["modifierFlags"] == 0:
            operation, self.menu_operation = self.menu_operation, None
            self.start_reply = key_reply.defer() if key_reply else None
            self._request(operation)
            return True
        self.cancel()
        epoch = self.epoch
        self.status("")
        if epoch != self.epoch or self.active:
            return True
        if event["keyCode"] == 53 and event["modifierFlags"] == 0:
            return True
        return self.process(event, key, key_reply=key_reply)

    def start(self, *, undo, key_reply=None):
        source = self._available_context()
        if source is None:
            return
        self.epoch += 1
        self.source = source
        self.start_reply = key_reply.defer() if key_reply else None
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
            self._finish_start(epoch)
            if epoch != self.epoch or self.phase != "reading":
                return
            self.status(message("reading_input", reading=snapshot["reconversionReading"]))
            self._drain(epoch)
        elif snapshot.get("reconversion"):
            self._replace(snapshot["reconversion"])
        elif snapshot.get("reconversionError") or snapshot.get("error"):
            self._fail(snapshot.get("reconversionError", "replacement_unavailable"))
        else:
            self._finish()

    def _replace(self, replacement):
        expected = removed_context(self.source, replacement)
        if expected is None:
            self._fail("changed_context")
            return
        self.phase = "deleting"
        self.expected = expected
        self.replacement = replacement
        epoch = self.epoch
        self.timeout_source = self.schedule_timeout(DELETION_ACK_TIMEOUT_MS, self._expired)
        self.delete(replacement["offset"], replacement["count"])
        # Synchronous clients apply deletion after this original call returns.
        # Returning earlier lets its release key block the deletion ACK instead.
        self._finish_start(epoch)

    def _finish_start(self, epoch):
        if epoch != self.epoch:
            return
        reply, self.start_reply = self.start_reply, None
        if reply:
            reply(True)

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
        self._finish()

    def _finish(self):
        epoch = self.epoch
        target = self.expected if self.phase == "confirming" else self.source
        self.phase = None
        self.source = self.expected = self.replacement = None
        self.menu_operation = None
        self._stop_timeout()
        self._finish_start(epoch)
        if epoch != self.epoch or self.active:
            return
        self.status("")
        if epoch != self.epoch or self.active:
            return
        if not same_document(target, self.context()):
            self._fail("changed_context")
            return
        self._drain(epoch)

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
        target = self.expected if self.phase == "confirming" else self.source
        changed = self.active and not same_document(target, self.context())
        recovery = self._retire()
        if changed:
            self.finish_recovery(recovery, allow_native=False)
            self.status(message("changed_context"))
            return "", recovery
        return text, recovery

    def finish_recovery(self, recovery, *, allow_native):
        start_reply, recovery.start_reply = recovery.start_reply, None
        if start_reply:
            start_reply(True)
        while recovery.keys:
            pending = recovery.keys.popleft()
            # A commit or native reply can synchronously change focus. The
            # remaining invocations must then complete without native edits.
            consumed = not allow_native or recovery.epoch != self.epoch
            pending.finish(consumed, forward=self.forward)

    def is_current_recovery(self, recovery):
        return recovery.epoch == self.epoch and (
            recovery.target is None or same_document(recovery.target, self.context()))

    def _drain(self, epoch):
        while self.queued and epoch == self.epoch and self.phase in (None, "reading"):
            if self.phase == "reading" and not same_document(self.source, self.context()):
                self._fail("changed_context")
                return
            pending = self.queued.popleft()
            self.replay(*pending.key, key_reply=pending.reply)

    def cancel(self):
        self.finish_recovery(self._retire(), allow_native=False)

    def _retire(self):
        target = self.expected if self.phase == "confirming" else self.source
        self.epoch += 1
        self._stop_timeout()
        self.phase = None
        self.source = self.expected = self.replacement = None
        self.menu_operation = None
        queued, self.queued = self.queued, deque()
        start_reply, self.start_reply = self.start_reply, None
        return ReconversionRecovery(
            epoch=self.epoch, keys=queued, target=target, start_reply=start_reply,
        )

    def _fail(self, reason):
        target = self.expected if self.phase == "confirming" else self.source
        allow_native = reason != "changed_context" and same_document(target, self.context())
        recovery = self._retire()
        try:
            if recovery.epoch == self.epoch:
                self.inputs.cancel()
                if recovery.epoch == self.epoch:
                    self.status(message(reason))
        finally:
            self.finish_recovery(recovery, allow_native=allow_native and self.is_current_recovery(recovery))

    def _stop_timeout(self):
        if self.timeout_source is not None:
            self.remove_timeout(self.timeout_source)
            self.timeout_source = None

    def _expired(self):
        self.timeout_source = None
        self._fail("replacement_unavailable")
        return False
