"""Two real workers prepare replacements without taking the client's deletion ACK."""
import os
import signal
import sys
import unittest

from azookey.keymap import translate
from azookey.reconversion import removed_context, surrounding_context
from reading_process_fixture import ReadingProcessTestCase
from worker_settings_fixture import settings_values


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingReconversionProcessTests(ReadingProcessTestCase):
    def prepare_worker_settings(self):
        return {"settings": settings_values()}

    def command(self, operation, **payload):
        token, replies = object(), []
        self.coordinator.reconversion("field", operation, payload, token=token, finish=self.finish,
                                      callback=replies.append)
        self.drain_until(lambda: replies)
        self.assertEqual(sum(owner is token for owner, _ in self.finished), 1)
        self.assertFalse(self.coordinator._broken, [notice.code for notice in self.notices])
        return replies[0]

    def resolve_selection(self, document):
        prepared = self.command("reconvert", reconversionContext=document,
                                candidateWorkerGeneration=self.coordinator.prepare_reconversion_worker())
        self.assertNotIn("snapshot", prepared)
        request = prepared["reconversionReadingRequest"]
        replies = []
        self.coordinator.candidates.resolve_reconversion_reading(request, replies.append)
        self.drain_until(lambda: replies)
        self.assertIsNone(replies[0].error)
        resolved = replies[0].reconversion_reading
        self.assertEqual(resolved["request"], request)
        return self.command("resolve-reconversion", reconversionContext=document,
                            reconversionReadingResult=resolved)

    def confirm(self, document, replacement):
        return self.command("confirm-reconversion", reconversionContext=removed_context(document, replacement),
                            reconversionToken=replacement["token"])

    def commit_raw(self):
        before = surrounding_context("前後", 1, 1, can_replace=True, sensitive=False)
        self.type("nihongo")
        token = object()
        self.coordinator.key("field", translate(0xFF0D, 0), reconversion_context=before,
                             token=token, finish=self.finish)
        self.drain_until(lambda: any(owner is token for owner, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["にほんご"])
        return surrounding_context("前にほんご後", 5, 5, can_replace=True, sensitive=False)

    def test_known_reading_prepares_no_input_then_confirm_uses_new_real_candidate_ids(self):
        document = surrounding_context("前ニホンゴ後", 5, 1, can_replace=True, sensitive=False)
        planned = self.resolve_selection(document)
        self.assertEqual(self.inputs, [])
        self.assertEqual(self.panels, [])
        replacement = planned["reconversion"]
        self.assertEqual((replacement["text"], replacement["reading"], replacement["offset"], replacement["count"]),
                         ("ニホンゴ", "にほんご", -4, 4))
        confirmed = self.confirm(document, replacement)
        self.assertEqual(confirmed["snapshot"]["preedit"], "にほんご")
        self.assertEqual(confirmed["snapshot"]["commits"], [])
        self.assertFalse(confirmed["snapshot"].get("candidateCompletions"))
        self.drain_until(lambda: self.panels)
        publication = self.panels[-1]
        view = publication.candidate_view
        self.assertIsNone(view.get("selection"))
        candidate = next(item for item in view["candidates"] if item["text"] == "日本語")
        token = object()
        self.coordinator.commit_candidate(
            "field", {"batch": view["candidateReference"], "candidateID": candidate["candidateID"]},
            token=token, finish=self.finish,
            reconversion_context=removed_context(document, replacement),
        )
        self.drain_until(lambda: any(owner is token for owner, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["日本語"])
        self.flush_candidates()
        receipts = [notice.completion for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["candidateID"], candidate["candidateID"])
        self.assertFalse(receipts[0]["learningRequested"])
        self.record(replacement=replacement, confirmedReading="にほんご", candidateID=candidate["candidateID"],
                    commits=["日本語"], completionReceipts=1, inputBeforeDeletionAck=0)

    def test_undo_restores_raw_reading_without_waiting_for_a_stopped_candidate(self):
        document = self.commit_raw()
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGSTOP)
        try:
            pid, state = os.waitpid(converter.process.pid, os.WUNTRACED)
            self.assertEqual(pid, converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(state))
            count = len(self.inputs)
            planned = self.command("undo-commit", reconversionContext=document)
            self.assertEqual(len(self.inputs), count)
            self.assertEqual(planned["reconversion"]["text"], "にほんご")
            restored = self.confirm(document, planned["reconversion"])
            self.assertEqual(restored["snapshot"]["preedit"], "にほんご")
            self.assertEqual(restored["snapshot"]["commits"], [])
            self.assertEqual(self.key(ord("a"))["preedit"], "にほんごあ")
        finally:
            os.kill(converter.process.pid, signal.SIGCONT)
        self.record(candidateStopped=True, restored="にほんご", nextInput="にほんごあ")

    def test_changed_post_deletion_document_never_publishes_the_rejected_confirmation(self):
        document = self.commit_raw()
        replacement = self.command("undo-commit", reconversionContext=document)["reconversion"]
        changed = {**removed_context(document, replacement), "after": "別"}
        count = len(self.inputs)
        rejected = self.command("confirm-reconversion", reconversionContext=changed,
                                reconversionToken=replacement["token"])
        self.assertEqual(rejected["reconversionError"], "changed_context")
        self.assertEqual(len(self.inputs), count)
        self.assertEqual([text for value in self.inputs for text in value.snapshot["commits"]], ["にほんご"])
        self.record(rejected="changed_context", inputCallbacksAfterRejection=0)

    def test_undo_token_cannot_restore_the_same_text_twice(self):
        document = self.commit_raw()
        replacement = self.command("undo-commit", reconversionContext=document)["reconversion"]
        self.confirm(document, replacement)
        count = len(self.inputs)
        repeated = self.confirm(document, replacement)
        self.assertIn("reconversionError", repeated)
        self.assertEqual(len(self.inputs), count)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "にほんご")
        self.record(duplicateInputCallbacks=0, duplicateError=repeated["reconversionError"])

    def test_unknown_reading_is_entered_locally_and_escape_keeps_the_selected_text(self):
        document = surrounding_context("前🧪後", 2, 1, can_replace=True, sensitive=False)
        unresolved = self.resolve_selection(document)
        self.assertEqual(unresolved["reconversionReading"], "")
        self.assertEqual(unresolved["reconversionError"], "reading_required")
        entered = self.command("reconversion-reading", reconversionContext=document, event=translate(ord("a"), 0))
        self.assertEqual(entered["reconversionReading"], "あ")
        cancelled = self.command("reconversion-reading", reconversionContext=document, event=translate(0xFF1B, 0))
        self.assertNotIn("reconversionReading", cancelled)
        self.assertNotIn("reconversion", cancelled)
        self.assertEqual(self.inputs, [])
        self.record(selected=document["selected"], cancelledReading="あ", inputCallbacks=0)

    def assert_client_cancellation_has_no_second_commit(self, operation):
        document = surrounding_context("前日本語後", 4, 1, can_replace=True, sensitive=False)
        replacement = self.command("reconvert", reconversionContext=document, reading="にほんご")["reconversion"]
        self.confirm(document, replacement)
        token = object()
        cancel = self.coordinator.reset if operation == "reset" else self.coordinator.focus_out
        cancel("field", submit=False, token=token, finish=self.finish)
        self.drain_until(lambda: any(owner is token for owner, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["commits"], [])
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "")
        self.assertFalse(self.inputs[-1].snapshot.get("candidateCompletions"))
        self.assertFalse(self.coordinator._broken)
        self.record(clientCancellation=operation, commits=[], completionReceipts=0)

    def test_client_reset_does_not_commit_reconversion_text_already_owned_by_the_toolkit(self):
        self.assert_client_cancellation_has_no_second_commit("reset")

    def test_focus_out_does_not_commit_reconversion_text_into_a_later_field(self):
        self.assert_client_cancellation_has_no_second_commit("focus-out")


if __name__ == "__main__":
    unittest.main()
