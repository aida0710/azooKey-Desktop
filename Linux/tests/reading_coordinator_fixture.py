"""Scriptable reading ownership fixture; formal kana behavior uses real JSONL tests."""
from collections import defaultdict, deque
from copy import deepcopy
import threading

from candidate_fixture import Gate, WAIT_SECONDS, candidate_request, completion_for


def event(text="", code=0):
    return {"keyCode": code, "characters": text, "charactersIgnoringModifiers": text, "modifierFlags": 0}


class ReadingBridgeFixture:
    def __init__(self):
        self.restarts = 0
        self.generation = "reader-0"
        self.dead = False
        self.closed = False
        self.interrupted = False
        self.calls = []
        self.threads = set()
        self.gates = defaultdict(deque)
        self.all_gates = []
        self.failures = defaultdict(deque)
        self.rewrite = None
        self.condition = threading.Condition()
        self._reset()

    def _reset(self):
        self.epoch = 0
        self.settings = 0
        self.contexts = {}
        self.focus = None

    def gate(self, operation):
        gate = Gate()
        self.gates[operation].append(gate)
        self.all_gates.append(gate)
        return gate

    def fail(self, operation, *, after_effect=False):
        self.failures[operation].append(after_effect)

    def ensure_running(self):
        if self.interrupted:
            raise RuntimeError("fixture interrupted")
        if self.dead:
            self.restarts += 1
            self.generation = f"reader-{self.restarts}"
            self.dead = False
            self._reset()

    def request(self, operation, **payload):
        self.ensure_running()
        self.threads.add(threading.get_ident())
        with self.condition:
            self.calls.append((operation, deepcopy(payload)))
            self.condition.notify_all()
        if self.gates[operation]:
            gate = self.gates[operation].popleft()
            gate.entered.set()
            if not gate.proceed.wait(WAIT_SECONDS):
                raise RuntimeError("fixture gate expired")
        failure = self.failures[operation].popleft() if self.failures[operation] else None
        if failure is False:
            raise RuntimeError("fixture failed before reply")
        response = self._respond(operation, payload)
        if failure is True:
            raise RuntimeError("fixture lost acknowledgement")
        return self.rewrite(operation, deepcopy(response)) if self.rewrite else response

    def _header(self, kind="acknowledgement", **fields):
        return {"kind": kind, "readingProcessGeneration": self.generation, "settingsRevision": self.settings, **fields}

    def _reference(self, context):
        self.epoch += 1
        return {"context": context, "readingProcessGeneration": self.generation, "focusEpoch": self.epoch}

    def _respond(self, operation, payload):
        if operation == "hello":
            return self._header("process", limits={})
        if operation == "open":
            reference = self._reference(payload["context"])
            self.contexts[payload["context"]] = {"reference": reference, "text": "", "revision": 0,
                                                  "batch": None, "selection": None, "state": "none"}
            return self._header(reference=reference)
        if operation == "learning-revision":
            self.settings = payload["settingsRevision"]
            return self._header()
        reference = payload["reference"]
        state = self.contexts.get(reference["context"])
        if state is None or state["reference"] != reference:
            return self._header("error", error="stale_reading_focus")
        if operation == "focus-in":
            state["reference"] = self._reference(reference["context"])
            state["surroundings"] = payload["surroundings"]
            self.focus = reference["context"]
            return self._header(reference=state["reference"])
        if operation == "close":
            self.contexts.pop(reference["context"])
            return self._header(reference=reference)
        if operation == "prepare-candidates":
            request = candidate_request(state["text"], context=reference["context"], focus=reference["focusEpoch"],
                                        revision=state["revision"], settings=self.settings, generation=self.generation)
            request.update(state["surroundings"])
            state["request"] = request
            return self._header("candidates", reference=reference, candidateRequest=request)
        if operation == "adopt-candidates":
            if payload["batch"]["authority"] != state["request"]["authority"]:
                return self._header("error", error="stale_candidate_request")
            state["batch"] = payload["batch"]
            return self._header(reference=reference, candidateReference=payload["retainedReference"])
        if operation == "candidate-worker-stopped":
            return self._header(reference=reference)
        if operation == "select":
            state["selection"] = payload["selection"]
            state["state"] = "selecting"
            return self._input(state, reference)
        if operation in ("focus-out", "reset"):
            snapshot = self._commit(state) if payload["submit"] else self._clear(state)
            response = self._header("input", reference=reference, snapshot=snapshot)
            if operation == "focus-out":
                state["reference"] = self._reference(reference["context"])
                self.focus = None
                response["nextReference"] = state["reference"]
            return response
        if operation == "key":
            return self._key(state, reference, payload["event"])
        raise ValueError("unsupported reading fixture operation")

    def _key(self, state, reference, key):
        code = key["keyCode"]
        if code == 999:
            return self._header("error", error="unsupported_reading_action")
        if code == 49:
            return self._input(state, reference, request="candidates")
        if code == 36:
            return self._header("input", reference=reference, snapshot=self._commit(state))
        if code == 53:
            return self._header("input", reference=reference, snapshot=self._clear(state))
        state["text"] += key["characters"]
        state["revision"] += 1
        state["state"] = "composing"
        state["selection"] = None
        return self._input(state, reference)

    def _snapshot(self, state, **fields):
        text = state["text"]
        if state["selection"]:
            text = state["batch"]["candidates"][0]["text"]
        return {"consumed": True, "preedit": text, "cursor": len(text), "commits": [],
                "reading": state["text"], "readingCursor": len(state["text"]),
                "inputState": state["state"], "compositionRevision": state["revision"],
                "generation": state["revision"], **fields}

    def _input(self, state, reference, **fields):
        return self._header("input", reference=reference, snapshot=self._snapshot(state, **fields))

    def _clear(self, state):
        state.update(text="", selection=None, batch=None, state="none", revision=state["revision"] + 1)
        return self._snapshot(state)

    def _commit(self, state):
        text = self._snapshot(state)["preedit"]
        completions = []
        if state["selection"]:
            completion = completion_for(state["batch"], settings=self.settings)
            completion["privateInput"] = state["surroundings"]["privateInput"]
            completions.append(completion)
        return {**self._clear(state), "commits": [text] if text else [], "candidateCompletions": completions}

    def invalidate(self):
        self.dead = True

    def interrupt(self):
        self.interrupted = True
        for gate in self.all_gates:
            gate.proceed.set()

    def close(self):
        self.closed = True
