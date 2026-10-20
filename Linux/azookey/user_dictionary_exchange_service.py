"""Read Core exchange previews and atomically export its lossless JSON format."""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import tempfile
import uuid

from .bridge import Bridge
from .user_dictionary_model import (
    DictionaryEntry, DictionaryExchangeError, DictionaryImportPreview,
    DictionaryImportRow, DictionaryValidationIssue,
)


IMPORT_FORMATS = ("json", "atok2017", "mozc")
IMPORT_ENCODINGS = ("automatic", "utf8", "utf16", "shiftJIS")
EXCHANGE_FAILURES = frozenset({
    "unknownEncoding", "invalidEncoding", "unsupportedBinary", "unsupportedFormat",
    "unsupportedVersion", "invalidDocument", "stalePreview", "missingResources",
    "importFailed", "exportFailed",
})
IMPORT_PROBLEMS = frozenset({
    "invalidColumns", "unsupportedFields", "unsupportedPartOfSpeech", "invalidEntry", "duplicate", "conflict",
})
IMPORT_OUTCOMES = ("addition", "duplicate", "conflict", "excluded")
COUNT_FIELDS = ("additions", "duplicates", "conflicts", "excluded")


def _string(value, *, optional=False):
    if value is None and optional:
        return None
    if type(value) is not str:
        raise ValueError("invalid_exchange_string")
    value.encode("utf-8")
    return value


def _entry(document):
    if type(document) is not dict or not {"id", "word", "reading"} <= document.keys():
        raise ValueError("invalid_exchange_entry")
    if not document.keys() <= {"id", "word", "reading", "hint"}:
        raise ValueError("unknown_exchange_entry_field")
    entry_id = _string(document["id"])
    uuid.UUID(entry_id)
    return DictionaryEntry(
        id=entry_id, word=_string(document["word"]), reading=_string(document["reading"]),
        hint=_string(document.get("hint"), optional=True),
    )


def _entries(documents):
    if type(documents) is not list:
        raise ValueError("invalid_exchange_entries")
    entries = tuple(_entry(document) for document in documents)
    if len({uuid.UUID(entry.id) for entry in entries}) != len(entries):
        raise ValueError("duplicate_exchange_entry_id")
    return entries


def _same_entry(left, right):
    return (
        uuid.UUID(left.id) == uuid.UUID(right.id)
        and (left.word, left.reading, left.hint) == (right.word, right.reading, right.hint)
    )


def _validation_issue(document):
    if type(document) is not dict:
        raise ValueError("invalid_exchange_validation_issue")
    entry_id = _string(document.get("rowID"))
    uuid.UUID(entry_id)
    field = document.get("field")
    reason = document.get("reason")
    if field not in ("word", "reading") or reason not in ("empty", "controlCharacter", "unsupportedCharacter"):
        raise ValueError("invalid_exchange_validation_reason")
    return DictionaryValidationIssue(
        entry_id=entry_id, field=field, code=reason, characters=_string(document.get("characters")),
    )


def _source_position(value, *, optional=False):
    if value is None and optional:
        return None
    if type(value) is not int or value < 1:
        raise ValueError("invalid_exchange_source_position")
    return value


def _import_row(document):
    if type(document) is not dict or type(document.get("source")) is not dict:
        raise ValueError("invalid_exchange_preview_row")
    source = document["source"]
    outcome = document.get("outcome")
    problem = document.get("problem")
    if outcome not in IMPORT_OUTCOMES or problem is not None and problem not in IMPORT_PROBLEMS:
        raise ValueError("invalid_exchange_preview_outcome")
    if type(document.get("validationIssues")) is not list:
        raise ValueError("invalid_exchange_validation_issues")
    issues = tuple(_validation_issue(issue) for issue in document["validationIssues"])
    item = _entry(source["item"]) if source.get("item") is not None else None
    if outcome == "addition" and (item is None or problem is not None or issues):
        raise ValueError("invalid_exchange_addition")
    if outcome in ("duplicate", "conflict") and problem != outcome:
        raise ValueError("invalid_exchange_conflict")
    if outcome == "excluded" and problem is None and not issues:
        raise ValueError("missing_exchange_exclusion_reason")
    if document.get("existingID") is not None:
        uuid.UUID(_string(document["existingID"]))
    return DictionaryImportRow(
        source_index=_source_position(source.get("sourceIndex")),
        source_line=_source_position(source.get("sourceLine"), optional=True),
        entry=item, part_of_speech=_string(source.get("partOfSpeech"), optional=True),
        outcome=outcome, problem=problem, validation_issues=issues,
    )


