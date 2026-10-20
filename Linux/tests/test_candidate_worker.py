"""Real candidate-process identities and completion receipts, without a frontend."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Detect a stuck process; this is not a key-to-paint performance threshold.
REQUEST_TIMEOUT_SECONDS = 5


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real Linux Swift bridge")
class CandidateWorkerTests(unittest.TestCase):
    def setUp(self):
        from azookey.bridge import Bridge

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.environment = {
            **os.environ,
            "AZOOKEY_BRIDGE_ROLE": "candidate",
            "AZOOKEY_DATA_DIR": str(self.directory / "data"),
            "AZOOKEY_RESOURCES": str(self.directory / "absent-models"),
            "XDG_CONFIG_HOME": str(self.directory / "config"),
            "XDG_DATA_HOME": str(self.directory / "data-home"),
        }
        self.bridge = Bridge(timeout=REQUEST_TIMEOUT_SECONDS, environment=self.environment)
        self.addCleanup(lambda: self.bridge.close())
        self.settings = self.bridge.request("settings")
        self.revision = 0

    def request(self, reading, *, context="field", private=False):
        self.revision += 1
        # A direct-kana fixture is an explicit formal input, not a Python romanizer.
        return {
            "authority": {
                "context": context, "readingProcessGeneration": "reader-1", "focusEpoch": 1,
                "compositionRevision": self.revision,
                "settingsRevision": self.settings["settingsRevision"], "requestID": str(uuid.uuid4()),
            },
            "composition": {
                "schemaVersion": 1,
                "input": [{"piece": {"kind": "character", "value": character},
                           "inputStyle": {"kind": "direct"}} for character in reading],
                "convertTarget": reading, "convertTargetCursorPosition": len(reading),
                "lastInputStyle": {"kind": "direct"}, "conversionRangeEnd": None,
                "customInputTableRevisions": {},
            },
            "leftContext": "", "rightContext": "", "privateInput": private,
        }

    def batch(self, reading, **options):
        request = self.request(reading, **options)
        response = self.bridge.request("candidates", request=request)
        self.assertNotIn("error", response)
        self.assertEqual(response["authority"], request["authority"])
        self.assertEqual(response["batch"]["authority"], request["authority"])
        for forbidden in ("commits", "preedit", "cursor", "consumed", "inputState"):
            self.assertNotIn(forbidden, response)
            self.assertNotIn(forbidden, response["batch"])
        return response["batch"]

    @staticmethod
    def reference(batch):
        return {field: batch[field] for field in ("authority", "workerGeneration", "batchID")}

    def retain(self, batch):
        response = self.bridge.request("retain", reference=self.reference(batch))
        self.assertNotIn("error", response)

    def completion(self, batch, text, *, private=False):
        candidate = next(item for item in batch["candidates"] if item["text"] == text)
        return {**self.reference(batch), "candidateID": candidate["candidateID"],
                "commitID": str(uuid.uuid4()), "settingsRevision": self.settings["settingsRevision"],
                "privateInput": private}

    def learning(self, mode):
        self.settings = self.bridge.request("configure-learning", workerGeneration=self.settings["workerGeneration"],
                                            settingsRevision=self.settings["settingsRevision"] + 1, learning=mode)
        self.assertNotIn("error", self.settings)

    def memory(self):
        return {path.name: path.read_bytes() for path in (self.directory / "data" / "memory").iterdir()
                if path.is_file()}

    def test_retained_source_survives_new_calculation_and_duplicate_ack_never_learns_twice(self):
        selected = self.batch("きょう")
        self.retain(selected)
        newer = self.batch("にほんご")
        self.retain(newer)
        completion = self.completion(selected, "京")
        completed = self.bridge.request("complete", completion=completion)["completion"]
        self.assertEqual(completed["status"], "completed")
        self.assertTrue(completed["learningRequested"])
        stored = self.memory()
        self.assertTrue(stored)
        repeated = self.bridge.request("complete", completion=completion)["completion"]
        self.assertEqual(repeated["status"], "alreadyCompleted")
        self.assertEqual(self.memory(), stored)
        self.assertEqual(self.bridge.request("complete", completion=self.completion(newer, "日本語"))
                         ["completion"]["status"], "completed")

    def test_rejected_references_leave_both_real_contexts_available(self):
        first = self.batch("きょう", context="first")
        second = self.batch("にほんご", context="second")
        self.retain(first)
        self.retain(second)
        completion = self.completion(first, "京")
        rejected = self.bridge.request("complete", completion={**completion, "authority": second["authority"]})
        self.assertEqual(rejected["error"], "unknown_candidate_batch")
        self.assertEqual(rejected["authority"], second["authority"])
        rejected = self.bridge.request("complete", completion={**completion, "candidateID": str(uuid.uuid4())})
        self.assertEqual(rejected["error"], "unknown_candidate_id")
        rejected = self.bridge.request("complete", completion={**completion, "workerGeneration": str(uuid.uuid4())})
        self.assertEqual(rejected["error"], "wrong_candidate_worker_generation")
        self.assertEqual(self.bridge.request("complete", completion=completion)["completion"]["status"], "completed")
        self.assertEqual(self.bridge.request("complete", completion=self.completion(second, "日本語"))
                         ["completion"]["status"], "completed")

    def test_commit_time_learning_and_both_private_boundaries_keep_the_saved_preference(self):
        selected = self.batch("きょう")
        self.retain(selected)
        before = self.memory()
        self.learning("nothing")
        response = self.bridge.request("complete", completion=self.completion(selected, "京"))["completion"]
        self.assertFalse(response["learningRequested"])
        self.assertEqual(self.memory(), before)
        self.learning("inputAndOutput")
        for source_private, commit_private in ((True, False), (False, True), (True, True)):
            with self.subTest(source_private=source_private, commit_private=commit_private):
                selected = self.batch("きょう", private=source_private)
                self.retain(selected)
                response = self.bridge.request("complete", completion=self.completion(selected, "京", private=commit_private))
                self.assertFalse(response["completion"]["learningRequested"])
                self.assertEqual(self.bridge.request("settings")["learning"], "inputAndOutput")
                self.assertEqual(self.memory(), before)

    def test_empty_unknown_and_invalid_input_do_not_authorize_an_input_field_update(self):
        self.assertEqual(self.batch("")["candidates"], [])
        selected = self.batch("にほんご")
        self.retain(selected)
        for operation in ("key", "configure", "ai", "suggestions"):
            self.assertEqual(self.bridge.request(operation)["error"], "unsupported_candidate_operation")
        invalid = self.request("あ")
        invalid["composition"]["convertTarget"] = "別の読み"
        self.assertIn("error", self.bridge.request("candidates", request=invalid))
        invalid = self.request("あ")
        invalid["authority"]["focusEpoch"] = -1
        self.assertEqual(self.bridge.request("candidates", request=invalid)["error"], "invalid_candidate_request")
        self.assertEqual(self.bridge.request("complete", completion=self.completion(selected, "日本語"))
                         ["completion"]["status"], "completed")

    def test_close_and_restart_cannot_replay_a_reference_from_the_previous_lifetime(self):
        from azookey.bridge import Bridge

        selected = self.batch("きょう")
        self.retain(selected)
        completion = self.completion(selected, "京")
        self.bridge.request("close", context="field", readingProcessGeneration="reader-1",
                            workerGeneration=self.settings["workerGeneration"])
        self.assertEqual(self.bridge.request("complete", completion=completion)["error"], "unknown_candidate_batch")
        previous_generation = self.settings["workerGeneration"]
        self.bridge.close()
        self.bridge = Bridge(timeout=REQUEST_TIMEOUT_SECONDS, environment=self.environment)
        self.settings = self.bridge.request("settings")
        self.assertNotEqual(self.settings["workerGeneration"], previous_generation)
        self.assertEqual(self.bridge.request("complete", completion=completion)["error"], "wrong_candidate_worker_generation")
        self.assertIn("日本語", [item["text"] for item in self.batch("にほんご")["candidates"]])


if __name__ == "__main__":
    unittest.main()
