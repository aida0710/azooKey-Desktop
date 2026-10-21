"""Initial dictionary binding uses real acknowledgements without resetting input."""
from copy import deepcopy
import os
import signal
import sys
import unittest

from candidate_fixture import WAIT_SECONDS
from reading_dictionary_process_fixture import ReadingDictionaryProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real dictionary writer, reader and candidate processes")
class ReadingDictionaryBindingProcessTests(ReadingDictionaryProcessTestCase):
    def test_first_preparation_preserves_active_input_and_publishes_only_after_both_acknowledgements(self):
        candidate = self.bridges["candidate"]
        os.kill(candidate.process.pid, signal.SIGSTOP)
        try:
            pid, status = os.waitpid(candidate.process.pid, os.WUNTRACED)
            self.assertEqual(pid, candidate.process.pid)
            self.assertTrue(os.WIFSTOPPED(status))
            self.coordinator.refresh_dictionary()
            self.type("aida")
            self.key(0x20)
            before = deepcopy(self.inputs[-1].snapshot)
            reference = deepcopy(self.coordinator._contexts["field"].reference)
            self.assertEqual(self.panels, [])
            self.assertIsNone(self.coordinator.prepare_reconversion_worker())
            self.assertIsNone(self.agreement.reader.get("dictionaryRevision"))
        finally:
            os.kill(candidate.process.pid, signal.SIGCONT)
        self.agreed()
        self.drain_until(lambda: self.panels)
        self.assertEqual(self.inputs[-1].snapshot, before)
        self.assertEqual(self.coordinator._contexts["field"].reference, reference)
        self.assertEqual(self.agreement.reader["settingsRevision"], 0)
        batch = self.panels[-1].batch
        self.assertEqual(self.inverse(batch), "あいだ")
        selected = next(item for item in batch["candidates"] if item["text"] == self.item["word"])
        self.select(batch, selected)
        self.assertEqual(self.key(0xFF0D)["commits"], [self.item["word"]])
        self.record(initialPreparationWithCandidateStopped=True, inputAndReferenceUnchanged=True,
                    initialSettingsRevision=0, explicitCommit=self.item["word"])

    def test_delayed_candidate_binding_allows_raw_commit_and_never_publishes_retired_input(self):
        binding = self.hold_request("candidate", "bind-initial-dictionary")
        self.coordinator.refresh_dictionary()
        try:
            self.drain_until(lambda: self.agreement.reader.get("dictionaryRevision") is not None)
            self.assertTrue(binding.entered.wait(WAIT_SECONDS))
            self.type("aida")
            self.key(0x20)
            self.assertIsNone(self.coordinator.prepare_reconversion_worker())
            self.assertEqual(self.key(0xFF0D)["commits"], ["あいだ"])
            self.assertEqual(self.panels, [])
            self.assertFalse(binding.proceed.is_set())
        finally:
            binding.proceed.set()
        self.agreed()
        self.flush_candidates()
        self.assertEqual(self.panels, [])
        batch = self.current_batch("aida")
        self.assertEqual(self.inverse(batch), "あいだ")
        self.record(candidateBindingDelayed=True, rawCommitBeforeCandidateAck="あいだ",
                    retiredCandidatesPublished=0, nextCompositionUsesSavedDictionary=True)

    def test_next_prepared_save_recovers_after_initial_binding_detects_newer_saved_source(self):
        self.blur()
        binding = self.hold_request("reading", "bind-initial-dictionary")
        first = self.prepare()
        try:
            self.assertTrue(binding.entered.wait(WAIT_SECONDS))
            self.save({**self.item, "reading": "あいう"})
            second = self.prepare()
            self.assertNotEqual(second, first)
        finally:
            binding.proceed.set()
        self.agreed()
        self.assertEqual(self.agreement.reader["dictionaryRevision"], second)
        self.assertEqual(self.agreement.reader["settingsRevision"], 1)
        self.assertTrue(any(notice.code == "candidate_dictionary_changed" for notice in self.notices))
        self.focus("field")
        self.assertEqual(self.inverse(self.current_batch("aiu")), "あいう")
        self.record(laterSavePreparedBeforeInitialReaderAck=True, firstBindingRejected=True,
                    laterSaveAutomaticallyApplied=True, settingsRevision=1)


if __name__ == "__main__":
    unittest.main()
