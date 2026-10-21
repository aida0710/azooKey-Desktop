"""Choose which IBus participant owns preedit submission during focus changes."""
import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus


QT_IBUS_CLIENT = "QIBusInputContext"


def preedit_focus_mode(focus_identity, *, input_state=None):
    # Qt's IBus plugin commits to its current widget before sending Reset.
    # IBus COMMIT would submit its cached copy again, possibly into a new widget
    # sharing that input context. GTK and unknown clients keep the IBus contract.
    # See docs/preedit-ownership.md for the toolkit and daemon source boundaries.
    client = focus_identity[1] if focus_identity is not None else None
    if input_state == "unicodeInput" or client == QT_IBUS_CLIENT:
        return IBus.PreeditFocusMode.CLEAR
    return IBus.PreeditFocusMode.COMMIT
