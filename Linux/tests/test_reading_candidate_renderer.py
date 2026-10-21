"""Real GTK/AT actions use retained IDs without changing the input on arrival."""
from copy import deepcopy
import os
from types import MethodType
import unittest
from unittest import mock

from azookey.reading_frontend import ReadingFrontend
from azookey.reading_protocol import ReadingCandidates
from candidate_fixture import CandidateBridgeFixture, candidate_request
from reading_candidate_view_fixture import candidate_view
from test_reading_frontend import ManualReadingCoordinator, reading_snapshot


class RendererEngineFixture:
    def __init__(self, shell):
        from azookey.reading_candidate_renderer import ReadingCandidateRenderer
        from azookey.reading_engine import ReadingEngine
        from gi.repository import IBus

        self.private = False
        self.candidate_tree_enabled = True
        self.preedits, self.commits, self.replies, self.lookups = [], [], [], []
        self.notices = []
        self.table = IBus.LookupTable.new(9, 0, True, True)
        self.renderer = None
        self.render_input = MethodType(ReadingEngine.render_input, self)
        self.render_candidates = MethodType(ReadingEngine.render_candidates, self)
        self.choose = MethodType(ReadingEngine.choose, self)
        self.candidate_renderer_lost = MethodType(ReadingEngine.candidate_renderer_lost, self)
        self.frontend = ReadingFrontend(
            lambda callback, *args: callback(*args), render_input=self.render_input,
            render_candidates=self.render_candidates, notify=self.notice,
            coordinator_factory=ManualReadingCoordinator,
        )
        self.renderer = ReadingCandidateRenderer(self, select_candidate=self.frontend.select_candidate, shell=shell)
        self.frontend.focus_in({"leftContext": "", "rightContext": "", "privateInput": False})

    @property
    def context_id(self):
        return self.frontend.context

    @property
    def focused(self):
        return self.frontend.focused

    @property
    def snapshot(self):
        return self.renderer.snapshot

    @property
    def panel(self):
        return self.renderer.panel

    def commit_text(self, value):
        self.commits.append(value.get_text())

    def update_preedit_text_with_mode(self, value, cursor, visible, mode):
        self.preedits.append((value.get_text(), cursor, visible, mode))

    def update_lookup_table(self, table, visible):
        self.lookups.append((visible, [table.get_candidate(index).get_text()
                                      for index in range(table.get_number_of_candidates())]))

    def hide_lookup_table(self):
        self.lookups.append((False, []))

    def notice(self, notice):
        self.notices.append(notice)

    def key(self):
        self.renderer.suspend()
        self.frontend.key({}, self.replies.append)
        return self.frontend.coordinator.operations[-1]

    def close(self):
        self.frontend.close()
        self.renderer.close()


