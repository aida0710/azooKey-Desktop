"""Scripted replacement replies for testing ownership, not Core conversion."""
from collections import defaultdict, deque
from copy import deepcopy

from candidate_fixture import CandidateBridgeFixture
from reading_coordinator_fixture import ReadingBridgeFixture


class ReconversionReaderFixture(ReadingBridgeFixture):
    def __init__(self):
        super().__init__()
        self.reconversion_replies = defaultdict(deque)

    def _respond(self, operation, payload):
        if operation == "reconvert" and not self.reconversion_replies[operation]:
            reference = payload["reference"]
            authority = {**reference, "compositionRevision": 0, "settingsRevision": self.settings,
                         "requestID": "dictionary-reading"}
            request = {"authority": authority, "workerGeneration": payload["candidateWorkerGeneration"],
                       "text": payload["reconversionContext"]["selected"], "privateInput": False}
            return self._header(reference=reference, reconversionReadingRequest=request)
        if self.reconversion_replies[operation]:
            fields = deepcopy(self.reconversion_replies[operation].popleft())
            kind = fields.pop("kind", "acknowledgement")
            return self._header(kind, reference=payload["reference"], **fields)
        return super()._respond(operation, payload)


class ReconversionCandidateFixture(CandidateBridgeFixture):
    def __init__(self):
        super().__init__()
        self.resolved_reading = "にほんご"

    def _respond(self, operation, payload):
        if operation != "resolve-reconversion-reading":
            return super()._respond(operation, payload)
        request = deepcopy(payload["reconversionReadingRequest"])
        resolved = {"request": request}
        if self.resolved_reading is not None:
            resolved["reading"] = self.resolved_reading
        return {"workerGeneration": self.generation, "settingsRevision": self.settings_revision,
                "learning": self.learning, "customInputTableRevisions": {},
                "authority": request["authority"], "reconversionReadingResult": resolved}
