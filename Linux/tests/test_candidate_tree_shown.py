"""Whether the candidate window shows the tree reaches Core with each key."""
import os
import pathlib
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
try:
    from gi.repository import Gio, GLib
    from azookey.shell_surface import NAME, PATH, XML, ShellSurface
except (ImportError, ValueError):
    ShellSurface = None

LEFT, UP, RIGHT, DOWN, SPACE = 0xFF51, 0xFF52, 0xFF53, 0xFF54, 32


@unittest.skipUnless(ShellSurface, "requires PyGObject")
class ShellTreeReportTests(unittest.TestCase):
    """The GNOME renderer reports its tree button; the engine keeps it per input context."""

    def setUp(self):
        with mock.patch("azookey.shell_surface.Gio.bus_own_name"):
            self.surface = ShellSurface()
        self.surface.connection = mock.Mock()
        self.surface.renderer = ":1.42"
        self.engine = SimpleNamespace(context_id="document")

    def report(self, shown, context="document", sender=":1.42"):
        invocation = mock.Mock()
        self.surface.method(None, sender, PATH, NAME, "SetTreeShown",
                            GLib.Variant("(bs)", (shown, context)), invocation)
        return invocation

    def test_the_bus_contract_declares_the_tree_report(self):
        method = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0].lookup_method("SetTreeShown")
        self.assertEqual([argument.signature for argument in method.in_args], ["b", "s"])
        self.assertEqual(method.out_args, [])

    def test_the_renderer_opens_and_closes_the_tree_of_its_input_context(self):
        self.report(True).return_value.assert_called_once()
        self.assertTrue(self.surface.shows_tree(self.engine))
        self.assertFalse(self.surface.shows_tree(SimpleNamespace(context_id="another-document")))
        self.report(False)
        self.assertFalse(self.surface.shows_tree(self.engine))

    def test_another_client_cannot_report_the_tree(self):
        invocation = self.report(True, sender=":1.99")
        invocation.return_dbus_error.assert_called_once()
        self.assertFalse(self.surface.shows_tree(self.engine))

    def test_hiding_the_candidates_or_losing_the_renderer_forgets_the_tree(self):
        self.report(True)
        self.surface.hide(SimpleNamespace(context_id="another-document"))
        self.assertTrue(self.surface.shows_tree(self.engine))
        self.surface.hide(self.engine)
        self.assertFalse(self.surface.shows_tree(self.engine))
        self.report(True)
        self.surface.lost()
        self.assertFalse(self.surface.shows_tree(self.engine))


@unittest.skipUnless(ShellSurface, "requires PyGObject")
class EngineTreeFactTests(unittest.TestCase):
    """The engine reports the tree of whichever renderer shows the candidates."""

    @classmethod
    def setUpClass(cls):
        try:
            from azookey.engine import Engine
        except (ImportError, ValueError):
            raise unittest.SkipTest("IBus GI dependencies are unavailable")
        cls.engine_type = Engine

    def facts(self, *, panel_tree, shell_tree):
        shell = mock.Mock()
        shell.shows_tree.return_value = shell_tree
        engine = SimpleNamespace(panel=SimpleNamespace(tree_expanded=panel_tree), context_id="document")
        with mock.patch("azookey.engine.surface", return_value=shell):
            return self.engine_type.candidate_display_facts(engine)

    def test_either_renderer_showing_the_tree_is_reported(self):
        self.assertEqual(self.facts(panel_tree=False, shell_tree=False), {"treeShown": False})
        self.assertEqual(self.facts(panel_tree=True, shell_tree=False), {"treeShown": True})
        self.assertEqual(self.facts(panel_tree=False, shell_tree=True), {"treeShown": True})


@unittest.skipUnless(os.environ.get("DISPLAY") and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires an isolated GTK display and the Swift bridge")
class TreeButtonKeyTests(unittest.TestCase):
    """The GTK tree button decides what ↑/↓ do in Core."""

    def setUp(self):
        from azookey.bridge import Bridge
        from candidate_core import core_tree_panel
        directory = tempfile.TemporaryDirectory(prefix="azookey-tree-shown-")
        self.addCleanup(directory.cleanup)
        self.bridge = Bridge(environment={
            **os.environ, "AZOOKEY_DATA_DIR": directory.name, "XDG_CONFIG_HOME": directory.name,
        })
        self.addCleanup(self.bridge.close)
        settings = self.bridge.request("settings")["settings"]
        self.bridge.request("configure", settings={**settings, "tree": True, "live": True, "learning": "nothing"})
        self.panel = core_tree_panel(lambda *_: None)
        self.addCleanup(self.panel.destroy)
        shell = mock.Mock()
        shell.shows_tree.return_value = False
        surface_patch = mock.patch("azookey.engine.surface", return_value=shell)
        surface_patch.start()
        self.addCleanup(surface_patch.stop)
        self.engine = SimpleNamespace(panel=self.panel, context_id="document")

    def key(self, keyval):
        from azookey.engine import Engine
        from azookey.keymap import translate
        snapshot = self.bridge.request("key", event=translate(keyval, 0),
                                       candidateDisplay=Engine.candidate_display_facts(self.engine))
        self.panel.update(snapshot)
        self.flush()
        return snapshot

    @staticmethod
    def flush():
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    @staticmethod
    def focused_word(snapshot):
        return next(node for node in snapshot["nodes"] if node["id"] == snapshot["focusedNode"])

    def toggle_tree(self):
        self.panel.disclosure_actions["tree"].clicked()
        self.flush()

    def test_down_follows_the_tree_button_after_the_tree_was_asked_for(self):
        for character in "watashihanihongowobenkyoushiteimasu":
            self.key(ord(character))
        self.key(SPACE)
        self.key(SPACE)
        self.key(RIGHT)
        self.assertTrue(self.key(RIGHT)["candidateDisplay"]["expandTree"])
        self.assertTrue(self.panel.tree_expanded)
        # Back on the first word, whose alternatives such as 私 and 渡し are siblings.
        shown = self.key(LEFT)
        for _ in range(4):
            if self.focused_word(shown)["depth"] == 0:
                break
            shown = self.key(LEFT)
        first, focused = shown["selection"], self.focused_word(shown)

        self.toggle_tree()
        self.assertFalse(self.panel.tree_expanded)
        self.assertEqual(self.key(DOWN)["selection"], first + 1)
        self.assertEqual(self.key(UP)["selection"], first)

        self.toggle_tree()
        self.assertTrue(self.panel.tree_expanded)
        opened = self.key(DOWN)
        moved = self.focused_word(opened)
        self.assertNotEqual(opened["selection"], first + 1)
        self.assertNotEqual(moved["id"], focused["id"])
        # Core omits the parent of a first word.
        self.assertEqual((moved.get("parent"), moved["depth"]), (focused.get("parent"), focused["depth"]))


if __name__ == "__main__":
    unittest.main()
