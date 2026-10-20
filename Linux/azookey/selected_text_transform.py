"""Keep an AI preview until its original input field is verified or copied."""
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("IBus", "1.0")
from gi.repository import GLib, Gtk, IBus

from .ai_transform_target import PendingTransformation, TransformationTarget
from .focused_text import inspect_focused_text
from .prompt_dialog import PromptDialog


# Lack of a focus notification is failure, never permission to write later.
FOCUS_RETURN_TIMEOUT_MS = 2000


class SelectedTextTransformation:
    def __init__(self, engine):
        self.engine = engine
        self.dialog = None
        self.active = False
        self.revision = object()
        self.request_revision = None
        self.target = None
        self.pending = None
        self.verifying = False
        self.restore_timeout = None
        self.dismissal_focus_revision = None
        self.dismissal_from_dialog = False
        self.opening_focus_revision = None
        self.opening_focus_seen = False
        self.opening_reset_pending = False

    def show(self, initial_prompt=""):
        if self.active:
            return
        selection = self.engine.current_transform_selection()
        if not self.engine.selected_text or self.engine.sensitive:
            return
        self.active = True
        self.revision = object()
        revision = self.revision
        focus_revision = self.engine.focus_revision
        scope = self.engine.make_ai_scope(self.engine.selected_text)
        snapshot = dict(self.engine.snapshot)

        def captured(accessible):
            if revision is not self.revision:
                return
            if focus_revision is not self.engine.focus_revision:
                self.close()
                return
            if accessible and selection == self.engine.current_transform_selection():
                self.target = TransformationTarget(selection, accessible)
            self.dialog = PromptDialog(
                lambda prompt, selected_scope, finish: self.request_preview(
                    snapshot, scope=selected_scope, prompt=prompt, finish=finish),
                initial_prompt, scope=scope, on_context_changed=self.engine.save_ai_context,
            )
            self.dialog.set_modal(True)
            self.dialog.set_target_available(self.target is not None)
            self.dialog.connect("response", self.respond)
            self.dialog.connect("notify::is-active", self.dialog_focus_changed)
            self.opening_focus_revision = focus_revision if self.target else None
            self.dialog.show_all()
            self.dialog.present()

        if selection is None:
            captured(None)
        else:
            self.inspect(selection, captured)

    def request_preview(self, snapshot, *, scope, prompt, finish):
        revision, dialog = self.revision, self.dialog
        prompt_revision = dialog.preview.pending_revision
        request_revision = self.request_revision = object()

        def completed(text, *, input_context_unchanged=True):
            if (not self.active or revision is not self.revision or dialog is not self.dialog
                    or request_revision is not self.request_revision
                    or prompt_revision is None or prompt_revision != dialog.preview.pending_revision):
                return
            self.request_revision = None
            if not input_context_unchanged:
                # A reply must not bring the prompt in front of another editor.
                self.discard_target()
                dialog.set_target_available(False)
            finish(text)

        self.engine.start_ai(snapshot, scope, prompt=prompt, completion=completed)

    @staticmethod
    def inspect(selection, completion):
        def work():
            inspected = inspect_focused_text(selection)
            GLib.idle_add(lambda: completion(inspected) or GLib.SOURCE_REMOVE)
        threading.Thread(target=work, daemon=True).start()

    def dialog_focus_changed(self, dialog, _property):
        if dialog is not self.dialog or self.opening_focus_revision is None:
            return
        if dialog.is_active():
            self.opening_focus_seen = True
            self.opening_reset_pending = False
            dialog.set_target_available(self.target is not None)
            if self.engine.focus_revision is not self.opening_focus_revision:
                self.finish_opening_focus()
        elif self.opening_focus_seen:
            self.finish_opening_focus()

    def reset_input(self):
        # Qt resets its old input context before delivering focus-out when our
        # prompt takes focus. Only that original epoch can defer invalidation.
        # GTK activation is still required before this transfer is accepted.
        if (self.target is not None and self.dialog is not None and self.dialog.get_visible()
                and self.pending is None and self.opening_focus_revision is self.engine.focus_revision):
            active = self.dialog.is_active()
            if not self.opening_focus_seen or active:
                self.opening_focus_seen |= active
                self.opening_reset_pending = not active
                self.dialog.set_target_available(active)
                return
        # Hiding our active prompt also resets its outgoing IBus context.
        # Once focus returns, resets again cancel even a delayed AT-SPI read.
        if (self.pending is not None and not self.verifying and self.dismissal_from_dialog
                and self.engine.focus_revision is self.dismissal_focus_revision
                and self.dialog is not None and not self.dialog.get_visible()):
            return
        self.invalidate_target()

    def finish_opening_focus(self):
        self.opening_focus_revision = None
        self.opening_focus_seen = False
        self.opening_reset_pending = False

    def respond(self, _dialog, response):
        if response != Gtk.ResponseType.OK:
            self.close()
            return
        if self.pending:
            return
        if self.target is None or not self.dialog.result or self.opening_reset_pending:
            self.reject()
            return
        self.finish_opening_focus()
        self.pending = PendingTransformation(self.target, self.dialog.result)
        self.dismissal_focus_revision = self.engine.focus_revision
        self.dismissal_from_dialog = self.dialog.is_active()
        self.dialog.hide()
        self.restore_timeout = GLib.timeout_add(FOCUS_RETURN_TIMEOUT_MS, self.focus_return_expired)
        self.engine.get_surrounding_text()
        GLib.idle_add(self.context_changed)

    def focus_entered(self):
        context = self.engine.current_transform_context()
        # Closing the prompt can pass through IBus's temporary fake context.
        # Only returning to the original context starts a new target read.
        if self.pending and context and context.context_id == self.target.input_selection.context_id:
            self.context_changed()

    def context_changed(self):
        if (self.opening_reset_pending and self.engine.focus_revision is not self.opening_focus_revision
                and self.engine.current_transform_selection() is not None):
            # A different editor was reached before the prompt gained focus.
            # Even matching text is not an acknowledgement from our window.
            return self.reject()
        if not self.pending:
            return GLib.SOURCE_REMOVE
        context = self.engine.current_transform_context()
        if context is None:
            return GLib.SOURCE_REMOVE
        # The prompt's last input context can outlive hide() until focus-out is
        # dispatched. Wait for the notification, not a guessed sleep duration.
        if self.engine.focus_revision is self.dismissal_focus_revision:
            return GLib.SOURCE_REMOVE
        if not context.matches_original(self.target.input_selection):
            return self.reject()
        if self.verifying:
            return GLib.SOURCE_REMOVE
        revision, pending = self.revision, self.pending
        focus_revision = self.engine.focus_revision
        self.verifying = True

        def verified(accessible):
            if revision is not self.revision or pending is not self.pending:
                return
            self.verifying = False
            current = self.engine.current_transform_context()
            if focus_revision is not self.engine.focus_revision:
                self.reject()
                return
            replacement = pending.take_after_focus(current, accessible)
            if replacement is None:
                self.reject()
                return
            # Consume the one-shot permission before emitting a re-entrant
            # commit signal. Closing the hidden preview does not change focus.
            self.close()
            self.engine.commit_text(IBus.Text.new_from_string(replacement))

        # This is a comparison target, never a substitute for current IBus
        # text. The fresh AT-SPI result must match its original identity/range.
        self.inspect(self.target.input_selection, verified)
        return GLib.SOURCE_REMOVE

    def focus_return_expired(self):
        self.restore_timeout = None
        return self.reject()

    def input_changed(self):
        if self.pending or self.opening_reset_pending:
            self.reject()
        elif self.active and self.dialog is None:
            self.close()

    def invalidate_target(self):
        if self.dialog is None:
            self.close()
        else:
            self.reject()

    def discard_target(self):
        self.cancel_timeout()
        self.finish_opening_focus()
        self.target = self.pending = None
        self.dismissal_from_dialog = False
        self.verifying = False

    def reject(self):
        self.discard_target()
        if self.dialog:
            self.dialog.set_target_available(False)
            self.dialog.show_all()
            self.dialog.present()
        return GLib.SOURCE_REMOVE

    def cancel_timeout(self):
        if self.restore_timeout is not None:
            GLib.source_remove(self.restore_timeout)
            self.restore_timeout = None

    def close(self):
        self.revision = object()
        self.request_revision = None
        self.cancel_timeout()
        self.finish_opening_focus()
        self.active = False
        self.target = self.pending = None
        self.dismissal_from_dialog = False
        self.verifying = False
        if self.dialog:
            self.dialog.destroy()
            self.dialog = None
