"""Synthetic documents and candidate batches for the explicit reading JSONL contract."""
import os
from pathlib import Path
import sys
import tempfile
import unittest
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Detect a stuck fixture; this is not an input-to-paint performance budget.
REQUEST_TIMEOUT_SECONDS = 5


@unittest.skipUnless(sys.platform == "linux" and os.environ.get("AZOOKEY_BRIDGE"),
                     "requires the real Linux Swift bridge")
class ReadingWorkerCase(unittest.TestCase):
    def setUp(self):
        from azookey.bridge import Bridge

        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.directory = Path(directory.name)
        # Reading must work without a writable converter memory path or model files.
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
        hello = self.request("hello")
        self.process_generation = hello["readingProcessGeneration"]
        self.limits = hello["limits"]
        self.reference = self.open("field")
        self.focus()

    def request(self, operation, **payload):
        reply = self.bridge.request(operation, **payload)
        self.assertEqual("snapshot" in reply, reply["kind"] == "input", reply)
        if reply["kind"] == "input":
            self.assertEqual(reply["reference"], payload["reference"])
        if operation != "focus-out" or reply["kind"] == "error":
            self.assertNotIn("nextReference", reply)
        for field in ("preedit", "commits", "cursor", "inputState"):
            self.assertNotIn(field, reply)
        return reply

    def open(self, context):
        reply = self.request("open", readingProcessGeneration=self.process_generation, context=context)
        self.assertEqual(reply["kind"], "acknowledgement", reply)
        return reply["reference"]

    def focus(self, *, private=False, left="", right=""):
        reply = self.request("focus-in", reference=self.reference,
                             surroundings={"privateInput": private, "leftContext": left, "rightContext": right})
        self.assertEqual(reply["kind"], "acknowledgement", reply)
        self.reference = reply["reference"]

    def focus_out(self, *, submit):
        reply = self.request("focus-out", reference=self.reference, submit=submit)
        self.assertEqual(reply["kind"], "input", reply)
        self.assertGreater(reply["nextReference"]["focusEpoch"], self.reference["focusEpoch"])
        self.reference = reply["nextReference"]
        return reply["snapshot"]

    def snapshot(self):
        reply = self.request("snapshot", reference=self.reference)
        self.assertEqual(reply["kind"], "input", reply)
        return reply["snapshot"]

    def key(self, keyval, *, modifiers=0):
        from azookey.keymap import translate

        return self.request("key", reference=self.reference, event=translate(keyval, modifiers))

    def type(self, text):
        snapshot = self.snapshot()
        for character in text:
            reply = self.key(ord(character))
            self.assertEqual(reply["kind"], "input", reply)
            snapshot = reply["snapshot"]
        return snapshot

    def prepare(self, *, worker="converter"):
        reply = self.request("prepare-candidates", reference=self.reference, candidateWorkerGeneration=worker)
        self.assertEqual(reply["kind"], "candidates", reply)
        return reply["candidateRequest"]

    def batch(self, *, text="日本語", count=None, worker="converter"):
        request = self.prepare(worker=worker)
        count = len(request["composition"]["input"]) if count is None else count
        # These explicit test candidates never enter the ordinary converter or learning store.
        return {"authority": request["authority"], "workerGeneration": worker,
                "batchID": str(uuid.uuid4()), "candidates": [{
                    "candidateID": "candidate", "text": text,
                    "composingCount": {"kind": "inputCount", "count": count},
                    "presentation": {"tokens": [], "extraValues": {}}}]}

    @staticmethod
    def batch_reference(batch):
        return {field: batch[field] for field in ("authority", "workerGeneration", "batchID")}

    def adopt(self, batch):
        return self.request("adopt-candidates", reference=self.reference, batch=batch,
                            retainedReference=self.batch_reference(batch))

    def select(self, batch):
        return self.request("select", reference=self.reference,
                            selection={"batch": self.batch_reference(batch),
                                       "candidateID": batch["candidates"][0]["candidateID"]})

    def assert_rejected_without_edit(self, operation, *, error=None, **payload):
        before = self.snapshot()
        reply = self.request(operation, **payload)
        self.assertEqual(reply["kind"], "error", reply)
        if error is not None:
            self.assertEqual(reply["error"], error)
        self.assertEqual(self.snapshot(), before)
        return reply
