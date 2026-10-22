"""Native ATK actions for the custom candidate drawing."""

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Atk", "1.0")
from gi.repository import Atk, Gtk


class CandidateAccessible(Gtk.ButtonAccessible):
    def do_ref_state_set(self):
        states = Gtk.ButtonAccessible.do_ref_state_set(self)
        button = self.get_widget()
        if button and button.selected:
            states.add_state(Atk.StateType.SELECTED)
        return states


class CandidateAction(Gtk.Button):
    """A real button supplies ATK activation without taking document focus."""

    def __init__(self, activate):
        super().__init__()
        self.selected = False
        self.activation_token = None
        self.pressed_token = None
        self.set_can_focus(False)
        self.set_focus_on_click(False)
        self.get_style_context().add_class("candidate-action")
        self.connect("button-press-event", self.begin_press)
        self.connect_after("button-release-event", self.end_press)
        self.connect("clicked", lambda _button: self.activate_current(activate))

    def begin_press(self, _button, event):
        if event.button == 1:
            self.pressed_token = self.activation_token
        return False

    def end_press(self, *_args):
        self.pressed_token = None
        return False

    def activate_current(self, activate):
        # A release after an intervening update must not confirm the new selection.
        if self.pressed_token is None or self.pressed_token == self.activation_token:
            activate(self)

    def update_accessibility(self, name, *, selected, description):
        accessible = self.get_accessible()
        if accessible.get_name() != name:
            accessible.set_name(name)
        if accessible.get_description() != description:
            accessible.set_description(description)
        if self.selected != selected:
            self.selected = selected
            accessible.notify_state_change(Atk.StateType.SELECTED, selected)


CandidateAction.set_accessible_type(CandidateAccessible)
