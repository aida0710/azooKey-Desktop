"""Settings agreement must never give the candidate process input ownership."""
from copy import deepcopy
from pathlib import Path
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.reading_coordinator import ReadingCoordinator
from azookey.reading_protocol import response
from azookey.worker_settings import validated_settings
from candidate_fixture import CallbackQueue, WAIT_SECONDS
from reading_coordinator_fixture import event
from worker_settings_fixture import (
    ConfiguredCandidateFixture, ConfiguredReadingFixture, settings_values,
)


class ReadingSettingsTests(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.reader = ConfiguredReadingFixture()
        self.converter = ConfiguredCandidateFixture()
        self.inputs, self.panels, self.notices, self.finished = [], [], [], []
        self.coordinator = None

    def tearDown(self):
        if self.coordinator is not None:
            self.coordinator.close()
            for transport in (self.coordinator.transport, self.coordinator.candidates.transport):
                transport.worker.join(WAIT_SECONDS)
                self.assertFalse(transport.worker.is_alive())

    def start(self, settings=None):
        self.coordinator = ReadingCoordinator(
            self.callbacks.dispatch, publish_input=self.inputs.append,
            publish_candidates=self.panels.append, notify=self.notices.append,
            reader_factory=lambda: self.reader, candidate_factory=lambda: self.converter,
            settings=settings if settings is not None else settings_values(),
        )

    def until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("settings condition did not complete")

    def focus(self):
        self.coordinator.open_context("field")
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False})

    def key(self, text="", code=0):
        token = object()
        self.coordinator.key("field", event(text, code), token=token,
                             finish=lambda owner, consumed: self.finished.append((owner, consumed)))
        self.until(lambda: any(owner is token for owner, _ in self.finished))

    def agreement(self):
        return self.coordinator._settings_agreement

    def agreed(self):
        self.until(lambda: self.agreement().confirmed_identity is not None)

    def test_candidate_startup_does_not_delay_configured_reading_or_original_replies(self):
        startup = self.converter.gate("settings")
        self.start(settings_values(halfSpace=True, punctuation=4))
        self.focus()
        self.key("a")
        self.key("", 49)
        self.key("", 36)
        self.assertTrue(startup.entered.is_set())
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(len(self.finished), 3)
        self.assertEqual(self.panels, [])
        self.assertTrue(self.reader.values["halfSpace"])
        self.assertEqual(self.reader.values["punctuation"], 4)
        startup.proceed.set()
        self.agreed()
        self.assertEqual(self.panels, [])
        self.assertEqual(self.converter.values, self.reader.values)

    def test_candidate_configuration_ack_must_arrive_before_prepare_and_display(self):
        configured = self.converter.gate("configure-settings")
        self.start()
        self.focus()
        self.key("a")
        self.key("", 49)
        self.until(lambda: self.agreement().reader is not None)
        self.assertTrue(configured.entered.wait(WAIT_SECONDS))
        self.assertFalse(any(name == "prepare-candidates" for name, _ in self.reader.calls))
        self.assertEqual(self.panels, [])
        configured.proceed.set()
        self.until(lambda: self.panels)
        self.assertEqual(self.panels[0].batch["authority"]["settingsRevision"], 0)
        self.assertEqual(len(self.finished), 2)

    def test_queued_focus_and_inputs_wait_for_the_reader_configuration_ack(self):
        configured = self.reader.gate("configure-settings")
        self.start()
        self.focus()
        self.coordinator.key("field", event("a"), token="input",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: self.coordinator._generation is not None)
        self.assertTrue(configured.entered.wait(WAIT_SECONDS))
        self.assertEqual(self.finished, [])
        self.assertFalse(any(name == "open" for name, _ in self.reader.calls))
        configured.proceed.set()
        self.until(lambda: self.finished)
        operations = [name for name, _ in self.reader.calls]
        self.assertLess(operations.index("configure-settings"), operations.index("open"))
        self.assertLess(operations.index("open"), operations.index("focus-in"))
        self.assertLess(operations.index("focus-in"), operations.index("key"))

    def test_unknown_reader_configuration_retires_queued_input_without_replay(self):
        self.reader.fail("configure-settings", after_effect=True)
        self.start()
        self.focus()
        self.coordinator.key("field", event("a"), token="input",
                             finish=lambda *reply: self.finished.append(reply))
        self.until(lambda: self.finished)
        self.assertTrue(self.coordinator._broken)
        self.assertEqual(self.finished, [("input", True)])
        self.assertEqual(self.inputs, [])
        self.assertEqual([name for name, _ in self.reader.calls].count("configure-settings"), 1)
        self.assertFalse(any(name == "key" for name, _ in self.reader.calls))

    def test_unknown_candidate_configuration_keeps_reading_and_needs_explicit_retry(self):
        self.converter.fail("configure-settings", after_effect=True)
        self.start()
        self.focus()
        self.until(lambda: self.agreement().failed)
        self.key("a")
        self.key("", 49)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertFalse(self.coordinator._broken)
        self.assertEqual(self.panels, [])
        self.assertEqual([name for _, name, _ in self.converter.calls].count("configure-settings"), 1)
        self.coordinator.retry_candidate_settings()
        self.agreed()
        self.assertEqual(self.converter.values, self.reader.values)
        self.assertFalse(any(name == "complete" for _, name, _ in self.converter.calls))

    def test_candidate_table_mismatch_never_authorizes_prepare_or_input_effects(self):
        def changed_table(operation, acknowledgement):
            if operation == "configure-settings":
                acknowledgement["customInputTableRevisions"] = {"another-table": "another-hash"}
            return acknowledgement
        self.converter.rewrite = changed_table
        self.start()
        self.focus()
        self.until(lambda: self.agreement().failed)
        self.key("a")
        self.key("", 49)
        self.assertFalse(any(name == "prepare-candidates" for name, _ in self.reader.calls))
        self.assertEqual(self.panels, [])
        self.assertFalse(self.coordinator._broken)

    def test_restarted_candidate_receives_all_confirmed_settings_before_new_candidates(self):
        self.start(settings_values(halfSpace=True, inputStyle="defaultAZIK", learning="nothing"))
        self.agreed()
        self.focus()
        self.key("a")
        self.key("", 49)
        self.until(lambda: self.panels)
        self.converter.dead = True
        self.key("", 53)
        self.key("b")
        self.key("", 49)
        self.until(lambda: len(self.panels) == 2)
        self.assertEqual(self.converter.values, self.reader.values)
        self.assertEqual(self.panels[-1].batch["workerGeneration"], "worker-1")
        self.assertEqual([name for _, name, _ in self.converter.calls].count("configure-settings"), 2)
        self.assertEqual(self.converter.learning_updates, [])

    def test_idle_change_updates_both_processes_and_rejects_reusing_revision_for_other_values(self):
        self.start()
        self.agreed()
        acknowledged = []
        changed = settings_values(punctuation=4, halfSpace=True, learning="onlyOutput")
        self.coordinator.configure_settings(changed, 1, acknowledged.append)
        self.until(lambda: acknowledged)
        self.agreed()
        self.assertEqual(self.reader.values, changed)
        self.assertEqual(self.converter.values, changed)
        self.assertEqual(self.agreement().reader["settingsRevision"], 1)
        with self.assertRaises(ValueError):
            self.coordinator.configure_settings(settings_values(), 1)
        with self.assertRaises(ValueError):
            self.coordinator.configure_learning("nothing", 2)

    def test_active_focus_cannot_change_settings_between_owned_keys(self):
        self.start()
        self.agreed()
        self.focus()
        self.key("a")
        with self.assertRaises(ValueError):
            self.coordinator.configure_settings(settings_values(halfSpace=True), 1)
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])

    def test_settings_reject_missing_keys_dictionary_body_and_unsupported_operations(self):
        for values in ({**settings_values(), "userDictionary": {"items": []}},
                       {key: value for key, value in settings_values().items() if key != "learning"},
                       settings_values(live=True), settings_values(aiEnabled=True),
                       settings_values(predictiveTyping=True), settings_values(debug=True)):
            with self.subTest(keys=values.keys()), self.assertRaises(ValueError):
                validated_settings(values)

    def test_configuration_ack_cannot_carry_commit_or_changed_setting(self):
        values = settings_values()
        self.reader.values = values
        acknowledgement = self.reader._respond("configure-settings", {"settings": values, "settingsRevision": 0})
        payload = {"readingProcessGeneration": self.reader.generation, "settings": values, "settingsRevision": 0}
        for changed in ({**acknowledgement, "commits": ["unexpected"]},
                        {**acknowledgement, "settings": settings_values(halfSpace=True)},
                        {**acknowledgement, "settingsRevision": 1}):
            with self.assertRaises(ValueError):
                response(deepcopy(changed), "configure-settings", payload)


if __name__ == "__main__":
    unittest.main()
