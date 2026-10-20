"""Run only in a disposable container with /opt populated from the test package."""
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[2] / "Tools/tests"))
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from ai_fixture_preferences import backup, verify
from ai_fixture_restore import restore_settings
from ai_mock_server import LocalAIServer
from Linux.tests.ai_restore_engine_fixture import SettingsRuntime


@unittest.skipUnless(os.environ.get("AZOOKEY_TEST_INSTALLED_SETTINGS") == "1",
                     "disposable installed-package container required")
class InstalledAIFixtureSettingsTests(unittest.TestCase):
    def test_restore_recovers_original_bytes_and_rejects_corruption_before_changing_core(self):
        sys.path.insert(0, "/opt/azookey-tree")
        from azookey.bridge import Bridge
        command = pathlib.Path(__file__).resolve().parents[2] / "Tools/tests/ai_fixture_settings.py"
        with tempfile.TemporaryDirectory() as temporary, LocalAIServer() as server:
            root = pathlib.Path(temporary)
            environment = {
                **os.environ, "XDG_CONFIG_HOME": str(root / "config"),
                "XDG_DATA_HOME": str(root / "data"), "LD_LIBRARY_PATH": "/opt/azookey-tree/libexec",
            }
            bridge = Bridge("/opt/azookey-tree/libexec/azookey-desktop-bridge", environment=environment)
            try:
                original = bridge.request("settings")["settings"]
            finally:
                bridge.close()
            original.update(aiEnabled=False, includeContext=True, live=False, candidateTextSize="large")
            source = root / "config/azookey-tree"
            source.mkdir(parents=True)
            original_bytes = (json.dumps(original, ensure_ascii=False, indent=2) + "\n").encode()
            (source / "settings.json").write_bytes(original_bytes)
            (source / "settings.json").chmod(0o600)
            (source / "prompts.json").write_text("[]\n")
            saved = root / "original"
            backup(saved, source=source)
            server_state = root / "server.json"
            server_state.write_text(json.dumps({"endpoint": server.endpoint, "model": "fixture-model"}))
            applied = subprocess.run(
                [sys.executable, str(command), "apply", "--directory", str(saved),
                 "--server-state", str(server_state)], env=environment, capture_output=True, text=True, check=True,
            )
            self.assertEqual(json.loads(applied.stdout)["applied"]["aiEndpoint"], server.endpoint)
            active = json.loads((source / "settings.json").read_text())
            self.assertTrue(active["aiEnabled"])
            self.assertFalse(active["includeContext"])
            self.assertFalse(active["live"])
            self.assertEqual(active["candidateTextSize"], "large")
            bridge = Bridge("/opt/azookey-tree/libexec/azookey-desktop-bridge", environment=environment)
            try:
                self.assertNotIn("error", bridge.request("configure", settings=active))
            finally:
                bridge.close()
            # A damaged saved file must not partially restore Core while the
            # live JSON still contains the mock endpoint.
            saved_prompt_bytes = (saved / "prompts.json").read_bytes()
            (saved / "prompts.json").write_text("damaged")
            refused = subprocess.run(
                [sys.executable, str(command), "restore", "--directory", str(saved)],
                env=environment, capture_output=True, text=True,
            )
            self.assertNotEqual(refused.returncode, 0)
            bridge = Bridge("/opt/azookey-tree/libexec/azookey-desktop-bridge", environment=environment)
            try:
                self.assertEqual(bridge.request("settings")["settings"], active)
            finally:
                bridge.close()
            (saved / "prompts.json").write_bytes(saved_prompt_bytes)
            def bridge_factory():
                return Bridge("/opt/azookey-tree/libexec/azookey-desktop-bridge", environment=environment)
            runtime = SettingsRuntime(source / "settings.json", bridge_factory=bridge_factory, active_settings=active)
            restored = restore_settings(saved, settings_path=source / "settings.json",
                                        bridge_factory=bridge_factory, runtime=runtime)
            self.assertTrue(restored["matches"])
            self.assertEqual(runtime.active_settings, original)
            self.assertEqual((source / "settings.json").read_bytes(), original_bytes)
            self.assertTrue(verify(saved)["matches"])
            bridge = Bridge("/opt/azookey-tree/libexec/azookey-desktop-bridge", environment=environment)
            try:
                self.assertEqual(bridge.request("settings")["settings"], original)
            finally:
                bridge.close()


if __name__ == "__main__":
    unittest.main()
