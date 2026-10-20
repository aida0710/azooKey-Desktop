"""Exercise draft ownership and the save callback boundary without GTK or Swift."""

import copy
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_model import (
    DictionarySaveError, DictionaryValidationIssue, UserDictionaryModel,
    matches_dictionary_query, save_dictionary,
)


ENTRY_ID = "12345678-ABCD-1234-ABCD-123456789ABC"
OTHER_ID = "22345678-ABCD-1234-ABCD-123456789ABC"


def original_entries():
    return [{"id": ENTRY_ID, "word": "試験語", "reading": "しけんご", "hint": "固定の試験用"}]


class UserDictionaryModelTests(unittest.TestCase):
    def setUp(self):
        self.source = original_entries()
        self.model = UserDictionaryModel(self.source)
        self.saved = []

    def save_draft(self, *, validate=lambda _entries: (), save=None):
        request = self.model.begin_save()
        outcome = save_dictionary(
            request, validate=validate, save=self.saved.append if save is None else save,
        )
        self.assertTrue(self.model.finish_save(request, outcome))
        return outcome

    def test_caller_and_returned_mappings_cannot_rewrite_the_draft(self):
        self.source[0]["word"] = "別の値"
        exposed = self.model.entries
        exposed[0]["reading"] = "べつ"
        self.assertEqual(self.model.entries, original_entries())
        self.assertFalse(self.model.has_changes)

    def test_cancel_discards_empty_additions_and_keeps_existing_ids(self):
        added = self.model.add()
        self.assertNotEqual(added, ENTRY_ID)
        self.assertEqual(self.model.entry(added)["word"], "")
        self.assertEqual(self.source, original_entries())
        self.model.discard()
        self.assertEqual(self.model.entries, original_entries())
        self.assertFalse(self.model.has_changes)

    def test_cancel_restores_edited_and_deleted_entries(self):
        self.model.update(ENTRY_ID, word="変更後", reading="へんこうご", hint="下書き")
        self.model.remove(ENTRY_ID)
        self.model.discard()
        self.assertEqual(self.model.entries, original_entries())
        self.assertEqual(self.source, original_entries())

    def test_core_validation_reasons_stop_save_without_losing_edits(self):
        self.model.update(ENTRY_ID, reading="invalid")
        issues = [
            DictionaryValidationIssue(ENTRY_ID.lower(), "reading", "unsupportedCharacter", "invalid"),
            DictionaryValidationIssue(ENTRY_ID, "word", "empty"),
        ]
        outcome = self.save_draft(validate=lambda _entries: issues)
        self.assertFalse(outcome.saved)
        self.assertEqual(self.model.issues_for(ENTRY_ID), tuple(issues))
        self.assertEqual(self.saved, [])
        self.assertEqual(self.model.entry(ENTRY_ID)["reading"], "invalid")
        self.assertTrue(self.model.has_changes)

    def test_model_does_not_duplicate_core_reading_rules(self):
        self.model.update(ENTRY_ID, reading="Coreが許可した読み")
        self.assertTrue(self.save_draft().saved)
        self.assertEqual(self.saved[0][0]["reading"], "Coreが許可した読み")

    def test_callback_copies_cannot_change_the_saved_snapshot(self):
        def validate(entries):
            entries[0]["word"] = "検証側が変更した値"
            return []

        def save(entries):
            self.saved.append(copy.deepcopy(entries))
            entries[0]["reading"] = "保存側が変更した値"

        self.model.update(ENTRY_ID, word="新しい語")
        outcome = self.save_draft(validate=validate, save=save)
        self.assertTrue(outcome.saved)
        self.assertEqual(self.saved[0][0]["word"], "新しい語")
        self.assertEqual(self.model.entry(ENTRY_ID)["reading"], "しけんご")
        self.assertFalse(self.model.has_changes)
        self.model.update(ENTRY_ID, word="さらに編集")
        self.model.discard()
        self.assertEqual(self.model.entry(ENTRY_ID)["word"], "新しい語")
        self.assertEqual(self.source, original_entries())

    def test_each_save_failure_keeps_the_draft_and_allows_retry(self):
        for stage in ("compile", "persistence", "activation"):
            with self.subTest(stage=stage):
                self.model = UserDictionaryModel(original_entries())
                self.model.update(ENTRY_ID, word="未保存の語")

                def fail(_entries):
                    raise DictionarySaveError(stage)

                self.assertEqual(self.save_draft(save=fail).failure_stage, stage)
                self.assertEqual(self.model.entry(ENTRY_ID)["word"], "未保存の語")
                self.assertTrue(self.model.has_changes)
                self.assertFalse(self.model.is_saving)
                self.assertTrue(self.save_draft().saved)
                self.assertFalse(self.model.has_changes)

    def test_unstructured_errors_do_not_expose_their_message(self):
        def fail(_entries):
            raise OSError("PRIVATE_TEST_SENTINEL")

        outcome = self.save_draft(save=fail)
        self.assertEqual(outcome.failure_stage, "unknown")
        self.assertNotIn("PRIVATE_TEST_SENTINEL", repr(outcome))

    def test_invalid_callback_results_cannot_report_success(self):
        for invalid in (None, {}, [False]):
            with self.subTest(invalid=invalid):
                outcome = self.save_draft(validate=lambda _entries: invalid)
                self.assertEqual(outcome.failure_stage, "validation")
                self.assertEqual(self.saved, [])
        for invalid in (False, {"error": "compile"}):
            with self.subTest(invalid=invalid):
                outcome = self.save_draft(save=lambda _entries: invalid)
                self.assertFalse(outcome.saved)
                self.assertEqual(outcome.failure_stage, "unknown")

    def test_in_progress_save_blocks_edits_cancel_and_duplicate_requests(self):
        request = self.model.begin_save()
        self.assertIsNone(self.model.begin_save())
        for action in (
            self.model.add, lambda: self.model.update(ENTRY_ID, word="変更"),
            lambda: self.model.remove(ENTRY_ID), self.model.discard,
        ):
            with self.subTest(action=action):
                with self.assertRaises(RuntimeError):
                    action()
        outcome = save_dictionary(request, validate=lambda _entries: (), save=self.saved.append)
        self.assertTrue(self.model.finish_save(request, outcome))
        self.assertFalse(self.model.finish_save(request, outcome))
        next_request = self.model.begin_save()
        self.assertFalse(self.model.finish_save(request, outcome))
        self.assertTrue(self.model.is_saving)
        next_outcome = save_dictionary(next_request, validate=lambda _entries: (), save=self.saved.append)
        self.assertTrue(self.model.finish_save(next_request, next_outcome))

    def test_deleting_one_entry_preserves_other_ids_and_multiline_hints(self):
        entries = original_entries() + [
            {"id": OTHER_ID, "word": "別語", "reading": "べつご", "hint": "1行目\n2行目\t補足"},
        ]
        self.model = UserDictionaryModel(entries)
        self.model.remove(ENTRY_ID)
        self.assertTrue(self.save_draft().saved)
        self.assertEqual(self.saved[0], entries[1:])

    def test_search_matches_word_reading_and_multiline_hint_without_changing_text(self):
        self.model.update(ENTRY_ID, word="AzooKey試験", reading="しけん", hint="1行目\n共通TAG\t補足")
        entry = self.model.entry(ENTRY_ID)
        for query in ("", "azookey", "試験", "しけん", "共通tag", "\t補足"):
            with self.subTest(query=query):
                self.assertTrue(matches_dictionary_query(entry, query))
        self.assertFalse(matches_dictionary_query(entry, "存在しない語"))
        self.assertEqual(self.model.entry(ENTRY_ID), entry)
        self.assertEqual(self.source, original_entries())

    def test_search_allows_missing_hints_and_does_not_normalize_readings_for_validation(self):
        entry = {"word": "試験", "reading": "シケン", "hint": None}
        self.assertTrue(matches_dictionary_query(entry, "シケン"))
        self.assertFalse(matches_dictionary_query(entry, "しけん"))
        self.assertFalse(matches_dictionary_query(entry, "None"))


if __name__ == "__main__":
    unittest.main()
