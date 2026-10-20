"""Check the service boundary with a staged store and a private bridge double."""

import copy
import json
import os
import pathlib
import sys
import tempfile
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_model import DictionarySaveError, UserDictionaryModel, save_dictionary
from azookey.user_dictionary_service import UserDictionaryService
from test_user_dictionary_model import ENTRY_ID, original_entries


class StagedStore:
    """Only the public store contract; the real store has separate lock tests."""

    def __init__(self, path, values):
        self.path = path
        self.values = copy.deepcopy(values)
        self.stamp = ("opened",)
        self.failure = None
        self.calls = []
        self.path.write_text(json.dumps(values))

    def save(self, *_arguments, **_keywords):
        raise AssertionError("the service must not save again after the backend commit")

    def save_with_backend(self, values, *, apply_staged, expected_stamp):
        self.calls.append((copy.deepcopy(values), expected_stamp))
        if self.failure:
            raise self.failure
        if expected_stamp != self.stamp:
            raise ValueError("SYNTHETIC_PRIVATE_CONFLICT")
        descriptor, filename = tempfile.mkstemp(prefix=".settings-", dir=self.path.parent)
        staged = pathlib.Path(filename)
        try:
            with os.fdopen(descriptor, "w") as stream:
                json.dump(values, stream)
                stream.flush()
                os.fsync(stream.fileno())
            apply_staged(staged)
            observed = json.loads(self.path.read_text())
            if observed != values:
                raise ValueError("backend did not install the staged values")
        finally:
            staged.unlink(missing_ok=True)
        self.values = observed
        self.stamp = ("saved", len(self.calls))
        return SimpleNamespace(values=copy.deepcopy(observed), stamp=self.stamp, backup_warning=False)


class PrivateBridge:
    def __init__(self, handler):
        self.handler = handler
        self.requests = []
        self.closed = False
        self.close_failure = None

    def request(self, operation, **payload):
        self.requests.append((operation, copy.deepcopy(payload)))
        return self.handler(operation, payload)

    def close(self):
        self.closed = True
        if self.close_failure:
            raise self.close_failure


class UserDictionaryServiceTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.values = {
            "tree": False,
            "profile": "SYNTHETIC_PRIVATE_PROFILE",
            "aiModel": "SYNTHETIC_PRIVATE_MODEL",
            "aiEndpoint": "https://example.invalid/v1?key=SYNTHETIC_PRIVATE_TOKEN",
            "userDictionary": {"items": original_entries()},
        }
        self.store = StagedStore(self.directory / "settings.json", self.values)
        self.opened = SimpleNamespace(values=copy.deepcopy(self.values), stamp=self.store.stamp)
        self.connections = []
        self.handler = self.successful_backend
        self.service = UserDictionaryService(self.store, self.opened, bridge_factory=self.create_bridge)

    def create_bridge(self):
        connection = PrivateBridge(self.handler)
        self.connections.append(connection)
        return connection

    def successful_backend(self, operation, payload):
        if operation == "dictionary-validate":
            return {"dictionaryIssues": []}
        self.assertEqual(operation, "dictionary-save")
        staged = pathlib.Path(payload["stagedSettingsPath"])
        self.assertEqual(json.loads(staged.read_text())["userDictionary"]["items"], payload["items"])
        os.replace(staged, self.store.path)
        return {"dictionarySaved": True}

    def test_validation_maps_core_reasons_and_uses_a_closed_private_connection(self):
        issue = {
            "rowID": ENTRY_ID.lower(), "field": "reading",
            "reason": "unsupportedCharacter", "characters": "A",
        }
        self.handler = lambda _operation, _payload: {"dictionaryIssues": [issue]}
        observed = self.service.validate(original_entries())
        self.assertEqual(observed[0].entry_id, ENTRY_ID.lower())
        self.assertEqual(observed[0].code, "unsupportedCharacter")
        self.assertEqual(observed[0].characters, "A")
        self.assertTrue(self.connections[0].closed)
        self.assertEqual(self.store.calls, [])
        self.assertEqual(self.connections[0].requests, [("dictionary-validate", {"items": original_entries()})])

    def test_success_sends_only_items_and_staged_path_and_never_saves_twice(self):
        items = original_entries()
        items[0]["word"] = "保存した語"
        items[0]["hint"] = "1行目\n2行目\t補足"
        self.assertEqual(self.service.validate(items), [])
        self.assertIsNone(self.service.save(items))
        self.assertEqual(len(self.connections), 2)
        self.assertIsNot(self.connections[0], self.connections[1])
        self.assertTrue(all(connection.closed for connection in self.connections))
        operation, payload = self.connections[1].requests[0]
        self.assertEqual(operation, "dictionary-save")
        self.assertEqual(set(payload), {"items", "stagedSettingsPath"})
        self.assertEqual(payload["items"], items)
        self.assertNotIn("SYNTHETIC_PRIVATE", json.dumps(payload))
        self.assertEqual(len(self.store.calls), 1)
        self.assertEqual(self.store.calls[0][1], self.opened.stamp)
        self.assertEqual(self.store.values["profile"], self.values["profile"])
        self.assertEqual(self.store.values["aiEndpoint"], self.values["aiEndpoint"])
        self.assertEqual(self.service.last_saved.values["userDictionary"]["items"], items)
        self.assertEqual(self.opened.values, self.values)
        self.assertEqual(list(self.directory.glob(".settings-*")), [])

    def test_store_failure_never_calls_the_backend_or_exposes_private_details(self):
        before = self.store.path.read_bytes()
        for failure in (OSError("SYNTHETIC_PRIVATE_DISK"), ValueError("SYNTHETIC_PRIVATE_SCHEMA")):
            with self.subTest(failure=type(failure)):
                self.store.failure = failure
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.save(original_entries())
                self.assertEqual(raised.exception.stage, "persistence")
                self.assertNotIn("SYNTHETIC_PRIVATE", str(raised.exception))
                self.assertEqual(self.connections, [])
                self.assertEqual(self.store.path.read_bytes(), before)
                self.assertIsNone(self.service.last_saved)

    def test_a_stale_dialog_does_not_overwrite_other_settings(self):
        changed = {**self.values, "tree": True}
        self.store.path.write_text(json.dumps(changed))
        self.store.stamp = ("changed-by-another-writer",)
        with self.assertRaises(DictionarySaveError):
            self.service.save(original_entries())
        self.assertEqual(json.loads(self.store.path.read_text()), changed)
        self.assertEqual(self.connections, [])
        self.assertEqual(self.store.calls[0][1], self.opened.stamp)

    def test_core_failure_preserves_old_values_and_allows_the_same_draft_to_retry(self):
        before = self.store.path.read_bytes()
        for stage in ("compile", "persistence", "activation"):
            with self.subTest(stage=stage):
                self.handler = lambda _operation, _payload: {"dictionarySaveError": stage}
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.save(original_entries())
                self.assertEqual(raised.exception.stage, stage)
                self.assertEqual(self.store.path.read_bytes(), before)
                self.assertEqual(self.store.calls[-1][1], self.opened.stamp)
                self.assertTrue(self.connections[-1].closed)
                self.assertEqual(list(self.directory.glob(".settings-*")), [])
        self.handler = self.successful_backend
        items = original_entries()
        items[0]["word"] = "再試行の語"
        self.service.save(items)
        self.assertEqual(self.service.last_saved.values["userDictionary"]["items"], items)

    def test_rollback_failure_stops_further_backend_writes(self):
        self.handler = lambda _operation, _payload: {"dictionarySaveError": "rollback"}
        with self.assertRaises(DictionarySaveError):
            self.service.save(original_entries())
        self.assertTrue(self.service.needs_recovery)
        self.handler = self.successful_backend
        with self.assertRaises(DictionarySaveError) as raised:
            self.service.save(original_entries())
        self.assertEqual(raised.exception.stage, "rollback")
        self.assertEqual(len(self.store.calls), 1)
        self.assertEqual(len(self.connections), 1)

    def test_save_time_validation_rejection_returns_row_reasons_to_the_draft(self):
        self.handler = lambda _operation, _payload: {
            "dictionaryIssues": [{
                "rowID": ENTRY_ID, "field": "reading", "reason": "unsupportedCharacter", "characters": "A",
            }],
        }
        model = UserDictionaryModel(original_entries())
        model.update(ENTRY_ID, reading="A")
        request = model.begin_save()
        outcome = save_dictionary(request, validate=lambda _entries: [], save=self.service.save)
        model.finish_save(request, outcome)
        self.assertFalse(outcome.saved)
        self.assertEqual(model.issues_for(ENTRY_ID)[0].code, "unsupportedCharacter")
        self.assertEqual(model.entry(ENTRY_ID)["reading"], "A")
        self.assertTrue(model.has_changes)

    def test_missing_or_malformed_success_cannot_complete_a_save(self):
        replies = [
            {}, {"dictionarySaved": False}, {"dictionarySaved": 1},
            {"dictionarySaved": True, "dictionaryIssues": None},
            {"dictionarySaved": True, "error": "SYNTHETIC_PRIVATE_ERROR"},
            {"dictionarySaved": True, "error": []},
            {"dictionarySaveError": ["SYNTHETIC_PRIVATE_ERROR"]},
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                self.handler = lambda _operation, _payload: reply
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.save(original_entries())
                self.assertNotIn("SYNTHETIC_PRIVATE", str(raised.exception))
                self.assertIsNone(self.service.last_saved)
                self.assertTrue(self.connections[-1].closed)

    def test_validation_does_not_treat_bad_shapes_or_transport_errors_as_valid(self):
        replies = [
            {}, {"dictionaryIssues": None}, {"dictionaryIssues": [None]},
            {"dictionaryIssues": [], "error": ""},
            {"dictionaryIssues": [{"rowID": ENTRY_ID}]}, {"error": "SYNTHETIC_PRIVATE_ERROR"},
        ]
        for reply in replies:
            with self.subTest(reply=reply):
                self.handler = lambda _operation, _payload: reply
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.validate(original_entries())
                self.assertEqual(raised.exception.stage, "validation")
                self.assertTrue(self.connections[-1].closed)

        def disconnected(_operation, _payload):
            raise RuntimeError("SYNTHETIC_PRIVATE_TRANSPORT")

        self.handler = disconnected
        with self.assertRaises(DictionarySaveError) as raised:
            self.service.validate(original_entries())
        self.assertNotIn("SYNTHETIC_PRIVATE", str(raised.exception))
        self.assertTrue(self.connections[-1].closed)

    def test_connection_cleanup_failure_does_not_repeat_an_acknowledged_commit(self):
        def create_bridge():
            connection = self.create_bridge()
            connection.close_failure = OSError("SYNTHETIC_PRIVATE_CLOSE")
            return connection

        service = UserDictionaryService(self.store, self.opened, bridge_factory=create_bridge)
        service.save(original_entries())
        self.assertEqual(len(self.store.calls), 1)
        self.assertIsNotNone(service.last_saved)

    def test_a_second_explicit_save_uses_the_successful_stamp(self):
        self.service.save(original_entries())
        saved_stamp = self.service.last_saved.stamp
        items = original_entries()
        items[0]["word"] = "次の保存"
        self.service.save(items)
        self.assertEqual(self.store.calls[-1][1], saved_stamp)
        self.assertEqual(self.store.values["userDictionary"]["items"], items)


if __name__ == "__main__":
    unittest.main()
