"""Dictionary preparation cannot stall input or bypass agreement between workers."""
from copy import deepcopy
import unittest

from azookey import candidate_protocol, reading_protocol, worker_settings
from candidate_fixture import WAIT_SECONDS
from reading_dictionary_fixture import (
    FIRST_DICTIONARY, SECOND_DICTIONARY, DictionaryCandidateFixture, DictionaryReadingFixture,
)
from worker_settings_fixture import ReadingSettingsTestCase, settings_acknowledgement, settings_values


class ReadingDictionaryTests(ReadingSettingsTestCase):
    def setUp(self):
        super().setUp()
        self.reader = DictionaryReadingFixture()
        self.converter = DictionaryCandidateFixture()
        self.start()
        self.agreed()

    def applied(self, revision=FIRST_DICTIONARY):
        self.until(lambda: self.agreement().reader is not None
                   and self.agreement().reader.get("dictionaryRevision") == revision
                   and self.agreement().confirmed_identity is not None)
        self.assertEqual(self.converter.dictionary, revision)

    def blur(self):
        replies = []
        self.coordinator.focus_out("field", submit=False, token="blur",
                                   finish=lambda *value: replies.append(value))
        self.until(lambda: replies)

    def test_stopped_preparation_keeps_input_responsive_and_applies_only_after_focus_out(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        self.converter.saved_dictionary = SECOND_DICTIONARY
        self.focus()
        self.until(lambda: self.coordinator._contexts["field"].active)
        gate = self.converter.gate("prepare-dictionary")
        self.coordinator.refresh_dictionary()
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.key("a")
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertFalse(gate.proceed.is_set())
        gate.proceed.set()
        self.until(lambda: self.coordinator._dictionary.available is not None)
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)
        before = deepcopy(self.inputs)
        self.blur()
        self.applied(SECOND_DICTIONARY)
        self.assertEqual(self.reader.dictionary, SECOND_DICTIONARY)
        self.assertFalse(any(value.snapshot["commits"] for value in self.inputs[len(before):]))
        self.assertFalse(self.converter.learning_updates)
        operations = [name for _, name, _ in self.converter.calls]
        self.assertLess(operations.index("close"), len(operations) - 1 - operations[::-1].index("configure-settings"))

    def test_repeated_same_dictionary_does_not_advance_revision_or_duplicate_configuration(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        configured = sum(name == "configure-settings" for name, _ in self.reader.calls)
        revision = self.agreement().reader["settingsRevision"]
        self.coordinator.refresh_dictionary()
        self.until(lambda: not self.coordinator._dictionary.pending)
        self.assertEqual(sum(name == "configure-settings" for name, _ in self.reader.calls), configured)
        self.assertEqual(self.agreement().reader["settingsRevision"], revision)

    def test_later_save_during_preparation_only_applies_the_latest_requested_dictionary(self):
        gate = self.converter.gate("prepare-dictionary")
        self.coordinator.refresh_dictionary()
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.coordinator.refresh_dictionary()
        self.converter.saved_dictionary = SECOND_DICTIONARY
        gate.proceed.set()
        self.applied(SECOND_DICTIONARY)
        applied = [payload.get("dictionaryRevision") for name, payload in self.reader.calls
                   if name in ("configure-settings", "bind-initial-dictionary")]
        self.assertEqual(applied, [None, SECOND_DICTIONARY])

    def test_preparation_failure_preserves_current_dictionary_and_formal_input(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        self.focus()
        self.converter.fail("prepare-dictionary", after_effect=True)
        self.coordinator.refresh_dictionary()
        self.until(lambda: any(notice.operation == "prepare-dictionary" for notice in self.notices))
        self.key("a")
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)
        self.assertFalse(self.coordinator._broken)

    def test_failed_preparation_still_honors_the_next_explicit_save_request(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        gate = self.converter.gate("prepare-dictionary")
        self.converter.fail("prepare-dictionary", after_effect=True)
        self.coordinator.refresh_dictionary()
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.converter.saved_dictionary = SECOND_DICTIONARY
        self.coordinator.refresh_dictionary()
        gate.proceed.set()
        self.applied(SECOND_DICTIONARY)
        self.assertTrue(any(notice.operation == "prepare-dictionary" for notice in self.notices))

    def test_unrelated_settings_change_preserves_the_acknowledged_dictionary(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        self.coordinator.configure_settings(settings_values(halfSpace=True), 2)
        self.until(lambda: self.agreement().reader is not None
                   and self.agreement().reader["settingsRevision"] == 2)
        self.agreed()
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)
        self.assertEqual(self.converter.dictionary, FIRST_DICTIONARY)

    def test_restarted_candidate_prepares_the_same_dictionary_before_new_candidates(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        self.focus()
        self.key("a")
        self.key("", 49)
        self.until(lambda: self.panels)
        self.converter.dead = True
        self.key("", 53)
        self.key("b")
        self.key("", 49)
        self.until(lambda: len(self.panels) == 2)
        self.assertEqual(self.panels[-1].batch["workerGeneration"], "worker-1")
        self.assertEqual(self.converter.dictionary, FIRST_DICTIONARY)
        restarted = [name for generation, name, _ in self.converter.calls if generation == "worker-1"]
        self.assertLess(restarted.index("prepare-dictionary"), restarted.index("configure-settings"))
        self.assertLess(restarted.index("configure-settings"), restarted.index("candidates"))
        self.assertFalse(self.converter.learning_updates)

    def test_restarted_candidate_with_a_different_saved_dictionary_cannot_display_it(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        self.focus()
        self.converter.saved_dictionary = SECOND_DICTIONARY
        self.converter.dead = True
        self.key("a")
        self.key("", 49)
        self.until(lambda: self.agreement().failed)
        self.assertTrue(any(notice.code == "candidate_dictionary_changed" for notice in self.notices))
        self.assertEqual(self.panels, [])
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)

    def test_same_settings_revision_rejects_a_different_dictionary(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        with self.assertRaises(ValueError):
            self.coordinator.configure_settings(settings_values(), self.agreement().reader["settingsRevision"],
                                                dictionary_revision=SECOND_DICTIONARY)
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)

    def test_same_dictionary_refresh_recovers_a_failed_restart_without_reconfiguring_the_reader(self):
        self.coordinator.refresh_dictionary()
        self.applied()
        configured = sum(name == "configure-settings" for name, _ in self.reader.calls)
        self.converter.dead = True
        self.converter.fail("prepare-dictionary", after_effect=True)
        self.coordinator.retry_candidate_settings()
        self.until(lambda: self.agreement().failed)
        self.coordinator.refresh_dictionary()
        self.applied()
        self.assertFalse(self.agreement().failed)
        self.assertEqual(sum(name == "configure-settings" for name, _ in self.reader.calls), configured)

    def test_initial_dictionary_preparation_allows_input_but_no_unacknowledged_candidates_or_inverse(self):
        self.focus()
        self.until(lambda: self.coordinator._contexts["field"].active)
        gate = self.converter.gate("prepare-dictionary")
        self.coordinator.refresh_dictionary()
        self.callbacks.drain(1)
        self.assertTrue(gate.entered.wait(WAIT_SECONDS))
        self.key("a")
        self.key("", 49)
        self.assertEqual(self.inputs[-1].snapshot["preedit"], "a")
        self.assertIsNone(self.coordinator.prepare_reconversion_worker())
        self.assertEqual(self.panels, [])
        binding = self.reader.gate("bind-initial-dictionary")
        before = deepcopy(self.inputs[-1].snapshot)
        gate.proceed.set()
        self.until(lambda: not self.coordinator._dictionary.pending)
        self.assertTrue(binding.entered.wait(WAIT_SECONDS))
        self.assertEqual(self.panels, [])
        self.assertFalse(any(name == "candidates" for _, name, _ in self.converter.calls))
        self.assertEqual(self.inputs[-1].snapshot, before)
        binding.proceed.set()
        self.applied()
        self.until(lambda: self.panels)
        self.assertTrue(self.coordinator._contexts["field"].active)
        self.assertEqual(self.agreement().reader["settingsRevision"], 0)
        self.assertEqual(self.inputs[-1].snapshot, before)


class DictionaryProtocolTests(unittest.TestCase):
    def test_dictionary_identity_rejects_text_paths_non_hex_and_wrong_lengths(self):
        for value in ("日本語", "/tmp/dictionary", "A" * 64, "g" * 64, "a" * 63, None, 1):
            with self.subTest(value=value), self.assertRaises(ValueError):
                worker_settings.dictionary_revision(value)

    def test_reader_cannot_acknowledge_a_different_dictionary(self):
        values = settings_values()
        response = {"kind": "acknowledgement", "readingProcessGeneration": "reader",
                    "settingsRevision": 1, "dictionaryRevision": SECOND_DICTIONARY,
                    **settings_acknowledgement(values)}
        with self.assertRaises(ValueError):
            reading_protocol.response(response, "configure-settings",
                                      {"settings": values, "settingsRevision": 1,
                                       "dictionaryRevision": FIRST_DICTIONARY})

    def test_prepared_dictionary_is_only_accepted_for_its_own_operation(self):
        response = DictionaryCandidateFixture()._respond("prepare-dictionary", {})
        with self.assertRaises(ValueError):
            candidate_protocol.settings_response(response)
        response.pop("preparedDictionaryRevision")
        with self.assertRaises(ValueError):
            candidate_protocol.settings_response(response, prepared_dictionary=True)


if __name__ == "__main__":
    unittest.main()
