"""Test the real GTK accessible action without a converter or external service."""

import os
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class CandidateAccessibilityTests(unittest.TestCase):
    def setUp(self):
        from azookey.tree_panel import TreePanel

        self.submitted = []
        self.panel = TreePanel(lambda *selection: self.submitted.append(selection))
        self.snapshot = {
            "generation": 1,
            "selection": 0,
            "focusedNode": 0,
            "nodes": [
                {"id": 0, "text": "日本", "reading": "ニホン", "parent": None, "terminals": [0]},
                {"id": 1, "text": "日本", "reading": "ニッポン", "parent": None, "terminals": [1]},
            ],
            "columns": [[0, 1]],
            "selectedPath": [0],
        }
        self.panel.update(self.snapshot)
        self.flush_events()

    def tearDown(self):
        self.panel.destroy()
        self.flush_events()

    @staticmethod
    def flush_events():
        from gi.repository import GLib

        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def test_accessible_candidates_expose_reading_selection_and_one_activation(self):
        from gi.repository import Atk

        button = self.panel.actions[("node", 1)]
        accessible = button.get_accessible()
        self.assertEqual(accessible.get_name(), "日本（ニッポン）")
        self.assertFalse(accessible.ref_state_set().contains_state(Atk.StateType.SELECTED))
        self.assertFalse(button.get_can_focus())
        self.assertFalse(self.panel.get_accept_focus())
        self.assertGreater(accessible.get_n_actions(), 0)
        self.assertTrue(accessible.do_action(0))
        self.flush_events()
        self.assertEqual(self.submitted, [("node", 1, True)])

    def test_selection_updates_reuse_accessible_objects_without_submitting(self):
        from gi.repository import Atk

        button = self.panel.actions[("node", 1)]
        accessible = button.get_accessible()
        self.panel.update({**self.snapshot, "selection": 1, "selectedPath": [1], "focusedNode": 1})
        self.flush_events()
        self.assertIs(self.panel.actions[("node", 1)], button)
        self.assertTrue(accessible.ref_state_set().contains_state(Atk.StateType.SELECTED))
        self.assertEqual(self.submitted, [])

    def test_removed_candidate_action_cannot_submit_a_new_candidate(self):
        button = self.panel.actions[("node", 1)]
        self.panel.update({"nodes": []})
        self.panel.update(self.snapshot)
        self.panel.activate(("node", 1), button)
        self.assertEqual(self.submitted, [])

    def test_same_node_id_from_another_generation_cannot_use_an_old_action(self):
        button = self.panel.actions[("node", 0)]
        changed_nodes = [{**node, "text": "別の語"} for node in self.snapshot["nodes"]]
        self.panel.update({**self.snapshot, "generation": 2, "nodes": changed_nodes})
        button.clicked()
        self.flush_events()
        self.assertEqual(self.submitted, [])

    def test_same_word_with_a_different_complete_candidate_invalidates_old_actions(self):
        self.panel.update({**self.snapshot, "candidates": [{"index": 0, "text": "日本に行く"}]})
        button = self.panel.actions[("node", 0)]
        self.panel.update({**self.snapshot, "generation": 2, "candidates": [{"index": 0, "text": "日本に帰る"}]})
        button.clicked()
        self.assertEqual(self.submitted, [])

    def test_selection_change_between_mouse_press_and_click_does_not_commit(self):
        from gi.repository import Gdk

        button = self.panel.actions[("node", 1)]
        event = Gdk.Event.new(Gdk.EventType.BUTTON_PRESS)
        event.button = 1
        button.emit("button-press-event", event)
        self.panel.update({**self.snapshot, "generation": 2, "selection": 1, "selectedPath": [1]})
        self.assertIs(self.panel.actions[("node", 1)], button)
        button.clicked()
        self.assertEqual(self.submitted, [])


if __name__ == "__main__":
    unittest.main()
