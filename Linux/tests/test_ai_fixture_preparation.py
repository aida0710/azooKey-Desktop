"""Safety/recovery boundaries for temporary preferences and a synthetic key."""
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import Mock
import uuid

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "Tools/tests"))
from ai_fixture_key import FixtureKey, LABEL, SERVICE
from ai_fixture_preferences import backup, restore, verify
from fixture_events import FixtureEvents


class FixtureObservationTests(unittest.TestCase):
    def test_each_trial_keeps_ordered_events_and_refuses_an_existing_log(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = pathlib.Path(temporary) / "events.jsonl"
            events = FixtureEvents(path)
            events.append("insert-text", fieldIndex=0, text="変換した本文")
            events.append("state", state={"fields": [{"text": "変換した本文"}, {"text": ""}]})
            observed = [json.loads(line) for line in path.read_text().splitlines()]
            self.assertEqual([event["sequence"] for event in observed], [1, 2])
            self.assertEqual(observed[0]["text"], "変換した本文")
            self.assertLessEqual(observed[0]["monotonicNS"], observed[1]["monotonicNS"])
            with self.assertRaises(FileExistsError):
                FixtureEvents(path)


class AIFixturePreferencesTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.directory.name)
        self.source = self.root / "preferences"
        self.source.mkdir()
        self.saved = self.root / "saved"
        self.original = b'{ "aiEnabled" : false }\n'
        (self.source / "settings.json").write_bytes(self.original)
        (self.source / "settings.json").chmod(0o640)
        (self.source / "prompts.json").write_text("[]\n")
        (self.source / "unrelated.txt").write_text("keep")

    def tearDown(self):
        self.directory.cleanup()

    def test_restoration_preserves_bytes_modes_and_original_absence(self):
        manifest = backup(self.saved, source=self.source)
        self.assertFalse(manifest["files"]["settings.last-good.json"]["existed"])
        for name in manifest["files"]:
            (self.source / name).write_text('{"fixture": true}')
        self.assertFalse(verify(self.saved)["matches"])
        self.assertTrue(restore(self.saved)["matches"])
        self.assertEqual((self.source / "settings.json").read_bytes(), self.original)
        self.assertEqual((self.source / "settings.json").stat().st_mode & 0o777, 0o640)
        self.assertFalse((self.source / "settings.last-good.json").exists())
        self.assertEqual((self.source / "unrelated.txt").read_text(), "keep")
        self.assertEqual(self.saved.stat().st_mode & 0o777, 0o700)

    def test_new_session_never_overwrites_its_original_backup(self):
        backup(self.saved, source=self.source)
        (self.source / "settings.json").write_text("changed")
        with self.assertRaises(FileExistsError):
            backup(self.saved, source=self.source)
        self.assertEqual((self.saved / "settings.json").read_bytes(), self.original)

    def test_corrupt_backup_aborts_before_changing_any_live_file(self):
        backup(self.saved, source=self.source)
        (self.source / "settings.json").write_text("current")
        (self.saved / "prompts.json").write_text("corrupt")
        with self.assertRaises(ValueError):
            restore(self.saved)
        self.assertEqual((self.source / "settings.json").read_text(), "current")

    def test_symbolic_link_is_not_followed_during_backup_or_restore(self):
        target = self.root / "outside"
        target.write_text("preserve")
        (self.source / "settings.last-good.json").symlink_to(target)
        with self.assertRaises(ValueError):
            backup(self.saved, source=self.source)
        (self.source / "settings.last-good.json").unlink()
        second = self.root / "second"
        backup(second, source=self.source)
        (self.source / "prompts.json").unlink()
        (self.source / "prompts.json").symlink_to(target)
        with self.assertRaises(ValueError):
            restore(second)
        self.assertEqual(target.read_text(), "preserve")


class AIFixtureKeyTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.path = pathlib.Path(self.directory.name) / "key-state.json"
        self.secret = Mock()
        self.secret.SearchFlags.ALL = 2
        self.secret.ServiceFlags.NONE = 0
        self.secret.COLLECTION_SESSION = "session"
        self.service = self.secret.Service.get_sync.return_value
        self.keys = FixtureKey(self.secret)

    def tearDown(self):
        self.directory.cleanup()

    def fixture_item(self, state):
        item = Mock()
        item.get_attributes.return_value = {
            "service": SERVICE, "azookey-ux-fixture": state["fixture"],
        }
        item.get_object_path.return_value = "/fixture/item1"
        item.get_label.return_value = LABEL
        item.delete_sync.return_value = True
        return item

    def test_existing_key_is_preserved_without_reading_unlocking_or_creating_a_secret(self):
        self.service.search_sync.return_value = [Mock()]
        with self.assertRaisesRegex(ValueError, "contents were not read"):
            self.keys.create(self.path)
        self.secret.password_store_sync.assert_not_called()
        self.assertFalse(self.path.exists())
        self.assertEqual(self.service.search_sync.call_args.args[2], 2)
        self.secret.password_lookup_sync.assert_not_called()

    def test_only_tagged_session_item_is_created_and_removed(self):
        item = Mock()
        item.get_object_path.return_value = "/fixture/item1"
        self.service.search_sync.side_effect = [[], [item]]
        state = self.keys.create(self.path)
        self.assertEqual(state["phase"], "created")
        self.assertEqual(self.secret.password_store_sync.call_args.args[2], "session")
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        owned = self.fixture_item(state)
        self.service.search_sync.side_effect = [[owned]]
        self.assertEqual(self.keys.remove(self.path)["phase"], "removed")
        owned.delete_sync.assert_called_once_with(None)
        self.secret.password_lookup_sync.assert_not_called()
        owned.get_secret.assert_not_called()

    def test_changed_identity_is_preserved(self):
        state = {"fixture": str(uuid.uuid4()), "phase": "created", "objectPath": "/fixture/item1"}
        self.path.write_text(json.dumps(state))
        unrelated = self.fixture_item(state)
        unrelated.get_object_path.return_value = "/different/item"
        self.service.search_sync.return_value = [unrelated]
        with self.assertRaisesRegex(RuntimeError, "preserved"):
            self.keys.remove(self.path)
        unrelated.delete_sync.assert_not_called()

    def test_interrupted_creation_can_remove_only_its_previously_recorded_tag(self):
        state = {"fixture": str(uuid.uuid4()), "phase": "creating"}
        self.path.write_text(json.dumps(state))
        owned = self.fixture_item(state)
        self.service.search_sync.return_value = [owned]
        self.keys.remove(self.path)
        owned.delete_sync.assert_called_once_with(None)


if __name__ == "__main__":
    unittest.main()
