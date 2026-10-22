"""Shared isolated settings and three real workers for dictionary behavior."""
import json
from pathlib import Path

from azookey.bridge import Bridge
from candidate_fixture import Gate, WAIT_SECONDS
from reading_process_fixture import ReadingProcessTestCase
from worker_settings_fixture import settings_values


class ReadingDictionaryProcessTestCase(ReadingProcessTestCase):
    def prepare_worker_settings(self):
        self.environment.pop("AZOOKEY_RESOURCES", None)
        return {"settings": settings_values(learning="nothing")}

    def setUp(self):
        super().setUp()
        environment = dict(self.environment)
        environment.pop("AZOOKEY_BRIDGE_ROLE", None)
        self.writer = Bridge(environment=environment, timeout=WAIT_SECONDS)
        self.addCleanup(self.writer.close)
        self.item = {"id": "a0000001-abcd-1234-abcd-123456789abc", "word": "独立候補甲",
                     "reading": "あいだ", "hint": "捕捉済みヒント"}
        self.save(self.item)

    @property
    def agreement(self):
        return self.coordinator._settings_agreement

    def save(self, item, *, succeeds=True):
        settings = Path(self.environment["XDG_CONFIG_HOME"]) / "azookey-tree/settings.json"
        settings.parent.mkdir(parents=True, exist_ok=True)
        stage = settings.parent / ".settings-dictionary-test.json"
        stage.write_text(json.dumps({"userDictionary": {"items": [item]}, "syntheticPreserved": True}))
        response = self.writer.request("dictionary-save", items=[item], stagedSettingsPath=str(stage))
        self.assertNotIn("error", response)
        self.assertIs(response["dictionarySaved"], succeeds)
        stage.unlink(missing_ok=True)
        return response

    def prepare(self):
        self.coordinator.refresh_dictionary()
        self.drain_until(lambda: not self.coordinator._dictionary.pending)
        return self.agreement.prepared_dictionary[1]

    def blur(self):
        token = object()
        self.coordinator.focus_out("field", submit=False, token=token, finish=self.finish)
        self.drain_until(lambda: any(owner is token for owner, _ in self.finished))

    def agreed(self):
        self.drain_until(lambda: self.agreement.reader is not None
                         and self.agreement.reader.get("dictionaryRevision") is not None
                         and self.agreement.confirmed_identity is not None)

    def current_batch(self, text):
        count = len(self.panels)
        self.type(text)
        self.key(0x20)
        self.drain_until(lambda: len(self.panels) > count)
        batch = self.panels[-1].batch
        self.assertIn(self.item["word"], [candidate["text"] for candidate in batch["candidates"]])
        return batch

    def inverse(self, batch):
        replies = []
        self.coordinator.candidates.resolve_reconversion_reading(
            {"authority": batch["authority"], "workerGeneration": batch["workerGeneration"],
             "text": self.item["word"], "privateInput": False}, replies.append,
        )
        self.drain_until(lambda: replies)
        self.assertIsNone(replies[0].error)
        return replies[0].reconversion_reading["reading"]

    def hold_request(self, role, operation):
        bridge = self.bridges[role]
        request = bridge.request
        gate = Gate()

        def held_request(name, **payload):
            if name == operation:
                gate.entered.set()
                if not gate.proceed.wait(WAIT_SECONDS):
                    raise RuntimeError("dictionary process fixture was not released")
            # The gate delays a real request; it never supplies an acknowledgement.
            return request(name, **payload)

        bridge.request = held_request
        self.addCleanup(setattr, bridge, "request", request)
        self.addCleanup(gate.proceed.set)
        return gate
