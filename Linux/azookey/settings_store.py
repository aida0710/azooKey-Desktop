"""Recoverable settings-file reads and atomic, conflict-aware writes."""
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime
import copy
import fcntl
import json
import os
import pathlib
import tempfile
import uuid

from .localization import message
from .settings_schema import PRESERVED_SETTINGS, validate_settings


UNSPECIFIED_STAMP = object()


def config_path():
    base = pathlib.Path(os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
    return base / "azookey-tree/settings.json"


@dataclass(frozen=True)
class SettingsProblem:
    reason: str
    stamp: tuple


@dataclass(frozen=True)
class SettingsLoad:
    values: dict
    stamp: tuple | None
    problem: SettingsProblem | None = None


@dataclass(frozen=True)
class SettingsSave:
    values: dict
    stamp: tuple
    backup_path: pathlib.Path | None = None
    backup_warning: bool = False


class SettingsRecoveryRequired(ValueError):
    pass


def _stamp(path):
    try:
        stat = path.stat()
        return (stat.st_dev, stat.st_ino, stat.st_mtime_ns, stat.st_size, stat.st_mode)
    except FileNotFoundError:
        if path.is_symlink():
            return ("broken-link", path.lstat().st_mtime_ns)
        return None
    except OSError as error:
        return ("unreadable", error.errno)


def _unique_keys(pairs):
    document = {}
    for key, value in pairs:
        if key in document:
            raise ValueError(message("settings.invalid_value", field=key[:100]))
        document[key] = value
    return document


def _read(path, defaults):
    try:
        document = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_unique_keys)
    except json.JSONDecodeError as error:
        raise ValueError(message("settings.invalid_json", line=error.lineno, column=error.colno)) from error
    except (OSError, UnicodeError) as error:
        raise ValueError(message("settings.read_failed")) from error
    return validate_settings(document, defaults=defaults)


def _write_atomic(path, values):
    descriptor, temporary = tempfile.mkstemp(prefix=".settings-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(values, stream, ensure_ascii=False, allow_nan=False)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class SettingsStore:
    def __init__(self, path=None):
        self.path = pathlib.Path(path) if path is not None else config_path()
        self.backup = self.path.with_name("settings.last-good.json")
        self.cached_stamp = object()
        self.cached = None

    def load(self, known_good):
        stamp = _stamp(self.path)
        if stamp is None:
            return SettingsLoad(copy.deepcopy(known_good), None)
        if stamp != self.cached_stamp:
            self.cached_stamp = stamp
            try:
                values = _read(self.path, known_good)
                self.cached = SettingsLoad(values, stamp)
            except ValueError as error:
                self.cached = SettingsLoad({}, stamp, SettingsProblem(str(error), stamp))
        if self.cached.problem:
            # A later successful configure may have changed known_good while
            # the same broken file remains. Never pin an older fallback.
            return SettingsLoad(copy.deepcopy(known_good), stamp, self.cached.problem)
        return SettingsLoad(copy.deepcopy(self.cached.values), stamp)

    def reject(self, loaded):
        self.cached_stamp = loaded.stamp
        self.cached = SettingsLoad({}, loaded.stamp, SettingsProblem(message("settings.engine_rejected"), loaded.stamp))

    def remember(self, values):
        """Store only values that Core has accepted; failure never blocks input."""
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            _write_atomic(self.backup, validate_settings(values))
            return True
        except (OSError, ValueError):
            return False

    def recovery_values(self, known_good):
        try:
            saved = _read(self.backup, known_good)
            # Restoring preferences must not replace a newer active dictionary
            # or AI/learning choice with an older backup's copy.
            saved.update({key: copy.deepcopy(value) for key, value in known_good.items() if key in PRESERVED_SETTINGS})
            return saved
        except ValueError:
            return copy.deepcopy(known_good)

    @contextmanager
    def _writer(self):
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        descriptor = os.open(self.path.with_name(".settings.lock"), os.O_CREAT | os.O_RDWR, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError(message("settings.busy")) from error
            yield
        finally:
            os.close(descriptor)

    def save(self, values, *, expected_stamp=UNSPECIFIED_STAMP, recover=False):
        validated = validate_settings(values)
        with self._writer():
            return self._save_locked(validated, expected_stamp=expected_stamp, recover=recover)

    def update(self, changes, *, defaults):
        with self._writer():
            current = self._read_before_save(defaults)
            values = validate_settings(changes, defaults=current)
            return self._save_locked(values)

    def _read_before_save(self, defaults):
        if _stamp(self.path) is None:
            return copy.deepcopy(defaults)
        try:
            return _read(self.path, defaults)
        except ValueError as error:
            raise SettingsRecoveryRequired(message("settings.recovery_required")) from error

    def _save_locked(self, values, *, expected_stamp=UNSPECIFIED_STAMP, recover=False):
        current_stamp = _stamp(self.path)
        if expected_stamp is not UNSPECIFIED_STAMP and current_stamp != expected_stamp:
            raise ValueError(message("settings.changed"))
        if not recover:
            self._read_before_save(values)
        preserved = None
        if recover and current_stamp is not None:
            suffix = datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
            preserved = self.path.with_name(f"settings.recovered-{suffix}-{uuid.uuid4().hex[:8]}.json")
            os.replace(self.path, preserved)
        try:
            _write_atomic(self.path, values)
        except OSError:
            if preserved is not None and not self.path.exists():
                os.replace(preserved, self.path)
            raise
        warning = not self.remember(values)
        self.cached_stamp = object()
        return SettingsSave(copy.deepcopy(values), _stamp(self.path), preserved, warning)


def save_settings(values):
    return SettingsStore().save(values)


def update_settings(changes, *, defaults):
    return SettingsStore().update(changes, defaults=defaults)
