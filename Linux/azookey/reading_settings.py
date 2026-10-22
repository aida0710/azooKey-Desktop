"""Confirm candidate settings without delaying acknowledged reading input."""
from copy import deepcopy

from .reading_protocol import ReadingNotice
from .worker_settings import acknowledgement, dictionary_revision


class ReadingSettingsAgreement:
    def __init__(self, candidates, *, changed, notify, is_closed, initial_reply=None):
        self.candidates = candidates
        self.changed = changed
        self.notify = notify
        self.is_closed = is_closed
        self.reader = None
        self.observed = None
        self.pending = True
        self.failed = False
        self.confirmed_identity = None
        self.prepared_dictionary = None
        if initial_reply is not None:
            self.observed_candidate(initial_reply)

    def confirm_reading(self, response):
        acknowledgement(response, expected=response["settings"])
        self.reader = deepcopy(response)
        self.confirmed_identity = None
        self._synchronize()

    def begin_configuration(self):
        self.reader = None
        self.failed = False
        self.confirmed_identity = None

    def observed_candidate(self, reply):
        if self.is_closed():
            return
        self.pending = False
        if not self._valid_reply(reply):
            return
        try:
            acknowledgement(reply.settings)
        except ValueError:
            self._failed("candidate_settings_contract_changed")
            return
        self.observed = reply
        self._synchronize()

    def _valid_reply(self, reply, *, expected_identity=None):
        identity = self.candidates.transport.identity
        if reply.error:
            self._failed(reply.error)
            return False
        if ((reply.worker_generation, reply.transport_epoch) != identity
                or expected_identity is not None and expected_identity != identity):
            self._failed("candidate_worker_changed")
            return False
        return True

    def _synchronize(self):
        if self.reader is None or self.pending or self.failed or self.is_closed():
            return
        identity = self.candidates.transport.identity
        if self.observed is None or identity != (self.observed.worker_generation, self.observed.transport_epoch):
            self._query()
            return
        settings = self.observed.settings
        revision = self.reader["settingsRevision"]
        if self._matches(settings):
            self.confirmed_identity = identity
            self.changed()
            return
        initial_dictionary = (settings["settingsRevision"] == revision
                              and self._matching_values(settings)
                              and settings.get("dictionaryRevision") is None
                              and self.reader.get("dictionaryRevision") is not None)
        if (settings["settingsRevision"] > revision
                or settings.get("settings") is not None
                and settings["settingsRevision"] == revision and not initial_dictionary):
            self._failed("candidate_settings_changed")
            return
        dictionary = self.reader.get("dictionaryRevision")
        if (dictionary is not None and settings.get("dictionaryRevision") != dictionary
                and self.prepared_dictionary != (identity, dictionary)):
            self.pending = True
            self.candidates.prepare_dictionary(
                worker_generation=identity[0],
                callback=lambda reply: self._prepared(reply, identity=identity, dictionary=dictionary),
            )
            return
        self.pending = True
        # Only the reader's acknowledged values can be installed in a new
        # candidate process. No input or learning completion is replayed here.
        configure = (self.candidates.bind_initial_dictionary if initial_dictionary
                     else self.candidates.configure_settings)
        configure(
            self.reader["settings"], revision, worker_generation=identity[0],
            callback=lambda reply: self._configured(reply, identity=identity),
            dictionary_revision=dictionary,
        )

    def _matches(self, settings):
        return (settings["settingsRevision"] == self.reader["settingsRevision"]
                and self._matching_values(settings)
                and settings.get("dictionaryRevision") == self.reader.get("dictionaryRevision"))

    def _matching_values(self, settings):
        return (settings.get("settings") == self.reader["settings"]
                and settings["customInputTableRevisions"] == self.reader["customInputTableRevisions"])

    def record_dictionary_preparation(self, reply):
        identity = self.candidates.transport.identity
        if not self._valid_reply(reply, expected_identity=identity):
            return False
        try:
            acknowledgement(reply.settings)
            revision = dictionary_revision(reply.settings.get("preparedDictionaryRevision"))
        except (AttributeError, ValueError):
            self._failed("candidate_dictionary_contract_changed")
            return False
        self.prepared_dictionary = (identity, revision)
        return True

    def _prepared(self, reply, *, identity, dictionary):
        if self.is_closed():
            return
        self.pending = False
        if not self._valid_reply(reply, expected_identity=identity):
            return
        if self.reader is None or self.reader.get("dictionaryRevision") != dictionary:
            self._failed("candidate_settings_changed")
            return
        if not self.record_dictionary_preparation(reply):
            return
        if self.prepared_dictionary != (identity, dictionary):
            self._failed("candidate_dictionary_changed")
            return
        self._synchronize()

    def _configured(self, reply, *, identity):
        if self.is_closed():
            return
        self.pending = False
        if not self._valid_reply(reply, expected_identity=identity):
            return
        try:
            acknowledgement(reply.settings, expected=self.reader["settings"])
        except ValueError:
            self._failed("candidate_settings_changed")
            return
        if not self._matches(reply.settings):
            self._failed("candidate_settings_changed")
            return
        self.observed = reply
        self.confirmed_identity = identity
        self.changed()

    def ensure_candidate_settings(self):
        if self.is_closed() or self.failed or self.reader is None:
            return None
        identity = self.candidates.transport.identity
        if identity == self.confirmed_identity:
            return identity[0]
        self.confirmed_identity = None
        if not self.pending:
            self._query()
        return None

    def invalidate_candidate(self):
        self.confirmed_identity = None
        self.observed = None
        self.prepared_dictionary = None

    def retry_candidate(self):
        if not self.pending:
            self.failed = False
            self.confirmed_identity = None
            self._query()

    def _query(self):
        self.pending = True
        self.candidates.settings(self.observed_candidate)

    def _failed(self, code):
        self.failed = True
        self.confirmed_identity = None
        self.notify(ReadingNotice(code, operation="candidate-settings"))
        # A later explicit save may already be prepared. Failure retires the
        # pending ACK too, so an inactive reader can proceed with that save.
        self.changed()
