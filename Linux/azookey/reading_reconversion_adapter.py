"""Keep IBus replacement authority and recovery in the original input field."""
import logging

import gi

gi.require_version("IBus", "1.0")
from gi.repository import IBus

from .native_key_reply import NativeKeyReply
from .reading_reconversion_input import ReadingReconversionInput
from .reconversion import ReconversionCoordinator, surrounding_context
from .reconversion_strings import message


LOGGER = logging.getLogger(__name__)


class ReadingReconversionAdapter:
    def __init__(self, engine, *, schedule_timeout, remove_timeout):
        self.engine = engine
        self.document = None
        self.input_error_visible = False
        self.input = ReadingReconversionInput(
            engine.frontend, context=self.current_context, recover=self.recover,
            publish_recovery=self.publish_recovery,
        )
        self.coordinator = ReconversionCoordinator(
            self.input, context=self.current_context, delete=engine.delete_surrounding_text,
            status=self.status, replay=self.replay, forward=engine.forward_key_event,
            schedule_timeout=schedule_timeout, remove_timeout=remove_timeout,
            confirm_replacement=self.input.confirm_replacement,
        )

    @property
    def active(self):
        return self.coordinator.active

    def current_context(self):
        if (not self.engine.focused or self.engine.sensitive or self.engine.focus_identity is None
                or not self.engine.client_capabilities & IBus.Capabilite.SURROUNDING_TEXT):
            return None
        return self.document

    def surrounding_changed(self, text, cursor, anchor):
        self.document = surrounding_context(
            text, cursor, anchor, sensitive=self.engine.sensitive,
            can_replace=bool(self.engine.client_capabilities & IBus.Capabilite.SURROUNDING_TEXT),
        )
        self.coordinator.surrounding_changed()

    def process(self, event, key, *, key_reply):
        return self.coordinator.process(event, key, key_reply=key_reply)

    def clear(self):
        focus = self.engine.frontend.focus
        self.input.retire()
        self.document = None
        self.input_error_visible = False
        # Completing an old native invocation may synchronously activate a new
        # field. Detach the old state before allowing that callback to run.
        cancelled_epoch = self.coordinator.epoch + 1
        self.coordinator.cancel()
        if self.engine.frontend.focus is focus and self.coordinator.epoch == cancelled_epoch:
            self.status("")

    def status(self, value):
        try:
            self.engine.update_auxiliary_text(IBus.Text.new_from_string(value), bool(value))
        except Exception:
            LOGGER.exception("Could not display reconversion status")

    def render_input_error(self, reason):
        previous = self.input_error_visible
        self.input_error_visible = bool(reason)
        if reason or previous:
            self.status(message(reason) if reason else "")

    def publish_recovery(self, value):
        self.engine.renderer.dismiss()
        self.engine.update_preedit_text_with_mode(
            IBus.Text.new_from_string(value), len(value), bool(value), IBus.PreeditFocusMode.COMMIT,
        )

    def recover(self, value):
        value, recovery = self.coordinator.take_recovery(value)
        self.input.retire()
        try:
            self.engine.frontend.reset()
            can_restore = (self.engine.focused and not self.engine.sensitive
                           and self.coordinator.is_current_recovery(recovery))
            if value and can_restore:
                self.engine.commit_text(IBus.Text.new_from_string(value))
        except Exception:
            self.coordinator.finish_recovery(recovery, allow_native=False)
            raise
        self.coordinator.finish_recovery(recovery, allow_native=can_restore)

    def replay(self, *key, key_reply):
        reply = NativeKeyReply(key_reply)
        if self.engine.destroyed or self.engine.private or not self.engine.focused:
            reply.finish(True)
            return
        previous, self.engine.native_key_reply = self.engine.native_key_reply, reply
        try:
            consumed = self.engine.do_process_key_event(*key)
            if not reply.deferred:
                reply.finish(consumed)
        finally:
            self.engine.native_key_reply = previous

    def register_properties(self):
        properties = IBus.PropList()
        for name, key in (("undo-commit", "undo_menu"), ("reconvert", "selection_menu")):
            label = IBus.Text.new_from_string(message(key))
            properties.append(IBus.Property.new(
                name, IBus.PropType.NORMAL, label, "", label, True, True, IBus.PropState.UNCHECKED, None,
            ))
        self.engine.register_properties(properties)

    def activate_property(self, name):
        if name in ("undo-commit", "reconvert"):
            self.coordinator.prompt_menu(undo=name == "undo-commit")
