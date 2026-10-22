"""A completed start press permits client post-processing without overtaking held input."""
from types import MethodType
import unittest

from azookey.native_key_reply import NativeKeyReply
from candidate_fixture import WAIT_SECONDS
from test_reading_frontend import reading_snapshot
import test_reading_reconversion as reconversion_tests
import test_reading_reconversion_adapter as adapter_tests


RELEASE = 1 << 30
START = reconversion_tests.START
START_UP = (START[0], START[1], START[2] | RELEASE)
SHIFT_UP = (0xFFE1, 50, 5 | RELEASE)
CONTROL_DOWN = (0xFFE3, 37, 0)
CONTROL_UP = (0xFFE3, 37, 4 | RELEASE)
ENTER = reconversion_tests.ENTER
ENTER_UP = (ENTER[0], ENTER[1], RELEASE)


@unittest.skipIf(adapter_tests.ReadingEngine is None, "requires the IBus and GTK Python bindings")
class ReadingReconversionReleaseTests(unittest.TestCase):
    def setUp(self):
        self.trial = reconversion_tests.ReadingReconversionTests(
            "test_each_key_retains_the_same_document_context_for_the_short_commit_history")
        self.trial.setUp()
        self.addCleanup(self.trial.doCleanups)
        self.engine = adapter_tests.ObservedInputField(self.trial)
        self.engine.native_key_passthrough = False
        self.engine.native_key_reply = None
        self.engine.renderer.suspend = lambda: None
        self.engine.do_process_key_event = MethodType(adapter_tests.ReadingEngine.do_process_key_event, self.engine)
        self.adapter = adapter_tests.ReadingReconversionAdapter(
            self.engine, schedule_timeout=self.trial.schedule, remove_timeout=self.trial.timers.pop,
        )
        self.engine.reconversion = self.adapter
        self.adapter.document = self.trial.document
        self.trial.reconversion = self.adapter.coordinator
        self.trial.inputs = self.adapter.input

    def native(self, key):
        reply = NativeKeyReply(lambda consumed: self.trial.effects.append(("reply", key, consumed)))
        self.engine.native_key_reply = reply
        try:
            consumed = self.engine.do_process_key_event(*key)
            if not reply.deferred:
                reply.finish(consumed)
        finally:
            self.engine.native_key_reply = None
        return reply

    def replies(self):
        return [row for row in self.trial.effects if row[0] == "reply"]

    def begin_deletion(self):
        self.trial.reader.reconversion_replies["resolve-reconversion"].append({"reconversion": self.trial.plan})
        start = self.native(START)
        self.trial.drain_until(lambda: self.adapter.coordinator.phase == "deleting")
        self.assertTrue(start.completed)
        self.assertEqual(self.replies(), [("reply", START, True)])

    def confirm_later(self):
        gate = self.trial.reader.gate("confirm-reconversion")
        self.trial.reader.reconversion_replies["confirm-reconversion"].append(
            {"kind": "input", "snapshot": reading_snapshot("にほんご")})
        self.adapter.surrounding_changed("前後", 1, 1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        return gate

    def finish_confirmation(self, gate):
        gate.proceed.set()
        self.trial.drain_until(lambda: not self.engine.frontend.pending and not self.adapter.active)

    def test_release_flushes_original_recovery_while_formal_confirmation_is_pending(self):
        self.begin_deletion()
        gate = self.confirm_later()
        before = list(self.trial.reader.calls)
        releases = [self.native(key) for key in (START_UP, SHIFT_UP, CONTROL_UP)]
        self.assertTrue(all(reply.completed for reply in releases))
        self.assertEqual(self.replies(), [("reply", START, True), *[
            ("reply", key, False) for key in (START_UP, SHIFT_UP, CONTROL_UP)]])
        self.assertEqual(self.trial.reader.calls, before)
        self.assertIn(("recovery-preedit", "日本語"), self.trial.effects)
        self.assertFalse(any(row[0] == "input" for row in self.trial.effects))
        self.assertEqual([owner.operation for owner in self.engine.frontend.pending], ["confirm-reconversion"])
        self.finish_confirmation(gate)
        for reply in releases:
            reply.finish(True)
        self.assertEqual(len(self.replies()), 4)
        self.assertFalse(any(row[0] == "forward" for row in self.trial.effects))

    def test_release_after_start_reply_does_not_wait_for_the_clients_deletion_ack(self):
        self.begin_deletion()
        released = self.native(START_UP)
        self.assertTrue(released.completed)
        self.assertEqual(self.replies()[-1], ("reply", START_UP, False))
        self.assertEqual(self.adapter.coordinator.phase, "deleting")
        self.assertFalse(any(operation == "confirm-reconversion" for operation, _ in self.trial.reader.calls))
        self.assertFalse(any(row[0] in ("input", "recovery-preedit") for row in self.trial.effects))
        self.finish_confirmation(self.confirm_later())

    def test_release_cannot_overtake_a_start_press_still_waiting_for_its_plan(self):
        gate = self.trial.candidate.gate("resolve-reconversion-reading")
        self.trial.reader.reconversion_replies["resolve-reconversion"].append({"reconversion": self.trial.plan})
        start = self.native(START)
        self.trial.drain_until(lambda: not self.trial.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        released = self.native(START_UP)
        self.assertFalse(start.completed or released.completed)
        gate.proceed.set()
        self.trial.drain_until(lambda: self.adapter.coordinator.phase == "deleting")
        self.assertTrue(start.completed)
        self.assertFalse(released.completed)
        self.finish_confirmation(self.confirm_later())
        self.assertEqual(self.replies(), [("reply", START, True), ("reply", START_UP, False)])

    def test_queued_enter_and_modifier_press_keep_their_releases_in_original_order(self):
        self.begin_deletion()
        gate = self.confirm_later()
        keys = (ENTER, ENTER_UP, CONTROL_DOWN, CONTROL_UP)
        replies = [self.native(key) for key in keys]
        self.assertTrue(all(not reply.completed for reply in replies))
        self.finish_confirmation(gate)
        self.assertEqual(self.replies(), [("reply", START, True), *[
            ("reply", key, key == ENTER) for key in keys]])
        self.assertFalse(any(row[0] == "forward" for row in self.trial.effects))

    def test_normal_reading_reply_still_precedes_its_native_release(self):
        gate = self.trial.reader.gate("key")
        letter, release = (ord("a"), 38, 0), (ord("a"), 38, RELEASE)
        pressed = self.native(letter)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        released = self.native(release)
        self.assertFalse(pressed.completed or released.completed)
        gate.proceed.set()
        self.trial.drain_until(lambda: released.completed)
        self.assertEqual(self.replies(), [("reply", letter, True), ("reply", release, False)])

    def test_pending_frontend_native_reply_still_precedes_a_reconversion_release(self):
        self.begin_deletion()
        gate = self.confirm_later()
        barrier = NativeKeyReply(lambda consumed: self.trial.effects.append(("reply", CONTROL_DOWN, consumed)))
        self.engine.frontend.barrier(barrier.defer())
        released = self.native(START_UP)
        self.assertFalse(barrier.completed or released.completed)
        self.finish_confirmation(gate)
        self.assertEqual(self.replies(), [
            ("reply", START, True), ("reply", CONTROL_DOWN, False), ("reply", START_UP, False),
        ])

    def test_changed_document_retires_confirmation_without_repeating_a_finished_release(self):
        self.begin_deletion()
        gate = self.confirm_later()
        released = self.native(START_UP)
        self.assertTrue(released.completed)
        self.adapter.surrounding_changed("前変更後", 3, 3)
        gate.proceed.set()
        self.trial.drain_until(lambda: not self.engine.frontend.pending)
        released.finish(True)
        self.assertEqual(self.replies(), [("reply", START, True), ("reply", START_UP, False)])
        snapshots = [row[1] for row in self.trial.effects if row[0] == "input"]
        self.assertTrue(snapshots)
        # Cancellation can clear the recovery view; no late formal reading or
        # commit may replace text in the document that has changed meanwhile.
        self.assertTrue(all(value["preedit"] == "" and value["commits"] == [] for value in snapshots))
        self.assertFalse(any(row[0] in ("commit", "forward") for row in self.trial.effects))

    def test_focus_departure_cannot_replay_a_release_or_publish_the_old_confirmation(self):
        self.begin_deletion()
        gate = self.confirm_later()
        released = self.native(START_UP)
        self.assertTrue(released.completed)
        self.engine.do_focus_out()
        gate.proceed.set()
        self.trial.drain_until(lambda: not self.engine.frontend.pending)
        released.finish(True)
        self.assertEqual(self.replies(), [("reply", START, True), ("reply", START_UP, False)])
        self.assertFalse(any(row[0] in ("input", "commit", "forward") for row in self.trial.effects))

    def test_local_reading_prompt_keeps_its_existing_key_release_contract(self):
        self.trial.candidate.resolved_reading = None
        self.trial.reader.reconversion_replies["resolve-reconversion"].append({"reconversionReading": ""})
        self.native(START)
        self.trial.drain_until(lambda: self.adapter.coordinator.phase == "reading")
        release = self.native(START_UP)
        self.assertTrue(release.completed)
        self.assertEqual(self.replies(), [("reply", START, True), ("reply", START_UP, True)])
        self.assertFalse(any(row[0] in ("input", "delete", "commit") for row in self.trial.effects))


if __name__ == "__main__":
    unittest.main()
