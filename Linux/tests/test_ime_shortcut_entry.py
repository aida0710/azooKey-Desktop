import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from test_input_coordinator import ManualWorker
from ai_core_fixture import publish_core_shortcuts


def setUpModule():
    # Idle Control chords are routed by the bindings Core publishes.
    publish_core_shortcuts()


class IMEShortcutEntryTests(unittest.TestCase):
    def setUp(self):
        self.worker = ManualWorker()
        self.effects = []
        self.previews = []
        self.input = InputCoordinator(
            self.worker, "original-field",
            render=lambda snapshot: self.effects.append(("render", snapshot)),
            forward=lambda *key: self.effects.append(("forward", key)),
            recover=lambda text: self.effects.append(("recover", text)),
            preview=lambda text, cursor: self.previews.append((text, cursor)),
        )
        self.input.snapshot = {"inputState": "none", "language": "japanese", "preedit": ""}

    def key(self, keyval, state=0):
        event = translate(keyval, state)
        reply = NativeKeyReply(lambda consumed: self.effects.append(("reply", keyval, consumed)))
        deferred = self.input.pending_native_key(event)
        self.input.submit("key", payload={"event": event}, key=(keyval, 38, state),
                          key_reply=reply.defer() if deferred else None)
        return reply

    def suggestion(self, *, enabled):
        reply = self.key(ord("s"), 4)
        self.assertTrue(reply.deferred)
        self.assertFalse(self.worker.requests[0].cancelled.is_set())
        self.assertEqual(self.effects, [])
        snapshot = {"inputState": "composing" if enabled else "none",
                    "preedit": "", "consumed": enabled}
        if enabled:
            snapshot["request"] = "predict"
        self.worker.respond(0, snapshot)
        self.assertEqual(self.effects, [("render", snapshot), ("reply", ord("s"), enabled)])
        self.assertFalse(self.input.recovering)

    def test_enabled_idle_ai_request_reaches_core_before_completing_its_key(self):
        self.suggestion(enabled=True)

    def test_disabled_ai_returns_the_original_shortcut_only_after_core_rejects_it(self):
        self.suggestion(enabled=False)

    def test_typing_after_pending_ai_keeps_literal_input_for_old_field_recovery(self):
        self.key(ord("s"), 4)
        self.key(ord("a"))
        self.assertEqual(self.previews[-1], ("a", 1))
        self.input.cancel()
        self.worker.respond(0, {"consumed": True, "request": "predict"})
        self.worker.respond(1, {"consumed": True, "commits": ["stale"]})
        self.assertEqual(self.effects, [("reply", ord("s"), True), ("reply", ord("a"), True)])

    def test_unicode_waits_for_core_without_showing_raw_pending_hex(self):
        self.key(ord("U"), 5)
        self.key(ord("4"))
        self.key(ord("1"))
        self.key(0xFF0D)
        self.assertEqual(self.previews, [])
        self.assertFalse(any(request.cancelled.is_set() for request in self.worker.requests))
        for index, code in enumerate(("", "4", "41")):
            self.worker.respond(index, {
                "consumed": True, "preedit": "U+" + code, "inputState": "unicodeInput",
            })
        self.worker.respond(3, {"consumed": True, "preedit": "", "inputState": "none", "commits": ["A"]})
        self.assertEqual(self.previews, [])
        self.assertEqual([effect[1] for effect in self.effects if effect[0] == "render"][-1]["commits"], ["A"])
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", key, True) for key in (ord("U"), ord("4"), ord("1"), 0xFF0D)])
        self.assertFalse(any(effect[0] in ("forward", "recover") for effect in self.effects))

    def test_escape_and_later_input_follow_core_transition_in_order(self):
        self.input.snapshot = {"inputState": "unicodeInput", "preedit": "U+41"}
        self.key(0xFF1B)
        self.key(ord("a"))
        self.assertEqual(self.previews, [])
        self.worker.respond(0, {"consumed": True, "inputState": "none", "preedit": ""})
        self.worker.respond(1, {"consumed": True, "inputState": "composing", "preedit": "あ"})
        self.assertEqual(self.effects[-2:],
                         [("render", {"consumed": True, "inputState": "composing", "preedit": "あ"}),
                          ("reply", ord("a"), True)])
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def test_unicode_focus_or_reset_discards_late_result_without_returning_hex(self):
        for initial in ("none", "unicodeInput"):
            with self.subTest(initial=initial):
                self.setUp()
                self.input.snapshot = {"inputState": initial, "preedit": "" if initial == "none" else "U+4"}
                self.key(ord("U"), 5)
                self.key(ord("1"))
                self.input.cancel()
                self.worker.respond(0, {"consumed": True, "inputState": "unicodeInput", "preedit": "U+"})
                self.worker.respond(1, {"consumed": True, "commits": ["stale"]})
                self.input.cancel()
                self.assertEqual(self.effects, [("reply", ord("U"), True), ("reply", ord("1"), True)])

    def test_failed_unicode_entry_preserves_existing_composition_once(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "あ"}
        self.key(ord("U"), 5)
        self.key(ord("4"))
        self.worker.respond(0, failed=True)
        self.worker.respond(1, {"commits": ["stale"]})
        self.assertEqual(self.effects, [
            ("recover", "あ"), ("reply", ord("U"), True), ("reply", ord("4"), True),
        ])

    def test_unicode_failure_and_progress_timeout_never_commit_code_notation(self):
        for failure in ("transport", "timeout"):
            with self.subTest(failure=failure):
                self.setUp()
                self.input.snapshot = {"inputState": "unicodeInput", "preedit": "U+41"}
                self.key(0xFF0D)
                if failure == "transport":
                    self.worker.respond(0, failed=True)
                else:
                    self.input._progress_expired()
                self.assertEqual(self.effects, [("recover", ""), ("reply", 0xFF0D, True)])

    def test_converter_restart_discards_hex_and_native_newline_after_unicode_mode_is_lost(self):
        for key, snapshot in (
            (ord("4"), {"consumed": True, "inputState": "none", "preedit": "", "commits": ["4"]}),
            (0xFF0D, {"consumed": False, "inputState": "none", "preedit": ""}),
        ):
            with self.subTest(key=key):
                self.setUp()
                self.input.snapshot = {"inputState": "unicodeInput", "preedit": "U+41"}
                self.key(key)
                self.worker.respond(0, snapshot, generation=1)
                self.assertEqual(self.effects, [("recover", ""), ("reply", key, True)])
                self.assertTrue(self.input.recovering)

    def test_ai_failure_keeps_original_composition_and_returns_no_typed_text(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "あ"}
        self.key(ord("s"), 4)
        self.worker.respond(0, failed=True)
        self.assertEqual(self.effects, [("recover", "あ"), ("reply", ord("s"), False)])


if __name__ == "__main__":
    unittest.main()
