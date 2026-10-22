"""Text for the shortcut and prompt-history error codes Core returns."""
from .i18n import text

# DesktopShortcutText.Failure and AIPromptHistory.Failure in Core.
_MESSAGE_KEYS = {
    "format": "ai.shortcut.error.format",
    "modifierRequired": "ai.shortcut.error.modifier-required",
    "duplicateShortcut": "ai.shortcut.error.duplicate",
    "saveFailed": "ai.history.error.save",
}


def ai_error_message(code):
    return text(_MESSAGE_KEYS[code])
