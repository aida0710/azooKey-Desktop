"""Exercise the real settings transaction; only the Swift protocol is simulated."""

import json
import os
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.settings_store import SettingsStore
from azookey.user_dictionary_model import DictionarySaveError
from azookey.user_dictionary_service import UserDictionaryService
from test_user_dictionary_model import original_entries


def known_settings():
    return {
        "tree": False, "live": False, "halfSpace": True, "learning": "nothing",
        "inputStyle": "default", "punctuation": 1, "inferenceLimit": 5,
        "profile": "合成の試験用", "personalization": "soft", "customTable": "",
        "aiEnabled": True, "aiModel": "test-model", "aiEndpoint": "https://example.invalid/v1",
        "includeContext": False, "transformShortcut": {"key": "s", "modifiers": 2},
        "userDictionary": {"items": original_entries()},
    }


class SimulatedDictionaryBackend:
    """Honor the publish/rollback protocol without testing Swift's implementation."""

    def __init__(self, store):
        self.store = store
        self.calls = []
        self.closed = 0
        self.rollback = False
        self.installed_inode = None
        self.lock_observed = False

    def request(self, operation, **payload):
        assert operation == "dictionary-save"
        assert set(payload) == {"items", "stagedSettingsPath"}
        self.calls.append(payload)
        path = self.store.path
        staged = pathlib.Path(payload["stagedSettingsPath"])
        assert staged.parent == path.parent
        assert stat.S_IMODE(staged.stat().st_mode) == 0o600
        values = json.loads(staged.read_text(encoding="utf-8"))
        assert values["userDictionary"]["items"] == payload["items"]
        try:
            SettingsStore(path).save(known_settings())
        except ValueError:
            self.lock_observed = True
        else:
            raise AssertionError("writer lock was not held during the backend call")
        backup = path.with_name(".simulated-json-backup")
        existed = path.exists()
        if existed:
            os.link(path, backup)
        self.installed_inode = staged.stat().st_ino
        os.replace(staged, path)
        assert json.loads(path.read_text(encoding="utf-8")) == values
        if self.rollback:
            if existed:
                os.replace(backup, path)
            else:
                path.unlink()
            return {"dictionarySaveError": "activation"}
        backup.unlink(missing_ok=True)
        return {"dictionarySaved": True}

    def close(self):
        self.closed += 1


class UserDictionarySettingsStoreTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="azookey-dictionary-store-")
        self.addCleanup(directory.cleanup)
        self.directory = pathlib.Path(directory.name)
        self.store = SettingsStore(self.directory / "settings.json")
        self.backend = SimulatedDictionaryBackend(self.store)

    def open_service(self, *, initial=True):
        if initial:
            self.store.save(known_settings())
        self.opened = self.store.load(known_settings())
        return UserDictionaryService(self.store, self.opened, bridge_factory=lambda: self.backend)

    def test_success_holds_writer_lock_and_keeps_the_backend_file_without_double_save(self):
        service = self.open_service()
        items = original_entries()
        items[0].update(word="更新した辞書", hint="1行目\n2行目\t補足")
        with patch.object(self.store, "save", side_effect=AssertionError("double save")):
            service.save(items)
        self.assertTrue(self.backend.lock_observed)
        self.assertEqual(self.store.path.stat().st_ino, self.backend.installed_inode)
        self.assertEqual(service.last_saved.values["userDictionary"]["items"], items)
        self.assertEqual(self.store.load(known_settings()).values, service.last_saved.values)
        self.assertEqual(
            json.loads(self.store.backup.read_text(encoding="utf-8")), service.last_saved.values,
        )
        self.assertEqual(stat.S_IMODE(self.store.backup.stat().st_mode), 0o600)
        self.assertEqual(self.backend.closed, 1)
        self.assertEqual(list(self.directory.glob(".settings-*")), [])

    def assert_restored_stamp_allows_retry(self, *, initial):
        service = self.open_service(initial=initial)
        before = self.store.path.read_bytes() if initial else None
        self.backend.rollback = True
        with self.assertRaises(DictionarySaveError) as raised:
            service.save(original_entries())
        self.assertEqual(raised.exception.stage, "activation")
        self.assertEqual(self.store.load(known_settings()).stamp, self.opened.stamp)
        after = self.store.path.read_bytes() if self.store.path.exists() else None
        self.assertEqual(after, before)
        self.assertIsNone(service.last_saved)
        self.backend.rollback = False
        service.save(original_entries())
        self.assertIsNotNone(service.last_saved)
        self.assertEqual(len(self.backend.calls), 2)

    def test_existing_file_rollback_keeps_the_original_stamp_and_allows_retry(self):
        self.assert_restored_stamp_allows_retry(initial=True)

    def test_first_file_rollback_restores_absence_and_allows_retry(self):
        self.assert_restored_stamp_allows_retry(initial=False)

    def test_fsync_failure_and_stale_dialog_preserve_settings_without_calling_backend(self):
        service = self.open_service()
        before = self.store.path.read_bytes()
        with patch("azookey.settings_store.os.fsync", side_effect=OSError("synthetic fsync failure")):
            with self.assertRaises(DictionarySaveError) as raised:
                service.save(original_entries())
        self.assertEqual(raised.exception.stage, "persistence")
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(self.store.path.read_bytes(), before)
        self.assertEqual(list(self.directory.glob(".settings-*")), [])
        self.store.save({**known_settings(), "live": True}, expected_stamp=self.opened.stamp)
        changed = self.store.path.read_bytes()
        with self.assertRaises(DictionarySaveError) as raised:
            service.save(original_entries())
        self.assertEqual(raised.exception.stage, "persistence")
        self.assertEqual(self.backend.calls, [])
        self.assertEqual(self.store.path.read_bytes(), changed)


if __name__ == "__main__":
    unittest.main()
