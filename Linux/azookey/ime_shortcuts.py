"""Route the chords Core gives a meaning to, using the bindings Core publishes.

IBus needs an answer for each key at once, so keys are matched here against
Core's `ime-shortcuts` bindings to decide which ones Core must see. Core
decides what they do when they arrive.
"""
from enum import Enum


# Modifier bits of the bridge key protocol, not the native IBus mask.
CONTROL, OPTION, COMMAND = 2, 4, 8


class IMEShortcut(str, Enum):
    """Commands of Core's bindings, plus the state before Core has answered."""
    SUGGESTION = "suggestion"
    UNICODE = "unicode"
    PROMPT = "prompt"
    UNPUBLISHED = "unpublished"


_published = None


def publish(bindings):
    """Use the bindings from Core's latest `ime-shortcuts` reply."""
    global _published
    _published = list(bindings)


def binding_command(bindings, event):
    """The command of the first binding the event matches exactly, or None."""
    if not event:
        return None
    characters = (event.get("charactersIgnoringModifiers") or "").lower()
    for binding in bindings:
        if binding["modifiers"] != event.get("modifierFlags", 0):
            continue
        if binding.get("keyCode") is not None:
            if binding["keyCode"] == event.get("keyCode"):
                return binding["command"]
        elif binding.get("key") == characters:
            return binding["command"]
    return None


def ime_shortcut(event):
    """Core's command for an idle chord. Before Core has answered, every
    Control chord goes to Core instead of being guessed native."""
    if not event:
        return None
    if _published is None:
        return IMEShortcut.UNPUBLISHED if event.get("modifierFlags", 0) & CONTROL else None
    idle = [binding for binding in _published if binding["command"] != IMEShortcut.PROMPT]
    command = binding_command(idle, event)
    return IMEShortcut(command) if command else None


def opens_prompt(event):
    """Whether a chord may open the selected-text prompt. Before Core has
    answered, every Control, Alt or Super chord goes to Core."""
    if not event:
        return False
    if _published is None:
        return bool(event.get("modifierFlags", 0) & (CONTROL | OPTION | COMMAND))
    prompts = [binding for binding in _published if binding["command"] == IMEShortcut.PROMPT]
    return binding_command(prompts, event) is not None
