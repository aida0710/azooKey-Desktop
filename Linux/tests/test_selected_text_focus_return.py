"""Native focus return can be verified without a repeated surrounding message."""
from dataclasses import replace
from types import SimpleNamespace
from unittest import mock

from test_ai_transform_target import accessible_fixture
from test_selected_text_transform import SelectedTextTransformationFixture


class SelectedTextFocusReturnTests(SelectedTextTransformationFixture):
    def setUp(self):
        super().setUp()
        from azookey.engine import Engine
        from gi.repository import IBus
        self.engine.focused = True
        self.engine.focus_identity = self.selection.context_id
        self.engine.transform_selection = self.selection
        self.engine.has_transform_surrounding_update = True
        self.engine.client_capabilities = IBus.Capabilite.SURROUNDING_TEXT
        self.engine.anchor = SimpleNamespace(update=lambda *_: None)
        self.engine.reload_settings = lambda: None
        self.engine.register_properties = lambda _: None
        self.engine.transformation = self.session
        self.engine.activate_input_context = lambda: Engine.activate_input_context(self.engine)
        self.engine.do_focus_out = lambda: Engine.do_focus_out(self.engine)
        self.engine.current_transform_selection = lambda: Engine.current_transform_selection(self.engine)
        self.engine.current_transform_context = lambda: Engine.current_transform_context(self.engine)

    def begin_application(self):
        from gi.repository import Gtk
        self.engine.focus_identity = self.selection.context_id
        self.engine.transform_selection = self.selection
        self.engine.has_transform_surrounding_update = True
        self.generated_preview()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.assertIsNotNone(self.session.pending)
        self.assertEqual(self.inspections, [])

    def focus_original(self):
        from azookey.engine import Engine
        Engine.do_focus_in_id(self.engine, *self.selection.context_id)

    def test_native_focus_return_with_no_surrounding_message_verifies_fresh_target_and_applies_once(self):
        self.begin_application()
        self.focus_original()
        self.assertIsNone(self.engine.current_transform_selection(), "old surrounding text must stay unavailable")
        self.assertEqual(len(self.inspections), 1, "native focus return must start a fresh accessibility read")
        verified = self.inspections.pop()
        verified(accessible_fixture())
        verified(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def publish_surrounding(self, content="前 原文 後", *, cursor=4, anchor=2):
        from azookey.engine import Engine
        from gi.repository import IBus
        self.engine.reconversion = SimpleNamespace(surrounding_changed=lambda: None)
        with mock.patch.object(IBus.Engine, "do_set_surrounding_text"):
            Engine.do_set_surrounding_text(self.engine, IBus.Text.new_from_string(content), cursor, anchor)

    def test_missing_native_context_or_focus_never_uses_the_previous_selection(self):
        from azookey.engine import Engine
        self.begin_application()
        Engine.do_focus_in_id(self.engine, "/input/other", "gnome-shell")
        self.assertEqual(self.inspections, [])
        Engine.do_focus_in(self.engine)
        self.assertEqual(self.inspections, [])
        self.session.cancel_timeout()
        self.session.focus_return_expired()
        self.assert_preview_preserved_without_apply()

    def test_same_native_context_with_different_accessible_target_does_not_apply(self):
        original = accessible_fixture()
        for accessible in (
            replace(original, identity=(":1.4", "/field/2")),
            replace(original, identity=(":1.5", "/field/1")),
            replace(original, window_identity=(":1.4", "/window/2")),
            replace(original, bus_id="restarted-bus"),
            replace(original, start=8, end=10),
            replace(original, selected="別文"),
            replace(original, before="別 "), replace(original, after=" 別"),
            None,
        ):
            with self.subTest(accessible=accessible):
                self.begin_application()
                self.focus_original()
                self.inspections.pop()(accessible)
                self.assert_preview_preserved_without_apply()
                self.session.close()

    def test_new_surrounding_selection_and_direction_must_match_during_the_read(self):
        for content, cursor, anchor in (
            ("前 原文 後", 4, 4), ("前 原文 後", 2, 4), ("前 原文 後", 6, 4),
            ("前 別文 後", 4, 2), ("別 原文 後", 4, 2), ("前 原文 別", 4, 2),
        ):
            with self.subTest(content=content, cursor=cursor, anchor=anchor):
                self.begin_application()
                self.focus_original()
                verified = self.inspections.pop()
                self.publish_surrounding(content, cursor=cursor, anchor=anchor)
                self.assertTrue(self.engine.has_transform_surrounding_update)
                # Returning to the old selection cannot resurrect a permission
                # that a known new notification already invalidated.
                self.publish_surrounding()
                verified(accessible_fixture())
                self.assert_preview_preserved_without_apply()
                self.session.close()

    def test_matching_new_surrounding_message_during_read_still_requires_fresh_accessibility(self):
        self.begin_application()
        self.focus_original()
        verified = self.inspections.pop()
        self.publish_surrounding()
        self.assertEqual(self.commits, [])
        self.assertEqual(self.inspections, [], "a surrounding update must not start a second concurrent read")
        verified(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])

    def test_focus_changes_during_read_reject_the_previous_accessible_reply(self):
        from azookey.engine import Engine
        for context_id in (self.selection.context_id, ("/input/other", "gnome-shell")):
            with self.subTest(context_id=context_id):
                self.begin_application()
                self.focus_original()
                verified = self.inspections.pop()
                Engine.do_focus_in_id(self.engine, *context_id)
                verified(accessible_fixture())
                self.assert_preview_preserved_without_apply()
                self.session.close()

    def test_reset_after_native_return_cancels_a_pending_accessibility_read(self):
        self.begin_application()
        self.focus_original()
        verified = self.inspections.pop()
        self.reset_input()
        verified(accessible_fixture())
        self.assert_preview_preserved_without_apply()

    def test_native_focus_out_during_read_never_applies_the_old_reply(self):
        from azookey.engine import Engine
        self.begin_application()
        self.focus_original()
        verified = self.inspections.pop()
        self.engine.lookup_announcements = SimpleNamespace(reset=lambda: None)
        self.engine.ai_review = SimpleNamespace(cancel=lambda: None)
        self.engine.clear_reconversion = lambda: None
        self.engine.input.cancel = lambda: setattr(self.engine.input, "cancelled", object())
        self.engine.panel = SimpleNamespace(dismiss=lambda: None)
        with mock.patch("azookey.engine.surface"):
            Engine.do_focus_out_id(self.engine, self.selection.context_id[0])
        verified(accessible_fixture())
        self.assert_preview_preserved_without_apply()

    def test_private_notification_during_read_cannot_apply_a_successful_accessibility_reply(self):
        from azookey.engine import Engine
        from gi.repository import IBus
        self.begin_application()
        self.focus_original()
        verified = self.inspections.pop()
        self.engine.ai_review = SimpleNamespace(cancel=lambda: None)
        self.engine.clear_reconversion = lambda: None
        Engine.do_set_content_type(self.engine, IBus.InputPurpose.FREE_FORM, IBus.InputHints.PRIVATE)
        verified(accessible_fixture())
        self.assert_preview_preserved_without_apply()

    def test_dismissal_during_read_does_not_restore_or_apply_the_old_preview(self):
        self.begin_application()
        self.focus_original()
        verified = self.inspections.pop()
        self.session.close()
        verified(accessible_fixture())
        self.assertEqual(self.commits, [])
        self.assertIsNone(self.session.dialog)
