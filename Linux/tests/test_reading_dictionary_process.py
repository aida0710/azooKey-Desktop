"""Saved dictionaries cross three real processes only at an inactive boundary."""
from copy import deepcopy
import os
import signal
import sys
import unittest

from candidate_fixture import WAIT_SECONDS
from reading_dictionary_process_fixture import ReadingDictionaryProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real dictionary writer, reader and candidate processes")
class ReadingDictionaryProcessTests(ReadingDictionaryProcessTestCase):
    def setUp(self):
        super().setUp()
        self.prepare()
        self.blur()
        self.agreed()
        self.initial_dictionary = self.agreement.reader["dictionaryRevision"]
        self.focus("field")

    def test_save_preserves_active_candidates_and_inverse_until_both_workers_acknowledge(self):
        original = self.current_batch("aida")
        before = deepcopy(self.inputs[-1].snapshot)
        self.save({**self.item, "reading": "あいう", "hint": "次のヒント"})
        updated_dictionary = self.prepare()
        self.assertNotEqual(updated_dictionary, self.initial_dictionary)
        self.assertEqual(self.agreement.reader["dictionaryRevision"], self.initial_dictionary)
        self.assertEqual(self.inverse(original), "あいだ")
        self.assertEqual(self.inputs[-1].snapshot, before)
        self.blur()
        self.agreed()
        self.assertEqual(self.agreement.reader["dictionaryRevision"], updated_dictionary)
        self.focus("field")
        current = self.current_batch("aiu")
        self.assertEqual(self.inverse(current), "あいう")
        candidate = next(value for value in current["candidates"] if value["text"] == self.item["word"])
        self.select(current, candidate)
        self.assertEqual(self.key(0xFF0D)["commits"], [self.item["word"]])
        self.flush_candidates()
        receipts = [notice.completion for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertFalse(receipts[0]["learningRequested"])
        self.record(oldDictionaryBeforeFocusOut=True, candidateAndInverseUpdatedTogether=True,
                    explicitCandidateCommit=1, learningRequested=False)

    def test_stopped_candidate_during_preparation_does_not_hold_reader_input(self):
        converter = self.bridges["candidate"]
        pid = converter.process.pid
        os.kill(pid, signal.SIGSTOP)
        try:
            stopped_pid, state = os.waitpid(pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, pid)
            self.assertTrue(os.WIFSTOPPED(state))
            self.coordinator.refresh_dictionary()
            self.assertEqual(self.type("nihongo")["preedit"], "にほんご")
            self.assertEqual(self.key(0xFF0D)["commits"], ["にほんご"])
            self.assertTrue(self.coordinator._dictionary.pending)
            self.assertEqual(self.agreement.reader["dictionaryRevision"], self.initial_dictionary)
        finally:
            os.kill(pid, signal.SIGCONT)
        self.drain_until(lambda: not self.coordinator._dictionary.pending)
        self.assertFalse(self.coordinator._broken)
        self.record(candidateStopped=True, readingCompletedBeforeResume=True,
                    commits=["にほんご"], originalReplies=len(self.finished))

    def test_restart_with_a_later_saved_dictionary_keeps_candidates_hidden_until_new_agreement(self):
        self.save({**self.item, "reading": "あいう"})
        converter = self.bridges["candidate"]
        original_pid = converter.process.pid
        os.kill(original_pid, signal.SIGKILL)
        converter.process.wait(timeout=WAIT_SECONDS)
        self.coordinator.retry_candidate_settings()
        self.drain_until(lambda: self.agreement.failed)
        self.assertNotEqual(converter.process.pid, original_pid)
        self.assertTrue(any(notice.code == "candidate_dictionary_changed" for notice in self.notices))
        self.assertEqual(self.panels, [])
        self.type("nihongo")
        self.assertEqual(self.key(0xFF0D)["commits"], ["にほんご"])
        updated_dictionary = self.prepare()
        self.blur()
        self.agreed()
        self.assertEqual(self.agreement.reader["dictionaryRevision"], updated_dictionary)
        self.focus("field")
        self.assertEqual(self.inverse(self.current_batch("aiu")), "あいう")
        self.record(restarted=True, mismatchedCandidatesPublished=0,
                    rawCommitDuringMismatch="にほんご", recoveredAfterExplicitRefresh=True)

    def test_save_after_preparation_rejects_that_version_and_accepts_the_next_explicit_refresh(self):
        self.save({**self.item, "reading": "あいう"})
        prepared = self.prepare()
        self.save({**self.item, "reading": "あいえ"})
        self.blur()
        self.drain_until(lambda: self.agreement.failed)
        self.assertTrue(any(notice.code == "dictionary_source_changed" for notice in self.notices))
        self.assertEqual(self.agreement.reader["dictionaryRevision"], prepared)
        self.assertEqual(self.panels, [])
        self.focus("field")
        self.type("a")
        self.assertEqual(self.key(0xFF0D)["commits"], ["あ"])
        current = self.prepare()
        self.blur()
        self.agreed()
        self.assertNotEqual(current, prepared)
        self.focus("field")
        self.assertEqual(self.inverse(self.current_batch("aie")), "あいえ")
        self.record(savedAfterPrepareRejected=True, rawInputDuringMismatch=True,
                    nextExplicitSaveRecovered=True)

    def test_failed_save_keeps_the_applied_dictionary_and_its_original_reading(self):
        response = self.save({**self.item, "reading": "😀"}, succeeds=False)
        self.assertEqual(response["dictionarySaveError"], "compile")
        self.assertEqual(self.prepare(), self.initial_dictionary)
        self.assertEqual(self.inverse(self.current_batch("aida")), "あいだ")
        self.record(failedSavePreservedDictionary=True)


if __name__ == "__main__":
    unittest.main()
