"""Full settings acknowledgements for controlled transport failures."""
from copy import deepcopy

from candidate_fixture import CandidateBridgeFixture
from reading_coordinator_fixture import ReadingBridgeFixture


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
