"""Require pointer movement before showing candidate hover details."""

import gi

gi.require_version("Gdk", "3.0")
from gi.repository import Gdk


class CandidateHover:
    def __init__(self, widget, *, entered=None, left=None):
        self.is_hovering = False
        self.tooltip_text = None
        self.entered = entered
        self.left = left
        widget.add_events(Gdk.EventMask.POINTER_MOTION_MASK | Gdk.EventMask.LEAVE_NOTIFY_MASK)
        widget.connect("motion-notify-event", self.motion)
        widget.connect("leave-notify-event", self.leave)
        widget.connect("unmap", self.leave)
        widget.set_has_tooltip(True)
        widget.connect("query-tooltip", self.tooltip)

    def motion(self, widget, event):
        # XWayland can synthesize a normal enter at a cached position on map.
        # Only movement proves the pointer reached this currently mapped widget.
        if not self.contains_pointer(widget, event):
            return self.leave(widget)
        if not self.is_hovering:
            self.is_hovering = True
            if self.entered is not None:
                self.entered(widget)
        return False

    @staticmethod
    def contains_pointer(widget, event):
        # A button grab can also deliver motion from outside its bounds.
        toplevel = widget.get_toplevel()
        position = widget.translate_coordinates(toplevel, 0, 0)
        window = toplevel.get_window()
        if not widget.get_mapped() or position is None or window is None:
            return False
        _, root_x, root_y = window.get_origin()
        left, top = root_x + position[0], root_y + position[1]
        return (left <= event.x_root < left + widget.get_allocated_width()
                and top <= event.y_root < top + widget.get_allocated_height())

    def leave(self, widget, *_arguments):
        if self.is_hovering:
            self.is_hovering = False
            if self.left is not None:
                self.left(widget)
        return False

    def tooltip(self, _widget, _x, _y, keyboard_mode, tooltip):
        # Keyboard help does not depend on a pointer. These non-focusing controls
        # also keep their complete descriptions exposed through ATK.
        if self.tooltip_text and (keyboard_mode or self.is_hovering):
            tooltip.set_text(self.tooltip_text)
            return True
        return False
