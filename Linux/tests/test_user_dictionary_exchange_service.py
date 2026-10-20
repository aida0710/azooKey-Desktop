"""Verify the exchange protocol and file publication using synthetic dictionaries."""

import copy
import json
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_exchange_service import UserDictionaryExchangeService
from azookey.user_dictionary_model import DictionaryExchangeError
from test_user_dictionary_model import ENTRY_ID, OTHER_ID, original_entries


def preview_response(entries=None):
    existing = copy.deepcopy(original_entries() if entries is None else entries)
    canonical = [{**entry, "id": entry["id"].upper()} for entry in existing]
    added = {"id": OTHER_ID, "word": "追加語", "reading": "ついかご", "hint": "1行目\n2行目\t補足"}
    rows = [
        {
            "source": {"sourceIndex": 1, "sourceLine": 2, "item": added, "partOfSpeech": "名詞"},
            "outcome": "addition", "validationIssues": [],
        },
        {
            "source": {"sourceIndex": 2, "sourceLine": 3, "item": existing[0]},
            "outcome": "duplicate", "problem": "duplicate", "validationIssues": [], "existingID": ENTRY_ID,
        },
        {
            "source": {"sourceIndex": 3, "sourceLine": 4, "item": {**existing[0], "hint": "異なるヒント"}},
            "outcome": "conflict", "problem": "conflict", "validationIssues": [], "existingID": ENTRY_ID,
        },
        {
            "source": {"sourceIndex": 4, "sourceLine": 5, "item": {
                "id": "42345678-ABCD-1234-ABCD-123456789ABC", "word": "食べる", "reading": "たべる", "hint": None,
            }, "partOfSpeech": "動詞"},
            "outcome": "excluded", "problem": "unsupportedPartOfSpeech", "validationIssues": [],
        },
        {
            "source": {"sourceIndex": 5, "sourceLine": 6},
            "outcome": "excluded", "problem": "invalidColumns", "validationIssues": [],
        },
    ]
    return {
        "dictionaryImportPreview": {
            "rows": rows, "counts": {"additions": 1, "duplicates": 1, "conflicts": 1, "excluded": 2},
            "notices": ["properNounRegistration"],
        },
        "dictionaryImportItems": canonical + [copy.deepcopy(added)],
    }


def export_response(entries):
    return {"dictionaryExportJSON": json.dumps({
        "format": "azookey-user-dictionary", "version": 1,
        "items": [{key: value for key, value in entry.items() if key != "id"} for entry in entries],
    }, ensure_ascii=False)}


class SyntheticExchangeBridge:
    def __init__(self, response):
        self.response = response
        self.calls = []
        self.closed = 0

    def request(self, operation, **payload):
        self.calls.append((operation, copy.deepcopy(payload)))
        if isinstance(self.response, Exception):
            raise self.response
        return copy.deepcopy(self.response)

    def close(self):
        self.closed += 1


