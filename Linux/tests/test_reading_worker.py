"""Real JSONL lifecycle and converter-independent formal input."""
import os
from pathlib import Path
import signal
import unittest

from Linux.tests.reading_worker_fixture import ReadingWorkerCase, REQUEST_TIMEOUT_SECONDS


class ReadingWorkerTests(ReadingWorkerCase):
    def test_reading_edit_and_enter_work_while_the_separate_converter_process_is_stopped(self):
        from azookey.bridge import Bridge

        converter_environment = {**self.environment, "AZOOKEY_DATA_DIR": str(self.directory / "converter")}
        converter_environment.pop("AZOOKEY_BRIDGE_ROLE")
        converter = Bridge(timeout=REQUEST_TIMEOUT_SECONDS, environment=converter_environment)
        try:
            converter.request("snapshot")
            self.assertNotEqual(converter.process.pid, self.bridge.process.pid)
            os.kill(converter.process.pid, signal.SIGSTOP)
            stopped_pid, status = os.waitpid(converter.process.pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(status))
            self.assertEqual(self.type("nihongo")["preedit"], "にほんご")
            self.assertEqual(self.key(0xFF51)["snapshot"]["cursor"], 3)
            self.assertEqual(self.type("a")["preedit"], "にほんあご")
            self.assertEqual(self.key(0xFF08)["snapshot"]["preedit"], "にほんご")
            self.assertEqual(self.key(0xFFFF)["snapshot"]["preedit"], "にほん")
            committed = self.key(0xFF0D)["snapshot"]
            self.assertEqual(committed["commits"], ["にほん"])
            self.assertEqual(committed["preedit"], "")
            self.assertEqual(self.type("a")["preedit"], "あ")
            self.assertEqual(self.key(0xFF1B)["snapshot"]["preedit"], "")
            self.assertIsNone(converter.process.poll())
            process_status = Path(f"/proc/{converter.process.pid}/status").read_text()
            self.assertRegex(process_status, r"(?m)^State:\s+T\b")
        finally:
            if converter.process.poll() is None:
                os.kill(converter.process.pid, signal.SIGCONT)
            converter.close()
        self.assertEqual(self.blocked_data_path.read_text(), "do not replace\n")
        mappings = Path(f"/proc/{self.bridge.process.pid}/maps").read_text()
        for suffix in (".gguf", ".louds", ".loudstxt", ".marisa"):
            self.assertNotIn(suffix, mappings)
        self.assertFalse(self.snapshot()["zenzaiLoaded"])

    def test_focus_out_commits_once_and_delayed_old_field_keys_cannot_edit_the_new_field(self):
        self.type("nihongo")
        old_focus = self.reference
        other = self.open("second")
        self.assert_rejected_without_edit("focus-in", reference=other,
                                          surroundings={"leftContext": "", "rightContext": "", "privateInput": False})
        self.assert_rejected_without_edit("close", reference=self.reference)
        self.assertEqual(self.focus_out(submit=True)["commits"], ["にほんご"])
        inactive = self.reference
        self.assert_rejected_without_edit("focus-out", reference=old_focus, submit=True,
                                          error="stale_reading_focus")
        self.reference = other
        self.focus()
        self.type("a")
        for reference in (old_focus, inactive):
            self.assert_rejected_without_edit("key", reference=reference,
                                              event={"keyCode": 0, "characters": "b", "modifierFlags": 0})
        self.assertEqual(self.snapshot()["preedit"], "あ")
        self.assertEqual(self.key(0xFF8D)["snapshot"]["commits"], ["あ"])
        self.assertEqual(self.request("snapshot", reference=inactive)["snapshot"]["preedit"], "")

    def test_cancel_and_same_name_reopen_retire_focus_and_pending_candidates(self):
        self.type("nihongo")
        batch = self.batch()
        old_reference = self.reference
        self.assertEqual(self.focus_out(submit=False)["commits"], [])
        self.assertEqual(self.snapshot()["preedit"], "")
        self.request("close", reference=self.reference)
        self.reference = self.open("field")
        self.focus(private=True)
        self.type("nihongo")
        self.assertGreater(self.reference["focusEpoch"], old_reference["focusEpoch"])
        self.assert_rejected_without_edit("key", reference=old_reference,
                                          event={"keyCode": 36, "modifierFlags": 0})
        self.assert_rejected_without_edit("adopt-candidates", reference=self.reference, batch=batch,
                                          retainedReference=self.batch_reference(batch))
        request = self.prepare()
        self.assertTrue(request["privateInput"])
        self.assertEqual(request["authority"]["focusEpoch"], self.reference["focusEpoch"])

    def test_unsupported_actions_and_stale_process_do_not_discard_the_active_reading(self):
        self.type("nihongo")
        self.key(0xFF51)
        before = self.snapshot()
        reply = self.key(0xFF09)
        self.assertEqual(reply["error"], "unsupported_reading_action")
        self.assertEqual(self.snapshot(), before)
        self.assert_rejected_without_edit("reset", reference={**self.reference, "readingProcessGeneration": "old"},
                                          submit=True, error="wrong_reading_process_generation")
        self.assert_rejected_without_edit("key", reference={**self.reference, "context": "unknown"},
                                          event={"keyCode": 36, "modifierFlags": 0}, error="unknown_reading_context")
        self.assertEqual(self.type("a")["preedit"], "にほんあご")
        self.assertEqual(self.key(0xFF8D)["snapshot"]["commits"], ["にほんあご"])


if __name__ == "__main__":
    unittest.main()
