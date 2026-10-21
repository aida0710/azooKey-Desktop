"""Toolkit notification callbacks cannot retain or overwrite a retired field."""
from types import MethodType, SimpleNamespace
import unittest

try:
    import gi
    gi.require_version("IBus", "1.0")
    from gi.repository import IBus
    from azookey.reading_engine import ReadingEngine
    from azookey.reading_reconversion_adapter import ReadingReconversionAdapter
except (ImportError, ValueError):
    ReadingEngine = None

from azookey.native_key_reply import NativeKeyReply
from candidate_fixture import WAIT_SECONDS
import test_reading_reconversion as reconversion_tests


class ObservedInputField:
    def __init__(self, trial):
        self.frontend = trial.frontend
        self.effects = trial.effects
        self.sensitive = self.private = self.destroyed = False
        self.client_capabilities = IBus.Capabilite.SURROUNDING_TEXT
        self.focus_identity = ("original", "test-client")
        self.left, self.right = "前", "後"
        self.context_changed = False
        self.last_language_key = (None, 0)
        self.on_status = None
        self.on_commit = None
        self.on_preedit = None
        self.fail_status = False
        self.renderer = SimpleNamespace(dismiss=lambda: None, close=lambda: None, input_changed=lambda _snapshot: None)
        for name in ("activate", "do_focus_out", "do_reset", "do_set_content_type",
                     "close_worker", "surroundings"):
            setattr(self, name, MethodType(getattr(ReadingEngine, name), self))

    @property
    def focused(self):
        return self.frontend.focused

    def update_auxiliary_text(self, text, visible):
        self.effects.append(("auxiliary", text.get_text(), visible))
        if self.on_status:
            self.on_status()
        if self.fail_status:
            raise OSError("synthetic auxiliary display failure")

    def update_preedit_text_with_mode(self, text, *_):
        self.effects.append(("recovery-preedit", text.get_text()))
        if self.on_preedit:
            self.on_preedit()

    def commit_text(self, text):
        self.effects.append(("commit", text.get_text()))
        if self.on_commit:
            self.on_commit()

    def delete_surrounding_text(self, offset, count):
        self.effects.append(("delete", offset, count))

    def forward_key_event(self, *key):
        self.effects.append(("forward", key))

    def get_surrounding_text(self):
        return None

    def register_properties(self, _properties):
        pass


