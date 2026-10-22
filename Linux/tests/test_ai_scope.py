"""The suggestion review and prompt dialog show Core's decisions and report the user's choices."""
import json
import os
import pathlib
import re
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from ai_core_fixture import FIXTURE_ENDPOINT, CoreAITestCase, CoreWorker
from azookey.keymap import translate


class AILabelTests(unittest.TestCase):
    def test_common_ai_labels_match_macos(self):
        root = pathlib.Path(__file__).resolve().parents[2]
        source = (root / "Core/Sources/Core/Resources/ja.lproj/Localizable.strings").read_text()
        macos = dict(re.findall(r'^"(ai\.[^"]+)" = "([^"]*)";', source, re.MULTILINE))
        linux = json.loads((root / "Linux/azookey/locales/ja.json").read_text())
        for key in macos:
            self.assertEqual(linux[key], macos[key], key)


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class AIReviewTests(CoreAITestCase):
    """Core opens and validates the review; the window only shows it."""

    def setUp(self):
        from azookey.ai_bridge import AIBridge
        from azookey.ai_review import AISuggestionReview
        from azookey.engine import Engine
        self.context = f"review-{uuid.uuid4()}"
        self.sent, self.saved = [], []
        self.engine = SimpleNamespace(
            private=False, sensitive=False, focused=True, destroyed=False,
            native_key_passthrough=False, native_key_reply=None,
            input=SimpleNamespace(recovering=False, pending=[], cancelled=object(), generation=0),
            transformation=SimpleNamespace(input_changed=lambda: None),
            ai=AIBridge(CoreWorker(self.bridge), self.context),
            start_ai=lambda snapshot, request, **_: self.sent.append((snapshot, request)),
        )
        self.engine.ai_review = AISuggestionReview(
            current_state=lambda: Engine.ai_review_state(self.engine),
            send=lambda review, include: Engine.send_ai_review(self.engine, review, include),
            save_context=lambda value: self.saved.append(value) or True,
        )
        self.addCleanup(self.engine.ai_review.cancel)

    def core_key(self, keyval, state=0, **values):
        return self.bridge.request("key", event=translate(keyval, state), context=self.context, **values)

    def review(self):
        """Compose, then ask for AI candidates as Ctrl+S does."""
        for character in "nihongo":
            self.core_key(ord(character))
        snapshot = self.core_key(ord("s"), 4, leftContext="PRIVATE_BEFORE", rightContext="PRIVATE_AFTER")
        self.engine.ai_review.show(snapshot["ai"]["review"], (0, 0, 0, 0))
        self.assertIsNotNone(self.engine.ai_review.confirmation)
        return snapshot

    def test_the_review_shows_the_reviewed_target_and_destination_only(self):
        snapshot = self.review()
        review = snapshot["ai"]["review"]
        self.assertEqual(review["target"], snapshot["reading"])
        self.assertEqual(review["destination"], "api.example.invalid:8443")
        self.assertNotIn("PRIVATE_BEFORE", json.dumps(review, ensure_ascii=False))
        self.assertEqual(self.sent, [], "nothing is sent before confirmation")

    def test_physical_control_key_keeps_review_until_the_send_chord_arrives(self):
        from azookey.engine import Engine
        from gi.repository import Gdk
        self.review()
        self.assertFalse(Engine.do_process_key_event(self.engine, Gdk.KEY_Control_L, 0, 0))
        self.assertIsNotNone(self.engine.ai_review.confirmation)
        self.assertTrue(Engine.do_process_key_event(self.engine, Gdk.KEY_s, 0, Gdk.ModifierType.CONTROL_MASK))
        self.assertIsNone(self.engine.ai_review.confirmation)
        self.assertEqual(len(self.sent), 1)
        snapshot, request = self.sent[0]
        self.assertEqual(request["aiEndpoint"], FIXTURE_ENDPOINT)
        self.assertEqual((request["leftContext"], request["rightContext"]), ("", ""))
        self.assertEqual(snapshot["reading"], request["target"])

    def test_including_context_sends_the_reviewed_surrounding_text(self):
        self.review()
        self.assertTrue(self.engine.ai_review.key(translate(ord("S"), 5)))
        self.assertEqual(self.saved, [True])
        self.assertTrue(self.engine.ai_review.key(translate(ord("s"), 4)))
        request = self.sent[0][1]
        self.assertEqual((request["leftContext"], request["rightContext"]), ("PRIVATE_BEFORE", "PRIVATE_AFTER"))

    def test_a_changed_composition_or_protected_field_is_not_sent(self):
        self.review()
        self.core_key(ord("a"))
        self.engine.ai_review.confirm()
        self.review()
        self.engine.sensitive = True
        self.engine.ai_review.confirm()
        self.assertEqual(self.sent, [])

    def test_return_and_ordinary_input_close_the_review_for_the_input_engine(self):
        self.review()
        self.assertFalse(self.engine.ai_review.key({"keyCode": 36, "modifierFlags": 0}))
        self.assertIsNone(self.engine.ai_review.confirmation)
        self.review()
        self.assertTrue(self.engine.ai_review.key({"keyCode": 53, "modifierFlags": 0}))
        self.assertIsNone(self.engine.ai_review.confirmation)
        self.assertEqual(self.sent, [])

    def test_pending_input_shows_no_review(self):
        self.engine.input.pending = [SimpleNamespace(key=(ord("a"), 38, 0))]
        for character in "nihongo":
            self.core_key(ord(character))
        self.engine.ai_review.show(self.core_key(ord("s"), 4)["ai"]["review"], (0, 0, 0, 0))
        self.assertIsNone(self.engine.ai_review.confirmation)

    def test_context_choice_preserves_newer_settings_and_does_not_overwrite_a_broken_file(self):
        from azookey.engine import Engine
        from azookey.i18n import text as message
        settings = {"includeContext": False, "aiModel": "fixture", "aiEndpoint": "https://example.invalid",
                    "profile": "old profile", "userDictionary": {"items": []}}
        engine = SimpleNamespace(settings=dict(settings), input=SimpleNamespace(settings=dict(settings)))
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}):
            path = pathlib.Path(directory) / "azookey-tree/settings.json"
            path.parent.mkdir()
            path.write_text(json.dumps({**settings, "profile": "new profile"}))
            self.assertTrue(Engine.save_ai_context(engine, True))
            self.assertTrue(json.loads(path.read_text())["includeContext"])
            self.assertEqual(json.loads(path.read_text())["profile"], "new profile")
            self.assertEqual(engine.settings["profile"], "old profile", "unacknowledged conversion settings stay out of input preview")
            engine.settings["includeContext"] = False
            broken = b'{"dictionary": "PRIVATE_ORIGINAL",'
            path.write_bytes(broken)
            self.engine.ai_review.save_context = lambda value: Engine.save_ai_context(engine, value)
            self.review()
            self.engine.ai_review.key(translate(ord("S"), 5))
            self.assertTrue(self.engine.ai_review.confirmation["includeContext"], "the choice applies to this request")
            self.assertEqual(self.engine.ai_review.window.message.get_text(), message("ai.scope.include-error"))
            self.assertEqual(path.read_bytes(), broken)
            self.assertFalse(engine.settings["includeContext"], "a failed save must not become the next request's default")

    def test_confirmation_window_requests_no_keyboard_focus(self):
        from azookey.ai_confirmation import AISuggestionConfirmationWindow
        window = AISuggestionConfirmationWindow(
            {"target": "対象", "destination": None, "includeContext": False},
            on_send=lambda: None, on_cancel=lambda: None, on_context_changed=lambda _: None,
        )
        try:
            self.assertFalse(window.get_accept_focus())
            self.assertFalse(window.get_focus_on_map())
        finally:
            window.destroy()


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class PromptDialogTests(unittest.TestCase):
    """The dialog reports what the user chose and shows Core's answers."""

    OPENED = {"target": "対象", "destination": "api.example.invalid:8443", "includeContext": False, "history": []}

    def test_initial_prompt_waits_for_send_and_context_changes_invalidate_preview(self):
        from azookey.prompt_dialog import PromptDialog
        from gi.repository import Gtk
        requests, invalidations, selections = [], [], []
        dialog = PromptDialog(self.OPENED, "敬語に直す", request_preview=lambda *values: requests.append(values),
                              invalidate_preview=lambda: invalidations.append(True), on_context_changed=selections.append)
        try:
            dialog.show_all()
            self.assertEqual(requests, [])
            self.assertFalse(dialog.scope_view.context.get_active())
            dialog.scope_view.context.set_active(True)
            dialog.entry.emit("activate")
            self.assertEqual(requests, [("敬語に直す", False, "", True)])
            dialog.preview_started()
            dialog.preview_finished("変換した本文")
            self.assertEqual(dialog.result, "変換した本文")
            self.assertTrue(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
            dialog.scope_view.context.set_active(False)
            self.assertEqual(selections, [True, False])
            self.assertEqual(len(invalidations), 2)
            self.assertIsNone(dialog.result)
            self.assertFalse(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
            dialog.entry.emit("activate")
            self.assertFalse(requests[1][3])
        finally:
            dialog.destroy()

    def test_history_shows_pins_and_their_shortcuts(self):
        from azookey.prompt_dialog import PromptDialog
        opened = {**self.OPENED, "history": [{"prompt": "敬語に直す", "pinned": True, "shortcutText": "Ctrl+Alt+e"}]}
        dialog = PromptDialog(opened, request_preview=lambda *_: None, invalidate_preview=lambda: None,
                              on_context_changed=lambda _: True)
        try:
            dialog.history.set_active_id("0")
            self.assertEqual(dialog.entry.get_text(), "敬語に直す")
            self.assertTrue(dialog.pin.get_active())
            self.assertEqual(dialog.shortcut.get_text(), "Ctrl+Alt+e")
        finally:
            dialog.destroy()


if __name__ == "__main__":
    unittest.main()
