"""A current AI response remains copyable after its input target is lost."""
from unittest import mock

from ai_core_fixture import witness_fixture
from test_selected_text_transform import SelectedTextTransformationFixture


class SelectedTextResultTests(SelectedTextTransformationFixture):
    def setUp(self):
        super().setUp()
        self.engine.destroyed = False
        self.engine.focused = True
        self.engine.ai_pending = False
        self.engine.input.generation = 3
        self.engine.start_ai = self.capture_request
        self.engine.request = mock.Mock()
        self.engine.update_auxiliary_text = mock.Mock()

    def capture_request(self, _snapshot, request, **values):
        values["request"] = request
        values["bridge_generation"] = self.engine.input.generation
        values["focus_epoch"] = self.engine.input.cancelled
        self.requests.append(values)
        self.engine.ai_pending = True

    def begin_request(self):
        if self.session.dialog is None:
            self.session.show("敬語に直す")
            self.inspections.pop()(witness_fixture())
            self.engine.focus_revision = object()
            with mock.patch.object(self.session.dialog, "is_active", return_value=True):
                self.session.dialog.notify("is-active")
        self.session.dialog.entry.emit("activate")
        return self.requests.pop()

    def deliver(self, request, texts=("新しい本文",)):
        from azookey.engine import Engine
        return Engine.finish_ai(
            self.engine, texts, 7, "原文", request["completion"],
            request["bridge_generation"], request["focus_epoch"],
        )

    def test_focus_change_keeps_success_for_explicit_copy_without_presenting_or_applying(self):
        from gi.repository import Gdk, Gtk
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text("既存のコピー", -1)
        request = self.begin_request()
        self.engine.input.cancelled = object()
        dialog = self.session.dialog
        with mock.patch.object(dialog, "present") as present, mock.patch.object(dialog, "show_all") as show:
            self.deliver(request)
        self.assert_preview_preserved_without_apply()
        present.assert_not_called()
        show.assert_not_called()
        self.assertEqual(clipboard.wait_for_text(), "既存のコピー")
        dialog.copy_button.emit("clicked")
        self.assertEqual(clipboard.wait_for_text(), "新しい本文")
        self.engine.request.assert_not_called()

    def test_same_focus_result_still_requires_original_target_verification_and_applies_once(self):
        request = self.begin_request()
        self.deliver(request)
        self.begin_apply()
        verified = self.inspections.pop()
        verified(witness_fixture())
        verified(witness_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def test_reset_or_private_notification_preserves_only_the_current_copyable_result(self):
        from azookey.engine import Engine
        from gi.repository import IBus
        for change in ("reset", "private", "password"):
            with self.subTest(change=change):
                request = self.begin_request()
                # Set up the real input cancellation/notification entry points.
                self.engine.ai_review = mock.Mock()
                self.engine.clear_reconversion = mock.Mock()
                self.engine.recover_composition = mock.Mock()
                self.engine.transformation = self.session
                self.engine.input.cancel = lambda: setattr(self.engine.input, "cancelled", object())
                if change == "reset":
                    Engine.do_reset(self.engine)
                else:
                    purpose = IBus.InputPurpose.PASSWORD if change == "password" else IBus.InputPurpose.FREE_FORM
                    Engine.do_set_content_type(self.engine, purpose, IBus.InputHints.PRIVATE)
                self.deliver(request)
                self.assert_preview_preserved_without_apply()
                self.engine.request.assert_not_called()
                self.session.close()
                self.engine.sensitive = False

    def test_old_prompt_reply_does_not_invalidate_the_current_prompt_target(self):
        from gi.repository import Gtk
        first = self.begin_request()
        dialog = self.session.dialog
        dialog.entry.set_text("新しい指示")
        second = self.begin_request()
        self.engine.input.cancelled = object()
        self.deliver(first, ("古い本文",))
        self.assertIsNone(dialog.result)
        self.assertTrue(self.session.target_available)
        self.assertTrue(dialog.loading)
        # The second request is also affected by the real focus change.
        self.deliver(second)
        self.assert_preview_preserved_without_apply()
        self.assertFalse(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())

    def test_edit_without_resubmission_discards_the_old_result_and_its_target_update(self):
        request = self.begin_request()
        dialog = self.session.dialog
        dialog.entry.set_text("まだ送信しない指示")
        dialog.entry.set_text("敬語に直す")
        self.engine.input.cancelled = object()
        self.deliver(request)
        self.assertIsNone(dialog.result)
        self.assertTrue(self.session.target_available)
        self.assertFalse(dialog.copy_button.get_sensitive())
        self.assertEqual(self.commits, [])

    def test_new_reply_before_old_reply_keeps_the_current_text_and_target(self):
        first = self.begin_request()
        self.session.dialog.entry.set_text("新しい指示")
        second = self.begin_request()
        self.deliver(second)
        self.engine.input.cancelled = object()
        self.deliver(first, ("逆順に届いた本文",))
        self.assertEqual(self.session.dialog.result, "新しい本文")
        self.assertTrue(self.session.target_available)
        self.assertEqual(self.commits, [])

    def test_dismissed_dialog_and_new_session_ignore_a_late_result(self):
        first = self.begin_request()
        previous = self.session.dialog
        self.session.close()
        second = self.begin_request()
        current = self.session.dialog
        self.assertIsNot(previous, current)
        self.deliver(second)
        self.engine.input.cancelled = object()
        self.deliver(first, ("閉じた画面の本文",))
        self.assertEqual(current.result, "新しい本文")
        self.assertTrue(self.session.target_available)
        self.assertEqual(self.commits, [])

    def test_repeated_delivery_cannot_replace_the_accepted_result(self):
        request = self.begin_request()
        self.deliver(request)
        self.engine.input.cancelled = object()
        self.deliver(request, ("二回目の本文",))
        self.assertEqual(self.session.dialog.result, "新しい本文")
        self.assertTrue(self.session.target_available)

    def test_bridge_restart_rejects_even_the_current_successful_response(self):
        request = self.begin_request()
        self.engine.input.generation += 1
        self.deliver(request)
        self.assertIsNone(self.session.dialog.result)
        self.assertFalse(self.session.dialog.copy_button.get_sensitive())
        self.assertEqual(self.commits, [])

    def test_destroyed_engine_does_not_complete_or_show_a_late_result(self):
        request = self.begin_request()
        dialog = self.session.dialog
        self.engine.destroyed = True
        with mock.patch.object(dialog, "present") as present:
            self.deliver(request)
        present.assert_not_called()
        self.assertIsNone(dialog.result)
        self.assertFalse(dialog.copy_button.get_sensitive())
        self.assertEqual(self.commits, [])

    def test_failed_current_response_keeps_the_failure_message_and_has_nothing_to_copy(self):
        from azookey.i18n import text
        request = self.begin_request()
        self.engine.input.cancelled = object()
        self.deliver(request, ())
        self.assertIsNone(self.session.dialog.result)
        self.assertFalse(self.session.dialog.copy_button.get_sensitive())
        self.assertEqual(self.session.dialog.message.get_text(), text("ai.preview.failed"))
        self.assertEqual(self.commits, [])

    def test_composition_suggestions_still_require_the_original_focus_epoch(self):
        from azookey.engine import Engine
        original_epoch = self.engine.input.cancelled
        self.engine.input.cancelled = object()
        Engine.finish_ai(self.engine, ["別欄へ出してはいけない候補"], 7, "原文", None, 3, original_epoch)
        self.engine.request.assert_not_called()
        self.engine.update_auxiliary_text.assert_not_called()
        Engine.finish_ai(self.engine, ["有効な候補"], 7, "原文", None, 3, self.engine.input.cancelled)
        self.engine.request.assert_called_once_with("suggestions", suggestions=["有効な候補"], generation=7, reading="原文")

    def test_private_input_cannot_start_another_request(self):
        from azookey.i18n import text
        self.deliver(self.begin_request())
        self.engine.sensitive = True
        self.session.dialog.entry.emit("activate")
        self.assertEqual(self.requests, [], "Core describes no request from a protected field")
        self.assertIsNone(self.session.dialog.result)
        self.assertEqual(self.session.dialog.message.get_text(), text("ai.preview.failed"))
