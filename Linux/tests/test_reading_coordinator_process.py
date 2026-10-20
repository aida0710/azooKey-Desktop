"""Real converter-free reading and candidate JSONL processes, without a frontend."""
from copy import deepcopy
import json
import os
from pathlib import Path
import queue
import signal
import sys
import tempfile
import threading
import time
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate
from azookey.reading_coordinator import ReadingCoordinator
from candidate_fixture import CallbackQueue, WAIT_SECONDS


class ObservedReadingProcess(Bridge):
    def __init__(self, environment):
        self.operations = []
        self.started = queue.Queue()
        self.threads = set()
        self.lose_key_reply = False
        super().__init__(timeout=WAIT_SECONDS, environment=environment)

    def request(self, operation, **payload):
        self.threads.add(threading.get_ident())
        self.operations.append((operation, deepcopy(payload)))
        self.started.put(operation)
        response = super().request(operation, **payload)
        if operation == "key" and self.lose_key_reply:
            self.lose_key_reply = False
            raise RuntimeError("fixture lost an actual reading acknowledgement")
        return response


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingCoordinatorProcessTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        self.callbacks = CallbackQueue()
        self.inputs = []
        self.panels = []
        self.notices = []
        self.finished = []
        self.bridges = {}
        self.environment = {**os.environ, "AZOOKEY_DATA_DIR": str(self.directory / "data"),
                            "AZOOKEY_RESOURCES": str(self.directory / "absent-models"),
                            "XDG_CONFIG_HOME": str(self.directory / "config"),
                            "XDG_DATA_HOME": str(self.directory / "data-home")}

        def factory(role):
            bridge = ObservedReadingProcess({**self.environment, "AZOOKEY_BRIDGE_ROLE": role})
            self.bridges[role] = bridge
            return bridge

        self.coordinator = ReadingCoordinator(self.callbacks.dispatch, publish_input=self.inputs.append,
                                              publish_candidates=self.panels.append, notify=self.notices.append,
                                              reader_factory=lambda: factory("reading"),
                                              candidate_factory=lambda: factory("candidate"))
        self.drain_until(lambda: self.coordinator._generation and self.coordinator._candidate_settings)
        self.focus("field", opening=True)

    def tearDown(self):
        self.coordinator.close()
        for transport in (self.coordinator.transport, self.coordinator.candidates.transport):
            transport.worker.join(WAIT_SECONDS)
            self.assertFalse(transport.worker.is_alive())
        for bridge in self.bridges.values():
            self.assertEqual(len(bridge.threads), 1)
            self.assertNotIn(threading.get_ident(), bridge.threads)

    def drain_until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("real reading condition did not complete")

    def finish(self, token, consumed):
        self.finished.append((token, consumed))

    def focus(self, context, *, opening=False, private=False):
        if opening:
            self.coordinator.open_context(context)
        ready = []
        self.coordinator.focus_in(context, {"leftContext": "", "rightContext": "", "privateInput": private}, ready.append)
        self.drain_until(lambda: ready)
        self.assertNotIn("error", ready[0])

    def key(self, keyval, *, context="field", modifiers=0):
        token = object()
        self.coordinator.key(context, translate(keyval, modifiers), token=token, finish=self.finish)
        self.drain_until(lambda: any(completed is token for completed, _ in self.finished))
        self.assertFalse(self.coordinator._broken, [notice.code for notice in self.notices])
        return self.inputs[-1].snapshot

    def type(self, text, *, context="field"):
        snapshot = None
        for character in text:
            snapshot = self.key(ord(character), context=context)
        return snapshot

    def batch(self, text="nihongo"):
        self.type(text)
        self.key(0x20)
        self.drain_until(lambda: self.panels)
        return self.panels[-1].batch

    def select(self, batch, candidate):
        token = object()
        reference = {field: batch[field] for field in ("authority", "workerGeneration", "batchID")}
        self.coordinator.select("field", {"batch": reference, "candidateID": candidate["candidateID"]},
                                token=token, finish=self.finish)
        self.drain_until(lambda: any(completed is token for completed, _ in self.finished))
        self.assertEqual(self.inputs[-1].snapshot["preedit"].startswith(candidate["text"]), True)

    def flush_candidates(self):
        replies = []
        self.coordinator.candidates.settings(replies.append)
        self.drain_until(lambda: replies)
        self.assertIsNone(replies[0].error)

    def record(self, **fields):
        destination = os.environ.get("AZOOKEY_READING_COORDINATOR_EVIDENCE")
        if destination:
            with open(destination, "a", encoding="utf-8") as output:
                output.write(json.dumps({"test": self.id(), **fields}, sort_keys=True) + "\n")

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
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["日本語"])
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
        committed = self.key(0xff0d)
        self.assertEqual(committed["commits"], ["今日"])
        self.assertEqual(committed["preedit"], "はにほんご")
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


if __name__ == "__main__":
    unittest.main()
