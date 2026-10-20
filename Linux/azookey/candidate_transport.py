"""Own blocking candidate-process I/O on one thread, including retain barriers."""
from collections import deque
from copy import deepcopy
from dataclasses import dataclass, field
import logging
import os
import threading
from typing import Callable

from .bridge import Bridge
from . import candidate_protocol as protocol


LOGGER = logging.getLogger(__name__)


@dataclass
class CandidateOperation:
    operation: str
    payload: dict
    complete: Callable[[protocol.CandidateReply], object]
    cancelled: threading.Event = field(default_factory=threading.Event)
    sent: bool = False


class CandidateGenerationChanged(RuntimeError):
    pass


class CandidateTransport:
    def __init__(self, dispatch, *, environment=None, bridge_factory=None):
        self.dispatch = dispatch
        child_environment = {**(os.environ if environment is None else environment), "AZOOKEY_BRIDGE_ROLE": "candidate"}
        self.bridge_factory = bridge_factory or (lambda: Bridge(environment=child_environment))
        self._condition = threading.Condition()
        self._pending = deque()
        self._closed = False
        self._bridge = None
        self._generation = None
        self._epoch = 0
        self._restarts = None
        self.worker = threading.Thread(target=self._run, name="azookey-candidates", daemon=True)
        self.worker.start()

    @property
    def identity(self):
        with self._condition:
            return self._generation, self._epoch

    def submit(self, operation, payload, complete):
        pending = CandidateOperation(operation, deepcopy(payload), complete)
        with self._condition:
            if self._closed:
                raise RuntimeError("candidate transport is closed")
            if operation == "candidates":
                context = payload["request"]["authority"]["context"]
                # Replacing at the new position preserves every control operation's
                # order, including a learning revision between two calculations.
                for earlier in tuple(self._pending):
                    if earlier.operation == "candidates" and earlier.payload["request"]["authority"]["context"] == context:
                        earlier.cancelled.set()
                        self._pending.remove(earlier)
            self._pending.append(pending)
            self._condition.notify()
        return pending

    def close(self):
        with self._condition:
            self._closed = True
            for operation in self._pending:
                operation.cancelled.set()
            self._pending.clear()
            bridge = self._bridge
            self._condition.notify()
        if bridge is not None:
            bridge.interrupt()

    def _next(self):
        with self._condition:
            self._condition.wait_for(lambda: self._closed or self._pending)
            return None if self._closed else self._pending.popleft()

    def _set_generation(self, generation):
        with self._condition:
            if self._generation != generation:
                self._generation = generation
                self._epoch += 1

    def _connect(self):
        if self._bridge is None:
            bridge = self.bridge_factory()
            with self._condition:
                self._bridge = bridge
                closed = self._closed
            if closed:
                bridge.interrupt()
                raise RuntimeError("candidate transport is closed")
        self._bridge.ensure_running()
        if self._generation is None or self._restarts != self._bridge.restarts:
            response = self._bridge.request("settings")
            protocol.response_header(response)
            protocol.settings_response(response)
            if response.get("error"):
                raise RuntimeError("candidate settings unavailable")
            self._restarts = self._bridge.restarts
            self._set_generation(response["workerGeneration"])

    def _exchange(self, operation, payload, *, generation=None, pending=None):
        self._connect()
        if generation is not None and generation != self._generation:
            raise CandidateGenerationChanged()
        if operation == "close" and payload.get("workerGeneration") is None:
            # Closing during the very first handshake has no candidate/learning
            # effect. Resolve its worker identity only after earlier queued work.
            payload = {**payload, "workerGeneration": self._generation}
        if pending is not None:
            pending.sent = True
        response = self._bridge.request(operation, **payload)
        protocol.response_header(response)
        if self._bridge.restarts != self._restarts or response["workerGeneration"] != self._generation:
            self._restarts = self._bridge.restarts
            self._set_generation(response["workerGeneration"])
            raise CandidateGenerationChanged()
        return response

    def _reply(self, **payload):
        generation, epoch = self.identity
        return protocol.CandidateReply(worker_generation=generation, transport_epoch=epoch, **payload)

    def _discard(self, reference):
        try:
            self._exchange("release", {"reference": reference}, generation=reference["workerGeneration"])
        except CandidateGenerationChanged:
            pass
        except (OSError, RuntimeError, ValueError):
            self._invalidate()

    def _calculate(self, pending):
        request = pending.payload["request"]
        response = self._exchange("candidates", pending.payload)
        if response.get("authority") != request["authority"]:
            raise ValueError("candidate response changed its request authority")
        if response.get("error"):
            return self._reply(error=response["error"])
        batch = protocol.candidate_batch(response, request)
        reference = protocol.reference(batch)
        if pending.cancelled.is_set():
            self._discard(reference)
            return self._reply(error="candidate_request_cancelled")
        retained = self._exchange("retain", {"reference": reference}, generation=reference["workerGeneration"])
        if retained.get("error"):
            self._discard(reference)
            return self._reply(error=retained["error"])
        if retained.get("reference") != reference or retained.get("authority") != request["authority"]:
            raise ValueError("candidate retain acknowledgement changed its identity")
        return self._reply(batch=batch)

    def _execute(self, pending):
        if pending.operation == "candidates":
            return self._calculate(pending)
        payload = pending.payload
        source = payload.get("reference") or payload.get("completion") or payload
        response = self._exchange(pending.operation, payload, generation=source.get("workerGeneration"), pending=pending)
        if response.get("error"):
            if pending.operation == "complete":
                if response.get("authority") != source["authority"]:
                    raise ValueError("candidate rejection changed its commit authority")
                # Input was already committed by its owner. A definitive rejection
                # ends this learning attempt; do not leave a retained batch behind.
                self._discard(protocol.reference(source))
            return self._reply(error=response["error"])
        if pending.operation == "complete":
            return self._reply(completion=protocol.completion_receipt(response, payload["completion"]))
        if pending.operation in ("settings", "configure-learning"):
            return self._reply(settings=protocol.settings_response(response))
        return self._reply()

    def _invalidate(self):
        self._set_generation(None)
        if self._bridge is not None:
            try:
                self._bridge.invalidate()
            except (OSError, RuntimeError, ValueError):
                LOGGER.error("Candidate process invalidation failed")

    def _run(self):
        try:
            while (pending := self._next()) is not None:
                if pending.cancelled.is_set():
                    continue
                try:
                    reply = self._execute(pending)
                except CandidateGenerationChanged:
                    reply = self._reply(error="candidate_worker_changed", uncertain=pending.operation == "complete" and pending.sent)
                except (OSError, RuntimeError, ValueError):
                    self._invalidate()
                    reply = self._reply(error="candidate_worker_unavailable", uncertain=pending.operation == "complete" and pending.sent)
                if self._closed:
                    break
                if pending.cancelled.is_set():
                    if reply.batch:
                        self._discard(protocol.reference(reply.batch))
                    continue
                try:
                    self.dispatch(pending.complete, reply)
                except (OSError, RuntimeError, ValueError):
                    # A dispatcher may have enqueued the callback before failing.
                    # Such a callback must never adopt the reference we release here.
                    pending.cancelled.set()
                    if reply.batch:
                        self._discard(protocol.reference(reply.batch))
                    LOGGER.error("Candidate reply dispatcher failed")
        finally:
            self._set_generation(None)
            if self._bridge is not None:
                try:
                    self._bridge.close()
                except (OSError, RuntimeError, ValueError):
                    LOGGER.error("Candidate process cleanup failed")
