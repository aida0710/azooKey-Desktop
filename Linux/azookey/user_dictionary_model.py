"""Keep dictionary edits separate from persistence and converter callbacks."""

from dataclasses import dataclass, replace
from typing import Callable, Sequence
import uuid


@dataclass(frozen=True)
class DictionaryValidationIssue:
    entry_id: str
    field: str
    code: str
    characters: str = ""


class DictionarySaveError(Exception):
    """The adapter exposes a public stage, never a raw backend error message."""

    def __init__(self, stage, *, issues=()):
        super().__init__(stage)
        self.stage = stage
        self.issues = tuple(issues)


class DictionaryExchangeError(Exception):
    """Only a public failure code crosses the file-service boundary."""

    def __init__(self, code):
        super().__init__(code)
        self.code = code


@dataclass(frozen=True)
class DictionaryEntry:
    id: str
    word: str
    reading: str
    hint: str | None = None

    def as_mapping(self):
        return {"id": self.id, "word": self.word, "reading": self.reading, "hint": self.hint}


@dataclass(frozen=True)
class DictionarySaveRequest:
    entries: tuple[DictionaryEntry, ...]

    def snapshot(self):
        return [entry.as_mapping() for entry in self.entries]


@dataclass(frozen=True)
class DictionarySaveOutcome:
    saved: bool = False
    issues: tuple[DictionaryValidationIssue, ...] = ()
    failure_stage: str | None = None


@dataclass(frozen=True)
class DictionaryImportRow:
    source_index: int
    source_line: int | None
    entry: DictionaryEntry | None
    part_of_speech: str | None
    outcome: str
    problem: str | None
    validation_issues: tuple[DictionaryValidationIssue, ...]


@dataclass(frozen=True)
class DictionaryImportPreview:
    original_entries: tuple[DictionaryEntry, ...]
    entries_after_import: tuple[DictionaryEntry, ...]
    rows: tuple[DictionaryImportRow, ...]
    notices: tuple[str, ...]

    def count(self, outcome):
        return sum(row.outcome == outcome for row in self.rows)


@dataclass(frozen=True)
class DictionaryFileRequest:
    operation: str
    entries: tuple[DictionaryEntry, ...]

    def snapshot(self):
        return [entry.as_mapping() for entry in self.entries]


@dataclass(frozen=True)
class DictionaryFileOutcome:
    preview: DictionaryImportPreview | None = None
    failure_code: str | None = None
    exported: bool = False


ValidateDictionary = Callable[[list[dict]], Sequence[DictionaryValidationIssue]]
SaveDictionary = Callable[[list[dict]], None]


def matches_dictionary_query(entry, query):
    """Search displayed text without changing its spelling or validation rules."""
    query = query.casefold()
    return any(query in (entry.get(field) or "").casefold() for field in ("word", "reading", "hint"))


def save_dictionary(request, *, validate: ValidateDictionary, save: SaveDictionary):
    """Run on a worker; the shared Core validator remains the authority on readings."""
    try:
        issues = validate(request.snapshot())
        if not isinstance(issues, (list, tuple)) or not all(
            isinstance(issue, DictionaryValidationIssue) for issue in issues
        ):
            return DictionarySaveOutcome(failure_stage="validation")
        if issues:
            return DictionarySaveOutcome(issues=tuple(issues))
    except Exception:
        return DictionarySaveOutcome(failure_stage="validation")
    try:
        # Each callback receives its own copy, so validation cannot rewrite the draft.
        if save(request.snapshot()) is not None:
            return DictionarySaveOutcome(failure_stage="unknown")
    except DictionarySaveError as error:
        if error.stage == "rollback":
            return DictionarySaveOutcome(issues=error.issues, failure_stage="rollback")
        if error.issues:
            return DictionarySaveOutcome(issues=error.issues)
        return DictionarySaveOutcome(failure_stage=error.stage)
    except Exception:
        return DictionarySaveOutcome(failure_stage="unknown")
    return DictionarySaveOutcome(saved=True)


