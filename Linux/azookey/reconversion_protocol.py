"""Validate document replacement and dictionary-reading messages."""
from copy import deepcopy

from . import candidate_protocol
from .reconversion import CONTEXT_LIMIT


CONTROL_OPERATIONS = frozenset((
    "undo-commit", "reconvert", "resolve-reconversion", "reconversion-reading", "cancel-reconversion",
))
RESPONSE_FIELDS = frozenset((
    "reconversion", "reconversionError", "reconversionReading", "reconversionReadingRequest",
))
CONTEXT_FIELDS = frozenset((
    "before", "selected", "after", "cursorUTF16", "anchorUTF16", "canReplace", "isSensitive",
))


def document_context(value):
    if not isinstance(value, dict) or set(value) != CONTEXT_FIELDS:
        raise ValueError("invalid reconversion context")
    for name in ("before", "selected", "after"):
        _text(value[name])
        if len(value[name]) > CONTEXT_LIMIT:
            raise ValueError("reconversion context exceeds its limit")
    for name in ("cursorUTF16", "anchorUTF16"):
        candidate_protocol.revision(value[name])
    if any(type(value[name]) is not bool for name in ("canReplace", "isSensitive")):
        raise ValueError("invalid reconversion context permissions")
    return deepcopy(value)


def reading_request(value):
    if not isinstance(value, dict) or set(value) != {"authority", "workerGeneration", "text", "privateInput"}:
        raise ValueError("invalid reconversion reading request")
    candidate_protocol.authority(value["authority"])
    candidate_protocol.identifier(value["workerGeneration"])
    _text(value["text"])
    if not value["text"] or len(value["text"]) > CONTEXT_LIMIT or value["privateInput"] is not False:
        raise ValueError("reconversion reading request has no public selection")
    return deepcopy(value)


def reading_result(value, *, request):
    if not isinstance(value, dict) or set(value) not in ({"request"}, {"request", "reading"}):
        raise ValueError("invalid reconversion reading result")
    if reading_request(value["request"]) != reading_request(request):
        raise ValueError("reconversion reading changed its request")
    if "reading" in value:
        _text(value["reading"])
        if len(value["reading"]) > CONTEXT_LIMIT:
            raise ValueError("reconversion reading exceeds its limit")
    return deepcopy(value)


def candidate_reading(response, *, request):
    fields = {"workerGeneration", "settingsRevision", "learning", "customInputTableRevisions",
              "authority", "reconversionReadingResult"}
    if set(response) != fields:
        raise ValueError("reconversion reading contains unrelated candidate effects")
    candidate_protocol.settings_response(response)
    if (response["workerGeneration"] != request["workerGeneration"]
            or response["settingsRevision"] != request["authority"]["settingsRevision"]
            or response["authority"] != request["authority"]):
        raise ValueError("reconversion reading changed its owner")
    return reading_result(response["reconversionReadingResult"], request=request)


def response_fields(value, *, reference, settings_revision):
    fields = RESPONSE_FIELDS.intersection(value)
    if "reconversionError" in fields:
        candidate_protocol.identifier(value["reconversionError"])
    if "reconversionReading" in fields:
        _text(value["reconversionReading"])
        if len(value["reconversionReading"]) > CONTEXT_LIMIT:
            raise ValueError("local reconversion reading exceeds its limit")
    if "reconversion" in fields:
        replacement = value["reconversion"]
        if not isinstance(replacement, dict) or set(replacement) != {"token", "offset", "count", "text", "reading"}:
            raise ValueError("invalid reconversion replacement")
        candidate_protocol.identifier(replacement["token"])
        for name in ("text", "reading"):
            _text(replacement[name])
        if (type(replacement["offset"]) is not int or type(replacement["count"]) is not int
                or not replacement["text"] or replacement["count"] != len(replacement["text"])):
            raise ValueError("invalid reconversion deletion")
    if "reconversionReadingRequest" in fields:
        request = reading_request(value["reconversionReadingRequest"])
        if (any(request["authority"][name] != expected for name, expected in reference.items())
                or request["authority"]["settingsRevision"] != settings_revision):
            raise ValueError("reconversion request changed its reading owner")
    outcomes = fields - {"reconversionError"}
    if len(outcomes) > 1:
        raise ValueError("reconversion response contains competing outcomes")
    return fields


def _text(value):
    if not isinstance(value, str):
        raise ValueError("invalid reconversion text")
    value.encode("utf-8")
