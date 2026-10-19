import os
import pathlib
import sys
import unittest
import tempfile
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge
from azookey.keymap import translate


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "build the real Swift bridge first")
class BridgeIntegrationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.old = os.environ.get("AZOOKEY_DATA_DIR")
        os.environ["AZOOKEY_DATA_DIR"] = self.directory.name
        self.bridge = Bridge()

    def tearDown(self):
        self.bridge.close()
        if self.old is None:
            os.environ.pop("AZOOKEY_DATA_DIR", None)
        else:
            os.environ["AZOOKEY_DATA_DIR"] = self.old
        self.directory.cleanup()

    def test_protocol_real_conversion_and_stale_generation(self):
        for character in "nihongo":
            self.bridge.request("key", event=translate(ord(character), 0))
        result = self.bridge.request("key", event=translate(32, 0))
        candidate = next(item for item in result["candidates"] if item["text"] == "日本語")
        stale = self.bridge.request("select", index=candidate["index"], generation=result["generation"] - 1, submit=True)
        self.assertEqual(stale["commits"], [])
        selected = self.bridge.request("select", index=candidate["index"], generation=result["generation"], submit=True)
        self.assertEqual(selected["commits"], ["日本語"])
        self.assertEqual(selected["preedit"], "")

    def test_invalid_request_does_not_crash(self):
        self.assertEqual(self.bridge.request("not-an-operation")["error"], "invalid_request")
        self.assertEqual(self.bridge.request("snapshot")["preedit"], "")


if __name__ == "__main__":
    unittest.main()
