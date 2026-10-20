"""Two real processes: candidate retain ACK precedes adoption and only input can commit."""
import os
from pathlib import Path
import signal
import unittest

from Linux.tests.reading_worker_fixture import ReadingWorkerCase, REQUEST_TIMEOUT_SECONDS


@unittest.skipUnless(os.environ.get("AZOOKEY_CANDIDATE_BRIDGE"), "requires an explicit candidate-role binary")
class ReadingCandidateIntegrationTests(ReadingWorkerCase):
    def setUp(self):
        super().setUp()
        from azookey.bridge import Bridge

        environment = {**self.environment, "AZOOKEY_BRIDGE_ROLE": "candidate",
                       "AZOOKEY_DATA_DIR": str(self.directory / "candidate-data"),
                       "XDG_DATA_HOME": str(self.directory / "candidate-data-home")}
        self.converter = Bridge(executable=os.environ["AZOOKEY_CANDIDATE_BRIDGE"],
                                timeout=REQUEST_TIMEOUT_SECONDS, environment=environment)
        self.addCleanup(self.converter.close)
        self.settings = self.converter.request("settings")
        self.assertNotIn("error", self.settings)
        self.worker_generation = self.settings["workerGeneration"]
        self.assertNotEqual(self.converter.process.pid, self.bridge.process.pid)

    def retained_candidate(self):
        request = self.prepare(worker=self.worker_generation)
        response = self.converter.request("candidates", request=request)
        self.assertNotIn("error", response)
        batch = response["batch"]
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        before = self.snapshot()
        retained = self.converter.request("retain", reference=self.batch_reference(batch))
        self.assertNotIn("error", retained)
        adopted = self.request("adopt-candidates", reference=self.reference, batch=batch,
                               retainedReference=retained["reference"])
        self.assertEqual(adopted["kind"], "acknowledgement")
        self.assertEqual(self.snapshot(), before)
        selected = self.request("select", reference=self.reference,
                                selection={"batch": retained["reference"], "candidateID": candidate["candidateID"]})
        self.assertEqual(selected["snapshot"]["preedit"], candidate["text"])
        return batch, candidate

    def test_real_retained_selection_commits_once_while_converter_is_stopped(self):
        self.type("nihongo")
        batch, candidate = self.retained_candidate()
        os.kill(self.converter.process.pid, signal.SIGSTOP)
        try:
            stopped_pid, status = os.waitpid(self.converter.process.pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, self.converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(status))
            self.request("candidate-worker-stopped", reference=self.reference, candidateWorkerGeneration=self.worker_generation)
            committed = self.key(0xFF0D)["snapshot"]
            self.assertEqual(committed["commits"], [candidate["text"]])
            completion = committed["candidateCompletions"][0]
            self.assertEqual(completion["candidateID"], candidate["candidateID"])
            self.assertEqual(completion["batchID"], batch["batchID"])
            self.assertEqual(self.type("a")["preedit"], "あ")
            self.assertNotIn("candidateCompletions", self.snapshot())
            process_status = Path(f"/proc/{self.converter.process.pid}/status").read_text()
            self.assertRegex(process_status, r"(?m)^State:\s+T\b")
        finally:
            if self.converter.process.poll() is None:
                os.kill(self.converter.process.pid, signal.SIGCONT)
        receipt = self.converter.request("complete", completion=completion)["completion"]
        self.assertEqual(receipt["status"], "completed")
        repeated = self.converter.request("complete", completion=completion)["completion"]
        self.assertEqual(repeated["status"], "alreadyCompleted")

    def test_actual_learning_ack_then_reader_revision_preserves_private_selected_identity(self):
        self.focus_out(submit=False)
        self.focus(private=True)
        self.type("nihongo")
        batch, candidate = self.retained_candidate()
        settings = self.converter.request("configure-learning", workerGeneration=self.worker_generation,
                                           settingsRevision=1, learning="inputAndOutput")
        self.assertNotIn("error", settings)
        self.request("learning-revision", readingProcessGeneration=self.process_generation,
                     settingsRevision=settings["settingsRevision"])
        committed = self.key(0xFF0D)["snapshot"]
        self.assertEqual(committed["commits"], [candidate["text"]])
        completion = committed["candidateCompletions"][0]
        self.assertEqual(completion["authority"], batch["authority"])
        self.assertEqual(completion["settingsRevision"], 1)
        self.assertTrue(completion["privateInput"])
        receipt = self.converter.request("complete", completion=completion)["completion"]
        self.assertEqual(receipt["status"], "completed")
        self.assertFalse(receipt["learningRequested"])


if __name__ == "__main__":
    unittest.main()
