"""Restoration must finish after a fresh engine has acknowledged its settings."""
import copy
import hashlib
import json
import pathlib
import sys
import tempfile
import unittest
from unittest.mock import Mock

ROOT = pathlib.Path(__file__).parents[2]
sys.path[:0] = [str(ROOT / "Linux"), str(ROOT / "Tools/tests")]
from ai_fixture_preferences import backup, verify
from ai_fixture_restore import restore_settings
from azookey.settings_schema import INPUT_DEFAULTS
from azookey.settings_store import SettingsStore
from Linux.tests.ai_restore_engine_fixture import SettingsRuntime


class AIFixtureRestoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.temporary.name)
        self.source = self.root / "preferences"
        self.source.mkdir()
        self.saved = self.root / "original"
        self.original = {
            **INPUT_DEFAULTS, "live": False, "aiEnabled": False, "aiModel": "original-model",
            "aiEndpoint": "https://original.invalid/v1", "includeContext": True,
        }
        self.persistent = copy.deepcopy(self.original)
        self.configure_count = 0

    def tearDown(self):
        self.temporary.cleanup()

    def prepare(self, shape, *, existing_last_good):
        if shape != "absent":
            document = {"live": False} if shape == "partial" else self.original
            (self.source / "settings.json").write_text(json.dumps(document, indent=2))
        if existing_last_good:
            (self.source / "settings.last-good.json").write_bytes(b'{ "live": false }\n')
        backup(self.saved, source=self.source)
        original_bytes = json.dumps(self.original).encode()
        (self.saved / "original-effective-settings.json").write_bytes(original_bytes)
        (self.saved / "original-effective-settings.sha256").write_text(hashlib.sha256(original_bytes).hexdigest())
        active = SettingsStore(self.source / "settings.json").update(
            {"aiEnabled": True, "aiEndpoint": "http://127.0.0.1:34001/v1/chat/completions",
             "aiModel": "fixture-model", "includeContext": False}, defaults=self.original,
        ).values
        self.persistent = copy.deepcopy(active)
        return SettingsRuntime(self.source / "settings.json", bridge_factory=self.bridge, active_settings=active)

    def bridge(self):
        owner = self

        class Bridge:
            def request(self, operation, **payload):
                if operation == "configure":
                    owner.configure_count += 1
                    owner.persistent = copy.deepcopy(payload["settings"])
                return {"settings": copy.deepcopy(owner.persistent)}

            def close(self):
                pass
        return Bridge()

    def test_absent_partial_and_complete_documents_restore_after_engine_startup(self):
        for shape in ("absent", "partial", "complete"):
            for existing_last_good in (False, True):
                with self.subTest(shape=shape, existing_last_good=existing_last_good):
                    self.tearDown()
                    self.setUp()
                    runtime = self.prepare(shape, existing_last_good=existing_last_good)
                    self.assertTrue(runtime.active_settings["aiEnabled"])
                    outcome = restore_settings(
                        self.saved, settings_path=self.source / "settings.json",
                        bridge_factory=self.bridge, runtime=runtime,
                    )
                    self.assertTrue(outcome["matches"])
                    self.assertTrue(outcome["startupAcknowledged"])
                    self.assertEqual(runtime.active_settings, self.original)
                    self.assertEqual(self.persistent, self.original)
                    runtime.engine.reload_settings()
                    self.assertFalse(runtime.pending)
                    self.assertTrue(verify(self.saved)["matches"])
                    phases = [json.loads(line)["phase"] for line in (self.saved / "restoration.jsonl").read_text().splitlines()]
                    self.assertEqual(phases[-1], "complete")

    def test_another_config_directory_is_rejected_before_stop_or_core_io(self):
        runtime = self.prepare("partial", existing_last_good=False)
        runtime.stop = Mock()
        bridge_factory = Mock()
        with self.assertRaisesRegex(ValueError, "different preferences"):
            restore_settings(self.saved, settings_path=self.root / "other/settings.json",
                             bridge_factory=bridge_factory, runtime=runtime)
        runtime.stop.assert_not_called()
        bridge_factory.assert_not_called()
        self.assertEqual(self.configure_count, 0)

    def test_a_corrupt_backup_is_rejected_before_stop_or_core_io(self):
        runtime = self.prepare("partial", existing_last_good=False)
        (self.saved / "settings.json").write_text("damaged")
        runtime.stop = Mock()
        bridge_factory = Mock()
        with self.assertRaisesRegex(ValueError, "saved bytes changed"):
            restore_settings(self.saved, settings_path=self.source / "settings.json",
                             bridge_factory=bridge_factory, runtime=runtime)
        runtime.stop.assert_not_called()
        bridge_factory.assert_not_called()

    def test_no_startup_acknowledgement_is_never_reported_as_complete(self):
        runtime = self.prepare("complete", existing_last_good=False)
        runtime.restart = Mock(side_effect=RuntimeError("missing settings acknowledgement"))
        with self.assertRaisesRegex(RuntimeError, "missing settings"):
            restore_settings(self.saved, settings_path=self.source / "settings.json",
                             bridge_factory=self.bridge, runtime=runtime)
        phases = [json.loads(line)["phase"] for line in (self.saved / "restoration.jsonl").read_text().splitlines()]
        self.assertNotIn("complete", phases)


if __name__ == "__main__":
    unittest.main()
