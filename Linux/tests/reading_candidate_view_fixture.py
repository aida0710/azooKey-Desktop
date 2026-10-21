"""Flat, explicit display rows for transport tests; real trees are tested in Core."""
from copy import deepcopy


PAGE_SIZE = 9  # Match the shared Core page used for number-key selection.


def candidate_view(batch, *, selection=None, show_indices=False):
    items = []
    nodes = []
    for index, candidate in enumerate(batch["candidates"]):
        presentation = candidate.get("presentation", {})
        item = {"index": index, "candidateID": candidate["candidateID"], "text": candidate["text"],
                "tokens": deepcopy(presentation.get("tokens", []))}
        for field in ("annotation", "score", "comparisonGroup", "commitScope"):
            if field in presentation:
                item[field] = deepcopy(presentation[field])
        items.append(item)
        preview = {"candidateIndex": index, "text": item["text"], "followingText": ""}
        for source, target in (("annotation", "annotation"), ("commitScope", "scope")):
            if source in item:
                preview[target] = deepcopy(item[source])
        nodes.append({"id": index, "text": item["text"], "reading": "", "children": [],
                      "terminals": [index], "depth": 0, "preview": preview})
    start = (selection or 0) // PAGE_SIZE * PAGE_SIZE
    page = {"totalCount": len(items), "start": start, "items": [
        {"index": item["index"], "text": item["text"], "reading": "", "detailDescription": "fixture"}
        for item in items[start:start + PAGE_SIZE]
    ]}
    selected_path = [selection if selection is not None else 0] if items else []
    view = {
        "candidateReference": {key: deepcopy(batch[key]) for key in ("authority", "workerGeneration", "batchID")},
        "candidates": items, "nodes": nodes, "columns": [selected_path] if selected_path else [],
        "selectedPath": selected_path, "candidatePage": page,
        "showCandidateIndex": show_indices, "showRelativeScores": False,
    }
    if selection is not None:
        view.update(selection=selection, focusedNode=selection)
        page["position"] = selection + 1
    if start:
        page["previousIndex"] = max(0, start - PAGE_SIZE)
    if start + PAGE_SIZE < len(items):
        page["nextIndex"] = start + PAGE_SIZE
    return view
