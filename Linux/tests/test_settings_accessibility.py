"""Native controls, keyboard navigation and persistent values after regrouping."""
import json
import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class SettingsAccessibilityTests(unittest.TestCase):
    def setUp(self):
        from azookey.settings import SettingsWindow
        from azookey.settings_store import SettingsStore
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        environment = mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": self.directory.name})
        environment.start()
        self.addCleanup(environment.stop)
        values = dict.fromkeys(
            ("tree", "live", "halfSpace", "backslash", "optionDirect", "aiEnabled", "includeContext",
             "predictiveTyping", "typoCorrection", "debug"), False,
        )
        values.update(candidateTextSize="large", showRelativeScores=True, inputStyle="default", learning="onlyOutput",
                      punctuation=3, personalization="soft", profile="保持するプロフィール", inferenceLimit=10,
                      userDictionary={"items": []}, customTable="", aiModel="fixture",
                      aiEndpoint="https://example.invalid", transformShortcut={"key": "g", "modifiers": 6})
        self.store = SettingsStore()
        self.store.save(values)
        bridge = mock.patch("azookey.settings.Bridge")
        factory = bridge.start()
        self.addCleanup(bridge.stop)
        factory.return_value.request.return_value = {"settings": values, "supportDiagnostics": "azooKey Tree"}
        support = mock.patch("azookey.support_page.renderer_registered", return_value=None)
        support.start()
        self.addCleanup(support.stop)
        self.window = SettingsWindow()
        self.addCleanup(self.window.destroy)
        self.window.show_all()

    def notebook(self):
        from gi.repository import Gtk
        return next(child for child in self.window.get_child().get_children() if isinstance(child, Gtk.Notebook))

    def test_labels_name_the_entry_combo_and_multiline_controls(self):
        from gi.repository import Atk, Gtk
        controls = list(self.window.widgets.values()) + [
            self.window.api_key, self.window.transform_shortcut, self.window.custom_table, self.window.dictionary_button,
        ]
        for control in controls:
            with self.subTest(control=control.get_name()):
                accessible = control.get_accessible()
                self.assertTrue(accessible.get_name())
                if isinstance(control, Gtk.Button):
                    continue
                relation = accessible.ref_relation_set().get_relation_by_type(Atk.RelationType.LABELLED_BY)
                self.assertIsNotNone(relation)
                label = relation.get_target()[0]
                self.assertTrue(label.get_name())

    def test_native_tabs_report_selection_and_preserve_values(self):
        from azookey.i18n import text
        from gi.repository import Atk
        notebook = self.notebook()
        names = [text("settings.page." + key) for key in ("input", "conversion", "dictionary", "ai", "support")]
        self.assertEqual(notebook.get_n_pages(), len(names))
        for index, title in enumerate(names):
            notebook.set_current_page(index)
            page = notebook.get_accessible().ref_accessible_child(index)
            self.assertEqual(page.get_name(), title)
            self.assertTrue(page.ref_state_set().contains_state(Atk.StateType.SELECTED))
        stored = json.loads(self.store.path.read_text())
        self.assertEqual(self.window.widgets["profile"].get_text(), stored["profile"])
        self.assertEqual(self.window.widgets["learning"].get_active_id(), stored["learning"])
        self.assertEqual(self.window.widgets["candidateTextSize"].get_active_id(), stored["candidateTextSize"])
        self.assertEqual(self.window.widgets["personalization"].get_active_id(), stored["personalization"])

    def test_tab_moves_between_ai_fields_in_visual_order(self):
        from gi.repository import Gtk
        self.notebook().set_current_page(3)
        self.window.set_focus(self.window.widgets["aiModel"])
        self.window.child_focus(Gtk.DirectionType.TAB_FORWARD)
        self.assertIs(self.window.get_focus(), self.window.widgets["aiEndpoint"])
        self.window.child_focus(Gtk.DirectionType.TAB_BACKWARD)
        self.assertIs(self.window.get_focus(), self.window.widgets["aiModel"])

    def test_save_error_is_visible_and_published_without_changing_the_file(self):
        from gi.repository import Atk
        original = self.store.path.read_bytes()
        self.window.widgets["inferenceLimit"].set_text("invalid")
        self.window.save(None)
        notice = self.window.message
        self.assertTrue(notice.get_text())
        self.assertEqual(notice.get_accessible().get_role(), Atk.Role.ALERT)
        self.assertEqual(notice.get_accessible().get_name(), notice.get_text())
        self.assertEqual(self.store.path.read_bytes(), original)

    def test_prompt_entry_and_preview_have_labels_and_wait_for_explicit_submit(self):
        from azookey.ai_scope import AIRequestConfiguration, AIRequestScope
        from azookey.i18n import text
        from azookey.prompt_dialog import PromptDialog
        from gi.repository import Gtk
        scope = AIRequestScope(configuration=AIRequestConfiguration(model="fixture", endpoint="https://example.invalid"),
                               target="対象", before="", after="")
        requests = []
        dialog = PromptDialog(lambda *arguments: requests.append(arguments), "敬語に直す", scope=scope,
                              on_context_changed=lambda _: True)
        self.addCleanup(dialog.destroy)
        dialog.show_all()
        self.assertEqual(requests, [])
        self.assertEqual(dialog.entry.get_accessible().get_name(), text("ai.instruction"))
        self.assertEqual(dialog.text.get_accessible().get_name(), text("ai.preview"))
        dialog.entry.emit("activate")
        self.assertEqual(len(requests), 1)
        self.assertFalse(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())
        requests[0][2]("生成した本文")
        self.assertTrue(dialog.get_widget_for_response(Gtk.ResponseType.OK).get_sensitive())


if __name__ == "__main__":
    unittest.main()
