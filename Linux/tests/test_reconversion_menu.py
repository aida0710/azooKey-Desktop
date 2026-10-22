"""Menu actions preserve the document until an original Enter starts replacement."""
import pathlib
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.keymap import translate
from azookey.native_key_reply import NativeKeyReply
from azookey.reconversion import surrounding_context
from reconversion_fixture import ReconversionFixture


ENTER_KEYS = ((0xFF0D, 36, 0), (0xFF8D, 104, 0))
ESCAPE = (0xFF1B, 9, 0)
HOME = (0xFF50, 110, 4)
F10 = (0xFFC7, 76, 0)
LETTER = (ord("a"), 38, 0)
RELEASE = 1 << 30


class ReconversionMenuTests(ReconversionFixture, unittest.TestCase):
    def send_key(self, key, *, after_reply=None):
        def complete(consumed):
            self.effects.append(("reply", key, consumed))
            if after_reply:
                after_reply(consumed)

        reply = NativeKeyReply(complete)
        consumed = self.coordinator.process(translate(key[0], key[2]), key, key_reply=reply)
        if not reply.deferred:
            reply.finish(consumed)
        return reply

    def assert_no_document_edit(self):
        self.assertEqual(self.worker.requests, [])
        self.assertFalse(any(effect[0] in ("delete", "render", "forward") for effect in self.effects))
        self.assertEqual(self.document["selected"], "日本語")

    def test_menu_only_displays_confirmation_without_requesting_or_deleting(self):
        for undo, expected_status in (
            (True, "Enterで直前の確定を取り消す / Escで取消"),
            (False, "Enterで選択した文字を再変換 / Escで取消"),
        ):
            with self.subTest(undo=undo):
                self.setUp()
                self.coordinator.prompt_menu(undo=undo)
                self.assert_no_document_edit()
                self.assertEqual(self.effects, [("status", expected_status)])

    def test_enter_holds_its_original_reply_until_delete_then_allows_client_ack(self):
        for undo in (False, True):
            for enter in ENTER_KEYS:
                with self.subTest(undo=undo, enter=enter):
                    self.setUp()
                    self.coordinator.prompt_menu(undo=undo)

                    def acknowledge_after_reply(consumed):
                        self.assertTrue(consumed)
                        self.assertIn(("delete", -3, 3), self.effects)
                        self.acknowledge()

                    reply = self.send_key(enter, after_reply=acknowledge_after_reply)
                    self.assertFalse(reply.completed)
                    self.assertEqual(self.worker.requests[0].operation, "undo-commit" if undo else "reconvert")
                    self.worker.respond(0, {"reconversion": self.plan})
                    self.assertTrue(reply.completed)
                    self.assertEqual(self.worker.requests[1].operation, "confirm-reconversion")
                    self.worker.respond(1, {"preedit": "日本語", "inputState": "selecting"})
                    self.assertEqual(self.inputs.snapshot["preedit"], "日本語")
                    self.assertFalse(self.coordinator.active)
                    self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                                     [("reply", enter, True)])

    def test_editing_keys_cancel_menu_and_keep_the_original_event_for_normal_input(self):
        for key in (F10, HOME, LETTER, (*ENTER_KEYS[0][:2], 4)):
            with self.subTest(key=key):
                self.setUp()
                self.coordinator.prompt_menu(undo=True)
                self.send_key(key)
                self.assertFalse(self.coordinator.active)
                self.assert_no_document_edit()
                self.assertIn(("reply", key, False), self.effects)

    def test_clearing_menu_during_refocus_cannot_queue_the_old_edit_in_a_new_session(self):
        self.coordinator.prompt_menu(undo=True)
        new_key = (ord("R"), 27, 5)
        new_reply = None
        new_request_index = None

        def status_and_refocus(text):
            nonlocal new_reply, new_request_index
            self.effects.append(("status", text))
            self.coordinator.status = lambda text: self.effects.append(("status", text))
            self.coordinator.cancel()
            self.inputs.cancel()
            self.document = surrounding_context("別日本語後", 4, 1, can_replace=True, sensitive=False)
            new_request_index = len(self.worker.requests)
            new_reply = self.send_key(new_key)

        self.coordinator.status = status_and_refocus
        old_reply = self.send_key(LETTER)
        self.assertIsNotNone(new_reply)
        self.assertTrue(old_reply.completed)
        self.assertFalse(new_reply.completed)
        self.assertEqual(list(self.coordinator.queued), [])
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", LETTER, True)])
        self.worker.respond(new_request_index, {"reconversion": self.plan})
        self.assertTrue(new_reply.completed)
        self.document = surrounding_context("別後", 1, 1, can_replace=True, sensitive=False)
        self.coordinator.surrounding_changed()
        self.worker.respond(len(self.worker.requests) - 1, {
            "preedit": "日本語", "inputState": "selecting",
        })
        old_reply.finish(False)
        new_reply.finish(False)
        self.assertFalse(any(effect[0] in ("replay", "forward") for effect in self.effects))
        self.assertEqual([effect for effect in self.effects if effect[0] == "reply"],
                         [("reply", LETTER, True), ("reply", new_key, True)])

    def test_escape_cancels_without_reaching_the_application(self):
        self.coordinator.prompt_menu(undo=False)
        self.send_key(ESCAPE)
        self.assertFalse(self.coordinator.active)
        self.assert_no_document_edit()
        self.assertIn(("reply", ESCAPE, True), self.effects)

    def test_modifiers_and_releases_preserve_the_menu_without_blocking_the_client(self):
        keys = ((0xFFE3, 37, 0), (0xFFE3, 37, RELEASE), (*F10[:2], RELEASE))
        self.coordinator.prompt_menu(undo=True)
        for key in keys:
            self.send_key(key)
            self.assertTrue(self.coordinator.active)
            self.assertIn(("reply", key, False), self.effects)
        self.assert_no_document_edit()

    def test_changed_document_rejects_confirmation_without_deleting_either_target(self):
        self.coordinator.prompt_menu(undo=True)
        self.document = surrounding_context("別の文書", 2, 2, can_replace=True, sensitive=False)
        self.send_key(ENTER_KEYS[0])
        self.assertFalse(self.coordinator.active)
        self.assertFalse(any(request.operation in ("undo-commit", "reconvert") for request in self.worker.requests))
        self.assertFalse(any(effect[0] == "delete" for effect in self.effects))
        self.assertEqual(self.document["before"], "別の")
        self.assertIn(("reply", ENTER_KEYS[0], True), self.effects)

    def test_shortcut_replaces_menu_confirmation_and_waits_for_its_own_plan(self):
        self.coordinator.prompt_menu(undo=True)
        key = (ord("R"), 27, 5)
        reply = self.send_key(key)
        self.assertEqual(self.worker.requests[0].operation, "reconvert")
        self.assertFalse(reply.completed)
        self.worker.respond(0, {"reconversion": self.plan})
        self.assertTrue(reply.completed)
        self.assertIn(("reply", key, True), self.effects)

    def test_cancel_removes_the_menu_so_later_enter_is_native(self):
        self.coordinator.prompt_menu(undo=True)
        self.coordinator.cancel()
        self.send_key(ENTER_KEYS[0])
        self.assert_no_document_edit()
        self.assertIn(("reply", ENTER_KEYS[0], False), self.effects)

    def test_menu_rejects_sensitive_readonly_and_composing_targets(self):
        for reason in ("absent", "sensitive", "readonly", "composition"):
            with self.subTest(reason=reason):
                self.setUp()
                if reason == "absent":
                    self.document = None
                elif reason == "sensitive":
                    self.document["isSensitive"] = True
                elif reason == "readonly":
                    self.document["canReplace"] = False
                else:
                    self.inputs.snapshot = {"preedit": "入力中"}
                self.coordinator.prompt_menu(undo=False)
                self.assertFalse(self.coordinator.active)
                self.assertEqual(self.worker.requests, [])


class ReconversionMenuEngineTests(ReconversionFixture, unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            import gi
            gi.require_version("Gdk", "3.0")
            gi.require_version("IBus", "1.0")
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        from azookey.engine import Engine
        cls.engine_type = Engine

    def test_both_public_properties_leave_text_intact_until_enter(self):
        for name in ("undo-commit", "reconvert"):
            with self.subTest(name=name):
                self.setUp()
                engine = SimpleNamespace(reconversion=self.coordinator)
                self.engine_type.do_property_activate(engine, name, 0)
                self.assertTrue(self.coordinator.active)
                self.assertEqual(self.worker.requests, [])
                self.assertFalse(any(effect[0] == "delete" for effect in self.effects))


if __name__ == "__main__":
    unittest.main()
