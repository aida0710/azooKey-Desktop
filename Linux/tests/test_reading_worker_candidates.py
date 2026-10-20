"""Candidate-only acknowledgements and explicit retained identities over real JSONL."""
import copy
import unittest

from Linux.tests.reading_worker_fixture import ReadingWorkerCase


class ReadingCandidateWorkerTests(ReadingWorkerCase):
    def test_function_keys_convert_only_the_selected_prefix_after_candidate_worker_stop(self):
        for keyval, expected in ((0xFFC3, "に"), (0xFFC4, "ニ"), (0xFFC5, "ﾆ"),
                                 (0xFFC6, "ｎｉ"), (0xFFC7, "ni")):
            with self.subTest(keyval=keyval):
                self.type("nihongo")
                batch = self.batch(text="荷", count=2)
                self.adopt(batch)
                self.select(batch)
                self.request("candidate-worker-stopped", reference=self.reference,
                             candidateWorkerGeneration="converter")
                committed = self.key(keyval)["snapshot"]
                self.assertEqual(committed["commits"], [expected])
                self.assertEqual(committed["preedit"], "ほんご")
                self.assertEqual(committed["request"], "candidates")
                self.assertNotIn("candidateCompletions", committed)
                self.assertEqual(self.key(0xFF0D)["snapshot"]["commits"], ["ほんご"])

    def test_number_selects_a_retained_identity_and_enter_finishes_the_suffix(self):
        self.type("nihongo")
        batch = self.batch(text="荷", count=2)
        second = copy.deepcopy(batch["candidates"][0])
        second.update(candidateID="second", text="二")
        batch["candidates"].append(second)
        self.adopt(batch)
        selected = self.select(batch)["snapshot"]
        self.assertTrue(selected["showCandidateIndex"])
        committed = self.key(ord("2"))["snapshot"]
        self.assertEqual(committed["commits"], ["二"])
        self.assertEqual(committed["preedit"], "ほんご")
        self.assertEqual(committed["candidateCompletions"][0]["candidateID"], "second")
        self.assertEqual(committed["candidateCompletions"][0]["batchID"], batch["batchID"])
        suffix = self.key(0xFF0D)["snapshot"]
        self.assertEqual(suffix["commits"], ["ほんご"])
        self.assertNotIn("candidateCompletions", suffix)

    def test_focus_out_input_and_completion_keep_old_authority_but_next_operation_uses_new_reference(self):
        self.type("nihongo")
        batch = self.batch()
        self.adopt(batch)
        self.select(batch)
        original = self.reference
        reply = self.request("focus-out", reference=original, submit=True)
        self.assertEqual(reply["reference"], original)
        completion = reply["snapshot"]["candidateCompletions"][0]
        self.assertEqual(completion["authority"]["focusEpoch"], original["focusEpoch"])
        self.assertEqual(reply["snapshot"]["commits"], ["日本語"])
        self.reference = reply["nextReference"]
        self.assertGreater(self.reference["focusEpoch"], original["focusEpoch"])
        self.assertEqual(self.reference["context"], original["context"])
        self.assert_rejected_without_edit("focus-in", reference=original,
                                          surroundings={"leftContext": "", "rightContext": "", "privateInput": False})
        self.focus()
        self.assertEqual(self.snapshot()["commits"], [])

    def test_adoption_requires_matching_retain_reference_and_never_changes_preedit(self):
        self.type("nihongo")
        before = self.snapshot()
        batch = self.batch()
        self.assertEqual(self.snapshot(), before)
        self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=batch)
        self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=batch,
                                          retainedReference={**self.batch_reference(batch), "batchID": "other"},
                                          error="candidate_retain_ack_required")
        adopted = self.adopt(batch)
        self.assertEqual(adopted["candidateReference"], self.batch_reference(batch))
        self.assertEqual(self.snapshot(), before)
        selected = self.select(batch)["snapshot"]
        self.assertEqual(selected["preedit"], "日本語")
        self.assertEqual(selected["commits"], [])
        committed = self.key(0xFF0D)["snapshot"]
        self.assertEqual(committed["commits"], ["日本語"])
        completion = committed["candidateCompletions"][0]
        self.assertEqual({key: completion[key] for key in self.batch_reference(batch)}, self.batch_reference(batch))
        self.assertNotIn("candidateCompletions", self.snapshot())
        self.assertNotIn("candidateCompletions", self.key(0xFF0D)["snapshot"])

    def test_old_list_action_cannot_select_a_new_list_with_the_same_candidate_id(self):
        self.type("nihongo")
        old = self.batch()
        self.adopt(old)
        latest = self.batch(text="にほんご")
        self.adopt(latest)
        self.assertEqual(old["candidates"][0]["candidateID"], latest["candidates"][0]["candidateID"])
        self.assert_rejected_without_edit("select", reference=self.reference,
                                          selection={"batch": self.batch_reference(old), "candidateID": "candidate"},
                                          error="unavailable_candidate")
        self.assert_rejected_without_edit("select", reference=self.reference, selection=0)
        self.assert_rejected_without_edit("select", reference=self.reference,
                                          selection={"batch": self.batch_reference(latest), "index": 0})
        self.assertEqual(self.select(latest)["snapshot"]["preedit"], "にほんご")

    def test_edited_reading_and_stale_authority_cannot_be_adopted(self):
        self.type("nihongo")
        old = self.batch()
        self.type("a")
        self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=old,
                                          retainedReference=self.batch_reference(old))
        batch = self.batch(text="日本語あ")
        self.assertGreater(batch["authority"]["compositionRevision"], old["authority"]["compositionRevision"])
        for field, value in (("context", "second"), ("readingProcessGeneration", "old-process"),
                             ("focusEpoch", -1), ("compositionRevision", -1), ("settingsRevision", -1),
                             ("requestID", "old-request")):
            with self.subTest(field=field):
                changed = copy.deepcopy(batch)
                changed["authority"][field] = value
                self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=changed,
                                                  retainedReference=self.batch_reference(changed))
        self.assertEqual(self.adopt(batch)["kind"], "acknowledgement")

    def test_batch_validation_is_atomic_and_corrected_consumption_can_be_adopted(self):
        self.type("nihongo")
        batch = self.batch()
        for count in (0, 8):
            changed = copy.deepcopy(batch)
            invalid = copy.deepcopy(changed["candidates"][0])
            invalid["candidateID"] = "invalid"
            invalid["composingCount"]["count"] = count
            changed["candidates"].append(invalid)
            self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=changed,
                                              retainedReference=self.batch_reference(changed))
        self.assertEqual(self.adopt(batch)["kind"], "acknowledgement")
        self.assertEqual(self.select(batch)["snapshot"]["preedit"], "日本語")

    def test_partial_selection_survives_worker_stop_and_suffix_gets_its_own_request_and_commit(self):
        self.focus_out(submit=False)
        self.focus(left="前", right="後")
        self.type("nihongo")
        prefix = self.batch(text="荷", count=2)
        self.adopt(prefix)
        self.assertEqual(self.select(prefix)["snapshot"]["preedit"], "荷ほんご")
        self.assert_rejected_without_edit("candidate-worker-stopped", reference=self.reference,
                                          candidateWorkerGeneration="older-converter")
        self.assertEqual(self.request("candidate-worker-stopped", reference=self.reference,
                                      candidateWorkerGeneration="converter")["kind"], "acknowledgement")
        first = self.key(0xFF0D)["snapshot"]
        self.assertEqual(first["commits"], ["荷"])
        self.assertEqual(first["reading"], "ほんご")
        request = self.prepare(worker="restarted-converter")
        self.assertEqual(request["leftContext"], "前荷")
        self.assertEqual(request["rightContext"], "後")
        self.assertEqual(request["composition"]["convertTarget"], "ほんご")
        self.assert_rejected_without_edit("candidate-worker-stopped", reference=self.reference,
                                          candidateWorkerGeneration="converter")
        suffix = self.batch(text="本語", worker="restarted-converter")
        self.adopt(suffix)
        self.select(suffix)
        second = self.key(0xFF0D)["snapshot"]
        self.assertEqual(second["commits"], ["本語"])
        self.assertEqual(second["preedit"], "")
        self.assertNotEqual(first["candidateCompletions"][0]["commitID"], second["candidateCompletions"][0]["commitID"])
        self.assertEqual(self.snapshot()["commits"], [])

    def test_learning_revision_keeps_selected_private_identity_and_retires_old_pending_work(self):
        self.focus_out(submit=False)
        self.focus(private=True)
        self.type("nihongo")
        batch = self.batch()
        self.adopt(batch)
        self.select(batch)
        reply = self.request("learning-revision", readingProcessGeneration=self.process_generation, settingsRevision=1)
        self.assertEqual(reply["kind"], "acknowledgement")
        completed = self.key(0xFF0D)["snapshot"]["candidateCompletions"][0]
        self.assertTrue(completed["privateInput"])
        self.assertEqual(completed["authority"]["settingsRevision"], 0)
        self.assertEqual(completed["settingsRevision"], 1)
        self.type("a")
        pending = self.batch(text="亜")
        self.request("learning-revision", readingProcessGeneration=self.process_generation, settingsRevision=2)
        self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=pending,
                                          retainedReference=self.batch_reference(pending))
        self.assert_rejected_without_edit("learning-revision", readingProcessGeneration=self.process_generation,
                                          settingsRevision=1, error="stale_reading_settings")
        self.assertEqual(self.prepare()["authority"]["settingsRevision"], 2)


if __name__ == "__main__":
    unittest.main()
