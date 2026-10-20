"""External callbacks cannot strand original replies or retire the next field."""
from copy import deepcopy
import unittest

from azookey.reading_coordinator import ReadingCoordinator
from azookey.reading_frontend import ReadingFrontend
from candidate_fixture import CallbackQueue, CandidateBridgeFixture, WAIT_SECONDS
from reading_coordinator_fixture import ReadingBridgeFixture, event


class WidgetFailure(Exception):
    """Model toolkit exceptions outside OSError, RuntimeError, and ValueError."""


class ReadingFrontendLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.coordinators = []
        self.inputs = []
        self.panels = []
        self.notices = []
        self.replies = []

        def coordinator(*args, **kwargs):
            reader, converter = ReadingBridgeFixture(), CandidateBridgeFixture()
            self.reader, self.converter = reader, converter
            instance = ReadingCoordinator(
                *args, reader_factory=lambda: reader,
                candidate_factory=lambda: converter, **kwargs,
            )
            self.coordinators.append(instance)
            return instance

        self.frontend = ReadingFrontend(
            self.callbacks.dispatch, render_input=lambda snapshot: self.inputs.append(deepcopy(snapshot)),
            render_candidates=lambda snapshot, batch: self.panels.append((deepcopy(snapshot), deepcopy(batch))),
            notify=self.notices.append, coordinator_factory=coordinator,
        )
        self.frontend.focus_in({"leftContext": "", "rightContext": "", "privateInput": False})
        self.drain_until(lambda: self.frontend.reference is not None
                         and self.frontend.coordinator._candidate_settings is not None)

    def tearDown(self):
        self.frontend.close()
        for coordinator in self.coordinators:
            coordinator.close()
            for transport in (coordinator.transport, coordinator.candidates.transport):
                transport.worker.join(WAIT_SECONDS)
                self.assertFalse(transport.worker.is_alive())

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("formal lifecycle operation did not finish")

    def key(self, text="", *, code=0, token=None):
        self.frontend.key(event(text, code), lambda consumed: self.replies.append((token or text, consumed)))

    def wait_reply(self, token):
        self.drain_until(lambda: (token, True) in self.replies)

    @property
    def commits(self):
        return [text for snapshot in self.inputs for text in snapshot.get("commits", [])]

    @staticmethod
    def fail_widget(*_arguments):
        raise WidgetFailure("injected external callback failure")

    def test_commit_then_widget_failure_finishes_queued_keys_without_replay_and_can_restart(self):
        self.key("a")
        self.wait_reply("a")
        render = self.frontend.render_input

        def commit_then_fail(snapshot):
            render(snapshot)
            if snapshot.get("commits"):
                self.fail_widget()

        self.frontend.render_input = commit_then_fail
        self.key(code=36, token="enter")
        self.key("retired")
        self.wait_reply("retired")
        self.assertEqual(self.commits, ["a"])
        self.assertEqual(self.replies, [("a", True), ("enter", True), ("retired", True)])
        self.assertEqual([(notice.code, notice.phase) for notice in self.notices], [
            ("reading_input_application_failed", "application-unknown"),
            ("reading_input_application_failed", "not-sent"),
        ])
        self.assertEqual(self.frontend.pending, set())
        self.assertTrue(self.frontend.blocked)
        self.frontend.render_input = render
        self.frontend.reset()
        self.drain_until(lambda: self.frontend.reference is not None)
        self.key("b")
        self.wait_reply("b")
        self.key(code=36, token="new-enter")
        self.wait_reply("new-enter")
        self.assertEqual(self.commits, ["a", "b"])
        self.assertFalse(self.frontend.blocked)

    def test_input_and_error_notification_failures_still_finish_each_original_once(self):
        self.frontend.render_input = self.fail_widget
        self.frontend.coordinator.notify = self.fail_widget
        self.key("first")
        self.key("queued")
        with self.assertLogs("azookey.reading_coordinator", level="ERROR"):
            self.wait_reply("queued")
        self.assertEqual(self.replies, [("first", True), ("queued", True)])
        self.assertEqual(self.frontend.pending, set())
        self.frontend.close()
        self.assertEqual(self.replies, [("first", True), ("queued", True)])

    def test_candidate_only_widget_failure_retains_batch_and_allows_the_next_key(self):
        self.key("a")
        self.wait_reply("a")
        render = self.frontend.render_candidates

        def fail_arrival(snapshot, view):
            if view is not None:
                self.fail_widget()
            render(snapshot, view)

        self.frontend.render_candidates = fail_arrival
        self.key(code=49, token="request")
        self.drain_until(lambda: self.notices)
        state = self.frontend.coordinator._contexts[self.frontend.context]
        self.assertIsNotNone(state.batch)
        self.assertIn(state.batch["batchID"], self.converter.retained)
        self.assertFalse(state.batch_visible)
        self.assertFalse(self.frontend.blocked)
        self.assertEqual(len(self.inputs), 2)
        self.assertEqual(self.frontend.snapshot["preedit"], "a")
        self.assertEqual(self.replies, [("a", True), ("request", True)])
        self.assertEqual([notice.code for notice in self.notices], ["reading_candidate_display_failed"])
        self.frontend.render_candidates = render
        self.key("b")
        self.wait_reply("b")
        self.assertEqual(self.frontend.snapshot["preedit"], "ab")
        self.assertEqual(self.frontend.pending, set())

    def test_candidate_display_and_notice_failures_do_not_hold_the_next_input(self):
        self.key("a")
        self.wait_reply("a")
        self.frontend.coordinator.publish_candidates = self.fail_widget
        self.frontend.coordinator.notify = self.fail_widget
        self.key(code=49, token="request")
        with self.assertLogs("azookey.reading_coordinator", level="ERROR"):
            self.drain_until(lambda: self.frontend.coordinator._contexts[self.frontend.context].batch is not None)
        self.key("b")
        self.wait_reply("b")
        self.assertEqual(self.frontend.snapshot["preedit"], "ab")
        self.assertEqual(self.replies, [("a", True), ("request", True), ("b", True)])
        self.assertFalse(self.frontend.blocked)

    def test_reply_then_callback_and_notice_failures_do_not_retry_or_strand_queued_input(self):
        def reply_then_fail(consumed):
            self.replies.append(("first", consumed))
            self.fail_widget()

        self.frontend.coordinator.notify = self.fail_widget
        self.frontend.key(event("a"), reply_then_fail)
        self.key("b")
        with self.assertLogs("azookey.reading_coordinator", level="ERROR"):
            self.wait_reply("b")
        self.assertEqual(self.replies, [("first", True), ("b", True)])
        self.assertEqual(self.frontend.pending, set())
        self.assertEqual(self.frontend.snapshot["preedit"], "ab")
        self.frontend.close()
        self.assertEqual(self.replies, [("first", True), ("b", True)])

    def test_control_and_notice_failures_do_not_strand_the_following_focus_and_key(self):
        coordinator = self.frontend.coordinator
        self.frontend.focus_out()
        coordinator.open_context("auxiliary", self.fail_widget)
        coordinator.notify = self.fail_widget
        self.frontend.focus_in({"leftContext": "next", "rightContext": "", "privateInput": False})
        self.key("b")
        with self.assertLogs("azookey.reading_coordinator", level="ERROR"):
            self.wait_reply("b")
        self.assertEqual(self.replies, [("b", True)])
        self.assertEqual(self.frontend.snapshot["preedit"], "b")
        self.assertEqual(self.frontend.pending, set())
        self.assertIsNone(coordinator._active)

    def test_candidate_failure_after_focus_reentry_cannot_restore_the_retired_view(self):
        self.key("a")
        self.wait_reply("a")
        render = self.frontend.render_candidates

        def move_then_fail(snapshot, view):
            render(snapshot, view)
            if view is not None:
                self.frontend.render_candidates = render
                self.frontend.focus_out()
                self.frontend.focus_in({"leftContext": "new", "rightContext": "", "privateInput": True})
                self.key("b")
                self.fail_widget()

        self.frontend.render_candidates = move_then_fail
        self.key(code=49, token="request")
        self.wait_reply("b")
        self.assertEqual(self.replies, [("a", True), ("request", True), ("b", True)])
        self.assertEqual(self.frontend.snapshot["preedit"], "b")
        self.assertIsNone(self.frontend.batch)
        self.assertIsNone(self.frontend.candidate_view)
        self.assertEqual(self.commits, [])
        self.assertEqual(self.frontend.pending, set())

    @staticmethod
    def fail_view(*_arguments):
        raise RuntimeError("injected view failure")

    def assert_cancel_survives_failed_view(self, operation, failed_view, *, fail_notice=False):
        self.key("shown")
        self.drain_until(lambda: ("shown", True) in self.replies)
        gate = self.reader.gate("key")
        self.key("cancelled")
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        original_view = getattr(self.frontend, failed_view)
        setattr(self.frontend, failed_view, self.fail_view)
        if fail_notice:
            self.frontend.notify = self.fail_view
        with self.assertLogs("azookey.reading_frontend", level="ERROR"):
            (self.frontend.focus_out if operation == "focus-out" else self.frontend.reset)()
        self.assertEqual(self.replies.count(("cancelled", True)), 1)
        self.assertTrue(any(item.operation == operation for item in self.frontend.coordinator._pending))
        self.assertFalse(self.frontend.blocked)
        setattr(self.frontend, failed_view, original_view)
        if operation == "focus-out":
            self.frontend.focus_in({"leftContext": "next", "rightContext": "", "privateInput": True})
        gate.proceed.set()
        self.drain_until(lambda: not self.frontend.pending and self.frontend.reference is not None)
        self.assertTrue(any(name == operation and not payload["submit"] for name, payload in self.reader.calls))
        self.assertEqual(self.replies.count(("cancelled", True)), 1)
        self.assertFalse(any(snapshot.get("commits") for snapshot in self.inputs))
        self.key("next")
        self.drain_until(lambda: ("next", True) in self.replies)
        self.assertEqual(self.inputs[-1]["preedit"], "next")
        self.assertFalse(self.frontend.blocked)

    def test_focus_out_still_cancels_and_allows_the_next_field_when_candidates_cannot_clear(self):
        self.assert_cancel_survives_failed_view("focus-out", "render_candidates")

    def test_reset_still_cancels_and_allows_new_input_when_preedit_cannot_clear(self):
        self.assert_cancel_survives_failed_view("reset", "render_input")

    def test_reset_still_cancels_and_allows_new_input_when_candidates_cannot_clear(self):
        self.assert_cancel_survives_failed_view("reset", "render_candidates")

    def test_failed_error_notification_does_not_hold_the_original_cancelled_reply(self):
        self.assert_cancel_survives_failed_view("focus-out", "render_candidates", fail_notice=True)


if __name__ == "__main__":
    unittest.main()
