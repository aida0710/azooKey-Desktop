"""A real Core for Linux AI glue tests, without a network or a GUI session.

Core makes every AI decision. These tests drive the IBus/GTK glue against
the actual Swift bridge; only the AI provider and the AT-SPI reads are
replaced, so no request leaves the machine.
"""
import os
import pathlib
import tempfile
import unittest
from unittest import mock

from azookey.async_bridge import Reply
from azookey.bridge import Bridge
from azookey.ime_shortcuts import publish


ORIGINAL_IDENTITY = ("/input/1", "gnome-shell")
# Shown as the destination; never contacted, because the provider is replaced.
FIXTURE_ENDPOINT = "https://user:password@api.example.invalid:8443/secret?key=private"


def field_fixture(text="前 原文 後", *, cursor=4, anchor=2, identity=ORIGINAL_IDENTITY, sensitive=False, fresh=True):
    """The facts the engine reports for a focused field (UTF-16 positions)."""
    return {
        "identity": list(identity) if identity else None,
        "surrounding": {"text": text, "cursorUTF16": cursor, "anchorUTF16": anchor},
        "hasSurroundingUpdate": fresh, "isSensitive": sensitive,
    }


def witness_fixture(**changes):
    """An AT-SPI read of the original field's selection."""
    return {"object": ["fixture-bus", ":1.4", "/field/1"], "window": [":1.4", "/window/1"],
            "start": 2, "end": 4, "before": "前 ", "selected": "原文", "after": " 後", **changes}


class CoreWorker:
    """Runs each operation on the real bridge at once, in submission order."""

    def __init__(self, bridge):
        self.bridge = bridge
        self.operations = []

    def submit(self, request):
        if request.cancelled.is_set():
            return
        self.operations.append(request.operation)
        try:
            reply = Reply(snapshot=self.bridge.request(request.operation, **request.payload))
        except (OSError, RuntimeError, ValueError):
            reply = Reply(failed=True)
        request.complete(reply)


def publish_core_shortcuts():
    """Install Core's routing bindings, as the engine does when it starts.
    Key routing tests need them: before Core answers, every Control chord
    goes to Core."""
    if not os.environ.get("AZOOKEY_BRIDGE"):
        raise unittest.SkipTest("build the real Swift bridge first")
    bridge = Bridge()
    try:
        publish(bridge.request("ime-shortcuts")["shortcuts"])
    finally:
        bridge.close()


def start_ai_bridge():
    """A bridge with AI enabled. The caller sets private XDG_CONFIG_HOME and
    AZOOKEY_DATA_DIR first, so no user settings or prompt history are read."""
    bridge = Bridge()
    settings = bridge.request("settings")["settings"]
    settings = {**settings, "aiEnabled": True, "aiEndpoint": FIXTURE_ENDPOINT, "aiModel": "fixture-model",
                "includeContext": False, "live": False}
    assert not bridge.request("configure", settings=settings).get("error")
    publish(bridge.request("ime-shortcuts")["shortcuts"])
    return bridge


@unittest.skipUnless(os.environ.get("AZOOKEY_BRIDGE"), "build the real Swift bridge first")
class CoreAITestCase(unittest.TestCase):
    """One bridge per test class with AI enabled and private config/data."""

    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        root = pathlib.Path(cls.directory.name)
        cls.environment = mock.patch.dict(os.environ, {
            "XDG_CONFIG_HOME": str(root / "config"), "AZOOKEY_DATA_DIR": str(root / "data"),
        })
        cls.environment.start()
        cls.bridge = start_ai_bridge()

    @classmethod
    def tearDownClass(cls):
        cls.bridge.close()
        cls.environment.stop()
        cls.directory.cleanup()
