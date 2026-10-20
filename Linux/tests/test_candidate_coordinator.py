from copy import deepcopy
from pathlib import Path
import sys
import threading
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.candidate_coordinator import CandidateCoordinator
from azookey import candidate_protocol as protocol
from candidate_fixture import CallbackQueue, CandidateBridgeFixture, WAIT_SECONDS, candidate_request, completion_for


class CandidateCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.bridge = CandidateBridgeFixture()
        self.coordinator = CandidateCoordinator(self.callbacks.dispatch, bridge_factory=lambda: self.bridge)
        self.flush()

    def tearDown(self):
        if not self.coordinator._closed:
            self.coordinator.close()
        self.coordinator.transport.worker.join(WAIT_SECONDS)
        self.assertFalse(self.coordinator.transport.worker.is_alive())
        self.assertTrue(self.bridge.closed)

    def flush(self):
        done = []
        self.coordinator.settings(done.append)
        while not done:
            self.callbacks.drain(1)
        self.assertIsNone(done[0].error)
        return done[0]

    def adopt(self, request=None):
        request = request or candidate_request()
        replies = []
        self.coordinator.request_candidates(request, replies.append)
        self.callbacks.drain(1)
        self.assertEqual(len(replies), 1)
        self.assertIsNone(replies[0].error)
        return request, replies[0].batch

    def test_a_blocked_calculation_keeps_only_each_contexts_latest_pending_without_blocking_dispatch(self):
        gate = self.bridge.gate("candidates")
        replies = []
        first = candidate_request("あ")
        self.coordinator.request_candidates(first, replies.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        obsolete = candidate_request("い", revision=2)
        other = candidate_request("う", context="other")
        latest = candidate_request("え", revision=3)
        self.coordinator.request_candidates(obsolete, replies.append)
        settings = []
        self.coordinator.settings(settings.append)
        self.coordinator.request_candidates(other, replies.append)
        self.coordinator.request_candidates(latest, replies.append)
        heartbeat = []
        self.callbacks.dispatch(lambda value: heartbeat.append(value), "alive")
        self.callbacks.drain(1)
        self.assertEqual(heartbeat, ["alive"])
        self.assertFalse(gate.proceed.is_set())
        gate.proceed.set()
        self.flush()
        sent = [payload["request"]["authority"]["requestID"] for _, operation, payload in self.bridge.calls if operation == "candidates"]
        self.assertEqual(sent, [request["authority"]["requestID"] for request in (first, other, latest)])
        self.assertEqual([reply.batch["authority"] for reply in replies], [other["authority"], latest["authority"]])
        self.assertEqual(len(settings), 1)
        operations = [operation for _, operation, _ in self.bridge.calls]
        self.assertLess(operations.index("release"), operations.index("candidates", operations.index("candidates") + 1))
        self.assertEqual(len(self.bridge.threads), 1)
        self.assertNotIn(threading.get_ident(), self.bridge.threads)

    def test_retain_ack_precedes_the_next_calculation_even_before_main_loop_delivery(self):
        gate = self.bridge.gate("retain")
        replies = []
        first = candidate_request("あ", context="first")
        second = candidate_request("い", context="second")
        self.coordinator.request_candidates(first, replies.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.request_candidates(second, replies.append)
        self.assertEqual(sum(operation == "candidates" for _, operation, _ in self.bridge.calls), 1)
        self.assertTrue(self.callbacks.pending.empty())
        gate.proceed.set()
        self.bridge.wait_calls(lambda calls: sum(operation == "retain" for _, operation, _ in calls) == 2)
        self.callbacks.drain(2)
        self.assertEqual(len(replies), 2)
        self.assertEqual(self.bridge.retained, {reply.batch["batchID"] for reply in replies})
        self.assertEqual([operation for _, operation, _ in self.bridge.calls if operation in ("candidates", "retain")],
                         ["candidates", "retain", "candidates", "retain"])

    def test_reverse_dispatch_cannot_adopt_an_older_request_and_releases_its_retained_batch(self):
        replies = []
        self.coordinator.request_candidates(candidate_request("あ"), replies.append)
        old_callback, old_reply = self.callbacks.take()
        latest = candidate_request("い", revision=2)
        self.coordinator.request_candidates(latest, replies.append)
        new_callback, new_reply = self.callbacks.take()
        new_callback(new_reply)
        old_callback(old_reply)
        self.flush()
        self.assertEqual([reply.batch["authority"] for reply in replies], [latest["authority"]])
        self.assertNotIn(old_reply.batch["batchID"], self.bridge.batches)
        self.assertIn(new_reply.batch["batchID"], self.bridge.retained)

    def test_each_authority_change_rejects_an_undelivered_batch_without_replaying_it(self):
        for field, value in (("focusEpoch", 2), ("compositionRevision", 2), ("settingsRevision", 1),
                             ("requestID", "new-request"), ("readingProcessGeneration", "reader-2")):
            with self.subTest(field=field):
                request = candidate_request(context=field)
                replies = []
                self.coordinator.request_candidates(request, replies.append)
                callback, reply = self.callbacks.take()
                updated = {**request["authority"], field: value}
                self.coordinator.set_authority(updated)
                callback(reply)
                self.flush()
                self.assertEqual(replies, [])
                self.assertNotIn(reply.batch["batchID"], self.bridge.batches)

    def test_close_cancels_display_but_does_not_destroy_another_context(self):
        request, first = self.adopt(candidate_request(context="first"))
        replies = []
        self.coordinator.request_candidates(candidate_request(context="second"), replies.append)
        callback, reply = self.callbacks.take()
        self.coordinator.close_context("second", "reader-1")
        callback(reply)
        self.flush()
        self.assertEqual(replies, [])
        self.assertIn(first["batchID"], self.bridge.retained)
        completed = []
        self.coordinator.complete(completion_for(first), authority=request["authority"], callback=completed.append)
        self.flush()
        self.assertEqual(completed[0].completion["status"], "completed")

    def test_a_committed_notification_survives_later_focus_and_close_in_fifo_order(self):
        request, batch = self.adopt()
        gate = self.bridge.gate("complete")
        receipts = []
        completion = completion_for(batch)
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.set_authority({**request["authority"], "focusEpoch": 2, "compositionRevision": 2})
        self.coordinator.close_context("field", "reader-1")
        gate.proceed.set()
        self.flush()
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0].completion["commitID"], completion["commitID"])
        self.assertEqual(self.bridge.learning_updates, [(completion["commitID"], "あ")])
        operations = [operation for _, operation, _ in self.bridge.calls]
        self.assertLess(operations.index("complete"), operations.index("close"))

    def test_learning_changes_and_completion_preserve_queue_order_and_current_revision(self):
        request, batch = self.adopt()
        current = {**request["authority"], "settingsRevision": 1, "compositionRevision": 2, "requestID": "current"}
        self.coordinator.set_authority(current)
        settings = []
        self.coordinator.configure_learning("nothing", 1, worker_generation=batch["workerGeneration"], callback=settings.append)
        receipts = []
        self.coordinator.complete(completion_for(batch, settings=1), authority=current, callback=receipts.append)
        self.flush()
        self.assertEqual(settings[0].settings["settingsRevision"], 1)
        self.assertFalse(receipts[0].completion["learningRequested"])
        self.assertEqual(self.bridge.learning_updates, [])
        operations = [operation for _, operation, _ in self.bridge.calls]
        self.assertLess(operations.index("configure-learning"), operations.index("complete"))

    def test_same_worker_receipt_replay_is_explicit_and_never_coalesces_completions(self):
        request, batch = self.adopt()
        completion = completion_for(batch)
        gate = self.bridge.gate("complete")
        receipts = []
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        with self.assertRaises(ValueError):
            self.coordinator.complete({**completion, "privateInput": True}, authority=request["authority"], callback=receipts.append)
        gate.proceed.set()
        self.flush()
        self.assertEqual([reply.completion["status"] for reply in receipts], ["completed", "alreadyCompleted"])
        self.assertEqual(len(self.bridge.learning_updates), 1)
        self.assertEqual(sum(operation == "complete" for _, operation, _ in self.bridge.calls), 2)

    def test_completion_capacity_keeps_the_first_receipt_and_rejects_new_learning_before_send(self):
        first_completion = None
        for revision in range(1, protocol.MAX_COMPLETIONS_PER_CONTEXT + 1):
            request, batch = self.adopt(candidate_request(revision=revision))
            completion = completion_for(batch)
            if first_completion is None:
                first_completion = completion
            receipts = []
            self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
            self.callbacks.drain(1)
            self.assertEqual(receipts[0].completion["status"], "completed")

        request, batch = self.adopt(candidate_request(revision=protocol.MAX_COMPLETIONS_PER_CONTEXT + 1))
        receipts = []
        before = len(self.bridge.calls)
        with self.assertRaisesRegex(ValueError, "completion limit"):
            self.coordinator.complete(completion_for(batch), authority=request["authority"], callback=receipts.append)
        self.assertEqual(len(self.bridge.calls), before)
        self.coordinator.complete(first_completion, authority=request["authority"], callback=receipts.append)
        self.callbacks.drain(1)
        self.assertEqual(receipts[0].completion["status"], "alreadyCompleted")
        self.assertEqual(len(self.bridge.learning_updates), protocol.MAX_COMPLETIONS_PER_CONTEXT)
        self.assertTrue(self.coordinator.release(batch))
        self.flush()

    def test_rejected_notifications_reserve_their_ids_instead_of_freeing_capacity_for_reuse(self):
        first_completion = None
        with patch.object(protocol, "MAX_COMPLETIONS_PER_CONTEXT", 2):
            for revision in range(2):
                request, batch = self.adopt(candidate_request(revision=revision + 1, settings=revision))
                current = {**request["authority"], "settingsRevision": revision + 1}
                self.coordinator.set_authority(current)
                completion = completion_for(batch, settings=revision + 1)
                first_completion = first_completion or completion
                receipts = []
                self.coordinator.complete(completion, authority=current, callback=receipts.append)
                self.callbacks.drain(1)
                self.assertEqual(receipts[0].error, "stale_candidate_authority")
                self.coordinator.configure_learning("nothing", revision + 1,
                                                    worker_generation=batch["workerGeneration"], callback=None)
                self.flush()
            request, batch = self.adopt(candidate_request(revision=3, settings=2))
            before = len(self.bridge.calls)
            with self.assertRaisesRegex(ValueError, "completion limit"):
                self.coordinator.complete(completion_for(batch, settings=2),
                                          authority=request["authority"], callback=None)
            with self.assertRaisesRegex(ValueError, "commit identity was reused"):
                changed = {**completion_for(batch, settings=2), "commitID": first_completion["commitID"]}
                self.coordinator.complete(changed, authority=request["authority"], callback=None)
            self.assertEqual(len(self.bridge.calls), before)
            self.assertEqual(self.bridge.learning_updates, [])
            self.assertTrue(self.coordinator.release(batch))
            self.flush()

    def test_restart_and_close_end_capacity_without_reauthorizing_retired_candidates(self):
        with patch.object(protocol, "MAX_COMPLETIONS_PER_CONTEXT", 1):
            request, batch = self.adopt()
            first = completion_for(batch)
            self.coordinator.complete(first, authority=request["authority"], callback=None)
            self.flush()
            self.bridge.dead = True
            self.flush()
            request, batch = self.adopt(candidate_request(revision=2))
            with self.assertRaisesRegex(ValueError, "worker changed"):
                self.coordinator.complete(first, authority=request["authority"], callback=None)
            second = completion_for(batch)
            self.coordinator.complete(second, authority=request["authority"], callback=None)
            self.flush()
            self.coordinator.close_context("field", "reader-1")
            self.flush()
            request, batch = self.adopt(candidate_request(generation="reader-2"))
            with self.assertRaises(ValueError):
                self.coordinator.complete(second, authority=request["authority"], callback=None)
            self.coordinator.complete(completion_for(batch), authority=request["authority"], callback=None)
            self.flush()
            self.assertEqual(len(self.bridge.learning_updates), 3)
            self.assertEqual(sum(operation == "complete" for _, operation, _ in self.bridge.calls), 3)

    def test_context_capacity_rejects_new_owners_without_disturbing_existing_ones(self):
        requests = [candidate_request(context=f"field-{index}") for index in range(protocol.MAX_CONTEXTS)]
        for request in requests:
            self.coordinator.set_authority(request["authority"])
        overflow = candidate_request(context="overflow")
        before = len(self.bridge.calls)
        with self.assertRaisesRegex(ValueError, "context limit"):
            self.coordinator.request_candidates(overflow, lambda _reply: self.fail("overflow was delivered"))
        self.assertEqual(len(self.bridge.calls), before)
        request, batch = self.adopt(requests[0])
        self.coordinator.close_context(requests[-1]["authority"]["context"], "reader-1")
        self.flush()
        self.adopt(overflow)
        completed = []
        self.coordinator.complete(completion_for(batch), authority=request["authority"], callback=completed.append)
        self.flush()
        self.assertEqual(completed[0].completion["status"], "completed")

    def test_lost_completion_ack_is_uncertain_and_never_sent_to_a_restarted_worker(self):
        request, batch = self.adopt()
        completion = completion_for(batch)
        self.bridge.fail("complete", after_effect=True)
        receipts = []
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.callbacks.drain(1)
        self.assertTrue(receipts[0].uncertain)
        self.assertEqual(receipts[0].error, "candidate_worker_unavailable")
        self.flush()
        self.assertNotEqual(self.coordinator.transport.identity[0], batch["workerGeneration"])
        with self.assertRaises(ValueError):
            self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        newer = candidate_request("い", revision=2)
        self.adopt(newer)
        self.assertEqual(len(self.bridge.learning_updates), 1)
        self.assertEqual(sum(operation == "complete" for _, operation, _ in self.bridge.calls), 1)

    def test_restart_before_completion_delivery_does_not_send_the_old_candidate_to_the_new_worker(self):
        request, batch = self.adopt()
        self.bridge.dead = True
        replies = []
        self.coordinator.complete(completion_for(batch), authority=request["authority"], callback=replies.append)
        self.callbacks.drain(1)
        self.assertEqual(replies[0].error, "candidate_worker_changed")
        self.assertFalse(replies[0].uncertain)
        self.assertEqual(self.bridge.learning_updates, [])
        self.assertFalse(any(operation == "complete" for _, operation, _ in self.bridge.calls))

    def test_restart_before_main_loop_delivery_discards_an_old_batch(self):
        replies = []
        self.coordinator.request_candidates(candidate_request(), replies.append)
        callback, reply = self.callbacks.take()
        self.bridge.dead = True
        self.flush()
        callback(reply)
        self.assertEqual(replies, [])
        self.assertFalse(any(generation == "worker-1" and operation == "release" for generation, operation, _ in self.bridge.calls))

    def test_retain_failure_never_exposes_an_unprotected_batch(self):
        self.bridge.fail("retain")
        replies = []
        self.coordinator.request_candidates(candidate_request(), replies.append)
        self.callbacks.drain(1)
        self.assertIsNone(replies[0].batch)
        self.assertEqual(replies[0].error, "candidate_worker_unavailable")
        self.assertEqual(self.coordinator._retained, {})
        self.flush()
        self.adopt(candidate_request("い", revision=2))

    def test_invalid_authority_or_completion_does_not_consume_the_retained_reference(self):
        request, batch = self.adopt()
        completion = completion_for(batch)
        before = len(self.bridge.calls)
        for changed in ({**completion, "candidateID": "unknown"},
                        {**completion, "settingsRevision": 1},
                        {**completion, "authority": {**completion["authority"], "context": "other"}}):
            with self.assertRaises(ValueError):
                self.coordinator.complete(changed, authority=request["authority"], callback=lambda _reply: None)
        with self.assertRaises(ValueError):
            self.coordinator.set_authority({**request["authority"], "compositionRevision": 0})
        self.assertEqual(len(self.bridge.calls), before)
        receipts = []
        self.coordinator.complete(completion, authority=request["authority"], callback=receipts.append)
        self.flush()
        self.assertEqual(receipts[0].completion["status"], "completed")

    def test_wire_mutation_or_input_commands_are_rejected_before_adoption(self):
        for mutation in ("authority", "commands", "duplicate", "error-authority"):
            with self.subTest(mutation=mutation):
                def rewrite(operation, response):
                    if operation != "candidates":
                        return response
                    response = deepcopy(response)
                    if mutation == "authority":
                        response["batch"]["authority"]["requestID"] = "foreign"
                    elif mutation == "commands":
                        response["commits"] = ["must-not-commit"]
                    elif mutation == "duplicate":
                        response["batch"]["candidates"] *= 2
                    else:
                        response["error"] = "stale_candidate_authority"
                        response["authority"]["requestID"] = "foreign-error"
                    return response
                self.bridge.rewrite = rewrite
                replies = []
                self.coordinator.request_candidates(candidate_request(context=mutation), replies.append)
                self.callbacks.drain(1)
                self.assertEqual(replies[0].error, "candidate_worker_unavailable")
                self.assertIsNone(replies[0].batch)
                self.bridge.rewrite = None
                self.flush()

    def test_malformed_settings_do_not_kill_the_worker_or_leave_later_requests_waiting(self):
        self.bridge.rewrite = lambda operation, response: {**response, "learning": {}} if operation == "settings" else response
        replies = []
        self.coordinator.settings(replies.append)
        self.callbacks.drain(1)
        self.assertEqual(replies[0].error, "candidate_worker_unavailable")
        self.assertTrue(self.coordinator.transport.worker.is_alive())
        self.bridge.rewrite = None
        self.flush()
        self.adopt(candidate_request())

    def test_callback_failure_releases_the_original_reference_even_if_its_copy_was_changed(self):
        def broken(reply):
            reply.batch["authority"]["requestID"] = "modified-by-callback"
            raise RuntimeError("fixture presentation failure")
        self.coordinator.request_candidates(candidate_request(), broken)
        callback, reply = self.callbacks.take()
        batch_id = reply.batch["batchID"]
        with self.assertRaises(RuntimeError):
            callback(reply)
        self.flush()
        self.assertNotIn(batch_id, self.bridge.retained)
        self.assertNotIn(batch_id, self.bridge.batches)

    def test_dispatch_failure_after_enqueue_cannot_adopt_the_released_reference(self):
        def failing_dispatch(callback, reply):
            self.callbacks.dispatch(callback, reply)
            if reply.batch:
                raise RuntimeError("fixture failed after enqueue")
        self.coordinator.transport.dispatch = failing_dispatch
        replies = []
        with self.assertLogs("azookey.candidate_transport", level="ERROR"):
            self.coordinator.request_candidates(candidate_request(), replies.append)
            callback, reply = self.callbacks.take()
            self.bridge.wait_calls(lambda calls: any(operation == "release" for _, operation, _ in calls))
            callback(reply)
            self.flush()
        self.assertEqual(replies, [])
        self.assertNotIn(reply.batch["batchID"], self.bridge.retained)

    def test_a_rejected_learning_notification_releases_its_batch_without_retrying_or_learning(self):
        request, batch = self.adopt()
        self.coordinator.configure_learning("nothing", 1, worker_generation=batch["workerGeneration"], callback=lambda _reply: None)
        # The caller still has revision 0: the real worker remains authoritative.
        receipts = []
        self.coordinator.complete(completion_for(batch), authority=request["authority"], callback=receipts.append)
        self.flush()
        self.assertEqual(receipts[0].error, "stale_candidate_authority")
        self.assertFalse(receipts[0].uncertain)
        self.assertEqual(self.bridge.learning_updates, [])
        self.assertNotIn(batch["batchID"], self.bridge.retained)
        self.assertEqual(sum(operation == "complete" for _, operation, _ in self.bridge.calls), 1)

    def test_close_during_first_handshake_is_ordered_before_reopening_the_same_context(self):
        bridge = CandidateBridgeFixture()
        callbacks = CallbackQueue()
        gate = bridge.gate("settings")
        coordinator = CandidateCoordinator(callbacks.dispatch, bridge_factory=lambda: bridge)
        replies = []
        try:
            coordinator.request_candidates(candidate_request(), replies.append)
            self.assertTrue(gate.entered.wait(WAIT_SECONDS))
            coordinator.close_context("field", "reader-1")
            coordinator.request_candidates(candidate_request("い", generation="reader-2"), replies.append)
            gate.proceed.set()
            done = []
            coordinator.settings(done.append)
            while not done:
                callbacks.drain(1)
            self.assertEqual(len(replies), 1)
            self.assertEqual(replies[0].batch["authority"]["readingProcessGeneration"], "reader-2")
            close_index = next(index for index, (_, operation, _) in enumerate(bridge.calls) if operation == "close")
            next_index = next(index for index, (_, operation, payload) in enumerate(bridge.calls)
                              if operation == "candidates" and payload["request"]["authority"]["readingProcessGeneration"] == "reader-2")
            self.assertLess(close_index, next_index)
        finally:
            coordinator.close()
            coordinator.transport.worker.join(WAIT_SECONDS)
            self.assertFalse(coordinator.transport.worker.is_alive())

    def test_the_default_factory_copies_the_environment_and_forces_only_the_candidate_role(self):
        environment = {"AZOOKEY_BRIDGE_ROLE": "reading", "AZOOKEY_RESOURCES": "/fixture/models"}
        original = dict(environment)
        bridge = CandidateBridgeFixture()
        callbacks = CallbackQueue()
        with patch("azookey.candidate_transport.Bridge", return_value=bridge) as factory:
            coordinator = CandidateCoordinator(callbacks.dispatch, environment=environment)
            try:
                coordinator.settings(lambda _reply: None)
                callbacks.drain(1)
                factory.assert_called_once_with(environment={**original, "AZOOKEY_BRIDGE_ROLE": "candidate"})
                self.assertEqual(environment, original)
            finally:
                coordinator.close()
                coordinator.transport.worker.join(WAIT_SECONDS)
                self.assertFalse(coordinator.transport.worker.is_alive())

    def test_close_interrupts_a_blocked_child_and_suppresses_late_callbacks(self):
        gate = self.bridge.gate("candidates")
        replies = []
        self.coordinator.request_candidates(candidate_request(), replies.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.close()
        self.coordinator.transport.worker.join(WAIT_SECONDS)
        self.assertFalse(self.coordinator.transport.worker.is_alive())
        self.assertTrue(self.bridge.interrupted)
        self.assertEqual(replies, [])
        self.assertTrue(self.callbacks.pending.empty())


if __name__ == "__main__":
    unittest.main()
