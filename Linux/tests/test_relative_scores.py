"""Score visibility must not change the selected candidate or its activation."""
import os
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


class RelativeScoreSettingsTests(unittest.TestCase):
    def test_score_preference_is_validated_saved_and_reset_with_display_settings(self):
        from azookey.settings_schema import input_defaults, validate_settings
        from azookey.settings_store import SettingsStore

        with tempfile.TemporaryDirectory() as directory:
            store = SettingsStore(pathlib.Path(directory) / "settings.json")
            store.save({"showRelativeScores": False})
            saved = store.load({"showRelativeScores": True})
            self.assertIsNone(saved.problem)
            self.assertFalse(saved.values["showRelativeScores"])
            self.assertTrue(input_defaults(saved.values)["showRelativeScores"])
        with self.assertRaises(ValueError):
            validate_settings({"showRelativeScores": "false"})


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real Swift bridge and isolated Linux preferences")
class RelativeScoreBridgeTests(unittest.TestCase):
    def test_hidden_scores_survive_restart_and_preserve_the_exact_candidate_commit(self):
        from azookey.bridge import Bridge
        from azookey.keymap import translate

        with tempfile.TemporaryDirectory() as directory:
            environment = {**os.environ, "AZOOKEY_DATA_DIR": directory, "XDG_CONFIG_HOME": directory}
            bridge = Bridge(environment=environment)
            try:
                settings = bridge.request("settings")["settings"]
                self.assertTrue(settings["showRelativeScores"])
                settings.update(tree=True, live=True, learning="nothing")
                self.assertNotIn("error", bridge.request("configure", settings=settings))
                for character in "sentaku":
                    bridge.request("key", event=translate(ord(character), 0))
                visible = bridge.request("snapshot")
                candidate = next(item for item in visible["candidates"] if item["index"] == visible["selection"])
                shown_ids = {node_id for column in visible["columns"] for node_id in column}
                self.assertTrue(shown_ids)
                self.assertTrue(all(node.get("scorePresentation") for node in visible["nodes"] if node["id"] in shown_ids))

                settings["showRelativeScores"] = False
                self.assertNotIn("error", bridge.request("configure", settings=settings))
                hidden = bridge.request("snapshot")
                self.assertFalse(hidden["showRelativeScores"])
                self.assertFalse(any(node.get("scorePresentation") for node in hidden["nodes"]))
                self.assertEqual([node.get("relativeScore") for node in hidden["nodes"]],
                                 [node.get("relativeScore") for node in visible["nodes"]])
                for field in ("generation", "selection", "focusedNode", "selectedPath", "reading"):
                    self.assertEqual(hidden[field], visible[field], field)
                committed = bridge.request("select", index=candidate["index"], generation=hidden["generation"], submit=True)
                self.assertEqual(committed["commits"], [candidate["text"]])
                self.assertEqual(committed["reading"], "")
                bridge.close()
                bridge = Bridge(environment=environment)
                self.assertFalse(bridge.request("settings")["settings"]["showRelativeScores"])
                self.assertFalse(bridge.request("snapshot")["showRelativeScores"])
            finally:
                bridge.close()


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires a GTK display")
class RelativeScorePanelTests(unittest.TestCase):
    def test_hiding_scores_removes_their_space_and_explanation_without_replacing_the_focused_action(self):
        from candidate_core import core_tree_panel

        commits = []
        panel = core_tree_panel(lambda *selection: commits.append(selection))
        # Core's explanation of a conditional 100.
        description = "100はこの分岐内の相対値です。子候補が一つでも100になり、正解を保証しません。"
        nodes = [
            {"id": 0, "text": "選択", "reading": "センタク", "parent": None, "terminals": [0], "relativeScore": 100,
             "scorePresentation": {"label": "100", "role": "scoreHigh", "detailDescription": description}},
            {"id": 1, "text": "洗濯", "reading": "センタク", "parent": None, "terminals": [1],
             "scorePresentation": {"label": "—", "role": "scoreUnknown", "detailDescription": "未評価"}},
        ]
        snapshot = {
            "nodes": nodes, "columns": [[0, 1]], "selectedPath": [0], "selection": 0, "inputState": "selecting",
            "focusedNode": 0, "generation": 1, "showRelativeScores": True,
        }
        try:
            panel.update(snapshot)
            panel.disclosure_actions["tree"].clicked()
            self.assertIn(description, panel.details.displayed_text)
            focused_action = panel.actions[("node", 0)]
            self.assertIn(description, focused_action.get_accessible().get_description())
            visible_height = panel.canvas.get_size_request()[1]
            hidden_nodes = [{key: value for key, value in node.items() if key != "scorePresentation"} for node in nodes]
            panel.update({**snapshot, "nodes": hidden_nodes, "showRelativeScores": False})
            self.assertIs(panel.actions[("node", 0)], focused_action)
            self.assertNotIn(description, panel.details.displayed_text)
            self.assertNotIn(description, focused_action.get_accessible().get_description())
            self.assertLess(panel.canvas.get_size_request()[1], visible_height)
            self.assertFalse(panel.get_accept_focus())
            self.assertEqual(commits, [])
            focused_action.clicked()
            self.assertEqual(commits, [("node", 0, False)])
            panel.navigation.confirm.clicked()
            self.assertEqual(commits, [("node", 0, False), ("select", 0, True)])
        finally:
            panel.destroy()


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("DISPLAY") and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires GTK and the real Swift bridge")
class RelativeScoreSettingsWindowTests(unittest.TestCase):
    def test_the_settings_checkbox_saves_hidden_scores_and_reopens_with_the_same_choice(self):
        from azookey.settings import SettingsWindow

        with tempfile.TemporaryDirectory() as directory, patch.dict(
                os.environ, {"AZOOKEY_DATA_DIR": directory, "XDG_CONFIG_HOME": directory}):
            window = SettingsWindow()
            try:
                self.assertTrue(window.widgets["showRelativeScores"].get_active())
                window.widgets["showRelativeScores"].set_active(False)
                window.save(None)
                self.assertFalse(window.bridge.request("settings")["settings"]["showRelativeScores"])
                self.assertFalse(window.settings_store.load(window.values).values["showRelativeScores"])
            finally:
                window.destroy()
            reopened = SettingsWindow()
            try:
                self.assertFalse(reopened.widgets["showRelativeScores"].get_active())
            finally:
                reopened.destroy()


if __name__ == "__main__":
    unittest.main()
