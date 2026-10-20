"""Learning permission is checked when an existing candidate is committed."""
import os
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "requires the Swift bridge")
class LearningModeChangeTests(unittest.TestCase):
    def create_bridge(self):
        directory = tempfile.TemporaryDirectory(prefix="azookey-learning-mode-")
        self.addCleanup(directory.cleanup)
        root = Path(directory.name)
        environment = {**os.environ, "AZOOKEY_DATA_DIR": str(root / "data"),
                       "XDG_CONFIG_HOME": str(root / "config")}
        # These cases isolate history permissions from neural-model ranking.
        environment.pop("AZOOKEY_RESOURCES", None)
        bridge = Bridge(environment=environment)
        self.addCleanup(bridge.close)
        return bridge, root / "data/memory"

    def request(self, bridge, operation, **payload):
        snapshot = bridge.request(operation, **payload)
        self.assertNotIn("error", snapshot)
        return snapshot

    def select_candidate(self, bridge, reading, word):
        for character in reading:
            self.request(bridge, "key", event=translate(ord(character), 0))
        self.request(bridge, "key", event=translate(32, 0))
        snapshot = self.request(bridge, "key", event=translate(32, 0))
        index = next(item["index"] for item in snapshot["candidates"] if item["text"] == word)
        return self.request(bridge, "select", index=index, generation=snapshot["generation"], submit=False)

    def configure(self, bridge, mode):
        settings = self.request(bridge, "settings")["settings"]
        return self.request(bridge, "configure", settings={**settings, "learning": mode, "live": False})

    @staticmethod
    def memory_bytes(directory):
        return {path.name: path.read_bytes() for path in directory.glob("memory*") if path.is_file()}

    def test_changing_learning_before_enter_uses_the_new_mode_without_replacing_the_candidate(self):
        modes = ("inputAndOutput", "onlyOutput", "nothing")
        for before in modes:
            for after in modes:
                with self.subTest(before=before, after=after):
                    bridge, memory = self.create_bridge()
                    self.configure(bridge, before)
                    selected = self.select_candidate(bridge, "kyou", "京")
                    configured = self.configure(bridge, after)
                    for key in ("reading", "preedit", "candidates", "selection", "generation"):
                        self.assertEqual(configured[key], selected[key], key)
                    committed = self.request(bridge, "key", event=translate(0xFF0D, 0))
                    self.assertEqual(committed["commits"], ["京"])
                    self.assertEqual(committed["reading"], "")
                    self.request(bridge, "close")
                    bridge.close()
                    self.assertEqual(bool(self.memory_bytes(memory)), after == "inputAndOutput")

    def test_enabling_learning_does_not_override_private_input_at_commit(self):
        bridge, memory = self.create_bridge()
        self.configure(bridge, "nothing")
        self.select_candidate(bridge, "kyou", "京")
        self.configure(bridge, "inputAndOutput")
        committed = self.request(bridge, "key", event=translate(0xFF0D, 0), privateInput=True)
        self.assertEqual(committed["commits"], ["京"])
        self.request(bridge, "close")
        bridge.close()
        self.assertEqual(self.memory_bytes(memory), {})

    def test_another_private_context_does_not_disable_learning_for_the_original_public_candidate(self):
        bridge, memory = self.create_bridge()
        self.configure(bridge, "inputAndOutput")
        selected = self.select_candidate(bridge, "kyou", "京")
        self.request(bridge, "key", context="private-field", privateInput=True, event=translate(ord("a"), 0))
        restored = self.request(bridge, "snapshot")
        self.assertEqual(restored["reading"], selected["reading"])
        self.assertEqual(restored["preedit"], selected["preedit"])
        committed = self.request(bridge, "key", event=translate(0xFF0D, 0))
        self.assertEqual(committed["commits"], ["京"])
        self.request(bridge, "close")
        bridge.close()
        self.assertTrue(self.memory_bytes(memory))

    def test_stopping_updates_preserves_history_saved_before_the_change(self):
        for mode in ("onlyOutput", "nothing"):
            with self.subTest(mode=mode):
                bridge, memory = self.create_bridge()
                self.configure(bridge, "inputAndOutput")
                self.select_candidate(bridge, "kyou", "京")
                self.request(bridge, "key", event=translate(0xFF0D, 0))
                saved = self.memory_bytes(memory)
                self.assertTrue(saved)
                self.select_candidate(bridge, "hashi", "橋")
                self.configure(bridge, mode)
                committed = self.request(bridge, "key", event=translate(0xFF0D, 0))
                self.assertEqual(committed["commits"], ["橋"])
                self.request(bridge, "close")
                bridge.close()
                self.assertEqual(self.memory_bytes(memory), saved)


if __name__ == "__main__":
    unittest.main()
