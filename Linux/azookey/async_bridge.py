"""Serialize converter I/O without running it in the IBus main loop."""
from dataclasses import dataclass, field
import queue
import threading
import time
from typing import Callable

from .bridge import Bridge


@dataclass
class Request:
    operation: str | None
    payload: dict
    complete: Callable[["Reply"], object]
    cancelled: threading.Event = field(default_factory=threading.Event)


@dataclass
class Reply:
    snapshot: dict | None = None
    generation: int = 0
    failed: bool = False


class AsyncBridge:
    """One worker owns the shared converter and all its process lifecycle."""
    _shared = None

    @classmethod
    def acquire(cls, dispatch):
        if cls._shared is None:
            cls._shared = cls(dispatch)
        return cls._shared

    @classmethod
    def close_shared(cls):
        if cls._shared is not None:
            cls._shared.close()
            cls._shared = None

    @classmethod
    def reset_shared_learning(cls, completion):
        if cls._shared is None:
            completion(False)
            return
        cls._shared.submit(Request(
            "reset-learning", {},
            lambda reply: completion(not reply.failed and not reply.snapshot.get("error")),
        ))

    def __init__(self, dispatch, *, bridge_factory=None):
        self.dispatch = dispatch
        # The UI has a separate progress deadline. Keep the transport's longer
        # limit so a slow initial model load is not repeatedly killed.
        self.bridge_factory = bridge_factory or Bridge
        self.requests = queue.Queue()
        self.closed = False
        self.bridge = None
        self.last_progress_at = time.monotonic()
        self.worker = threading.Thread(target=self._run, name="azookey-converter", daemon=True)
        self.worker.start()

    def submit(self, request):
        if self.closed:
            raise RuntimeError("converter worker is closed")
        self.requests.put(request)

    def close(self):
        # Process exit and pipe draining also belong to the worker. Joining it
        # here would reintroduce a main-loop stall on engine destruction.
        self.closed = True
        self.requests.put(None)
        # Service shutdown must not leave a cold/hung child orphaned. SIGTERM
        # does not wait; the worker alone drains/closes pipes and reaps it.
        if self.bridge is not None:
            self.bridge.interrupt()

    def _run(self):
        bridge = None
        generation = 0
        try:
            while (request := self.requests.get()) is not None:
                if self.closed:
                    break
                if request.cancelled.is_set():
                    continue
                if request.operation is None:
                    reply = Reply(snapshot={"consumed": False}, generation=generation)
                else:
                    try:
                        if bridge is None:
                            bridge = self.bridge_factory()
                            self.bridge = bridge
                        if self.closed:
                            break
                        bridge.ensure_running()
                        generation = bridge.restarts
                        snapshot = bridge.request(request.operation, **request.payload)
                        reply = Reply(snapshot=snapshot, generation=generation)
                    except (OSError, RuntimeError, ValueError):
                        if bridge is not None:
                            bridge.invalidate()
                        reply = Reply(generation=generation, failed=True)
                self.last_progress_at = time.monotonic()
                if not request.cancelled.is_set():
                    self.dispatch(request.complete, reply)
        finally:
            if bridge is not None:
                bridge.close()
