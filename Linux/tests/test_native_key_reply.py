import pathlib
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.async_bridge import Reply
from azookey.input_coordinator import InputCoordinator
from azookey.input_preview import is_native_key
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply


# F9 and F10 can commit either all input or only the selected segment.
ROMAN_CONVERSION_KEYS = (0xFFC6, 0xFFC7)


class ManualWorker:
    def __init__(self):
        self.requests = []

    def submit(self, request):
        self.requests.append(request)

    def respond(self, index, snapshot, *, failed=False):
        self.requests[index].complete(Reply(snapshot, 0, failed))


class NativeKeyReplyTests(unittest.TestCase):
    def setUp(self):
        self.effects = []
        self.previews = []
        self.worker = ManualWorker()
        self.input = InputCoordinator(
            self.worker, "original", render=lambda value: self.effects.append(("render", value)),
            forward=lambda *key: self.effects.append(("forward", key)),
            recover=lambda text: self.effects.append(("recover", text)),
            preview=lambda text, cursor: self.previews.append((text, cursor)),
        )

    def key(self, keyval, state=0, *, deferred=False):
        reply = NativeKeyReply(lambda consumed: self.effects.append(("reply", keyval, consumed)))
        self.input.submit("key", payload={"event": translate(keyval, state)},
                          key=(keyval, 38, state), key_reply=reply.defer() if deferred else None)
        return reply

    def test_idle_shortcuts_keep_original_native_events_but_ime_shortcuts_do_not(self):
        idle = {"inputState": "none", "language": "english"}
        for key, state in [(0xFF50, 4), (0xFF57, 4), (ord("A"), 1), (0xFF51, 1)]:
            self.assertTrue(is_native_key(translate(key, state), idle))
        for key, state in [(ord("s"), 4), (ord("U"), 5), (ord("\\"), 0)]:
            self.assertFalse(is_native_key(translate(key, state), idle))
        composing = {**idle, "inputState": "composing", "preedit": "にほんご"}
        self.assertFalse(is_native_key(translate(0xFF50, 4), composing))
        self.assertFalse(is_native_key(translate(ord("h"), 4), composing))

    def test_enter_then_native_shortcut_waits_for_commit_and_replies_once(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "にほんご"}
        self.key(0xFF0D)
        self.assertTrue(self.input.pending_native_key(translate(0xFF50, 4)))
        reply = self.key(0xFF50, 4, deferred=True)
        self.assertEqual(self.effects, [])
        self.worker.respond(0, {"inputState": "none", "preedit": "", "commits": ["にほんご"], "consumed": True})
        self.assertEqual([effect[0] for effect in self.effects], ["render", "reply"])
        self.assertEqual(self.effects[-1], ("reply", 0xFF50, False))
        reply.finish(False)
        self.input.cancel()
        self.assertEqual(len(self.effects), 2)

    def test_roman_conversion_returns_the_original_home_only_after_the_full_commit(self):
        for keyval in ROMAN_CONVERSION_KEYS:
            with self.subTest(keyval=keyval):
                self.setUp()
                self.input.snapshot = {"inputState": "selecting", "preedit": "日本語"}
                self.key(keyval)
                self.assertTrue(self.input.pending_native_key(translate(0xFF50, 4)))
                reply = self.key(0xFF50, 4, deferred=True)
                self.assertEqual(self.effects, [])
                self.worker.respond(0, {
                    "inputState": "none", "preedit": "", "commits": ["nihongo"], "consumed": True,
                })
                self.assertEqual([effect[0] for effect in self.effects], ["render", "reply"])
                self.assertEqual(self.effects[-1], ("reply", 0xFF50, False))
                reply.finish(False)
                self.assertEqual(len(self.effects), 2)

    def test_partial_roman_conversion_keeps_home_in_core_until_its_actual_reply(self):
        for keyval in ROMAN_CONVERSION_KEYS:
            with self.subTest(keyval=keyval):
                self.setUp()
                self.input.snapshot = {"inputState": "selecting", "preedit": "日本語です"}
                self.key(keyval)
                self.assertTrue(self.input.pending_native_key(translate(0xFF50, 4)))
                self.key(0xFF50, 4, deferred=True)
                self.worker.respond(0, {
                    "inputState": "composing", "preedit": "です", "commits": ["nihongo"], "consumed": True,
                })
                self.assertEqual([effect[0] for effect in self.effects], ["render"])
                self.worker.respond(1, {
                    "inputState": "composing", "preedit": "です", "consumed": True,
                })
                self.assertEqual(self.effects[-1], ("reply", 0xFF50, True))
                self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def test_pending_english_keys_keep_literal_preedit_for_focus_recovery(self):
        self.key(0xFF22)
        self.assertTrue(self.input.pending_native_key(translate(ord("A"), 1)))
        self.key(ord("A"), 1, deferred=True)
        self.key(0xFF51, deferred=True)
        self.key(ord("B"), 1, deferred=True)
        self.assertEqual(self.previews[-1], ("BA", 1))
        self.input.cancel()
        self.worker.respond(0, {"inputState": "none", "language": "english", "consumed": True})
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", ord("A"), True), ("reply", 0xFF51, True), ("reply", ord("B"), True)])
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def test_focus_loss_completes_deferred_call_without_editing_the_next_field(self):
        self.key(ord("n"))
        self.key(0xFF50, 4, deferred=True)
        self.input.cancel()
        self.worker.respond(0, {"commits": ["stale"], "consumed": True})
        self.input.cancel()
        self.assertEqual(self.effects, [("reply", 0xFF50, True)])

    def test_focus_loss_preserves_later_literal_text_after_a_canceled_host_shortcut(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "にほんご"}
        self.key(0xFF0D)
        self.key(0xFF50, 4, deferred=True)
        self.key(ord("a"), deferred=True)
        self.assertEqual(self.previews[-1], ("にほんごa", 5))
        self.input.cancel()
        self.worker.respond(0, {"commits": ["stale"], "consumed": True})
        self.assertEqual(self.effects, [("reply", 0xFF50, True), ("reply", ord("a"), True)])

    def test_converter_failure_returns_the_original_native_call_after_recovery(self):
        self.key(ord("n"))
        reply = self.key(0xFF50, 4, deferred=True)
        self.worker.respond(0, {}, failed=True)
        self.assertEqual(self.effects, [
            ("recover", ""), ("forward", (ord("n"), 38, 0)), ("reply", 0xFF50, False),
        ])
        self.worker.respond(2, {})
        reply.finish(False)
        self.assertEqual(sum(effect[0] == "reply" for effect in self.effects), 1)

    def test_pending_language_switch_returns_shifted_native_text_without_forwarding(self):
        self.key(0xFF22)
        self.key(ord("A"), 1, deferred=True)
        self.worker.respond(0, {"inputState": "none", "language": "english", "consumed": True})
        self.assertEqual(self.effects[-1], ("reply", ord("A"), False))
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def test_reset_preserves_english_mode_and_orders_native_edits_after_its_acknowledgement(self):
        self.input.snapshot = {"language": "english", "inputState": "none", "preedit": ""}
        self.input.cancel()
        for key in (ord("p"), ord("q")):
            self.assertFalse(self.input.pending_native_key(translate(key, 0)))
            self.key(key)
        self.assertTrue(self.input.pending_native_key(translate(0xFF51, 0)))
        self.key(0xFF51, deferred=True)
        self.assertEqual(self.effects, [])
        self.assertEqual(self.previews[-1], ("pq", 1))
        self.worker.respond(0, {"language": "english", "inputState": "none", "preedit": ""})
        self.assertEqual(self.effects, [])
        for index, character in enumerate("pq", start=1):
            self.worker.respond(index, {"language": "english", "inputState": "none", "preedit": "",
                                        "commits": [character], "consumed": True})
        self.assertEqual([effect[0] for effect in self.effects], ["render", "render", "reply"])
        self.assertEqual(self.effects[-1], ("reply", 0xFF51, False))

    def test_native_edit_after_accepted_english_text_still_keeps_its_original_reply(self):
        self.input.snapshot = {"language": "english", "inputState": "none"}
        self.key(ord("A"), 1)
        self.assertTrue(self.input.pending_native_key(translate(0xFF51, 0)))
        self.assertTrue(self.input.pending_native_key(translate(ord("B"), 1)))

    def test_reset_acknowledgement_replaces_a_stale_language_before_returning_a_pending_key(self):
        self.input.snapshot = {"language": "english", "inputState": "none"}
        self.input.cancel()
        self.key(ord("a"), deferred=True)
        self.worker.respond(0, {"language": "japanese", "inputState": "none"})
        self.assertEqual(self.effects, [])
        self.worker.respond(1, {"language": "japanese", "inputState": "composing",
                                "preedit": "あ", "consumed": True})
        self.assertEqual(self.effects[-1], ("reply", ord("a"), True))

    def test_reset_finishes_native_delivery_only_after_retiring_its_recovery_preedit(self):
        self.input.snapshot = {"language": "english", "inputState": "none"}
        self.input.cancel()
        visible_at_delivery = []
        self.input.submit(
            "key", payload={"event": translate(ord("B"), 1)}, key=(ord("B"), 38, 1),
            key_reply=lambda consumed: visible_at_delivery.append((consumed, self.previews[-1])),
        )
        self.assertEqual(self.previews[-1], ("B", 1))
        self.worker.respond(0, {"language": "english", "inputState": "none"})
        self.assertEqual(visible_at_delivery, [(False, ("", 0))])

    def test_settings_acknowledgement_retains_the_current_language_for_native_routing(self):
        self.input.submit("settings", completion=lambda _: None)
        self.worker.respond(0, {"settings": {}, "language": "english"})
        self.assertTrue(is_native_key(translate(ord("A"), 1), self.input.snapshot))


class NativeKeyEngineFailureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import gi
            gi.require_version("Gdk", "3.0")
            from azookey.engine import Engine
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        cls.engine_type = Engine

    def test_reconversion_replay_keeps_a_native_key_whose_original_call_already_completed(self):
        forwarded = []
        engine = SimpleNamespace(
            destroyed=False, private=False, focused=True, native_key_reply=None,
            do_process_key_event=lambda *_: False,
            forward_key_event=lambda *key: forwarded.append(key),
        )
        self.engine_type.replay_key_event(engine, 0xFF50, 102, 4)
        self.assertEqual(forwarded, [(0xFF50, 102, 4)])
        engine.do_process_key_event = lambda *_: True
        self.engine_type.replay_key_event(engine, 0xFF0D, 36, 0)
        self.assertEqual(forwarded, [(0xFF50, 102, 4)])

    def test_settings_failure_completes_the_original_call_without_reconstructing_a_shortcut(self):
        effects = []
        reply = NativeKeyReply(lambda consumed: effects.append(("reply", consumed)))
        def reload_settings():
            raise ValueError("synthetic settings failure")
        def recover_pending(*, key, key_reply):
            effects.append(("recover",))
            self.assertEqual(key, (0xFF50, 102, 4))
            key_reply(False)
        engine = SimpleNamespace(
            native_key_passthrough=False, native_key_reply=reply,
            private=False, focused=True, selected_text="", sensitive=False,
            transformation=SimpleNamespace(input_changed=lambda: None),
            ai_review=SimpleNamespace(confirmation=None, key=lambda _: False),
            reconversion=SimpleNamespace(process=lambda *_, **__: False),
            input=SimpleNamespace(pending=[object()], recovering=False, is_resetting=False,
                                  recover_pending=recover_pending),
            defer_native_key=lambda _key: reply.defer(),
            reload_settings=reload_settings,
            forward_key_event=lambda *key: effects.append(("forward", key)),
        )
        self.assertTrue(self.engine_type.do_process_key_event(engine, 0xFF50, 102, 4))
        reply.finish(False)
        self.assertEqual(effects, [("recover",), ("reply", False)])


if __name__ == "__main__":
    unittest.main()
