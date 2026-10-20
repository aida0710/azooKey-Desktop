"""Keep deferred key delivery, recovery, and focus epochs on the main loop."""
from collections import deque
from dataclasses import dataclass, field
import math
import threading
import time
from typing import Callable

from .async_bridge import Request
from .input_preview import InputPreview, is_native_key


# Two-second replies still make progress; three seconds without a reply
# recovers the input while the worker is allowed to finish a cold model load.
INPUT_PROGRESS_TIMEOUT_MS = 3000


@dataclass
class PendingInput:
    operation: str | None
    payload: dict
    key: tuple | None
    completion: Callable[[dict], object] | None = None
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
        self.schedule_timeout = schedule_timeout
        self.remove_timeout = remove_timeout
        self.timeout_source = None

    def submit(self, operation, *, payload=None, key=None, completion=None, persist=None):
        if self.recovering and key is not None:
            self.forward(*key)
            return
        pending = PendingInput(operation, payload or {}, key, completion=completion)
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

    def cancel(self):
        """Discard this epoch without replaying effects into a new input field."""
        self.cancelled.set()
        self.cancelled = threading.Event()
        epoch = self.cancelled
        for pending in self.pending:
            pending.cancelled.set()
        self.pending.clear()
        self.snapshot = {}
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
        self.pending.popleft()
        self._watch_progress()
        if reply.generation != self.generation:
            self.generation = reply.generation
            self.recover(self.snapshot.get("preedit", ""))
            self.snapshot = {}
        snapshot = reply.snapshot
        if pending.completion:
            try:
                pending.completion(snapshot)
            except (OSError, RuntimeError, ValueError):
                self.recover_pending()
                return False
        elif pending.operation is not None:
            self.publish(snapshot)
        if pending.key is not None and not snapshot.get("consumed", False):
            self.forward(*pending.key)
        self._forward_native()
        if not self.pending:
            self._stop_timeout()
        self._preview()
        return False

    def publish(self, snapshot):
        """Keep recovery aligned with an explicitly acknowledged composition."""
        self.snapshot = {**snapshot, "commits": [], "request": None}
        self.render(snapshot)

    def recover_pending(self):
        # Only acknowledged snapshots reached the application. Preserve that
        # text once, then return each unacknowledged physical key in order.
        # Never retry a request whose converter-side effects are uncertain.
        keys = [pending.key for pending in self.pending if pending.key is not None]
        preedit = self.snapshot.get("preedit", "")
        projection, unrepresented = self._project()
        if projection.discarded or projection.restored_reading:
            # A canceled composition must not be resurrected by replaying its
            # physical keys after a converter failure.
            preedit = projection.visible_text
            keys = [pending.key for pending in unrepresented if pending.key is not None]
        self.recovering = True
        self.cancel()
        self.recover(preedit)
        for key in keys:
            self.forward(*key)

    def _resume(self, epoch, reply):
        if not self.closed and epoch is self.cancelled:
            # Even a failed reset has left the worker's I/O wait. The next key
            # may start a fresh process; no background retry loop is needed.
            self.recovering = False
            self._watch_progress()
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
        if not any(pending.operation == "key" for pending in self.pending):
            return
        projection, unrepresented = self._project()
        if unrepresented:
            # A native operation outside this buffer (for example Left before
            # its start) belongs to the application. Recover first, in order.
            self.recover_pending()
            return
        self.preview(projection.visible_text, projection.visible_cursor)

    def _project(self):
        projection = InputPreview(self.snapshot, settings=self.settings)
        pending_inputs = list(self.pending)
        for index, pending in enumerate(pending_inputs):
            if pending.operation == "key" and not projection.apply(pending.payload.get("event", {})):
                return projection, pending_inputs[index:]
        return projection, []

    def _forward_native(self):
        while self.pending:
            pending = self.pending[0]
            if pending.key is None or pending.completion is not None:
                break
            if pending.operation is not None and not (
                pending.operation == "key" and is_native_key(pending.payload.get("event", {}), self.snapshot)
            ):
                break
            pending.cancelled.set()
            self.pending.popleft()
            self.forward(*pending.key)
