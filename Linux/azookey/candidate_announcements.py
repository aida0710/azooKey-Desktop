"""Concise selection announcements that keep AT focus in the document."""
from .i18n import text as message


def candidate_announcement(snapshot):
    if snapshot.get("inputState") not in ("previewing", "selecting", "replaceSuggestion"):
        return None
    candidate = next((item for item in snapshot.get("candidates", [])
                      if item["index"] == snapshot.get("selection")), None)
    node = next((item for item in snapshot.get("nodes", [])
                 if item["id"] == snapshot.get("focusedNode")), None)
    if candidate is None or node is None:
        return None
    scope = candidate.get("commitScope") or {}
    reading = node.get("reading") or scope.get("consumedReading") or snapshot.get("reading")
    parts = [message("candidate.position", position=candidate["index"] + 1,
                     total=len(snapshot["candidates"])), node["text"]]
    if reading:
        parts.append(message("candidate.announceReading", reading=reading))
    path = snapshot.get("selectedPath", [])
    if node["id"] in path and len(path) > 1:
        parts.append(message("candidate.wordPosition", position=path.index(node["id"]) + 1, total=len(path)))
    if candidate["text"] != node["text"]:
        parts.append(message("candidate.announceCommit", text=candidate["text"]))
    if scope.get("remainingReading"):
        parts.append(message("candidate.announceRemaining", reading=scope["remainingReading"]))
    return "。".join(parts)


class CandidateAnnouncements:
    def __init__(self, announce):
        self.announce = announce
        self.identity = None

    def update(self, snapshot):
        announcement = candidate_announcement(snapshot)
        if announcement is None:
            self.reset()
            return
        identity = (snapshot.get("contextId"), announcement)
        if identity == self.identity:
            return
        self.identity = identity
        self.announce(announcement)

    def reset(self):
        self.identity = None
