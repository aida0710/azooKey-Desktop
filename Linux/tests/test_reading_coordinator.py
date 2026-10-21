"""Reading ownership behavior through real coordinator threads and controlled replies."""
from copy import deepcopy
from pathlib import Path
import sys
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.reading_coordinator import ReadingCoordinator
from candidate_fixture import CallbackQueue, CandidateBridgeFixture, WAIT_SECONDS
from reading_coordinator_fixture import ReadingBridgeFixture, event


class ReadingCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.reader = ReadingBridgeFixture()
        self.converter = CandidateBridgeFixture()
        self.inputs = []
        self.panels = []
        self.notices = []
        self.finished = []
        self.sequence = []
        self.coordinator = ReadingCoordinator(self.callbacks.dispatch, publish_input=self.publish,
                                              publish_candidates=self.panels.append, notify=self.notices.append,
                                              reader_factory=lambda: self.reader, candidate_factory=lambda: self.converter)
        self.drain_until(lambda: self.coordinator._generation is not None and self.coordinator._candidate_settings is not None)
        self.open_focus("field")

    def tearDown(self):
        self.coordinator.close()
        for transport in (self.coordinator.transport, self.coordinator.candidates.transport):
            transport.worker.join(WAIT_SECONDS)
            self.assertFalse(transport.worker.is_alive())
        self.assertNotIn(threading.get_ident(), self.reader.threads)

    def publish(self, publication):
        self.inputs.append(publication)
        self.sequence.append(("input", publication.token))

    def finish(self, token, consumed):
        self.finished.append((token, consumed))
        self.sequence.append(("finish", token))

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("reading condition did not complete")

    def open_focus(self, context, *, private=False):
        ready = []
        self.coordinator.open_context(context)
        self.coordinator.focus_in(context, {"leftContext": "left", "rightContext": "right", "privateInput": private}, ready.append)
        self.drain_until(lambda: ready)
        self.assertNotIn("error", ready[0])

    def key(self, text="", code=0, *, token=None):
        token = token or object()
        self.coordinator.key("field", event(text, code), token=token, finish=self.finish)
        self.drain_until(lambda: any(finished is token for finished, _ in self.finished))
        return token

    def batch(self):
        self.key("a")
        self.key("", 49)
        self.drain_until(lambda: self.panels)
        return self.panels[-1].batch

    def select(self, batch):
        token = object()
        selection = {"batch": {field: batch[field] for field in ("authority", "workerGeneration", "batchID")},
                     "candidateID": batch["candidates"][0]["candidateID"]}
        self.coordinator.select("field", selection, token=token, finish=self.finish)
        self.drain_until(lambda: any(finished is token for finished, _ in self.finished))

    def test_original_replies_follow_applied_inputs_and_native_barriers_in_fifo_order(self):
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("a"), token="first", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.barrier("field", token="release", finish=self.finish)
        self.coordinator.key("field", event("b"), token="second", finish=self.finish)
        self.assertEqual(self.finished, [])
        gate.proceed.set()
        self.drain_until(lambda: len(self.finished) == 3)
        self.assertEqual(self.sequence, [("input", "first"), ("finish", "first"), ("finish", "release"),
                                         ("input", "second"), ("finish", "second")])
        self.assertEqual(self.finished, [("first", True), ("release", False), ("second", True)])

    def test_candidates_are_retained_then_adopted_without_republishing_input(self):
        gate = self.converter.gate("retain")
        self.key("a")
        self.key("", 49)
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.assertEqual(self.panels, [])
        self.assertFalse(any(operation == "adopt-candidates" for operation, _ in self.reader.calls))
        input_count = len(self.inputs)
        gate.proceed.set()
        self.drain_until(lambda: self.panels)
        self.assertEqual(len(self.inputs), input_count)
        self.assertEqual(self.panels[0].batch["authority"]["focusEpoch"], self.inputs[-1].reference["focusEpoch"])

    def test_candidate_wait_does_not_hold_reading_enter_or_native_release(self):
        gate = self.converter.gate("candidates")
        self.key("a")
        self.key("", 49)
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(self.panels, [])
        gate.proceed.set()
        flushed = []
        self.coordinator.candidates.settings(flushed.append)
        self.drain_until(lambda: flushed)
        self.assertEqual(self.panels, [])

    def test_focus_cancel_retires_queued_inputs_and_moves_to_another_field_without_committing(self):
        self.key("shown")
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("unknown"), token="active", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.barrier("field", token="old-release", finish=self.finish)
        self.coordinator.key("field", event("unsent"), token="queued", finish=self.finish)
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.assertEqual(self.finished[-3:], [("active", True), ("old-release", True), ("queued", True)])
        self.assertNotIn(("out", True), self.finished)
        opened = []
        self.coordinator.open_context("other")
        self.coordinator.focus_in("other", {"leftContext": "", "rightContext": "", "privateInput": False}, opened.append)
        gate.proceed.set()
        self.drain_until(lambda: opened)
        self.assertEqual([item.snapshot["preedit"] for item in self.inputs], ["shown", ""])
        self.assertEqual([item.snapshot["commits"] for item in self.inputs], [[], []])
        self.assertEqual([token for token, _ in self.finished].count("active"), 1)
        self.assertEqual([token for token, _ in self.finished].count("queued"), 1)
        self.assertFalse(any(payload.get("event", {}).get("characters") == "unsent" for _, payload in self.reader.calls))
        self.assertFalse(self.coordinator._broken)

    def test_focus_submit_applies_to_old_reference_once_and_saves_next_reference_for_reopen(self):
        self.key("a")
        previous = self.inputs[-1].reference
        self.coordinator.focus_out("field", submit=True, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        self.assertEqual(self.inputs[-1].reference, previous)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        following = deepcopy(self.coordinator._contexts["field"].reference)
        self.assertGreater(following["focusEpoch"], previous["focusEpoch"])
        ready = []
        self.coordinator.focus_in("field", {"leftContext": "a", "rightContext": "", "privateInput": False}, ready.append)
        self.drain_until(lambda: ready)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], [])
        self.assertEqual([item for item in self.inputs if item.snapshot["commits"]], [self.inputs[-2]])

    def test_known_cancel_publisher_rejection_does_not_require_restart(self):
        self.key("a")
        self.coordinator.publish_input = lambda _publication: False
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        self.assertFalse(self.coordinator._broken)
        self.open_focus("other")

    def test_lost_reading_reply_preserves_displayed_boundary_without_replaying_any_key(self):
        self.key("shown")
        self.reader.fail("key", after_effect=True)
        self.coordinator.key("field", event("unknown"), token="unknown", finish=self.finish)
        self.coordinator.key("field", event("unsent"), token="unsent", finish=self.finish)
        self.drain_until(lambda: self.coordinator._broken)
        notices = {notice.token: notice for notice in self.notices if notice.token is not None}
        self.assertEqual(notices["unknown"].phase, "response-unknown")
        self.assertEqual(notices["unsent"].phase, "not-sent")
        self.assertEqual(notices["unknown"].displayed_snapshot["preedit"], "shown")
        self.assertEqual([item.snapshot["preedit"] for item in self.inputs], ["shown"])
        sent = [payload["event"]["characters"] for operation, payload in self.reader.calls if operation == "key"]
        self.assertEqual(sent, ["shown", "unknown"])
        self.assertEqual(self.finished[-2:], [("unknown", True), ("unsent", True)])

    def test_publication_exception_after_commit_does_not_retry_commit_or_original_key(self):
        self.key("a")
        def commit_then_fail(publication):
            self.inputs.append(publication)
            raise RuntimeError("fixture failure after application side effect")
        self.coordinator.publish_input = commit_then_fail
        self.key("", 36, token="enter")
        self.assertTrue(self.coordinator._broken)
        self.assertEqual([item.snapshot["commits"] for item in self.inputs], [[], ["a"]])
        self.assertEqual(self.finished[-1], ("enter", True))
        self.assertEqual(self.notices[-1].phase, "application-unknown")

    def test_atomic_unsupported_key_rejection_keeps_reading_available_for_next_key(self):
        self.key("a")
        self.key("", 999)
        self.key("b")
        self.assertFalse(self.coordinator._broken)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "ab")
        self.assertEqual(self.notices[-1].code, "unsupported_reading_action")

    def test_selected_completion_is_queued_before_later_focus_close_and_never_applies_its_ack(self):
        batch = self.batch()
        self.select(batch)
        gate = self.converter.gate("complete")
        self.key("", 36)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        closed = []
        self.coordinator.close_context("field", closed.append)
        self.drain_until(lambda: closed)
        count = len(self.inputs)
        gate.proceed.set()
        self.drain_until(lambda: any(notice.code == "candidate_learning_completed" for notice in self.notices))
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(len(self.converter.learning_updates), 1)

    def test_private_completion_keeps_preference_and_never_requests_learning(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        ready = []
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": True}, ready.append)
        self.drain_until(lambda: ready)
        self.select(self.batch())
        self.key("", 36)
        self.drain_until(lambda: any(notice.completion and notice.phase == "receipt" for notice in self.notices))
        self.assertEqual(self.converter.learning_updates, [])
        self.assertEqual(self.converter.learning, "inputAndOutput")

    def test_learning_update_requires_inactive_context_and_two_acknowledgements(self):
        with self.assertRaises(ValueError):
            self.coordinator.configure_learning("nothing", 1)
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        gate = self.converter.gate("configure-learning")
        configured = []
        self.coordinator.configure_learning("nothing", 1, configured.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        with self.assertRaises(ValueError):
            self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False})
        self.assertFalse(any(operation == "learning-revision" for operation, _ in self.reader.calls))
        gate.proceed.set()
        self.drain_until(lambda: configured)
        self.assertEqual(configured[0]["settingsRevision"], 1)
        self.assertEqual(self.reader.settings, 1)
        self.assertEqual(self.converter.settings_revision, 1)

    def test_reading_process_restart_rejects_the_old_owner_before_sending_a_new_key(self):
        self.key("a")
        self.reader.dead = True
        self.key("b", token="stale")
        self.assertTrue(self.coordinator._broken)
        self.assertEqual([payload["event"]["characters"] for operation, payload in self.reader.calls if operation == "key"], ["a"])
        self.assertEqual(self.notices[-1].phase, "not-sent")

    def test_malformed_reading_control_response_cannot_publish_commits(self):
        self.reader.rewrite = lambda operation, response: {**response, "snapshot": {"commits": ["wrong"]}} if operation == "prepare-candidates" else response
        self.key("a")
        self.key("", 49)
        self.drain_until(lambda: self.coordinator._broken)
        self.assertTrue(all(not item.snapshot["commits"] for item in self.inputs))

    def test_queued_candidate_delivery_after_a_new_key_is_released_without_adoption(self):
        self.key("a")
        self.key("", 49)
        self.callbacks.drain(1)
        callback, reply = self.callbacks.take()
        self.assertIsNotNone(reply.batch)
        self.coordinator.key("field", event("b"), token="new", finish=self.finish)
        callback(reply)
        self.drain_until(lambda: ("new", True) in self.finished)
        flushed = []
        self.coordinator.candidates.settings(flushed.append)
        self.drain_until(lambda: flushed)
        self.assertEqual(self.panels, [])
        self.assertFalse(any(operation == "adopt-candidates" for operation, _ in self.reader.calls))
        self.assertEqual(self.converter.retained, set())

    def test_key_release_does_not_cancel_an_in_flight_candidate_request(self):
        gate = self.converter.gate("candidates")
        self.key("a")
        self.key("", 49)
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.barrier("field", token="release", finish=self.finish)
        self.assertEqual(self.finished[-1], ("release", False))
        gate.proceed.set()
        self.drain_until(lambda: self.panels)
        self.assertEqual(len(self.panels), 1)

    def test_repeated_reading_callback_cannot_commit_or_finish_twice(self):
        self.key("a")
        self.coordinator.key("field", event("", 36), token="enter", finish=self.finish)
        callback, reply = self.callbacks.take()
        callback(reply)
        callback(reply)
        self.assertEqual([item.snapshot["commits"] for item in self.inputs], [[], ["a"]])
        self.assertEqual(self.finished.count(("enter", True)), 1)

    def test_reentrant_input_callback_keeps_later_key_after_the_original_reply(self):
        def enqueue(publication):
            self.publish(publication)
            if publication.token == "first":
                self.coordinator.key("field", event("b"), token="second", finish=self.finish)
        self.coordinator.publish_input = enqueue
        self.coordinator.key("field", event("a"), token="first", finish=self.finish)
        self.drain_until(lambda: len(self.finished) == 2)
        self.assertEqual(self.sequence, [("input", "first"), ("finish", "first"),
                                         ("input", "second"), ("finish", "second")])

    def test_unknown_input_owner_is_reported_without_native_replay(self):
        self.coordinator.publish_input = lambda _publication: False
        self.key("a", token="lost")
        self.assertTrue(self.coordinator._broken)
        self.assertEqual(self.notices[-1].phase, "not-applied")
        self.assertEqual(self.finished, [("lost", True)])

    def test_invalid_learning_mode_does_not_leave_focus_blocked(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        with self.assertRaises(ValueError):
            self.coordinator.configure_learning("unknown", 1)
        self.assertFalse(self.coordinator._changing_settings)

    def test_close_ends_pending_original_replies_once_and_ignores_late_reading_ack(self):
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("a"), token="active", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.key("field", event("b"), token="queued", finish=self.finish)
        self.coordinator.close()
        self.coordinator.close()
        self.assertEqual(self.finished, [("active", True), ("queued", True)])
        self.assertEqual(self.inputs, [])

    def test_close_reentered_from_publication_finishes_the_current_original_reply_once(self):
        def close_during_publish(publication):
            self.publish(publication)
            self.coordinator.close()
        self.coordinator.publish_input = close_during_publish
        self.coordinator.key("field", event("a"), token="current", finish=self.finish)
        self.drain_until(lambda: self.coordinator._closed)
        self.assertEqual(self.finished, [("current", True)])
        self.assertEqual(len(self.inputs), 1)

    def test_candidate_display_exception_keeps_the_real_source_available_for_explicit_selection(self):
        def fail_display(_publication):
            raise RuntimeError("fixture display failure")
        self.coordinator.publish_candidates = fail_display
        self.key("a")
        self.key("", 49)
        self.drain_until(lambda: any(notice.code == "reading_candidate_display_failed" for notice in self.notices))
        batch = deepcopy(self.coordinator._contexts["field"].batch)
        self.assertIn(batch["batchID"], self.converter.retained)
        self.select(batch)
        self.key("", 36)
        self.drain_until(lambda: any(notice.code == "candidate_learning_completed" for notice in self.notices))
        self.assertEqual(len(self.converter.learning_updates), 1)

    def test_invalid_cancel_cannot_retire_inputs_owned_by_an_earlier_focus(self):
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("a"), token="typed", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.focus_out("field", submit=True, token="out", finish=self.finish)
        self.coordinator.open_context("other")
        ready = []
        self.coordinator.focus_in("other", {"leftContext": "", "rightContext": "", "privateInput": False}, ready.append)
        with self.assertRaises(ValueError):
            self.coordinator.reset("field", submit=False, token="invalid", finish=self.finish)
        gate.proceed.set()
        self.drain_until(lambda: ready)
        self.assertEqual([item.snapshot["commits"] for item in self.inputs], [[], ["a"]])
        self.assertNotIn(("invalid", True), self.finished)

    def test_mismatched_settings_ack_does_not_advance_reader_or_allow_new_focus(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        self.converter.rewrite = lambda operation, response: {**response, "settingsRevision": 2} if operation == "configure-learning" else response
        completed = []
        self.coordinator.configure_learning("nothing", 1, completed.append)
        self.drain_until(lambda: completed)
        self.assertEqual(completed[0]["error"], "candidate_settings_changed")
        self.assertEqual(self.reader.settings, 0)
        with self.assertRaises(RuntimeError):
            self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False})

    def test_lost_lifecycle_ack_notifies_its_callback_once_and_never_reuses_the_old_reference(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        self.reader.fail("focus-in", after_effect=True)
        completed = []
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False}, completed.append)
        self.drain_until(lambda: self.coordinator._broken)
        self.assertEqual(len(completed), 1)
        self.assertIn("error", completed[0])
        self.assertEqual(self.notices[-1].phase, "response-unknown")
        self.assertEqual(self.notices[-1].displayed_snapshot["preedit"], "")
        self.assertEqual(self.notices[-1].displayed_snapshot["commits"], [])

    def test_changed_completion_privacy_is_rejected_before_input_or_learning_side_effects(self):
        self.select(self.batch())
        count = len(self.inputs)
        def change_privacy(operation, response):
            if operation == "key" and response.get("snapshot", {}).get("candidateCompletions"):
                response["snapshot"]["candidateCompletions"][0]["privateInput"] = True
            return response
        self.reader.rewrite = change_privacy
        self.key("", 36)
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(self.converter.learning_updates, [])
        self.assertEqual(self.notices[-1].code, "reading_completion_conditions_changed")

    def test_cancel_reentered_while_applying_keeps_original_reply_order(self):
        def cancel(publication):
            self.publish(publication)
            if publication.token == "first":
                self.coordinator.reset("field", submit=False, token="cancel", finish=self.finish)
        self.coordinator.publish_input = cancel
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("a"), token="first", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.key("field", event("b"), token="second", finish=self.finish)
        gate.proceed.set()
        self.drain_until(lambda: ("cancel", True) in self.finished)
        self.assertEqual(self.sequence, [("input", "first"), ("finish", "first"), ("finish", "second"),
                                         ("input", "cancel"), ("finish", "cancel")])
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "")

    def test_cancel_in_a_reopened_focus_does_not_erase_the_earlier_focus_commit(self):
        gate = self.reader.gate("key")
        self.coordinator.key("field", event("a"), token="old-key", finish=self.finish)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.focus_out("field", submit=True, token="old-out", finish=self.finish)
        self.coordinator.focus_in("field", {"leftContext": "a", "rightContext": "", "privateInput": False})
        self.coordinator.key("field", event("b"), token="new-key", finish=self.finish)
        self.coordinator.reset("field", submit=False, token="new-cancel", finish=self.finish)
        self.assertNotIn(("old-key", True), self.finished)
        self.assertNotIn(("old-out", True), self.finished)
        self.assertNotIn(("new-key", True), self.finished)
        gate.proceed.set()
        self.drain_until(lambda: ("new-cancel", True) in self.finished)
        self.assertEqual([text for item in self.inputs for text in item.snapshot["commits"]], ["a"])
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "")
        self.assertEqual(self.finished, [("old-key", True), ("old-out", True), ("new-key", True), ("new-cancel", True)])

    def focus_changes_during_commit(self, *, applied):
        batch = self.batch()
        self.select(batch)
        panel_count = len(self.panels)
        reopened = []

        def publish_with_focus_change(publication):
            if publication.token != "enter":
                return self.publish(publication)
            if applied:
                self.publish(publication)
            self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
            self.coordinator.focus_in("field", {"leftContext": "new", "rightContext": "", "privateInput": True},
                                      reopened.append)
            return applied

        self.coordinator.publish_input = publish_with_focus_change
        self.coordinator.key("field", event("", 36), token="enter", finish=self.finish)
        self.callbacks.drain(1)
        self.assertFalse(self.coordinator._broken)
        self.assertIsNone(self.coordinator._contexts["field"].displayed)
        self.assertIsNone(self.coordinator._contexts["field"].wanted)
        self.assertEqual(len(self.panels), panel_count)
        self.assertEqual(self.finished.count(("enter", True)), 1)
        self.drain_until(lambda: reopened)
        flushed = []
        self.coordinator.candidates.settings(flushed.append)
        self.drain_until(lambda: flushed)
        self.assertIsNone(self.coordinator._contexts["field"].displayed)
        self.assertTrue(self.coordinator._contexts["field"].private_input)
        return batch

    def test_applied_commit_keeps_old_learning_owner_when_focus_changes_inside_publication(self):
        batch = self.focus_changes_during_commit(applied=True)
        self.assertEqual([text for item in self.inputs for text in item.snapshot["commits"]],
                         [batch["candidates"][0]["text"]])
        completed = [payload["completion"] for _, operation, payload in self.converter.calls if operation == "complete"]
        self.assertEqual(len(completed), 1)
        self.assertEqual(completed[0]["authority"], batch["authority"])
        self.assertFalse(completed[0]["privateInput"])
        self.assertEqual(len(self.converter.learning_updates), 1)

    def test_unapplied_commit_is_retired_without_learning_when_focus_changes_inside_publication(self):
        self.focus_changes_during_commit(applied=False)
        self.assertEqual([text for item in self.inputs for text in item.snapshot["commits"]], [])
        self.assertFalse(any(operation == "complete" for _, operation, _ in self.converter.calls))
        self.assertEqual(self.converter.learning_updates, [])

    def restart_configured_candidate(self):
        self.coordinator.focus_out("field", submit=False, token="configure-out", finish=self.finish)
        self.drain_until(lambda: ("configure-out", True) in self.finished)
        configured = []
        self.coordinator.configure_learning("nothing", 1, configured.append)
        self.drain_until(lambda: configured)
        reopened = []
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False}, reopened.append)
        self.drain_until(lambda: reopened)
        self.converter.dead = True
        self.key("a")
        self.key("", 49)
        self.drain_until(lambda: any(notice.code == "candidate_worker_changed" for notice in self.notices))

    def wait_for_restoration(self):
        gate = self.converter.gate("configure-learning")
        self.key("", 49)
        self.callbacks.drain(1)  # The settings ACK authorizes only a restoration request.
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        return gate

    def test_candidate_settings_restore_wait_does_not_hold_enter_or_adopt_an_old_focus(self):
        self.restart_configured_candidate()
        gate = self.wait_for_restoration()
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.coordinator.focus_out("field", submit=False, token="restore-out", finish=self.finish)
        opened = []
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": True}, opened.append)
        self.drain_until(lambda: opened)
        self.key("b")
        self.key("", 49)
        self.assertEqual(self.panels, [])
        self.assertFalse(any(operation == "candidates" for _, operation, _ in self.converter.calls))
        gate.proceed.set()
        self.drain_until(lambda: self.panels)
        self.assertEqual(self.panels[-1].batch["authority"]["focusEpoch"], self.inputs[-1].reference["focusEpoch"])
        self.assertEqual(self.panels[-1].batch["authority"]["settingsRevision"], 1)
        self.assertTrue(self.converter.private[self.panels[-1].batch["batchID"]])
        self.assertEqual(self.converter.learning, "nothing")
        self.assertFalse(self.coordinator._broken)
        self.assertFalse(any(operation == "complete" for _, operation, _ in self.converter.calls))

    def test_wrong_restoration_ack_cannot_enable_candidate_adoption(self):
        self.restart_configured_candidate()
        self.converter.rewrite = lambda operation, response: {**response, "learning": "inputAndOutput"} if operation == "configure-learning" else response
        self.key("", 49)
        self.drain_until(lambda: any(notice.code == "candidate_settings_changed" for notice in self.notices))
        self.assertIsNone(self.coordinator._candidate_settings)
        self.assertEqual(self.panels, [])
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertFalse(self.coordinator._broken)

    def test_lost_restoration_ack_keeps_reading_and_retries_only_after_an_explicit_candidate_request(self):
        self.restart_configured_candidate()
        self.converter.fail("configure-learning", after_effect=True)
        self.key("", 49)
        self.drain_until(lambda: any(notice.code == "candidate_worker_unavailable" for notice in self.notices))
        self.assertEqual(self.panels, [])
        self.assertFalse(self.coordinator._broken)
        attempts = sum(operation == "configure-learning" for _, operation, _ in self.converter.calls)
        self.key("b")
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "ab")
        self.assertEqual(sum(operation == "configure-learning" for _, operation, _ in self.converter.calls), attempts)
        self.key("", 49)
        self.drain_until(lambda: self.panels)
        self.assertEqual(self.converter.learning, "nothing")
        self.assertEqual(self.converter.settings_revision, 1)
        self.assertEqual(sum(operation == "configure-learning" for _, operation, _ in self.converter.calls), attempts + 1)
        self.assertFalse(any(operation == "complete" for _, operation, _ in self.converter.calls))

    def test_restoration_ack_from_a_retired_worker_cannot_enable_candidate_adoption(self):
        self.restart_configured_candidate()
        gate = self.wait_for_restoration()
        gate.proceed.set()
        callback, reply = self.callbacks.take()
        self.assertEqual(reply.settings["settingsRevision"], 1)
        self.converter.dead = True
        settings = []
        self.coordinator.candidates.settings(settings.append)
        self.callbacks.drain(1)
        self.assertNotEqual(settings[0].worker_generation, reply.worker_generation)
        callback(reply)
        self.assertEqual(self.notices[-1].code, "candidate_worker_changed")
        self.assertIsNone(self.coordinator._candidate_settings)
        self.assertEqual(self.panels, [])
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])

    def test_same_or_ahead_revision_with_another_preference_is_rejected_without_guessing_settings(self):
        self.restart_configured_candidate()
        attempts = sum(operation == "configure-learning" for _, operation, _ in self.converter.calls)
        for revision in (1, 2):
            with self.subTest(revision=revision):
                self.converter.rewrite = lambda operation, response: {**response, "settingsRevision": revision} if operation == "settings" else response
                notices = len(self.notices)
                self.key("", 49)
                self.drain_until(lambda: len(self.notices) > notices)
                self.assertEqual(self.notices[-1].code, "candidate_settings_changed")
                self.assertIsNone(self.coordinator._candidate_settings)
                self.assertEqual(self.panels, [])
                self.assertEqual(sum(operation == "configure-learning" for _, operation, _ in self.converter.calls), attempts)
        self.assertEqual(self.coordinator._settings_revision, 1)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])

    def test_old_focus_rejection_cannot_retire_the_new_same_context_owner(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        gate = self.reader.gate("focus-in")
        self.reader.reject("focus-in", "reading_request_limit")
        rejected, reopened = [], []
        self.coordinator.focus_in("field", {"leftContext": "old", "rightContext": "", "privateInput": False}, rejected.append)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.focus_out("field", submit=False, token="old-out", finish=self.finish)
        self.coordinator.focus_in("field", {"leftContext": "new", "rightContext": "", "privateInput": True}, reopened.append)
        gate.proceed.set()
        self.drain_until(lambda: reopened)
        self.assertEqual(rejected[0]["error"], "reading_request_limit")
        self.assertNotIn("error", reopened[0])
        self.key("a", token="new")
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "a")
        self.assertEqual(self.inputs[-1].reference, reopened[0]["reference"])
        self.assertTrue(self.coordinator._contexts["field"].private_input)
        self.assertEqual(self.finished.count(("new", True)), 1)

    def test_current_focus_rejection_allows_a_later_valid_focus(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        self.reader.reject("focus-in", "reading_request_limit")
        rejected = []
        self.coordinator.focus_in("field", {"leftContext": "bad", "rightContext": "", "privateInput": False}, rejected.append)
        self.drain_until(lambda: rejected)
        self.assertIsNone(self.coordinator._planned_focus)
        reopened = []
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False}, reopened.append)
        self.drain_until(lambda: reopened)
        self.key("a")
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "a")


if __name__ == "__main__":
    unittest.main()
