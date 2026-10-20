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
        self.target = None
        self.pending = None
        self.verifying = False
        self.restore_timeout = None
        self.dismissal_focus_revision = None

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
                lambda prompt, selected_scope, finish: self.engine.start_ai(
                    snapshot, selected_scope, prompt=prompt, completion=finish),
                initial_prompt, scope=scope, on_context_changed=self.engine.save_ai_context,
            )
            self.dialog.set_modal(True)
            self.dialog.set_target_available(self.target is not None)
            self.dialog.connect("response", self.respond)
            self.dialog.show_all()
            self.dialog.present()

        if selection is None:
            captured(None)
        else:
            self.inspect(selection, captured)

    @staticmethod
    def inspect(selection, completion):
        def work():
            inspected = inspect_focused_text(selection)
            GLib.idle_add(lambda: completion(inspected) or GLib.SOURCE_REMOVE)
        threading.Thread(target=work, daemon=True).start()

    def respond(self, _dialog, response):
        if response != Gtk.ResponseType.OK:
            self.close()
            return
        if self.pending:
            return
        if self.target is None or not self.dialog.result:
            self.reject()
            return
        self.pending = PendingTransformation(self.target, self.dialog.result)
        self.dismissal_focus_revision = self.engine.focus_revision
        self.dialog.hide()
        self.restore_timeout = GLib.timeout_add(FOCUS_RETURN_TIMEOUT_MS, self.focus_return_expired)
        self.engine.get_surrounding_text()
        GLib.idle_add(self.context_changed)

    def context_changed(self):
        if not self.pending or self.verifying:
            return GLib.SOURCE_REMOVE
        selection = self.engine.current_transform_selection()
        if selection is None:
            return GLib.SOURCE_REMOVE
        # The prompt's last input context can outlive hide() until focus-out is
        # dispatched. Wait for the notification, not a guessed sleep duration.
        if self.engine.focus_revision is self.dismissal_focus_revision:
            return GLib.SOURCE_REMOVE
        if selection != self.target.input_selection:
            return self.reject()
        revision, pending = self.revision, self.pending
        focus_revision = self.engine.focus_revision
        self.verifying = True

        def verified(accessible):
            if revision is not self.revision or pending is not self.pending:
                return
            self.verifying = False
            current = self.engine.current_transform_selection()
            if focus_revision is not self.engine.focus_revision:
                self.reject()
                return
            replacement = pending.take(current, accessible)
            if replacement is None:
                self.reject()
                return
            # Consume the one-shot permission before emitting a re-entrant
            # commit signal. Closing the hidden preview does not change focus.
            self.close()
            self.engine.commit_text(IBus.Text.new_from_string(replacement))

        self.inspect(selection, verified)
        return GLib.SOURCE_REMOVE

    def focus_return_expired(self):
        self.restore_timeout = None
        return self.reject()

    def input_changed(self):
        if self.pending:
            self.reject()
        elif self.active and self.dialog is None:
            self.close()

    def invalidate_target(self):
        if self.dialog is None:
            self.close()
        else:
            self.reject()

    def reject(self):
        self.cancel_timeout()
        self.target = self.pending = None
        self.verifying = False
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
        self.cancel_timeout()
        self.active = False
        self.target = self.pending = None
        self.verifying = False
        if self.dialog:
            self.dialog.destroy()
            self.dialog = None
