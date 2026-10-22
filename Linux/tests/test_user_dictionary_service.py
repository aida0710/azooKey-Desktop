"""Check the service boundary with a private bridge double that answers like Core."""

import copy
import json
import pathlib
import sys
from types import SimpleNamespace
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from azookey.user_dictionary_model import DictionarySaveError, UserDictionaryModel, save_dictionary
from azookey.user_dictionary_service import UserDictionaryService
from test_user_dictionary_model import ENTRY_ID, original_entries


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


def saved_reply(values, stamp):
    return {
        "dictionarySaved": True, "settings": values,
        "settingsResult": {"file": {"path": "/synthetic/settings.json", "stamp": stamp, "exists": True},
                           "saved": {"lastGoodSaved": True}},
    }


def refused_reply(code):
    return {
        "dictionarySaved": False, "dictionarySaveError": "persistence",
        "settingsResult": {"error": {"code": code, "message": "settings." + code, "arguments": {}}},
    }


class UserDictionaryServiceTests(unittest.TestCase):
    def setUp(self):
        self.values = {
            "tree": False,
            "profile": "SYNTHETIC_PRIVATE_PROFILE",
            "aiModel": "SYNTHETIC_PRIVATE_MODEL",
            "aiEndpoint": "https://example.invalid/v1?key=SYNTHETIC_PRIVATE_TOKEN",
            "userDictionary": {"items": original_entries()},
        }
        # Core owns the file; this double keeps only the stamp it would check.
        self.core_stamp = "opened"
        self.opened = SimpleNamespace(values=copy.deepcopy(self.values), stamp=self.core_stamp)
        self.connections = []
        self.handler = self.successful_backend
        self.service = UserDictionaryService(self.opened, bridge_factory=self.create_bridge)

    def create_bridge(self):
        connection = PrivateBridge(self.handler)
        self.connections.append(connection)
        return connection

    def saves(self):
        return [payload for connection in self.connections
                for operation, payload in connection.requests if operation == "dictionary-save"]

    def successful_backend(self, operation, payload):
        if operation == "dictionary-validate":
            return {"dictionaryIssues": []}
        self.assertEqual(operation, "dictionary-save")
        if payload["settingsFile"]["expectedStamp"] != self.core_stamp:
            return refused_reply("changed")
        self.core_stamp = f"saved-{len(self.saves())}"
        return saved_reply({**self.values, "userDictionary": {"items": payload["items"]}}, self.core_stamp)

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
        self.assertEqual(self.saves(), [])
        self.assertEqual(self.connections[0].requests, [("dictionary-validate", {"items": original_entries()})])

    def test_success_sends_only_items_and_the_opened_stamp_and_follows_the_new_stamp(self):
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
        self.assertEqual(payload, {"items": items, "settingsFile": {"expectedStamp": "opened"}})
        self.assertNotIn("SYNTHETIC_PRIVATE", json.dumps(payload))
        self.assertEqual(self.service.last_saved.values["userDictionary"]["items"], items)
        self.assertEqual(self.service.last_saved.stamp, "saved-1")
        self.assertFalse(self.service.last_saved.backup_warning)
        self.assertEqual(self.opened.values, self.values)
        self.service.save(original_entries())
        self.assertEqual(self.saves()[-1]["settingsFile"], {"expectedStamp": "saved-1"})

    def test_core_refusing_the_settings_file_is_a_persistence_failure_without_private_details(self):
        for code in ("busy", "recoveryRequired", "writeFailed"):
            with self.subTest(code=code):
                self.handler = lambda _operation, _payload: refused_reply(code)
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.save(original_entries())
                self.assertEqual(raised.exception.stage, "persistence")
                self.assertNotIn("SYNTHETIC_PRIVATE", str(raised.exception))
                self.assertIsNone(self.service.last_saved)

    def test_a_stale_dialog_does_not_overwrite_other_settings(self):
        self.core_stamp = "changed-by-another-writer"
        with self.assertRaises(DictionarySaveError) as raised:
            self.service.save(original_entries())
        self.assertEqual(raised.exception.stage, "persistence")
        self.assertEqual(self.saves()[0]["settingsFile"], {"expectedStamp": "opened"})
        self.assertIsNone(self.service.last_saved)

    def test_core_failure_preserves_old_values_and_allows_the_same_draft_to_retry(self):
        for stage in ("compile", "persistence", "activation"):
            with self.subTest(stage=stage):
                self.handler = lambda _operation, _payload: {"dictionarySaveError": stage}
                with self.assertRaises(DictionarySaveError) as raised:
                    self.service.save(original_entries())
                self.assertEqual(raised.exception.stage, stage)
                self.assertEqual(self.saves()[-1]["settingsFile"], {"expectedStamp": "opened"})
                self.assertTrue(self.connections[-1].closed)
                self.assertIsNone(self.service.last_saved)
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
        self.assertEqual(len(self.saves()), 1)
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
            {}, {"dictionarySaved": False}, {"dictionarySaved": 1}, {"dictionarySaved": True},
            {"dictionarySaved": True, "settings": {}, "settingsResult": {"file": {}}},
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

        service = UserDictionaryService(self.opened, bridge_factory=create_bridge)
        service.save(original_entries())
        self.assertEqual(len(self.saves()), 1)
        self.assertIsNotNone(service.last_saved)

    def test_a_second_explicit_save_uses_the_successful_stamp(self):
        self.service.save(original_entries())
        saved_stamp = self.service.last_saved.stamp
        items = original_entries()
        items[0]["word"] = "次の保存"
        self.service.save(items)
        self.assertEqual(self.saves()[-1]["settingsFile"], {"expectedStamp": saved_stamp})
        self.assertEqual(self.service.last_saved.values["userDictionary"]["items"], items)


if __name__ == "__main__":
    unittest.main()
