"""Original key replies keep their order across reconversion's client ACK."""
import unittest
from unittest.mock import Mock

from reconversion_fixture import ReconversionFixture
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from azookey.reconversion import surrounding_context


CONTROL = 4
RELEASE = 1 << 30
ENTER = (0xFF0D, 36, 0)
HOME = (0xFF50, 102, CONTROL)
CONTROL_DOWN = (0xFFE3, 37, 0)
HOME_UP = (0xFF50, 102, CONTROL | RELEASE)
CONTROL_UP = (0xFFE3, 37, CONTROL | RELEASE)
LETTER = (ord("a"), 38, 0)
ORDERED_KEYS = (ENTER, CONTROL_DOWN, HOME, HOME_UP, CONTROL_UP, LETTER)


class ReconversionNativeReplyTests(ReconversionFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.coordinator.replay = self.replay_native

    def native_key(self, key):
        reply = NativeKeyReply(lambda consumed: self.effects.append(("reply", key, consumed)))
        self.dispatch(key, reply)
        return reply

    def dispatch(self, key, reply):
        event = translate(key[0], key[2])
        if not self.coordinator.process(event, key, key_reply=reply):
            self.inputs.submit(
                "key" if event is not None else None, payload={"event": event},
                key=key, key_reply=reply.defer(),
            )
        elif not reply.deferred:
            reply.finish(True)

    def replay_native(self, *key, key_reply=None):
        self.assertIsNotNone(key_reply)
        self.dispatch(key, NativeKeyReply(key_reply))

    def replies(self):
        return [effect for effect in self.effects if effect[0] == "reply"]

    def assert_no_forward(self):
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def reach_phase(self, phase):
        self.coordinator.start(undo=False)
        if phase in ("deleting", "confirming"):
            self.worker.respond(0, {"reconversion": self.plan})
        if phase == "confirming":
            self.acknowledge()

    def test_deletion_ack_and_commit_precede_original_shortcuts_and_releases(self):
        self.coordinator.start(undo=False)
        replies = [self.native_key(key) for key in ORDERED_KEYS]
        self.assertEqual(self.replies(), [])
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [])
        self.assertEqual([effect for effect in self.effects if effect[0] == "delete"], [("delete", -3, 3)])
        self.acknowledge()
        self.worker.respond(1, {"preedit": "日本語", "reading": "にほんご", "inputState": "selecting"})
        self.assertEqual(self.replies(), [])
        self.worker.respond(2, {"commits": ["日本語"], "preedit": "", "inputState": "none", "consumed": True})
        self.assertEqual(self.replies(), [
            ("reply", key, key == ENTER) for key in ORDERED_KEYS[:-1]
        ])
        self.assertLess(
            self.effects.index(("render", {"commits": ["日本語"], "preedit": "", "inputState": "none", "consumed": True})),
            self.effects.index(("reply", HOME, False)),
        )
        self.worker.respond(7, {"preedit": "あ", "inputState": "composing", "consumed": True})
        self.assertEqual(self.replies()[-1], ("reply", LETTER, True))
        for reply in replies:
            reply.finish(False)
        self.coordinator.cancel()
        self.inputs.cancel()
        self.assertEqual(len(self.replies()), len(ORDERED_KEYS))
        self.assert_no_forward()

    def test_focus_cancellation_completes_every_phase_once_without_native_edits(self):
        for phase in ("requesting", "deleting", "confirming"):
            with self.subTest(phase=phase):
                self.setUp()
                self.reach_phase(phase)
                replies = [self.native_key(key) for key in ORDERED_KEYS]
                self.coordinator.cancel()
                self.inputs.cancel()
                expected = [("reply", key, True) for key in ORDERED_KEYS]
                self.assertEqual(self.replies(), expected)
                old_effects = list(self.effects)
                self.worker.respond(0, {"reconversion": self.plan})
                self.worker.respond(0, failed=True)
                self.coordinator.cancel()
                for reply in replies:
                    reply.finish(False)
                self.assertEqual(self.effects, old_effects)
                self.assert_no_forward()

    def test_ignored_deletion_returns_original_keys_once_only_in_the_same_document(self):
        for changed in (False, True):
            with self.subTest(changed=changed):
                self.setUp()
                self.prepare()
                for key in ORDERED_KEYS:
                    self.native_key(key)
                if changed:
                    self.document = surrounding_context("別日本語後", 4, 1, can_replace=True, sensitive=False)
                self.timers.pop(1)()
                self.assertEqual(self.replies(), [("reply", key, changed) for key in ORDERED_KEYS])
                self.assertEqual(sum(effect[0] == "delete" for effect in self.effects), 1)
                self.assertFalse(any(effect[0] == "render" for effect in self.effects))
                self.assert_no_forward()

    def test_failure_recovers_original_before_keys_and_discards_them_in_a_changed_field(self):
        for changed in (False, True):
            for failure in ("transport", "timeout", "generation"):
                with self.subTest(changed=changed, failure=failure):
                    self.setUp()
                    self.reach_phase("confirming")
                    for key in ORDERED_KEYS:
                        self.native_key(key)
                    self.effects.clear()
                    if changed:
                        self.document = None
                    if failure == "timeout":
                        self.inputs._progress_expired()
                    else:
                        self.worker.respond(1, {"preedit": "古い候補"}, failed=failure == "transport",
                                            generation=int(failure == "generation"))
                    self.assertEqual(self.replies(), [("reply", key, changed) for key in ORDERED_KEYS])
                    recovered = [effect for effect in self.effects if effect[0] == "recover"]
                    self.assertEqual(recovered, [("recover", "" if changed else "日本語")])
                    if not changed:
                        self.assertLess(self.effects.index(recovered[0]), self.effects.index(self.replies()[0]))
                    self.assert_no_forward()

    def test_changed_target_before_a_reply_consumes_keys_without_deleting(self):
        self.coordinator.start(undo=False)
        self.native_key(HOME)
        self.document = surrounding_context("別日本語後", 4, 1, can_replace=True, sensitive=False)
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [("reply", HOME, True)])
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.assert_no_forward()

    def test_error_status_failure_still_completes_start_and_buffered_original_calls(self):
        start = (ord("r"), 27, CONTROL | 1)
        self.native_key(start)
        self.native_key(LETTER)
        self.coordinator.status = Mock(side_effect=OSError("synthetic status failure"))
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"reconversionError": "replacement_unavailable"})
        self.assertEqual(self.replies(), [("reply", start, True), ("reply", LETTER, False)])
        previous = list(self.replies())
        self.coordinator.cancel()
        self.inputs.cancel()
        self.assertEqual(self.replies(), previous)
        self.assertFalse(self.coordinator.active)
        self.assert_no_forward()

    def test_failed_retired_reply_never_strands_or_repeats_the_following_original_calls(self):
        start = (ord("r"), 27, CONTROL | 1)
        keys = (start, ENTER, LETTER)
        for failed_key in (start, ENTER):
            with self.subTest(failed_key=failed_key):
                self.setUp()
                replies = []
                for key in keys:
                    def complete(consumed, key=key):
                        self.effects.append(("reply", key, consumed))
                        if key == failed_key:
                            raise OSError("synthetic reply failure after delivery")
                    reply = NativeKeyReply(complete)
                    replies.append(reply)
                    self.dispatch(key, reply)
                with self.assertLogs("azookey.reconversion", level="ERROR"):
                    self.coordinator.cancel()
                self.coordinator.cancel()
                for reply in replies:
                    reply.finish(False)
                self.assertEqual(self.replies(), [("reply", key, True) for key in keys])
                self.assertFalse(self.coordinator.active)
                self.assert_no_forward()

    def test_focus_change_during_failed_error_status_does_not_deliver_keys_to_the_new_field(self):
        start = (ord("r"), 27, CONTROL | 1)
        self.native_key(start)
        self.native_key(LETTER)

        def changed_status(_text):
            self.document = None
            self.coordinator.cancel()
            raise OSError("synthetic status failure after focus change")

        self.coordinator.status = changed_status
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"reconversionError": "replacement_unavailable"})
        self.assertEqual(self.replies(), [("reply", start, True), ("reply", LETTER, True)])
        self.assert_no_forward()

    def test_reading_entry_keeps_queued_text_backspace_enter_and_modifiers_local(self):
        self.coordinator.start(undo=False)
        reading_keys = [(ord("n"), 57, 0), (ord("i"), 31, 0), (0xFF08, 22, 0), ENTER]
        for key in reading_keys:
            self.native_key(key)
        self.worker.respond(0, {"reconversionReading": ""})
        for index, reading in enumerate(("ん", "に", ""), start=1):
            self.assertEqual(self.worker.requests[index].operation, "reconversion-reading")
            self.worker.respond(index, {"reconversionReading": reading})
        self.assertEqual(self.replies(), [("reply", key, True) for key in reading_keys[:-1]])
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.worker.respond(4, {"reconversionReading": ""})
        self.assertEqual(self.replies(), [("reply", key, True) for key in reading_keys])
        for key in (CONTROL_DOWN, HOME, HOME_UP, CONTROL_UP):
            self.native_key(key)
            if self.coordinator.phase == "requesting":
                self.worker.respond(len(self.worker.requests) - 1, {"reconversionReading": ""})
        self.assertTrue(all(effect[2] for effect in self.replies()))
        self.assertEqual(self.document["selected"], "日本語")
        self.assert_no_forward()

    def test_canceling_reading_routes_later_keys_through_normal_input(self):
        self.coordinator.start(undo=False)
        self.worker.respond(0, {"reconversionReading": ""})
        escape = (0xFF1B, 9, 0)
        self.native_key(escape)
        self.native_key(LETTER)
        self.native_key(HOME)
        self.worker.respond(1, {})
        self.assertEqual(self.worker.requests[2].operation, "key")
        self.assertEqual(self.replies(), [("reply", escape, True)])
        self.worker.respond(2, {"commits": ["a"], "inputState": "none", "language": "english", "consumed": True})
        self.assertEqual(self.replies(), [
            ("reply", escape, True), ("reply", LETTER, True), ("reply", HOME, False),
        ])
        self.assert_no_forward()

    def test_status_focus_change_ends_drain_and_completes_remaining_calls(self):
        self.prepare()
        for key in ORDERED_KEYS:
            self.native_key(key)
        self.acknowledge()
        self.coordinator.status = lambda _text: self.coordinator.cancel()
        self.worker.respond(1, {"preedit": "日本語", "inputState": "selecting"})
        self.assertEqual(self.replies(), [("reply", key, True) for key in ORDERED_KEYS])
        self.assertEqual(len(self.worker.requests), 2)
        self.assert_no_forward()

    def test_focus_change_during_native_recovery_discards_the_rest(self):
        self.prepare()
        def complete_first(consumed):
            self.effects.append(("reply", HOME, consumed))
            self.coordinator.cancel()
        first = NativeKeyReply(complete_first)
        self.dispatch(HOME, first)
        self.native_key(LETTER)
        self.timers.pop(1)()
        self.assertEqual(self.replies(), [("reply", HOME, False), ("reply", LETTER, True)])
        self.assert_no_forward()

    def test_focus_change_after_transfer_completes_calls_in_the_input_owner_once(self):
        self.reach_phase("confirming")
        replies = [self.native_key(key) for key in ORDERED_KEYS]
        self.worker.respond(1, {"preedit": "日本語", "inputState": "selecting"})
        self.assertFalse(self.coordinator.queued)
        self.assertTrue(self.inputs.pending)
        self.coordinator.cancel()
        self.inputs.cancel()
        self.worker.respond(2, {"commits": ["古い候補"], "consumed": True})
        for reply in replies:
            reply.finish(False)
        self.assertEqual(self.replies(), [("reply", key, True) for key in ORDERED_KEYS])
        self.assert_no_forward()

    def test_failure_during_transfer_returns_input_keys_before_later_reconversion_keys(self):
        self.reach_phase("confirming")
        for key in ORDERED_KEYS:
            self.native_key(key)
        replay = self.coordinator.replay
        def fail_second_key(*key, key_reply=None):
            if key == CONTROL_DOWN:
                self.inputs.recover_pending(key=key, key_reply=key_reply)
            else:
                replay(*key, key_reply=key_reply)
        self.coordinator.replay = fail_second_key
        self.worker.respond(1, {"preedit": "日本語", "inputState": "selecting"})
        self.assertEqual(self.replies(), [("reply", key, False) for key in ORDERED_KEYS])
        recovered = [effect for effect in self.effects if effect[0] == "recover"]
        self.assertEqual(recovered, [("recover", "日本語")])
        self.assertLess(self.effects.index(recovered[0]), self.effects.index(self.replies()[0]))
        self.assert_no_forward()

    def test_focus_change_while_returning_transferred_keys_consumes_the_remaining_calls(self):
        self.reach_phase("confirming")
        def complete_first(consumed):
            self.effects.append(("reply", ENTER, consumed))
            self.coordinator.cancel()
            self.inputs.cancel()
        self.dispatch(ENTER, NativeKeyReply(complete_first))
        for key in ORDERED_KEYS[1:]:
            self.native_key(key)
        self.worker.respond(1, {"preedit": "日本語", "inputState": "selecting"})
        self.worker.respond(2, failed=True)
        self.assertEqual(self.replies(), [
            ("reply", ENTER, False), *[("reply", key, True) for key in ORDERED_KEYS[1:]],
        ])
        self.assert_no_forward()


if __name__ == "__main__":
    unittest.main()
