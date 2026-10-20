"""Main-result metadata retains an existing identity without selecting or synthesizing it."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey import candidate_protocol
from candidate_fixture import CandidateBridgeFixture, candidate_request


class CandidateMainIdentityTests(unittest.TestCase):
    def setUp(self):
        self.request = candidate_request("にほんご")
        self.response = CandidateBridgeFixture().request("candidates", request=self.request)
        self.batch = self.response["batch"]
        self.original = self.batch["candidates"][0]

    def test_an_existing_main_id_is_preserved_without_changing_order_or_counts(self):
        self.batch["mainCandidateID"] = self.original["candidateID"]
        expected = deepcopy(self.batch)
        accepted = candidate_protocol.candidate_batch(self.response, self.request)
        self.assertEqual(accepted, expected)
        self.assertIsNot(accepted, self.batch)
        self.assertFalse(candidate_protocol.INPUT_COMMAND_FIELDS.intersection(accepted))

    def test_absent_main_is_not_inferred_from_the_first_or_same_text_candidate(self):
        self.batch["candidates"].append({**deepcopy(self.original), "candidateID": "whole",
                                         "composingCount": {"kind": "surfaceCount", "count": 4}})
        accepted = candidate_protocol.candidate_batch(self.response, self.request)
        self.assertNotIn("mainCandidateID", accepted)
        self.batch["mainCandidateID"] = "whole"
        accepted = candidate_protocol.candidate_batch(self.response, self.request)
        self.assertEqual(accepted["mainCandidateID"], "whole")
        self.assertEqual(accepted["candidates"], self.batch["candidates"])

    def test_missing_or_invalid_main_ids_reject_the_entire_batch(self):
        for invalid in ("missing", "", None, 1, "日本語", "has space"):
            with self.subTest(main_id=invalid):
                self.batch["mainCandidateID"] = invalid
                with self.assertRaises(ValueError):
                    candidate_protocol.candidate_batch(self.response, self.request)

    def test_main_metadata_does_not_authorize_an_older_revision_or_worker(self):
        self.batch["mainCandidateID"] = self.original["candidateID"]
        for field in ("compositionRevision", "settingsRevision"):
            with self.subTest(field=field):
                changed = deepcopy(self.request)
                changed["authority"][field] += 1
                with self.assertRaises(ValueError):
                    candidate_protocol.candidate_batch(self.response, changed)
        self.batch["workerGeneration"] = "old-worker"
        with self.assertRaises(ValueError):
            candidate_protocol.candidate_batch(self.response, self.request)


if __name__ == "__main__":
    unittest.main()
