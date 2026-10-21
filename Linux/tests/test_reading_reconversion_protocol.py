"""Replacement messages cannot carry commits or change document authority."""
from copy import deepcopy
import unittest

from azookey import reading_protocol, reconversion_protocol
from azookey.reconversion import surrounding_context
from candidate_fixture import candidate_request
from test_reading_frontend import reading_snapshot


class ReadingReconversionProtocolTests(unittest.TestCase):
    def setUp(self):
        self.authority = candidate_request()["authority"]
        self.reference = {name: self.authority[name] for name in reading_protocol.REFERENCE_FIELDS}
        self.request = {"authority": self.authority, "workerGeneration": "candidate",
                        "text": "日本語", "privateInput": False}
        self.document = surrounding_context("前日本語後", 4, 1, can_replace=True, sensitive=False)
        self.header = {"kind": "acknowledgement", "readingProcessGeneration": self.reference["readingProcessGeneration"],
                       "settingsRevision": 0, "reference": self.reference}
        self.payload = {"reference": self.reference, "reconversionContext": self.document}

    def response(self, operation, **fields):
        return reading_protocol.response({**self.header, **fields}, operation, self.payload)

    def test_reading_resolution_and_local_entry_return_no_formal_input(self):
        for fields in ({"reconversionReadingRequest": self.request},
                       {"reconversionReading": "", "reconversionError": "reading_required"},
                       {"reconversionReading": "にほんご"}, {}):
            with self.subTest(fields=tuple(fields)):
                self.assertEqual(self.response("reconvert", **fields), self.header | fields)
                with self.assertRaises(ValueError):
                    self.response("reconvert", snapshot=reading_snapshot(), **fields)

    def test_resolution_response_keeps_every_request_field_and_exact_unicode_bytes(self):
        resolved = {"request": self.request, "reading": "にほんご"}
        self.assertEqual(reconversion_protocol.reading_result(resolved, request=self.request), resolved)
        for field, value in (("text", "別"), ("workerGeneration", "other"), ("privateInput", True)):
            changed = deepcopy(resolved)
            changed["request"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                reconversion_protocol.reading_result(changed, request=self.request)
        composed = {**self.request, "text": "が"}
        decomposed = {**self.request, "text": "か\u3099"}
        with self.assertRaises(ValueError):
            reconversion_protocol.reading_result({"request": decomposed, "reading": "が"}, request=composed)

    def test_private_or_malformed_selection_never_leaves_as_a_dictionary_request(self):
        for field, value in (("privateInput", True), ("privateInput", 0), ("text", ""), ("text", "\ud800"),
                             ("text", "字" * 257), ("workerGeneration", "")):
            with self.subTest(field=field, value=repr(value)), self.assertRaises(ValueError):
                reconversion_protocol.reading_request({**self.request, field: value})

    def test_reading_resolution_rejects_each_changed_authority_field(self):
        for field, value in (("context", "other"), ("focusEpoch", 2), ("compositionRevision", 2),
                             ("settingsRevision", 2), ("requestID", "other"), ("readingProcessGeneration", "other")):
            changed = deepcopy(self.request)
            changed["authority"][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                reconversion_protocol.reading_result({"request": changed}, request=self.request)

    def test_candidate_reply_contains_only_the_same_request_and_optional_reading(self):
        response = {"workerGeneration": "candidate", "settingsRevision": 0, "authority": self.authority,
                    "learning": "nothing", "customInputTableRevisions": {},
                    "reconversionReadingResult": {"request": self.request}}
        self.assertEqual(reconversion_protocol.candidate_reading(response, request=self.request),
                         {"request": self.request})
        for field, value in (("workerGeneration", "other"), ("settingsRevision", 1),
                             ("learning", "unknown"), ("customInputTableRevisions", {"table": 3}),
                             ("preedit", "にほんご"), ("batch", {}), ("completion", {})):
            with self.subTest(field=field), self.assertRaises(ValueError):
                reconversion_protocol.candidate_reading({**response, field: value}, request=self.request)

    def test_deletion_counts_are_scalars_and_never_booleans(self):
        replacement = {"token": "single-use", "offset": -2, "count": 2, "text": "😀字", "reading": "えもじ"}
        self.assertEqual(self.response("undo-commit", reconversion=replacement)["reconversion"], replacement)
        for field, value in (("count", 3), ("count", True), ("offset", False), ("text", "\ud800")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.response("undo-commit", reconversion={**replacement, field: value})

    def test_confirmation_cannot_commit_or_learn_even_with_a_valid_snapshot(self):
        self.assertEqual(self.response("confirm-reconversion", kind="input", snapshot=reading_snapshot())["kind"], "input")
        for field, value in (("commits", ["日本語"]), ("candidateCompletions", [{}])):
            with self.subTest(field=field), self.assertRaises(ValueError):
                self.response("confirm-reconversion", kind="input", snapshot={**reading_snapshot(), field: value})

    def test_confirmation_failure_returns_the_existing_formal_snapshot(self):
        snapshot = reading_snapshot("")
        self.assertEqual(self.response("confirm-reconversion", kind="input", snapshot=snapshot,
                                       reconversionError="changed_context")["snapshot"], snapshot)

    def test_unrelated_input_operations_cannot_introduce_reconversion_actions(self):
        with self.assertRaises(ValueError):
            self.response("key", kind="input", snapshot=reading_snapshot(), reconversionReadingRequest=self.request)
        with self.assertRaises(ValueError):
            self.response("reconvert", reconversionReadingRequest=self.request, reconversionReading="にほんご")

    def test_document_positions_preserve_utf16_while_context_preserves_scalar_text(self):
        document = surrounding_context("😀か\u3099後", 3, 1, can_replace=True, sensitive=False)
        self.assertEqual(reconversion_protocol.document_context(document), document)
        self.assertEqual((document["cursorUTF16"], document["anchorUTF16"], document["selected"]), (4, 2, "か\u3099"))
        for field, value in (("cursorUTF16", True), ("anchorUTF16", -1), ("canReplace", 1), ("before", "\ud800")):
            with self.subTest(field=field), self.assertRaises(ValueError):
                reconversion_protocol.document_context({**document, field: value})


if __name__ == "__main__":
    unittest.main()
