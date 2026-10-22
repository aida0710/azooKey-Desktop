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
        self.pending_signature = None

    def request(self):
        if self.path is None:
            # Core names the file in its first answer.
            if not any(pending.operation == "settings-reload" for pending in self.input.pending):
                self._submit(None)
            return
        signature = file_signature(self.path)
        if signature in (self.signature, self.pending_signature):
            return
        self._submit(signature)

    def forget_pending(self):
        """The input queue was cancelled, so its reload will never answer."""
        self.pending_signature = None

    def _submit(self, signature):
        self.pending_signature = signature
        self.input.submit("settings-reload", completion=lambda snapshot: self._answered(signature, snapshot))

    def _answered(self, signature, snapshot):
        if self.pending_signature == signature:
            self.pending_signature = None
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
