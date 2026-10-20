"""Reset during the prompt's own focus transfer must not discard its target."""
from dataclasses import replace
from unittest import mock

from test_ai_transform_target import accessible_fixture
from test_selected_text_transform import SelectedTextTransformationFixture


class SelectedTextDialogFocusTests(SelectedTextTransformationFixture):
    def capture_dialog(self):
        self.session.show("敬語に直す")
        self.inspections.pop()(accessible_fixture())
        self.dialog_active = False
        patch = mock.patch.object(self.session.dialog, "is_active", side_effect=lambda: self.dialog_active)
        patch.start()
        self.addCleanup(patch.stop)

    def dialog_focus(self, active):
        self.dialog_active = active
        self.session.dialog.notify("is-active")

    def generate_result(self):
        self.session.dialog.entry.emit("activate")
        self.requests.pop()["completion"]("新しい本文")

    def enter_dialog(self):
        self.engine.focus_revision = object()
        self.dialog_focus(True)

    def return_to_original(self):
        self.engine.focus_revision = object()
        self.session.context_changed()
        verified = self.inspections.pop()
        verified(accessible_fixture())
        verified(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def assert_apply_enabled(self, enabled):
        from gi.repository import Gtk
        self.assertEqual(self.session.dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive(), enabled)

    def test_reset_before_prompt_focus_preserves_the_original_target_for_verified_apply(self):
        self.capture_dialog()
        # Qt's real order is Reset -> FocusOut -> prompt activation.
        self.reset_input()
        self.enter_dialog()
        self.generate_result()
        self.assert_apply_enabled(True)
        self.begin_apply()
        self.inspections.pop()(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def test_prompt_activation_before_outgoing_reset_also_preserves_the_target(self):
        self.capture_dialog()
        self.dialog_focus(True)
        self.reset_input()
        self.enter_dialog()
        self.generate_result()
        self.assert_apply_enabled(True)
        self.begin_apply()
        self.inspections.pop()(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def test_reset_without_prompt_activation_never_grants_apply(self):
        from gi.repository import Gtk
        self.capture_dialog()
        self.reset_input()
        self.generate_result()
        self.assert_apply_enabled(False)
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.enter_dialog()
        self.assert_preview_preserved_without_apply()
        self.assertEqual(self.inspections, [])

    def test_another_editor_reached_before_prompt_activation_rejects_the_target(self):
        self.capture_dialog()
        self.reset_input()
        # Even an identical selection from a shared IBus context is not the
        # prompt's activation acknowledgement.
        self.engine.focus_revision = object()
        self.session.context_changed()
        self.enter_dialog()
        self.generate_result()
        self.assert_preview_preserved_without_apply()

    def test_reset_after_the_prompt_takes_focus_is_not_an_opening_reset(self):
        self.capture_dialog()
        self.enter_dialog()
        self.reset_input()
        self.generate_result()
        self.assert_preview_preserved_without_apply()

    def test_leaving_the_prompt_ends_the_opening_exception_without_ibus_notification(self):
        self.capture_dialog()
        self.dialog_focus(True)
        self.dialog_focus(False)
        self.reset_input()
        self.generate_result()
        self.assert_preview_preserved_without_apply()

    def test_private_input_or_typing_during_opening_cannot_be_reenabled_by_late_focus(self):
        for invalidation in ("private", "typing"):
            with self.subTest(invalidation=invalidation):
                self.capture_dialog()
                self.reset_input()
                if invalidation == "private":
                    self.session.invalidate_target()
                else:
                    self.session.input_changed()
                self.enter_dialog()
                self.generate_result()
                self.assert_preview_preserved_without_apply()
                self.session.close()

    def test_all_original_target_checks_still_apply_after_an_opening_reset(self):
        original = accessible_fixture()
        changed = (
            None,
            replace(original, bus_id="restarted-bus"),
            replace(original, identity=(":1.4", "/other-field")),
            replace(original, window_identity=(":1.4", "/other-window")),
            replace(original, start=8, end=10),
            replace(original, selected="別文"),
            replace(original, before="別 "),
            replace(original, after=" 別"),
        )
        for inspected in changed:
            with self.subTest(inspected=inspected):
                self.capture_dialog()
                self.reset_input()
                self.enter_dialog()
                self.generate_result()
                self.begin_apply()
                self.inspections.pop()(inspected)
                self.assert_preview_preserved_without_apply()
                self.session.close()

    def test_resets_from_the_hidden_prompt_wait_for_verified_return_and_apply_once(self):
        from gi.repository import Gtk
        self.capture_dialog()
        self.enter_dialog()
        self.generate_result()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.dialog_focus(False)
        self.reset_input()
        self.reset_input()
        self.session.context_changed()
        self.assertEqual(self.inspections, [], "the outgoing prompt cannot authorize a replacement")
        self.assertFalse(self.session.dialog.get_visible())
        self.return_to_original()

    def test_hiding_an_inactive_prompt_does_not_exempt_a_reset(self):
        from gi.repository import Gtk
        self.capture_dialog()
        self.enter_dialog()
        self.generate_result()
        self.dialog_focus(False)
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.reset_input()
        self.assert_preview_preserved_without_apply()

    def test_reset_after_return_cancels_even_a_delayed_accessibility_reply(self):
        self.capture_dialog()
        self.enter_dialog()
        self.generate_result()
        self.begin_apply()
        verified = self.inspections.pop()
        self.reset_input()
        verified(accessible_fixture())
        self.assert_preview_preserved_without_apply()

    def test_focus_change_during_read_after_a_prompt_reset_never_applies(self):
        from gi.repository import Gtk
        self.capture_dialog()
        self.enter_dialog()
        self.generate_result()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.reset_input()
        self.engine.focus_revision = object()
        self.session.context_changed()
        verified = self.inspections.pop()
        self.engine.focus_revision = object()
        verified(accessible_fixture())
        self.assert_preview_preserved_without_apply()
