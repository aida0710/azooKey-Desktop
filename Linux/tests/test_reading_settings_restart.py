"""A replacement candidate process must confirm settings before calculation."""
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from candidate_fixture import WAIT_SECONDS
from worker_settings_fixture import ReadingSettingsTestCase, settings_values


class ReadingSettingsRestartTests(ReadingSettingsTestCase):
    def prepare_candidate_request(self):
        self.start(settings_values(halfSpace=True, inputStyle="defaultAZIK", learning="nothing"))
        self.agreed()
        self.focus()
        self.key("a")
        prepared = self.reader.gate("prepare-candidates")
        self.key("", 49)
        self.assertTrue(prepared.entered.wait(WAIT_SECONDS))
        return prepared

    def test_restart_after_preparation_restores_settings_before_calculating_current_reading(self):
        prepared = self.prepare_candidate_request()
        # The reading request owns worker-0 even though the next transport
        # connection will discover worker-1. No delay determines this order.
        self.converter.dead = True
        prepared.proceed.set()
        self.until(lambda: self.panels)

        self.assertEqual(self.converter.values, self.reader.values)
        self.assertEqual(self.panels[-1].batch["workerGeneration"], "worker-1")
        replacements = [name for generation, name, _ in self.converter.calls if generation == "worker-1"]
        self.assertLess(replacements.index("configure-settings"), replacements.index("candidates"))
        prepared_generations = [payload["candidateWorkerGeneration"] for name, payload in self.reader.calls
                                if name == "prepare-candidates"]
        self.assertEqual(prepared_generations, ["worker-0", "worker-1"])
        self.assertEqual(len(self.finished), 2)
        self.assertEqual(len(self.inputs), 2)
        self.assertEqual(self.converter.learning_updates, [])

    def test_restart_between_connection_and_write_never_calculates_with_default_settings(self):
        prepared = self.prepare_candidate_request()
        request = self.converter.request
        restart_before_write = True

        def restarted_request(operation, **payload):
            nonlocal restart_before_write
            if operation == "candidates" and restart_before_write:
                restart_before_write = False
                self.converter.dead = True
            return request(operation, **payload)

        self.converter.request = restarted_request
        prepared.proceed.set()
        self.until(lambda: self.panels)
        self.assertEqual(self.converter.values, self.reader.values)
        replacement_operations = [name for generation, name, _ in self.converter.calls if generation == "worker-1"]
        self.assertLess(replacement_operations.index("configure-settings"), replacement_operations.index("candidates"))
        self.assertEqual(replacement_operations.count("candidates"), 1)
        self.assertEqual(len(self.finished), 2)
        self.assertEqual(self.converter.learning_updates, [])

    def test_return_during_replacement_configuration_commits_once_without_recalculating_old_reading(self):
        prepared = self.prepare_candidate_request()
        configured = self.converter.gate("configure-settings")
        self.converter.dead = True
        prepared.proceed.set()
        self.until(lambda: self.agreement().pending and self.agreement().observed is not None
                   and self.agreement().observed.worker_generation == "worker-1")
        self.assertTrue(configured.entered.wait(WAIT_SECONDS))
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(len(self.finished), 3)
        configured.proceed.set()
        self.agreed()
        self.assertEqual(self.panels, [])
        self.assertFalse(any(name == "candidates" for _, name, _ in self.converter.calls))
        self.assertEqual(self.converter.learning_updates, [])

    def test_unknown_replacement_configuration_keeps_input_responsive_and_waits_for_explicit_retry(self):
        prepared = self.prepare_candidate_request()
        self.converter.fail("configure-settings", after_effect=True)
        self.converter.dead = True
        prepared.proceed.set()
        self.until(lambda: self.agreement().failed)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(len(self.finished), 3)
        self.assertEqual(self.panels, [])
        self.assertEqual(sum(name == "configure-settings" for _, name, _ in self.converter.calls), 2)
        self.coordinator.retry_candidate_settings()
        self.agreed()
        self.assertEqual(self.converter.values, self.reader.values)
        self.assertFalse(any(name in ("candidates", "complete") for _, name, _ in self.converter.calls))

    def test_repeated_restarts_end_candidate_recovery_and_allow_the_next_input(self):
        prepared = self.prepare_candidate_request()
        request = self.converter.request

        def restarted_request(operation, **payload):
            if operation == "candidates":
                self.converter.dead = True
            return request(operation, **payload)

        self.converter.request = restarted_request
        prepared.proceed.set()
        self.until(lambda: sum(notice.code == "candidate_worker_changed" for notice in self.notices) == 2)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(len(self.finished), 3)
        self.assertEqual(self.panels, [])
        self.assertEqual(sum(name == "prepare-candidates" for name, _ in self.reader.calls), 2)
        self.assertFalse(any(name in ("candidates", "complete") for _, name, _ in self.converter.calls))


if __name__ == "__main__":
    unittest.main()
