"""Display messages preserve retained candidate identity and contain no input effects."""
from copy import deepcopy
import unittest

from azookey.reading_candidate_view import validate_view
from azookey import reading_protocol
from candidate_fixture import CandidateBridgeFixture, candidate_request
from reading_candidate_view_fixture import candidate_view
from test_reading_frontend import reading_snapshot


class ReadingCandidateViewTests(unittest.TestCase):
    def setUp(self):
        self.request = candidate_request("にほんご")
        self.batch = CandidateBridgeFixture().request("candidates", request=self.request)["batch"]
        self.reference = {name: self.request["authority"][name] for name in reading_protocol.REFERENCE_FIELDS}
        self.view = candidate_view(self.batch)

    def validate(self, value):
        return validate_view(value, expected_reference=self.reference, batch=self.batch)

    def test_a_view_keeps_original_id_order_without_selecting_or_inserting(self):
        view = self.validate(self.view)
        self.assertEqual(view, self.view)
        self.assertIsNot(view, self.view)
        self.assertNotIn("selection", view)
        self.assertEqual(view["candidates"][0]["candidateID"], self.batch["candidates"][0]["candidateID"])

    def test_an_old_focus_revision_or_batch_cannot_supply_current_display_actions(self):
        for container, field in (("authority", "focusEpoch"), ("authority", "compositionRevision"),
                                 ("authority", "settingsRevision"), ("root", "batchID"), ("root", "workerGeneration")):
            with self.subTest(field=field):
                view = deepcopy(self.view)
                source = view["candidateReference"]
                target = source["authority"] if container == "authority" else source
                target[field] = target[field] + 1 if type(target[field]) is int else "old"
                with self.assertRaises(ValueError):
                    self.validate(view)

    def test_identical_text_cannot_authorize_another_candidate_id(self):
        view = deepcopy(self.view)
        view["candidates"][0]["candidateID"] = "same-text-other-id"
        with self.assertRaises(ValueError):
            self.validate(view)

    def test_a_preview_cannot_change_the_candidate_text_scope_or_annotation(self):
        for field, value in (("text", "偽の組合せ"), ("scope", {"consumedReading": "別", "remainingReading": ""}),
                             ("annotation", "other"), ("candidateIndex", 999)):
            with self.subTest(field=field):
                view = deepcopy(self.view)
                view["nodes"][0]["preview"][field] = value
                with self.assertRaises(ValueError):
                    self.validate(view)

    def test_a_same_unicode_normalization_cannot_replace_the_actual_text(self):
        self.batch["candidates"][0]["text"] = "e\u0301"
        view = candidate_view(self.batch)
        view["candidates"][0]["text"] = "é"
        with self.assertRaises(ValueError):
            self.validate(view)

    def test_invalid_node_links_do_not_become_pointer_targets(self):
        for field, value in (("id", True), ("children", [0]), ("parent", 0), ("terminals", [999])):
            with self.subTest(field=field):
                view = deepcopy(self.view)
                view["nodes"][0][field] = value
                with self.assertRaises(ValueError):
                    self.validate(view)

    def test_display_columns_and_page_items_refer_to_existing_candidates(self):
        for change in (
            lambda view: view.update(columns=[[999]]),
            lambda view: view.update(selectedPath=[]),
            lambda view: view["candidatePage"].update(totalCount=999),
            lambda view: view["candidatePage"]["items"][0].update(text="different"),
        ):
            view = deepcopy(self.view)
            change(view)
            with self.assertRaises(ValueError):
                self.validate(view)

    def test_an_input_view_must_agree_with_the_formal_selection_and_revision(self):
        view = candidate_view(self.batch, selection=0, show_indices=True)
        snapshot = {**reading_snapshot("にほんご", revision=self.request["authority"]["compositionRevision"]),
                    "selection": 0, "showCandidateIndex": True}
        validate_view(view, expected_reference=self.reference, snapshot=snapshot)
        for field, value in (("selection", None), ("compositionRevision", 999), ("showCandidateIndex", False)):
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    validate_view(view, expected_reference=self.reference, snapshot={**snapshot, field: value})

    def test_adoption_requires_its_view_and_never_an_automatic_selection(self):
        response = {"kind": "acknowledgement", "readingProcessGeneration": self.reference["readingProcessGeneration"],
                    "settingsRevision": self.request["authority"]["settingsRevision"], "reference": self.reference,
                    "candidateReference": self.view["candidateReference"], "candidateView": self.view}
        payload = {"reference": self.reference, "batch": self.batch, "retainedReference": self.view["candidateReference"]}
        reading_protocol.response(response, "adopt-candidates", payload)
        missing = {name: value for name, value in response.items() if name != "candidateView"}
        with self.assertRaises(ValueError):
            reading_protocol.response(missing, "adopt-candidates", payload)
        selected = {**response, "candidateView": candidate_view(self.batch, selection=0)}
        with self.assertRaises(ValueError):
            reading_protocol.response(selected, "adopt-candidates", payload)

    def test_a_candidate_view_cannot_inject_top_level_input_effects(self):
        for field in ("preedit", "commits", "cursor", "inputState", "consumed"):
            with self.subTest(field=field):
                with self.assertRaises(ValueError):
                    self.validate({**self.view, field: "unexpected"})


if __name__ == "__main__":
    unittest.main()
