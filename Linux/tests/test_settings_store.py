import copy
import fcntl
import json
import os
import pathlib
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.settings_schema import input_defaults, validate_settings
from azookey.settings_store import SettingsRecoveryRequired, SettingsStore, update_settings


def known_settings():
    return {
        "tree": False, "live": False, "halfSpace": True, "learning": "nothing",
        "inputStyle": "default", "punctuation": 1, "inferenceLimit": 5,
        "profile": "テスト", "personalization": "soft", "customTable": "",
        "aiEnabled": True, "aiModel": "test-model", "aiEndpoint": "https://example.invalid/v1",
        "includeContext": False, "transformShortcut": {"key": "s", "modifiers": 2},
        "userDictionary": {"items": [{
            "id": "6c5fce13-fb0f-4b59-9281-f7347ae8f91c", "reading": "てすと", "word": "試験", "hint": None,
        }]},
    }


class SettingsValidationTests(unittest.TestCase):
    def test_wrong_types_unknown_keys_and_values_are_rejected_before_core(self):
        malformed = [
            [], None, {"live": 1}, {"tree": "true"}, {"inferenceLimit": True},
            {"inferenceLimit": 0}, {"inferenceLimit": 101}, {"punctuation": "1"},
            {"punctuation": 5}, {"learning": "sometimes"}, {"newSetting": 1},
            {"aiEndpoint": "file:///tmp/model"}, {"aiEndpoint": "https://"},
            {"transformShortcut": {"key": "s", "modifiers": 16}},
            {"transformShortcut": {"key": "", "modifiers": 2}},
            {"userDictionary": {"items": [{"word": "欠落"}]}},
            {"customTable": 10}, {"inputStyle": "custom"}, {"profile": "\ud800"},
            {"profile": "あ" * 4097},
        ]
        for document in malformed:
            with self.subTest(document=document):
                with self.assertRaises(ValueError):
                    validate_settings(document, defaults=known_settings())

    def test_extended_graphemes_use_the_same_profile_limit_as_core(self):
        self.assertEqual(validate_settings({"profile": "か\u3099" * 4096})["profile"], "か\u3099" * 4096)

    def test_duplicate_dictionary_id_is_rejected_without_mutating_original(self):
        values = known_settings()
        values["userDictionary"]["items"] *= 2
        before = copy.deepcopy(values)
        with self.assertRaises(ValueError):
            validate_settings(values)
        self.assertEqual(values, before)

    def test_input_defaults_preserve_dictionary_ai_learning_and_custom_table(self):
        values = known_settings()
        values["customTable"] = "synthetic custom table"
        reset = input_defaults(values)
        self.assertTrue(reset["tree"])
        self.assertTrue(reset["live"])
        self.assertFalse(reset["halfSpace"])
        for key in ("userDictionary", "aiEnabled", "aiModel", "aiEndpoint", "includeContext",
                    "transformShortcut", "learning", "profile", "personalization", "customTable"):
            self.assertEqual(reset[key], values[key])


class SettingsStoreTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="azookey-settings-test-")
        self.addCleanup(self.directory.cleanup)
        self.path = pathlib.Path(self.directory.name) / "settings.json"
        self.store = SettingsStore(self.path)
        self.values = known_settings()

    def write(self, values):
        self.path.write_text(json.dumps(values, ensure_ascii=False), encoding="utf-8")

    def test_missing_file_and_unchanged_broken_file_use_latest_known_settings(self):
        self.assertEqual(self.store.load(self.values).values, self.values)
        changed = {**self.values, "live": True}
        self.assertEqual(self.store.load(changed).values, changed)
        self.path.write_text("{")
        self.assertIsNotNone(self.store.load(self.values).problem)
        self.assertEqual(self.store.load(changed).values, changed)

    def test_invalid_json_duplicate_keys_types_and_unknown_values_keep_original_and_input(self):
        documents = ['{', '{"live":false,"live":true}', '{"live":1}', '{"learning":"unknown"}',
                     '{"unexpected":true}', '["not an object"]', '{"profile":"\\ud800"}']
        for document in documents:
            with self.subTest(document=document):
                self.path.write_text(document, encoding="utf-8")
                loaded = self.store.load(self.values)
                self.assertEqual(loaded.values, self.values)
                self.assertIsNotNone(loaded.problem)
                self.assertEqual(self.path.read_text(), document)
                self.assertEqual(list(self.path.parent.glob("settings.recovered-*")), [])

    def test_unreadable_file_and_broken_link_remain_recoverable(self):
        self.write(self.values)
        with patch.object(pathlib.Path, "read_text", side_effect=PermissionError):
            loaded = self.store.load(self.values)
        self.assertIsNotNone(loaded.problem)
        self.assertEqual(loaded.values, self.values)
        self.path.unlink()
        self.path.symlink_to(self.path.parent / "missing.json")
        loaded = self.store.load(self.values)
        self.assertIsNotNone(loaded.problem)
        self.assertEqual(loaded.values, self.values)

    def test_repaired_file_applies_on_next_load_without_restart(self):
        self.path.write_text("{")
        self.assertIsNotNone(self.store.load(self.values).problem)
        self.write({"live": True})
        loaded = self.store.load(self.values)
        self.assertIsNone(loaded.problem)
        self.assertTrue(loaded.values["live"])
        self.assertEqual(loaded.values["userDictionary"], self.values["userDictionary"])

    def test_core_rejection_is_cached_until_document_changes(self):
        self.write({"customTable": "synthetic invalid TSV"})
        loaded = self.store.load(self.values)
        self.store.reject(loaded)
        self.assertIsNotNone(self.store.load(self.values).problem)
        self.assertEqual(self.store.load(self.values).values, self.values)
        self.write({"customTable": ""})
        self.assertIsNone(self.store.load(self.values).problem)

    def test_save_and_update_refuse_to_overwrite_a_broken_file(self):
        self.path.write_bytes(b"{ invalid synthetic document")
        for operation in (lambda: self.store.save(self.values),
                          lambda: self.store.update({"includeContext": True}, defaults=self.values)):
            with self.assertRaises(SettingsRecoveryRequired):
                operation()
            self.assertEqual(self.path.read_bytes(), b"{ invalid synthetic document")

    def test_update_merges_latest_dictionary_instead_of_stale_dialog_copy(self):
        latest = copy.deepcopy(self.values)
        latest["userDictionary"]["items"][0]["word"] = "最新"
        self.write(latest)
        with patch.dict(os.environ, {"XDG_CONFIG_HOME": self.directory.name}):
            # The public function resolves the same path as the engine/UI.
            target = pathlib.Path(self.directory.name) / "azookey-tree"
            target.mkdir()
            os.replace(self.path, target / "settings.json")
            saved = update_settings({"includeContext": True}, defaults=self.values)
        self.assertTrue(saved.values["includeContext"])
        self.assertEqual(saved.values["userDictionary"], latest["userDictionary"])

    def test_conflict_detection_includes_file_created_after_dialog_opened(self):
        absent = self.store.load(self.values)
        self.write(self.values)
        with self.assertRaisesRegex(ValueError, "変わりました"):
            self.store.save(self.values, expected_stamp=absent.stamp)
        opened = self.store.load(self.values)
        self.write({**self.values, "live": True})
        with self.assertRaisesRegex(ValueError, "変わりました"):
            self.store.save(self.values, expected_stamp=opened.stamp)
        self.assertTrue(json.loads(self.path.read_text())["live"])

    def test_explicit_recovery_preserves_exact_original_and_external_assets(self):
        original = b"{ broken synthetic JSON\n"
        self.path.write_bytes(original)
        self.path.chmod(0o400)
        protected = ["learning.dat", "lm_3.marisa", "test-keyring"]
        for name in protected:
            (self.path.parent / name).write_bytes(name.encode())
        loaded = self.store.load(self.values)
        saved = self.store.save(self.values, expected_stamp=loaded.stamp, recover=True)
        self.assertEqual(saved.backup_path.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(saved.backup_path.stat().st_mode), 0o400)
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(json.loads(self.path.read_text()), self.values)
        self.assertEqual(json.loads(self.store.backup.read_text()), self.values)
        for name in protected:
            self.assertEqual((self.path.parent / name).read_bytes(), name.encode())

    def test_failed_recovery_write_puts_original_back(self):
        self.path.write_bytes(b"{ original")
        with patch("azookey.settings_store._write_atomic", side_effect=OSError("synthetic disk full")):
            with self.assertRaises(OSError):
                self.store.save(self.values, recover=True)
        self.assertEqual(self.path.read_bytes(), b"{ original")
        self.assertEqual(list(self.path.parent.glob("settings.recovered-*")), [])

    def test_old_backup_does_not_replace_newer_active_dictionary_or_privacy_choices(self):
        older = copy.deepcopy(self.values)
        older["live"] = True
        older["userDictionary"]["items"][0]["word"] = "古い"
        older["includeContext"] = True
        self.assertTrue(self.store.remember(older))
        restored = self.store.recovery_values(self.values)
        self.assertTrue(restored["live"])
        self.assertEqual(restored["userDictionary"], self.values["userDictionary"])
        self.assertFalse(restored["includeContext"])

    def test_another_writer_fails_quickly_without_changing_document(self):
        self.write(self.values)
        with self.path.with_name(".settings.lock").open("w") as writer:
            fcntl.flock(writer, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with self.assertRaisesRegex(ValueError, "別の画面"):
                self.store.save({**self.values, "live": True})
        self.assertEqual(json.loads(self.path.read_text()), self.values)

    def test_backup_failure_reports_warning_but_keeps_successful_settings_save(self):
        with patch.object(self.store, "remember", return_value=False):
            saved = self.store.save(self.values)
        self.assertTrue(saved.backup_warning)
        self.assertEqual(json.loads(self.path.read_text()), self.values)

    def test_backend_save_receives_private_synced_staging_and_publishes_only_once_under_lock(self):
        self.write(self.values)
        opened = self.store.load(self.values)
        updated = {**self.values, "live": True}
        installed_inode = []

        def apply_staged(staged):
            self.assertEqual(staged.parent, self.path.parent)
            self.assertEqual(stat.S_IMODE(staged.stat().st_mode), 0o600)
            self.assertEqual(json.loads(staged.read_text()), updated)
            with self.assertRaisesRegex(ValueError, "別の画面"):
                SettingsStore(self.path).save(self.values)
            installed_inode.append(staged.stat().st_ino)
            os.replace(staged, self.path)

        saved = self.store.save_with_backend(updated, apply_staged=apply_staged, expected_stamp=opened.stamp)
        self.assertEqual(saved.values, updated)
        self.assertEqual(self.path.stat().st_ino, installed_inode[0])
        self.assertEqual(json.loads(self.store.backup.read_text()), updated)
        self.assertEqual(list(self.path.parent.glob(".settings-*")), [])

    def test_backend_error_is_returned_unchanged_and_staging_is_removed(self):
        self.write(self.values)
        opened = self.store.load(self.values)
        failure = RuntimeError("synthetic backend rollback succeeded")

        def reject_staged(_staged):
            raise failure

        with self.assertRaises(RuntimeError) as raised:
            self.store.save_with_backend(self.values, apply_staged=reject_staged, expected_stamp=opened.stamp)
        self.assertIs(raised.exception, failure)
        self.assertEqual(self.store.load(self.values).stamp, opened.stamp)
        self.assertEqual(json.loads(self.path.read_text()), self.values)
        self.assertFalse(self.store.backup.exists())
        self.assertEqual(list(self.path.parent.glob(".settings-*")), [])
        with patch.object(pathlib.Path, "unlink", side_effect=PermissionError), self.assertRaises(RuntimeError) as raised:
            self.store.save_with_backend(self.values, apply_staged=reject_staged, expected_stamp=opened.stamp)
        self.assertIs(raised.exception, failure)

    def test_backend_is_not_called_for_conflicts_invalid_settings_or_broken_current_file(self):
        called = []
        callback = lambda _path: called.append(True)
        self.write(self.values)
        opened = self.store.load(self.values)
        with self.assertRaises(ValueError):
            self.store.save_with_backend({"live": 1}, apply_staged=callback, expected_stamp=opened.stamp)
        self.write({**self.values, "live": True})
        with self.assertRaises(ValueError):
            self.store.save_with_backend(self.values, apply_staged=callback, expected_stamp=opened.stamp)
        self.path.write_text("{")
        broken = self.store.load(self.values)
        with self.assertRaises(SettingsRecoveryRequired):
            self.store.save_with_backend(self.values, apply_staged=callback, expected_stamp=broken.stamp)
        self.assertEqual(called, [])
        self.assertEqual(self.path.read_text(), "{")

    def test_backend_recovery_preserves_original_and_restores_it_on_failure(self):
        original = b"{ synthetic broken JSON"
        self.path.write_bytes(original)
        opened = self.store.load(self.values)

        def reject_staged(_staged):
            raise RuntimeError("synthetic backend rejection")

        with self.assertRaises(RuntimeError):
            self.store.save_with_backend(self.values, apply_staged=reject_staged, expected_stamp=opened.stamp, recover=True)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(self.store.load(self.values).stamp, opened.stamp)
        self.assertEqual(list(self.path.parent.glob("settings.recovered-*")), [])
        saved = self.store.save_with_backend(
            self.values, apply_staged=lambda staged: staged.replace(self.path), expected_stamp=opened.stamp, recover=True,
        )
        self.assertEqual(saved.backup_path.read_bytes(), original)
        self.assertEqual(json.loads(self.path.read_text()), self.values)


if __name__ == "__main__":
    unittest.main()
