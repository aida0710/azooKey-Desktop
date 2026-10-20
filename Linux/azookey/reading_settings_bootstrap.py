"""Read saved preferences without changing them or forwarding unrelated data."""
from .settings_store import SettingsStore
from .worker_settings import SETTINGS_FIELDS, validated_settings, validated_settings_values


class ReadingSettingsBootstrap:
    def __init__(self, *, path=None):
        self.path = path
        self.problem = None

    def load(self, defaults):
        known_good = validated_settings_values(defaults)
        # A fresh read uses this process's defaults even when an unchanged older
        # settings file omits fields. Nothing here creates or updates a backup.
        loaded = SettingsStore(self.path).load(known_good)
        values = validated_settings({key: loaded.values[key] for key in SETTINGS_FIELDS})
        self.problem = loaded.problem
        return values
