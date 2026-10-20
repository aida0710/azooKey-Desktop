"""Validate reading replies and describe input ownership without toolkit types."""
from copy import deepcopy
from dataclasses import dataclass, field

from . import candidate_protocol as candidates


REFERENCE_FIELDS = frozenset(("context", "readingProcessGeneration", "focusEpoch"))
RESPONSE_FIELDS = frozenset(("kind", "readingProcessGeneration", "settingsRevision", "reference",
                             "nextReference", "snapshot", "candidateRequest", "candidateReference", "limits", "error"))
INPUT_OPERATIONS = frozenset(("key", "select", "reset", "focus-out"))
RESPONSE_KINDS = {"hello": "process", "prepare-candidates": "candidates",
                  **{operation: "input" for operation in INPUT_OPERATIONS}}


@dataclass(frozen=True)
class ReadingReply:
    response: dict | None = field(default=None, repr=False)
    generation: str | None = None
    transport_epoch: int = 0
    error: str | None = None
    uncertain: bool = False


@dataclass(frozen=True)
class ReadingInput:
    context: str
    token: object = field(repr=False)
    reference: dict
    snapshot: dict = field(repr=False)


@dataclass(frozen=True)
class ReadingCandidates:
    context: str
    reference: dict
    batch: dict = field(repr=False)


@dataclass(frozen=True)
class ReadingNotice:
    code: str
    context: str | None = None
    operation: str | None = None
    phase: str | None = None
    token: object = field(default=None, repr=False)
    reference: dict | None = None
    displayed_snapshot: dict | None = field(default=None, repr=False)
    payload: dict | None = field(default=None, repr=False)
    completion: dict | None = field(default=None, repr=False)


def reference(value):
    if not isinstance(value, dict) or set(value) != REFERENCE_FIELDS:
        raise ValueError("invalid reading reference")
    candidates.identifier(value["context"])
    candidates.identifier(value["readingProcessGeneration"])
    candidates.revision(value["focusEpoch"])
    return deepcopy(value)


def snapshot(value, expected_reference):
    if not isinstance(value, dict):
        raise ValueError("invalid reading snapshot")
    for name in ("preedit", "reading", "inputState"):
        if not isinstance(value.get(name), str):
            raise ValueError("invalid reading text")
        value[name].encode("utf-8")
    for name in ("cursor", "readingCursor", "compositionRevision", "generation"):
        candidates.revision(value.get(name))
    if value["cursor"] > len(value["preedit"]) or value["readingCursor"] > len(value["reading"]):
        raise ValueError("invalid reading cursor")
    if type(value.get("consumed")) is not bool:
        raise ValueError("invalid reading consumption")
    if not isinstance(value.get("commits"), list) or any(not isinstance(text, str) for text in value["commits"]):
        raise ValueError("invalid reading commits")
    for text in value["commits"]:
        text.encode("utf-8")
    completions = value.get("candidateCompletions", [])
    if not isinstance(completions, list):
        raise ValueError("invalid reading completions")
    for completion in completions:
        source = candidates.completion_request(completion)["authority"]
        if any(source[name] != expected_reference[name] for name in REFERENCE_FIELDS):
            raise ValueError("reading completion changed its input owner")
    return deepcopy(value)


def response(value, operation, payload):
    if not isinstance(value, dict) or set(value) - RESPONSE_FIELDS:
        raise ValueError("invalid reading response")
    generation = candidates.identifier(value.get("readingProcessGeneration"))
    candidates.revision(value.get("settingsRevision"))
    kind = value.get("kind")
    if kind == "error":
        if set(value) != {"kind", "readingProcessGeneration", "settingsRevision", "error"}:
            raise ValueError("reading error contains input effects")
        candidates.identifier(value.get("error"))
        return deepcopy(value)
    if kind != RESPONSE_KINDS.get(operation, "acknowledgement"):
        raise ValueError("reading response changed its operation kind")
    permitted = {"kind", "readingProcessGeneration", "settingsRevision"}
    if operation == "hello":
        permitted.add("limits")
    elif operation == "learning-revision":
        if value["settingsRevision"] != payload["settingsRevision"]:
            raise ValueError("reading settings acknowledgement changed revision")
    else:
        permitted.add("reference")
        current = reference(value.get("reference"))
        if current["readingProcessGeneration"] != generation:
            raise ValueError("reading reference changed process")
        if operation == "open":
            if current["context"] != payload["context"]:
                raise ValueError("reading open changed context")
        elif operation == "focus-in":
            previous = payload["reference"]
            if (any(current[name] != previous[name] for name in ("context", "readingProcessGeneration"))
                    or current["focusEpoch"] <= previous["focusEpoch"]):
                raise ValueError("reading focus did not advance")
        elif current != payload["reference"]:
            raise ValueError("reading response changed its input owner")
        if kind == "input":
            permitted.add("snapshot")
            snapshot(value.get("snapshot"), current)
        if operation == "focus-out":
            permitted.add("nextReference")
            following = reference(value.get("nextReference"))
            if (any(following[name] != current[name] for name in ("context", "readingProcessGeneration"))
                    or following["focusEpoch"] <= current["focusEpoch"]):
                raise ValueError("reading focus retirement did not advance")
        if operation == "prepare-candidates":
            permitted.add("candidateRequest")
            request = value.get("candidateRequest")
            if not isinstance(request, dict):
                raise ValueError("invalid reading candidate request")
            authority = candidates.authority(request.get("authority"))
            if (any(authority[name] != current[name] for name in REFERENCE_FIELDS)
                    or authority["settingsRevision"] != value["settingsRevision"]):
                raise ValueError("reading candidate request changed owner")
        if operation == "adopt-candidates":
            permitted.add("candidateReference")
            if candidates.reference(value.get("candidateReference")) != payload["retainedReference"]:
                raise ValueError("reading adopted another candidate reference")
    if set(value) != permitted:
        raise ValueError("reading response contains unrelated effects")
    return deepcopy(value)


def displayed_snapshot(value):
    return {**deepcopy(value), "commits": [], "candidateCompletions": []}
