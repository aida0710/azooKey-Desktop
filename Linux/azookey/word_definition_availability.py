"""Check the current candidate page in the background, independently of selection."""
from .word_definition_target import word_definition_target

# Physical number-key pages have at most nine candidates.
MAXIMUM_PAGE_CANDIDATES = 9


def page_definition_targets(snapshot):
    return tuple((item["index"], word_definition_target(snapshot, candidate_index=item["index"]))
                 for item in snapshot.get("candidatePage", {}).get("items", [])[:MAXIMUM_PAGE_CANDIDATES])


def has_definition(response):
    return bool(response and response.get("status") == "found" and any(
        text.strip() for sense in response.get("senses", [])
        for text in sense.get("definitions", []) if isinstance(text, str)))


class WordDefinitionAvailability:
    def __init__(self, worker, changed, *, completed=lambda: None):
        self.worker = worker
        self.changed = changed
        self.completed = completed
        self.targets = None
        self.found_indices = frozenset()
        self.epoch = object()

    def update(self, snapshot):
        targets = page_definition_targets(snapshot)
        if targets == self.targets:
            return
        self.invalidate()
        self.targets = targets
        self.changed(self.found_indices)
        self.query_next(self.epoch, 0)

    def query_next(self, epoch, offset):
        if epoch is not self.epoch:
            return
        if offset == len(self.targets):
            self.completed()
            return
        index, target = self.targets[offset]
        if target is None:
            self.query_next(epoch, offset + 1)
            return

        def received(response):
            if epoch is not self.epoch:
                return
            if has_definition(response):
                self.found_indices = self.found_indices | {index}
                self.changed(self.found_indices)
            self.query_next(epoch, offset + 1)

        self.worker.request(target, received)

    def invalidate(self):
        self.epoch = object()
        self.targets = None
        self.found_indices = frozenset()
