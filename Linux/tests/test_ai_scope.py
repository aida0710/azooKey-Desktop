import json
import os
import pathlib
import re
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.ai_scope import AIRequestConfiguration, AIRequestScope, AISuggestionConfirmation, endpoint_host


def scope_fixture():
    return AIRequestScope(
        AIRequestConfiguration(model="fixture-model", endpoint="https://user:password@api.example.invalid:8443/secret?key=private"),
        target="送信する本文", before="PRIVATE_BEFORE", after="PRIVATE_AFTER",
    )


class AIScopeTests(unittest.TestCase):
    def test_destination_does_not_display_url_credentials_or_path(self):
        self.assertEqual(scope_fixture().configuration.destination, "api.example.invalid:8443")
        self.assertEqual(endpoint_host("http://[::1]:8080/private"), "[::1]:8080")
        for invalid in ("file:///secret", "https://user:password@", "https://host:invalid/private", "not a URL"):
            with self.subTest(endpoint=invalid):
                self.assertIsNone(endpoint_host(invalid))

    def test_surrounding_text_is_absent_from_the_off_request(self):
        scope = scope_fixture()
        disabled = scope.bridge_arguments()
        self.assertNotIn("PRIVATE_BEFORE", json.dumps(disabled))
        self.assertNotIn("PRIVATE_AFTER", json.dumps(disabled))
        enabled = scope.with_context(True).bridge_arguments()
        self.assertEqual(enabled["leftContext"], "PRIVATE_BEFORE")
        self.assertEqual(enabled["rightContext"], "PRIVATE_AFTER")
        self.assertEqual(enabled["target"], "送信する本文")
        self.assertFalse(scope.include_context, "changing one request must not mutate a previous snapshot")

    def test_confirmation_is_invalid_after_input_or_focus_changes(self):
        epoch = object()
        confirmation = AISuggestionConfirmation(scope_fixture(), 8, "よみ", epoch, 3)
        snapshot = {"generation": 8, "reading": "よみ"}
        self.assertTrue(confirmation.matches(snapshot, epoch, 3))
        self.assertFalse(confirmation.matches({**snapshot, "generation": 9}, epoch, 3))
        self.assertFalse(confirmation.matches({**snapshot, "reading": "べつ"}, epoch, 3))
        self.assertFalse(confirmation.matches(snapshot, object(), 3))
        self.assertFalse(confirmation.matches(snapshot, epoch, 4))

    def test_review_keyboard_leaves_enter_and_ordinary_input_to_the_engine(self):
        action = AISuggestionConfirmation.keyboard_action
        self.assertEqual(action({"charactersIgnoringModifiers": "s", "modifierFlags": 2}), "send")
        self.assertEqual(action({"charactersIgnoringModifiers": "S", "modifierFlags": 3}), "toggle")
        self.assertEqual(action({"keyCode": 53, "modifierFlags": 0}), "cancel")
        for event in ({"keyCode": 36}, {"charactersIgnoringModifiers": "a"}, {"charactersIgnoringModifiers": "s", "modifierFlags": 4}):
            self.assertIsNone(action(event))

    def test_common_ai_labels_match_macos(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / "Core/Sources/Core/Resources/ja.lproj/Localizable.strings").read_text()
        macos = dict(re.findall(r'^"(ai\.[^"]+)" = "([^"]*)";', source, re.MULTILINE))
        linux = json.loads((root / "Linux/azookey/locales/ja.json").read_text())
        for key in macos:
            self.assertEqual(linux[key], macos[key], key)


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class AIScopeDialogTests(unittest.TestCase):
    def test_enter_while_generating_and_old_replies_cannot_apply_stale_text(self):
        from azookey.prompt_dialog import PromptDialog
        from gi.repository import Gtk
        requests = []
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}):
            dialog = PromptDialog(lambda *arguments: requests.append(arguments), "最初の指示",
                                  scope=scope_fixture(), on_context_changed=lambda _: True)
            try:
                dialog.entry.emit("activate")
                dialog.entry.emit("activate")
                self.assertEqual(len(requests), 1, "pending Enter must not send another request")
                dialog.entry.set_text("新しい指示")
                dialog.entry.emit("activate")
                self.assertEqual(len(requests), 2)
                requests[0][2]("古い本文")
                self.assertIsNone(dialog.result)
                self.assertFalse(dialog.preview_button.get_sensitive())
                requests[1][2]("新しい本文")
                self.assertEqual(dialog.result, "新しい本文")
                dialog.entry.emit("activate")
                self.assertIsNone(dialog.result, "regeneration immediately invalidates the old preview")
                self.assertFalse(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
                requests[2][2](None)
                self.assertIsNone(dialog.result)
            finally:
                dialog.destroy()

    def test_physical_control_key_keeps_review_until_the_send_chord_arrives(self):
        from azookey.engine import Engine
        from azookey.ai_review import AISuggestionReview
        from gi.repository import Gdk
        engine = SimpleNamespace(
            private=False, sensitive=False, focused=True,
            input=SimpleNamespace(recovering=False, pending=[], cancelled=object(), generation=1),
            transformation=SimpleNamespace(input_changed=lambda: None),
            snapshot={"generation": 2, "reading": "よみ"},
        )
        sent = []
        engine.ai_review = AISuggestionReview(
            current_state=lambda: Engine.ai_review_state(engine),
            send=lambda snapshot, scope: sent.append((snapshot, scope)),
            save_context=lambda _: True,
        )
        try:
            engine.ai_review.show(scope_fixture(), engine.snapshot, (0, 0, 0, 0))
            self.assertFalse(Engine.do_process_key_event(engine, Gdk.KEY_Control_L, 0, 0))
            self.assertIsNotNone(engine.ai_review.confirmation)
            self.assertTrue(Engine.do_process_key_event(engine, Gdk.KEY_s, 0, Gdk.ModifierType.CONTROL_MASK))
            self.assertEqual(len(sent), 1)
            self.assertIsNone(engine.ai_review.confirmation)
        finally:
            engine.ai_review.cancel()

    def test_context_choice_preserves_newer_settings_and_does_not_overwrite_a_broken_file(self):
        from azookey.engine import Engine
        from azookey.settings_store import config_path
        from azookey.ai_review import AISuggestionReview
        from azookey.i18n import text as message
        settings = {"includeContext": False, "aiModel": "fixture", "aiEndpoint": "https://example.invalid",
                    "profile": "old profile", "userDictionary": {"items": []}}
        engine = SimpleNamespace(settings=dict(settings), input=SimpleNamespace(settings=dict(settings)))
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}):
            path = config_path()
            path.parent.mkdir()
            path.write_text(json.dumps({**settings, "profile": "new profile"}))
            self.assertTrue(Engine.save_ai_context(engine, True))
            self.assertTrue(json.loads(path.read_text())["includeContext"])
            self.assertEqual(json.loads(path.read_text())["profile"], "new profile")
            self.assertEqual(engine.settings["profile"], "old profile", "unacknowledged conversion settings stay out of input preview")
            engine.settings["includeContext"] = False
            broken = b'{"dictionary": "PRIVATE_ORIGINAL",'
            path.write_bytes(broken)
            snapshot = {"generation": 2, "reading": "よみ"}
            state = {"snapshot": snapshot, "focused": True, "pending_input": False,
                     "input_epoch": object(), "bridge_generation": 1}
            review = AISuggestionReview(current_state=lambda: state, send=lambda *_: None,
                                        save_context=lambda value: Engine.save_ai_context(engine, value))
            try:
                review.show(scope_fixture(), snapshot, (0, 0, 0, 0))
                review.key({"charactersIgnoringModifiers": "s", "modifierFlags": 3})
                self.assertTrue(review.confirmation.scope.include_context, "the choice applies to this request")
                self.assertEqual(review.window.message.get_text(), message("ai.scope.include-error"))
                self.assertEqual(path.read_bytes(), broken)
                self.assertFalse(engine.settings["includeContext"], "a failed save must not become the next request's default")
            finally:
                review.cancel()

    def test_initial_prompt_waits_for_send_and_context_changes_invalidate_preview(self):
        from azookey.prompt_dialog import PromptDialog
        from gi.repository import Gtk
        requests = []
        selections = []
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}):
            dialog = PromptDialog(
                lambda prompt, scope, finish: requests.append((prompt, scope, finish)),
                "敬語に直す", scope=scope_fixture(), on_context_changed=selections.append,
            )
            try:
                dialog.show_all()
                self.assertEqual(requests, [])
                self.assertFalse(dialog.scope_view.context.get_active())
                dialog.scope_view.context.set_active(True)
                dialog.entry.emit("activate")
                self.assertEqual(len(requests), 1)
                self.assertTrue(requests[0][1].include_context)
                requests[0][2]("変換した本文")
                self.assertEqual(dialog.result, "変換した本文")
                dialog.scope_view.context.set_active(False)
                self.assertEqual(selections, [True, False])
                self.assertIsNone(dialog.result)
                self.assertFalse(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
                dialog.entry.emit("activate")
                self.assertFalse(requests[1][1].include_context)
                requests[1][2](None)
                self.assertIsNone(dialog.result)
            finally:
                dialog.destroy()

    def test_confirmation_window_requests_no_keyboard_focus(self):
        from azookey.ai_confirmation import AISuggestionConfirmationWindow
        window = AISuggestionConfirmationWindow(
            scope_fixture(), on_send=lambda: None, on_cancel=lambda: None, on_context_changed=lambda _: None,
        )
        try:
            self.assertFalse(window.get_accept_focus())
            self.assertFalse(window.get_focus_on_map())
        finally:
            window.destroy()

    def test_review_sends_only_after_confirmation_and_rejects_a_changed_input(self):
        from azookey.ai_review import AISuggestionReview
        epoch = object()
        snapshot = {"generation": 2, "reading": "よみ"}
        state = {
            "snapshot": snapshot, "input_epoch": epoch, "bridge_generation": 1,
            "focused": True, "pending_input": False,
        }
        sent = []
        settings = []
        review = AISuggestionReview(
            current_state=lambda: state,
            send=lambda received, scope: sent.append((received, scope)),
            save_context=settings.append,
        )
        try:
            review.show(scope_fixture(), snapshot, (0, 0, 0, 0))
            self.assertEqual(sent, [])
            self.assertFalse(review.key(None), "key release must not cancel a review")
            self.assertIsNotNone(review.confirmation)
            self.assertTrue(review.key({"charactersIgnoringModifiers": "s", "modifierFlags": 3}))
            self.assertEqual(settings, [True])
            self.assertTrue(review.key({"charactersIgnoringModifiers": "s", "modifierFlags": 2}))
            self.assertEqual(len(sent), 1)
            self.assertTrue(sent[0][1].include_context)
            self.assertEqual(sent[0][1].configuration.endpoint, scope_fixture().configuration.endpoint)
            review.show(scope_fixture(), snapshot, (0, 0, 0, 0))
            state["snapshot"] = {**snapshot, "generation": 3}
            review.confirm()
            self.assertEqual(len(sent), 1, "a changed input must not send")
            state["snapshot"] = snapshot
            review.show(scope_fixture(), snapshot, (0, 0, 0, 0))
            self.assertFalse(review.key({"keyCode": 36}))
            self.assertIsNone(review.confirmation, "Enter continues to the ordinary input engine")
            self.assertEqual(len(sent), 1)
        finally:
            review.cancel()


if __name__ == "__main__":
    unittest.main()
