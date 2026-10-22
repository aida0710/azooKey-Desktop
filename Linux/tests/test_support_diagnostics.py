import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.i18n import text as message
from azookey.support_diagnostics import component_version


def settings_fixture():
    defaults = dict.fromkeys(
        ("tree", "live", "halfSpace", "backslash", "optionDirect", "aiEnabled", "includeContext",
         "predictiveTyping", "typoCorrection", "debug"), False,
    )
    defaults.update(candidateTextSize="standard", showRelativeScores=True, inputStyle="default", learning="inputAndOutput",
                    punctuation=1, personalization="off", profile="", inferenceLimit=10,
                    userDictionary={"items": []}, customTable="", aiModel="fixture",
                    aiEndpoint="https://example.invalid", transformShortcut=None)
    return defaults


class ComponentVersionTests(unittest.TestCase):
    def test_ibus_component_uses_only_a_recognized_packaged_version(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "build-info.txt"
            with mock.patch("azookey.support_diagnostics.BUILD_INFO_PATH", path):
                self.assertEqual(component_version(), "development")
                path.write_text("source=0123456789abcdef\nversion=0.2.0\n", encoding="utf-8")
                self.assertEqual(component_version(), "0.2.0")
                path.write_text("version=PRIVATE_TEXT\n", encoding="utf-8")
                self.assertEqual(component_version(), "development")


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class SupportPageTests(unittest.TestCase):
    def test_missing_engine_on_a_real_session_bus_is_reported_as_unavailable(self):
        from azookey.support_page import renderer_registered
        self.assertIsNone(renderer_registered())

    def test_learning_reset_uses_the_bridge_when_the_session_has_no_engine(self):
        from azookey.settings import SettingsWindow
        from gi.repository import Gtk
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}), \
                mock.patch("azookey.settings.Bridge") as factory, \
                mock.patch.object(Gtk, "main_quit"):
            factory.return_value.request.return_value = {"settings": settings_fixture(), "supportDiagnostics": "azooKey Tree"}
            window = SettingsWindow()
            try:
                factory.return_value.request.reset_mock()
                factory.return_value.request.return_value = {}
                with mock.patch.object(Gtk.MessageDialog, "run", return_value=Gtk.ResponseType.OK):
                    window.reset_learning(None)
                window.bridge.request.assert_called_once_with("reset-learning")
                self.assertEqual(window.message.get_text(), message("learning.reset.completed"))
            finally:
                window.destroy()

    def test_first_settings_visit_opens_the_guide_and_saved_settings_keep_the_input_page(self):
        from azookey.settings import SettingsWindow
        from gi.repository import Gtk
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}), \
                mock.patch("azookey.settings.Bridge") as bridge, \
                mock.patch("azookey.support_page.renderer_registered", return_value=None), \
                mock.patch.object(Gtk, "main_quit"):
            bridge.return_value.request.return_value = {"settings": settings_fixture(), "supportDiagnostics": "azooKey Tree"}
            for existing_settings in (False, True):
                with self.subTest(existing_settings=existing_settings):
                    if existing_settings:
                        path = pathlib.Path(directory) / "azookey-tree/settings.json"
                        path.parent.mkdir()
                        path.write_text("{}")
                    window = SettingsWindow()
                    try:
                        window.show_all()
                        book = next(child for child in window.get_child().get_children() if isinstance(child, Gtk.Notebook))
                        self.assertEqual(book.get_current_page(), 0 if existing_settings else book.get_n_pages() - 1)
                    finally:
                        window.destroy()

    @unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "build the real Swift bridge first")
    def test_copy_contains_only_core_s_allowlisted_report(self):
        from azookey.bridge import Bridge
        from azookey.support_page import SupportPage
        from gi.repository import Gdk, Gtk
        bridge = Bridge()
        private_environment = {"XDG_SESSION_TYPE": "PRIVATE_SESSION", "API_KEY": "PRIVATE_ENVIRONMENT"}
        try:
            with mock.patch("azookey.support_page.renderer_registered", return_value=False), \
                    mock.patch.dict(os.environ, private_environment):
                page = SupportPage(lambda: {"tree": False, "profile": "PRIVATE_PROFILE", "apiKey": "PRIVATE_KEY"}, bridge)
                try:
                    page.copy(None)
                    copied = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text()
                    self.assertEqual(copied, page.report_text)
                    self.assertNotIn("PRIVATE_", copied)
                    self.assertIn(f"{message('support.renderer')}: {message('support.renderer.ibus-list')}", copied.splitlines())
                    self.assertIn(f"{message('support.fallback')}: {message('support.fallback.setting')}", copied.splitlines())
                    self.assertIn(f"{message('support.session')}: {message('support.unknown')}", copied.splitlines())
                    self.assertEqual(page.notice.get_text(), message("support.copied"))
                finally:
                    page.destroy()
        finally:
            bridge.close()


if __name__ == "__main__":
    unittest.main()
