"""Only the active registered renderer can request a real snapshot word."""
import json
from pathlib import Path
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import weakref

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))


class EngineFixture:
    def __init__(self):
        self.focused = True
        self.context_id = "field"
        self.focus_revision = object()
        self.input = SimpleNamespace(pending=False, cancelled=object())
        self.snapshot = {"generation": 3, "inputState": "selecting", "focusedNode": 0,
                         "selection": 0, "selectedPath": [0], "candidates": [{"index": 0}],
                         "nodes": [{"id": 0, "text": "保証", "reading": "ホショウ", "depth": 0,
                                    "parent": None, "terminals": [0]}]}


class InvocationFixture:
    def __init__(self):
        self.values = []
        self.errors = []

    def return_value(self, value):
        self.values.append(value.unpack())

    def return_dbus_error(self, name, message):
        self.errors.append((name, message))


class WordDefinitionSurfaceTests(unittest.TestCase):
    def setUp(self):
        from azookey.shell_surface import ShellSurface
        self.engine = EngineFixture()
        self.surface = ShellSurface.__new__(ShellSurface)
        self.surface.engine = weakref.ref(self.engine)
        self.surface.renderer = ":renderer"
        self.requests = []
        self.worker = SimpleNamespace(request=lambda target, completed: self.requests.append((target, completed)))
        self.replacement = patch("azookey.shell_surface.word_definition_worker", return_value=self.worker)
        self.replacement.start()
        self.addCleanup(self.replacement.stop)

    def request(self, *, sender=":renderer", context="field", generation=3, kind="node", index=0):
        invocation = InvocationFixture()
        parameters = SimpleNamespace(unpack=lambda: (context, generation, kind, index))
        self.surface.method(None, sender, "/org/azookey/Tree", "org.azookey.Tree", "LookupWordDefinitions", parameters, invocation)
        return invocation

    def test_registered_renderer_receives_only_the_resolved_snapshot_word(self):
        invocation = self.request()
        target, completed = self.requests[0]
        self.assertEqual((target.word, target.reading), ("保証", "ホショウ"))
        completed({"status": "found", "word": target.word, "reading": target.reading, "senses": []})
        self.assertEqual(json.loads(invocation.values[0][0])["word"], "保証")
        self.assertEqual(invocation.errors, [])

    def test_unregistered_sender_cannot_trigger_a_dictionary_read(self):
        invocation = self.request(sender=":other")
        self.assertEqual(self.requests, [])
        self.assertTrue(invocation.errors[0][0].endswith(".Busy"))

    def test_wrong_context_or_generation_or_pending_input_does_not_query(self):
        for arguments in ({"context": "other"}, {"generation": 2}):
            self.assertTrue(self.request(**arguments).errors)
        self.engine.input.pending = True
        self.assertTrue(self.request().errors)
        self.assertEqual(self.requests, [])

    def test_focus_epoch_change_discards_a_completed_dictionary_read(self):
        invocation = self.request()
        self.engine.focus_revision = object()
        self.requests[0][1]({"status": "found"})
        self.assertEqual(invocation.values, [])
        self.assertTrue(invocation.errors[0][0].endswith(".Stale"))

    def test_input_reset_or_node_change_discards_a_completed_dictionary_read(self):
        for change in ("epoch", "word"):
            invocation = self.request()
            if change == "epoch":
                self.engine.input.cancelled = object()
            else:
                self.engine.snapshot["nodes"][0]["text"] = "保障"
            self.requests[-1][1]({"status": "found"})
            self.assertEqual(invocation.values, [])
            self.assertTrue(invocation.errors)

    def test_only_the_latest_renderer_request_can_complete_with_definitions(self):
        first = self.request()
        latest = self.request()
        self.requests[0][1]({"status": "found"})
        self.requests[1][1]({"status": "found"})
        self.assertTrue(first.errors)
        self.assertEqual(first.values, [])
        self.assertEqual(len(latest.values), 1)
        self.assertEqual(latest.errors, [])

    def test_latest_missing_target_retires_the_previous_dictionary_reply(self):
        first = self.request()
        latest = self.request(index=999)
        self.assertEqual(json.loads(latest.values[0][0])["status"], "noTarget")
        self.requests[0][1]({"status": "found"})
        self.assertEqual(first.values, [])
        self.assertTrue(first.errors[0][0].endswith(".Stale"))

    def test_renderer_replacement_does_not_receive_previous_renderer_result(self):
        invocation = self.request()
        self.surface.renderer = ":replacement"
        self.requests[0][1]({"status": "found"})
        self.assertEqual(invocation.values, [])
        self.assertTrue(invocation.errors)

    def test_arbitrary_query_kind_is_not_a_sql_or_file_interface(self):
        self.assertTrue(self.request(kind="SELECT * FROM word").errors)
        self.assertEqual(self.requests, [])


if __name__ == "__main__":
    unittest.main()
