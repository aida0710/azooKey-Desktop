"""The application and IBus must not both submit the same visible preedit."""
from types import SimpleNamespace
import unittest
from unittest.mock import ANY, Mock, patch


class PreeditOwnershipTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        try:
            from azookey import engine
            from azookey.reading_engine import ReadingEngine
            from gi.repository import IBus
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        cls.ordinary_engine = engine.Engine
        cls.reading_engine = ReadingEngine
        cls.ibus = IBus
        cls.engine_module = engine

    def setUp(self):
        self.preedits = []
        self.commits = []
        self.engine = SimpleNamespace(
            focused=True, private=False, focus_identity=None,
            frontend=SimpleNamespace(focus=object()),
            snapshot={}, input=SimpleNamespace(snapshot={}),
            anchor=Mock(), panel=Mock(), renderer=Mock(),
            update_property=Mock(), render_candidates=lambda snapshot: snapshot,
            update_preedit_text_with_mode=lambda text, cursor, visible, mode:
                self.preedits.append((text.get_text(), cursor, visible, mode)),
            commit_text=lambda text: self.commits.append(text.get_text()),
            lookup_announcements=Mock(), ai_review=Mock(),
            hide_preedit_text=Mock(), hide_lookup_table=Mock(),
            reconversion=SimpleNamespace(
                take_recovery=lambda text: (text, object()),
                is_current_recovery=lambda _recovery: True,
                finish_recovery=Mock(),
                render_input_error=Mock(),
            ),
        )
        surface = patch.object(self.engine_module, "surface", return_value=Mock())
        surface.start()
        self.addCleanup(surface.stop)

    def publish(self, entry, state="composing", *, commits=()):
        snapshot = {"preedit": "にほんご", "cursor": 4, "inputState": state, "commits": list(commits)}
        self.engine.input.snapshot = snapshot
        if entry == "pending":
            self.ordinary_engine.preview_pending(self.engine, snapshot["preedit"], snapshot["cursor"])
        else:
            render = self.reading_engine.render_input if entry == "reading" else self.ordinary_engine.render
            render(self.engine, snapshot)
        self.assertEqual(self.preedits[-1][:3], ("にほんご", 4, True))
        return self.preedits[-1][3]

    def test_qt_local_commit_is_not_committed_again_by_ibus_reset(self):
        self.engine.focus_identity = ("/context/shared-by-two-fields", "QIBusInputContext")
        for entry in ("ordinary", "reading", "pending"):
            with self.subTest(entry=entry):
                mode = self.publish(entry)
                # Qt 6.4 commit() sends the preedit to the old widget before
                # Reset. IBus COMMIT then emits another commit to the new one.
                old_field = self.preedits[-1][0]
                next_field = self.preedits[-1][0] if mode == self.ibus.PreeditFocusMode.COMMIT else ""
                self.assertEqual((old_field, next_field), ("にほんご", ""))
                self.assertEqual(self.commits, [])

    def test_gtk_and_unrecognized_clients_keep_their_existing_focus_commit(self):
        identities = (None, ("/context", "gtk4-im:fixture"), ("/context", "gtk-im:fixture"),
                      ("/context", "unknown"), ("/context", "QIBusInputContextExtra"))
        for identity in identities:
            self.engine.focus_identity = identity
            for entry in ("ordinary", "reading", "pending"):
                with self.subTest(identity=identity, entry=entry):
                    self.assertEqual(self.publish(entry), self.ibus.PreeditFocusMode.COMMIT)

    def test_unicode_input_still_clears_instead_of_committing_on_focus_loss(self):
        for client in ("QIBusInputContext", "gtk4-im:fixture", "unknown"):
            self.engine.focus_identity = ("/context", client)
            for entry in ("ordinary", "reading"):
                with self.subTest(client=client, entry=entry):
                    self.assertEqual(self.publish(entry, "unicodeInput"), self.ibus.PreeditFocusMode.CLEAR)

    def test_explicit_enter_commit_remains_one_engine_commit_for_each_client(self):
        for client in ("QIBusInputContext", "gtk4-im:fixture"):
            self.engine.focus_identity = ("/context", client)
            for entry in ("ordinary", "reading"):
                with self.subTest(client=client, entry=entry):
                    self.commits.clear()
                    self.publish(entry, commits=("日本語",))
                    self.assertEqual(self.commits, ["日本語"])

    def test_recovery_clears_cached_preedit_before_restoring_once_in_the_original_field(self):
        for client in ("QIBusInputContext", "gtk4-im:fixture"):
            self.engine.focus_identity = ("/context", client)
            self.commits.clear()
            finish = self.ordinary_engine.prepare_composition_recovery(self.engine, "元の文章")
            self.assertEqual(self.preedits[-1][:3], ("", 0, False))
            expected = (self.ibus.PreeditFocusMode.CLEAR if client == "QIBusInputContext"
                        else self.ibus.PreeditFocusMode.COMMIT)
            self.assertEqual(self.preedits[-1][3], expected)
            self.assertEqual(self.commits, ["元の文章"])
            finish()
            self.engine.reconversion.finish_recovery.assert_called_with(ANY, allow_native=True)


if __name__ == "__main__":
    unittest.main()
