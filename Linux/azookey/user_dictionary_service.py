"""Connect dictionary editor callbacks to Core's dictionary save transaction."""

from contextlib import contextmanager
import copy
import uuid

from .bridge import Bridge
from . import settings_client
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
    """Use one private Bridge per worker call.

    opened is the settings-load result captured when the editor opens. Its
    stamp lets Core refuse to overwrite settings another screen saved since.
    Core stages, validates, installs, reads back and rolls back the settings
    file together with the compiled dictionary.
    """

    def __init__(self, opened, *, bridge_factory=Bridge):
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
        try:
            with self._connection() as connection:
                response = connection.request(
                    "dictionary-save", items=copy.deepcopy(entries), settingsFile={"expectedStamp": self._stamp},
                )
            saved = _saved_settings(response)
        except DictionarySaveError as error:
            if error.stage == "rollback":
                self.needs_recovery = True
            raise
        except Exception:
            raise DictionarySaveError("unknown") from None
        self._stamp = saved.stamp
        self.last_saved = saved


def _saved_settings(response):
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
    try:
        return settings_client.saved_settings(response)
    except (KeyError, TypeError, ValueError, RuntimeError):
        raise DictionarySaveError("unknown") from None
