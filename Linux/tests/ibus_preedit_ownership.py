"""Verify real IBus Reset/focus commits separately from toolkit widget tests."""
import json
import os
from pathlib import Path
import time

import gi
gi.require_version("IBus", "1.0")
from gi.repository import Gio, GLib, IBus


WAIT_SECONDS = 5  # A missing local daemon/reader acknowledgement is an error.
POLL_SECONDS = .005  # Yield between observations of the real bus.


def drain_until(predicate):
    deadline = time.monotonic() + WAIT_SECONDS
    while not predicate():
        while GLib.MainContext.default().pending():
            GLib.MainContext.default().iteration(False)
        assert time.monotonic() < deadline, "preedit ownership response did not arrive"
        time.sleep(POLL_SECONDS)


class Client:
    def __init__(self, name):
        self.context = bus.create_input_context(name)
        self.context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS)
        self.commits, self.preedits = [], []
        self.context.connect("commit-text", lambda _context, value: self.commits.append(value.get_text()))
        self.context.connect("update-preedit-text", lambda _context, value, _cursor, _visible:
                             self.preedits.append(value.get_text()))
        self.context.focus_in()
        self.context.call_sync("SetEngine", GLib.Variant("(s)", ("azookey-tree",)),
                               Gio.DBusCallFlags.NONE, int(WAIT_SECONDS * 1000), None)

    def key(self, keyval):
        assert self.context.process_key_event(keyval, 0, 0)

    def reading(self, raw, expected):
        self.key(IBus.KEY_Henkan)
        for character in raw:
            self.key(ord(character))
        drain_until(lambda: self.preedits and self.preedits[-1] == expected)


IBus.init()
bus = IBus.Bus()
assert bus.is_connected()
qt = Client("QIBusInputContext")
qt.reading("nihongo", "にほんご")
# The real Qt plugin already delivered this visible preedit to its old widget.
# This client tests only the daemon contract, without claiming native delivery.
locally_committed = qt.preedits[-1]
qt.context.reset()
qt.context.focus_in()  # Qt reuses the same context for its next widget.
qt.reading("ka", "か")
assert qt.commits == [], f"IBus duplicated the client's local commit: {qt.commits}"
qt.key(IBus.KEY_Return)
drain_until(lambda: qt.preedits[-1] == "" and qt.commits == ["か"])
qt.reading("ni", "に")
qt.key(IBus.KEY_Escape)
drain_until(lambda: qt.preedits[-1] == "")
assert qt.commits == ["か"]
qt.context.focus_out()

unknown = Client("preedit-ownership-unknown")
unknown.reading("nihongo", "にほんご")
unknown.context.focus_out()
drain_until(lambda: unknown.commits == ["にほんご"])
assert qt.commits == ["か"]

observations = {
    "adapter": os.environ["AZOOKEY_TEST_PREEDIT_ADAPTER"],
    "qtLocalCommitModel": locally_committed, "qtDaemonCommits": qt.commits,
    "qtPreedits": qt.preedits, "unknownFocusCommits": unknown.commits,
    "nativeQtWidgetTest": False,
}
destination = os.environ.get("AZOOKEY_PREEDIT_EVIDENCE")
if destination:
    Path(destination).write_text(json.dumps(observations, ensure_ascii=False, indent=2) + "\n")
print(json.dumps(observations, ensure_ascii=False))
