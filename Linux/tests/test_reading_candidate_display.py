"""Display mode never selects a candidate or changes the formal reading state."""
from copy import deepcopy
import unittest

from azookey.candidate_protocol import reference as batch_reference
from azookey.reading_candidate_display import MAX_DISPLAY_GENERATION, ReadingCandidateDisplay
from candidate_fixture import CandidateBridgeFixture, candidate_request
from reading_candidate_view_fixture import candidate_view
from test_reading_frontend import reading_snapshot


class ReadingCandidateDisplayTests(unittest.TestCase):
    def setUp(self):
        self.request = candidate_request("にほんご")
        self.batch = CandidateBridgeFixture().request("candidates", request=self.request)["batch"]
        first = self.batch["candidates"][0]
        first.update(text="日本語", composingCount={"kind": "surfaceCount", "count": 4})
        self.batch["candidates"].append({**deepcopy(first), "candidateID": "same-text-other-reading"})
        self.reference = {name: self.request["authority"][name]
                          for name in ("context", "readingProcessGeneration", "focusEpoch")}
        self.snapshot = reading_snapshot("にほんご")
        self.view = candidate_view(self.batch)
        self.display = ReadingCandidateDisplay("renderer-context")

    def update(self, view=None, snapshot=None):
        return self.display.update(snapshot or self.snapshot, self.view if view is None else view,
                                   reference=self.reference)

    def selection(self, operation="select", index=0, **changes):
        return self.display.selection(operation, index, **{
            "generation": self.display.generation, "reference": self.reference,
            "retained_reference": batch_reference(self.batch), **changes,
        })

    def test_arrival_shows_a_menu_without_selecting_or_replacing_the_formal_reading(self):
        snapshot, view = deepcopy(self.snapshot), deepcopy(self.view)
        displayed = self.update()
        self.assertEqual(displayed["candidateDisplayMode"], "menu")
        self.assertEqual(displayed["inputState"], "composing")
        self.assertEqual(displayed["preedit"], "にほんご")
        self.assertNotIn("selection", displayed)
        self.assertFalse(displayed["showCandidateIndex"])
        self.assertEqual([candidate["text"] for candidate in displayed["candidates"]], ["日本語", "日本語"])
        self.assertEqual((self.snapshot, self.view), (snapshot, view))

    def test_display_has_no_input_effects_and_cannot_mutate_its_retained_source(self):
        snapshot = {**self.snapshot, "commits": ["already-applied"], "candidateCompletions": ["already-queued"]}
        displayed = self.update(snapshot=snapshot)
        self.assertEqual(displayed["commits"], [])
        self.assertEqual(displayed["candidateCompletions"], [])
        displayed["candidates"][0]["candidateID"] = "changed-outside"
        displayed["candidateReference"]["batchID"] = "changed-outside"
        self.assertEqual(self.selection()["candidateID"], self.batch["candidates"][0]["candidateID"])
        self.assertEqual(snapshot["commits"], ["already-applied"])
        self.assertEqual(self.display.snapshot["candidateReference"], batch_reference(self.batch))

    def test_same_text_keeps_distinct_candidate_ids_in_the_original_order(self):
        self.update()
        first, second = self.selection(index=0), self.selection(index=1)
        self.assertEqual(first["batch"], second["batch"])
        self.assertNotEqual(first["candidateID"], second["candidateID"])
        self.assertEqual(second["candidateID"], "same-text-other-reading")

    def test_shared_node_uses_cores_preview_candidate_instead_of_its_terminal(self):
        view = deepcopy(self.view)
        view["nodes"][0]["preview"]["candidateIndex"] = 1
        self.update(view)
        self.assertEqual(view["nodes"][0]["terminals"], [0])
        self.assertEqual(self.selection("node", 0)["candidateID"], "same-text-other-reading")
        view["nodes"][0].pop("preview")
        self.update(view)
        self.assertIsNone(self.selection("node", 0))

    def test_only_a_formal_selection_changes_the_enter_confirmation_state(self):
        self.update()
        snapshot = {**self.snapshot, "preedit": "日本語", "selection": 1,
                    "inputState": "selecting", "showCandidateIndex": True}
        displayed = self.update(candidate_view(self.batch, selection=1, show_indices=True), snapshot)
        self.assertEqual(displayed["selection"], 1)
        self.assertEqual(displayed["inputState"], "selecting")
        self.assertEqual(displayed["preedit"], "日本語")

    def test_old_display_generation_or_retained_batch_cannot_select_a_current_candidate(self):
        self.update()
        old_generation = self.display.generation
        old_reference = batch_reference(self.batch)
        self.batch["authority"]["requestID"] = "next-request"
        self.view = candidate_view(self.batch)
        self.update()
        self.assertIsNone(self.selection(generation=old_generation))
        self.assertIsNone(self.selection(retained_reference=old_reference))
        self.assertIsNotNone(self.selection())

    def test_other_focus_context_or_process_cannot_use_this_display(self):
        self.update()
        for field, changed in (("context", "other-field"), ("focusEpoch", 999),
                               ("readingProcessGeneration", "other-process")):
            with self.subTest(field=field):
                self.assertIsNone(self.selection(reference={**self.reference, field: changed}))

    def test_pending_input_retires_actions_until_a_new_acknowledged_view(self):
        displayed = self.update()
        self.display.suspend()
        self.assertEqual(self.display.snapshot, displayed)
        self.assertIsNone(self.selection())
        self.update()
        self.assertIsNone(self.selection(generation=displayed["generation"]))
        self.assertIsNotNone(self.selection())

    def test_retirement_or_an_empty_view_cannot_leave_a_selectable_old_id(self):
        self.update()
        self.display.retire()
        self.assertEqual(self.display.snapshot, {})
        self.assertIsNone(self.selection())
        self.update()
        displayed = self.display.update(self.snapshot, None, reference=self.reference)
        self.assertEqual(displayed["candidates"], [])
        self.assertIsNone(self.selection())

    def test_invalid_new_view_does_not_reactivate_the_previous_actions(self):
        self.update()
        view = deepcopy(self.view)
        view["candidateReference"]["authority"]["focusEpoch"] += 1
        with self.assertRaises(ValueError):
            self.update(view)
        self.assertIsNone(self.selection())

    def test_unknown_or_non_integer_actions_do_not_resolve_to_real_ids(self):
        self.update()
        for operation, index in (("submit", 0), ("select", True), ("select", -1),
                                  ("select", 2), ("node", 999), ("node", "0")):
            with self.subTest(operation=operation, index=index):
                self.assertIsNone(self.selection(operation, index))
        self.assertIsNone(self.selection(generation=True))

    def test_generation_exhaustion_never_wraps_to_an_old_action(self):
        self.update()
        self.display.generation = MAX_DISPLAY_GENERATION
        with self.assertRaises(RuntimeError):
            self.update()
        self.assertIsNone(self.selection())


if __name__ == "__main__":
    unittest.main()
