"""Saved preferences remain intact while only the worker contract is loaded."""
from copy import deepcopy
import json
from pathlib import Path
import tempfile
import unittest

from azookey.reading_protocol import response
from azookey.reading_settings_bootstrap import ReadingSettingsBootstrap
from azookey.worker_settings import UnsupportedWorkerSettings
from worker_settings_fixture import ConfiguredReadingFixture, settings_values


class ReadingSettingsBootstrapTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "settings.json"
        self.backup = self.path.with_name("settings.last-good.json")
        self.bootstrap = ReadingSettingsBootstrap(path=self.path)

    def test_missing_file_uses_core_defaults_without_creating_settings_or_backup(self):
        defaults = settings_values(halfSpace=True, inputStyle="defaultAZIK")
        self.assertEqual(self.bootstrap.load(defaults), defaults)
        self.assertEqual(list(self.path.parent.iterdir()), [])

    def test_partial_document_preserves_defaults_and_excludes_dictionary_and_ai_connection(self):
        document = {
            "live": False, "inputStyle": "defaultAZIK",
            "userDictionary": {"items": [{"id": "7eabccba-44fe-4105-8116-43d5c61a5da5",
                                           "reading": "てすと", "word": "検査", "hint": "合成項目"}]},
            "aiModel": "fixture-model", "aiEndpoint": "http://localhost:9999", "includeContext": True,
        }
        encoded = json.dumps(document).encode()
        self.path.write_bytes(encoded)
        self.backup.write_bytes(b'{"learning":"nothing"}')
        values = self.bootstrap.load(settings_values(live=True, halfSpace=True))
        self.assertEqual(values, settings_values(halfSpace=True, inputStyle="defaultAZIK"))
        self.assertEqual(self.path.read_bytes(), encoded)
        self.assertEqual(self.backup.read_bytes(), b'{"learning":"nothing"}')
        self.assertIsNone(self.bootstrap.problem)

    def test_corrupt_document_falls_back_to_known_values_without_overwriting_either_file(self):
        self.path.write_bytes(b'{"live":false, broken')
        self.backup.write_bytes(b"existing backup")
        defaults = settings_values(learning="onlyOutput")
        self.assertEqual(self.bootstrap.load(defaults), defaults)
        self.assertIsNotNone(self.bootstrap.problem)
        self.assertEqual(self.path.read_bytes(), b'{"live":false, broken')
        self.assertEqual(self.backup.read_bytes(), b"existing backup")

    def test_unsupported_saved_settings_are_not_silently_disabled(self):
        for name in ("live", "aiEnabled", "predictiveTyping", "debug"):
            with self.subTest(setting=name):
                encoded = json.dumps({name: True}).encode()
                self.path.write_bytes(encoded)
                with self.assertRaises(UnsupportedWorkerSettings):
                    self.bootstrap.load(settings_values())
                self.assertEqual(self.path.read_bytes(), encoded)
        self.assertFalse(self.backup.exists())

    def test_corrupt_file_does_not_hide_an_unsupported_core_default(self):
        self.path.write_bytes(b"broken")
        with self.assertRaises(UnsupportedWorkerSettings):
            self.bootstrap.load(settings_values(live=True))
        self.assertEqual(self.path.read_bytes(), b"broken")

    def test_restart_uses_new_defaults_even_when_the_partial_file_did_not_change(self):
        self.path.write_text('{"live": false}')
        self.assertFalse(self.bootstrap.load(settings_values())["halfSpace"])
        self.assertTrue(self.bootstrap.load(settings_values(halfSpace=True))["halfSpace"])

    def test_invalid_or_incomplete_core_defaults_are_not_filled_from_python_guesses(self):
        self.path.write_text('{"live":false}')
        for defaults in ({}, settings_values(inferenceLimit=0), settings_values(halfSpace="true")):
            with self.subTest(defaults=defaults), self.assertRaises(ValueError):
                self.bootstrap.load(defaults)
        self.assertEqual(self.path.read_text(), '{"live":false}')


class ReadingDefaultsProtocolTests(unittest.TestCase):
    def setUp(self):
        self.reader = ConfiguredReadingFixture()
        self.hello = self.reader._respond("hello", {})

    def test_unsupported_defaults_describe_preferences_without_claiming_they_were_applied(self):
        reply = {**self.hello, "defaultSettings": settings_values(live=True, aiEnabled=True)}
        accepted = response(reply, "hello", {})
        self.assertTrue(accepted["defaultSettings"]["live"])
        self.assertNotIn("settings", accepted)

    def test_default_capture_error_is_distinct_from_a_failed_handshake(self):
        reply = {**self.hello, "defaultSettingsError": "invalid_worker_defaults"}
        self.assertEqual(response(reply, "hello", {})["readingProcessGeneration"], self.reader.generation)

    def test_defaults_cannot_include_conflicting_fields_unknown_errors_or_unvalidated_values(self):
        for fields in (
            {"defaultSettings": settings_values(), "defaultSettingsError": "invalid_worker_defaults"},
            {"defaultSettingsError": "anything"}, {"defaultSettings": settings_values(halfSpace=1)},
        ):
            with self.subTest(fields=fields), self.assertRaises(ValueError):
                response({**self.hello, **fields}, "hello", {})

    def test_configuration_ack_cannot_replace_bootstrap_defaults(self):
        values = settings_values()
        payload = {"settings": values, "settingsRevision": 0}
        reply = self.reader._respond("configure-settings", payload)
        reply["defaultSettings"] = deepcopy(values)
        with self.assertRaises(ValueError):
            response(reply, "configure-settings", payload)


if __name__ == "__main__":
    unittest.main()
