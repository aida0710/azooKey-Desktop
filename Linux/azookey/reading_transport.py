"""Keep reading JSONL I/O off the caller and never replay an uncertain operation."""
from collections import deque
from copy import deepcopy
from dataclasses import dataclass
import logging
import os
import threading

from .bridge import Bridge
from . import reading_protocol as protocol


LOGGER = logging.getLogger(__name__)


@dataclass
class ReadingOperation:
    operation: str
    payload: dict
    complete: object
    sent: bool = False


class ReadingTransport:
    def __init__(self, dispatch, *, environment=None, bridge_factory=None):
        self.dispatch = dispatch
        child_environment = {**(os.environ if environment is None else environment), "AZOOKEY_BRIDGE_ROLE": "reading"}
        self.bridge_factory = bridge_factory or (lambda: Bridge(environment=child_environment))
        self._condition = threading.Condition()
        self._pending = deque()
        self._closed = False
        self._bridge = None
        self._generation = None
        self._epoch = 0
        self._restarts = None
        self.worker = threading.Thread(target=self._run, name="azookey-reading", daemon=True)
        self.worker.start()

    @property
    def identity(self):
        with self._condition:
            return self._generation, self._epoch

    def submit(self, operation, payload, complete):
        pending = ReadingOperation(operation, deepcopy(payload), complete)
        with self._condition:
            if self._closed:
                raise RuntimeError("reading transport is closed")
            self._pending.append(pending)
            self._condition.notify()
        return pending

    def close(self):
        with self._condition:
            self._closed = True
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
                raise RuntimeError("reading transport is closed")
        self._bridge.ensure_running()
        if self._generation is None or self._restarts != self._bridge.restarts:
            hello = protocol.response(self._bridge.request("hello"), "hello", {})
            if hello.get("error"):
                raise ValueError("reading handshake rejected")
            self._restarts = self._bridge.restarts
            self._set_generation(hello["readingProcessGeneration"])

    def _execute(self, pending):
        self._connect()
        expected = pending.payload.get("readingProcessGeneration")
        if "reference" in pending.payload:
            expected = pending.payload["reference"]["readingProcessGeneration"]
        if expected is not None and expected != self._generation:
            return self._reply(error="reading_process_changed")
        pending.sent = True
        response = protocol.response(self._bridge.request(pending.operation, **pending.payload),
                                     pending.operation, pending.payload)
        if self._bridge.restarts != self._restarts or response["readingProcessGeneration"] != self._generation:
            self._set_generation(response["readingProcessGeneration"])
            return self._reply(error="reading_process_changed", uncertain=True)
        return self._reply(response=response)

    def _reply(self, **fields):
        generation, epoch = self.identity
        return protocol.ReadingReply(generation=generation, transport_epoch=epoch, **fields)

    def _invalidate(self):
        self._set_generation(None)
        if self._bridge is not None:
            try:
                self._bridge.invalidate()
            except (OSError, RuntimeError, ValueError):
                LOGGER.error("Reading process invalidation failed")

    def _run(self):
        try:
            while (pending := self._next()) is not None:
                try:
                    reply = self._execute(pending)
                except (OSError, RuntimeError, ValueError):
                    self._invalidate()
                    reply = self._reply(error="reading_process_unavailable", uncertain=pending.sent)
                if self._closed:
                    break
                try:
                    self.dispatch(pending.complete, reply)
                except (OSError, RuntimeError, ValueError):
                    # The caller must provide a reliable owner-thread dispatcher.
                    # Do not run input callbacks here or replay a possibly applied key.
                    LOGGER.error("Reading reply dispatcher failed")
                    self._invalidate()
        finally:
            self._set_generation(None)
            if self._bridge is not None:
                try:
                    self._bridge.close()
                except (OSError, RuntimeError, ValueError):
                    LOGGER.error("Reading process cleanup failed")
