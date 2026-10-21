"""Real candidate IDs reach atomic Core commits without synthetic key events."""
import os
import signal
import sys
import unittest

from azookey.reading_candidate_display import ReadingCandidateDisplay
from reading_process_fixture import ReadingProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingCandidateActionsProcessTests(ReadingProcessTestCase):
    def displayed(self, batch):
        publication = self.panels[-1]
        display = ReadingCandidateDisplay("test-renderer")
        display.update(self.inputs[-1].snapshot, publication.candidate_view, reference=publication.reference)
        self.assertEqual(publication.candidate_view["candidateReference"]["batchID"], batch["batchID"])
        return display

    def selection(self, display, index, *, operation="select"):
        view = self.panels[-1]
        selection = display.selection(operation, index, generation=display.generation,
                                      reference=view.reference, retained_reference=view.candidate_view["candidateReference"])
        self.assertIsNotNone(selection)
        return selection

    def commit(self, selection, *, context="field"):
        token = object()
        self.coordinator.commit_candidate(context, selection, token=token, finish=self.finish)
        self.drain_until(lambda: any(finished is token for finished, _ in self.finished))
        self.assertEqual(sum(finished is token for finished, _ in self.finished), 1)
        self.assertFalse(self.coordinator._broken)
        return self.inputs[-1].snapshot

    def test_arrival_stays_unselected_and_direct_commit_sends_only_the_atomic_operation(self):
        batch = self.batch()
        display = self.displayed(batch)
        self.assertEqual(display.snapshot["preedit"], "にほんご")
        self.assertNotIn("selection", display.snapshot)
        self.assertEqual(display.snapshot["inputState"], "composing")
        candidate = next(item for item in display.snapshot["candidates"] if item["text"] == "日本語")
        selection = self.selection(display, candidate["index"])
        reader = self.bridges["reading"]
        sent, publications = len(reader.operations), len(self.inputs)
        committed = self.commit(selection)
        self.assertEqual(committed["commits"], ["日本語"])
        self.assertEqual(committed["preedit"], "")
        self.assertEqual(len(self.inputs), publications + 1)
        self.assertEqual([name for name, _ in reader.operations[sent:]], ["commit-candidate"])
        self.flush_candidates()
        receipts = [notice.completion for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["candidateID"], selection["candidateID"])
        count = len(self.inputs)
        self.commit(selection)
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(self.notices[-1].phase, "rejected")
        self.assertEqual([text for value in self.inputs for text in value.snapshot["commits"]], ["日本語"])
        self.record(direct_operation="commit-candidate", fake_keys=0, original_candidate_id=selection["candidateID"],
                    commit_callbacks=1, completion_receipts=1, duplicate_input_callbacks=0)

    def test_real_word_preview_selects_its_own_candidate_before_a_distinct_atomic_confirmation(self):
        batch = self.batch("kyouhanihongo")
        display = self.displayed(batch)
        node = next(node for node in display.snapshot["nodes"] if node.get("preview"))
        preview = node["preview"]
        item = display.snapshot["candidates"][preview["candidateIndex"]]
        selection = self.selection(display, node["id"], operation="node")
        self.assertEqual(selection["candidateID"], item["candidateID"])
        token = object()
        self.coordinator.select("field", selection, token=token, finish=self.finish)
        self.drain_until(lambda: any(finished is token for finished, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["commits"], [])
        self.assertEqual(self.inputs[-1].snapshot["selection"], item["index"])
        committed = self.commit(selection)
        self.assertEqual(committed["commits"], [item["text"]])
        self.assertEqual(committed["preedit"], item["commitScope"]["remainingReading"])
        self.flush_candidates()
        self.assertEqual(sum(notice.code == "candidate_learning_completed" for notice in self.notices), 1)
        self.record(node=node["id"], preview_candidate_id=selection["candidateID"], committed=committed["commits"],
                    remaining=committed["preedit"])

    def test_partial_direct_commit_preserves_the_formal_suffix_and_rejects_the_old_batch(self):
        batch = self.batch("kyouhanihongo")
        display = self.displayed(batch)
        partial = next(item for item in display.snapshot["candidates"] if item["text"] == "今日")
        selection = self.selection(display, partial["index"])
        committed = self.commit(selection)
        self.assertEqual(committed["commits"], ["今日"])
        self.assertEqual(committed["preedit"], "はにほんご")
        self.assertEqual(committed["candidateCompletions"][0]["candidateID"], partial["candidateID"])
        count = len(self.inputs)
        self.commit(selection)
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "はにほんご")
        self.assertEqual(self.key(0xff0d)["commits"], ["はにほんご"])
        self.flush_candidates()
        self.assertEqual(sum(notice.code == "candidate_learning_completed" for notice in self.notices), 1)
        self.record(prefix="今日", remaining="はにほんご", candidate_id=partial["candidateID"], stale_input_callbacks=0)

    def test_old_focus_candidate_cannot_commit_into_a_new_field(self):
        batch = self.batch()
        display = self.displayed(batch)
        selection = self.selection(display, 0)
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.focus("other", opening=True)
        self.type("a", context="other")
        count = len(self.inputs)
        self.commit(selection, context="other")
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "あ")
        self.assertEqual([text for value in self.inputs for text in value.snapshot["commits"]], [])
        self.record(other_field_preedit="あ", stale_input_callbacks=0, commit_callbacks=0)

    def test_stopped_candidate_process_does_not_block_atomic_commit_of_its_retained_id(self):
        batch = self.batch()
        display = self.displayed(batch)
        candidate = next(item for item in display.snapshot["candidates"] if item["text"] == "日本語")
        selection = self.selection(display, candidate["index"])
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGSTOP)
        try:
            pid, status = os.waitpid(converter.process.pid, os.WUNTRACED)
            self.assertEqual(pid, converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(status))
            committed = self.commit(selection)
            self.assertEqual(committed["commits"], ["日本語"])
            self.assertEqual(self.key(ord("a"))["preedit"], "あ")
            self.assertFalse(any(notice.code == "candidate_learning_completed" for notice in self.notices))
        finally:
            os.kill(converter.process.pid, signal.SIGCONT)
        self.flush_candidates()
        self.assertEqual(sum(notice.code == "candidate_learning_completed" for notice in self.notices), 1)
        self.record(candidate_stopped_during_commit=True, committed=["日本語"], next_reading="あ", completion_receipts=1)


if __name__ == "__main__":
    unittest.main()
