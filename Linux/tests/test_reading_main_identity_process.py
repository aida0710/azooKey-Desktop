"""Real process metadata preserves main IDs without sending an input update on arrival."""
import os
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from reading_process_fixture import ReadingProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingMainIdentityProcessTests(ReadingProcessTestCase):
    def test_main_arrival_does_not_send_input_reply_commit_or_learning(self):
        self.type("nihongo")
        pending = self.key(0x20)
        input_count, reply_count = len(self.inputs), len(self.finished)
        self.drain_until(lambda: self.panels)
        batch = self.panels[-1].batch
        main_id = batch["mainCandidateID"]
        main = next(item for item in batch["candidates"] if item["candidateID"] == main_id)
        self.assertEqual(main["text"], "日本語")
        self.assertEqual(len(self.inputs), input_count)
        self.assertEqual(len(self.finished), reply_count)
        self.assertEqual(self.inputs[-1].snapshot, pending)
        self.assertEqual(pending["preedit"], "にほんご")
        self.assertEqual(pending["commits"], [])
        self.assertFalse(any(operation == "complete" for operation, _ in self.bridges["candidate"].operations))
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["にほんご"])
        self.assertNotIn("candidateCompletions", committed)
        self.flush_candidates()
        self.assertFalse(any(operation == "complete" for operation, _ in self.bridges["candidate"].operations))
        self.record(main_candidate_id=main_id, arrival_input_callbacks=0, arrival_original_replies=0,
                    committed=committed["commits"], completion_count=0)

    def test_partial_main_keeps_its_suffix_and_only_the_explicit_id_can_complete(self):
        self.type("kyougo")
        pending = self.key(0xff51, modifiers=1)
        self.assertEqual(pending["preedit"], "きょうご")
        input_count, reply_count = len(self.inputs), len(self.finished)
        self.drain_until(lambda: self.panels)
        batch = self.panels[-1].batch
        main = next(item for item in batch["candidates"] if item["candidateID"] == batch["mainCandidateID"])
        self.assertEqual(len(self.inputs), input_count)
        self.assertEqual(len(self.finished), reply_count)
        self.select(batch, main)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], main["text"] + "ご")
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], [main["text"]])
        self.assertEqual(committed["preedit"], "ご")
        self.assertEqual(committed["candidateCompletions"][0]["candidateID"], main["candidateID"])
        self.assertEqual(self.key(0xff0d)["commits"], ["ご"])
        self.flush_candidates()
        receipts = [notice.completion for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["candidateID"], main["candidateID"])
        self.record(main_candidate_id=main["candidateID"], committed_prefix=main["text"], suffix="ご",
                    completion_count=len(receipts))


if __name__ == "__main__":
    unittest.main()
