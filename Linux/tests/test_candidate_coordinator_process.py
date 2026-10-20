"""Real JSONL candidate lifetime tests; no IBus/GTK or input-field mutations."""
from copy import deepcopy
import os
from pathlib import Path
import queue
import signal
import sys
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.candidate_coordinator import CandidateCoordinator
from candidate_fixture import CallbackQueue, WAIT_SECONDS, candidate_request, completion_for


class ObservedCandidateBridge(Bridge):
    def __init__(self, environment):
        self.started = queue.Queue()
        self.events = []
        self.owner_threads = set()
        self.lose_completion_ack = False
        super().__init__(timeout=WAIT_SECONDS, environment=environment)

    def request(self, operation, **payload):
        self.owner_threads.add(threading.get_ident())
        self.events.append(("started", operation, deepcopy(payload)))
        self.started.put(operation)
        response = super().request(operation, **payload)
        self.events.append(("replied", operation, deepcopy(response)))
        if operation == "complete" and self.lose_completion_ack:
            self.lose_completion_ack = False
            raise RuntimeError("fixture lost a real completion acknowledgement")
        return response


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real Linux Swift candidate process")
class CandidateCoordinatorProcessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.callbacks = CallbackQueue()
        self.environment = {**os.environ, "AZOOKEY_BRIDGE_ROLE": "candidate",
                            "AZOOKEY_DATA_DIR": str(self.directory / "data"),
                            "AZOOKEY_RESOURCES": str(self.directory / "absent-models"),
                            "XDG_CONFIG_HOME": str(self.directory / "config"),
                            "XDG_DATA_HOME": str(self.directory / "data-home")}
        self.bridge = None

        def factory():
            self.bridge = ObservedCandidateBridge(self.environment)
            return self.bridge

        self.coordinator = CandidateCoordinator(self.callbacks.dispatch, bridge_factory=factory)
        self.flush()

    def tearDown(self):
        self.coordinator.close()
        self.coordinator.transport.worker.join(WAIT_SECONDS)
        self.assertFalse(self.coordinator.transport.worker.is_alive())
        self.assertEqual(len(self.bridge.owner_threads), 1)
        self.assertNotIn(threading.get_ident(), self.bridge.owner_threads)

    def flush(self):
        replies = []
        self.coordinator.settings(replies.append)
        while not replies:
            self.callbacks.drain(1)
        self.assertIsNone(replies[0].error)
        return replies[0]

    def adopt(self, request):
        replies = []
        self.coordinator.request_candidates(request, replies.append)
        self.callbacks.drain(1)
        self.assertEqual(len(replies), 1)
        self.assertIsNone(replies[0].error)
        self.assertTrue(replies[0].batch["candidates"])
        return replies[0].batch

    def memory(self):
        return {file.name: file.read_bytes() for file in (self.directory / "data" / "memory").iterdir() if file.is_file()}

    def test_sigstop_keeps_dispatch_available_and_resuming_calculates_only_the_latest_pending_per_context(self):
        while not self.bridge.started.empty():
            self.bridge.started.get_nowait()
        process = self.bridge.process
        replies = []
        first = candidate_request("あ")
        latest = candidate_request("にほんご", revision=3)
        other = candidate_request("きょう", context="other")
        os.kill(process.pid, signal.SIGSTOP)
        try:
            self.coordinator.request_candidates(first, replies.append)
            self.assertEqual(self.bridge.started.get(timeout=WAIT_SECONDS), "candidates")
            self.coordinator.request_candidates(candidate_request("い", revision=2), replies.append)
            self.coordinator.request_candidates(other, replies.append)
            self.coordinator.request_candidates(latest, replies.append)
            heartbeat = []
            self.callbacks.dispatch(lambda value: heartbeat.append(value), "alive")
            self.callbacks.drain(1)
            self.assertEqual(heartbeat, ["alive"])
            self.assertEqual(replies, [])
        finally:
            os.kill(process.pid, signal.SIGCONT)
        self.flush()
        self.assertEqual([reply.batch["authority"] for reply in replies], [other["authority"], latest["authority"]])
        sent = [payload["request"]["authority"] for phase, operation, payload in self.bridge.events
                if phase == "started" and operation == "candidates"]
        self.assertEqual(sent, [first["authority"], other["authority"], latest["authority"]])

    def test_reverse_delivery_releases_the_old_real_batch_and_retains_before_the_next_calculation(self):
        replies = []
        first = candidate_request("きょう")
        latest = candidate_request("にほんご", revision=2)
        self.coordinator.request_candidates(first, replies.append)
        old_callback, old_reply = self.callbacks.take()
        self.coordinator.request_candidates(latest, replies.append)
        new_callback, new_reply = self.callbacks.take()
        new_callback(new_reply)
        old_callback(old_reply)
        self.flush()
        self.assertEqual([reply.batch["authority"] for reply in replies], [latest["authority"]])
        old_batch = old_reply.batch["batchID"]
        released = [payload for phase, operation, payload in self.bridge.events if phase == "replied" and operation == "release"]
        self.assertTrue(any(payload.get("reference", {}).get("batchID") == old_batch and "error" not in payload for payload in released))
        retained_index = next(index for index, (phase, operation, _) in enumerate(self.bridge.events)
                              if phase == "replied" and operation == "retain")
        next_calculation = next(index for index, (phase, operation, payload) in enumerate(self.bridge.events)
                                if phase == "started" and operation == "candidates" and payload["request"]["authority"] == latest["authority"])
        self.assertLess(retained_index, next_calculation)

    def test_learning_revision_and_later_focus_close_do_not_cancel_a_permitted_real_completion(self):
        request = candidate_request("きょう")
        batch = self.adopt(request)
        before = self.memory()
        current = {**request["authority"], "compositionRevision": 2, "settingsRevision": 1, "requestID": "current"}
        self.coordinator.set_authority(current)
        configured = []
        self.coordinator.configure_learning("nothing", 1, worker_generation=batch["workerGeneration"], callback=configured.append)
        receipts = []
        completion = completion_for(batch, text="京", settings=1)
        self.coordinator.complete(completion, authority=current, callback=receipts.append)
        self.coordinator.set_authority({**current, "focusEpoch": 2})
        self.coordinator.close_context("field", "reader-1")
        self.flush()
        self.assertEqual(configured[0].settings["learning"], "nothing")
        self.assertEqual(receipts[0].completion["commitID"], completion["commitID"])
        self.assertFalse(receipts[0].completion["learningRequested"])
        self.assertEqual(self.memory(), before)
        sent = [operation for phase, operation, _ in self.bridge.events if phase == "started"]
        self.assertLess(sent.index("configure-learning"), sent.index("complete"))
        self.assertLess(sent.index("complete"), sent.index("close"))

    def test_same_worker_explicit_ack_replay_preserves_the_original_completion_payload(self):
        request = candidate_request("きょう")
        batch = self.adopt(request)
        completion = completion_for(batch, text="京")
        original = deepcopy(completion)
        receipts = []
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        completion["candidateID"] = "changed-after-enqueue"
        self.flush()
        saved = self.memory()
        self.assertTrue(saved)
        self.coordinator.complete(original, authority=request["authority"], callback=receipts.append)
        self.flush()
        self.assertEqual([reply.completion["status"] for reply in receipts], ["completed", "alreadyCompleted"])
        self.assertEqual(self.memory(), saved)
        sent = [payload["completion"] for phase, operation, payload in self.bridge.events if phase == "started" and operation == "complete"]
        self.assertEqual(sent, [original, original])

    def test_lost_real_ack_is_reported_once_and_never_replayed_after_restart(self):
        request = candidate_request("きょう")
        batch = self.adopt(request)
        completion = completion_for(batch, text="京")
        self.bridge.lose_completion_ack = True
        receipts = []
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.callbacks.drain(1)
        self.assertEqual(receipts[0].error, "candidate_worker_unavailable")
        self.assertTrue(receipts[0].uncertain)
        saved = self.memory()
        self.assertTrue(saved, "the failed transport had already applied actual converter learning")
        self.flush()
        with self.assertRaises(ValueError):
            self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.adopt(candidate_request("にほんご", revision=2))
        self.assertEqual(self.memory(), saved)
        self.assertEqual(sum(phase == "started" and operation == "complete" for phase, operation, _ in self.bridge.events), 1)

    def test_a_dead_process_is_replaced_without_sending_its_candidate_to_the_new_generation(self):
        request = candidate_request("きょう")
        batch = self.adopt(request)
        self.bridge.process.kill()
        self.bridge.process.wait(timeout=WAIT_SECONDS)
        receipts = []
        self.coordinator.complete(completion_for(batch, text="京"), authority=request["authority"], callback=receipts.append)
        self.callbacks.drain(1)
        self.assertEqual(receipts[0].error, "candidate_worker_changed")
        self.assertFalse(receipts[0].uncertain)
        self.assertNotEqual(self.coordinator.transport.identity[0], batch["workerGeneration"])
        self.assertFalse(any(phase == "started" and operation == "complete" for phase, operation, _ in self.bridge.events))
        self.adopt(candidate_request("にほんご", revision=2))


if __name__ == "__main__":
    unittest.main()