class UserDictionaryModel:
    """Own the draft and save state; all mutations belong to the UI thread."""

    def __init__(self, entries):
        self._entries = tuple(
            DictionaryEntry(
                id=entry["id"], word=entry["word"], reading=entry["reading"], hint=entry.get("hint"),
            )
            for entry in entries
        )
        self._saved_entries = self._entries
        self._active_request = None
        self._active_file_request = None
        self.import_preview = None
        self.exchange_failure = None
        self.did_export = False
        self.needs_recovery = False
        self.issues = ()
        self.failure_stage = None

    @property
    def entries(self):
        return [entry.as_mapping() for entry in self._entries]

    @property
    def has_changes(self):
        return self._entries != self._saved_entries

    @property
    def is_saving(self):
        return self._active_request is not None

    @property
    def is_busy(self):
        return self.is_saving or self._active_file_request is not None

    @property
    def file_operation(self):
        return self._active_file_request.operation if self._active_file_request else None

    @property
    def can_close(self):
        return not self.is_busy and self.import_preview is None

    def entry(self, entry_id):
        return next(entry.as_mapping() for entry in self._entries if entry.id == entry_id)

    def issues_for(self, entry_id):
        # Swift emits canonical UUID strings, which can differ only in letter case.
        return tuple(issue for issue in self.issues if issue.entry_id.lower() == entry_id.lower())

    def _require_editable(self):
        if not self.can_close:
            raise RuntimeError("dictionary_operation_in_progress")

    def _clear_feedback(self):
        self.failure_stage = None
        self.exchange_failure = None
        self.did_export = False

    def add(self):
        self._require_editable()
        entry = DictionaryEntry(id=str(uuid.uuid4()).upper(), word="", reading="", hint="")
        self._entries += (entry,)
        self._clear_feedback()
        return entry.id

    def update(self, entry_id, **fields):
        self._require_editable()
        if not fields.keys() <= {"word", "reading", "hint"}:
            raise ValueError("unknown_dictionary_field")
        if not any(entry.id == entry_id for entry in self._entries):
            raise KeyError(entry_id)
        self._entries = tuple(
            replace(entry, **fields) if entry.id == entry_id else entry for entry in self._entries
        )
        self.issues = tuple(issue for issue in self.issues if issue.entry_id.lower() != entry_id.lower())
        self._clear_feedback()

    def remove(self, entry_id):
        self._require_editable()
        self.entry(entry_id)
        self._entries = tuple(entry for entry in self._entries if entry.id != entry_id)
        self.issues = tuple(issue for issue in self.issues if issue.entry_id.lower() != entry_id.lower())
        self._clear_feedback()

    def discard(self):
        self._require_editable()
        self._entries = self._saved_entries
        self.issues = ()
        self._clear_feedback()

    def begin_save(self):
        if not self.can_close or self.needs_recovery:
            return None
        self.issues = ()
        self._clear_feedback()
        self._active_request = DictionarySaveRequest(self._entries)
        return self._active_request

    def finish_save(self, request, outcome):
        if request is not self._active_request:
            return False
        self._active_request = None
        self.issues = outcome.issues
        self.failure_stage = outcome.failure_stage
        if outcome.failure_stage == "rollback":
            self.needs_recovery = True
        if outcome.saved:
            self._saved_entries = request.entries
        return True

    def begin_file_operation(self, operation):
        if operation not in ("import", "export"):
            raise ValueError("unknown_dictionary_file_operation")
        if not self.can_close or (operation == "import" and self.needs_recovery):
            return None
        self._clear_feedback()
        self._active_file_request = DictionaryFileRequest(operation, self._entries)
        return self._active_file_request

    def finish_file_operation(self, request, outcome):
        if request is not self._active_file_request:
            return False
        self._active_file_request = None
        failure_code = "importFailed" if request.operation == "import" else "exportFailed"
        if outcome.failure_code is not None:
            self.exchange_failure = (
                outcome.failure_code if type(outcome.failure_code) is str and outcome.failure_code else failure_code
            )
            return True
        self.exchange_failure = None
        if request.operation == "import" and isinstance(outcome.preview, DictionaryImportPreview):
            if self._entries != request.entries or outcome.preview.original_entries != request.entries:
                self.exchange_failure = "stalePreview"
            else:
                self.import_preview = outcome.preview
        elif request.operation == "export" and outcome.exported is True:
            self.did_export = True
        else:
            self.exchange_failure = failure_code
        return True

    def cancel_import(self):
        if self.is_busy:
            return False
        self.import_preview = None
        self._clear_feedback()
        return True

    def apply_import(self):
        preview = self.import_preview
        if self.is_busy or self.needs_recovery or preview is None or not preview.count("addition"):
            return False
        self.import_preview = None
        if self._entries != preview.original_entries:
            self.exchange_failure = "stalePreview"
            return False
        self._entries = preview.entries_after_import
        self.issues = ()
        self._clear_feedback()
        return True
