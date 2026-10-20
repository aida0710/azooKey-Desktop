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


ValidateDictionary = Callable[[list[dict]], Sequence[DictionaryValidationIssue]]
SaveDictionary = Callable[[list[dict]], None]


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

    def entry(self, entry_id):
        return next(entry.as_mapping() for entry in self._entries if entry.id == entry_id)

    def issues_for(self, entry_id):
        # Swift emits canonical UUID strings, which can differ only in letter case.
        return tuple(issue for issue in self.issues if issue.entry_id.lower() == entry_id.lower())

    def _require_editable(self):
        if self.is_saving:
            raise RuntimeError("dictionary_save_in_progress")

    def add(self):
        self._require_editable()
        entry = DictionaryEntry(id=str(uuid.uuid4()).upper(), word="", reading="", hint="")
        self._entries += (entry,)
        self.failure_stage = None
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
        self.failure_stage = None

    def remove(self, entry_id):
        self._require_editable()
        self.entry(entry_id)
        self._entries = tuple(entry for entry in self._entries if entry.id != entry_id)
        self.issues = tuple(issue for issue in self.issues if issue.entry_id.lower() != entry_id.lower())
        self.failure_stage = None

    def discard(self):
        self._require_editable()
        self._entries = self._saved_entries
        self.issues = ()
        self.failure_stage = None

    def begin_save(self):
        if self.is_saving or self.needs_recovery:
            return None
        self.issues = ()
        self.failure_stage = None
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
