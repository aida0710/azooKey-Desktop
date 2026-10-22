"""Send AI operations to Core behind earlier input, and deliver the replies."""
import threading

from .async_bridge import Request


class AIBridge:
    """AI operations for one input context on the shared converter queue.

    Core keeps one suggestion review and one selected-text transformation per
    context, so requests carry this engine's context. Replies arrive on the
    main loop in request order; after `close` they are dropped.
    """

    def __init__(self, worker, context):
        self.worker = worker
        self.context = context
        self.closed = threading.Event()

    def submit(self, operation, *, completion=None, **payload):
        def delivered(reply):
            if completion is None or self.closed.is_set():
                return
            failed = reply.failed or reply.snapshot.get("error")
            completion(None if failed else reply.snapshot)

        self.worker.submit(Request(operation, {**payload, "context": self.context}, delivered, cancelled=self.closed))

    def close(self):
        self.closed.set()
