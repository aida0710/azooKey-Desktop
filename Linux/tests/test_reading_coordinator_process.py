"""Real converter-free reading and candidate JSONL processes, without a frontend."""
import os
import signal
import sys
import threading
import time
import unittest

from azookey.keymap import translate
from candidate_fixture import WAIT_SECONDS
from reading_process_fixture import ReadingProcessTestCase


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingCoordinatorProcessTests(ReadingProcessTestCase):
    def test_sigstop_candidate_keeps_formal_edit_enter_escape_and_focus_independent(self):
        candidate = self.bridges["candidate"]
        while not candidate.started.empty():
            candidate.started.get_nowait()
        os.kill(candidate.process.pid, signal.SIGSTOP)
        try:
            stopped_pid, stopped_status = os.waitpid(candidate.process.pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, candidate.process.pid)
            self.assertTrue(os.WIFSTOPPED(stopped_status))
            self.assertEqual(self.type("nihongo")["preedit"], "にほんご")
            self.key(0x20)
            self.callbacks.drain(1)
            self.assertEqual(candidate.started.get(timeout=WAIT_SECONDS), "candidates")
            start = time.monotonic()
            self.key(0xff51)  # Left edits the formal reading, not a Python approximation.
            self.key(0xff08)  # Backspace removes the preceding formal character.
            self.key(0xff57)  # End returns to the formal composition end.
            edited = self.inputs[-1].snapshot["preedit"]
            self.assertNotEqual(edited, "にほんご")
            committed = self.key(0xff0d)
            self.assertEqual(committed["commits"], [edited])
            self.type("a")
            self.assertEqual(self.key(0xff1b)["preedit"], "")
            self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
            self.focus("other", opening=True)
            self.assertEqual(self.type("ka", context="other")["preedit"], "か")
            elapsed = time.monotonic() - start
            self.assertLess(elapsed, WAIT_SECONDS)
            self.assertEqual(candidate.process.poll(), None)
            self.assertEqual(self.panels, [])
            self.record(candidate_stopped=True, elapsed_seconds=elapsed,
                        input_callbacks=len(self.inputs), original_replies=len(self.finished),
                        candidate_panels=len(self.panels))
        finally:
            os.kill(candidate.process.pid, signal.SIGCONT)
        self.flush_candidates()
        self.assertEqual(self.panels, [])
        self.assertEqual([text for item in self.inputs for text in item.snapshot["commits"]], [edited])

    def test_real_candidate_selection_commits_once_and_learning_receipt_never_replays_input(self):
        batch = self.batch()
        view = self.panels[-1].candidate_view
        self.assertEqual([(item["candidateID"], item["text"]) for item in view["candidates"]],
                         [(item["candidateID"], item["text"]) for item in batch["candidates"]])
        self.assertNotIn("selection", view)
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        selected_view = self.inputs[-1].candidate_view
        self.assertEqual(selected_view["candidates"][selected_view["selection"]]["candidateID"], candidate["candidateID"])
        self.assertEqual(selected_view["candidateReference"]["batchID"], batch["batchID"])
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["日本語"])
        self.assertIsNone(self.inputs[-1].candidate_view)
        input_count = len(self.inputs)
        self.flush_candidates()
        self.assertEqual(len(self.inputs), input_count)
        receipts = [notice for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0].completion["candidateID"], candidate["candidateID"])
        self.key(0xff0d)
        self.assertEqual([text for item in self.inputs for text in item.snapshot["commits"]], ["日本語"])

    def test_real_partial_candidate_keeps_suffix_and_source_id_for_one_completion(self):
        batch = self.batch("kyouhanihongo")
        partial = next(item for item in batch["candidates"] if item["text"] == "今日")
        self.select(batch, partial)
        selected_view = self.inputs[-1].candidate_view
        selected = selected_view["candidates"][selected_view["selection"]]
        self.assertEqual(selected["candidateID"], partial["candidateID"])
        self.assertEqual(selected["commitScope"], {"consumedReading": "きょう", "remainingReading": "はにほんご"})
        focused = next(node for node in selected_view["nodes"] if node["id"] == selected_view["focusedNode"])
        self.assertEqual(focused["preview"]["text"], selected["text"])
        self.assertEqual(focused["preview"]["scope"], selected["commitScope"])
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["今日"])
        self.assertEqual(committed["preedit"], "はにほんご")
        self.assertIsNone(self.inputs[-1].candidate_view)
        self.assertEqual(committed["candidateCompletions"][0]["candidateID"], partial["candidateID"])
        remainder = self.key(0xff0d)
        self.assertEqual(remainder["commits"], ["はにほんご"])
        self.flush_candidates()
        self.assertEqual(len([notice for notice in self.notices if notice.code == "candidate_learning_completed"]), 1)

    def test_lost_real_reading_reply_is_not_replayed_and_preserves_last_displayed_text(self):
        self.assertEqual(self.type("a")["preedit"], "あ")
        reader = self.bridges["reading"]
        reader.lose_key_reply = True
        self.coordinator.key("field", translate(ord("b"), 0), token="unknown", finish=self.finish)
        self.coordinator.key("field", translate(ord("c"), 0), token="unsent", finish=self.finish)
        self.drain_until(lambda: self.coordinator._broken)
        notices = {notice.token: notice for notice in self.notices if notice.token is not None}
        self.assertEqual(notices["unknown"].phase, "response-unknown")
        self.assertEqual(notices["unknown"].displayed_snapshot["preedit"], "あ")
        self.assertEqual(notices["unsent"].phase, "not-sent")
        sent = [payload["event"]["characters"] for operation, payload in reader.operations if operation == "key"]
        self.assertEqual(sent, ["a", "b"])
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "あ")

    def test_reader_process_exit_cannot_send_a_key_with_the_old_owner_to_the_new_process(self):
        self.type("a")
        reader = self.bridges["reading"]
        os.kill(reader.process.pid, signal.SIGKILL)
        reader.process.wait(timeout=WAIT_SECONDS)
        self.coordinator.key("field", translate(ord("b"), 0), token="old-owner", finish=self.finish)
        self.drain_until(lambda: self.coordinator._broken)
        self.assertEqual(self.finished[-1], ("old-owner", True))
        self.assertEqual(self.notices[-1].phase, "not-sent")
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "あ")
        self.assertEqual([payload["event"]["characters"] for operation, payload in reader.operations if operation == "key"], ["a"])

    def test_candidate_restart_does_not_delay_selected_enter_or_replay_learning_to_new_generation(self):
        batch = self.batch()
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGKILL)
        converter.process.wait(timeout=WAIT_SECONDS)
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["日本語"])
        self.drain_until(lambda: any(notice.code == "candidate_worker_changed" for notice in self.notices))
        self.assertFalse(any(operation == "complete" for operation, _ in converter.operations))
        self.assertFalse(self.coordinator._broken)

    def test_private_and_inactive_learning_configuration_keep_confirmed_revision(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        configured = []
        self.coordinator.configure_learning("nothing", 1, configured.append)
        self.drain_until(lambda: configured)
        self.focus("field", private=True)
        batch = self.batch()
        self.assertEqual(batch["authority"]["settingsRevision"], 1)
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.key(0xff0d)
        self.flush_candidates()
        receipt = next(notice.completion for notice in self.notices if notice.code == "candidate_learning_completed")
        self.assertFalse(receipt["learningRequested"])

    def test_key_queued_during_adopt_ack_keeps_selected_source_retained_until_completion(self):
        self.type("nihongo")
        self.key(0x20)
        self.callbacks.drain(1)  # prepare ACK submits candidate calculation.
        self.callbacks.drain(1)  # retained candidate callback submits Core adoption.
        callback, reply = self.callbacks.take()
        self.assertIsNotNone(reply.response.get("candidateReference"))
        self.coordinator.key("field", translate(0x20, 0), token="space", finish=self.finish)
        callback(reply)
        self.assertEqual(self.panels, [])
        self.drain_until(lambda: ("space", True) in self.finished)
        selected = self.inputs[-1].snapshot["preedit"]
        self.assertIsNotNone(self.inputs[-1].snapshot.get("selection"))
        self.assertEqual(len(self.panels), 1)
        self.key(0xff0d)
        self.assertEqual(self.inputs[-1].snapshot["commits"], [selected])
        self.flush_candidates()
        self.assertEqual(len([notice for notice in self.notices if notice.code == "candidate_learning_completed"]), 1)

    def test_restarted_candidate_restores_acknowledged_learning_before_displaying_an_actual_batch(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        configured = []
        self.coordinator.configure_learning("nothing", 1, configured.append)
        self.drain_until(lambda: configured)
        self.focus("field")
        old_batch = self.batch()
        self.coordinator.reset("field", submit=False, token="reset", finish=self.finish)
        self.drain_until(lambda: ("reset", True) in self.finished)
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGKILL)
        converter.process.wait(timeout=WAIT_SECONDS)
        self.type("nihongo")
        for _ in range(2):
            notices = len(self.notices)
            self.key(0x20)
            self.drain_until(lambda: len(self.panels) == 2 or len(self.notices) > notices)
            if len(self.panels) == 2:
                break
        self.assertEqual(len(self.panels), 2)
        batch = self.panels[-1].batch
        self.assertNotEqual(batch["workerGeneration"], old_batch["workerGeneration"])
        self.assertEqual(batch["authority"]["settingsRevision"], 1)
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.key(0xff0d)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["日本語"])
        self.flush_candidates()
        receipt = next(notice.completion for notice in self.notices if notice.code == "candidate_learning_completed")
        self.assertFalse(receipt["learningRequested"])
        self.assertEqual(receipt["candidateID"], candidate["candidateID"])
        self.assertEqual(sum(operation == "complete" for operation, _ in converter.operations), 1)

    def test_rejected_oversized_focus_cannot_cancel_the_following_same_context_private_focus(self):
        self.coordinator.focus_out("field", submit=False, token="out", finish=self.finish)
        self.drain_until(lambda: ("out", True) in self.finished)
        reader = self.bridges["reading"]
        original_request = reader.request
        entered, proceed = threading.Event(), threading.Event()
        gate_pending = True

        def hold_first_focus(operation, **payload):
            nonlocal gate_pending
            if operation == "focus-in" and gate_pending:
                gate_pending = False
                entered.set()
                if not proceed.wait(WAIT_SECONDS):
                    raise RuntimeError("focus fixture gate expired")
            return original_request(operation, **payload)

        reader.request = hold_first_focus
        rejected, reopened = [], []
        # The actual reading protocol rejects context beyond its 16 KiB limit.
        self.coordinator.focus_in("field", {"leftContext": "x" * (16 * 1024 + 1),
                                             "rightContext": "", "privateInput": False}, rejected.append)
        self.assertTrue(entered.wait(WAIT_SECONDS))
        try:
            self.coordinator.focus_out("field", submit=False, token="old-out", finish=self.finish)
            self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": True}, reopened.append)
        finally:
            proceed.set()
        self.drain_until(lambda: reopened)
        self.assertEqual(rejected[0]["error"], "reading_request_limit")
        self.assertNotIn("error", reopened[0])
        self.assertEqual(self.type("a")["preedit"], "あ")
        self.assertEqual(self.inputs[-1].reference, reopened[0]["reference"])
        self.assertTrue(self.coordinator._contexts["field"].private_input)


if __name__ == "__main__":
    unittest.main()
