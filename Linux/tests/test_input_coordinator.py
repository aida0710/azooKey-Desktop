import pathlib
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.async_bridge import Reply
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate


class ManualWorker:
    def __init__(self):
        self.requests = []

    def submit(self, request):
        self.requests.append(request)

    def respond(self, index, snapshot=None, *, failed=False, generation=0):
        self.requests[index].complete(Reply(snapshot, generation, failed))


class InputCoordinatorTests(unittest.TestCase):
    def setUp(self):
        self.worker = ManualWorker()
        self.effects = []
        self.previews = []
        self.coordinator = InputCoordinator(
            self.worker, "first-field",
            render=lambda snapshot: self.effects.append(("render", snapshot)),
            forward=lambda *key: self.effects.append(("forward", key)),
            recover=lambda text: self.effects.append(("recover", text)),
            preview=lambda text, cursor: self.previews.append((text, cursor)),
        )

    def key(self, character):
        keyval = ord(character)
        self.coordinator.submit("key", payload={"event": translate(keyval, 0)}, key=(keyval, 38, 0))

    def test_unconsumed_key_is_forwarded_after_earlier_commit(self):
        self.key("a")
        self.key("b")
        self.worker.respond(0, {"consumed": True, "commits": ["あ"], "preedit": ""})
        self.worker.respond(1, {"consumed": False, "preedit": ""})
        self.assertEqual(self.effects, [
            ("render", {"consumed": True, "commits": ["あ"], "preedit": ""}),
            ("render", {"consumed": False, "preedit": ""}),
            ("forward", (ord("b"), 38, 0)),
        ])

    def test_modifier_presses_during_pending_input_preserve_text_and_key_order(self):
        self.key("a")
        physical_keys = []
        for keyval, mask in ((0xFFE1, 1), (0xFFE3, 4), (0xFFE9, 8), (0xFFEB, 1 << 6)):
            for state in (0, mask | (1 << 30)):
                physical_key = (keyval, 0, state)
                physical_keys.append(physical_key)
                event = translate(keyval, state, 0)
                self.coordinator.submit(
                    "key" if event is not None else None,
                    payload={"event": event} if event is not None else {}, key=physical_key,
                )
        self.key("b")
        self.assertEqual(self.effects, [], "A physical modifier must not recover the pending input")
        self.assertEqual(self.previews[-1], ("ab", 2))
        self.worker.respond(0, {"consumed": True, "preedit": "あ", "inputState": "composing"})
        self.worker.respond(len(self.worker.requests) - 1, {
            "consumed": True, "preedit": "あb", "inputState": "composing",
        })
        self.assertEqual([effect[1] for effect in self.effects if effect[0] == "forward"], physical_keys)
        self.assertFalse(any(effect[0] == "recover" for effect in self.effects))
        self.assertEqual(self.coordinator.snapshot["preedit"], "あb")

    def test_failure_preserves_acknowledged_preedit_once_and_returns_pending_keys_in_order(self):
        self.key("a")
        self.worker.respond(0, {"consumed": True, "preedit": "あ", "cursor": 1})
        self.key("i")
        self.key("u")
        self.coordinator.submit(None, key=(ord("u"), 38, 1 << 30))
        self.assertEqual(self.previews[-1], ("あiu", 3))
        self.worker.respond(1, failed=True)
        self.assertEqual(self.effects[1:], [
            ("recover", "あ"),
            ("forward", (ord("i"), 38, 0)),
            ("forward", (ord("u"), 38, 0)),
            ("forward", (ord("u"), 38, 1 << 30)),
        ])
        # A response already queued by the worker must not duplicate a commit.
        self.worker.respond(2, {"consumed": True, "commits": ["stale"]})
        self.worker.respond(1, failed=True)
        self.assertEqual(len(self.effects), 5)

    def test_cancelled_context_discards_pending_input_and_ignores_late_commits(self):
        self.key("a")
        self.coordinator.cancel()
        self.key("i")
        self.worker.respond(0, {"consumed": True, "commits": ["old"]})
        self.worker.respond(2, {"consumed": True, "preedit": "い"})
        self.assertEqual(self.effects, [("render", {"consumed": True, "preedit": "い"})])
        self.assertTrue(self.worker.requests[0].cancelled.is_set())
        self.assertEqual(self.worker.requests[1].operation, "reset")

    def test_focus_loss_and_refocus_cannot_deliver_old_keys_or_commits(self):
        self.key("a")
        self.coordinator.cancel()
        self.key("b")
        self.worker.respond(0, {"consumed": False, "commits": ["old-field"]})
        self.worker.respond(2, {"consumed": False, "preedit": ""})
        self.assertEqual(self.effects[-1], ("forward", (ord("b"), 38, 0)))
        self.assertFalse(any(effect == ("forward", (ord("a"), 38, 0)) for effect in self.effects))

    def test_restarted_converter_preserves_previous_preedit_before_first_new_result(self):
        self.key("a")
        self.worker.respond(0, {"consumed": True, "preedit": "あ"})
        self.key("i")
        self.worker.respond(1, {"consumed": True, "preedit": "い"}, generation=1)
        self.assertEqual(self.effects[1:], [
            ("recover", "あ"), ("render", {"consumed": True, "preedit": "い"}),
        ])
        self.key("u")
        self.worker.respond(2, {"consumed": True, "preedit": "いう"}, generation=1)
        self.assertEqual(sum(effect[0] == "recover" for effect in self.effects), 1)

    def test_two_contexts_have_independent_cancellation_and_recovery(self):
        other_effects = []
        other = InputCoordinator(
            self.worker, "second-field", render=other_effects.append,
            forward=lambda *_: self.fail("a consumed key must not be forwarded"),
            recover=lambda text: other_effects.append(text), preview=lambda *_: None,
        )
        self.key("a")
        other.submit("key", payload={"event": translate(ord("b"), 0)}, key=(ord("b"), 38, 0))
        self.coordinator.cancel()
        self.worker.respond(0, {"consumed": True, "commits": ["old-field"]})
        self.worker.respond(1, {"consumed": True, "preedit": "b"})
        self.assertEqual(other_effects, [{"consumed": True, "preedit": "b"}])
        self.assertEqual(self.effects, [])

    def test_settings_reply_does_not_clear_composition(self):
        self.key("a")
        self.worker.respond(0, {"consumed": True, "preedit": "あ"})
        settings = []
        self.coordinator.submit("settings", completion=settings.append)
        self.worker.respond(1, {"settings": {"live": True}})
        self.assertEqual(self.coordinator.snapshot["preedit"], "あ")
        self.assertEqual(settings, [{"settings": {"live": True}}])

    def test_focus_fallback_keeps_literal_space_and_second_enter(self):
        self.coordinator.settings = {"halfSpace": True}
        self.key("a")
        for keyval in (0xFF0D, 32, 0xFF0D):
            self.coordinator.submit("key", payload={"event": translate(keyval, 0)}, key=(keyval, 0, 0))
        self.assertEqual(self.previews[-1], ("a \n", 3))

    def test_closed_context_ignores_pending_result(self):
        self.key("a")
        self.coordinator.close()
        self.worker.respond(0, {"consumed": True, "commits": ["old"]})
        self.assertEqual(self.effects, [])

    def test_progress_deadline_recovers_input_without_killing_slow_model_load(self):
        timers = {}
        removed = []

        def schedule(milliseconds, callback):
            timers[len(timers) + 1] = callback
            return len(timers)

        self.coordinator.schedule_timeout = schedule
        self.coordinator.remove_timeout = removed.append
        self.key("a")
        timers[1]()
        self.assertTrue(self.coordinator.recovering)
        self.assertEqual(self.effects, [("recover", ""), ("forward", (ord("a"), 38, 0))])
        # A slow, valid initial load keeps running. New input bypasses its queue.
        self.key("b")
        self.assertEqual(self.effects[-1], ("forward", (ord("b"), 38, 0)))
        self.assertEqual(len(self.worker.requests), 2)
        self.worker.respond(0, {"consumed": True, "commits": ["late"]})
        self.worker.respond(1, {"preedit": ""})
        self.assertFalse(self.coordinator.recovering)
        self.key("c")
        self.worker.respond(2, {"consumed": True, "preedit": "c"})
        self.assertEqual(self.effects[-1], ("render", {"consumed": True, "preedit": "c"}))

    def test_each_reply_renews_progress_deadline_for_a_slow_but_working_converter(self):
        scheduled = []
        removed = []
        self.coordinator.schedule_timeout = lambda milliseconds, callback: scheduled.append(milliseconds) or len(scheduled)
        self.coordinator.remove_timeout = removed.append
        self.key("a")
        self.key("b")
        self.worker.respond(0, {"consumed": True, "preedit": "a"})
        self.assertEqual(removed, [1])
        self.assertEqual(scheduled, [3000, 3000])
        self.worker.respond(1, {"consumed": True, "preedit": "ab"})
        self.assertEqual(removed, [1, 2])
        self.assertIsNone(self.coordinator.timeout_source)

    def test_another_contexts_progress_prevents_a_premature_queue_timeout(self):
        scheduled = []
        self.coordinator.schedule_timeout = lambda milliseconds, callback: scheduled.append(milliseconds) or len(scheduled)
        self.coordinator.remove_timeout = lambda _source: None
        self.key("a")
        self.worker.last_progress_at = 9.0
        with patch("azookey.input_coordinator.time.monotonic", return_value=10.0):
            self.coordinator._progress_expired()
        self.assertFalse(self.coordinator.recovering)
        self.assertEqual(scheduled, [3000, 2000])
        with patch("azookey.input_coordinator.time.monotonic", return_value=12.0):
            self.coordinator._progress_expired()
        self.assertTrue(self.coordinator.recovering)

    def test_failure_after_escape_does_not_resurrect_cancelled_keys(self):
        self.key("a")
        self.coordinator.submit("key", payload={"event": translate(0xFF1B, 0)}, key=(0xFF1B, 38, 0))
        self.assertEqual(self.previews[-1], ("", 0))
        self.worker.respond(0, failed=True)
        self.assertEqual(self.effects, [("recover", "")])

    def test_failure_after_conversion_escape_preserves_reading_once(self):
        self.coordinator.snapshot = {
            "preedit": "にほんご", "reading": "にほんご", "inputState": "composing",
        }
        for keyval in (32, 0xFF1B):
            self.coordinator.submit("key", payload={"event": translate(keyval, 0)}, key=(keyval, 38, 0))
        self.worker.respond(0, failed=True)
        self.assertEqual(self.effects, [("recover", "にほんご")])

    def test_acknowledged_english_mode_delivers_native_edits_without_waiting_for_converter(self):
        self.coordinator.snapshot = {"language": "english", "inputState": "none"}
        for keyval in (ord("a"), 0xFF51, ord("b")):
            self.coordinator.submit(
                "key", payload={"event": translate(keyval, 0)}, key=(keyval, 38, 0),
                key_reply=lambda consumed, keyval=keyval: self.effects.append(("reply", (keyval, consumed))),
            )
        self.assertEqual([effect[1][0] for effect in self.effects], [ord("a"), 0xFF51, ord("b")])
        self.assertEqual(self.worker.requests, [])
        self.assertEqual(self.previews, [])

    def test_mode_reply_returns_queued_native_edits_in_order_without_partial_projection(self):
        for keyval in (0xFF22, ord("a"), 0xFF51, ord("b")):
            reply = None if keyval == 0xFF22 else (
                lambda consumed, keyval=keyval: self.effects.append(("reply", (keyval, consumed)))
            )
            self.coordinator.submit("key", payload={"event": translate(keyval, 0)}, key=(keyval, 38, 0),
                                    key_reply=reply)
        self.assertEqual(self.previews[-1], ("ba", 1))
        self.worker.respond(0, {"language": "english", "inputState": "none", "preedit": "", "consumed": True})
        self.assertEqual([effect[1][0] for effect in self.effects[1:]], [ord("a"), 0xFF51, ord("b")])
        self.assertFalse(self.coordinator.pending)
        self.worker.respond(1, {"commits": ["a"]})
        self.assertEqual(len(self.effects), 4)


if __name__ == "__main__":
    unittest.main()
