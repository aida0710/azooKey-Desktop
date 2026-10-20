"""Immutable selection identities used before an AI replacement can be applied."""
from dataclasses import dataclass

# Match the existing AI request's surrounding-text limit.
CONTEXT_CHARACTERS = 100


@dataclass(frozen=True)
class InputSelection:
    context_id: tuple
    cursor: int
    anchor: int
    before: str
    selected: str
    after: str

    @classmethod
    def capture(cls, context_id, content, *, cursor, anchor):
        if not context_id or not (0 <= cursor <= len(content) and 0 <= anchor <= len(content)):
            return None
        start, end = sorted((cursor, anchor))
        if start == end:
            return None
        return cls(context_id=context_id, cursor=cursor, anchor=anchor,
                   before=content[:start][-CONTEXT_CHARACTERS:],
                   selected=content[start:end], after=content[end:][:CONTEXT_CHARACTERS])


@dataclass(frozen=True)
class AccessibleSelection:
    bus_id: str
    identity: tuple
    window_identity: tuple
    start: int
    end: int
    before: str
    selected: str
    after: str

    def describes(self, selection):
        # IBus can expose only the current paragraph. Do not invent absolute
        # offsets from that substring; the accessibility range stays separate.
        return (
            self.selected == selection.selected
            and self.before.endswith(selection.before)
            and self.after.startswith(selection.after)
        )


@dataclass(frozen=True)
class TransformationTarget:
    input_selection: InputSelection
    accessible_selection: AccessibleSelection

    def matches(self, input_selection, accessible_selection):
        return self.input_selection == input_selection and self.accessible_selection == accessible_selection


class PendingTransformation:
    def __init__(self, target, replacement):
        self.target = target
        self.replacement = replacement

    def take(self, input_selection, accessible_selection):
        replacement, self.replacement = self.replacement, None
        if self.target.matches(input_selection, accessible_selection):
            return replacement
        return None
