"""Own reading operations and original input replies independently of candidates."""
from collections import deque
from copy import deepcopy
from dataclasses import dataclass, field
import logging
import threading

from . import candidate_protocol as candidate_protocol
from . import reading_protocol as protocol
from .candidate_coordinator import CandidateCoordinator
from .reading_transport import ReadingTransport
from .reading_settings import ReadingSettingsAgreement
from .reading_candidate_view import validate_view
from . import reconversion_protocol
from .worker_settings import UnsupportedWorkerSettings, validated_settings


LOGGER = logging.getLogger(__name__)
# Bound original-call ownership even when the reading process is unresponsive.
MAX_PENDING_INPUTS = 1024


@dataclass
class ReadingContext:
    name: str
    reference: dict | None = None
    displayed: dict | None = field(default=None, repr=False)
    active: bool = False
    private_input: bool = False
    planned_owner: object = field(default=None, repr=False)
    sequence: int = 0
    authority: dict | None = None
    batch: dict | None = field(default=None, repr=False)
    candidate_view: dict | None = field(default=None, repr=False)
    batch_visible: bool = False
    wanted: int | None = None
    recovery_sequence: int | None = None


@dataclass
class OwnedReadingOperation:
    operation: str
    context: ReadingContext | None
    payload: dict = field(default_factory=dict, repr=False)
    token: object = field(default=None, repr=False)
    finish: object = None
    callback: object = None
    sequence: int = 0
    cancelled: bool = False
    completed: bool = False
    wire_payload: dict | None = field(default=None, repr=False)
    owner: object = field(default=None, repr=False)


