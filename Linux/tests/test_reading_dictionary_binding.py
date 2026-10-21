"""Initial dictionary agreement preserves input while its candidate side waits."""
from copy import deepcopy
import unittest

from candidate_fixture import WAIT_SECONDS
from reading_dictionary_fixture import (
    FIRST_DICTIONARY, SECOND_DICTIONARY, DictionaryCandidateFixture, DictionaryReadingFixture,
)
from worker_settings_fixture import ReadingSettingsTestCase


class ReadingDictionaryBindingTests(ReadingSettingsTestCase):
    def setUp(self):
        super().setUp()
        self.reader = DictionaryReadingFixture()
        self.converter = DictionaryCandidateFixture()
        self.start()
        self.agreed()

    def bound(self, dictionary=FIRST_DICTIONARY):
        self.until(lambda: self.agreement().reader is not None
                   and self.agreement().reader.get("dictionaryRevision") == dictionary
                   and self.agreement().confirmed_identity is not None)

    def test_delayed_candidate_binding_keeps_raw_input_replies_and_drops_old_candidate_demand(self):
        binding = self.converter.gate("bind-initial-dictionary")
        self.focus()
        self.key("a")
        original_focus = self.coordinator._contexts["field"].reference.copy()
        self.coordinator.refresh_dictionary()
        self.until(lambda: self.agreement().reader.get("dictionaryRevision") is not None)
        self.assertTrue(binding.entered.wait(WAIT_SECONDS))
        self.key("", 49)
        self.key("b")
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["ab"])
        self.assertFalse(binding.proceed.is_set())
        self.assertEqual(self.panels, [])
        binding.proceed.set()
        self.bound()
        self.key("c")
        self.key("", 49)
        self.until(lambda: self.panels)
        self.assertEqual(self.coordinator._contexts["field"].reference, original_focus)
        self.assertEqual(self.agreement().reader["settingsRevision"], 0)
        self.assertEqual(self.panels[-1].batch["candidates"][0]["text"], "c")
        self.assertEqual(len(self.finished), 6)

    def test_definitive_reader_binding_rejection_keeps_input_and_allows_an_explicit_refresh(self):
        self.focus()
        self.key("a")
        self.reader.reject("bind-initial-dictionary", "dictionary_binding_busy")
        self.coordinator.refresh_dictionary()
        self.until(lambda: any(notice.operation == "bind-initial-dictionary" for notice in self.notices))
        self.assertFalse(self.coordinator._broken)
        self.assertIsNone(self.reader.dictionary)
        self.assertIsNone(self.coordinator.prepare_reconversion_worker())
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.coordinator.refresh_dictionary()
        self.bound()
        self.assertEqual(self.panels, [])
        self.assertEqual(len(self.finished), 2)

    def test_later_preparation_is_applied_after_the_first_binding_detects_a_changed_saved_source(self):
        binding = self.reader.gate("bind-initial-dictionary")
        self.coordinator.refresh_dictionary()
        self.until(lambda: not self.coordinator._dictionary.pending)
        self.assertTrue(binding.entered.wait(WAIT_SECONDS))
        self.converter.saved_dictionary = SECOND_DICTIONARY
        self.coordinator.refresh_dictionary()
        self.until(lambda: not self.coordinator._dictionary.pending)
        self.assertEqual(self.coordinator._dictionary.available[1], SECOND_DICTIONARY)
        binding.proceed.set()
        self.bound(SECOND_DICTIONARY)
        self.assertTrue(any(notice.code == "candidate_dictionary_changed" for notice in self.notices))
        self.assertEqual(self.agreement().reader["settingsRevision"], 1)
        self.assertEqual(self.inputs, [])

    def retry_same_dictionary_while_active(self, *, after_effect):
        self.focus()
        self.key("a")
        reference = deepcopy(self.coordinator._contexts["field"].reference)
        self.converter.fail("bind-initial-dictionary", after_effect=after_effect)
        self.coordinator.refresh_dictionary()
        self.until(lambda: self.agreement().failed)
        self.assertEqual(self.reader.dictionary, FIRST_DICTIONARY)
        self.coordinator.refresh_dictionary()
        self.bound()
        self.assertFalse(self.agreement().failed)
        self.key("", 49)
        self.until(lambda: self.panels)
        self.assertEqual(self.coordinator._contexts["field"].reference, reference)
        self.assertEqual(self.agreement().reader["settingsRevision"], 0)
        self.assertEqual(self.panels[-1].batch["candidates"][0]["text"], "a")
        self.key("", 36)
        self.assertEqual(self.inputs[-1].snapshot["commits"], ["a"])
        self.assertEqual(len(self.finished), 3)
        self.assertEqual(self.converter.learning_updates, [])

    def test_failed_initial_candidate_binding_recovers_in_the_same_active_field(self):
        self.retry_same_dictionary_while_active(after_effect=False)

    def test_lost_initial_candidate_ack_recovers_in_the_same_active_field_without_replaying_input(self):
        self.retry_same_dictionary_while_active(after_effect=True)


if __name__ == "__main__":
    unittest.main()
