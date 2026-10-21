"""Full settings acknowledgements for controlled transport failures."""
from copy import deepcopy
import unittest

from azookey.reading_coordinator import ReadingCoordinator
from candidate_fixture import CallbackQueue, CandidateBridgeFixture, WAIT_SECONDS
from reading_coordinator_fixture import ReadingBridgeFixture, event


def settings_values(**changes):
    return {
        "tree": True, "candidateTextSize": "standard", "showRelativeScores": True,
        "live": False, "halfSpace": False, "backslash": False, "optionDirect": False,
        "inputStyle": "default", "learning": "nothing", "punctuation": 1,
        "profile": "", "personalization": "off", "inferenceLimit": 5,
        "predictiveTyping": False, "typoCorrection": False, "debug": False,
        "aiEnabled": False, "transformShortcut": {"key": "t", "modifiers": 3},
        "customTable": "", **changes,
    }


def settings_acknowledgement(values):
    fields = {"settingsContract": "full", "customInputTableRevisions": {},
              "unsupportedFeatures": ["live", "predictiveTyping", "ai", "reconversion", "debug"]}
    if values is not None:
        fields["settings"] = deepcopy(values)
    return fields


class ConfiguredReadingFixture(ReadingBridgeFixture):
    def _reset(self):
        super()._reset()
        self.values = None

    def _respond(self, operation, payload):
        if operation == "configure-settings":
            self.values = deepcopy(payload["settings"])
            self.settings = payload["settingsRevision"]
            return self._header(**settings_acknowledgement(self.values))
        response = super()._respond(operation, payload)
        if operation == "hello":
            response.update(settings_acknowledgement(self.values))
        return response


class ConfiguredCandidateFixture(CandidateBridgeFixture):
    def _reset(self):
        super()._reset()
        self.values = None

    def _respond(self, operation, payload):
        if operation == "configure-settings":
            self.values = deepcopy(payload["settings"])
            self.settings_revision = payload["settingsRevision"]
            self.learning = self.values["learning"]
            return self._header(**settings_acknowledgement(self.values))
        response = super()._respond(operation, payload)
        if operation == "settings":
            response.update(settings_acknowledgement(self.values))
        return response


class ReadingSettingsTestCase(unittest.TestCase):
    def setUp(self):
        self.callbacks = CallbackQueue()
        self.reader = ConfiguredReadingFixture()
        self.converter = ConfiguredCandidateFixture()
        self.inputs, self.panels, self.notices, self.finished = [], [], [], []
        self.coordinator = None

    def tearDown(self):
        if self.coordinator is not None:
            self.coordinator.close()
            for transport in (self.coordinator.transport, self.coordinator.candidates.transport):
                transport.worker.join(WAIT_SECONDS)
                self.assertFalse(transport.worker.is_alive())

    def start(self, settings=None, *, settings_provider=None):
        values = settings if settings is not None else settings_values()
        self.coordinator = ReadingCoordinator(
            self.callbacks.dispatch, publish_input=self.inputs.append,
            publish_candidates=self.panels.append, notify=self.notices.append,
            reader_factory=lambda: self.reader, candidate_factory=lambda: self.converter,
            settings=values if settings_provider is None else settings,
            settings_provider=settings_provider,
        )

    def until(self, predicate):
        for _ in range(100):
            if predicate():
                return
            self.callbacks.drain(1)
        self.fail("settings condition did not complete")

    def focus(self):
        self.coordinator.open_context("field")
        self.coordinator.focus_in("field", {"leftContext": "", "rightContext": "", "privateInput": False})

    def key(self, text="", code=0):
        token = object()
        self.coordinator.key("field", event(text, code), token=token,
                             finish=lambda owner, consumed: self.finished.append((owner, consumed)))
        self.until(lambda: any(owner is token for owner, _ in self.finished))

    def agreement(self):
        return self.coordinator._settings_agreement

    def agreed(self):
        self.until(lambda: self.agreement().confirmed_identity is not None)
