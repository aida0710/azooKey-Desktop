"""Bind formal reading replies to their original input owner and candidate view."""
from copy import deepcopy
from dataclasses import dataclass, field
import logging
import uuid

from .reading_coordinator import ReadingCoordinator
from .reading_protocol import ReadingNotice


LOGGER = logging.getLogger(__name__)


@dataclass(eq=False)
class ReadingInputOwner:
    focus: object
    operation: str
    reply: object = field(default=None, repr=False)
    finished: bool = False


class ReadingFrontend:
    def __init__(self, dispatch, *, render_input, render_candidates, notify,
                 environment=None, coordinator_factory=ReadingCoordinator, settings_provider=None):
        self.context = str(uuid.uuid4())
        self.dispatch = dispatch
        self.render_input = render_input
        self.render_candidates = render_candidates
        self.notify = notify
        self.environment = environment
        self.coordinator_factory = coordinator_factory
        self.settings_provider = settings_provider
        self.focus = object()
        self.focused = False
        self.blocked = False
        self.closed = False
        self.reference = None
        self.snapshot = {}
        self.batch = None
        self.pending = set()
        self.surroundings = {"leftContext": "", "rightContext": "", "privateInput": False}
        self.coordinator = self._start_coordinator()

    def _start_coordinator(self):
        coordinator = self.coordinator_factory(
            self.dispatch, publish_input=self._publish_input,
            publish_candidates=self._publish_candidates, notify=self._notice,
            environment=self.environment,
            settings_provider=self.settings_provider,
        )
        coordinator.open_context(self.context, self._opened)
        return coordinator

    def _opened(self, response):
        if response.get("error"):
            self.blocked = True

    def focus_in(self, surroundings):
        if self.closed:
            return
        if self.focused:
            self.focus_out()
        if self.blocked:
            self._restart()
        self.focus = object()
        self.focused = True
        self.surroundings = deepcopy(surroundings)
        owner = self.focus

        def activated(response):
            if not self.closed and self.focused and self.focus is owner:
                self.reference = response.get("reference")
                self.blocked = bool(response.get("error"))

        self.coordinator.focus_in(self.context, self.surroundings, activated)

    def focus_out(self):
        if not self.focused or self.closed:
            return
        self.focused = False
        self.focus = object()
        retired_focus = self.focus
        self.snapshot, self.batch, self.reference = {}, None, None
        if not self.blocked:
            self._control("focus-out")
        if self.focus is retired_focus:
            self._clear_view()

    def reset(self):
        if not self.focused or self.closed:
            return
        self.focus = object()
        reset_focus = self.focus
        self.snapshot, self.batch = {}, None
        # Reset is an explicit client cancellation. IBus already owns any
        # focus-out submission; neither this clear nor a later ACK commits it.
        if self.blocked:
            surroundings = self.surroundings
            self._restart()
            self.focused = False
            self.focus_in(surroundings)
            reset_focus = self.focus
        else:
            self._control("reset")
        if self.focus is reset_focus:
            self._clear_view(include_input=True)

    def _clear_view(self, *, include_input=False):
        # Cancellation and original replies are already registered. Each view
        # can fail independently without keeping cancelled input alive.
        views = [("candidates", lambda: self.render_candidates({}, None))]
        if include_input:
            views.insert(0, ("input", lambda: self.render_input(
                {"preedit": "", "cursor": 0, "commits": [], "inputState": "none"})))
        cancelled_focus = self.focus
        for view, render in views:
            if self.closed or self.focus is not cancelled_focus:
                return
            try:
                render()
            except Exception:
                LOGGER.exception("Could not clear the cancelled %s view", view)
                self._notice(ReadingNotice("reading_view_unavailable", context=self.context,
                                          operation=view, phase="display"))

    def _restart(self):
        self.coordinator.close()
        self._finish_pending()
        self.blocked = False
        self.reference = None
        self.coordinator = self._start_coordinator()

    def key(self, event, reply, *, double_tap=False):
        if self.closed or not self.focused:
            reply(False)
            return
        if self.blocked:
            reply(True)
            return
        owner = self._owner("key", reply)
        try:
            self.coordinator.key(self.context, event, token=owner, finish=self._finish, double_tap=double_tap)
        except (OSError, RuntimeError, ValueError):
            self._submission_failed(owner)

    def barrier(self, reply):
        if self.closed or not self.focused:
            reply(False)
            return
        if self.blocked:
            reply(True)
            return
        owner = self._owner("barrier", reply)
        try:
            self.coordinator.barrier(self.context, token=owner, finish=self._finish)
        except (OSError, RuntimeError, ValueError):
            self._submission_failed(owner)

    def _control(self, operation):
        owner = self._owner(operation)
        submit = self.coordinator.reset if operation == "reset" else self.coordinator.focus_out
        try:
            submit(self.context, submit=False, token=owner, finish=self._finish)
        except (OSError, RuntimeError, ValueError):
            self._submission_failed(owner)

    def _owner(self, operation, reply=None):
        owner = ReadingInputOwner(self.focus, operation, reply)
        self.pending.add(owner)
        return owner

    def _submission_failed(self, owner):
        self.blocked = True
        self._notice(ReadingNotice("reading_frontend_submission_failed", context=self.context,
                                  operation=owner.operation, phase="not-sent", token=owner))
        self._finish(owner, True)

    def _publish_input(self, value):
        owner = value.token
        if (self.closed or not self.focused or self.blocked or value.context != self.context
                or owner not in self.pending or owner.focus is not self.focus or owner.finished):
            return False
        snapshot = value.snapshot
        if owner.operation in ("reset", "focus-out") and snapshot.get("commits"):
            raise ValueError("cancelled input cannot submit text")
        self.render_input(snapshot)
        if self.closed or not self.focused or owner.focus is not self.focus:
            return True
        self.snapshot = {**deepcopy(snapshot), "commits": [], "candidateCompletions": []}
        self.reference = deepcopy(value.reference)
        if (self.batch is not None and (not snapshot.get("preedit")
                or self.batch["authority"]["compositionRevision"] != snapshot["compositionRevision"])):
            self.batch = None
        self.render_candidates(self.snapshot, self.batch)
        return True

    def _publish_candidates(self, value):
        batch = value.batch
        if (self.closed or self.blocked or not self.focused or value.context != self.context
                or value.reference != self.reference
                or batch["authority"]["compositionRevision"] != self.snapshot.get("compositionRevision")):
            return False
        # Candidate arrival updates no input text and completes no native key.
        focus = self.focus
        self.render_candidates(self.snapshot, batch)
        if self.closed or not self.focused or self.focus is not focus:
            return False
        self.batch = deepcopy(batch)
        return True

    def _finish(self, owner, consumed):
        if owner.finished:
            return
        owner.finished = True
        self.pending.discard(owner)
        if owner.reply is not None:
            owner.reply(consumed)

    def _finish_pending(self):
        for owner in tuple(self.pending):
            self._finish(owner, True)

    def _notice(self, notice):
        if self.closed:
            return
        if (notice.code.startswith("reading_")
                and notice.phase in ("not-sent", "response-unknown", "not-applied", "application-unknown")):
            self.blocked = True
        try:
            self.notify(notice)
        except Exception:
            # An auxiliary message cannot own or prevent the original reply.
            LOGGER.exception("Could not display reading notice %s", notice.code)

    def close(self):
        if self.closed:
            return
        self.closed = True
        self.focused = False
        self.focus = object()
        self.coordinator.close()
        self._finish_pending()
