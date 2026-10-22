"""Keep the candidate popup in the work area without covering the caret."""

from dataclasses import dataclass

# The GTK tree reserves this leading space before its first document word.
COLUMN_START_INSET = 12


@dataclass(frozen=True)
class PopupPlacement:
    x: int
    y: int
    width: int
    height: int
    side: str


def popup_placement(*, cursor, work_area, popup_size, preferred_side=None, column_anchor_x=None):
    left, top, area_width, area_height = work_area
    right, bottom = left + area_width, top + area_height
    cursor_x, cursor_y, cursor_width, cursor_height = cursor
    # IBus commonly reports a zero-width insertion caret. Leave its pixel clear.
    cursor_right = cursor_x + max(1, cursor_width)
    cursor_bottom = cursor_y + cursor_height
    spaces = {
        "below": max(0, bottom - max(top, cursor_bottom)),
        "above": max(0, min(bottom, cursor_y) - top),
        "right": max(0, right - max(left, cursor_right)),
        "left": max(0, min(right, cursor_x) - left),
    }
    width, height = min(popup_size[0], area_width), min(popup_size[1], area_height)
    fitting = [
        side for side in ("below", "above", "right", "left")
        if (height if side in ("below", "above") else width) <= spaces[side]
    ]
    if fitting:
        # Keep an already usable side while candidates change or a list scrolls.
        side = preferred_side if preferred_side in fitting else fitting[0]
    else:
        # Preserve readable line width first. A bounded viewport keeps even the
        # confirmation controls reachable when their fixed height does not fit.
        side = max(("below", "above"), key=spaces.get)
        height = spaces[side]
        if not height:
            side = max(("right", "left"), key=spaces.get)
            width = spaces[side]
            height = min(popup_size[1], area_height)
    if not width or not height:
        return None  # A caret covering the whole work area leaves no safe region.
    desired_x = cursor_x if column_anchor_x is None else column_anchor_x - COLUMN_START_INSET
    x = max(left, min(desired_x, right - width))
    y = max(top, min(cursor_y, bottom - height))
    if side == "below":
        y = max(top, cursor_bottom)
    elif side == "above":
        y = min(bottom, cursor_y) - height
    elif side == "right":
        x = max(left, cursor_right)
    else:
        x = min(right, cursor_x) - width
    return PopupPlacement(int(x), int(y), int(width), int(height), side)
