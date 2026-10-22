"""Keep an AI preview until Core verifies its original input field, or the user copies it."""
import threading

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("IBus", "1.0")
from gi.repository import GLib, Gtk, IBus

from .focused_text import inspect_focused_text
from .prompt_dialog import PromptDialog


# Lack of a focus notification is failure, never permission to write later.
FOCUS_RETURN_TIMEOUT_MS = 2000


class SelectedTextTransformation:
    """IBus and GTK timing around Core's `ai-transform-*` decisions.

    Core decides what is sent, which preview is current, and whether a result
    may replace the original selection. This class follows the IBus focus and
    Reset order that tells when to ask Core, reads the AT-SPI witness, and
    shows the prompt. Each Core reply is checked against the focus at the time
    of the request before it is acted on.
    """

    def __init__(self, engine):
        self.engine = engine
        self.dialog = None
        self.active = False
        self.revision = object()
        # Core's identifier for this prompt's transformation.
        self.transformation = None
        self.context_characters = 0
        self.original_identity = None
        self.target_available = False
        # Apply was confirmed; waiting for focus to return to the original field.
        self.pending = False
        self.verifying = False
        self.restore_timeout = None
        self.dismissal_focus_revision = None
        self.dismissal_from_dialog = False
        self.opening_focus_revision = None
        self.opening_focus_seen = False
        self.opening_reset_pending = False

    def ask_core(self, operation, completion=None, **values):
        """Ask Core about this prompt's transformation. A failed or stale
        reply reaches the completion as None; a closed prompt gets nothing."""
        revision = self.revision

        def delivered(reply):
            if completion and revision is self.revision:
                completion(None if reply is None or reply.get("stale") else reply)

        self.engine.ai.submit(f"ai-transform-{operation}", completion=delivered,
                              ai={"transformation": self.transformation, **values})

    def show(self, initial_prompt=""):
        if self.active:
            return
        self.active = True
        self.revision = object()
        revision = self.revision
        focus_revision = self.engine.focus_revision
        field = self.engine.ai_field()
        self.original_identity = field["identity"]

        def opened(reply):
            if revision is not self.revision:
                return
            if reply is None or reply.get("transformation") is None:
                self.close()  # Nothing selected, or a protected field.
                return
            self.transformation = reply["transformation"]
            self.context_characters = reply["contextCharacters"]
            if focus_revision is not self.engine.focus_revision:
                self.close()
            elif reply["needsWitness"]:
                self.capture_target(reply, initial_prompt, focus_revision)
            else:
                self.open_dialog(reply, initial_prompt, target_available=False)

        self.engine.ai.submit("ai-transform-open", completion=opened, ai={"field": field})

    def capture_target(self, opened, initial_prompt, focus_revision):
        """Read the witness, then let Core decide whether the selection can be replaced later."""
        revision = self.revision

        def targeted(target):
            if focus_revision is not self.engine.focus_revision:
                self.close()
                return
            self.open_dialog(opened, initial_prompt, target_available=bool(target and target["targetAvailable"]))

        def captured(witness):
            if revision is not self.revision:
                return
            if focus_revision is not self.engine.focus_revision:
                self.close()
                return
            self.ask_core("target", targeted, field=self.engine.ai_field(), witness=witness)

        self.inspect(self.context_characters, captured)

    def open_dialog(self, opened, initial_prompt, *, target_available):
        self.target_available = target_available
        self.dialog = PromptDialog(
            opened, initial_prompt, request_preview=self.request_preview,
            invalidate_preview=lambda: self.ask_core("invalidate"), on_context_changed=self.engine.save_ai_context,
        )
        self.dialog.set_modal(True)
        self.dialog.set_target_available(target_available)
        self.dialog.connect("response", self.respond)
        self.dialog.connect("notify::is-active", self.dialog_focus_changed)
        self.opening_focus_revision = self.engine.focus_revision if target_available else None
        self.dialog.show_all()
        self.dialog.present()

    def request_preview(self, prompt, pinned, shortcut_text, include_context):
        dialog, edits = self.dialog, self.dialog.edits

        def started(reply):
            if dialog is not self.dialog or dialog.edits != edits or reply is None:
                return
            if reply.get("historyError"):
                dialog.history_failed(reply["historyError"])
            elif reply.get("revision") is not None:
                # Without a revision Core refused: a blank instruction, or one still generating.
                dialog.preview_started()
                self.send_request(dialog, reply)

        self.ask_core("preview", started, prompt=prompt, pinned=pinned, shortcutText=shortcut_text,
                      includeContext=include_context, field=self.engine.ai_field())

    def send_request(self, dialog, started):
        """Send the request Core described; Core decides whether its reply is current."""
        request = started.get("request")
        if request is None:
            dialog.preview_finished(None)  # Core ended this preview without sending anything.
            return

        def completed(text, *, input_context_unchanged=True):
            self.ask_core("result", lambda result: self.preview_delivered(dialog, result), revision=started["revision"],
                          text=text, inputContextChanged=not input_context_unchanged)

        self.engine.start_ai(dict(self.engine.snapshot), request, prompt=request["prompt"], completion=completed)

    def preview_delivered(self, dialog, result):
        if dialog is not self.dialog:
            return
        if result is None:
            # Core no longer holds this transformation (it restarted), so
            # nothing it returns for this prompt can be applied.
            self.forget_target()
            dialog.set_target_available(False)
            dialog.preview_finished(None)
            return
        if not result["accepted"]:
            return
        if self.target_available and not result["targetAvailable"]:
            # Core no longer trusts the target: the reply came after a focus change.
            self.forget_target()
            dialog.set_target_available(False)
        dialog.preview_finished(result.get("text"))

    @staticmethod
    def inspect(context_characters, completion):
        def work():
            witness = inspect_focused_text(context_characters)
            GLib.idle_add(lambda: completion(witness) or GLib.SOURCE_REMOVE)
        threading.Thread(target=work, daemon=True).start()

    def dialog_focus_changed(self, dialog, _property):
        if dialog is not self.dialog or self.opening_focus_revision is None:
            return
        if dialog.is_active():
            self.opening_focus_seen = True
            self.opening_reset_pending = False
            dialog.set_target_available(self.target_available)
            if self.engine.focus_revision is not self.opening_focus_revision:
                self.finish_opening_focus()
        elif self.opening_focus_seen:
            self.finish_opening_focus()

    def reset_input(self):
        # Qt resets its old input context before delivering focus-out when our
        # prompt takes focus. Only that original epoch can defer invalidation.
        # GTK activation is still required before this transfer is accepted.
        if (self.target_available and self.dialog is not None and self.dialog.get_visible()
                and not self.pending and self.opening_focus_revision is self.engine.focus_revision):
            active = self.dialog.is_active()
            if not self.opening_focus_seen or active:
                self.opening_focus_seen |= active
                self.opening_reset_pending = not active
                self.dialog.set_target_available(active)
                return
        # Hiding our active prompt also resets its outgoing IBus context.
        # Once focus returns, resets again cancel even a delayed AT-SPI read.
        if (self.pending and not self.verifying and self.dismissal_from_dialog
                and self.engine.focus_revision is self.dismissal_focus_revision
                and self.dialog is not None and not self.dialog.get_visible()):
            return
        self.invalidate_target()

    def finish_opening_focus(self):
        self.opening_focus_revision = None
        self.opening_focus_seen = False
        self.opening_reset_pending = False

    def respond(self, dialog, response):
        if response != Gtk.ResponseType.OK:
            self.close()
            return
        if self.pending:
            return
        if self.opening_reset_pending:
            self.reject()
            return
        focus_revision = self.engine.focus_revision

        def confirmed(reply):
            if dialog is not self.dialog or self.pending or not self.target_available:
                return
            if (reply is None or not reply["confirmed"] or self.opening_reset_pending
                    or focus_revision is not self.engine.focus_revision):
                self.reject()
                return
            self.finish_opening_focus()
            self.pending = True
            self.dismissal_focus_revision = self.engine.focus_revision
            self.dismissal_from_dialog = dialog.is_active()
            dialog.hide()
            self.restore_timeout = GLib.timeout_add(FOCUS_RETURN_TIMEOUT_MS, self.focus_return_expired)
            self.engine.get_surrounding_text()
            GLib.idle_add(self.context_changed)

        self.ask_core("confirm", confirmed)

    def focus_entered(self):
        # Closing the prompt can pass through IBus's temporary fake context.
        # Only returning to the original context starts a new target check.
        if self.pending and self.original_identity is not None and self.engine.ai_field()["identity"] == self.original_identity:
            self.context_changed()

    def context_changed(self):
        if (self.opening_reset_pending and self.engine.focus_revision is not self.opening_focus_revision
                and self.engine.has_fresh_selection()):
            # A different editor was reached before the prompt gained focus.
            # Even matching text is not an acknowledgement from our window.
            return self.reject()
        if not self.pending:
            return GLib.SOURCE_REMOVE
        field = self.engine.ai_field()
        if field["identity"] is None:
            return GLib.SOURCE_REMOVE
        # The prompt's last input context can outlive hide() until focus-out is
        # dispatched. Wait for the notification, not a guessed sleep duration.
        if self.engine.focus_revision is self.dismissal_focus_revision:
            return GLib.SOURCE_REMOVE
        revision = self.revision
        focus_revision = self.engine.focus_revision

        def checked(reply):
            if revision is not self.revision or not self.pending:
                return
            if reply is None or not reply["matches"]:
                self.reject()
                return
            if self.verifying:
                return
            self.verifying = True
            # This is a comparison target, never a substitute for current IBus
            # text. Core compares the fresh AT-SPI read with the original.
            self.inspect(self.context_characters, lambda witness: self.verified(witness, revision, focus_revision))

        self.ask_core("check", checked, field=field)
        return GLib.SOURCE_REMOVE

    def verified(self, witness, revision, focus_revision):
        if revision is not self.revision or not self.pending:
            return
        self.verifying = False
        if focus_revision is not self.engine.focus_revision:
            self.reject()
            return

        def taken(reply):
            if revision is not self.revision or not self.pending:
                return
            replacement = reply and reply.get("replacement")
            if replacement is None or focus_revision is not self.engine.focus_revision:
                self.reject()
                return
            # Core handed the replacement out once. Close before emitting a
            # re-entrant commit signal; the hidden prompt does not change focus.
            self.close()
            self.engine.commit_text(IBus.Text.new_from_string(replacement))

        self.ask_core("take", taken, field=self.engine.ai_field(), witness=witness)

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

    def forget_target(self):
        self.cancel_timeout()
        self.finish_opening_focus()
        self.target_available = False
        self.pending = False
        self.dismissal_from_dialog = False
        self.verifying = False

    def reject(self):
        self.forget_target()
        self.ask_core("reject")
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
        if self.transformation is not None:
            self.ask_core("close")
        self.revision = object()
        self.transformation = None
        self.forget_target()
        self.active = False
        if self.dialog:
            self.dialog.destroy()
            self.dialog = None
