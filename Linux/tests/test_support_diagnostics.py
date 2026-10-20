import os
import pathlib
import sys
import tempfile
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.i18n import text as message
from azookey.support_diagnostics import diagnostics, read_build_info, renderer_status


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


class SupportDiagnosticsTests(unittest.TestCase):
    def test_build_info_ignores_unknown_keys_and_invalid_values(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "build-info.txt"
            path.write_text("version=0.1.2\narchitecture=amd64\nsource=0123456789abcdef\napiKey=PRIVATE_KEY\n", encoding="utf-8")
            self.assertEqual(read_build_info(path), {"version": "0.1.2", "architecture": "amd64", "source": "0123456789abcdef"})
            path.write_text("version=PRIVATE_TEXT\narchitecture=PRIVATE_CPU\nsource=PRIVATE_DOCUMENT\n", encoding="utf-8")
            self.assertEqual(read_build_info(path), {})
            path.write_bytes(b"\xff")
            self.assertEqual(read_build_info(path), {})
            self.assertEqual(read_build_info(path.with_name("absent")), {})

    def test_report_excludes_document_dictionary_history_api_key_and_user_environment(self):
        report = diagnostics(
            tree_enabled=True, engine_status={"rendererRegistered": False, "document": "PRIVATE_DOCUMENT"},
            build_info={"version": "0.1.2", "architecture": "arm64", "source": "0123456789abcdef",
                        "dictionary": "PRIVATE_DICTIONARY", "history": "PRIVATE_HISTORY", "apiKey": "PRIVATE_KEY"},
            environment={"XDG_SESSION_TYPE": "wayland", "HOME": "/home/PRIVATE_USER", "API_KEY": "PRIVATE_ENV"},
            os_release={"ID": "ubuntu", "VERSION_ID": "24.04", "PRETTY_NAME": "PRIVATE_OS_EXTRA"},
            architecture="aarch64",
        )
        self.assertNotIn("PRIVATE_", report)
        for value in ("0.1.2", "ubuntu 24.04", "aarch64", "arm64", "0123456789abcdef"):
            self.assertIn(value, report)
        self.assertIn(message("support.renderer.ibus-list"), report)
        self.assertIn(message("support.fallback.extension"), report)

    def test_unknown_environment_does_not_claim_a_working_renderer(self):
        report = diagnostics(tree_enabled=True, engine_status=None,
                             environment={"XDG_SESSION_TYPE": "PRIVATE_SESSION"},
                             build_info={"version": "PRIVATE_VERSION"}, os_release={"ID": "PRIVATE OS"})
        self.assertNotIn("PRIVATE", report)
        self.assertIn(message("support.fallback.unavailable"), report)

    def test_renderer_reason_distinguishes_setting_extension_and_missing_engine(self):
        cases = [
            (False, "wayland", None, "support.renderer.ibus-list", "support.fallback.setting"),
            (True, "x11", {}, "support.renderer.gtk-tree", "support.none"),
            (True, "wayland", {"rendererRegistered": True}, "support.renderer.shell-tree", "support.none"),
            (True, "wayland", {"rendererRegistered": False}, "support.renderer.ibus-list", "support.fallback.extension"),
            (True, "wayland", None, "support.unknown", "support.fallback.unavailable"),
        ]
        for tree, session, status, renderer, reason in cases:
            with self.subTest(session=session, status=status, tree=tree):
                self.assertEqual(renderer_status(tree_enabled=tree, session=session, engine_status=status),
                                 (message(renderer), message(reason)))


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class SupportPageTests(unittest.TestCase):
    def test_missing_engine_on_a_real_session_bus_is_reported_as_unavailable(self):
        from azookey.support_page import engine_status
        self.assertIsNone(engine_status())

    def test_learning_reset_uses_the_bridge_when_the_session_has_no_engine(self):
        from azookey.settings import SettingsWindow
        from gi.repository import Gtk
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}), \
                mock.patch("azookey.settings.Bridge") as factory, \
                mock.patch.object(Gtk, "main_quit"):
            factory.return_value.request.return_value = {"settings": settings_fixture()}
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
        defaults = settings_fixture()
        with tempfile.TemporaryDirectory() as directory, mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": directory}), \
                mock.patch("azookey.settings.Bridge") as bridge, \
                mock.patch("azookey.support_page.engine_status", return_value=None), \
                mock.patch.object(Gtk, "main_quit"):
            bridge.return_value.request.return_value = {"settings": defaults}
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

    def test_copy_contains_only_the_visible_allowlisted_report(self):
        from azookey.support_page import SupportPage
        from gi.repository import Gdk, Gtk
        with mock.patch("azookey.support_page.engine_status", return_value={"rendererRegistered": False}):
            page = SupportPage(lambda: {"tree": False, "profile": "PRIVATE_PROFILE", "apiKey": "PRIVATE_KEY"})
            try:
                page.copy(None)
                copied = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD).wait_for_text()
                self.assertEqual(copied, page.report_text)
                self.assertNotIn("PRIVATE_", copied)
                self.assertIn(message("support.renderer.ibus-list"), copied)
                self.assertEqual(page.notice.get_text(), message("support.copied"))
            finally:
                page.destroy()


if __name__ == "__main__":
    unittest.main()
