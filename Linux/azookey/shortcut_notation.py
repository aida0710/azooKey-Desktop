"""Core reads and writes the typed shortcut notation, such as Ctrl+Alt+e."""
from .ai_error_messages import ai_error_message


class ShortcutNotation:
    """The bridge's `ai-shortcut` operation for a window that edits a shortcut."""

    def __init__(self, bridge):
        self.bridge = bridge

    def text(self, shortcut):
        return self.bridge.request("ai-shortcut", ai={"shortcut": shortcut}).get("shortcutText", "")

    def parse(self, text):
        """The shortcut, or None for blank text. A rejected notation raises ValueError with its message."""
        reply = self.bridge.request("ai-shortcut", ai={"shortcutText": text})
        if reply.get("shortcutError"):
            raise ValueError(ai_error_message(reply["shortcutError"]))
        return reply.get("shortcut")
