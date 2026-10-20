"""Verify that file previews and exports never implicitly save dictionary edits."""

from dataclasses import replace
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_model import (
    DictionaryEntry, DictionaryFileOutcome, DictionaryImportPreview, DictionaryImportRow, UserDictionaryModel,
)
from test_user_dictionary_model import ENTRY_ID, OTHER_ID, original_entries


def preview_for(entries):
    original = tuple(DictionaryEntry(**entry) for entry in entries)
    addition = DictionaryEntry(id=OTHER_ID, word="追加語", reading="ついかご", hint="追加の説明")
    return DictionaryImportPreview(
        original_entries=original, entries_after_import=original + (addition,),
        rows=(DictionaryImportRow(
            source_index=1, source_line=None, entry=addition, part_of_speech=None,
            outcome="addition", problem=None, validation_issues=(),
        ),),
        notices=("properNounRegistration",),
    )


class UserDictionaryExchangeModelTests(unittest.TestCase):
    def setUp(self):
        self.source = original_entries()
        self.model = UserDictionaryModel(self.source)
        self.model.update(ENTRY_ID, word="保存前の編集")
        self.draft = self.model.entries

    def complete_preview(self):
        request = self.model.begin_file_operation("import")
        preview = preview_for(request.snapshot())
        self.assertTrue(self.model.finish_file_operation(request, DictionaryFileOutcome(preview=preview)))
        return preview

    def test_import_in_progress_blocks_edits_save_close_and_duplicate_file_operations(self):
        request = self.model.begin_file_operation("import")
        self.assertTrue(self.model.is_busy)
        self.assertFalse(self.model.can_close)
        self.assertIsNone(self.model.begin_save())
        self.assertIsNone(self.model.begin_file_operation("export"))
        for edit in (self.model.add, self.model.discard, lambda: self.model.update(ENTRY_ID, word="禁止")):
            with self.assertRaises(RuntimeError):
                edit()
        self.assertTrue(self.model.finish_file_operation(request, DictionaryFileOutcome(failure_code="importFailed")))
        self.assertFalse(self.model.finish_file_operation(request, DictionaryFileOutcome(preview=preview_for(self.draft))))
        self.assertEqual(self.model.entries, self.draft)
        self.assertTrue(self.model.can_close)

    def test_canceling_preview_preserves_the_preexisting_unsaved_draft_and_source(self):
        self.complete_preview()
        self.assertFalse(self.model.can_close)
        self.assertIsNone(self.model.begin_save())
        self.assertEqual(self.model.entries, self.draft)
        self.assertTrue(self.model.cancel_import())
        self.assertEqual(self.model.entries, self.draft)
        self.assertTrue(self.model.has_changes)
        self.assertEqual(self.source, original_entries())

    def test_applying_preview_adds_only_to_the_draft_and_full_cancel_restores_the_original(self):
        preview = self.complete_preview()
        self.assertTrue(self.model.apply_import())
        self.assertEqual(self.model.entries, [entry.as_mapping() for entry in preview.entries_after_import])
        self.assertEqual(self.model.entries[0], self.draft[0])
        self.assertEqual(self.model.entries[-1]["id"], OTHER_ID)
        self.assertTrue(self.model.has_changes)
        self.assertFalse(self.model.apply_import())
        self.model.discard()
        self.assertEqual(self.model.entries, original_entries())
        self.assertEqual(self.source, original_entries())

    def test_preview_for_another_snapshot_is_rejected_without_replacing_the_draft(self):
        request = self.model.begin_file_operation("import")
        stale = preview_for(original_entries())
        self.model.finish_file_operation(request, DictionaryFileOutcome(preview=stale))
        self.assertEqual(self.model.exchange_failure, "stalePreview")
        self.assertIsNone(self.model.import_preview)
        self.assertFalse(self.model.apply_import())
        self.assertEqual(self.model.entries, self.draft)
        self.assertTrue(self.model.can_close)

    def test_export_keeps_unsaved_state_and_is_available_for_recovery_backups(self):
        self.model.needs_recovery = True
        self.assertIsNone(self.model.begin_file_operation("import"))
        request = self.model.begin_file_operation("export")
        self.assertIsNotNone(request)
        self.model.finish_file_operation(request, DictionaryFileOutcome(exported=True))
        self.assertTrue(self.model.did_export)
        self.assertTrue(self.model.has_changes)
        self.assertTrue(self.model.needs_recovery)
        self.assertIsNone(self.model.begin_save())
        self.assertEqual(self.model.entries, self.draft)
        self.model.discard()
        self.assertEqual(self.model.entries, original_entries())

    def test_malformed_outcomes_do_not_mark_an_export_successful_or_install_a_preview(self):
        for outcome in (
            DictionaryFileOutcome(), DictionaryFileOutcome(exported="yes"),
            DictionaryFileOutcome(exported=True, failure_code=""),
            DictionaryFileOutcome(exported=True, failure_code=[]),
        ):
            with self.subTest(outcome=outcome):
                request = self.model.begin_file_operation("export")
                self.model.finish_file_operation(request, outcome)
                self.assertFalse(self.model.did_export)
                self.assertEqual(self.model.exchange_failure, "exportFailed")
                self.assertEqual(self.model.entries, self.draft)
        request = self.model.begin_file_operation("import")
        invalid = replace(preview_for(self.draft), original_entries=())
        self.model.finish_file_operation(request, DictionaryFileOutcome(preview=invalid))
        self.assertEqual(self.model.exchange_failure, "stalePreview")
        self.assertIsNone(self.model.import_preview)


if __name__ == "__main__":
    unittest.main()
