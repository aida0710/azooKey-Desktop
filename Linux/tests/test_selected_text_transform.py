"""The prompt retains generated text when Core cannot verify its original target."""
import os
import pathlib
import sys
from types import SimpleNamespace
import unittest
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from ai_core_fixture import CoreAITestCase, CoreWorker, field_fixture, witness_fixture


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class SelectedTextTransformationFixture(CoreAITestCase):
    """The real Core decides; the engine, provider and AT-SPI reads are fixtures."""

    def setUp(self):
        from azookey.ai_bridge import AIBridge
        from azookey.selected_text_transform import SelectedTextTransformation
        self.field = field_fixture()
        self.commits, self.inspections, self.requests = [], [], []
        self.worker = CoreWorker(self.bridge)
        self.engine = SimpleNamespace(
            sensitive=False, snapshot={}, focus_revision=object(), selected_text="原文",
            input=SimpleNamespace(cancelled=object(), generation=0),
            ai=AIBridge(self.worker, f"fixture-{uuid.uuid4()}"),
            ai_field=self.current_field, has_fresh_selection=self.has_fresh_selection,
            save_ai_context=lambda _: True,
            start_ai=lambda snapshot, request, **values: self.requests.append({"request": request, **values}),
            get_surrounding_text=lambda: None,
            commit_text=lambda text: self.commits.append(text.get_text()),
        )
        self.session = SelectedTextTransformation(self.engine)
        self.session.inspect = lambda _context_characters, completion: self.inspections.append(completion)

    def tearDown(self):
        self.session.close()

    def current_field(self):
        if self.field is None:
            return {"identity": None, "surrounding": None, "hasSurroundingUpdate": False, "isSensitive": self.engine.sensitive}
        return {**self.field, "isSensitive": self.engine.sensitive}

    def has_fresh_selection(self):
        field = self.current_field()
        return bool(field["identity"] and field["hasSurroundingUpdate"] and not field["isSensitive"])

    def generated_preview(self, captured=None):
        self.session.show("敬語に直す")
        self.inspections.pop(0)(captured or witness_fixture())
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
        verified(witness_fixture())
        verified(witness_fixture())
        self.assertEqual(self.commits, ["新しい本文"])
        self.assertFalse(self.session.active)
        self.assertIsNone(self.session.dialog)

    def test_identical_text_in_another_field_of_a_shared_ibus_context_does_not_apply(self):
        self.generated_preview()
        self.begin_apply()
        self.inspections.pop()(witness_fixture(object=["fixture-bus", ":1.4", "/field/2"]))
        self.assert_preview_preserved_without_apply()

    def test_selection_moved_inside_the_same_object_does_not_apply(self):
        self.generated_preview()
        self.begin_apply()
        self.inspections.pop()(witness_fixture(start=8, end=10))
        self.assert_preview_preserved_without_apply()

    def test_changed_ibus_context_is_rejected_before_an_accessibility_read(self):
        self.generated_preview()
        self.field = field_fixture(identity=("/input/2", "gtk3-im:fixture"))
        self.begin_apply()
        self.assertEqual(self.inspections, [])
        self.assert_preview_preserved_without_apply()

    def test_focus_change_during_verification_never_applies_the_late_read(self):
        self.generated_preview()
        self.begin_apply()
        self.engine.focus_revision = object()
        self.inspections.pop()(witness_fixture())
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
                callback(witness_fixture())
                self.assert_preview_preserved_without_apply()
                self.session.close()
                self.engine.sensitive = False

    def test_reset_before_delayed_surrounding_text_cannot_resume_application(self):
        from gi.repository import Gtk
        self.generated_preview()
        self.session.respond(self.session.dialog, Gtk.ResponseType.OK)
        self.field = None
        self.engine.focus_revision = object()
        self.reset_input()
        self.field = field_fixture()
        self.session.context_changed()
        self.assertEqual(self.inspections, [])
        self.assert_preview_preserved_without_apply()

    def test_focus_in_clears_cached_surrounding_text_before_verification(self):
        from azookey.engine import Engine
        from gi.repository import IBus
        engine = SimpleNamespace(
            focused=False, sensitive=False, focus_revision=object(), selected_text="原文",
            surrounding=field_fixture()["surrounding"],
            focus_identity=("/input/1", "gnome-shell"), has_transform_surrounding_update=True,
            client_capabilities=IBus.Capabilite.SURROUNDING_TEXT,
            anchor=SimpleNamespace(update=lambda *_: None),
            reload_settings=lambda: None, get_surrounding_text=lambda: None,
            register_properties=lambda _: None,
            transformation=SimpleNamespace(focus_entered=lambda: None),
        )
        engine.ai_field = lambda: Engine.ai_field(engine)
        Engine.activate_input_context(engine)
        self.assertTrue(engine.focused)
        self.assertFalse(Engine.ai_field(engine)["hasSurroundingUpdate"])
        self.assertFalse(Engine.has_fresh_selection(engine))

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
        self.field = field_fixture(identity=None)
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
                callback(witness_fixture())
                self.assertIsNone(self.session.dialog)
                self.assertFalse(self.session.active)
                self.assertEqual(self.commits, [])

    def test_sensitive_or_empty_selection_opens_no_prompt(self):
        for sensitive, field in ((True, field_fixture()), (False, field_fixture(cursor=4, anchor=4))):
            with self.subTest(sensitive=sensitive):
                self.engine.sensitive, self.field = sensitive, field
                self.session.show("敬語に直す")
                self.assertIsNone(self.session.dialog)
                self.assertFalse(self.session.active)
                self.assertEqual(self.inspections, [])


if __name__ == "__main__":
    unittest.main()
