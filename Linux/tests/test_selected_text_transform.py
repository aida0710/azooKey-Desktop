"""The prompt retains generated text when its original target cannot be verified."""
from dataclasses import replace
import os
import pathlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from test_ai_scope import scope_fixture
from test_ai_transform_target import accessible_fixture, selection_fixture


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class SelectedTextTransformationFixture(unittest.TestCase):
    def setUp(self):
        from azookey.ai_transform_target import FocusedInputContext
        from azookey.selected_text_transform import SelectedTextTransformation
        self.directory = tempfile.TemporaryDirectory()
        self.config = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.directory.name})
        self.config.start()
        self.selection = selection_fixture()
        self.commits, self.inspections, self.requests = [], [], []
        self.engine = SimpleNamespace(
            selected_text=self.selection.selected, sensitive=False, snapshot={},
            focus_revision=object(),
            input=SimpleNamespace(cancelled=object()),
            current_transform_selection=lambda: None if self.engine.sensitive else self.selection,
            current_transform_context=lambda: None if self.engine.sensitive or self.selection is None else
                FocusedInputContext(context_id=self.selection.context_id, selection=self.selection,
                                    has_surrounding_update=True),
            make_ai_scope=lambda _: scope_fixture(), save_ai_context=lambda _: True,
            start_ai=lambda snapshot, scope, **values: self.requests.append(values),
            get_surrounding_text=lambda: None,
            commit_text=lambda text: self.commits.append(text.get_text()),
        )
        self.session = SelectedTextTransformation(self.engine)
        self.session.inspect = lambda selection, completion: self.inspections.append(completion)

    def tearDown(self):
        self.session.close()
        self.config.stop()
        self.directory.cleanup()

    def generated_preview(self, captured=None):
        self.session.show("敬語に直す")
        self.inspections.pop(0)(captured or accessible_fixture())
        self.session.dialog.entry.emit("activate")
        self.requests.pop()["completion"]("新しい本文")
        # The prompt has its own focus-out/in notifications.
        self.engine.focus_revision = object()
        self.assertEqual(self.session.dialog.result, "新しい本文")

    def begin_apply(self):
        from gi.repository import Gtk
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.assertFalse(self.session.dialog.get_visible())
        self.session.context_changed()
        self.assertEqual(self.inspections, [], "hiding a prompt alone does not prove focus returned")
        self.engine.focus_revision = object()
        self.session.context_changed()

    def assert_preview_preserved_without_apply(self):
        from gi.repository import Gtk
        from azookey.i18n import text
        self.assertEqual(self.commits, [])
        self.assertEqual(self.session.dialog.result, "新しい本文")
        self.assertTrue(self.session.dialog.get_visible())
        self.assertTrue(self.session.dialog.copy_button.get_sensitive())
        self.assertFalse(self.session.dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
        self.assertEqual(self.session.dialog.target_message.get_text(), text("ai.preview.target-changed"))

    def reset_input(self):
        from azookey.engine import Engine
        self.engine.ai_review = SimpleNamespace(cancel=lambda: None)
        self.engine.transformation = self.session
        self.engine.clear_reconversion = lambda: None
        self.engine.recover_composition = lambda: None
        self.engine.input.cancel = lambda: setattr(self.engine.input, "cancelled", object())
        Engine.do_reset(self.engine)


class SelectedTextTransformationTests(SelectedTextTransformationFixture):
    def test_original_target_after_prompt_focus_return_applies_exactly_once(self):
        self.generated_preview()
        self.begin_apply()
        verified = self.inspections.pop()
        verified(accessible_fixture())
        verified(accessible_fixture())
        self.assertEqual(self.commits, ["新しい本文"])
        self.assertFalse(self.session.active)
        self.assertIsNone(self.session.dialog)

    def test_identical_text_in_another_field_of_a_shared_ibus_context_does_not_apply(self):
        self.generated_preview()
        self.begin_apply()
        self.inspections.pop()(replace(accessible_fixture(), identity=(":1.4", "/field/2")))
        self.assert_preview_preserved_without_apply()

    def test_selection_moved_inside_the_same_object_does_not_apply(self):
        self.generated_preview()
        self.begin_apply()
        self.inspections.pop()(replace(accessible_fixture(), start=8, end=10))
        self.assert_preview_preserved_without_apply()

    def test_changed_ibus_context_is_rejected_before_an_accessibility_read(self):
        self.generated_preview()
        self.selection = replace(self.selection, context_id=("/input/2", "gtk3-im:fixture"))
        self.begin_apply()
        self.assertEqual(self.inspections, [])
        self.assert_preview_preserved_without_apply()

    def test_focus_change_during_verification_never_applies_the_late_read(self):
        self.generated_preview()
        self.begin_apply()
        self.engine.focus_revision = object()
        self.inspections.pop()(accessible_fixture())
        self.assert_preview_preserved_without_apply()

    def test_private_input_or_new_typing_cancels_an_inflight_application(self):
        for cancellation in ("private", "typing"):
            with self.subTest(cancellation=cancellation):
                self.generated_preview()
                self.begin_apply()
                callback = self.inspections.pop()
                if cancellation == "private":
                    self.engine.sensitive = True
                    self.session.invalidate_target()
                else:
                    self.session.input_changed()
                callback(accessible_fixture())
                self.assert_preview_preserved_without_apply()
                self.session.close()
                self.engine.sensitive = False

    def test_reset_before_delayed_surrounding_text_cannot_resume_application(self):
        from gi.repository import Gtk
        self.generated_preview()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.selection = None
        self.engine.focus_revision = object()
        self.reset_input()
        self.selection = selection_fixture()
        self.session.context_changed()
        self.assertEqual(self.inspections, [])
        self.assert_preview_preserved_without_apply()

    def test_focus_in_clears_cached_surrounding_text_before_verification(self):
        from azookey.engine import Engine
        from gi.repository import IBus
        engine = SimpleNamespace(
            focused=False, sensitive=False, focus_revision=object(),
            transform_selection=selection_fixture(),
            focus_identity=selection_fixture().context_id, has_transform_surrounding_update=True,
            client_capabilities=IBus.Capabilite.SURROUNDING_TEXT,
            anchor=SimpleNamespace(update=lambda *_: None),
            reload_settings=lambda: None, get_surrounding_text=lambda: None,
            register_properties=lambda _: None,
            transformation=SimpleNamespace(focus_entered=lambda: None),
        )
        engine.current_transform_context = lambda: Engine.current_transform_context(engine)
        Engine.activate_input_context(engine)
        self.assertTrue(engine.focused)
        self.assertIsNone(Engine.current_transform_selection(engine))

    def test_missing_accessibility_keeps_results_and_copies_only_on_explicit_action(self):
        from gi.repository import Gdk, Gtk
        clipboard = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
        clipboard.set_text("既存のコピー", -1)
        self.session.show("敬語に直す")
        self.inspections.pop()(None)
        self.session.dialog.entry.emit("activate")
        self.requests.pop()["completion"]("新しい本文")
        self.assert_preview_preserved_without_apply()
        self.assertEqual(clipboard.wait_for_text(), "既存のコピー")
        self.session.dialog.copy_button.emit("clicked")
        self.assertEqual(clipboard.wait_for_text(), "新しい本文")

    def test_missing_context_identity_still_offers_a_copyable_preview(self):
        self.selection = None
        self.session.show("敬語に直す")
        self.assertEqual(self.inspections, [])
        self.session.dialog.entry.emit("activate")
        self.requests.pop()["completion"]("新しい本文")
        self.assert_preview_preserved_without_apply()

    def test_focus_return_expiry_preserves_result_without_granting_apply(self):
        from gi.repository import Gtk
        self.generated_preview()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.session.cancel_timeout()
        self.session.focus_return_expired()
        self.assert_preview_preserved_without_apply()

    def test_cancel_or_private_focus_while_capturing_does_not_open_a_late_dialog(self):
        for cancellation in ("cancel", "private", "focus"):
            with self.subTest(cancellation=cancellation):
                self.session.show("敬語に直す")
                callback = self.inspections.pop()
                if cancellation == "cancel":
                    self.session.close()
                elif cancellation == "private":
                    self.session.invalidate_target()
                else:
                    self.engine.focus_revision = object()
                callback(accessible_fixture())
                self.assertIsNone(self.session.dialog)
                self.assertFalse(self.session.active)
                self.assertEqual(self.commits, [])


if __name__ == "__main__":
    unittest.main()
