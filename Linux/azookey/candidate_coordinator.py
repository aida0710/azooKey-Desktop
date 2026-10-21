"""Gate candidate adoption on current ownership; keep commit notifications independent."""
from copy import deepcopy
import threading

from . import candidate_protocol as protocol
from .candidate_transport import CandidateTransport
from .reconversion_protocol import reading_request
from .worker_settings import dictionary_revision as validate_dictionary_revision, validated_settings


class CandidateCoordinator:
    def __init__(self, dispatch, *, environment=None, bridge_factory=None):
        self.transport = CandidateTransport(dispatch, environment=environment, bridge_factory=bridge_factory)
        self._owner_thread = threading.get_ident()
        self._closed = False
        self._current = {}
        self._calculations = {}
        self._retained = {}
        self._commits = {}
        self._known_generation = None

    def _owner(self):
        if threading.get_ident() != self._owner_thread:
            raise RuntimeError("candidate ownership must run on its dispatcher thread")
        if self._closed:
            raise RuntimeError("candidate coordinator is closed")

    def set_authority(self, authority):
        self._owner()
        authority = protocol.authority(authority)
        context = authority["context"]
        previous = self._current.get(context)
        if previous == authority:
            return
        if previous is None and len(self._current) >= protocol.MAX_CONTEXTS:
            raise ValueError("candidate context limit reached")
        if previous is not None:
            if previous["readingProcessGeneration"] != authority["readingProcessGeneration"]:
                self.close_context(context, previous["readingProcessGeneration"])
            elif any(authority[field] < previous[field] for field in
                     ("focusEpoch", "compositionRevision", "settingsRevision")):
                raise ValueError("candidate authority moved backwards")
        self._cancel_calculation(context)
        self._current[context] = authority
        if previous is not None and not protocol.same_owner(previous, authority):
            self._release_context(context)

    def request_candidates(self, request, callback, *, worker_generation=None):
        self._owner()
        if worker_generation is not None:
            protocol.identifier(worker_generation)
        if not isinstance(request, dict):
            raise ValueError("invalid candidate calculation request")
        request = deepcopy(request)
        authority = protocol.authority(request.get("authority"))
        if (not isinstance(request.get("composition"), dict)
                or not isinstance(request.get("leftContext"), str)
                or not isinstance(request.get("rightContext"), str)
                or type(request.get("privateInput")) is not bool):
            raise ValueError("invalid candidate calculation request")
        self.set_authority(authority)
        context = authority["context"]
        self._cancel_calculation(context)
        token = object()
        operation = self.transport.submit("candidates", {"request": request},
                                          lambda reply: self._calculated(authority, token, callback, reply),
                                          worker_generation=worker_generation)
        self._calculations[context] = token, operation

    def _cancel_calculation(self, context):
        previous = self._calculations.pop(context, None)
        if previous is not None:
            previous[1].cancelled.set()

    def _calculated(self, authority, token, callback, reply):
        calculation = self._calculations.get(authority["context"])
        generation, epoch = self.transport.identity
        current = (not self._closed and calculation is not None and calculation[0] is token
                   and not calculation[1].cancelled.is_set()
                   and self._current.get(authority["context"]) == authority
                   and reply.transport_epoch == epoch and reply.worker_generation == generation)
        if not current:
            if calculation is not None and calculation[0] is token:
                self._calculations.pop(authority["context"])
            if reply.batch:
                self._release_unadopted(reply.batch)
            return False
        self._owner()
        self._calculations.pop(authority["context"])
        self._forget_old_generations()
        if reply.batch:
            self._retained[protocol.reference_key(reply.batch)] = deepcopy(reply.batch)
        retained_reference = protocol.reference(reply.batch) if reply.batch else None
        delivered = False
        try:
            callback(reply)
            delivered = True
        finally:
            # A failing presentation cannot silently keep one of the worker's
            # bounded retained batches alive forever.
            if retained_reference is not None and not delivered and not self._closed:
                self.release(retained_reference)
        return False

    def _release_unadopted(self, batch):
        if self._closed:
            return
        reference = protocol.reference(batch)
        if reference["workerGeneration"] == self.transport.identity[0]:
            self.transport.submit("release", {"reference": reference}, lambda _reply: None)

    def _forget_old_generations(self):
        generation = self.transport.identity[0]
        if generation == self._known_generation:
            return
        self._known_generation = generation
        self._retained = {key: batch for key, batch in self._retained.items() if key[0] == generation}
        # A retired generation cannot accept any of these candidate references.
        # Queued completion payloads keep their own permission and are not replayed.
        self._commits.clear()

    def release(self, reference):
        self._owner()
        reference = protocol.reference(reference)
        self._forget_old_generations()
        key = protocol.reference_key(reference)
        batch = self._retained.get(key)
        if batch is None:
            return False
        if protocol.reference(batch) != reference:
            raise ValueError("candidate release changed its authority")
        self._retained.pop(key)
        self.transport.submit("release", {"reference": reference}, lambda _reply: None)
        return True

    def _release_context(self, context):
        for batch in tuple(self._retained.values()):
            if batch["authority"]["context"] == context:
                self.release(protocol.reference(batch))

    def complete(self, completion, *, authority, callback):
        self._owner()
        completion = protocol.completion_request(completion)
        self._forget_old_generations()
        context = completion["authority"]["context"]
        history = self._commits.get(context, {})
        previous = history.get(completion["commitID"])
        if completion["workerGeneration"] != self.transport.identity[0]:
            raise ValueError("candidate worker changed before completion")
        if previous is not None:
            if previous != completion:
                raise ValueError("candidate commit identity was reused")
        else:
            self._authorize_completion(completion, authority)
            if len(history) >= protocol.MAX_COMPLETIONS_PER_CONTEXT:
                raise ValueError("candidate completion limit reached")
        # This permission was granted at the commit point. Later edits/focus or
        # context-close must not cancel this independent learning notification.
        self.transport.submit("complete", {"completion": completion},
                              lambda reply: self._control_finished(callback, reply))
        # Failed attempts also reserve their ID: forgetting one would allow a
        # different payload to reuse it after an ambiguous or rejected receipt.
        self._commits.setdefault(context, {})[completion["commitID"]] = completion
        self._retained.pop(protocol.reference_key(completion), None)

    def _authorize_completion(self, completion, current_authority):
        current_authority = protocol.authority(current_authority)
        source = completion["authority"]
        if (self._current.get(source["context"]) != current_authority
                or not protocol.same_owner(source, current_authority)
                or completion["settingsRevision"] != current_authority["settingsRevision"]):
            raise ValueError("candidate completion has no current owner permission")
        batch = self._retained.get(protocol.reference_key(completion))
        if (batch is None or protocol.reference(batch) != protocol.reference(completion)
                or not any(item["candidateID"] == completion["candidateID"] for item in batch["candidates"])):
            raise ValueError("candidate completion has no retained candidate")

    def settings(self, callback):
        self._owner()
        self.transport.submit("settings", {}, lambda reply: self._control_finished(callback, reply))

    def resolve_reconversion_reading(self, request, callback):
        self._owner()
        request = reading_request(request)
        if request["workerGeneration"] != self.transport.identity[0]:
            raise ValueError("reconversion reading worker changed")
        self.transport.submit(
            "resolve-reconversion-reading", {"reconversionReadingRequest": request},
            lambda reply: self._control_finished(callback, reply),
            worker_generation=request["workerGeneration"],
        )

    def configure_learning(self, learning, revision, *, worker_generation, callback):
        self._owner()
        if not isinstance(learning, str) or learning not in protocol.LEARNING_MODES:
            raise ValueError("invalid candidate learning preference")
        payload = {"learning": learning, "settingsRevision": protocol.revision(revision),
                   "workerGeneration": protocol.identifier(worker_generation)}
        self.transport.submit("configure-learning", payload, lambda reply: self._control_finished(callback, reply))

    def _control_finished(self, callback, reply):
        if self._closed:
            return False
        self._owner()
        self._forget_old_generations()
        # Completion replies contain only the validated historical commit receipt.
        # They cannot authorize a candidate display or an input-field mutation.
        if callback is not None:
            callback(reply)
        return False

    def prepare_dictionary(self, *, worker_generation, callback):
        self._owner()
        payload = {"workerGeneration": protocol.identifier(worker_generation)}
        self.transport.submit("prepare-dictionary", payload, lambda reply: self._control_finished(callback, reply),
                              worker_generation=worker_generation)

    def configure_settings(self, settings, revision, *, worker_generation, callback, dictionary_revision=None):
        self._submit_settings("configure-settings", settings, revision, worker_generation=worker_generation,
                              callback=callback, dictionary_revision=dictionary_revision)

    def bind_initial_dictionary(self, settings, revision, *, worker_generation, callback, dictionary_revision):
        validate_dictionary_revision(dictionary_revision)
        self._submit_settings("bind-initial-dictionary", settings, revision, worker_generation=worker_generation,
                              callback=callback, dictionary_revision=dictionary_revision)

    def _submit_settings(self, operation, settings, revision, *, worker_generation, callback, dictionary_revision):
        self._owner()
        payload = {"settings": validated_settings(settings), "settingsRevision": protocol.revision(revision),
                   "workerGeneration": protocol.identifier(worker_generation)}
        if dictionary_revision is not None:
            payload["dictionaryRevision"] = validate_dictionary_revision(dictionary_revision)
        self.transport.submit(operation, payload, lambda reply: self._control_finished(callback, reply))

    def close_context(self, context, reading_process_generation, callback=None):
        self._owner()
        protocol.identifier(context)
        protocol.identifier(reading_process_generation)
        current = self._current.get(context)
        if current is not None and current["readingProcessGeneration"] != reading_process_generation:
            raise ValueError("candidate context belongs to another reading process")
        self._cancel_calculation(context)
        self._current.pop(context, None)
        self._release_context(context)
        payload = {"context": context, "readingProcessGeneration": reading_process_generation,
                   "workerGeneration": self.transport.identity[0]}
        self.transport.submit("close", payload, lambda reply: self._control_finished(callback, reply))
        self._commits.pop(context, None)

    def close(self):
        self._owner()
        self._closed = True
        for context in tuple(self._calculations):
            self._cancel_calculation(context)
        self._current.clear()
        self._retained.clear()
        self._commits.clear()
        self.transport.close()
