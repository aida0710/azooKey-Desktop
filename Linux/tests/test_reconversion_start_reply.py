"""Reply to the initiating key after deletion is sent, before its client ACK."""
import pathlib
import sys
from types import MethodType, SimpleNamespace
import unittest
from unittest.mock import Mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from azookey.reconversion import surrounding_context
from reconversion_fixture import ReconversionFixture


CONTROL_SHIFT = 5
RELEASE = 1 << 30
RECONVERT = (ord("R"), 27, CONTROL_SHIFT)
UNDO_COMMIT = (0xFF08, 14, CONTROL_SHIFT)
LETTER = (ord("a"), 38, 0)


class ReconversionStartReplyTests(ReconversionFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.coordinator.replay = self.replay_native

    def send_key(self, key, *, after_reply=None):
        def complete(consumed):
            self.effects.append(("reply", key, consumed))
            if after_reply:
                after_reply(consumed)

        reply = NativeKeyReply(complete)
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

    def begin_in_another_context(self):
        self.coordinator.cancel()
        self.inputs.cancel()
        self.document = surrounding_context(
            "別日本語後", 4, 1, can_replace=True, sensitive=False,
        )
        self.new_request_index = len(self.worker.requests)
        self.new_reply = self.send_key(RECONVERT)

    def assert_new_start_waits_for_its_own_plan(self):
        self.assertEqual(self.coordinator.phase, "requesting")
        request = self.worker.requests[self.new_request_index]
        self.assertEqual(request.operation, "reconvert")
        self.assertFalse(request.cancelled.is_set())
        self.assertFalse(self.new_reply.completed)
        self.worker.respond(self.new_request_index, {"reconversion": self.plan})
        self.assertTrue(self.new_reply.completed)
        self.assertEqual(self.replies()[-1], ("reply", RECONVERT, True))
        self.assert_no_forward()

    def test_start_reply_follows_delete_and_unblocks_ack_before_later_keys(self):
        for start_key in (RECONVERT, UNDO_COMMIT):
            with self.subTest(start_key=start_key):
                self.setUp()

                def acknowledge_after_reply(consumed):
                    self.assertTrue(consumed)
                    self.assertEqual(self.coordinator.phase, "deleting")
                    self.assertEqual(
                        [effect for effect in self.effects if effect[0] == "delete"],
                        [("delete", -3, 3)],
                    )
                    self.effects.append(("client-ack",))
                    self.acknowledge()

                start_reply = self.send_key(start_key, after_reply=acknowledge_after_reply)
                release_key = (*start_key[:2], start_key[2] | RELEASE)
                later_replies = [self.send_key(release_key), self.send_key(LETTER)]
                self.assertEqual(self.replies(), [])
                self.worker.respond(0, {"reconversion": self.plan})
                self.assertEqual(self.replies(), [("reply", start_key, True)])
                self.assertLess(self.effects.index(("delete", -3, 3)),
                                self.effects.index(("reply", start_key, True)))
                self.assertLess(self.effects.index(("reply", start_key, True)),
                                self.effects.index(("client-ack",)))
                self.assertEqual(self.worker.requests[1].operation, "confirm-reconversion")
                self.worker.respond(1, {
                    "preedit": "日本語", "reading": "にほんご", "inputState": "selecting",
                })
                self.assertEqual(self.replies(), [
                    ("reply", start_key, True), ("reply", release_key, False),
                ])
                self.worker.respond(2, {"preedit": "日本語あ", "consumed": True})
                self.assertEqual(self.replies()[-1], ("reply", LETTER, True))
                for reply in (start_reply, *later_replies):
                    reply.finish(False)
                self.assertEqual(len(self.replies()), 3)
                self.assert_no_forward()

    def test_reading_noop_and_errors_finish_start_once_without_deletion(self):
        snapshots = (
            {"reconversionReading": ""}, {},
            {"reconversionError": "replacement_unavailable"},
            {"error": "invalid_request"}, {"reconversion": {"text": "不正"}},
        )
        for snapshot in snapshots:
            with self.subTest(snapshot=snapshot):
                self.setUp()
                reply = self.send_key(RECONVERT)
                self.assertEqual(self.replies(), [])
                self.worker.respond(0, snapshot)
                self.assertEqual(self.replies(), [("reply", RECONVERT, True)])
                self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
                self.coordinator.cancel()
                self.inputs.cancel()
                reply.finish(False)
                self.assertEqual(self.replies(), [("reply", RECONVERT, True)])

    def test_reading_enter_reply_follows_delete_before_its_release_can_block_the_ack(self):
        self.send_key(RECONVERT)
        self.worker.respond(0, {"reconversionReading": "にほんご"})
        enter = (0xFF0D, 36, 0)
        release = (*enter[:2], RELEASE)

        def acknowledge_after_reply(consumed):
            self.assertTrue(consumed)
            self.assertIn(("delete", -3, 3), self.effects)
            self.acknowledge()

        self.effects.clear()
        enter_reply = self.send_key(enter, after_reply=acknowledge_after_reply)
        self.assertFalse(enter_reply.completed)
        self.send_key(release)
        self.assertEqual(self.replies(), [])
        self.worker.respond(1, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [("reply", enter, True)])
        self.assertEqual(self.worker.requests[2].operation, "confirm-reconversion")
        self.worker.respond(2, {"preedit": "日本語", "inputState": "selecting"})
        self.assertEqual(self.replies(), [("reply", enter, True), ("reply", release, False)])
        self.assert_no_forward()

    def test_reading_completion_keeps_each_key_reply_with_its_own_request(self):
        next_letter = (ord("b"), 56, 0)
        escape = (0xFF1B, 9, 0)
        cases = (
            (LETTER, {"reconversionReading": "あ"}, next_letter, {"reconversionReading": "あb"}),
            (escape, {}, RECONVERT, {"reconversion": self.plan}),
        )
        for first_key, first_snapshot, next_key, next_snapshot in cases:
            with self.subTest(first_key=first_key):
                self.setUp()
                self.send_key(RECONVERT)
                self.worker.respond(0, {"reconversionReading": ""})
                next_reply = None

                def status_and_send_next(text):
                    nonlocal next_reply
                    self.effects.append(("status", text))
                    self.coordinator.status = lambda text: self.effects.append(("status", text))
                    next_reply = self.send_key(next_key)

                self.coordinator.status = status_and_send_next
                first_reply = self.send_key(first_key)
                self.worker.respond(1, first_snapshot)
                self.assertIsNotNone(next_reply)
                self.assertTrue(first_reply.completed)
                self.assertFalse(next_reply.completed)
                self.assertEqual(self.replies(), [
                    ("reply", RECONVERT, True), ("reply", first_key, True),
                ])
                self.worker.respond(2, next_snapshot)
                self.assertTrue(next_reply.completed)
                first_reply.finish(False)
                next_reply.finish(False)
                self.assertEqual(self.replies(), [
                    ("reply", RECONVERT, True), ("reply", first_key, True),
                    ("reply", next_key, True),
                ])
                self.assert_no_forward()

    def test_transport_timeout_and_generation_change_finish_start_without_old_deletion(self):
        for failure in ("transport", "timeout", "generation"):
            with self.subTest(failure=failure):
                self.setUp()
                reply = self.send_key(UNDO_COMMIT)
                if failure == "timeout":
                    self.inputs._progress_expired()
                else:
                    self.worker.respond(
                        0, {"reconversion": self.plan},
                        failed=failure == "transport", generation=int(failure == "generation"),
                    )
                self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
                reply.finish(False)
                self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
                self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
                self.assert_no_forward()

    def test_unavailable_or_composing_target_finishes_start_without_a_request(self):
        for reason in ("absent", "sensitive", "readonly", "composition"):
            with self.subTest(reason=reason):
                self.setUp()
                if reason == "absent":
                    self.document = None
                elif reason == "sensitive":
                    self.document["isSensitive"] = True
                elif reason == "readonly":
                    self.document["canReplace"] = False
                else:
                    self.inputs.snapshot = {"preedit": "入力中"}
                reply = self.send_key(RECONVERT)
                self.assertFalse(reply.deferred)
                self.assertEqual(self.replies(), [("reply", RECONVERT, True)])
                self.assertEqual(self.worker.requests, [])

    def test_cancel_and_late_plan_never_repeat_start_or_delete(self):
        reply = self.send_key(UNDO_COMMIT)
        self.coordinator.cancel()
        self.inputs.cancel()
        self.worker.respond(0, {"reconversion": self.plan})
        self.coordinator.cancel()
        reply.finish(False)
        self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.assert_no_forward()

    def test_changed_document_before_the_plan_consumes_start_without_deleting(self):
        self.send_key(RECONVERT)
        self.document = surrounding_context(
            "別の文書", 0, 0, can_replace=True, sensitive=False,
        )
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [("reply", RECONVERT, True)])
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))

    def test_start_reply_refocus_during_failure_does_not_cancel_the_new_request(self):
        self.send_key(UNDO_COMMIT, after_reply=lambda _consumed: self.begin_in_another_context())
        release_key = (*UNDO_COMMIT[:2], CONTROL_SHIFT | RELEASE)
        self.send_key(release_key)
        self.worker.respond(0, {"reconversionError": "replacement_unavailable"})
        self.assertEqual(self.replies(), [
            ("reply", UNDO_COMMIT, True), ("reply", release_key, True),
        ])
        self.assert_new_start_waits_for_its_own_plan()

    def test_cancel_during_delete_does_not_finish_a_new_context_start(self):
        def delete_and_change_context(offset, count):
            self.effects.append(("delete", offset, count))
            self.begin_in_another_context()

        self.coordinator.delete = delete_and_change_context
        self.send_key(UNDO_COMMIT)
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
        self.coordinator.delete = lambda offset, count: self.effects.append(("delete", offset, count))
        self.assert_new_start_waits_for_its_own_plan()

    def test_status_refocus_on_reading_or_noop_leaves_the_new_start_pending(self):
        for snapshot in ({"reconversionReading": ""}, {}):
            with self.subTest(snapshot=snapshot):
                self.setUp()
                self.send_key(UNDO_COMMIT)
                self.coordinator.status = lambda _text: self.begin_in_another_context()
                self.worker.respond(0, snapshot)
                self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
                self.coordinator.status = lambda text: self.effects.append(("status", text))
                self.assert_new_start_waits_for_its_own_plan()

    def test_start_reply_refocus_after_delete_keeps_the_next_context_independent(self):
        self.send_key(UNDO_COMMIT, after_reply=lambda _consumed: self.begin_in_another_context())
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertEqual(self.replies(), [("reply", UNDO_COMMIT, True)])
        self.assert_new_start_waits_for_its_own_plan()


