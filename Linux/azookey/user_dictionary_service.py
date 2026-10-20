"""Connect dictionary callbacks to a staged SettingsStore transaction."""

from contextlib import contextmanager
import copy
import os
import uuid

from .bridge import Bridge
from .user_dictionary_model import DictionarySaveError, DictionaryValidationIssue


SAVE_STAGES = frozenset({"compile", "persistence", "activation", "rollback"})
VALIDATION_FIELDS = frozenset({"word", "reading"})
VALIDATION_REASONS = frozenset({"empty", "controlCharacter", "unsupportedCharacter"})


def _validation_issues(response, *, required):
    if "dictionaryIssues" not in response and not required:
        return []
    issues = response.get("dictionaryIssues")
    if type(issues) is not list:
        raise ValueError("invalid_dictionary_validation_response")
    observations = []
    for issue in issues:
        if type(issue) is not dict:
            raise ValueError("invalid_dictionary_validation_issue")
        row_id = issue.get("rowID")
        field = issue.get("field")
        reason = issue.get("reason")
        characters = issue.get("characters")
        if not all(type(value) is str for value in (row_id, field, reason, characters)):
            raise ValueError("invalid_dictionary_validation_issue")
        uuid.UUID(row_id)
        if field not in VALIDATION_FIELDS or reason not in VALIDATION_REASONS:
            raise ValueError("invalid_dictionary_validation_issue")
        observations.append(DictionaryValidationIssue(row_id, field, reason, characters))
    return observations


class UserDictionaryService:
    """Use a dedicated store instance and one private Bridge per worker call.

    opened is the SettingsLoad captured when the editor opens. The required
    expected_stamp prevents its other settings from overwriting later changes.
    SettingsStore.save_with_backend owns validation, the writer lock, staging,
    readback, and cache updates. Core owns the atomic commit and rollback.
    """

    def __init__(self, store, opened, *, bridge_factory=Bridge):
        self._store = store
        self._values = copy.deepcopy(opened.values)
        self._stamp = opened.stamp
        self._bridge_factory = bridge_factory
        self.last_saved = None
        self.needs_recovery = False

    @contextmanager
    def _connection(self):
        connection = self._bridge_factory()
        try:
            yield connection
        finally:
            try:
                connection.close()
            except Exception:
                # Closing an already finished private process must not turn an
                # acknowledged commit into a failure the user would retry.
                pass

    def validate(self, entries):
        try:
            with self._connection() as connection:
                response = connection.request("dictionary-validate", items=copy.deepcopy(entries))
            if type(response) is not dict or response.get("error") is not None:
                raise ValueError("dictionary_validation_failed")
            return _validation_issues(response, required=True)
        except Exception:
            raise DictionarySaveError("validation") from None

    def save(self, entries):
        if self.needs_recovery:
            raise DictionarySaveError("rollback")
        items = copy.deepcopy(entries)
        values = copy.deepcopy(self._values)
        values["userDictionary"] = {"items": items}
        try:
            saved = self._store.save_with_backend(
                values,
                apply_staged=lambda path: self._apply_staged(items, path),
                expected_stamp=self._stamp,
            )
            if saved.values != values or saved.stamp is None:
                raise ValueError("dictionary_settings_readback_failed")
        except DictionarySaveError as error:
            if error.stage == "rollback":
                self.needs_recovery = True
            raise
        except Exception:
            raise DictionarySaveError("persistence") from None
        self._values = copy.deepcopy(saved.values)
        self._stamp = saved.stamp
        self.last_saved = saved

    def _apply_staged(self, items, path):
        try:
            with self._connection() as connection:
                response = connection.request(
                    "dictionary-save", items=copy.deepcopy(items), stagedSettingsPath=os.fspath(path),
                )
            if type(response) is not dict or response.get("error") is not None:
                raise DictionarySaveError("unknown")
            issues = _validation_issues(response, required=False)
            stage = response.get("dictionarySaveError")
            if stage is not None:
                public_stage = stage if type(stage) is str and stage in SAVE_STAGES else "unknown"
                raise DictionarySaveError(public_stage, issues=issues)
            if issues:
                raise DictionarySaveError("validation", issues=issues)
            if response.get("dictionarySaved") is not True:
                raise DictionarySaveError("unknown")
        except DictionarySaveError:
            raise
        except Exception:
            raise DictionarySaveError("unknown") from None
