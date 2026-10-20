"""Record only the protected-input fixture's own synthetic text and attributes."""
import argparse
import json
from pathlib import Path
import time

from fixture_events import FixtureEvents


FIELD_LABELS = {
    "normal": "Normal input",
    "password": "Password input",
    "pin": "Numeric password input",
    "private": "Private input",
    "read-only": "Read-only input",
}
READ_ONLY_TEXT = "READ_ONLY_BEFORE TARGET_TEXT READ_ONLY_AFTER"
# Five labelled rows fit inside the 1280×800 guest without moving other fixtures.
WINDOW_WIDTH = 900
WINDOW_HEIGHT = 600


class ProtectedFixtureRecorder:
    def __init__(self, *, output, events):
        self.output = Path(output)
        self.output.parent.mkdir(parents=True, exist_ok=True)
        self.events = FixtureEvents(events)

    @classmethod
    def from_arguments(cls):
        parser = argparse.ArgumentParser(
            description="Use synthetic text only; records this fixture's fields."
        )
        parser.add_argument("--output", type=Path, required=True)
        parser.add_argument("--events", type=Path)
        arguments = parser.parse_args()
        return cls(output=arguments.output, events=arguments.events)

    def record(self, *, fields, window_active, toolkit):
        state = {
            "observedAt": time.time(),
            "monotonicNS": time.monotonic_ns(),
            "windowActive": window_active,
            "toolkit": toolkit,
            "fields": fields,
        }
        pending = self.output.with_suffix(self.output.suffix + ".pending")
        pending.write_text(json.dumps(state, ensure_ascii=False), encoding="utf-8")
        pending.chmod(0o600)
        pending.replace(self.output)
        self.events.append("state", state=state)
        return state
