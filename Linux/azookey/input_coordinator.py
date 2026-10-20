"""Keep deferred key delivery, recovery, and focus epochs on the main loop."""
from collections import deque
from dataclasses import dataclass, field
import math
import threading
import time
from typing import Callable

from .async_bridge import Request
from .ime_shortcuts import IMEShortcut, ime_shortcut
from .input_preview import InputPreview, is_core_input, is_native_key


# Two-second replies still make progress; three seconds without a reply
# recovers the input while the worker is allowed to finish a cold model load.
INPUT_PROGRESS_TIMEOUT_MS = 3000


@dataclass
class PendingInput:
    operation: str | None
    payload: dict
    key: tuple | None
    completion: Callable[[dict], object] | None = None
    key_reply: Callable[[bool], None] | None = None
    cancelled: threading.Event = field(default_factory=threading.Event)


class InputCoordinator:
    def __init__(self, worker, context, *, render, forward, recover, preview,
                 schedule_timeout=None, remove_timeout=None):
        self.worker = worker
        self.context = context
        self.render = render
        self.forward = forward
        self.recover = recover
        self.preview = preview
        self.snapshot = {}
        self.settings = {}
        self.pending = deque()
        self.cancelled = threading.Event()
        self.generation = 0
        self.closed = False
        self.recovering = False
        self.is_resetting = False
        self.has_recovery_preedit = False
        self.schedule_timeout = schedule_timeout
        self.remove_timeout = remove_timeout
        self.timeout_source = None

    def pending_native_key(self, event):
        """A projected native key must wait for an authoritative Core reply."""
        if event is None:
            return False
        if ime_shortcut(event) is not None or self.has_unicode_input:
            return True
        if self.is_resetting:
            # These keys remain consumed in either reset language. Accept
            # them immediately and let Core produce their composition/commit.
            return not is_core_input(event)
        if not self.pending:
            return False
        projection, unrepresented = self._project()
        # Conversion can commit all or only part of the preedit. Recovery
        # projection cannot decide whether a following shortcut becomes native.
        return bool(unrepresented) or is_native_key(event, {
            "inputState": "none",
            "language": projection.language,
        })

    def submit(self, operation, *, payload=None, key=None, completion=None, persist=None, key_reply=None):
        if self.recovering and key is not None:
            if key_reply:
                key_reply(False)
            else:
                self.forward(*key)
            return
        pending = PendingInput(operation, payload or {}, key, completion=completion, key_reply=key_reply)
        self.pending.append(pending)
        epoch = self.cancelled
        self._forward_native()
        if pending.cancelled.is_set():
            return
        self.worker.submit(Request(
            operation, {**pending.payload, "context": self.context},
            lambda reply: self._complete(epoch, pending, reply), cancelled=pending.cancelled, persist=persist,
        ))
        if self.timeout_source is None:
            self._watch_progress()
        self._preview()

    def cancel(self, *, discard_keys=True):
        """Discard this epoch without replaying effects into a new input field."""
        self.cancelled.set()
        self.cancelled = threading.Event()
        epoch = self.cancelled
        for pending in self.pending:
            pending.cancelled.set()
            if discard_keys:
                self._finish_key(pending, True)
        self.pending.clear()
        self.has_recovery_preedit = False
        # Reset clears composition, but Core keeps its input language. Do not
        # guess Japanese while a native client is still typing in English.
        self.snapshot = {key: value for key, value in self.snapshot.items() if key == "language"}
        self.is_resetting = True
        self._stop_timeout()
        # A barrier clears the converter after an already running request. Its
        # response has no application effects and cannot resurrect old preedit.
        self.worker.submit(Request(
            "reset", {"context": self.context, "submit": False},
            lambda reply: self._resume(epoch, reply),
        ))

    def close(self):
        self.cancel()
        self.closed = True
        self.worker.submit(Request("close", {"context": self.context}, lambda _reply: None))

    def _complete(self, epoch, pending, reply):
        if self.closed or epoch is not self.cancelled or epoch.is_set() or pending.cancelled.is_set():
            return False
        if reply.failed or (reply.snapshot.get("error") and pending.completion is None):
            self.recover_pending()
            return False
        if reply.generation != self.generation and self.snapshot.get("inputState") == "unicodeInput":
            # A restarted Core no longer owns this Unicode sequence. Its reply
            # may treat a hex digit as text or Enter as a native newline.
            self.generation = reply.generation
            self.recover_pending()
            return False
        self.pending.popleft()
        self._watch_progress()
        finish_recovery = None
        if reply.generation != self.generation:
            self.generation = reply.generation
            finish_recovery = self.recover(self._recovery_preedit())
            if self.closed or epoch is not self.cancelled or epoch.is_set():
                self._finish_key(pending, True)
                if finish_recovery:
                    finish_recovery()
                return False
            self.snapshot = {}
        snapshot = reply.snapshot
        self._remember_language(snapshot)
        if pending.completion:
            try:
                pending.completion(snapshot)
            except (OSError, RuntimeError, ValueError):
                self._finish_key(pending, True)
                self.recover_pending()
                if finish_recovery:
                    finish_recovery()
                return False
        elif pending.operation is not None:
            self.publish(snapshot)
        self._finish_key(pending, epoch is not self.cancelled or bool(snapshot.get("consumed", False)))
        if finish_recovery:
            finish_recovery()
        self._forward_native()
        if not self.pending:
            self._stop_timeout()
        self._preview()
        return False

    def _finish_key(self, pending, consumed):
        if pending.key_reply:
            reply, pending.key_reply = pending.key_reply, None
            reply(consumed)
        elif pending.key is not None and not consumed:
            self.forward(*pending.key)

    def publish(self, snapshot):
        """Keep recovery aligned with an explicitly acknowledged composition."""
        self.has_recovery_preedit = False
        self.snapshot = {**snapshot, "commits": [], "request": None}
        self.render(snapshot)

    def _remember_language(self, snapshot):
        if snapshot and snapshot.get("language") in ("english", "japanese"):
            self.snapshot["language"] = snapshot["language"]

    @property
    def has_pending_preview(self):
        return any(pending.operation == "key" for pending in self.pending)

    @property
    def has_unicode_input(self):
        return (self.snapshot.get("inputState") == "unicodeInput"
                or self._unicode_entry_index(self.pending) is not None)

    @staticmethod
    def _unicode_entry_index(pending_inputs):
        return next((index for index, pending in enumerate(pending_inputs)
                     if pending.operation == "key"
                     and ime_shortcut(pending.payload.get("event")) == IMEShortcut.UNICODE), None)

    def _recovery_preedit(self):
        # U+... is an instruction to Core, never document text to recover.
        return "" if self.snapshot.get("inputState") == "unicodeInput" else self.snapshot.get("preedit", "")

    def recover_pending(self, *, key=None, key_reply=None):
        # Only acknowledged snapshots reached the application. Preserve that
        # text once, then return each unacknowledged physical key in order.
        # Never retry a request whose converter-side effects are uncertain.
        if key is not None:
            self.pending.append(PendingInput(None, {}, key, key_reply=key_reply))
        original_pending = list(self.pending)
        recoverable = original_pending
        if self.snapshot.get("inputState") == "unicodeInput":
            recoverable = []
        else:
            unicode_index = self._unicode_entry_index(original_pending)
            if unicode_index is not None:
                recoverable = original_pending[:unicode_index]
        return_ids = {id(pending) for pending in recoverable if pending.key is not None}
        preedit = self._recovery_preedit()
        projection, unrepresented = self._project(recoverable)
        if projection.discarded or projection.restored_reading:
            # A canceled composition must not be resurrected by replaying its
            # physical keys after a converter failure.
            preedit = projection.visible_text
            return_ids = {id(pending) for pending in unrepresented if pending.key is not None}
        self.recovering = True
        self.cancel(discard_keys=False)
        recovery_epoch = self.cancelled
        finish_recovery = self.recover(preedit)
        for pending in original_pending:
            consumed = recovery_epoch is not self.cancelled or id(pending) not in return_ids
            self._finish_key(pending, consumed)
        # Reconversion may still own later keys that have not reached this
        # queue. Return those only after this queue and its current failed key.
        if finish_recovery:
            finish_recovery()

    def _resume(self, epoch, reply):
        if not self.closed and epoch is self.cancelled:
            # Even a failed reset has left the worker's I/O wait. The next key
            # may start a fresh process; no background retry loop is needed.
            self.recovering = False
            self.is_resetting = False
            if not reply.failed:
                self._remember_language(reply.snapshot)
            else:
                self.snapshot.pop("language", None)
            self._forward_native()
            self._watch_progress()
            self._preview()
        return False

    def _watch_progress(self):
        self._stop_timeout()
        if self.pending and self.schedule_timeout:
            self.timeout_source = self.schedule_timeout(INPUT_PROGRESS_TIMEOUT_MS, self._progress_expired)

    def _stop_timeout(self):
        if self.timeout_source is not None:
            self.remove_timeout(self.timeout_source)
            self.timeout_source = None

    def _progress_expired(self):
        self.timeout_source = None
        progress_at = getattr(self.worker, "last_progress_at", None)
        if self.pending and progress_at is not None:
            remaining = INPUT_PROGRESS_TIMEOUT_MS - (time.monotonic() - progress_at) * 1000
            if remaining > 0:
                # Another context or a cancellation barrier can have made
                # progress while this context was waiting in the shared queue.
                self.timeout_source = self.schedule_timeout(math.ceil(remaining), self._progress_expired)
                return False
        if self.pending:
            self.recover_pending()
        return False

    def _preview(self):
        if not self.has_pending_preview:
            return
        if self.has_unicode_input:
            # Hex validation, cancellation and the resulting character belong
            # to Core. Keep its last display until the ordered reply arrives.
            return
        projection, unrepresented = self._project()
        if unrepresented:
            if unrepresented[0].key_reply:
                # A host shortcut cannot be projected into our preedit, but
                # its original native call can wait without reconstructing it.
                # Keep later literal edits visible for IBus focus-out recovery:
                # canceled host shortcuts never run in the next input field.
                for pending in unrepresented[1:]:
                    if pending.operation == "key":
                        projection.apply(pending.payload.get("event", {}))
                self._show_preview(projection.visible_text, projection.visible_cursor)
                return
            # A native operation outside this buffer (for example Left before
            # its start) belongs to the application. Recover first, in order.
            self.recover_pending()
            return
        self._show_preview(projection.visible_text, projection.visible_cursor)

    def _show_preview(self, text, cursor):
        self.has_recovery_preedit = bool(text)
        self.preview(text, cursor)

    def _project(self, pending_inputs=None):
        projection = InputPreview(self.snapshot, settings=self.settings)
        pending_inputs = list(self.pending) if pending_inputs is None else pending_inputs
        for index, pending in enumerate(pending_inputs):
            if pending.operation == "key" and not projection.apply(pending.payload.get("event", {})):
                return projection, pending_inputs[index:]
        return projection, []

    def _forward_native(self):
        if self.is_resetting:
            return
        while self.pending:
            pending = self.pending[0]
            if pending.key is None or pending.completion is not None:
                break
            if pending.operation is not None and not (
                pending.operation == "key" and pending.key_reply
                and is_native_key(pending.payload.get("event", {}), self.snapshot)
            ):
                break
            pending.cancelled.set()
            self.pending.popleft()
            if self.has_recovery_preedit:
                # A reset barrier has no render callback. Retire our recovery
                # preedit before the client receives its original event, or a
                # native edit can first commit that same preview in GTK.
                self._show_preview("", 0)
            self._finish_key(pending, False)