class UserDictionaryExchangeServiceTests(unittest.TestCase):
    def setUp(self):
        self.bridge = SyntheticExchangeBridge(preview_response())
        self.service = UserDictionaryExchangeService(bridge_factory=lambda: self.bridge)
        directory = tempfile.TemporaryDirectory(prefix="azookey-dictionary-exchange-")
        self.addCleanup(directory.cleanup)
        self.directory = pathlib.Path(directory.name)

    def preview(self, entries=None, **options):
        options.setdefault("format_name", "json")
        options.setdefault("encoding", "automatic")
        return self.service.preview(
            self.directory / "synthetic-import.json",
            entries=original_entries() if entries is None else entries, **options,
        )

    def test_preview_keeps_ids_and_core_outcomes_without_writing_or_reparsing_the_file(self):
        entries = original_entries()
        entries[0]["id"] = entries[0]["id"].lower()
        self.bridge.response = preview_response(entries)
        preview = self.preview(entries)
        self.assertEqual(preview.original_entries[0].as_mapping(), entries[0])
        self.assertEqual(preview.entries_after_import[0].as_mapping(), entries[0])
        self.assertEqual([preview.count(outcome) for outcome in ("addition", "duplicate", "conflict", "excluded")], [1, 1, 1, 2])
        self.assertEqual(preview.entries_after_import[-1].hint, "1行目\n2行目\t補足")
        operation, payload = self.bridge.calls[0]
        self.assertEqual(operation, "dictionary-import-preview")
        self.assertEqual(set(payload), {"importPath", "importFormat", "importEncoding", "items"})
        self.assertEqual(payload["items"], entries)
        self.assertEqual(list(self.directory.iterdir()), [])
        self.assertEqual(self.bridge.closed, 1)
        entries[0]["word"] = "呼出側の別編集"
        self.bridge.response["dictionaryImportItems"][-1]["word"] = "応答の別編集"
        self.assertEqual(preview.original_entries[0].word, "試験語")
        self.assertEqual(preview.entries_after_import[-1].word, "追加語")

    def test_format_and_encoding_are_explicit_core_choices(self):
        for format_name in ("json", "atok2017", "mozc"):
            for encoding in ("automatic", "utf8", "utf16", "shiftJIS"):
                with self.subTest(format_name=format_name, encoding=encoding):
                    self.preview(format_name=format_name, encoding=encoding)
                    payload = self.bridge.calls[-1][1]
                    self.assertEqual(payload["importFormat"], format_name)
                    self.assertEqual(payload["importEncoding"], encoding)
        calls = len(self.bridge.calls)
        with self.assertRaises(DictionaryExchangeError):
            self.preview(encoding="guessShiftJIS")
        self.assertEqual(len(self.bridge.calls), calls)

    def test_core_errors_are_public_codes_and_raw_exception_contents_are_not_exposed(self):
        for failure in (
            {"dictionaryExchangeError": "unknownEncoding"},
            {"dictionaryExchangeError": "unsupportedBinary"},
            {"error": "PRIVATE_TEST_SENTINEL"},
            OSError("PRIVATE_TEST_SENTINEL"),
            {"dictionaryExchangeError": "PRIVATE_TEST_SENTINEL"},
        ):
            with self.subTest(failure=type(failure).__name__):
                self.bridge.response = failure
                with self.assertRaises(DictionaryExchangeError) as raised:
                    self.preview()
                self.assertNotIn("PRIVATE_TEST_SENTINEL", str(raised.exception))
        self.assertEqual(self.bridge.closed, 5)

    def test_inconsistent_preview_counts_and_modified_proposals_are_rejected(self):
        malformed = []
        response = preview_response()
        response["dictionaryImportPreview"]["counts"]["additions"] = True
        malformed.append(response)
        response = preview_response()
        response["dictionaryImportPreview"]["counts"]["conflicts"] = 0
        malformed.append(response)
        response = preview_response()
        response["dictionaryImportItems"][0]["word"] = "勝手な上書き"
        malformed.append(response)
        response = preview_response()
        response["dictionaryImportItems"].append(copy.deepcopy(response["dictionaryImportItems"][-1]))
        malformed.append(response)
        response = preview_response()
        response["dictionaryImportPreview"]["rows"][0]["outcome"] = "overwrite"
        malformed.append(response)
        response = preview_response()
        response["dictionaryImportPreview"]["rows"][0]["source"]["sourceLine"] = False
        malformed.append(response)
        for response in malformed + [{}, [], None]:
            with self.subTest(response_type=type(response).__name__):
                self.bridge.response = response
                with self.assertRaises(DictionaryExchangeError) as raised:
                    self.preview()
                self.assertEqual(raised.exception.code, "importFailed")

    def test_export_atomically_replaces_only_the_selected_file_and_keeps_multiline_hints(self):
        entries = original_entries()
        entries[0]["hint"] = "1行目\n2行目\t補足"
        self.bridge.response = export_response(entries)
        destination = self.directory / "chosen.json"
        other = self.directory / "untouched.json"
        destination.write_text("previous backup")
        other.write_text("untouched")
        previous_inode = destination.stat().st_ino
        self.service.export(entries, destination=destination)
        written = json.loads(destination.read_text(encoding="utf-8"))
        self.assertEqual(written["items"][0]["hint"], entries[0]["hint"])
        self.assertNotIn("id", written["items"][0])
        self.assertNotEqual(destination.stat().st_ino, previous_inode)
        self.assertEqual(stat.S_IMODE(destination.stat().st_mode), 0o600)
        self.assertEqual(other.read_text(), "untouched")
        self.assertEqual(list(self.directory.glob(".azookey-dictionary-*")), [])
        self.assertEqual(self.bridge.calls, [("dictionary-export", {"items": entries})])
        self.assertEqual(self.bridge.closed, 1)

    def test_fsync_and_replace_failures_leave_the_previous_export_and_clean_staged_files(self):
        self.bridge.response = export_response(original_entries())
        destination = self.directory / "chosen.json"
        destination.write_bytes(b"previous backup")
        for operation in ("os.fsync", "os.replace"):
            with self.subTest(operation=operation):
                with patch(
                    "azookey.user_dictionary_exchange_service." + operation,
                    side_effect=OSError("PRIVATE_TEST_SENTINEL"),
                ):
                    with self.assertRaises(DictionaryExchangeError) as raised:
                        self.service.export(original_entries(), destination=destination)
                self.assertEqual(raised.exception.code, "exportFailed")
                self.assertEqual(destination.read_bytes(), b"previous backup")
                self.assertEqual(list(self.directory.glob(".azookey-dictionary-*")), [])

    def test_invalid_or_rewritten_export_responses_never_create_the_target(self):
        changed = original_entries()
        changed[0]["word"] = "勝手な変更"
        destination = self.directory / "chosen.json"
        for response in ({}, {"dictionaryExportJSON": ""}, {"dictionaryExportJSON": False}, export_response(changed)):
            with self.subTest(response_type=type(response).__name__):
                self.bridge.response = response
                with self.assertRaises(DictionaryExchangeError) as raised:
                    self.service.export(original_entries(), destination=destination)
                self.assertEqual(raised.exception.code, "exportFailed")
                self.assertFalse(destination.exists())
                self.assertEqual(list(self.directory.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
