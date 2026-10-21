"""Resolve a dictionary word from Core's actual display nodes, never sentence guesses."""
from dataclasses import dataclass


@dataclass(frozen=True)
class WordDefinitionTarget:
    context: str
    generation: int
    node_id: int
    word: str
    reading: str
    candidate_index: int | None = None


def candidate_path(snapshot, candidate_index):
    nodes = {node["id"]: node for node in snapshot.get("nodes", [])}
    terminals = [node for node in nodes.values() if candidate_index in node.get("terminals", [])]
    if len(terminals) != 1:
        return []
    path = []
    node = terminals[0]
    while node:
        if node["id"] in path:
            return []
        path.append(node["id"])
        parent = node.get("parent")
        if parent is not None and parent not in nodes:
            return []
        node = nodes.get(parent)
    return list(reversed(path))


def word_definition_target(snapshot, *, node_id=None, candidate_index=None):
    nodes = {node["id"]: node for node in snapshot.get("nodes", [])}
    if candidate_index is not None:
        if type(candidate_index) is not int:
            return None
        candidates = snapshot.get("candidates", []) or snapshot.get("candidatePage", {}).get("items", [])
        if not any(item.get("index") == candidate_index for item in candidates):
            return None
        path = candidate_path(snapshot, candidate_index)
        focused = nodes.get(snapshot.get("focusedNode"))
        # Display depth can differ from the converter's original token array.
        depth = focused.get("depth", 0) if focused else 0
        if type(depth) is not int or not 0 <= depth < len(path):
            return None
        node_id = path[depth]
    elif node_id is None:
        node_id = snapshot.get("focusedNode")
        if node_id is None:
            selected = snapshot.get("selectedPath", [])
            node_id = selected[0] if selected else None
    node = nodes.get(node_id)
    if not node or not isinstance(node.get("text"), str) or not isinstance(node.get("reading"), str):
        return None
    # Special candidates may project a whole sentence with no dictionary reading.
    if not node["text"] or not node["reading"]:
        return None
    return WordDefinitionTarget(str(snapshot.get("contextId", "")), snapshot.get("generation", 0),
                                node["id"], node["text"], node["reading"], candidate_index)
