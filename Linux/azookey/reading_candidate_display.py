"""Project an acknowledged reading view and resolve its actions to retained IDs."""
from copy import deepcopy

from .candidate_protocol import reference as batch_reference
from .reading_candidate_view import validate_view


# ShellSurface carries generation as a signed D-Bus int. Exhaustion retires this
# display instead of allowing an old action to become current after wrapping.
MAX_DISPLAY_GENERATION = 2 ** 31 - 1
EMPTY_VIEW = {
    "candidates": [], "nodes": [], "columns": [], "selectedPath": [],
    "candidatePage": {"totalCount": 0, "start": 0, "items": []},
    "showCandidateIndex": False, "showRelativeScores": False,
}


class ReadingCandidateDisplay:
    def __init__(self, context_id):
        self.context_id = context_id
        self.generation = 0
        self.active = False
        self._reference = None
        self._view = None
        self._snapshot = {}

    @property
    def snapshot(self):
        return deepcopy(self._snapshot)

    def update(self, snapshot, candidate_view, *, reference):
        self.active = False
        view = (validate_view(candidate_view, expected_reference=reference, snapshot=snapshot)
                if candidate_view is not None else None)
        if self.generation == MAX_DISPLAY_GENERATION:
            self.retire()
            raise RuntimeError("candidate display generation exhausted")
        self.generation += 1
        self._reference = deepcopy(reference)
        self._view = view
        self.active = bool(view and view["candidates"])
        self._snapshot = {
            **deepcopy(snapshot), **deepcopy(view if view is not None else EMPTY_VIEW),
            "commits": [], "candidateCompletions": [],
            "contextId": self.context_id, "generation": self.generation,
            # This entry supports live=false only. Arrival presents an unselected
            # list while formal composing/Enter behavior remains unchanged.
            "candidateDisplayMode": "menu",
        }
        return self.snapshot

    def suspend(self):
        """Retire actions while keeping the displayed list's visual identity."""
        self.active = False

    def retire(self):
        self.active = False
        self._reference = None
        self._view = None
        self._snapshot = {}

    def selection(self, operation, index, *, generation, reference, retained_reference):
        if (not self.active or type(generation) is not int or generation != self.generation
                or reference != self._reference or type(index) is not int):
            return None
        source = self._view["candidateReference"]
        if retained_reference != source:
            return None
        if operation == "node":
            node = next((node for node in self._view["nodes"] if node["id"] == index), None)
            if node is None or node.get("preview") is None:
                return None
            # Shared word nodes may end a shorter candidate. Only Core's preview
            # identifies the actual candidate behind this action.
            index = node["preview"]["candidateIndex"]
        elif operation != "select":
            return None
        candidates = self._view["candidates"]
        if not 0 <= index < len(candidates):
            return None
        return {"batch": batch_reference(source), "candidateID": candidates[index]["candidateID"]}
