"""Keep recovered text and original key replies in the captured input context."""
import pathlib
import sys
from types import MethodType, SimpleNamespace
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from azookey.reconversion import surrounding_context
from reconversion_fixture import ReconversionFixture
from test_input_coordinator import ManualWorker


HOME = (0xFF50, 102, 4)
LETTER = (ord("a"), 38, 0)


class ReconversionEngineTests(ReconversionFixture, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import gi
            gi.require_version("Gdk", "3.0")
            gi.require_version("IBus", "1.0")
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        from azookey import engine
        cls.engine_module = engine

    def setUp(self):
        super().setUp()
        self.prepare()
        self.acknowledge()
        self.application_effects = []
        self.engine = SimpleNamespace(
            reconversion=self.coordinator, input=self.inputs,
            focused=True, private=False, destroyed=False,
            lookup_announcements=Mock(), ai_review=Mock(),
            pending_settings_stamp=None, snapshot={}, anchor=Mock(),
            update_preedit_text_with_mode=Mock(), panel=Mock(),
            hide_preedit_text=Mock(), hide_lookup_table=Mock(),
            show_reconversion_status=Mock(), reconversion_context=self.document,
            commit_text=self.commit_original,
        )
        for name in ("prepare_composition_recovery", "clear_reconversion", "do_focus_out"):
            setattr(self.engine, name, MethodType(getattr(self.engine_module.Engine, name), self.engine))
        self.inputs.recover = self.engine.prepare_composition_recovery
        self.surface_patch = patch.object(self.engine_module, "surface", return_value=Mock())
        self.surface_patch.start()
        self.addCleanup(self.surface_patch.stop)
        for key in (HOME, LETTER):
            reply = NativeKeyReply(
                lambda consumed, key=key: self.application_effects.append(("reply", key, consumed)),
            )
            self.coordinator.process(translate(key[0], key[2]), key, key_reply=reply)
        self.application_effects.clear()

    def commit_original(self, text):
        self.application_effects.append(("commit", text.get_text()))
        # Restoring the original changes the cursor legitimately. Later keys
        # still belong to this context and must follow that single commit.
        self.document = surrounding_context(
            "前日本語後", 4, 4, can_replace=True, sensitive=False,
        )

    def finish_recovery(self):
        complete = self.engine.prepare_composition_recovery("日本語")
        complete()
        complete()

    def assert_recovery_was_discarded(self):
        self.finish_recovery()
        self.assertEqual(self.application_effects, [
            ("reply", HOME, True), ("reply", LETTER, True),
        ])

    def test_original_is_restored_once_before_each_native_key_in_the_same_context(self):
        self.finish_recovery()
        self.assertEqual(self.application_effects, [
            ("commit", "日本語"), ("reply", HOME, False), ("reply", LETTER, False),
        ])

    def test_focus_out_and_another_focused_field_reject_the_recovered_original(self):
        def change_field():
            self.engine.do_focus_out()
            self.document = surrounding_context(
                "別の入力欄", 0, 0, can_replace=True, sensitive=False,
            )
            self.engine.focused = True

        self.engine.hide_preedit_text.side_effect = change_field
        self.assert_recovery_was_discarded()

    def test_refocusing_an_identical_document_does_not_revive_the_original_request(self):
        def leave_and_return():
            self.engine.do_focus_out()
            self.engine.focused = True

        self.engine.hide_preedit_text.side_effect = leave_and_return
        self.assert_recovery_was_discarded()

    def test_changed_text_without_a_focus_notification_rejects_the_recovered_original(self):
        def change_text():
            self.document = surrounding_context(
                "別後", 1, 1, can_replace=True, sensitive=False,
            )

        self.engine.hide_preedit_text.side_effect = change_text
        self.assert_recovery_was_discarded()

    def test_changed_selection_without_a_focus_notification_rejects_the_recovered_original(self):
        def change_selection():
            self.document = surrounding_context(
                "前後", 1, 0, can_replace=True, sensitive=False,
            )

        self.engine.hide_preedit_text.side_effect = change_selection
        self.assert_recovery_was_discarded()

    def test_canceling_while_dismissing_the_popup_discards_text_and_finishes_calls_once(self):
        self.engine.panel.dismiss.side_effect = self.coordinator.cancel
        self.assert_recovery_was_discarded()


class InputRecoveryReentryTests(unittest.TestCase):
    def test_restarted_reply_does_not_publish_old_text_after_recovery_cancels_its_context(self):
        worker = ManualWorker()
        published = []
        replies = []
        recovered = []
        completions = []

        def recover(text):
            recovered.append(text)
            inputs.cancel()
            return lambda: completions.append("finished")

        inputs = InputCoordinator(
            worker, "old-field", render=published.append, forward=Mock(),
            recover=recover, preview=Mock(),
        )
        inputs.snapshot = {"preedit": "元の入力", "inputState": "composing"}
        reply = NativeKeyReply(replies.append)
        inputs.submit(
            "key", key=LETTER, key_reply=reply.defer(),
            payload={"event": translate(ord("a"), 0)},
        )
        worker.respond(0, {
            "consumed": True, "commits": ["古い確定"], "preedit": "古い未確定",
            "inputState": "composing",
        }, generation=1)
        self.assertEqual(published, [])
        self.assertEqual(recovered, ["元の入力"])
        self.assertEqual(replies, [True])
        self.assertEqual(completions, ["finished"])
        reply.finish(False)
        self.assertEqual(replies, [True])


if __name__ == "__main__":
    unittest.main()
