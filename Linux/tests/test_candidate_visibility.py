"""Pending conversion hides candidates without ending their navigation session."""
import os
import pathlib
import sys
import unittest
import weakref
from types import MethodType, SimpleNamespace
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
try:
    from azookey.shell_surface import NAME, PATH, XML, ShellSurface
except ImportError:
    ShellSurface = None


@unittest.skipUnless(ShellSurface, "requires PyGObject")
class CandidateSurfaceTests(unittest.TestCase):
    def setUp(self):
        with mock.patch("azookey.shell_surface.Gio.bus_own_name"):
            self.surface = ShellSurface()
        self.engine = mock.Mock()
        self.surface.connection = mock.Mock()
        self.surface.renderer = ":1.42"
        self.surface.engine = weakref.ref(self.engine)

    def test_pending_visibility_and_session_end_use_distinct_targeted_signals(self):
        self.surface.suspend(self.engine)
        self.surface.hide(self.engine)
        self.assertEqual(self.surface.connection.emit_signal.call_args_list, [
            mock.call(":1.42", PATH, NAME, "Suspend", None),
            mock.call(":1.42", PATH, NAME, "Hide", None),
        ])

    def test_old_context_cannot_hide_or_suspend_the_current_candidates(self):
        other_engine = mock.Mock()
        self.surface.suspend(other_engine)
        self.surface.hide(other_engine)
        self.assertFalse(self.surface.scroll_details(other_engine, True))
        self.surface.connection.emit_signal.assert_not_called()

    def test_renderer_loss_or_expired_context_never_broadcasts_visibility(self):
        connection = self.surface.connection
        cases = (
            ("renderer", None), ("engine", None),
            ("engine", lambda: None), ("connection", None),
        )
        for attribute, value in cases:
            with self.subTest(attribute=attribute, value=value):
                with mock.patch.object(self.surface, attribute, value):
                    self.surface.suspend(self.engine)
                    self.surface.hide(self.engine)
                    self.assertFalse(self.surface.scroll_details(self.engine, True))
        connection.emit_signal.assert_not_called()

    def test_registered_renderer_can_scroll_details_in_the_current_context(self):
        self.assertTrue(self.surface.scroll_details(self.engine, False))
        arguments = self.surface.connection.emit_signal.call_args.args
        self.assertEqual(arguments[:4], (":1.42", PATH, NAME, "ScrollDetails"))
        self.assertEqual(arguments[4].unpack(), (False,))

    def test_bus_contract_declares_suspend_without_composition_payload(self):
        from gi.repository import Gio
        interface = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
        signal = interface.lookup_signal("Suspend")
        self.assertIsNotNone(signal)
        self.assertEqual(signal.args, [])


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidateVisibilityTests(unittest.TestCase):
    def setUp(self):
        from azookey.engine import Engine
        self.engine_type = Engine
        self.shell = mock.Mock()
        self.surface_patch = mock.patch("azookey.engine.surface", return_value=self.shell)
        self.surface_patch.start()
        self.addCleanup(self.surface_patch.stop)
        self.engine = SimpleNamespace(
            focused=True, private=False, focus_identity=None,
            panel=mock.Mock(spec=("suspend", "dismiss")),
            update_preedit_text_with_mode=mock.Mock(),
            hide_lookup_table=mock.Mock(), hide_preedit_text=mock.Mock(),
            lookup_announcements=mock.Mock(), ai_review=mock.Mock(),
            reconversion=mock.Mock(), anchor=mock.Mock(), input=mock.Mock(),
            clear_reconversion=mock.Mock(), commit_text=mock.Mock(),
            forward_key_event=mock.Mock(),
        )
        self.engine.prepare_composition_recovery = MethodType(
            Engine.prepare_composition_recovery, self.engine,
        )
        self.engine.reconversion.take_recovery.return_value = ("", [])

    def test_pending_conversion_preserves_preedit_and_suspends_both_renderers(self):
        from gi.repository import IBus
        self.engine_type.preview_pending(self.engine, "にほんご", 2)
        text, cursor, visible, mode = self.engine.update_preedit_text_with_mode.call_args.args
        self.assertEqual((text.get_text(), cursor, visible, mode),
                         ("にほんご", 2, True, IBus.PreeditFocusMode.COMMIT))
        self.engine.panel.suspend.assert_called_once_with()
        self.shell.suspend.assert_called_once_with(self.engine)
        self.engine.panel.dismiss.assert_not_called()
        self.shell.hide.assert_not_called()
        self.engine.hide_lookup_table.assert_called_once_with()

    def test_private_or_unfocused_input_does_not_publish_a_pending_preview(self):
        for focused, private in ((False, False), (True, True)):
            with self.subTest(focused=focused, private=private):
                self.engine.focused, self.engine.private = focused, private
                self.engine_type.preview_pending(self.engine, "private", 7)
        self.engine.update_preedit_text_with_mode.assert_not_called()
        self.engine.panel.suspend.assert_not_called()
        self.shell.suspend.assert_not_called()

    def test_focus_loss_dismisses_a_previously_suspended_session(self):
        self.engine_type.preview_pending(self.engine, "にほんご", 4)
        self.engine_type.do_focus_out(self.engine)
        self.engine.panel.dismiss.assert_called_once_with()
        self.shell.hide.assert_called_once_with(self.engine)
        self.engine.input.cancel.assert_called_once_with()
        self.assertFalse(self.engine.focused)
        self.assertEqual(self.engine.snapshot, {})

    def test_recovery_dismisses_a_previously_suspended_session(self):
        self.engine_type.preview_pending(self.engine, "にほんご", 4)
        self.engine_type.recover_composition(self.engine)
        self.engine.panel.dismiss.assert_called_once_with()
        self.shell.hide.assert_called_once_with(self.engine)
        self.assertEqual(self.engine.snapshot, {})
        self.engine.commit_text.assert_not_called()


if __name__ == "__main__":
    unittest.main()
