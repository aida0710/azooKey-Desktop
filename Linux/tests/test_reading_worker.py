"""The explicit reading process must remain independent of converter work."""
import os
from pathlib import Path
import signal
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# This detects a stuck fixture; it is not the input-to-paint performance budget.
REQUEST_TIMEOUT_SECONDS = 5


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real Linux Swift bridge")
class ReadingWorkerTests(unittest.TestCase):
    def setUp(self):
        from azookey.bridge import Bridge

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        # A converter session cannot create its memory directory below a regular file.
        self.blocked_data_path = self.directory / "reading-data-is-a-file"
        self.blocked_data_path.write_text("do not replace\n")
        self.environment = {
            **os.environ,
            "AZOOKEY_BRIDGE_ROLE": "reading",
            "AZOOKEY_DATA_DIR": str(self.blocked_data_path),
            "AZOOKEY_RESOURCES": str(self.directory / "absent-models"),
            "XDG_CONFIG_HOME": str(self.directory / "config"),
        }
        self.bridge = Bridge(timeout=REQUEST_TIMEOUT_SECONDS, environment=self.environment)
        self.addCleanup(self.bridge.close)

    def key(self, keyval, *, context="field"):
        from azookey.keymap import translate

        return self.bridge.request("key", context=context, event=translate(keyval, 0))

    def type(self, text, *, context="field"):
        snapshot = self.bridge.request("snapshot", context=context)
        for character in text:
            snapshot = self.key(ord(character), context=context)
        return snapshot

    def test_reading_edit_and_enter_work_while_the_separate_converter_process_is_stopped(self):
        from azookey.bridge import Bridge

        converter_environment = {
            **self.environment,
            "AZOOKEY_DATA_DIR": str(self.directory / "converter"),
        }
        converter_environment.pop("AZOOKEY_BRIDGE_ROLE")
        converter = Bridge(timeout=REQUEST_TIMEOUT_SECONDS, environment=converter_environment)
        try:
            converter.request("snapshot")
            self.assertNotEqual(converter.process.pid, self.bridge.process.pid)
            os.kill(converter.process.pid, signal.SIGSTOP)
            stopped_pid, status = os.waitpid(converter.process.pid, os.WUNTRACED)
            self.assertEqual(stopped_pid, converter.process.pid)
            self.assertTrue(os.WIFSTOPPED(status))
            self.assertEqual(self.type("nihongo")["preedit"], "にほんご")
            self.assertEqual(self.key(0xFF51)["cursor"], 3)
            self.assertEqual(self.type("a")["preedit"], "にほんあご")
            self.assertEqual(self.key(0xFF08)["preedit"], "にほんご")
            self.assertEqual(self.key(0xFFFF)["preedit"], "にほん")
            committed = self.key(0xFF0D)
            self.assertEqual(committed["commits"], ["にほん"])
            self.assertEqual(committed["preedit"], "")
            self.assertEqual(self.type("a")["preedit"], "あ")
            self.assertEqual(self.key(0xFF1B)["preedit"], "")
            self.assertIsNone(converter.process.poll())
            process_status = Path(f"/proc/{converter.process.pid}/status").read_text()
            self.assertRegex(process_status, r"(?m)^State:\s+T\b")
        finally:
            if converter.process.poll() is None:
                os.kill(converter.process.pid, signal.SIGCONT)
            converter.close()
        self.assertEqual(self.blocked_data_path.read_text(), "do not replace\n")
        mappings = Path(f"/proc/{self.bridge.process.pid}/maps").read_text()
        for suffix in (".gguf", ".louds", ".loudstxt", ".marisa"):
            self.assertNotIn(suffix, mappings)
        self.assertFalse(self.bridge.request("snapshot")["zenzaiLoaded"])

    def test_rejected_actions_and_other_contexts_do_not_discard_the_active_reading(self):
        self.assertEqual(self.type("nihongo")["preedit"], "にほんご")
        before = self.key(0xFF51)
        rejected = self.key(0xFF09)
        self.assertEqual(rejected["error"], "unsupported_reading_action")
        self.assertFalse(rejected["consumed"])
        for field in ("reading", "preedit", "cursor", "generation", "inputState"):
            self.assertEqual(rejected[field], before[field], field)
        self.assertEqual(rejected["commits"], [])
        self.assertEqual(self.type("a", context="second")["preedit"], "あ")
        self.assertEqual(self.type("a")["preedit"], "にほんあご")
        committed = self.key(0xFF8D)
        self.assertEqual(committed["commits"], ["にほんあご"])
        self.assertEqual(self.bridge.request("snapshot", context="second")["preedit"], "あ")
        self.bridge.request("close", context="second")
        self.assertEqual(self.bridge.request("snapshot", context="second")["preedit"], "")


if __name__ == "__main__":
    unittest.main()
