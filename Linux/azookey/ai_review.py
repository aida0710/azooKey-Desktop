"""Coordinate send review without taking ownership of ordinary input."""
from .ai_confirmation import AISuggestionConfirmationWindow
from .ai_scope import AISuggestionConfirmation


class AISuggestionReview:
    def __init__(self, *, current_state, send, save_context):
        self.current_state = current_state
        self.send = send
        self.save_context = save_context
        self.confirmation = None
        self.window = None

    def show(self, scope, snapshot, location):
        self.cancel()
        state = self.current_state()
        if not state["focused"] or state["pending_input"]:
            return
        self.confirmation = AISuggestionConfirmation(
            scope, snapshot.get("generation", -1), snapshot.get("reading", ""),
            state["input_epoch"], state["bridge_generation"],
        )
        self.window = AISuggestionConfirmationWindow(
            scope, on_send=self.confirm, on_cancel=self.cancel, on_context_changed=self.scope_changed,
        )
        self.window.show_near(location)

    def scope_changed(self, scope):
        if self.confirmation:
            self.confirmation.scope = scope
            if self.save_context(scope.include_context) is False:
                self.window.context_save_failed()

    def confirm(self):
        confirmation = self.confirmation
        state = self.current_state()
        self.cancel()
        if (confirmation and state["focused"] and not state["pending_input"]
                and confirmation.matches(state["snapshot"], state["input_epoch"], state["bridge_generation"])):
            self.send(state["snapshot"], confirmation.scope)

    def cancel(self):
        self.confirmation = None
        if self.window:
            window, self.window = self.window, None
            window.destroy()
        return True

    def key(self, event):
        if not self.confirmation or event is None:
            return False
        action = self.confirmation.keyboard_action(event)
        if action == "send":
            self.confirm()
        elif action == "toggle":
            self.window.scope_view.toggle_context()
        elif action == "cancel":
            self.cancel()
        else:
            self.cancel()
            return False
        return True
