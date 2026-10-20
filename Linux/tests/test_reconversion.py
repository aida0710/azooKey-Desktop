import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate
from azookey.reconversion import ReconversionCoordinator, removed_context, surrounding_context
from test_input_coordinator import ManualWorker


class ReconversionTests(unittest.TestCase):
    def setUp(self):
        self.worker = ManualWorker()
        self.effects = []
        self.timers = {}
        self.document = surrounding_context("前日本語後", 4, 1, can_replace=True, sensitive=False)
        self.inputs = InputCoordinator(
            self.worker, "same-field", render=lambda snapshot: self.effects.append(("render", snapshot)),
            forward=lambda *key: self.effects.append(("forward", key)), recover=self.recover,
            preview=lambda *_: None,
        )
        self.coordinator = ReconversionCoordinator(
            self.inputs, context=lambda: self.document,
            delete=lambda offset, count: self.effects.append(("delete", offset, count)),
            status=lambda text: self.effects.append(("status", text)),
            replay=lambda *key: self.effects.append(("replay", key)),
            forward=lambda *key: self.effects.append(("forward", key)),
            schedule_timeout=self.schedule, remove_timeout=self.timers.pop,
        )
        self.plan = {"token": "one-use", "offset": -3, "count": 3, "text": "日本語", "reading": "にほんご"}

    def schedule(self, milliseconds, callback):
        self.timers[1] = callback
        return 1

    def recover(self, text):
        text, queued = self.coordinator.take_recovery(text)
        self.effects.append(("recover", text))
        for key in queued:
            self.effects.append(("forward", key))

    def prepare(self):
        self.coordinator.start(undo=False)
        self.worker.respond(0, {"reconversion": self.plan})

    def acknowledge(self):
        self.document = surrounding_context("前後", 1, 1, can_replace=True, sensitive=False)
        self.coordinator.surrounding_changed()

    def confirm_with_buffered_enter(self):
        self.prepare()
        self.coordinator.process(translate(0xFF0D, 0), (0xFF0D, 0, 0))
        self.acknowledge()
        self.effects.clear()

    def assert_changed_confirmation_is_discarded(self):
        self.assertFalse(self.coordinator.active)
        self.assertFalse(self.inputs.snapshot.get("preedit"))
        self.assertFalse(any(effect[0] in ("replay", "forward") for effect in self.effects))
        self.assertFalse(any(effect[0] == "recover" and effect[1] for effect in self.effects))
        self.assertFalse(any(effect[0] == "render" and effect[1].get("preedit") for effect in self.effects))
        self.assertIn(("status", "文字や入力位置が変わったため再変換を中止しました"), self.effects)

    def test_selection_waits_for_deletion_ack_and_preserves_later_key_order(self):
        self.prepare()
        self.coordinator.start(undo=False)
        self.assertIn(("delete", -3, 3), self.effects)
        self.assertFalse(any(effect[0] == "render" for effect in self.effects))
        for keyval in (0xFF0D, ord("a")):
            self.assertTrue(self.coordinator.process(translate(keyval, 0), (keyval, 0, 0)))
        self.acknowledge()
        self.assertEqual(self.inputs.snapshot["preedit"], "日本語")
        self.assertEqual(self.worker.requests[-1].operation, "confirm-reconversion")
        self.worker.respond(1, {"preedit": "日本語", "reading": "にほんご", "inputState": "selecting"})
        self.assertEqual(self.effects[-2:], [("replay", (0xFF0D, 0, 0)), ("replay", (ord("a"), 0, 0))])
        self.assertFalse(self.coordinator.active)
        self.assertFalse(self.timers)
        self.coordinator.surrounding_changed()
        self.assertEqual(sum(effect[0] == "delete" for effect in self.effects), 1)
        self.assertEqual(len(self.worker.requests), 2)

    def test_changed_document_before_reply_never_deletes_text(self):
        self.coordinator.start(undo=False)
        self.document = surrounding_context("別日本語後", 4, 1, can_replace=True, sensitive=False)
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.assertFalse(self.coordinator.active)

    def test_focus_change_before_reply_never_deletes_text(self):
        self.coordinator.start(undo=False)
        self.coordinator.cancel()
        self.inputs.cancel()
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))

    def test_first_shortcut_waits_for_initial_settings_without_being_rejected(self):
        self.inputs.submit("settings", completion=lambda _snapshot: None)
        self.coordinator.start(undo=False)
        self.worker.respond(0, {"settings": {}})
        self.worker.respond(1, {"reconversion": self.plan})
        self.assertIn(("delete", -3, 3), self.effects)

    def test_ignored_deletion_never_starts_composition_and_is_not_retried(self):
        self.prepare()
        self.coordinator.surrounding_changed()
        self.timers.pop(1)()
        self.assertFalse(self.coordinator.active)
        self.assertFalse(any(effect[0] == "render" for effect in self.effects))
        self.assertEqual(sum(effect[0] == "delete" for effect in self.effects), 1)
        self.assertIn(("status", "この入力先では範囲の置換を確認できません"), self.effects)

    def test_bridge_failure_after_ack_preserves_original_once_before_buffered_keys(self):
        self.prepare()
        self.coordinator.process(translate(ord("a"), 0), (ord("a"), 0, 0))
        self.acknowledge()
        self.worker.respond(1, failed=True)
        self.assertEqual(self.effects[-2:], [("recover", "日本語"), ("forward", (ord("a"), 0, 0))])
        self.worker.respond(1, failed=True)
        self.assertEqual(sum(effect[0] == "recover" for effect in self.effects), 1)

    def test_document_change_during_confirmation_discards_preedit_and_late_replies(self):
        self.confirm_with_buffered_enter()
        self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
        self.coordinator.surrounding_changed()
        self.assert_changed_confirmation_is_discarded()
        effects_after_cancel = list(self.effects)
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"})
        self.worker.respond(1, failed=True)
        self.assertEqual(self.effects, effects_after_cancel)
        self.assertEqual(self.worker.requests[-1].operation, "reset")

    def test_confirmation_reply_rechecks_cursor_without_a_surrounding_notification(self):
        self.confirm_with_buffered_enter()
        self.document = surrounding_context("前後", 0, 0, can_replace=True, sensitive=False)
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"})
        self.assert_changed_confirmation_is_discarded()

    def test_transport_failure_cannot_restore_original_when_context_is_unavailable(self):
        self.confirm_with_buffered_enter()
        self.document = None
        self.worker.respond(1, failed=True)
        self.assert_changed_confirmation_is_discarded()

    def test_error_reply_cannot_restore_original_after_an_unreported_document_change(self):
        self.confirm_with_buffered_enter()
        self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
        self.worker.respond(1, {"reconversionError": "stale_request"})
        self.assert_changed_confirmation_is_discarded()

    def test_timeout_cannot_restore_original_after_an_unreported_document_change(self):
        self.confirm_with_buffered_enter()
        self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
        self.inputs._progress_expired()
        self.assert_changed_confirmation_is_discarded()

    def test_converter_restart_cannot_restore_original_after_an_unreported_document_change(self):
        self.confirm_with_buffered_enter()
        self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"}, generation=1)
        self.assert_changed_confirmation_is_discarded()

    def test_converter_restart_preserves_original_before_keys_and_accepts_next_input(self):
        self.confirm_with_buffered_enter()
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"}, generation=1)
        self.assertEqual(self.effects, [("recover", "日本語"), ("forward", (0xFF0D, 0, 0))])
        self.assertFalse(self.coordinator.active)
        self.inputs.submit("key", payload={"event": translate(ord("a"), 0)}, key=(ord("a"), 0, 0))
        self.worker.respond(2, {"consumed": True, "preedit": "あ"}, generation=1)
        self.assertEqual(self.effects[-1], ("render", {"consumed": True, "preedit": "あ"}))
        self.assertEqual(sum(effect == ("recover", "日本語") for effect in self.effects), 1)

    def test_timeout_in_unchanged_context_preserves_original_once_and_key_order(self):
        self.confirm_with_buffered_enter()
        self.inputs._progress_expired()
        self.assertEqual(self.effects, [("recover", "日本語"), ("forward", (0xFF0D, 0, 0))])
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"})
        self.assertEqual(len(self.effects), 2)

    def test_focus_cancellation_after_ack_discards_late_success_and_failure(self):
        self.confirm_with_buffered_enter()
        self.coordinator.cancel()
        self.inputs.cancel()
        self.worker.respond(1, {"preedit": "古い候補", "reading": "にほんご"})
        self.worker.respond(1, failed=True)
        self.assertEqual(self.effects, [])

    def test_document_change_during_acknowledged_preedit_display_stops_confirmation(self):
        self.prepare()

        def change_document(snapshot):
            self.effects.append(("render", snapshot))
            self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
            self.coordinator.surrounding_changed()

        self.inputs.render = change_document
        self.acknowledge()
        self.assertFalse(self.coordinator.active)
        self.assertFalse(any(request.operation == "confirm-reconversion" for request in self.worker.requests))
        self.assertFalse(any(effect[0] == "recover" and effect[1] for effect in self.effects))

    def test_document_change_while_showing_confirmed_candidates_discards_buffered_keys(self):
        self.confirm_with_buffered_enter()

        def change_document(snapshot):
            self.effects.append(("render", snapshot))
            self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)

        self.inputs.render = change_document
        self.worker.respond(1, {"preedit": "新候補", "reading": "にほんご"})
        self.assertFalse(self.coordinator.active)
        self.assertFalse(self.inputs.snapshot.get("preedit"))
        self.assertFalse(any(effect[0] in ("replay", "forward") for effect in self.effects))
        self.assertFalse(any(effect[0] == "recover" and effect[1] for effect in self.effects))
        self.assertEqual(self.effects[-1], ("status", "文字や入力位置が変わったため再変換を中止しました"))

    def test_missing_reading_does_not_edit_document_and_escape_closes_prompt(self):
        self.coordinator.start(undo=False)
        self.worker.respond(0, {"reconversionError": "reading_required", "reconversionReading": ""})
        self.assertEqual(self.coordinator.phase, "reading")
        self.coordinator.process(translate(ord("a"), 0), (ord("a"), 0, 0))
        self.assertEqual(self.worker.requests[-1].operation, "reconversion-reading")
        self.worker.respond(1, {"reconversionReading": "あ"})
        self.coordinator.process(translate(0xFF1B, 0), (0xFF1B, 0, 0))
        self.worker.respond(2, {})
        self.assertFalse(self.coordinator.active)
        self.assertFalse(any(effect[0] in ("delete", "render") for effect in self.effects))

    def test_private_unavailable_and_active_compositions_are_not_replaced(self):
        for context in (None, {**self.document, "canReplace": False}, {**self.document, "isSensitive": True}):
            self.document = context
            self.coordinator.start(undo=False)
        self.inputs.snapshot = {"preedit": "入力中"}
        self.coordinator.start(undo=False)
        self.assertEqual(self.worker.requests, [])
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))

    def test_plan_must_describe_exact_selected_scalar_range(self):
        for invalid in (
            None, {}, "invalid",
            {**self.plan, "text": "日本"},
            {**self.plan, "offset": 0},
            {**self.plan, "count": 4},
            {**self.plan, "count": 3.0},
        ):
            self.assertIsNone(removed_context(self.document, invalid))
        selected = "👩‍💻e\u0301"
        document = surrounding_context("前" + selected + "後", 1, 1 + len(selected), can_replace=True, sensitive=False)
        self.assertEqual(document["cursorUTF16"], 1)
        self.assertEqual(document["anchorUTF16"], 8)
        expected = removed_context(document, {"token": "unicode", "text": selected, "offset": 0, "count": 5})
        self.assertEqual(expected["cursorUTF16"], 1)
        self.assertEqual(expected["selected"], "")

    def test_sensitive_context_never_retains_document_text(self):
        self.assertIsNone(surrounding_context("secret", 3, 3, can_replace=True, sensitive=True))
        self.assertIsNone(surrounding_context("short", 99, 0, can_replace=True, sensitive=False))


if __name__ == "__main__":
    unittest.main()
