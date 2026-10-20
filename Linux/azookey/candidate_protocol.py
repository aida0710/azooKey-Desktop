"""Validate candidate identities without rebuilding formal input or candidates."""
from copy import deepcopy
from dataclasses import dataclass


AUTHORITY_FIELDS = frozenset(("context", "readingProcessGeneration", "focusEpoch",
                              "compositionRevision", "settingsRevision", "requestID"))
OWNER_FIELDS = ("context", "readingProcessGeneration", "focusEpoch")
INPUT_COMMAND_FIELDS = frozenset(("preedit", "commits", "cursor", "consumed", "inputState"))
LEARNING_MODES = frozenset(("inputAndOutput", "onlyOutput", "nothing"))
# The Swift development transport uses the same opaque identifier limit.
IDENTIFIER_BYTES = 512
# Match DesktopCandidateLimits without evicting receipts that suppress learning.
MAX_CONTEXTS = 64
MAX_COMPLETIONS_PER_CONTEXT = 1024


@dataclass(frozen=True)
class CandidateReply:
    worker_generation: str | None = None
    transport_epoch: int = 0
    batch: dict | None = None
    completion: dict | None = None
    settings: dict | None = None
    error: str | None = None
    uncertain: bool = False


def identifier(value):
    if not isinstance(value, str) or not value or len(value) > IDENTIFIER_BYTES:
        raise ValueError("invalid candidate identifier")
    if any(not 0x21 <= ord(character) <= 0x7e for character in value):
        raise ValueError("invalid candidate identifier")
    return value


def revision(value):
    if type(value) is not int or value < 0:
        raise ValueError("invalid candidate revision")
    return value


def authority(value):
    if not isinstance(value, dict) or set(value) != AUTHORITY_FIELDS:
        raise ValueError("invalid candidate authority")
    for field in ("context", "readingProcessGeneration", "requestID"):
        identifier(value[field])
    for field in ("focusEpoch", "compositionRevision", "settingsRevision"):
        revision(value[field])
    return deepcopy(value)


def same_owner(first, second):
    return all(first[field] == second[field] for field in OWNER_FIELDS)


def reference(batch):
    if not isinstance(batch, dict):
        raise ValueError("invalid candidate reference")
    return {"authority": authority(batch.get("authority")),
            "workerGeneration": identifier(batch.get("workerGeneration")),
            "batchID": identifier(batch.get("batchID"))}


def reference_key(batch):
    return batch["workerGeneration"], batch["batchID"]


def completion_request(value):
    copied = reference(value)
    copied.update(candidateID=identifier(value.get("candidateID")),
                  commitID=identifier(value.get("commitID")),
                  settingsRevision=revision(value.get("settingsRevision")))
    if type(value.get("privateInput")) is not bool:
        raise ValueError("invalid candidate privacy")
    copied["privateInput"] = value["privateInput"]
    return copied


def response_header(response):
    if not isinstance(response, dict) or INPUT_COMMAND_FIELDS.intersection(response):
        raise ValueError("candidate response cannot contain input commands")
    identifier(response.get("workerGeneration"))
    revision(response.get("settingsRevision"))
    if "error" in response and not isinstance(response["error"], str):
        raise ValueError("invalid candidate error")


def candidate_batch(response, request):
    batch = response.get("batch")
    source = reference(batch)
    if (source["authority"] != request["authority"] or response.get("authority") != request["authority"]
            or source["workerGeneration"] != response["workerGeneration"]):
        raise ValueError("candidate response changed its authority")
    if INPUT_COMMAND_FIELDS.intersection(batch) or not isinstance(batch.get("candidates"), list):
        raise ValueError("invalid candidate batch")
    seen = set()
    for item in batch["candidates"]:
        if not isinstance(item, dict) or INPUT_COMMAND_FIELDS.intersection(item):
            raise ValueError("invalid candidate item")
        candidate_id = identifier(item.get("candidateID"))
        if candidate_id in seen or not isinstance(item.get("text"), str):
            raise ValueError("invalid candidate identity")
        if not isinstance(item.get("composingCount"), dict) or not isinstance(item.get("presentation"), dict):
            raise ValueError("invalid candidate presentation")
        seen.add(candidate_id)
    return deepcopy(batch)


def completion_receipt(response, request):
    receipt = response.get("completion")
    fields = ("authority", "workerGeneration", "batchID", "candidateID", "commitID")
    if not isinstance(receipt, dict) or any(receipt.get(field) != request[field] for field in fields):
        raise ValueError("candidate receipt changed its commit identity")
    if (response.get("authority") != request["authority"]
            or receipt.get("status") not in ("completed", "alreadyCompleted")
            or type(receipt.get("learningRequested")) is not bool
            or INPUT_COMMAND_FIELDS.intersection(receipt)):
        raise ValueError("invalid candidate receipt")
    return deepcopy(receipt)


def settings_response(response):
    learning = response.get("learning")
    tables = response.get("customInputTableRevisions")
    if not isinstance(learning, str) or learning not in LEARNING_MODES or not isinstance(tables, dict):
        raise ValueError("invalid candidate settings")
    if any(not isinstance(name, str) or not isinstance(value, str) for name, value in tables.items()):
        raise ValueError("invalid candidate table revision")
    return deepcopy({field: response[field] for field in
                     ("workerGeneration", "settingsRevision", "learning", "customInputTableRevisions")})