@unittest.skipUnless(os.environ.get("DISPLAY"), "requires an isolated GTK display")
class ReadingCandidateRendererTests(unittest.TestCase):
    def setUp(self):
        from azookey.shell_surface import ShellSurface
        from gi.repository import Gtk

        with mock.patch("azookey.shell_surface.Gio.bus_own_name"):
            self.shell = ShellSurface()
        self.shell.connection = mock.Mock()
        self.engine = RendererEngineFixture(self.shell)
        self.document = Gtk.Window()
        self.field = Gtk.Entry()
        self.document.add(self.field)
        self.document.show_all()
        self.field.grab_focus()
        self.deliver(self.engine.key(), reading_snapshot("にほんご"))
        request = candidate_request("にほんご", **{
            "context": self.engine.frontend.context, "generation": "reader", "focus": 1,
        })
        self.batch = CandidateBridgeFixture().request("candidates", request=request)["batch"]
        item = self.batch["candidates"][0]
        item.update(text="日本語", composingCount={"kind": "surfaceCount", "count": 4})
        self.batch["candidates"].append({**deepcopy(item), "candidateID": "same-text-distinct-id"})
        self.view = candidate_view(self.batch)
        self.arrive()

    def tearDown(self):
        self.engine.close()
        self.document.destroy()
        self.flush()

    @staticmethod
    def flush():
        from gi.repository import GLib
        context = GLib.MainContext.default()
        while context.pending():
            context.iteration(False)

    def arrive(self):
        frontend = self.engine.frontend
        self.assertTrue(frontend._publish_candidates(ReadingCandidates(
            frontend.context, deepcopy(frontend.reference), deepcopy(self.batch), candidate_view=deepcopy(self.view))))
        self.flush()

    def deliver(self, operation, snapshot, view=None):
        coordinator = self.engine.frontend.coordinator
        self.assertTrue(coordinator.deliver(operation, snapshot, view))
        coordinator.finish(operation)
        self.flush()

    def test_arrival_uses_the_menu_but_has_no_input_or_automatic_selection_effect(self):
        self.assertEqual(len(self.engine.preedits), 1)
        self.assertEqual(self.engine.preedits[-1][0], "にほんご")
        self.assertEqual(self.engine.commits, [])
        self.assertEqual(self.engine.replies, [True])
        self.assertEqual(self.engine.frontend.snapshot["inputState"], "composing")
        self.assertNotIn("selection", self.engine.frontend.snapshot)
        self.assertTrue(self.engine.panel.navigation.expanded)
        self.assertFalse(self.engine.panel.navigation.confirm.get_sensitive())
        self.assertIs(self.document.get_focus(), self.field)

    def test_at_select_then_distinct_confirmation_uses_the_same_retained_id_once(self):
        row = self.engine.panel.navigation.row_buttons[1]
        self.assertTrue(row.get_accessible().do_action(0))
        self.flush()
        operation = self.engine.frontend.coordinator.operations[-1]
        self.assertEqual(operation.operation, "select")
        self.assertEqual(operation.selection["candidateID"], "same-text-distinct-id")
        self.assertEqual(self.engine.commits, [])
        self.assertFalse(self.engine.choose("select", 0, True))
        selected = {**reading_snapshot("にほんご"), "preedit": "日本語", "cursor": 3,
                    "inputState": "selecting", "selection": 1, "showCandidateIndex": True}
        view = candidate_view(self.batch, selection=1, show_indices=True)
        self.deliver(operation, selected, view)
        count = len(self.engine.frontend.coordinator.operations)
        row.clicked()
        self.assertEqual(len(self.engine.frontend.coordinator.operations), count)
        confirm = self.engine.panel.navigation.confirm
        self.assertTrue(confirm.get_accessible().do_action(0))
        self.flush()
        committed = self.engine.frontend.coordinator.operations[-1]
        self.assertEqual(committed.operation, "commit-candidate")
        self.assertEqual(committed.selection, operation.selection)
        confirm.clicked()
        self.assertEqual(len(self.engine.frontend.coordinator.operations), count + 1)
        self.deliver(committed, reading_snapshot("", revision=2, commits=("日本語",)))
        self.assertEqual(self.engine.commits, ["日本語"])
        self.assertEqual(self.engine.replies, [True])
        self.assertIs(self.document.get_focus(), self.field)

    def test_native_lookup_click_commits_the_exact_id_without_a_select_or_fake_enter(self):
        self.engine.candidate_tree_enabled = False
        self.engine.renderer.renderer_lost()
        self.assertFalse(self.engine.panel.get_visible())
        self.assertEqual(self.engine.lookups[-1], (True, ["日本語", "日本語"]))
        count = len(self.engine.frontend.coordinator.operations)
        self.assertTrue(self.engine.renderer.lookup_clicked(1))
        operation = self.engine.frontend.coordinator.operations[-1]
        self.assertEqual(operation.operation, "commit-candidate")
        self.assertEqual(operation.selection["candidateID"], "same-text-distinct-id")
        self.assertFalse(self.engine.renderer.lookup_clicked(1))
        self.assertEqual(len(self.engine.frontend.coordinator.operations), count + 1)
        self.deliver(operation, reading_snapshot("", revision=2, commits=("日本語",)))
        self.assertEqual(self.engine.commits, ["日本語"])

    def test_old_shell_generation_focus_and_sender_cannot_activate_a_current_id(self):
        from gi.repository import GLib
        self.shell.renderer = ":1.42"
        self.engine.renderer.renderer_lost()
        generation = self.engine.snapshot["generation"]
        self.engine.renderer.renderer_lost()
        count = len(self.engine.frontend.coordinator.operations)

        def select(sender, shown_generation, context):
            self.shell.method(None, sender, None, None, "Select", GLib.Variant(
                "(sibis)", ("select", 1, True, shown_generation, context)), mock.Mock())

        select(":1.99", self.engine.snapshot["generation"], self.engine.context_id)
        select(":1.42", generation, self.engine.context_id)
        select(":1.42", self.engine.snapshot["generation"], "other-field")
        self.assertEqual(len(self.engine.frontend.coordinator.operations), count)
        select(":1.42", self.engine.snapshot["generation"], self.engine.context_id)
        self.assertEqual(len(self.engine.frontend.coordinator.operations), count + 1)
        self.assertEqual(self.engine.frontend.coordinator.operations[-1].operation, "commit-candidate")

    def test_pending_renderer_loss_does_not_resurrect_old_candidates_or_republish_preedit(self):
        self.shell.renderer = ":1.42"
        self.engine.renderer.renderer_lost()
        old_generation = self.engine.snapshot["generation"]
        self.engine.key()
        before = deepcopy(self.engine.preedits)
        self.shell.lost()
        self.assertFalse(self.engine.panel.get_visible())
        self.assertFalse(self.engine.renderer.display.active)
        self.assertEqual(self.engine.snapshot["generation"], old_generation)
        self.assertEqual(self.engine.preedits, before)
        self.assertFalse(self.engine.choose("select", 0, True))

    def test_focus_reentry_during_shell_publication_cannot_show_the_old_fallback(self):
        shell_show = self.shell.show

        def change_focus(*arguments):
            self.shell.show = shell_show
            self.engine.frontend.focus_out()
            self.engine.frontend.focus_in({"leftContext": "second-field", "rightContext": "", "privateInput": False})
            return False

        self.shell.show = change_focus
        self.engine.renderer.renderer_lost()
        self.assertFalse(self.engine.panel.get_visible())
        self.assertEqual(self.engine.snapshot, {})
        self.assertFalse(self.engine.renderer.display.active)
        self.assertFalse(self.engine.choose("select", 0, True))
        self.assertEqual(self.engine.commits, [])

    def test_widget_failure_retires_actions_and_cannot_block_cleanup_or_new_input(self):
        from gi.repository import GLib
        with mock.patch.object(self.engine.panel, "update", side_effect=GLib.Error("synthetic paint failure")):
            with self.assertLogs("azookey.reading_candidate_renderer", level="ERROR"):
                self.engine.renderer.renderer_lost()
        self.assertFalse(self.engine.renderer.display.active)
        self.assertFalse(self.engine.choose("select", 0, True))
        self.assertEqual(self.engine.notices[-1].code, "reading_view_unavailable")
        with mock.patch.object(self.shell, "suspend", side_effect=GLib.Error("synthetic cleanup failure")):
            with self.assertLogs("azookey.reading_candidate_renderer", level="ERROR"):
                operation = self.engine.key()
        self.assertFalse(self.engine.panel.get_visible())
        self.deliver(operation, reading_snapshot("にほんごあ", revision=2))
        self.assertEqual(self.engine.preedits[-1][0], "にほんごあ")
        self.assertEqual(self.engine.replies, [True, True])


if __name__ == "__main__":
    unittest.main()