def _import_preview(response, original):
    document = response.get("dictionaryImportPreview")
    if type(document) is not dict or type(document.get("rows")) is not list:
        raise ValueError("missing_exchange_preview")
    rows = tuple(_import_row(row) for row in document["rows"])
    if len({row.source_index for row in rows}) != len(rows):
        raise ValueError("duplicate_exchange_source_index")
    counts = document.get("counts")
    if type(counts) is not dict or set(counts) != set(COUNT_FIELDS):
        raise ValueError("invalid_exchange_counts")
    for outcome, field in zip(IMPORT_OUTCOMES, COUNT_FIELDS):
        if type(counts[field]) is not int or counts[field] != sum(row.outcome == outcome for row in rows):
            raise ValueError("inconsistent_exchange_counts")
    notices = document.get("notices")
    if type(notices) is not list or any(notice != "properNounRegistration" for notice in notices):
        raise ValueError("invalid_exchange_notice")
    proposed = _entries(response.get("dictionaryImportItems"))
    additions = tuple(row.entry for row in rows if row.outcome == "addition")
    expected = original + additions
    if len(proposed) != len(expected) or not all(
        _same_entry(actual, wanted) for actual, wanted in zip(proposed, expected)
    ):
        raise ValueError("inconsistent_exchange_items")
    # Core encodes UUIDs canonically. Preserve the caller's original ID spelling
    # while verifying the exact word, reading and optional hint of every entry.
    return DictionaryImportPreview(
        original_entries=original, entries_after_import=original + proposed[len(original):],
        rows=rows, notices=tuple(notices),
    )


def _export_content(response, entries):
    content = _string(response.get("dictionaryExportJSON"))
    document = json.loads(content)
    if type(document) is not dict or set(document) != {"format", "version", "items"}:
        raise ValueError("invalid_exchange_export")
    if document["format"] != "azookey-user-dictionary" or type(document["version"]) is not int or document["version"] != 1:
        raise ValueError("unsupported_exchange_export")
    items = document["items"]
    if type(items) is not list or len(items) != len(entries):
        raise ValueError("inconsistent_exchange_export")
    for item, entry in zip(items, entries):
        if type(item) is not dict or not {"word", "reading"} <= item.keys() <= {"word", "reading", "hint"}:
            raise ValueError("invalid_exchange_export_item")
        if (item["word"], item["reading"], item.get("hint")) != (entry.word, entry.reading, entry.hint):
            raise ValueError("changed_exchange_export_item")
    return content.encode("utf-8")


def _write_atomic(destination, content):
    path = Path(destination)
    descriptor, temporary = tempfile.mkstemp(prefix=".azookey-dictionary-", dir=path.parent)
    staged = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(staged, path)
    finally:
        staged.unlink(missing_ok=True)


class UserDictionaryExchangeService:
    """Use private, short-lived bridges; never open the application's settings."""

    def __init__(self, *, bridge_factory=Bridge):
        self._bridge_factory = bridge_factory

    @contextmanager
    def _connection(self):
        connection = self._bridge_factory()
        try:
            yield connection
        finally:
            try:
                connection.close()
            except Exception:
                pass

    def _request(self, operation, *, failure_code, **payload):
        with self._connection() as connection:
            response = connection.request(operation, **payload)
        if type(response) is not dict or response.get("error") is not None:
            raise DictionaryExchangeError(failure_code)
        code = response.get("dictionaryExchangeError")
        if code is not None:
            raise DictionaryExchangeError(code if type(code) is str and code in EXCHANGE_FAILURES else failure_code)
        return response

    def preview(self, path, *, format_name, encoding, entries):
        try:
            if format_name not in IMPORT_FORMATS or encoding not in IMPORT_ENCODINGS:
                raise DictionaryExchangeError("unsupportedFormat")
            original = _entries(entries)
            response = self._request(
                "dictionary-import-preview", failure_code="importFailed",
                importPath=os.fspath(path), importFormat=format_name, importEncoding=encoding,
                items=[entry.as_mapping() for entry in original],
            )
            return _import_preview(response, original)
        except DictionaryExchangeError:
            raise
        except Exception:
            raise DictionaryExchangeError("importFailed") from None

    def export(self, entries, *, destination):
        try:
            original = _entries(entries)
            response = self._request(
                "dictionary-export", failure_code="exportFailed",
                items=[entry.as_mapping() for entry in original],
            )
            _write_atomic(destination, _export_content(response, original))
        except DictionaryExchangeError:
            raise
        except Exception:
            raise DictionaryExchangeError("exportFailed") from None
