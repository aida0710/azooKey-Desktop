"""Prepare a saved dictionary asynchronously without owning formal input."""
from .reading_protocol import ReadingNotice
from .worker_settings import dictionary_revision


class ReadingDictionaryPreparation:
    def __init__(self, candidates, *, prepared, notify, is_closed):
        self.candidates = candidates
        self.prepared = prepared
        self.notify = notify
        self.is_closed = is_closed
        self.pending = False
        self.refresh_again = False
        self.available = None
        self.required = False

    def refresh(self):
        if self.is_closed():
            return
        self.required = True
        if self.pending:
            # Several atomic-save events describe one latest saved document.
            self.refresh_again = True
            return
        self.pending = True
        self.available = None
        self.candidates.settings(self._settings)

    def _settings(self, reply):
        if self.is_closed():
            return
        identity = self.candidates.transport.identity
        if reply.error or (reply.worker_generation, reply.transport_epoch) != identity:
            self._failed(reply.error or "candidate_worker_changed")
            return
        self.candidates.prepare_dictionary(
            worker_generation=identity[0], callback=lambda value: self._prepared(value, identity=identity),
        )

    def _prepared(self, reply, *, identity):
        if self.is_closed():
            return
        if (reply.error or identity != self.candidates.transport.identity
                or (reply.worker_generation, reply.transport_epoch) != identity):
            self._failed(reply.error or "candidate_worker_changed")
            return
        try:
            revision = dictionary_revision(reply.settings.get("preparedDictionaryRevision"))
        except (AttributeError, ValueError):
            self._failed("candidate_dictionary_contract_changed")
            return
        self.pending = False
        if self.refresh_again:
            self.refresh_again = False
            self.refresh()
            return
        self.available = (identity, revision)
        self.prepared(reply)

    def _failed(self, code):
        refresh_again = self.refresh_again
        self.pending = False
        self.refresh_again = False
        self.available = None
        if refresh_again:
            # This is a later explicit save, not a retry of the failed request.
            self.refresh()
        self.notify(ReadingNotice(code, operation="prepare-dictionary"))