class ReconversionStartEngineTests(ReconversionFixture, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import gi
            gi.require_version("Gdk", "3.0")
            gi.require_version("IBus", "1.0")
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        from azookey.engine import Engine
        from gi.repository import GLib
        cls.engine_type = Engine
        cls.variant_type = GLib.Variant

    def test_idle_reconversion_shortcuts_keep_the_original_invocation_until_delete(self):
        for start_key in (RECONVERT, UNDO_COMMIT):
            with self.subTest(start_key=start_key):
                self.setUp()
                connection = object()
                invocation = Mock()
                engine = SimpleNamespace(
                    native_key_reply=None, native_key_passthrough=False,
                    private=False, focused=True, input=self.inputs,
                    transformation=Mock(), ai_review=SimpleNamespace(
                        confirmation=None, key=lambda _event: False,
                    ),
                    reconversion=self.coordinator, get_connection=lambda: connection,
                )
                for name in ("do_process_key_event", "finish_native_key", "do_service_method_call"):
                    setattr(engine, name, MethodType(getattr(self.engine_type, name), engine))
                engine.emit = lambda _signal, *key: engine.do_process_key_event(*key)
                engine.do_service_method_call(
                    connection, ":1.100", "/org/freedesktop/IBus/Engine/1",
                    "org.freedesktop.IBus.Engine", "ProcessKeyEvent",
                    self.variant_type("(uuu)", start_key), invocation,
                )
                invocation.return_value.assert_not_called()
                self.assertIsNone(engine.native_key_reply)
                self.worker.respond(0, {"reconversion": self.plan})
                invocation.return_value.assert_called_once()
                self.assertEqual(invocation.return_value.call_args.args[0].unpack(), (True,))
                self.assertEqual(self.coordinator.phase, "deleting")
                self.assertEqual(
                    [effect for effect in self.effects if effect[0] == "delete"],
                    [("delete", -3, 3)],
                )


if __name__ == "__main__":
    unittest.main()
