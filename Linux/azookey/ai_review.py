"""Show Core's suggestion review without taking ownership of ordinary input."""
from .ai_confirmation import AISuggestionConfirmationWindow
from .ime_shortcuts import binding_command

# Physical modifier presses must not dismiss a review before Control+S arrives.
MODIFIER_KEYS = {
    0xFFE1, 0xFFE2,  # Shift
    0xFFE3, 0xFFE4,  # Control
    0xFFE7, 0xFFE8,  # Meta
    0xFFE9, 0xFFEA,  # Alt
    0xFFEB, 0xFFEC,  # Super
    0xFFED, 0xFFEE,  # Hyper
    0xFE03,  # AltGr
}


class AISuggestionReview:
    """Core decides what is reviewed and whether a confirmation may send it;
    this shows the review and reports the user's choice."""

    def __init__(self, *, current_state, send, save_context):
        self.current_state = current_state
        self.send = send
        self.save_context = save_context
        # Core's review, with the user's current context choice.
        self.confirmation = None
        self.window = None

    def show(self, review, location):
        self.cancel()
        state = self.current_state()
        # A queued key will close the review in Core; showing it would flicker.
        if not state["focused"] or state["pending_input"]:
            return
        self.confirmation = dict(review)
        self.window = AISuggestionConfirmationWindow(
            review, on_send=self.confirm, on_cancel=self.cancel, on_context_changed=self.context_changed,
        )
        self.window.show_near(location)

    def context_changed(self, included):
        if self.confirmation:
            self.confirmation["includeContext"] = included
            if self.save_context(included) is False:
                self.window.context_save_failed()

    def confirm(self):
        confirmation = self.confirmation
        self.cancel()
        if confirmation:
            self.send(confirmation["id"], confirmation["includeContext"])

    def cancel(self):
        self.confirmation = None
        if self.window:
            window, self.window = self.window, None
            window.destroy()
        return True

    def key(self, event):
        if not self.confirmation or event is None:
            return False
        command = binding_command(self.confirmation["bindings"], event)
        if command == "send":
            self.confirm()
        elif command == "toggleContext":
            self.window.scope_view.toggle_context()
        elif command == "cancel":
            self.cancel()
        else:
            self.cancel()
            return False
        return True
