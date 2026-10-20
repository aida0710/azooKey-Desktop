"""Validate Core's display projection without rebuilding candidates or formal input."""
from copy import deepcopy

from . import candidate_protocol


VIEW_FIELDS = frozenset((
    "candidateReference", "candidates", "selection", "nodes", "columns", "selectedPath",
    "focusedNode", "candidatePage", "showCandidateIndex", "showRelativeScores",
))
REQUIRED_FIELDS = VIEW_FIELDS - {"selection", "focusedNode"}
REFERENCE_FIELDS = ("context", "readingProcessGeneration", "focusEpoch")


def _index(value, count):
    if type(value) is not int or not 0 <= value < count:
        raise ValueError("invalid candidate view index")
    return value


def _indices(value, count):
    if not isinstance(value, list):
        raise ValueError("invalid candidate view indices")
    for index in value:
        _index(index, count)
    if len(set(value)) != len(value):
        raise ValueError("duplicate candidate view index")


def _items(value, batch):
    if not isinstance(value, list):
        raise ValueError("invalid candidate view items")
    seen = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict) or candidate_protocol.INPUT_COMMAND_FIELDS.intersection(item):
            raise ValueError("candidate view item contains input effects")
        candidate_id = candidate_protocol.identifier(item.get("candidateID"))
        if (type(item.get("index")) is not int or item["index"] != index or candidate_id in seen
                or not isinstance(item.get("text"), str) or not item["text"]):
            raise ValueError("invalid candidate view identity")
        item["text"].encode("utf-8")
        seen.add(candidate_id)
    if batch is not None:
        expected = [(item["candidateID"], item["text"]) for item in batch["candidates"]]
        if [(item["candidateID"], item["text"]) for item in value] != expected:
            raise ValueError("candidate view changed retained candidates")


def _nodes(value, items):
    if not isinstance(value, list) or any(not isinstance(node, dict) for node in value):
        raise ValueError("invalid candidate view nodes")
    for index, node in enumerate(value):
        if (not isinstance(node, dict) or type(node.get("id")) is not int or node["id"] != index
                or candidate_protocol.INPUT_COMMAND_FIELDS.intersection(node)
                or not isinstance(node.get("text"), str) or not isinstance(node.get("reading"), str)):
            raise ValueError("invalid candidate view node")
        candidate_protocol.revision(node.get("depth"))
        _indices(node.get("children"), len(value))
        _indices(node.get("terminals"), len(items))
        parent = node.get("parent")
        if parent is not None:
            # Core creates a parent before its children; this also rejects cycles.
            _index(parent, index)
            if index not in value[parent].get("children", []):
                raise ValueError("candidate view changed node parent")
        for child in node["children"]:
            if child <= index or value[child].get("parent") != index:
                raise ValueError("candidate view changed node children")
        if "preview" in node:
            preview = node["preview"]
            if not isinstance(preview, dict) or candidate_protocol.INPUT_COMMAND_FIELDS.intersection(preview):
                raise ValueError("invalid candidate view preview")
            item = items[_index(preview.get("candidateIndex"), len(items))]
            if (preview.get("text") != item["text"] or preview.get("scope") != item.get("commitScope")
                    or preview.get("annotation") != item.get("annotation")):
                raise ValueError("candidate view preview changed its candidate")


def validate_view(value, *, expected_reference, batch=None, snapshot=None):
    if (not isinstance(value, dict) or set(value) - VIEW_FIELDS or not REQUIRED_FIELDS.issubset(value)):
        raise ValueError("invalid candidate view fields")
    source = candidate_protocol.reference(value["candidateReference"])
    if any(source["authority"][name] != expected_reference[name] for name in REFERENCE_FIELDS):
        raise ValueError("candidate view changed input owner")
    if batch is not None and source != candidate_protocol.reference(batch):
        raise ValueError("candidate view changed retained batch")
    items, nodes = value["candidates"], value["nodes"]
    _items(items, batch)
    _nodes(nodes, items)
    for field in ("showCandidateIndex", "showRelativeScores"):
        if type(value[field]) is not bool:
            raise ValueError("invalid candidate view preference")
    selected = value.get("selection")
    if selected is not None:
        _index(selected, len(items))
    focused = value.get("focusedNode")
    if focused is not None:
        _index(focused, len(nodes))
    if not isinstance(value["columns"], list):
        raise ValueError("invalid candidate view columns")
    for column in value["columns"]:
        _indices(column, len(nodes))
        if not column:
            raise ValueError("empty candidate view column")
    _indices(value["selectedPath"], len(nodes))
    if value["selectedPath"] != [column[0] for column in value["columns"]]:
        raise ValueError("candidate view path differs from its columns")
    page = value["candidatePage"]
    if (not isinstance(page, dict) or type(page.get("totalCount")) is not int
            or page["totalCount"] != len(items) or not isinstance(page.get("items"), list)):
        raise ValueError("invalid candidate view page")
    candidate_protocol.revision(page.get("start"))
    if page.get("position") != (selected + 1 if selected is not None else None):
        raise ValueError("candidate view page changed selection")
    for item in page["items"]:
        if not isinstance(item, dict):
            raise ValueError("invalid candidate view page item")
        original = items[_index(item.get("index"), len(items))]
        if item.get("text") != original["text"]:
            raise ValueError("candidate view page changed candidate text")
    for field in ("previousIndex", "nextIndex"):
        if field in page:
            _index(page[field], len(items))
    if snapshot is not None:
        if (source["authority"]["compositionRevision"] != snapshot["compositionRevision"]
                or selected != snapshot.get("selection")
                or value["showCandidateIndex"] != bool(snapshot.get("showCandidateIndex"))):
            raise ValueError("candidate view differs from formal input")
    return deepcopy(value)
