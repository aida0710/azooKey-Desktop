"""Controllable dictionary identities over the existing worker transport fixtures."""
from worker_settings_fixture import ConfiguredCandidateFixture, ConfiguredReadingFixture, settings_acknowledgement


FIRST_DICTIONARY = "a" * 64
SECOND_DICTIONARY = "b" * 64


class DictionaryReadingFixture(ConfiguredReadingFixture):
    def _reset(self):
        super()._reset()
        self.dictionary = None

    def _respond(self, operation, payload):
        if operation == "bind-initial-dictionary":
            self.dictionary = payload["dictionaryRevision"]
            return self._header(**settings_acknowledgement(self.values), dictionaryRevision=self.dictionary)
        response = super()._respond(operation, payload)
        if operation == "configure-settings":
            self.dictionary = payload.get("dictionaryRevision")
        if operation in ("hello", "settings", "configure-settings") and self.dictionary is not None:
            response["dictionaryRevision"] = self.dictionary
        return response


class DictionaryCandidateFixture(ConfiguredCandidateFixture):
    def _reset(self):
        super()._reset()
        self.dictionary = None
        self.saved_dictionary = getattr(self, "saved_dictionary", FIRST_DICTIONARY)

    def _respond(self, operation, payload):
        if operation == "bind-initial-dictionary":
            self.dictionary = payload["dictionaryRevision"]
            return self._header(**settings_acknowledgement(self.values), dictionaryRevision=self.dictionary)
        if operation == "prepare-dictionary":
            response = self._header(**settings_acknowledgement(self.values))
            response["preparedDictionaryRevision"] = self.saved_dictionary
        else:
            response = super()._respond(operation, payload)
        if operation == "configure-settings":
            self.dictionary = payload.get("dictionaryRevision")
        if operation in ("settings", "configure-settings", "prepare-dictionary") and self.dictionary is not None:
            response["dictionaryRevision"] = self.dictionary
        return response
