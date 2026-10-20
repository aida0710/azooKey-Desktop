"""Append native editor observations without changing the delivered input."""
import json
import pathlib
import time


class FixtureEvents:
    def __init__(self, path):
        self.path = pathlib.Path(path) if path else None
        self.sequence = 0
        if self.path:
            # Never concatenate separate trials into apparently continuous evidence.
            with self.path.open("x", encoding="utf-8"):
                self.path.chmod(0o600)

    def append(self, event, **details):
        if self.path is None:
            return
        self.sequence += 1
        observation = {
            "event": event, "sequence": self.sequence,
            "observedAt": time.time(), "monotonicNS": time.monotonic_ns(), **details,
        }
        with self.path.open("a", encoding="utf-8") as stream:
            stream.write(json.dumps(observation, ensure_ascii=False) + "\n")
