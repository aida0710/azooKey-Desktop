"""Shared fixture for real reading and candidate JSONL process behavior."""
from copy import deepcopy
import json
import os
from pathlib import Path
import queue
import signal
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate
from azookey.reading_coordinator import ReadingCoordinator
from candidate_fixture import CallbackQueue, WAIT_SECONDS


class ObservedReadingProcess(Bridge):
    def __init__(self, environment):
        self.operations = []
        self.started = queue.Queue()
        self.threads = set()
        self.lose_key_reply = False
        super().__init__(timeout=WAIT_SECONDS, environment=environment)

    def request(self, operation, **payload):
        self.threads.add(threading.get_ident())
        self.operations.append((operation, deepcopy(payload)))
        self.started.put(operation)
        response = super().request(operation, **payload)
        if operation == "key" and self.lose_key_reply:
            self.lose_key_reply = False
            raise RuntimeError("fixture lost an actual reading acknowledgement")
        return response


class ReadingProcessTestCase(unittest.TestCase):
    def prepare_worker_settings(self):
        return {}

    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.callbacks = CallbackQueue()
        self.inputs = []
        self.panels = []
        self.notices = []
        self.finished = []
        self.bridges = {}
        self.environment = {**os.environ, "AZOOKEY_DATA_DIR": str(self.directory / "data"),
                            "AZOOKEY_RESOURCES": str(self.directory / "absent-models"),
                            "XDG_CONFIG_HOME": str(self.directory / "config"),
                            "XDG_DATA_HOME": str(self.directory / "data-home")}

        def factory(role):
            bridge = ObservedReadingProcess({**self.environment, "AZOOKEY_BRIDGE_ROLE": role})
            self.bridges[role] = bridge
            return bridge

        self.coordinator = ReadingCoordinator(self.callbacks.dispatch, publish_input=self.inputs.append,
                                              publish_candidates=self.panels.append, notify=self.notices.append,
                                              reader_factory=lambda: factory("reading"),
                                              candidate_factory=lambda: factory("candidate"),
                                              **self.prepare_worker_settings())
        self.drain_until(lambda: self.coordinator._generation and (
            self.coordinator._settings_agreement.confirmed_identity if self.coordinator._settings_agreement
            else self.coordinator._candidate_settings))
        self.focus("field", opening=True)

    def tearDown(self):
        self.coordinator.close()
        for transport in (self.coordinator.transport, self.coordinator.candidates.transport):
            transport.worker.join(WAIT_SECONDS)
            self.assertFalse(transport.worker.is_alive())
        for bridge in self.bridges.values():
            self.assertEqual(len(bridge.threads), 1)
            self.assertNotIn(threading.get_ident(), bridge.threads)

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("real reading condition did not complete")

    def finish(self, token, consumed):
        self.finished.append((token, consumed))

    def focus(self, context, *, opening=False, private=False):
        if opening:
            self.coordinator.open_context(context)
        ready = []
        self.coordinator.focus_in(context, {"leftContext": "", "rightContext": "", "privateInput": private}, ready.append)
        self.drain_until(lambda: ready)
        self.assertNotIn("error", ready[0])

    def key(self, keyval, *, context="field", modifiers=0):
        token = object()
        self.coordinator.key(context, translate(keyval, modifiers), token=token, finish=self.finish)
        self.drain_until(lambda: any(completed is token for completed, _ in self.finished))
        self.assertFalse(self.coordinator._broken, [notice.code for notice in self.notices])
        return self.inputs[-1].snapshot

    def type(self, text, *, context="field"):
        snapshot = None
        for character in text:
            snapshot = self.key(ord(character), context=context)
        return snapshot

    def batch(self, text="nihongo"):
        self.type(text)
        self.key(0x20)
        self.drain_until(lambda: self.panels)
        return self.panels[-1].batch

    def select(self, batch, candidate):
        token = object()
        reference = {field: batch[field] for field in ("authority", "workerGeneration", "batchID")}
        self.coordinator.select("field", {"batch": reference, "candidateID": candidate["candidateID"]},
                                token=token, finish=self.finish)
        self.drain_until(lambda: any(completed is token for completed, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["preedit"].startswith(candidate["text"]), True)

    def flush_candidates(self):
        replies = []
        self.coordinator.candidates.settings(replies.append)
        self.drain_until(lambda: replies)
        self.assertIsNone(replies[0].error)

    def record(self, **fields):
        destination = os.environ.get("AZOOKEY_READING_COORDINATOR_EVIDENCE")
        if destination:
            with open(destination, "a", encoding="utf-8") as output:
                output.write(json.dumps({"test": self.id(), **fields}, sort_keys=True) + "\n")
