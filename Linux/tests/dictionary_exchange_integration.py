"""Run explicitly with AZOOKEY_BRIDGE; missing native prerequisites are failures."""

import json
import os
from pathlib import Path
import stat
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from azookey.bridge import Bridge
from azookey.user_dictionary_exchange_service import UserDictionaryExchangeService
from azookey.user_dictionary_model import (
    DictionaryExchangeError, DictionaryFileOutcome, UserDictionaryModel,
)


FIXTURES = Path(__file__).resolve().parents[2] / "Core/Tests/Fixtures/UserDictionaryExchange"


def original_entries():
    return [
        {"id": "a0000001-abcd-1234-abcd-123456789abc", "word": "合成語甲", "reading": "こう", "hint": None},
        {"id": "a0000002-abcd-1234-abcd-123456789abc", "word": "合成語乙", "reading": "おつ", "hint": ""},
        {"id": "a0000003-abcd-1234-abcd-123456789abc", "word": "Cafe\u0301", "reading": "カフェ",
         "hint": "タブ\t改行\n合成ヒント"},
        {"id": "a0000004-abcd-1234-abcd-123456789abc", "word": "合成語丙", "reading": "へい",
         "hint": "制御文字も保持\x00する"},
    ]


def fields(entries):
    return [(entry["word"], entry["reading"], entry.get("hint")) for entry in entries]


class DictionaryExchangeIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        executable = os.environ.get("AZOOKEY_BRIDGE")
        if not executable or not Path(executable).is_file():
            raise RuntimeError("AZOOKEY_BRIDGE must point to the built native bridge")
        if not FIXTURES.is_dir():
            raise RuntimeError("Core exchange fixtures must be available")
        cls.executable = executable

    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="azookey-exchange-integration-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.config = self.directory / "config"
        self.dictionary_data = self.directory / "dictionary-data"
        environment = {
            **os.environ,
            "XDG_CONFIG_HOME": str(self.config),
            "XDG_DATA_HOME": str(self.directory / "data-home"),
            "AZOOKEY_DATA_DIR": str(self.dictionary_data),
        }
        self.service = UserDictionaryExchangeService(
            bridge_factory=lambda: Bridge(executable=self.executable, environment=environment),
        )

    def preview(self, path, *, entries=(), format_name="json", encoding="automatic"):
        return self.service.preview(path, format_name=format_name, encoding=encoding, entries=list(entries))

    def assert_counts(self, preview, expected):
        self.assertEqual(
            tuple(preview.count(outcome) for outcome in ("addition", "duplicate", "conflict", "excluded")),
            expected,
        )
        self.assertEqual(preview.notices, ("properNounRegistration",))

    def assert_no_settings_created(self):
        self.assertFalse(self.config.exists())
        self.assertFalse(self.dictionary_data.exists())
        self.assertFalse((self.directory / "data-home").exists())

    def test_json_roundtrip_preserves_unicode_optional_hints_and_original_id_spelling(self):
        entries = original_entries()
        destination = self.directory / "draft.json"
        self.service.export(entries, destination=destination)
        exported = json.loads(destination.read_text(encoding="utf-8"))
        self.assertEqual(fields(exported["items"]), fields(entries))
        self.assertTrue(all("id" not in entry for entry in exported["items"]))
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        before = destination.read_bytes()
        existing = [{"id": "b0000001-abcd-1234-abcd-123456789abc",
                     "word": "既存語", "reading": "きぞん", "hint": None}]
        preview = self.preview(destination, entries=existing)
        self.assert_counts(preview, (4, 0, 0, 0))
        imported = [entry.as_mapping() for entry in preview.entries_after_import]
        self.assertEqual(imported[0], existing[0])
        self.assertEqual(fields(imported[1:]), fields(entries))
        self.assertEqual(len({entry["id"] for entry in imported}), 5)
        self.assertEqual(destination.read_bytes(), before)
        self.assert_no_settings_created()

    def test_real_preview_cancel_apply_and_export_never_persist_the_draft(self):
        original = original_entries()[:1]
        settings = self.config / "azookey-tree/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text(json.dumps({"userDictionary": original}), encoding="utf-8")
        before = settings.read_bytes(), settings.stat().st_ino, settings.stat().st_mtime_ns
        source = self.directory / "import.json"
        self.service.export(original_entries()[1:], destination=source)
        model = UserDictionaryModel(original)
        model.update(original[0]["id"], word="未保存の編集")
        draft = model.entries
        request = model.begin_file_operation("import")
        preview = self.preview(source, entries=request.snapshot())
        model.finish_file_operation(request, DictionaryFileOutcome(preview=preview))
        self.assertTrue(model.cancel_import())
        self.assertEqual(model.entries, draft)
        request = model.begin_file_operation("import")
        model.finish_file_operation(request, DictionaryFileOutcome(preview=preview))
        self.assertTrue(model.apply_import())
        self.assertEqual(model.entries[0], draft[0])
        self.assertEqual(len(model.entries), 4)
        self.assertTrue(model.has_changes)
        self.service.export(model.entries, destination=self.directory / "backup.json")
        self.assertTrue(model.has_changes)
        self.assertEqual(before, (settings.read_bytes(), settings.stat().st_ino, settings.stat().st_mtime_ns))
        self.assertFalse(self.dictionary_data.exists())
        model.discard()
        self.assertEqual(model.entries, original)

    def test_text_fixtures_keep_counts_hints_and_exclusion_reasons_across_encodings(self):
        cases = (
            ("mozc.txt", "mozc", "automatic", (2, 1, 1, 3)),
            ("mozc-utf16le.txt", "mozc", "automatic", (2, 1, 1, 3)),
            ("mozc-utf16be.txt", "mozc", "utf16", (2, 1, 1, 3)),
            ("atok2017.txt", "atok2017", "utf8", (2, 0, 0, 2)),
            ("atok2017-shift-jis.txt", "atok2017", "shiftJIS", (2, 0, 0, 2)),
        )
        for filename, format_name, encoding, counts in cases:
            with self.subTest(filename=filename):
                preview = self.preview(FIXTURES / filename, format_name=format_name, encoding=encoding)
                self.assert_counts(preview, counts)
                self.assertEqual([entry.word for entry in preview.entries_after_import], ["合成語甲", "合成語乙"])
                self.assertEqual(preview.entries_after_import[0].hint, "合成コメント")
                self.assertEqual(preview.entries_after_import[1].hint, None if format_name == "mozc" else "")
                self.assertTrue(all(row.problem or row.validation_issues for row in preview.rows if row.outcome == "excluded"))
        self.assert_no_settings_created()

    def test_duplicates_and_conflicts_keep_existing_values_and_ids(self):
        existing = [{"id": "c0000001-abcd-1234-abcd-123456789abc", "word": "合成語甲",
                     "reading": "ごうせいこう", "hint": "合成コメント"}]
        preview = self.preview(FIXTURES / "mozc.txt", entries=existing, format_name="mozc")
        self.assert_counts(preview, (1, 2, 1, 3))
        self.assertEqual(preview.entries_after_import[0].as_mapping(), existing[0])
        self.assertEqual(preview.entries_after_import[1].word, "合成語乙")
        self.assertEqual(len(preview.entries_after_import), 2)
        self.assert_no_settings_created()

    def test_file_and_encoding_failures_expose_only_public_codes_without_settings_changes(self):
        source = self.directory / "PRIVATE_SOURCE.json"
        source.write_text('{"format":"azookey-user-dictionary","version":99,"items":[]}', encoding="utf-8")
        cases = (
            (source, "json", "automatic", "unsupportedVersion"),
            (source.with_suffix(".missing"), "json", "automatic", "importFailed"),
            (FIXTURES / "atok2017-shift-jis.txt", "atok2017", "automatic", "unknownEncoding"),
            (FIXTURES / "atok2017-shift-jis.txt", "atok2017", "utf8", "invalidEncoding"),
        )
        for path, format_name, encoding, code in cases:
            with self.subTest(code=code):
                with self.assertRaises(DictionaryExchangeError) as caught:
                    self.preview(path, format_name=format_name, encoding=encoding)
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(str(caught.exception), code)
                self.assertNotIn("PRIVATE_SOURCE", str(caught.exception))
        self.assert_no_settings_created()


if __name__ == "__main__":
    unittest.main()
