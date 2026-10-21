"""Route replacement plans through reading ownership and dictionary-only work."""
from copy import deepcopy
from dataclasses import dataclass

from . import reconversion_protocol
from .reconversion import same_document


@dataclass(frozen=True)
class DeletedReconversionText:
    focus: object
    document: dict
    text: str


class ReadingReconversionInput:
    def __init__(self, frontend, *, context, recover, publish_recovery):
        self.frontend = frontend
        self.context = context
        self.recover = recover
        self.publish_recovery = publish_recovery
        self.epoch = object()
        self.deleted_text = None

    @property
    def pending(self):
        return self.frontend.pending

    @property
    def snapshot(self):
        return self.frontend.snapshot

    def submit(self, operation, *, payload, completion):
        payload = deepcopy(payload)
        epoch, focus = self.epoch, self.frontend.focus
        if operation == "reconvert" and "reading" not in payload:
            try:
                generation = self.frontend.coordinator.prepare_reconversion_worker()
            except (OSError, RuntimeError, ValueError):
                generation = None
            if generation is None:
                self._complete(completion, {"reconversionError": "replacement_unavailable"})
                return
            payload["candidateWorkerGeneration"] = generation
        self.frontend.submit_reconversion(
            operation, payload,
            completion=lambda response: self._received(
                response, payload=payload, epoch=epoch, focus=focus, completion=completion),
        )

    def _current(self, epoch, focus):
        return (self.epoch is epoch and self.frontend.focus is focus
                and self.frontend.focused and not self.frontend.closed)

    def _received(self, response, *, payload, epoch, focus, completion):
        if not self._current(epoch, focus):
            return
        request = response.get("reconversionReadingRequest")
        if request is None:
            self._complete(completion, self._snapshot(response))
            return
        if not same_document(payload["reconversionContext"], self.context()):
            self._complete(completion, {"reconversionError": "changed_context"})
            return
        try:
            self.frontend.coordinator.candidates.resolve_reconversion_reading(
                request, lambda reply: self._resolved(
                    reply, request=request, context=payload["reconversionContext"],
                    epoch=epoch, focus=focus, completion=completion),
            )
        except (OSError, RuntimeError, ValueError):
            self._complete(completion, {"reconversionError": "replacement_unavailable"})

    def _resolved(self, reply, *, request, context, epoch, focus, completion):
        if not self._current(epoch, focus):
            return
        if not same_document(context, self.context()):
            self._complete(completion, {"reconversionError": "changed_context"})
            return
        candidates = self.frontend.coordinator.candidates
        if (reply.error or (reply.worker_generation, reply.transport_epoch) != candidates.transport.identity
                or reply.worker_generation != request["workerGeneration"]):
            self._complete(completion, {"reconversionError": "replacement_unavailable"})
            return
        try:
            resolved = reconversion_protocol.reading_result(reply.reconversion_reading, request=request)
        except ValueError:
            self._complete(completion, {"reconversionError": "replacement_unavailable"})
            return
        self.frontend.submit_reconversion(
            "resolve-reconversion", {"reconversionContext": context, "reconversionReadingResult": resolved},
            completion=lambda response: self._received(
                response, payload={"reconversionContext": context}, epoch=epoch, focus=focus, completion=completion),
        )

    def confirm_replacement(self, *, replacement, context, is_current, complete):
        if not is_current():
            return
        self.deleted_text = DeletedReconversionText(
            focus=self.frontend.focus, document=deepcopy(context), text=replacement["text"],
        )
        epoch, focus = self.epoch, self.frontend.focus
        try:
            # The client has acknowledged deletion. Its old field must retain
            # this exact original even if focus leaves before Core can confirm.
            self.publish_recovery(replacement["text"])
        except Exception:
            self.recover_pending()
            raise
        if not self._current(epoch, focus) or not is_current():
            return

        def confirmed(response):
            if not self._current(epoch, focus):
                return
            snapshot = self._snapshot(response)
            if not (snapshot.get("error") or snapshot.get("reconversionError")):
                self.deleted_text = None
            self._complete(complete, snapshot)

        # Only this owner's formal response can replace the recovery text with
        # a reading. Dictionary arrival itself has no input effects.
        self.frontend.submit_reconversion(
            "confirm-reconversion",
            {"reconversionToken": replacement["token"], "reconversionContext": deepcopy(context)},
            completion=confirmed, publish_guard=is_current,
        )

    @staticmethod
    def _snapshot(response):
        return {**response.get("snapshot", {}),
                **{name: deepcopy(response[name])
                   for name in reconversion_protocol.RESPONSE_FIELDS | {"error"} if name in response}}

    def _complete(self, completion, snapshot):
        try:
            completion(snapshot)
        except Exception:
            # A failed auxiliary view must still retire the original start key
            # and any later keys held by the shared replacement coordinator.
            self.recover_pending()
            raise

    def cancel(self):
        self.retire()
        self.frontend.reset()

    def retire(self):
        self.epoch = object()
        self.deleted_text = None

    def recover_pending(self):
        deleted, self.deleted_text = self.deleted_text, None
        self.epoch = object()
        can_restore = (deleted is not None and deleted.focus is self.frontend.focus
                       and self.frontend.focused and same_document(deleted.document, self.context()))
        self.recover(deleted.text if can_restore else "")
