"""Let Core apply a changed settings file before an engine's next input."""
import os


def file_signature(path):
    """Notice a replaced, edited or removed settings file without reading it.

    Core decides what a change means; this check only spares a Core request
    for every key while the file stays the same.
    """
    try:
        status = os.stat(path)
        return ("file", status.st_dev, status.st_ino, status.st_mtime_ns, status.st_size, status.st_mode)
    except FileNotFoundError:
        pass
    except OSError as error:
        return ("unreadable", error.errno)
    try:
        # A link to a missing file is a damaged settings file, not an absent one.
        return ("link", os.lstat(path).st_mtime_ns)
    except OSError:
        return ("absent",)


class SettingsReload:
    """Keep one engine's settings equal to what Core runs with.

    applied(values) receives the settings after every answer. problem(problem)
    receives None, or Core's problem with the file version's "stamp", once the
    answer describes the file as it still is.
    """

    def __init__(self, input_queue, *, applied, problem):
        self.input = input_queue
        self.applied = applied
        self.problem = problem
        self.path = None
        self.signature = None

    def request(self):
        # One reload at a time; a change made meanwhile is seen by the next request.
        # Cancelling the input queue drops the reload with the rest of its requests.
        if any(pending.operation == "settings-reload" for pending in self.input.pending):
            return
        # Core names the file in its first answer.
        signature = None if self.path is None else file_signature(self.path)
        if signature is not None and signature == self.signature:
            return
        self.input.submit("settings-reload", completion=lambda snapshot: self._answered(signature, snapshot))

    def _answered(self, signature, snapshot):
        state = (snapshot.get("settingsResult") or {}).get("file")
        if snapshot.get("error") or state is None or "settings" not in snapshot:
            # The next key asks again; the engine keeps its last settings meanwhile.
            return
        self.applied(snapshot["settings"])
        if self.path is None:
            self.path = state["path"]
            self.request()
            return
        problem = state.get("problem")
        if problem is not None and file_signature(self.path) != signature:
            # The user changed the file after Core read it; only that version counts.
            self.request()
            return
        self.signature = signature
        self.problem(None if problem is None else {**problem, "stamp": state["stamp"]})
