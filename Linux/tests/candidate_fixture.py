"""Deterministic candidate transport gates and wire fixtures, without a GUI."""
from collections import defaultdict, deque
from copy import deepcopy
from dataclasses import dataclass, field
import queue
import threading
import uuid


# Detect a broken test handshake; never used to hide a product ordering race.
WAIT_SECONDS = 5


def candidate_request(reading="あ", *, context="field", focus=1, revision=1, settings=0, generation="reader-1"):
    return {
        "authority": {"context": context, "readingProcessGeneration": generation,
                      "focusEpoch": focus, "compositionRevision": revision,
                      "settingsRevision": settings, "requestID": str(uuid.uuid4())},
        "composition": {"schemaVersion": 1,
                        "input": [{"piece": {"kind": "character", "value": character},
                                   "inputStyle": {"kind": "direct"}} for character in reading],
                        "convertTarget": reading, "convertTargetCursorPosition": len(reading),
                        "lastInputStyle": {"kind": "direct"}, "conversionRangeEnd": None,
                        "customInputTableRevisions": {}},
        "leftContext": "", "rightContext": "", "privateInput": False,
    }


def completion_for(batch, *, text=None, settings=0):
    candidate = next(item for item in batch["candidates"] if text is None or item["text"] == text)
    return {field: deepcopy(batch[field]) for field in ("authority", "workerGeneration", "batchID")} | {
        "candidateID": candidate["candidateID"], "commitID": str(uuid.uuid4()),
        "settingsRevision": settings, "privateInput": False,
    }


class CallbackQueue:
    def __init__(self):
        self.pending = queue.Queue()

    def dispatch(self, callback, reply):
        self.pending.put((callback, reply))

    def take(self):
        return self.pending.get(timeout=WAIT_SECONDS)

    def drain(self, count):
        for _ in range(count):
            callback, reply = self.take()
            callback(reply)


@dataclass
class Gate:
    entered: threading.Event = field(default_factory=threading.Event)
    proceed: threading.Event = field(default_factory=threading.Event)


