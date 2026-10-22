#!/usr/bin/python3
"""Read real GTK selections over a private AT-SPI bus and let the real Core
decide on them, without external AI."""
import json
import os
import pathlib
import sys
import tempfile
import threading
import time

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.focused_text import inspect_focused_text


# Daemon/GTK registration is asynchronous; wait for observed state, not a fixed delay.
TEST_TIMEOUT_SECONDS = 5
POLL_INTERVAL_SECONDS = 0.005


def wait_until(predicate, description):
    deadline = time.monotonic() + TEST_TIMEOUT_SECONDS
    context = GLib.MainContext.default()
    while time.monotonic() < deadline:
        while context.pending():
            context.iteration(False)
        if predicate():
            return
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(description)


class TextFields:
    def __init__(self):
        self.window = Gtk.Window(title="azooKey AI target fixture")
        self.window.set_default_size(500, 160)
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.fields = [Gtk.Entry(text="前 原文 後"), Gtk.Entry(text="前 原文 後")]
        for index, field in enumerate(self.fields):
            field.get_accessible().set_name(f"fixture field {index + 1}")
            box.add(field)
        self.window.add(box)
        self.window.show_all()

    def focus(self, index):
        self.window.present()
        self.window.get_window().focus(Gdk.CURRENT_TIME)
        field = self.fields[index]
        field.grab_focus()
        field.select_region(2, 4)
        wait_until(lambda: self.window.is_active() and field.has_focus(), "GTK field did not receive focus")

    def close(self):
        self.window.destroy()


def inspect(context_characters):
    replies = []
    threading.Thread(target=lambda: replies.append(inspect_focused_text(context_characters)), daemon=True).start()
    wait_until(lambda: replies, "accessibility read did not complete")
    return replies[0]


class CoreTarget:
    """The real Core's transformation decisions for one IBus selection."""
    # The IBus facts both GTK fields share: one context, the same text.
    FIELD = {"identity": ["/fixture/context", "gnome-shell"],
             "surrounding": {"text": "前 原文 後", "cursorUTF16": 4, "anchorUTF16": 2},
             "hasSurroundingUpdate": True, "isSensitive": False}

    def __init__(self, bridge):
        self.bridge = bridge
        self.transformation = None

    def request(self, operation, **ai):
        return self.bridge.request(f"ai-transform-{operation}", context="fixture",
                                   ai={"transformation": self.transformation, **ai})

    def open(self, witness):
        opened = self.bridge.request("ai-transform-open", context="fixture", ai={"field": self.FIELD})
        self.transformation = opened["transformation"]
        available = self.request("target", field=self.FIELD, witness=witness)["targetAvailable"]
        revision = self.request("preview", prompt="敬語に直す", pinned=False, shortcutText="",
                                includeContext=False, field=self.FIELD)["revision"]
        self.request("result", revision=revision, text="変更済み")
        return available and self.request("confirm")["confirmed"]

    def take(self, witness):
        return self.request("take", field=self.FIELD, witness=witness).get("replacement")


def main():
    from ai_core_fixture import start_ai_bridge
    fields = TextFields()
    directory = tempfile.TemporaryDirectory()
    os.environ.update(XDG_CONFIG_HOME=f"{directory.name}/config", AZOOKEY_DATA_DIR=f"{directory.name}/data")
    bridge = start_ai_bridge()
    core = CoreTarget(bridge)
    context_characters = bridge.request("ai-transform-open", context="fixture",
                                        ai={"field": CoreTarget.FIELD})["contextCharacters"]
    try:
        fields.focus(0)
        original = inspect(context_characters)
        assert original is not None, "active GTK field was not available through AT-SPI"
        assert original["selected"] == "原文" and original["window"]
        fields.focus(1)
        second = inspect(context_characters)
        assert second and second["object"] != original["object"]
        assert second["window"] == original["window"]
        assert core.open(original), "Core did not accept the original field's read"
        assert core.take(second) is None, "identical text in another field must not be replaced"
        fields.focus(0)
        returned = inspect(context_characters)
        assert returned == original
        assert core.open(original)
        assert core.take(returned) == "変更済み"
        assert core.take(returned) is None
        fields.fields[0].set_editable(False)
        assert inspect(context_characters) is None
        fields.fields[0].set_editable(True)
        fields.fields[0].set_visibility(False)
        assert inspect(context_characters) is None
        fields.fields[0].set_visibility(True)
        fields.fields[0].set_text("前 別文 後")
        fields.fields[0].select_region(2, 4)
        changed = inspect(context_characters)
        assert changed and changed["selected"] == "別文"
        assert not core.open(changed), "Core must not accept a read of other text as the IBus selection"
        print(json.dumps({"status": "PASS", "checks": 9, "same_context_different_objects": True,
                          "identity": "AT-SPI bus GUID + unique bus name + object path",
                          "window_identity_verified": True, "decided_by": "Core", "external_ai_requests": 0}))
    finally:
        fields.close()
        bridge.close()
        directory.cleanup()


if __name__ == "__main__":
    main()
