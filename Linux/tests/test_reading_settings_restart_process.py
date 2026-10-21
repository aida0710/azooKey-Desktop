"""Restart boundaries against actual JSONL workers and bytes written to stdin."""
import json
import os
import signal
import sys
import threading
import unittest
from unittest.mock import patch

from candidate_fixture import WAIT_SECONDS
from reading_process_fixture import ReadingProcessTestCase
from worker_settings_fixture import settings_values


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingSettingsRestartProcessTests(ReadingProcessTestCase):
    def prepare_worker_settings(self):
        return {"settings": settings_values(inputStyle="custom", customTable="q\tにほんご\n", learning="nothing")}

    def restart_at_boundary(self, boundary):
        self.assertEqual(self.type("q")["preedit"], "にほんご")
        converter = self.bridges["candidate"]
        original_pid = converter.process.pid
        bridge = self.bridges["reading"] if boundary == "prepare" else converter
        operation_to_restart = "prepare-candidates" if boundary == "prepare" else "candidates"
        original_request = bridge.request
        restarted = False

        def stop_candidate():
            os.kill(converter.process.pid, signal.SIGKILL)
            converter.process.wait(timeout=WAIT_SECONDS)

        def restart_once(operation, **payload):
            nonlocal restarted
            if operation != operation_to_restart or restarted:
                return original_request(operation, **payload)
            restarted = True
            if boundary == "prepare":
                response = original_request(operation, **payload)
                stop_candidate()
                return response
            stop_candidate()
            return original_request(operation, **payload)

        bridge.request = restart_once
        written_operations, buffers = [], {}
        original_write = os.write

        def observe_written_operation(descriptor, message):
            written = original_write(descriptor, message)
            if threading.get_ident() in converter.threads:
                pid = converter.process.pid
                buffers[pid] = buffers.get(pid, b"") + bytes(message[:written])
                while b"\n" in buffers[pid]:
                    line, buffers[pid] = buffers[pid].split(b"\n", 1)
                    written_operations.append((pid, json.loads(line)["operation"]))
            return written

        with patch("azookey.bridge.os.write", side_effect=observe_written_operation):
            self.key(0x20)
            self.drain_until(lambda: self.panels)
        self.assertTrue(restarted)
        replacement_pid = converter.process.pid
        self.assertNotEqual(replacement_pid, original_pid)
        operations = [name for pid, name in written_operations if pid == replacement_pid]
        self.assertLess(operations.index("configure-settings"), operations.index("candidates"))
        self.assertEqual(operations.count("candidates"), 1)
        self.assertEqual(len(self.finished), 2)
        self.assertEqual(len(self.inputs), 2)
        self.assertEqual([item.snapshot["commits"] for item in self.inputs], [[], []])

        batch = self.panels[-1].batch
        self.assertEqual(batch["authority"]["settingsRevision"], 0)
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.assertEqual(self.key(0xff0d)["commits"], ["日本語"])
        self.flush_candidates()
        receipts = [notice.completion for notice in self.notices if notice.code == "candidate_learning_completed"]
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0]["candidateID"], candidate["candidateID"])
        self.assertFalse(receipts[0]["learningRequested"])
        self.record(restart_boundary=boundary, original_pid=original_pid, replacement_pid=replacement_pid,
                    replacement_written_operations=operations, committed="日本語", original_replies=len(self.finished),
                    candidate_id=candidate["candidateID"], learning_requested=False)

    def test_exit_after_preparation_restores_custom_settings_before_actual_calculation(self):
        self.restart_at_boundary("prepare")

    def test_exit_after_connection_cannot_write_calculation_before_actual_configuration(self):
        self.restart_at_boundary("write")


if __name__ == "__main__":
    unittest.main()
