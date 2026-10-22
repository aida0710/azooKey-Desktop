"""Keep pending input and candidate sessions consistent when a renderer changes."""
import os
from pathlib import Path
import sys
from types import MethodType
import unittest
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from azookey.async_bridge import Reply
from azookey.input_coordinator import InputCoordinator
from azookey.keymap import translate


class CandidateEngineFixture:
    """Run product input methods while recording application and panel effects."""

    def __init__(self):
        from azookey.engine import Engine
        self.render = MethodType(Engine.render, self)
        self.render_candidates = MethodType(Engine.render_candidates, self)
        self.preview_pending = MethodType(Engine.preview_pending, self)
        self.do_focus_out = MethodType(Engine.do_focus_out, self)
        self.context_id = "renderer-loss-field"
        self.focused = True
        self.private = False
        self.settings = {"tree": True}
        self.settings_problem_stamp = None
        self.snapshot = {}
        self.preedit_updates = []
        self.panel = mock.Mock()
        self.panel.location = (10, 20, 1, 20)
        self.lookup_announcements = mock.Mock()
        self.ai_review = mock.Mock()
        self.clear_reconversion = mock.Mock()
        self.anchor = mock.Mock()
        self.table = mock.Mock()
        self.update_property = mock.Mock()
        self.update_auxiliary_text = mock.Mock()
        self.commit_text = mock.Mock()
        self.forward_key_event = mock.Mock()
        self.hide_lookup_table = mock.Mock()
        self.update_lookup_table = mock.Mock()
        self.worker = mock.Mock()
        self.input = InputCoordinator(
            self.worker, self.context_id, render=self.render,
            forward=self.forward_key_event, recover=mock.Mock(), preview=self.preview_pending,
        )

    def positioned_snapshot(self, snapshot):
        return snapshot

    def update_preedit_text_with_mode(self, text, cursor, visible, mode):
        self.preedit_updates.append((text.get_text(), cursor, visible, mode))

    @property
    def preedit(self):
        return self.preedit_updates[-1][0] if self.preedit_updates else ""

    def complete_request(self, index, snapshot):
        request = self.worker.submit.call_args_list[index].args[0]
        request.complete(Reply(snapshot))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class CandidateRendererLossTests(unittest.TestCase):
    def setUp(self):
        from azookey.shell_surface import ShellSurface
        with mock.patch("azookey.shell_surface.Gio.bus_own_name"):
            self.surface = ShellSurface()
        self.surface.connection = mock.Mock()
        self.surface.renderer = ":1.42"
        surface_patch = mock.patch("azookey.engine.surface", return_value=self.surface)
        surface_patch.start()
        self.addCleanup(surface_patch.stop)
        self.engine = CandidateEngineFixture()
        self.snapshot = {
            "preedit": "あ", "reading": "あ", "cursor": 1, "readingCursor": 1,
            "inputState": "composing", "generation": 1, "language": "japanese",
            "selection": 0, "candidates": [{"index": 0, "text": "亜"}],
        }
        self.engine.input.publish(self.snapshot)
        self.surface.connection.emit_signal.reset_mock()
        self.engine.panel.reset_mock()

    def submit_pending_character(self):
        self.engine.input.submit(
            "key", payload={"event": translate(ord("i"), 0)}, key=(ord("i"), 31, 0),
        )
        self.assertEqual(self.engine.preedit, "あi")
        self.assertEqual(len(self.engine.input.pending), 1)

    def completed_character_snapshot(self):
        return {
            **self.snapshot, "consumed": True, "preedit": "あい", "reading": "あい",
            "cursor": 2, "readingCursor": 2,
        }

    def test_disabling_tree_ends_the_suspended_shell_session(self):
        self.submit_pending_character()
        self.engine.settings["tree"] = False
        self.engine.complete_request(0, self.completed_character_snapshot())
        signals = [call.args[3] for call in self.surface.connection.emit_signal.call_args_list]
        self.assertEqual(signals, ["Suspend", "Hide"])
        self.engine.panel.dismiss.assert_called_once_with()
        self.assertEqual(self.engine.preedit, "あい")

    def test_renderer_loss_does_not_restore_old_preedit_or_old_candidate_actions(self):
        self.submit_pending_character()
        preedit_updates = list(self.engine.preedit_updates)
        self.surface.lost()
        self.assertEqual(self.engine.preedit_updates, preedit_updates)
        self.assertEqual(len(self.engine.input.pending), 1)
        self.engine.panel.update.assert_not_called()
        self.engine.commit_text.assert_not_called()

    def test_renderer_loss_without_pending_input_shows_the_acknowledged_candidates(self):
        preedit_updates = list(self.engine.preedit_updates)
        property_updates = self.engine.update_property.call_count
        anchor_updates = self.engine.anchor.update.call_count
        self.surface.lost()
        self.assertEqual(self.engine.preedit, "あ")
        self.assertEqual(self.engine.preedit_updates, preedit_updates)
        self.assertEqual(self.engine.update_property.call_count, property_updates)
        self.assertEqual(self.engine.anchor.update.call_count, anchor_updates)
        self.engine.panel.update.assert_called_once_with({**self.snapshot, "commits": [], "request": None})
        self.surface.connection.emit_signal.assert_not_called()
        self.engine.commit_text.assert_not_called()

    def test_pending_settings_do_not_delay_fallback_candidate_display(self):
        settings_replies = []
        self.engine.input.submit("settings", completion=settings_replies.append)
        preedit_updates = list(self.engine.preedit_updates)
        self.surface.lost()
        self.engine.panel.update.assert_called_once_with({**self.snapshot, "commits": [], "request": None})
        self.assertEqual(self.engine.preedit, "あ")
        self.assertEqual(self.engine.preedit_updates, preedit_updates)
        settings_snapshot = {"settings": {"tree": True}}
        self.engine.complete_request(0, settings_snapshot)
        self.assertEqual(settings_replies, [settings_snapshot])
        self.assertFalse(self.engine.input.pending)
        self.engine.panel.update.assert_called_once()

    def test_redrawing_each_renderer_does_not_reapply_input_or_ai_effects(self):
        acknowledged = self.engine.snapshot
        preedit_updates = list(self.engine.preedit_updates)
        property_updates = self.engine.update_property.call_count
        anchor_updates = self.engine.anchor.update.call_count
        candidate_snapshot = {
            **self.snapshot, "commits": ["再送しない"], "preedit": "書き換えない",
            "cursor": 0, "request": "replace",
        }
        for renderer, display_name in (
            (":1.42", "WaylandDisplay"), (None, "WaylandDisplay"), (None, "X11Display"),
        ):
            with self.subTest(renderer=renderer, display=display_name):
                self.surface.renderer = renderer
                self.surface.connection.emit_signal.reset_mock()
                self.engine.panel.reset_mock()
                self.engine.update_lookup_table.reset_mock()
                display = type(display_name, (), {})()
                with mock.patch("azookey.engine.Gdk.Display.get_default", return_value=display):
                    self.engine.render_candidates(candidate_snapshot)
                if renderer:
                    self.assertEqual(self.surface.connection.emit_signal.call_args.args[3], "Update")
                elif display_name == "WaylandDisplay":
                    self.engine.update_lookup_table.assert_called_once_with(self.engine.table, True)
                else:
                    self.engine.panel.update.assert_called_once_with(candidate_snapshot)
                self.assertIs(self.engine.snapshot, acknowledged)
                self.assertEqual(self.engine.preedit_updates, preedit_updates)
                self.assertEqual(self.engine.update_property.call_count, property_updates)
                self.assertEqual(self.engine.anchor.update.call_count, anchor_updates)
                self.engine.commit_text.assert_not_called()
                self.engine.ai_review.show.assert_not_called()

    def test_late_normal_reply_restores_fallback_with_the_new_candidates(self):
        self.submit_pending_character()
        self.surface.lost()
        self.engine.panel.update.assert_not_called()
        completed = self.completed_character_snapshot()
        self.engine.complete_request(0, completed)
        self.assertEqual(self.engine.preedit, "あい")
        self.engine.panel.update.assert_called_once_with(completed)
        self.assertFalse(self.engine.input.pending)
        self.engine.forward_key_event.assert_not_called()
        self.engine.commit_text.assert_not_called()

    def test_focus_loss_rejects_a_late_reply_after_renderer_loss(self):
        self.submit_pending_character()
        self.surface.lost()
        preedit_updates = list(self.engine.preedit_updates)
        self.engine.do_focus_out()
        self.engine.complete_request(0, {
            **self.completed_character_snapshot(), "commits": ["late commit"],
        })
        self.assertEqual(self.engine.preedit_updates, preedit_updates)
        self.assertFalse(self.engine.focused)
        self.assertFalse(self.engine.input.pending)
        self.assertEqual(self.engine.snapshot, {})
        self.engine.panel.dismiss.assert_called_once_with()
        self.engine.panel.update.assert_not_called()
        self.engine.commit_text.assert_not_called()
        self.engine.forward_key_event.assert_not_called()


if __name__ == "__main__":
    unittest.main()
