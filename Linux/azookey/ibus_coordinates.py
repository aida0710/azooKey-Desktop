"""Convert X11 IBus device pixels to GTK application pixels."""
from math import ceil, floor


def logical_cursor_rectangle(rectangle, *, scale_factor):
    """Round outward so placement cannot cover a fractional logical caret."""
    if scale_factor < 1:
        raise ValueError("The GTK scale factor must be positive")
    x, y, width, height = rectangle
    left, top = floor(x / scale_factor), floor(y / scale_factor)
    logical_width = ceil((x + width) / scale_factor) - left if width else 0
    logical_height = ceil((y + height) / scale_factor) - top if height else 0
    return left, top, logical_width, logical_height