@unittest.skipIf(ReadingEngine is None, "requires IBus and GTK Python bindings")
class ReadingReconversionAdapterTests(unittest.TestCase):
    def setUp(self):
        self.trial = reconversion_tests.ReadingReconversionTests(
            "test_each_key_retains_the_same_document_context_for_the_short_commit_history")
        self.trial.setUp()
        self.addCleanup(self.trial.doCleanups)
        self.engine = ObservedInputField(self.trial)
        self.adapter = ReadingReconversionAdapter(
            self.engine, schedule_timeout=self.trial.schedule, remove_timeout=self.trial.timers.pop,
        )
        self.engine.reconversion = self.adapter
        self.adapter.document = self.trial.document
        self.trial.reconversion = self.adapter.coordinator
        self.trial.inputs = self.adapter.input

    def next_field(self):
        self.engine.on_status = None
        self.engine.do_focus_out()
        self.engine.activate(("next", "test-client"))
        self.adapter.surrounding_changed("次", 1, 1)

    def pending_resolution(self):
        gate = self.trial.candidate.gate("resolve-reconversion-reading")
        self.trial.native(reconversion_tests.START)
        self.trial.drain_until(lambda: not self.trial.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.trial.native(reconversion_tests.ENTER)
        return gate

    def test_failed_status_cannot_leave_a_departed_field_or_original_key_pending(self):
        gate = self.pending_resolution()
        self.engine.fail_status = True
        with self.assertLogs("azookey.reading_reconversion_adapter", level="ERROR"):
            self.engine.do_focus_out()
        gate.proceed.set()
        self.trial.drain_until(lambda: not self.trial.frontend.pending)
        self.assertFalse(self.engine.focused)
        self.assertIsNone(self.engine.focus_identity)
        self.assertEqual([effect for effect in self.trial.effects if effect[0] == "reply"], [
            ("reply", reconversion_tests.START, True), ("reply", reconversion_tests.ENTER, True),
        ])
        self.assertTrue(any(name == "focus-out" for name, _ in self.trial.reader.calls))

    def test_failed_status_still_applies_private_content_before_further_input(self):
        self.engine.fail_status = True
        with self.assertLogs("azookey.reading_reconversion_adapter", level="ERROR"):
            self.engine.do_set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
        frontend = self.trial.frontend
        self.trial.drain_until(lambda: not frontend.pending and frontend.reference is not None)
        self.assertTrue(self.engine.sensitive)
        self.assertTrue(frontend.surroundings["privateInput"])
        self.assertTrue(frontend.coordinator._contexts[frontend.context].private_input)

    def test_focus_out_notification_cannot_retire_the_field_it_just_activated(self):
        self.engine.on_status = self.next_field
        self.engine.do_focus_out()
        self.assertTrue(self.engine.focused)
        self.assertEqual(self.engine.focus_identity, ("next", "test-client"))
        self.assertEqual(self.adapter.document["before"], "次")

    def test_reset_notification_cannot_reset_the_field_it_just_activated(self):
        self.engine.on_status = self.next_field
        self.engine.do_reset()
        self.assertTrue(self.engine.focused)
        self.assertEqual(self.engine.focus_identity, ("next", "test-client"))
        self.assertEqual(self.adapter.document["before"], "次")
        self.assertFalse(any(owner.operation == "reset" for owner in self.trial.frontend.pending))

    def test_retired_start_reply_cannot_erase_new_document_or_new_reconversion_owner(self):
        def completed(consumed):
            self.trial.effects.append(("reply", reconversion_tests.START, consumed))
            self.next_field()
            self.new_epoch = self.adapter.input.epoch
        gate = self.trial.candidate.gate("resolve-reconversion-reading")
        self.trial.dispatch(reconversion_tests.START, NativeKeyReply(completed))
        self.trial.drain_until(lambda: not self.trial.frontend.pending)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.trial.native(reconversion_tests.ENTER)
        self.adapter.clear()
        gate.proceed.set()
        self.assertTrue(self.engine.focused)
        self.assertIs(self.adapter.input.epoch, self.new_epoch)
        self.assertEqual(self.adapter.document["before"], "次")
        self.assertEqual([effect for effect in self.trial.effects if effect[0] == "reply"], [
            ("reply", reconversion_tests.START, True), ("reply", reconversion_tests.ENTER, True),
        ])

    def test_privacy_reset_view_cannot_replace_a_new_focus_created_during_its_display(self):
        self.trial.frontend.render_input = lambda _snapshot: self.next_field()
        self.engine.do_set_content_type(IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
        self.assertTrue(self.engine.focused)
        self.assertEqual(self.engine.focus_identity, ("next", "test-client"))
        self.assertTrue(self.trial.frontend.surroundings["privateInput"])
        self.assertIsNone(self.adapter.document)

    def test_failed_status_during_close_still_closes_both_workers(self):
        self.engine.fail_status = True
        with self.assertLogs("azookey.reading_reconversion_adapter", level="ERROR"):
            self.engine.close_worker()
        self.assertTrue(self.trial.frontend.closed)

    def test_rejected_partial_commit_explains_the_whole_selection_and_next_input_clears_it(self):
        snapshot = {"preedit": "にほんご", "cursor": 4, "commits": [], "inputState": "composing",
                    "reconversionError": "whole_selection_required"}
        ReadingEngine.render_input(self.engine, snapshot)
        self.assertIn(("auxiliary", "選択範囲全体の候補を選んでください", True), self.trial.effects)
        del snapshot["reconversionError"]
        ReadingEngine.render_input(self.engine, snapshot)
        self.assertEqual(self.trial.effects[-1], ("auxiliary", "", False))
        self.assertEqual([effect[1] for effect in self.trial.effects if effect[0] == "recovery-preedit"],
                         ["にほんご", "にほんご"])
        self.assertFalse(any(effect[0] == "commit" for effect in self.trial.effects))

    def test_input_callback_focus_change_keeps_later_text_and_status_out_of_the_new_field(self):
        for stage in ("commit", "candidate-view", "preedit"):
            with self.subTest(stage=stage):
                self.trial.effects.clear()
                views = []

                def activate_next_field():
                    self.engine.on_commit = self.engine.on_preedit = None
                    self.next_field()
                    self.adapter.status("新しい欄の通知")

                def publish_view(snapshot):
                    views.append(snapshot)
                    if stage == "candidate-view":
                        activate_next_field()

                self.engine.renderer.input_changed = publish_view
                self.engine.on_commit = activate_next_field if stage == "commit" else None
                self.engine.on_preedit = activate_next_field if stage == "preedit" else None
                snapshot = {"preedit": "にほんご", "cursor": 4, "commits": ["日本語"],
                            "inputState": "composing", "reconversionError": "whole_selection_required"}
                ReadingEngine.render_input(self.engine, snapshot)
                self.assertEqual(self.engine.focus_identity, ("next", "test-client"))
                self.assertEqual(self.trial.effects[-1], ("auxiliary", "新しい欄の通知", True))
                self.assertFalse(self.adapter.input_error_visible)
                preedits = [effect for effect in self.trial.effects if effect[0] == "recovery-preedit"]
                self.assertEqual(preedits, [("recovery-preedit", "にほんご")] if stage == "preedit" else [])
                if stage == "commit":
                    self.assertEqual(views, [])


if __name__ == "__main__":
    unittest.main()
