"""Ownership of native key replies while reconversion waits for the client."""
from collections import deque
from dataclasses import dataclass, field
from typing import Callable


@dataclass
class ReconversionKey:
    key: tuple[int, int, int]
    reply: Callable[[bool], None] | None = None
    completed: bool = False

    def finish(self, consumed, *, forward):
        if self.completed:
            return
        self.completed = True
        if self.reply:
            self.reply(consumed)
        elif not consumed:
            forward(*self.key)


@dataclass
class ReconversionRecovery:
    epoch: int
    keys: deque[ReconversionKey] = field(default_factory=deque)
    target: dict | None = None
    start_reply: Callable[[bool], None] | None = None
