"""The real Engine dispatcher keeps Core display changes before key replies."""
import pathlib
import sys
from types import MethodType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_coordinator import InputCoordinator
from test_input_coordinator import ManualWorker


class KeyPreeditOrderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import gi
            gi.require_version("IBus", "1.0")
            from gi.repository import GLib, IBus
            from azookey.engine import Engine
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        cls.engine_type, cls.variant_type, cls.ibus_engine = Engine, GLib.Variant, IBus.Engine
        cls.glib_error = GLib.Error

    def setUp(self):
        self.effects = []
        self.worker = ManualWorker()
        self.input = InputCoordinator(
            self.worker, "original-field",
            render=lambda snapshot: self.effects.append(("render", snapshot)),
            preview=lambda text, cursor: self.effects.append(("preview", text, cursor)),
            recover=lambda text: self.effects.append(("recover", text)),
            forward=lambda *key: self.effects.append(("forward", key)),
        )
        self.input.snapshot = {"inputState": "none", "preedit": "", "language": "japanese"}
        connection = object()
        self.engine = SimpleNamespace(
            native_key_reply=None, native_key_passthrough=False, destroyed=False,
            private=False, sensitive=False, focused=True, selected_text="",
            left="", right="", input=self.input, settings={}, last_language_key=(None, 0),
            get_connection=lambda: connection, current_reconversion_context=lambda: None,
            transformation=Mock(), ai_review=SimpleNamespace(confirmation=None, key=lambda _: False, cancel=Mock()),
            reconversion=SimpleNamespace(active=False, process=lambda *_, **__: False),
            reload_settings=lambda: None,
        )
        for name in ("do_process_key_event", "do_service_method_call", "finish_native_key",
                     "defer_native_key", "request"):
            setattr(self.engine, name, MethodType(getattr(self.engine_type, name), self.engine))
        self.engine.emit = lambda _signal, *key: self.engine.do_process_key_event(*key)

        def synchronous_dispatch(engine, *_arguments):
            parameters, invocation = _arguments[-2:]
            consumed = engine.emit("process-key-event", *parameters.unpack())
            invocation.return_value(self.variant_type("(b)", (consumed,)))

        # Replace only the GI transport boundary; both Engine entry methods and
        # its actual InputCoordinator still decide consumption and reply timing.
        self.dispatcher = patch.object(self.ibus_engine, "do_service_method_call", synchronous_dispatch)
        self.dispatcher.start()
        self.addCleanup(self.dispatcher.stop)

    def send(self, keyval, state=0):
        invocation = Mock()
        invocation.return_value.side_effect = lambda value: self.effects.append(("reply", keyval, value.unpack()[0]))
        self.engine.do_service_method_call(
            self.engine.get_connection(), ":1.100", "/org/freedesktop/IBus/Engine/1",
            "org.freedesktop.IBus.Engine", "ProcessKeyEvent",
            self.variant_type("(uuu)", (keyval, 38, state)), invocation,
        )
        self.assertIsNone(self.engine.native_key_reply)
        return invocation

    def test_plain_text_reply_follows_the_core_preedit_and_cannot_finish_twice(self):
        invocation = self.send(ord("a"))
        invocation.return_value.assert_not_called()
        snapshot = {"consumed": True, "inputState": "composing", "preedit": "あ", "cursor": 1}
        self.worker.respond(0, snapshot)
        self.assertEqual(self.effects[-2:], [("render", snapshot), ("reply", ord("a"), True)])
        self.input.cancel()
        invocation.return_value.assert_called_once()

    def test_commit_reply_follows_the_commit_and_empty_preedit(self):
        for key in (0xFF0D, 0xFFC7):
            with self.subTest(key=key):
                self.input.snapshot = {"inputState": "composing", "preedit": "あ", "language": "japanese"}
                request_index = len(self.worker.requests)
                invocation = self.send(key)
                invocation.return_value.assert_not_called()
                snapshot = {"consumed": True, "inputState": "none", "preedit": "", "commits": ["a"]}
                self.worker.respond(request_index, snapshot)
                self.assertEqual(self.effects[-2:], [("render", snapshot), ("reply", key, True)])
                invocation.return_value.assert_called_once()

    def test_focus_cancellation_finishes_original_call_and_discards_late_display(self):
        invocation = self.send(ord("a"))
        invocation.return_value.assert_not_called()
        self.input.cancel()
        cancelled_effects = list(self.effects)
        self.worker.respond(0, {"consumed": True, "preedit": "別の欄へ送らない", "commits": ["stale"]})
        self.assertEqual(self.effects, cancelled_effects)
        invocation.return_value.assert_called_once()
        self.assertEqual(self.effects[-1], ("reply", ord("a"), True))

    def test_failed_plain_text_returns_original_key_once_after_recovery(self):
        invocation = self.send(ord("a"))
        invocation.return_value.assert_not_called()
        self.worker.respond(0, failed=True)
        self.assertEqual(self.effects[-2:], [("recover", ""), ("reply", ord("a"), False)])
        invocation.return_value.assert_called_once()
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))

    def test_idle_native_key_is_returned_without_waiting_for_core(self):
        invocation = self.send(0xFF50, 4)
        self.assertEqual(self.effects, [("reply", 0xFF50, False)])
        self.assertEqual(self.worker.requests, [])
        invocation.return_value.assert_called_once()

    def test_render_failure_preserves_preedit_once_and_completes_original_calls_in_order(self):
        first = self.send(ord("a"))
        second = self.send(ord("i"))
        self.input.render = Mock(side_effect=RuntimeError("synthetic renderer failure"))
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "inputState": "composing", "preedit": "あ"})
        self.assertEqual([effect for effect in self.effects if effect[0] != "preview"], [
            ("reply", ord("a"), True), ("recover", "あ"), ("reply", ord("i"), False),
        ])
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.worker.respond(1, {"consumed": True, "commits": ["stale"]})
        self.assertEqual(self.input.render.call_count, 1)
        self.assert_next_input_completes()

    def test_render_failure_after_commit_does_not_replay_the_commit_or_enter(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "あ", "language": "japanese"}
        invocation = self.send(0xFF0D)
        committed = []

        def render(snapshot):
            committed.extend(snapshot.get("commits", []))
            raise ValueError("synthetic failure after commit")

        self.input.render = render
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "inputState": "none", "preedit": "", "commits": ["あ"]})
        self.assertEqual(committed, ["あ"])
        self.assertEqual(self.effects[-2:], [("reply", 0xFF0D, True), ("recover", "")])
        invocation.return_value.assert_called_once()
        self.assert_next_input_completes()
        self.assertEqual(committed, ["あ"])

    def test_completion_status_failure_keeps_preedit_and_finishes_the_original_reply(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "あ", "language": "japanese"}
        completed = []
        self.input.submit(
            "settings", completion=Mock(side_effect=OSError("synthetic status failure")),
            key_reply=completed.append,
        )
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"settings": {}})
        self.assertEqual(completed, [True])
        self.assertEqual(self.effects, [("recover", "あ")])
        self.assert_next_input_completes()

    def test_recovery_failure_after_commit_retires_remaining_calls_without_duplicate_native_delivery(self):
        first, second = self.send(ord("a")), self.send(ord("i"))
        committed = []
        self.input.render = Mock(side_effect=RuntimeError("synthetic renderer failure"))

        def recover(text):
            committed.append(text)
            raise OSError("synthetic failure after recovery commit")

        self.input.recover = recover
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "inputState": "composing", "preedit": "あ"})
        self.assertEqual(committed, ["あ"])
        self.assertEqual([effect for effect in self.effects if effect[0] != "preview"], [
            ("reply", ord("a"), True), ("reply", ord("i"), True),
        ])
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.assert_next_input_completes()
        self.assertEqual(committed, ["あ"])

    def test_recovery_failure_during_converter_restart_finishes_all_calls_once(self):
        self.input.snapshot = {"inputState": "composing", "preedit": "あ", "language": "japanese"}
        first, second = self.send(ord("i")), self.send(ord("u"))
        self.input.recover = Mock(side_effect=RuntimeError("synthetic recovery display failure"))
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "preedit": "い"}, generation=1)
        self.assertEqual([effect for effect in self.effects if effect[0] != "preview"], [
            ("reply", ord("i"), True), ("reply", ord("u"), True),
        ])
        self.input.recover.assert_called_once_with("あ")
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.assert_next_input_completes(generation=1)

    def test_glib_errors_in_display_and_recovery_complete_original_calls_without_native_edits(self):
        first, second = self.send(ord("a")), self.send(ord("i"))
        self.input.render = Mock(side_effect=self.glib_error("synthetic display connection failure"))
        self.input.recover = Mock(side_effect=self.glib_error("synthetic recovery connection failure"))
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "inputState": "composing", "preedit": "あ"})
        self.assertEqual([effect for effect in self.effects if effect[0] != "preview"], [
            ("reply", ord("a"), True), ("reply", ord("i"), True),
        ])
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.input.recover.assert_called_once_with("あ")
        self.assert_next_input_completes()

    def test_failed_preview_clear_after_reset_retires_original_native_keys_once(self):
        self.input.snapshot = {"inputState": "none", "language": "english"}
        self.input.cancel()
        first, second = self.send(ord("a")), self.send(ord("b"))
        self.assertTrue(self.input.has_recovery_preedit)
        self.input.preview = Mock(side_effect=self.glib_error("synthetic preview connection failure"))
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"inputState": "none", "language": "english"})
        self.assertEqual([effect for effect in self.effects if effect[0] != "preview"], [
            ("reply", ord("a"), True), ("reply", ord("b"), True),
        ])
        self.input.preview.assert_called_once_with("", 0)
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.worker.respond(1, {"consumed": False})
        self.worker.respond(2, {"consumed": False})
        first.return_value.assert_called_once()
        second.return_value.assert_called_once()
        self.input.preview = lambda text, cursor: self.effects.append(("preview", text, cursor))
        self.assert_next_input_completes()

    def test_failed_render_reply_can_change_focus_without_cancelling_the_new_field(self):
        invocation = self.send(ord("a"))
        self.input.render = Mock(side_effect=RuntimeError("synthetic renderer failure"))
        new_call = []

        def change_focus(value):
            self.effects.append(("reply", ord("a"), value.unpack()[0]))
            self.input.cancel()
            new_call.append((len(self.worker.requests), self.send(ord("b"))))

        invocation.return_value.side_effect = change_focus
        with self.assertLogs("azookey.input_coordinator", level="ERROR"):
            self.worker.respond(0, {"consumed": True, "inputState": "composing", "preedit": "あ"})
        invocation.return_value.assert_called_once()
        self.assertFalse(any(effect[0] == "recover" for effect in self.effects))
        self.input.render = lambda snapshot: self.effects.append(("render", snapshot))
        self.worker.respond(1, {"inputState": "none", "language": "japanese"})
        request, pending = new_call[0]
        self.worker.respond(request, {"consumed": True, "preedit": "び"})
        pending.return_value.assert_called_once()
        self.assertEqual(self.input.snapshot["preedit"], "び")

    def test_engine_recovery_display_failure_retires_transferred_reconversion_calls(self):
        recovery = object()
        engine = SimpleNamespace(
            lookup_announcements=Mock(), ai_review=Mock(), reconversion=Mock(),
            anchor=Mock(), update_preedit_text_with_mode=Mock(side_effect=OSError("synthetic display failure")),
        )
        engine.reconversion.take_recovery.return_value = ("あ", recovery)
        with self.assertRaises(OSError):
            self.engine_type.prepare_composition_recovery(engine, "あ")
        engine.reconversion.finish_recovery.assert_called_once_with(recovery, allow_native=False)

    def assert_next_input_completes(self, *, generation=0):
        reset_index = len(self.worker.requests) - 1
        self.assertEqual(self.worker.requests[reset_index].operation, "reset")
        self.worker.respond(reset_index, {"inputState": "none", "language": "japanese"}, generation=generation)
        self.input.render = lambda snapshot: self.effects.append(("render", snapshot))
        request_index = len(self.worker.requests)
        invocation = self.send(ord("b"))
        self.worker.respond(request_index, {"consumed": True, "preedit": "び"}, generation=generation)
        invocation.return_value.assert_called_once()
        self.assertEqual(self.input.snapshot["preedit"], "び")
        self.assertFalse(any(effect[0] == "forward" for effect in self.effects))


if __name__ == "__main__":
    unittest.main()
