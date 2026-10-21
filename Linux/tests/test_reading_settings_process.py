"""Real settings, custom input, candidate recovery and privacy across two workers."""
import hashlib
import os
import signal
import sys
import unittest

from candidate_fixture import WAIT_SECONDS
from reading_process_fixture import ReadingProcessTestCase
from worker_settings_fixture import settings_values


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires both real Linux Swift process roles")
class ReadingSettingsProcessTests(ReadingProcessTestCase):
    def prepare_worker_settings(self):
        return {"settings": settings_values(halfSpace=True, candidateTextSize="large", showRelativeScores=False)}

    def blur(self):
        token = object()
        self.coordinator.focus_out("field", submit=False, token=token, finish=self.finish)
        self.drain_until(lambda: any(owner is token for owner, _ in self.finished))

    def configure(self, settings, revision, *, private=False):
        self.blur()
        configured = []
        self.coordinator.configure_settings(settings, revision, configured.append)
        self.drain_until(lambda: configured)
        self.assertNotIn("error", configured[0])
        self.drain_until(lambda: self.coordinator._settings_agreement.confirmed_identity is not None)
        self.focus("field", private=private)

    def test_initial_settings_change_formal_space_and_display_values(self):
        snapshot = self.key(0x20)
        self.assertEqual(snapshot["commits"], [" "])
        self.assertEqual(snapshot["candidateTextSize"], "large")
        self.assertFalse(snapshot["showRelativeScores"])
        self.configure(settings_values(halfSpace=False), 1)
        snapshot = self.key(0x20)
        self.assertEqual(snapshot["commits"], ["　"])
        self.assertEqual(snapshot["candidateTextSize"], "standard")
        self.assertTrue(snapshot["showRelativeScores"])

    def test_candidate_stop_during_settings_change_does_not_delay_new_reading_settings(self):
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGSTOP)
        try:
            stopped_pid, stopped_status = os.waitpid(converter.process.pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(stopped_status))
            self.blur()
            configured = []
            self.coordinator.configure_settings(settings_values(inputStyle="defaultAZIK"), 1, configured.append)
            self.drain_until(lambda: configured)
            self.assertNotIn("error", configured[0])
            self.focus("field")
            self.assertEqual(self.type("kz")["preedit"], "かん")
            self.assertEqual(self.key(0xff0d)["commits"], ["かん"])
            self.assertEqual(self.panels, [])
            self.assertTrue(self.coordinator._settings_agreement.pending)
            self.record(candidate_stopped=True, new_reading="かん", settings_revision=1,
                        original_replies=len(self.finished))
        finally:
            os.kill(converter.process.pid, signal.SIGCONT)
        self.drain_until(lambda: self.coordinator._settings_agreement.confirmed_identity is not None)
        self.assertEqual(self.panels, [])

    def test_custom_table_drives_real_candidates_and_leaves_saved_files_unchanged(self):
        persistent = self.directory / "config" / "azookey-tree"
        persistent.mkdir(parents=True, exist_ok=True)
        saved = {
            persistent / "settings.json": b'{"syntheticPreserved":true}\n',
            persistent / "settings.last-good.json": b'{"syntheticLastGood":true}\n',
            self.directory / "data" / "custom_input_table.tsv": "z\tもとのひょう\n".encode(),
        }
        for path, contents in saved.items():
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(contents)
        values = settings_values(inputStyle="custom", customTable="q\tにほんご\n")
        self.configure(values, 1)
        self.assertEqual(self.type("q")["preedit"], "にほんご")
        self.key(0x20)
        self.drain_until(lambda: self.panels)
        batch = self.panels[-1].batch
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.assertEqual(self.key(0xff0d)["commits"], ["日本語"])
        self.flush_candidates()
        digest = hashlib.sha256(values["customTable"].encode()).hexdigest()
        agreement = self.coordinator._settings_agreement
        self.assertEqual(list(agreement.reader["customInputTableRevisions"].values()), [digest])
        self.assertEqual(agreement.reader["customInputTableRevisions"],
                         agreement.observed.settings["customInputTableRevisions"])
        for path, contents in saved.items():
            self.assertEqual(path.read_bytes(), contents, path)
        self.assertEqual(set(persistent.iterdir()), {persistent / "settings.json", persistent / "settings.last-good.json"})
        receipt = next(notice.completion for notice in self.notices if notice.code == "candidate_learning_completed")
        self.assertFalse(receipt["learningRequested"])
        self.record(custom_table_sha256=digest, committed="日本語", persistent_files_unchanged=len(saved))

    def test_restarted_candidate_restores_custom_input_and_current_learning_before_display(self):
        values = settings_values(inputStyle="custom", customTable="q\tにほんご\n", learning="nothing")
        self.configure(values, 1)
        old_batch = self.batch("q")
        self.key(0xff1b)
        converter = self.bridges["candidate"]
        os.kill(converter.process.pid, signal.SIGKILL)
        converter.process.wait(timeout=WAIT_SECONDS)
        self.type("q")
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
        self.assertEqual(self.key(0xff0d)["commits"], ["日本語"])
        self.flush_candidates()
        receipt = next(notice.completion for notice in self.notices if notice.code == "candidate_learning_completed")
        self.assertFalse(receipt["learningRequested"])
        self.assertEqual(receipt["candidateID"], candidate["candidateID"])
        self.assertEqual(sum(operation == "complete" for operation, _ in converter.operations), 1)

    def test_private_focus_prevents_learning_after_custom_configuration(self):
        values = settings_values(inputStyle="custom", customTable="q\tにほんご\n", learning="inputAndOutput")
        self.configure(values, 1, private=True)
        batch = self.batch("q")
        candidate = next(item for item in batch["candidates"] if item["text"] == "日本語")
        self.select(batch, candidate)
        self.assertEqual(self.key(0xff0d)["commits"], ["日本語"])
        self.flush_candidates()
        receipt = next(notice.completion for notice in self.notices if notice.code == "candidate_learning_completed")
        self.assertFalse(receipt["learningRequested"])
        self.assertEqual(receipt["candidateID"], candidate["candidateID"])


if __name__ == "__main__":
    unittest.main()
