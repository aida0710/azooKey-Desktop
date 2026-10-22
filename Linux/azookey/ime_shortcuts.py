"""Identify IME operations whose meaning must be resolved by Core."""
from enum import Enum, auto


# Core's key-event mask differs from the native IBus modifier mask.
SHIFT = 1
CONTROL = 2


class IMEShortcut(Enum):
    SUGGESTION = auto()
    UNICODE = auto()


def ime_shortcut(event):
    if not event:
        return None
    key = event.get("charactersIgnoringModifiers")
    modifiers = event.get("modifierFlags", 0)
    if modifiers == CONTROL and key == "s":
        return IMEShortcut.SUGGESTION
    if modifiers == CONTROL | SHIFT and key == "u":
        return IMEShortcut.UNICODE
    return None
