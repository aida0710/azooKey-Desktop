"""The reviewed destination and document text for a single AI request."""
from dataclasses import dataclass, replace
from urllib.parse import urlsplit

from .i18n import text as message

# Modifier bits and key codes are the shared desktop bridge key protocol.
ESCAPE_KEY = 53
SHIFT_MODIFIER = 1
CONTROL_MODIFIER = 2
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


def endpoint_host(endpoint):
    """Display no URL userinfo, path, query or fragment, even for invalid URLs."""
    try:
        url = urlsplit(endpoint)
        if url.scheme not in ("http", "https") or not url.hostname:
            return None
        host = f"[{url.hostname}]" if ":" in url.hostname else url.hostname
        return f"{host}:{url.port}" if url.port is not None else host
    except ValueError:
        return None


@dataclass(frozen=True)
class AIRequestConfiguration:
    model: str
    endpoint: str

    @property
    def destination(self):
        return endpoint_host(self.endpoint) or message("ai.destination.invalid")

    @classmethod
    def from_settings(cls, settings):
        return cls(model=settings["aiModel"], endpoint=settings["aiEndpoint"])


@dataclass(frozen=True)
class AIRequestScope:
    configuration: AIRequestConfiguration
    target: str
    before: str = ""
    after: str = ""
    include_context: bool = False

    def with_context(self, included):
        return replace(self, include_context=bool(included))

    def bridge_arguments(self):
        # Only permitted text crosses the process boundary. Core also enforces
        # this flag and the 100-character limit before forming the HTTP body.
        return {
            "target": self.target,
            "leftContext": self.before if self.include_context else "",
            "rightContext": self.after if self.include_context else "",
            "includeContext": self.include_context,
            "aiModel": self.configuration.model,
            "aiEndpoint": self.configuration.endpoint,
        }


@dataclass
class AISuggestionConfirmation:
    scope: AIRequestScope
    generation: int
    reading: str
    input_epoch: object
    bridge_generation: int

    def matches(self, snapshot, input_epoch, bridge_generation):
        return (snapshot.get("generation") == self.generation
                and snapshot.get("reading", "") == self.reading
                and input_epoch is self.input_epoch
                and bridge_generation == self.bridge_generation)

    @staticmethod
    def keyboard_action(event):
        modifiers = event.get("modifierFlags", 0)
        characters = (event.get("charactersIgnoringModifiers") or "").lower()
        if event.get("keyCode") == ESCAPE_KEY and modifiers == 0:
            return "cancel"
        if characters == "s" and modifiers == CONTROL_MODIFIER:
            return "send"
        if characters == "s" and modifiers == (CONTROL_MODIFIER | SHIFT_MODIFIER):
            return "toggle"
        return None
