"""A failed view must not prevent formal cancellation or retire the next field."""
from copy import deepcopy
import unittest

from azookey.reading_coordinator import ReadingCoordinator
from azookey.reading_frontend import ReadingFrontend
from candidate_fixture import CallbackQueue, CandidateBridgeFixture, WAIT_SECONDS
from reading_coordinator_fixture import ReadingBridgeFixture, event


class ReadingFrontendLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.reader = ReadingBridgeFixture()
        self.converter = CandidateBridgeFixture()
        self.inputs = []
        self.panels = []
        self.notices = []
        self.replies = []

        def coordinator(*args, **kwargs):
            return ReadingCoordinator(
                *args, reader_factory=lambda: self.reader,
                candidate_factory=lambda: self.converter, **kwargs,
            )

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
        coordinator = self.frontend.coordinator
        for transport in (coordinator.transport, coordinator.candidates.transport):
            transport.worker.join(WAIT_SECONDS)
            self.assertFalse(transport.worker.is_alive())

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("formal lifecycle operation did not finish")

    def key(self, text):
        self.frontend.key(event(text), lambda consumed: self.replies.append((text, consumed)))

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