class ReadingCoordinator:
    def __init__(self, dispatch, *, publish_input, publish_candidates, notify,
                 environment=None, reader_factory=None, candidate_factory=None,
                 settings=None, settings_provider=None):
        if settings_provider is not None and (settings is not None or not callable(settings_provider)):
            raise ValueError("settings require either values or one provider")
        initial_settings = validated_settings(settings) if settings is not None else None
        self.publish_input = publish_input
        self.publish_candidates = publish_candidates
        self.notify = notify
        self.transport = ReadingTransport(dispatch, environment=environment, bridge_factory=reader_factory)
        self.candidates = CandidateCoordinator(dispatch, environment=environment, bridge_factory=candidate_factory)
        self._owner_thread = threading.get_ident()
        self._closed = False
        self._broken = False
        self._generation = None
        self._settings_revision = 0
        self._confirmed_learning = None
        self._candidate_settings = None
        self._candidate_settings_pending = True
        self._changing_settings = False
        self._settings_agreement = None
        self._candidate_settings_reply = None
        self._contexts = {}
        self._planned_focus = None
        self._pending = deque()
        self._active = None
        self._publishing = None
        self._settings_provider = settings_provider
        self._bootstrap_operation = None
        if initial_settings is not None:
            self.configure_settings(initial_settings, 0)
        elif settings_provider is not None:
            # Reserve configuration before clients can enqueue open/focus/key.
            # Its values arrive with hello; only the reader's ACK releases input.
            self._bootstrap_operation = self._queue_settings({})
        self.transport.submit("hello", {}, self._hello)
        self.candidates.settings(self._candidate_ready)

    def _owner(self):
        if threading.get_ident() != self._owner_thread:
            raise RuntimeError("reading ownership must run on its dispatcher thread")
        if self._closed or self._broken:
            raise RuntimeError("reading coordinator requires an explicit restart")

    def _context(self, name):
        self._owner()
        candidate_protocol.identifier(name)
        if name not in self._contexts:
            raise ValueError("reading context is not open")
        return self._contexts[name]

    def open_context(self, context, callback=None):
        self._owner()
        candidate_protocol.identifier(context)
        if context in self._contexts or len(self._contexts) >= candidate_protocol.MAX_CONTEXTS:
            raise ValueError("reading context already open or limit reached")
        state = ReadingContext(context)
        self._contexts[context] = state
        self._enqueue(OwnedReadingOperation("open", state, callback=callback))

    def focus_in(self, context, surroundings, callback=None):
        state = self._context(context)
        if (self._changing_settings and self._settings_agreement is None) or self._planned_focus is not None:
            raise ValueError("reading focus requires completed settings and retired previous focus")
        if (not isinstance(surroundings, dict) or set(surroundings) != {"leftContext", "rightContext", "privateInput"}
                or any(not isinstance(surroundings[name], str) for name in ("leftContext", "rightContext"))
                or type(surroundings["privateInput"]) is not bool):
            raise ValueError("invalid reading surroundings")
        self._planned_focus = context
        state.planned_owner = object()
        state.sequence += 1
        self._enqueue(OwnedReadingOperation("focus-in", state, {"surroundings": deepcopy(surroundings)},
                                           callback=callback, owner=state.planned_owner))

    def key(self, context, event, *, token, finish, double_tap=False, reconversion_context=None):
        if not isinstance(event, dict) or type(double_tap) is not bool:
            raise ValueError("invalid reading key")
        payload = {"event": deepcopy(event), "doubleTap": double_tap}
        if reconversion_context is not None:
            payload["reconversionContext"] = reconversion_protocol.document_context(reconversion_context)
        self._input("key", context, payload, token=token, finish=finish)

    def select(self, context, selection, *, token, finish):
        self._input("select", context, {"selection": deepcopy(selection)}, token=token, finish=finish)

    def commit_candidate(self, context, selection, *, token, finish, reconversion_context=None):
        payload = {"selection": deepcopy(selection)}
        if reconversion_context is not None:
            payload["reconversionContext"] = reconversion_protocol.document_context(reconversion_context)
        self._input("commit-candidate", context, payload, token=token, finish=finish)

    def reconversion(self, context, operation, payload, *, token, finish, callback):
        if operation not in reconversion_protocol.CONTROL_OPERATIONS | {"confirm-reconversion"}:
            raise ValueError("invalid reading reconversion operation")
        self._input(operation, context, deepcopy(payload), token=token, finish=finish, callback=callback)

    def prepare_reconversion_worker(self):
        self._owner()
        if self._changing_settings:
            return None
        if self._settings_agreement is not None:
            return self._settings_agreement.ensure_candidate_settings()
        settings = self._candidate_settings
        if settings is not None and settings["workerGeneration"] == self.candidates.transport.identity[0]:
            return settings["workerGeneration"]
        return None

    @property
    def settings(self):
        """Return only reader-acknowledged settings, independently of candidate startup."""
        confirmed = self._settings_agreement.reader if self._settings_agreement is not None else None
        return deepcopy(confirmed["settings"]) if confirmed is not None else None

    def reset(self, context, *, submit, token, finish):
        self._reset("reset", context, submit=submit, token=token, finish=finish)

    def focus_out(self, context, *, submit, token, finish):
        self._reset("focus-out", context, submit=submit, token=token, finish=finish)

    def _reset(self, operation, context, *, submit, token, finish):
        if type(submit) is not bool:
            raise ValueError("invalid reading submission")
        state = self._context(context)
        self._validate_input(context, finish, cancelling=not submit)
        retired = []
        earlier_operations = ((self._active,) if self._active else ()) + tuple(self._pending)
        if not submit:
            for earlier in earlier_operations:
                if (earlier.context is state and earlier.owner is state.planned_owner
                        and earlier.finish is not None):
                    earlier.cancelled = True
                    retired.append(earlier)
        immediate = self._can_finish_cancelled(earlier_operations, retired)
        if immediate:
            retired_ids = {id(earlier) for earlier in retired}
            self._pending = deque(earlier for earlier in self._pending if id(earlier) not in retired_ids)
        state.sequence += 1
        self._pending.append(OwnedReadingOperation(operation, state, {"submit": submit},
                                                   token=token, finish=finish, sequence=state.sequence, owner=state.planned_owner))
        if operation == "focus-out":
            self._planned_focus = None
        # Register the lifecycle boundary before callbacks can reenter with a new
        # focus. A known cancellation never needs the old process reply to finish.
        if immediate:
            for earlier in retired:
                self._finish(earlier, True)
        self._pump()

    def _can_finish_cancelled(self, operations, retired):
        retired_ids = {id(earlier) for earlier in retired}
        blocked = False
        for earlier in operations:
            if earlier is self._publishing or (earlier.finish is not None and not earlier.completed
                                               and id(earlier) not in retired_ids):
                blocked = True
            if id(earlier) in retired_ids and blocked:
                return False
        return True

    def barrier(self, context, *, token, finish):
        self._input("barrier", context, {}, token=token, finish=finish)

    def _input(self, operation, context, payload, *, token, finish, callback=None):
        state = self._context(context)
        self._validate_input(context, finish)
        if operation != "barrier":
            state.sequence += 1
        self._enqueue(OwnedReadingOperation(operation, state, payload, token=token, finish=finish,
                                           sequence=state.sequence, owner=state.planned_owner, callback=callback))

    def _validate_input(self, context, finish, *, cancelling=False):
        if self._planned_focus != context:
            raise ValueError("reading input has no planned focus")
        if not callable(finish):
            raise ValueError("reading input requires an original reply callback")
        if not cancelling and len(self._pending) >= MAX_PENDING_INPUTS:
            raise ValueError("reading input queue limit reached")

    def close_context(self, context, callback=None):
        state = self._context(context)
        if self._planned_focus == context:
            raise ValueError("reading focus must be retired before close")
        state.sequence += 1
        self._enqueue(OwnedReadingOperation("close", state, callback=callback))

    def _enqueue(self, operation):
        self._pending.append(operation)
        self._pump()

    def _hello(self, reply):
        if self._closed or self._broken:
            return False
        if reply.error or reply.response.get("error"):
            self._fail_all("reading_handshake_failed")
        else:
            self._settings_revision = reply.response["settingsRevision"]
            if self._bootstrap_operation is not None and not self._load_initial_settings(reply.response):
                return False
            self._generation = reply.generation
            self._pump()
        return False

    def _load_initial_settings(self, response):
        try:
            defaults = response.get("defaultSettings")
            if defaults is None:
                raise ValueError("reading process did not provide valid defaults")
            values = validated_settings(self._settings_provider(deepcopy(defaults)))
        except UnsupportedWorkerSettings:
            self._fail_all("reading_settings_unsupported")
            return False
        except Exception:
            # A settings provider may include toolkit notifications. Its failure
            # cannot strand queued original replies or release unconfigured input.
            self._fail_all("reading_settings_unavailable")
            return False
        if self._closed or self._broken:
            return False
        self._bootstrap_operation.payload = {"settings": values, "settingsRevision": self._settings_revision}
        self._bootstrap_operation = None
        return True

    def _payload(self, operation):
        if operation.operation == "open":
            return {"readingProcessGeneration": self._generation, "context": operation.context.name}
        if operation.operation in ("learning-revision", "configure-settings"):
            return {**operation.payload, "readingProcessGeneration": self._generation}
        state = operation.context
        if self._contexts.get(state.name) is not state or state.reference is None:
            raise ValueError("reading operation has no current context reference")
        return {**operation.payload, "reference": deepcopy(state.reference)}

    def _pump(self):
        if self._closed or self._broken or self._generation is None or self._active is not None:
            return
        while self._pending:
            if self._closed or self._broken or self._active is not None:
                return
            operation = self._pending.popleft()
            if operation.cancelled or operation.operation == "barrier":
                self._finish(operation, operation.cancelled)
                continue
            try:
                operation.wire_payload = self._payload(operation)
            except ValueError:
                self._reject(operation, "reading_context_unavailable")
                continue
            self._active = operation
            self.transport.submit(operation.operation, operation.wire_payload,
                                  lambda reply, current=operation: self._received(current, reply))
            return
        if self._active is None:
            self._prepare_wanted()

    def _received(self, operation, reply):
        if self._closed or self._broken or self._active is not operation:
            return False
        if reply.error or reply.generation != self._generation:
            phase = "response-unknown" if reply.uncertain else "not-sent"
            self._fail_all(reply.error or "reading_process_changed", operation, phase)
            return False
        response = reply.response
        if response.get("error"):
            self._reject(operation, response["error"])
        else:
            self._settings_revision = response["settingsRevision"]
            try:
                self._apply(operation, response)
            except (OSError, RuntimeError, ValueError):
                self._fail_all("reading_response_application_failed", operation, "application-unknown")
        if self._active is operation:
            self._active = None
        self._pump()
        return False

    def _apply(self, operation, response):
        state = operation.context
        name = operation.operation
        if name == "confirm-reconversion" and response.get("reconversionError"):
            # Failed confirmation leaves the old formal state unchanged. The
            # replacement owner decides whether its acknowledged deletion is recoverable.
            self._finish(operation, True)
        elif name in protocol.INPUT_OPERATIONS:
            self._apply_input(operation, response)
            if self._broken or self._closed:
                return
        elif name in ("open", "focus-in"):
            state.reference = response["reference"]
            state.active = name == "focus-in"
            if name == "focus-in":
                state.private_input = operation.payload["surroundings"]["privateInput"]
                state.displayed = None
                state.wanted = None
        elif name == "close":
            self._release_batch(state)
            self.candidates.close_context(state.name, self._generation)
            self._contexts.pop(state.name, None)
        elif name == "prepare-candidates":
            self._prepared(operation, response)
        elif name == "adopt-candidates":
            self._adopted(operation, response)
        elif name == "configure-settings":
            self._changing_settings = False
            self._settings_agreement.confirm_reading(response)
        elif name in reconversion_protocol.CONTROL_OPERATIONS:
            self._finish(operation, True)
        if name == "focus-out":
            state.reference = response["nextReference"]
            state.active = False
            self._release_batch(state)
            self.candidates.close_context(state.name, self._generation)
            state.authority = None
        self._callback(operation.callback, response)

    def _apply_input(self, operation, response):
        state = operation.context
        snapshot = response["snapshot"]
        if operation.cancelled:
            self._finish(operation, True)
            return
        if any(completion["privateInput"] != state.private_input
               or completion["settingsRevision"] != response["settingsRevision"]
               for completion in snapshot.get("candidateCompletions", [])):
            self._fail_all("reading_completion_conditions_changed", operation, "not-applied")
            return
        candidate_view = response.get("candidateView")
        if candidate_view is not None:
            try:
                if state.batch is None:
                    raise ValueError("candidate view has no retained batch")
                validate_view(candidate_view, expected_reference=response["reference"], batch=state.batch, snapshot=snapshot)
            except ValueError:
                self._fail_all("reading_candidate_view_changed", operation, "not-applied")
                return
        self._publishing = operation
        try:
            applied = self.publish_input(protocol.ReadingInput(state.name, operation.token,
                                                              deepcopy(response["reference"]), snapshot=deepcopy(snapshot),
                                                              candidate_view=deepcopy(candidate_view)))
        except Exception:
            # UI callbacks may fail after emitting a commit. Never return the
            # original key for native replay when its application is uncertain.
            self._fail_all("reading_input_application_failed", operation, "application-unknown")
            return
        finally:
            self._publishing = None
        if self._closed or self._broken:
            return
        known_cancel = operation.operation in ("reset", "focus-out") and not operation.payload["submit"]
        if applied is False and not (known_cancel or operation.cancelled):
            self._fail_all("reading_input_owner_changed", operation, "not-applied")
            return
        if applied is not False:
            self._update_authority(state, response)
            for completion in snapshot.get("candidateCompletions", []):
                self._complete_candidate(state, completion)
        if operation.cancelled:
            # Publication can retire its focus reentrantly. An applied commit
            # keeps its old learning owner, but cannot restore the retired UI.
            state.displayed = None
            state.wanted = None
            self._finish(operation, True)
            return
        if applied is not False:
            state.displayed = protocol.displayed_snapshot(snapshot)
            state.candidate_view = deepcopy(candidate_view)
        elif known_cancel:
            state.displayed = None
            state.candidate_view = None
            self._update_authority(state, response)
        if (state.batch is not None and (not snapshot["preedit"]
                or state.batch["authority"]["compositionRevision"] != snapshot["compositionRevision"])):
            self._release_batch(state)
        elif state.batch is not None and not state.batch_visible and snapshot.get("selection") is not None:
            self._publish_batch(state)
        state.wanted = state.sequence if snapshot.get("request") == "candidates" else None
        self._finish(operation, operation.cancelled or snapshot["consumed"])

    def _update_authority(self, state, response):
        if state.authority is None:
            return
        state.authority = {**state.authority, "compositionRevision": response["snapshot"]["compositionRevision"],
                           "settingsRevision": response["settingsRevision"]}
        self.candidates.set_authority(state.authority)

    def _complete_candidate(self, state, completion):
        try:
            self.candidates.complete(completion, authority=state.authority,
                                     callback=lambda reply: self._learning_receipt(state.name, completion, reply))
        except (OSError, RuntimeError, ValueError):
            self._notice(protocol.ReadingNotice("candidate_learning_not_sent", context=state.name,
                                               completion=deepcopy(completion), phase="not-sent"))

    def _learning_receipt(self, context, completion, reply):
        self._notice(protocol.ReadingNotice(reply.error or "candidate_learning_completed", context=context,
                                           phase="response-unknown" if reply.uncertain else "receipt",
                                           completion=deepcopy(reply.completion or completion)))

    def _candidate_ready(self, reply):
        if self._closed or self._broken:
            return
        self._candidate_settings_reply = reply
        if self._settings_agreement is not None:
            self._settings_agreement.observed_candidate(reply)
            return
        self._candidate_settings_pending = False
        generation, epoch = self.candidates.transport.identity
        if reply.error or (reply.worker_generation, reply.transport_epoch) != (generation, epoch):
            self._notice(protocol.ReadingNotice(reply.error or "candidate_worker_changed", operation="candidate-settings"))
            return
        settings = reply.settings
        if self._confirmed_learning is None and settings["settingsRevision"] == self._settings_revision:
            self._confirmed_learning = settings["learning"]
        if (settings["settingsRevision"] == self._settings_revision
                and settings["learning"] == self._confirmed_learning):
            self._candidate_settings = settings
            self._pump()
            return
        if self._confirmed_learning is None or settings["settingsRevision"] >= self._settings_revision:
            self._notice(protocol.ReadingNotice("candidate_settings_changed", operation="candidate-settings"))
            return
        # A replacement process starts at revision zero. Restore only settings
        # acknowledged by both workers; uncertain completion payloads stay retired.
        self._candidate_settings_pending = True
        learning, revision = self._confirmed_learning, self._settings_revision
        self.candidates.configure_learning(learning, revision, worker_generation=generation,
                                            callback=lambda response: self._candidate_restored(
                                                response, learning=learning, revision=revision,
                                                identity=(generation, epoch)))

    def _candidate_restored(self, reply, *, learning, revision, identity):
        if self._closed or self._broken:
            return
        self._candidate_settings_pending = False
        error = self._candidate_settings_error(reply, learning=learning, revision=revision, identity=identity)
        if not error and (learning, revision) != (self._confirmed_learning, self._settings_revision):
            error = "candidate_settings_changed"
        if error:
            self._notice(protocol.ReadingNotice(error, operation="candidate-settings"))
            return
        self._candidate_settings = reply.settings
        self._pump()

    def _candidate_settings_error(self, reply, *, learning, revision, identity=None):
        if reply.error:
            return reply.error
        current = self.candidates.transport.identity
        if (reply.worker_generation, reply.transport_epoch) != current or identity is not None and identity != current:
            return "candidate_worker_changed"
        if reply.settings["settingsRevision"] != revision or reply.settings["learning"] != learning:
            return "candidate_settings_changed"
        return None

    def _prepare_wanted(self):
        if self._changing_settings:
            return
        if self._settings_agreement is not None:
            generation = self._settings_agreement.ensure_candidate_settings()
            if generation is not None:
                self._prepare_candidate_requests(generation)
            return
        if (self._candidate_settings is not None
                and self._candidate_settings["workerGeneration"] != self.candidates.transport.identity[0]):
            self._candidate_settings = None
        if self._candidate_settings is None:
            if not self._candidate_settings_pending and any(state.wanted is not None for state in self._contexts.values()):
                self._candidate_settings_pending = True
                self.candidates.settings(self._candidate_ready)
            return
        self._prepare_candidate_requests(self._candidate_settings["workerGeneration"])

    def _prepare_candidate_requests(self, worker_generation):
        for state in self._contexts.values():
            if state.active and state.wanted is not None:
                sequence, state.wanted = state.wanted, None
                if sequence != state.sequence:
                    continue
                payload = {"candidateWorkerGeneration": worker_generation}
                self._enqueue(OwnedReadingOperation("prepare-candidates", state, payload,
                                                   sequence=sequence, owner=state.planned_owner))
                return

    def _current(self, operation):
        return self._same_focus(operation) and operation.context.sequence == operation.sequence

    def _same_focus(self, operation):
        state = operation.context
        return (not self._closed and not self._broken and self._contexts.get(state.name) is state
                and state.active and self._planned_focus == state.name and operation.owner is state.planned_owner)

    def _prepared(self, operation, response):
        if not self._current(operation):
            return
        state = operation.context
        request = response["candidateRequest"]
        if request.get("privateInput") != state.private_input:
            raise ValueError("reading candidate request changed privacy")
        state.authority = request["authority"]
        self.candidates.request_candidates(
            request, lambda reply: self._calculated(operation, reply),
            worker_generation=operation.payload["candidateWorkerGeneration"],
        )

    def _calculated(self, operation, reply):
        if not self._current(operation):
            if reply.batch and not self._closed:
                self.candidates.release(candidate_protocol.reference(reply.batch))
            return
        if reply.error:
            self._notice(protocol.ReadingNotice(reply.error, context=operation.context.name, operation="candidates"))
            if not self._current(operation):
                return
            self._candidate_settings = None
            if self._settings_agreement is not None:
                self._settings_agreement.invalidate_candidate()
            if (reply.error == "candidate_worker_changed"
                    and operation.context.recovery_sequence != operation.sequence):
                # Only this still-current calculation is renewed after settings
                # agreement, once per input; a crashing worker cannot loop forever.
                operation.context.recovery_sequence = operation.sequence
                operation.context.wanted = operation.sequence
            self._enqueue(OwnedReadingOperation("candidate-worker-stopped", operation.context,
                                                deepcopy(operation.payload), owner=operation.owner))
            return
        payload = {"batch": reply.batch, "retainedReference": candidate_protocol.reference(reply.batch)}
        self._enqueue(OwnedReadingOperation("adopt-candidates", operation.context, payload,
                                           sequence=operation.sequence, owner=operation.owner))

    def _adopted(self, operation, response):
        state = operation.context
        batch = operation.payload["batch"]
        if not self._same_focus(operation):
            self.candidates.release(candidate_protocol.reference(batch))
            return
        self._release_batch(state)
        state.batch = deepcopy(batch)
        state.candidate_view = deepcopy(response["candidateView"])
        # Core already adopted this exact retained batch. A key queued while its
        # ACK was in flight may select it; keep the reference until that key tells
        # us whether the composition changed, without publishing the old panel.
        if self._current(operation):
            self._publish_batch(state)

    def _publish_batch(self, state):
        if state.candidate_view is None:
            return
        try:
            applied = self.publish_candidates(protocol.ReadingCandidates(
                state.name, deepcopy(state.reference), deepcopy(state.batch),
                candidate_view=deepcopy(state.candidate_view)))
            state.batch_visible = applied is not False
        except Exception:
            # Core still owns its adopted selection source. Retain it even when
            # the panel fails; a later explicit key can select/commit it safely.
            state.batch_visible = False
            self._notice(protocol.ReadingNotice("reading_candidate_display_failed", context=state.name))

    def _release_batch(self, state):
        state.candidate_view = None
        if state.batch is not None:
            self.candidates.release(candidate_protocol.reference(state.batch))
            state.batch = None
            state.batch_visible = False

    def configure_learning(self, learning, revision, callback=None):
        self._owner()
        if self._settings_agreement is not None:
            raise ValueError("full worker settings are required")
        if not isinstance(learning, str) or learning not in candidate_protocol.LEARNING_MODES:
            raise ValueError("invalid reading learning preference")
        if (self._changing_settings or self._planned_focus is not None or self._active is not None or self._pending
                or any(state.active for state in self._contexts.values()) or self._candidate_settings is None):
            raise ValueError("reading settings require inactive contexts and completed operations")
        if candidate_protocol.revision(revision) <= self._settings_revision:
            raise ValueError("reading settings revision must advance")
        self._changing_settings = True
        self.candidates.configure_learning(learning, revision,
                                            worker_generation=self._candidate_settings["workerGeneration"],
                                            callback=lambda reply: self._configured(reply, learning=learning,
                                                                                     revision=revision, callback=callback))

    def configure_settings(self, settings, revision, callback=None):
        self._owner()
        values = validated_settings(settings)
        candidate_protocol.revision(revision)
        if (self._changing_settings or self._planned_focus is not None or self._active is not None
                or self._pending or any(state.active for state in self._contexts.values())
                or self._settings_agreement is not None and self._settings_agreement.pending):
            raise ValueError("reading settings require inactive contexts and completed operations")
        if revision < self._settings_revision:
            raise ValueError("reading settings revision cannot move backwards")
        previous = self._settings_agreement.reader if self._settings_agreement is not None else None
        if previous is not None and revision == previous["settingsRevision"] and values != previous["settings"]:
            raise ValueError("changed worker settings require a new revision")
        self._queue_settings({"settings": values, "settingsRevision": revision}, callback)

    def _queue_settings(self, payload, callback=None):
        if self._settings_agreement is None:
            self._settings_agreement = ReadingSettingsAgreement(
                self.candidates, ready=self._pump, notify=self._notice,
                is_closed=lambda: self._closed or self._broken, initial_reply=self._candidate_settings_reply,
            )
        self._settings_agreement.begin_configuration()
        self._changing_settings = True
        operation = OwnedReadingOperation("configure-settings", None, payload, callback=callback)
        self._enqueue(operation)
        return operation

    def retry_candidate_settings(self):
        self._owner()
        if self._settings_agreement is not None:
            self._settings_agreement.retry_candidate()

    def _configured(self, reply, *, learning, revision, callback):
        if self._closed or self._broken:
            return
        error = self._candidate_settings_error(reply, learning=learning, revision=revision)
        if error:
            # A failed candidate settings response can be ambiguous. Do not allow
            # new input under a guessed agreement between the two processes.
            self._fail_all("reading_settings_unconfirmed")
            self._callback(callback, {"error": error})
            return
        self._candidate_settings = reply.settings
        self._enqueue(OwnedReadingOperation("learning-revision", None, {"settingsRevision": revision},
                                           callback=lambda response: self._settings_finished(response, learning, callback)))

    def _settings_finished(self, response, learning, callback):
        self._changing_settings = False
        if not response.get("error"):
            self._confirmed_learning = learning
        self._callback(callback, response)

    def _reject(self, operation, error):
        if operation.operation in ("learning-revision", "configure-settings"):
            self._fail_all("reading_settings_unconfirmed", operation, "rejected")
            return
        if operation.operation == "adopt-candidates":
            self.candidates.release(operation.payload["retainedReference"])
        if (operation.operation == "focus-in" and self._planned_focus == operation.context.name
                and operation.owner is operation.context.planned_owner):
            self._planned_focus = None
        self._notice_for(operation, error, "rejected")
        self._finish(operation, True)
        self._callback(operation.callback, {"error": error})

    def _notice_for(self, operation, error, phase):
        state = operation.context
        self._notice(protocol.ReadingNotice(error, context=state.name if state else None,
                                           operation=operation.operation, phase=phase, token=operation.token,
                                           reference=deepcopy(state.reference) if state else None,
                                           displayed_snapshot=deepcopy(state.displayed) if state else None,
                                           payload=deepcopy(operation.payload)))

    def _fail_all(self, error, operation=None, phase="not-sent"):
        self._broken = True
        pending, self._pending = list(self._pending), deque()
        active, self._active = self._active, None
        first = operation or active
        operations = ([(first, phase if operation else "response-unknown")] if first else [])
        operations.extend((queued, "not-sent") for queued in pending)
        for retired, boundary in operations:
            self._notice_for(retired, error, boundary)
            self._finish(retired, True)
            self._callback(retired.callback, {"error": error})
        if not operations:
            self._notice(protocol.ReadingNotice(error))
        self.transport.close()

    def _finish(self, operation, consumed):
        if operation.completed:
            return
        operation.completed = True
        if operation.finish is not None:
            try:
                operation.finish(operation.token, consumed)
            except Exception:
                # The callback may already have replied before raising. Its
                # ownership stays completed; neither retry nor stall the queue.
                self._notice_for(operation, "reading_original_reply_failed", "reply")

    def _callback(self, callback, response):
        if callback is not None:
            try:
                callback(deepcopy(response))
            except Exception:
                self._notice(protocol.ReadingNotice("reading_callback_failed"))

    def _notice(self, notice):
        try:
            self.notify(notice)
        except Exception:
            # Error reporting is another external callback, never a prerequisite
            # for finishing an original input or draining a lifecycle operation.
            LOGGER.error("Reading notification failed")

    def close(self):
        if threading.get_ident() != self._owner_thread:
            raise RuntimeError("reading close must run on its dispatcher thread")
        if self._closed:
            return
        if self._active is not None or self._pending:
            self._fail_all("reading_coordinator_closed")
        self._closed = True
        self.transport.close()
        self.candidates.close()