class CandidateBridgeFixture:
    def __init__(self):
        self.restarts = 0
        self.generation = "worker-0"
        self.condition = threading.Condition()
        self.calls = []
        self.threads = set()
        self.gates = defaultdict(deque)
        self.all_gates = []
        self.failures = defaultdict(deque)
        self.rewrite = None
        self.dead = False
        self.interrupted = False
        self.closed = False
        self.serial = 0
        self.learning_updates = []
        self._reset()

    def _reset(self):
        self.settings_revision = 0
        self.learning = "inputAndOutput"
        self.batches = {}
        self.private = {}
        self.retained = set()
        self.receipts = {}

    def gate(self, operation):
        gate = Gate()
        with self.condition:
            self.gates[operation].append(gate)
            self.all_gates.append(gate)
        return gate

    def fail(self, operation, *, after_effect=False):
        self.failures[operation].append(after_effect)

    def wait_calls(self, predicate):
        with self.condition:
            if not self.condition.wait_for(lambda: predicate(self.calls), timeout=WAIT_SECONDS):
                raise AssertionError("candidate operation did not arrive")

    def ensure_running(self):
        if self.interrupted:
            raise RuntimeError("fixture interrupted")
        if self.dead:
            self.restarts += 1
            self.generation = f"worker-{self.restarts}"
            self.dead = False
            self._reset()

    def request(self, operation, **payload):
        self.ensure_running()
        with self.condition:
            self.threads.add(threading.get_ident())
            self.calls.append((self.generation, operation, deepcopy(payload)))
            gate = self.gates[operation].popleft() if self.gates[operation] else None
            self.condition.notify_all()
        if gate is not None:
            gate.entered.set()
            if not gate.proceed.wait(WAIT_SECONDS) or self.interrupted:
                raise RuntimeError("fixture wait ended")
        failure = self.failures[operation].popleft() if self.failures[operation] else None
        if failure is False:
            raise RuntimeError("fixture failed before response")
        response = self._respond(operation, payload)
        if failure is True:
            raise RuntimeError("fixture lost response after effect")
        if self.rewrite is not None:
            response = self.rewrite(operation, response)
        return response

    def _header(self, **payload):
        return {"workerGeneration": self.generation, "settingsRevision": self.settings_revision,
                "learning": self.learning, "customInputTableRevisions": {}, **payload}

    def _respond(self, operation, payload):
        if operation == "settings":
            return self._header()
        if operation == "candidates":
            return self._calculate(payload["request"])
        source = payload.get("reference") or payload.get("completion") or payload
        if source.get("workerGeneration") != self.generation:
            return self._header(error="wrong_candidate_worker_generation")
        if operation == "configure-learning":
            if payload["settingsRevision"] <= self.settings_revision:
                return self._header(error="stale_candidate_authority")
            self.settings_revision = payload["settingsRevision"]
            self.learning = payload["learning"]
            return self._header()
        if operation == "close":
            for batch_id, batch in tuple(self.batches.items()):
                if batch["authority"]["context"] == payload["context"]:
                    self.batches.pop(batch_id)
                    self.retained.discard(batch_id)
            self.receipts = {key: receipt for key, receipt in self.receipts.items()
                             if receipt["authority"]["context"] != payload["context"]}
            return self._header()
        if operation == "complete" and source["commitID"] in self.receipts:
            receipt = {**self.receipts[source["commitID"]], "status": "alreadyCompleted"}
            return self._header(authority=source["authority"], completion=receipt)
        batch = self.batches.get(source["batchID"])
        if batch is None or batch["authority"] != source["authority"]:
            return self._header(error="unknown_candidate_batch", authority=source["authority"])
        if operation == "retain":
            self.retained.add(source["batchID"])
            return self._header(authority=source["authority"], reference=source)
        if operation == "release":
            self.batches.pop(source["batchID"])
            self.retained.discard(source["batchID"])
            return self._header(authority=source["authority"], reference=source)
        if operation == "complete":
            return self._complete(source, batch)
        raise ValueError("unexpected fixture operation")

    def _calculate(self, request):
        if request["authority"]["settingsRevision"] != self.settings_revision:
            return self._header(error="stale_candidate_authority", authority=request["authority"])
        for batch_id, batch in tuple(self.batches.items()):
            if batch["authority"]["context"] == request["authority"]["context"] and batch_id not in self.retained:
                self.batches.pop(batch_id)
        self.serial += 1
        batch = {"authority": request["authority"], "workerGeneration": self.generation,
                 "batchID": f"batch-{self.serial}", "candidates": [{
                     "candidateID": f"candidate-{self.serial}", "text": request["composition"]["convertTarget"],
                     "composingCount": {"kind": "surfaceCount", "count": 1}, "presentation": {},
                 }]}
        self.batches[batch["batchID"]] = deepcopy(batch)
        self.private[batch["batchID"]] = request["privateInput"]
        return self._header(authority=request["authority"], batch=batch)

    def _complete(self, source, batch):
        if source["batchID"] not in self.retained:
            return self._header(error="candidate_batch_not_retained", authority=source["authority"])
        if source["settingsRevision"] != self.settings_revision:
            return self._header(error="stale_candidate_authority", authority=source["authority"])
        learning = self.learning == "inputAndOutput" and not source["privateInput"] and not self.private[source["batchID"]]
        if learning:
            self.learning_updates.append((source["commitID"], batch["candidates"][0]["text"]))
        self.batches.pop(source["batchID"])
        self.retained.discard(source["batchID"])
        receipt = {field: source[field] for field in ("authority", "workerGeneration", "batchID", "candidateID", "commitID")}
        receipt.update(status="completed", learningRequested=learning)
        self.receipts[source["commitID"]] = receipt
        return self._header(authority=source["authority"], completion=receipt)

    def invalidate(self):
        self.dead = True

    def interrupt(self):
        self.interrupted = True
        for gate in self.all_gates:
            gate.proceed.set()

    def close(self):
        self.closed = True
