"""Let renderer tests use Core's candidate display and layout decisions.

Synthetic snapshots omit the `candidateDisplay` that every bridge reply has;
the real Swift bridge derives it with the same function as a live session.
"""
import atexit
import pathlib
import sys

import gi

# Renderer tests import GTK after this helper; they test the GTK 3 renderer.
gi.require_version("Gtk", "3.0")
sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.bridge import Bridge

_bridge = None


def core_bridge():
    global _bridge
    if _bridge is None:
        _bridge = Bridge()
        atexit.register(_bridge.close)
    return _bridge


def displayed(snapshot, *, previous=None):
    """Return the snapshot with Core's `candidateDisplay`."""
    request = {**snapshot, "previous": previous} if previous else snapshot
    display = core_bridge().request("candidate-display", snapshot=request)["candidateDisplay"]
    return {**snapshot, "candidateDisplay": display}


def request_layout(layout, completion):
    """A synchronous `candidate-layout` round trip for tests."""
    completion(core_bridge().request("candidate-layout", layout=layout)["candidateLayout"])


def core_tree_panel(select):
    """A TreePanel whose synthetic snapshots get their display from Core.

    Like a session, the previous selection in the same context lets Core
    decide whether a focus move within one candidate expands the tree.
    """
    from azookey.tree_panel import TreePanel

    class CoreTreePanel(TreePanel):
        def update(self, snapshot):
            if "candidateDisplay" not in snapshot:
                last = self.snapshot
                previous = ({"selection": last.get("selection"), "focusedNode": last.get("focusedNode")}
                            if last and last.get("contextId") == snapshot.get("contextId") else None)
                snapshot = displayed(snapshot, previous=previous)
            super().update(snapshot)

    return CoreTreePanel(select, request_layout)
