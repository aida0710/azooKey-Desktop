#!/usr/bin/python3
"""Observe the real recovery UI and real Core using only isolated synthetic settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import sys

import gi
gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkX11, GLib, Gtk

# Sampling observes GTK state; it never responds to the confirmation dialog.
OBSERVATION_INTERVAL_MILLISECONDS = 20
INVALID_DOCUMENT = b"{ synthetic recovery fixture"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("observation", type=Path)
    parser.add_argument("--source-root", type=Path, required=True)
    arguments = parser.parse_args()
    sys.path.insert(0, str(arguments.source_root))
    os.environ.update({"XDG_CONFIG_HOME": str(arguments.observation.parent / "config"),
                       "XDG_DATA_HOME": str(arguments.observation.parent / "data"),
                       "AZOOKEY_DATA_DIR": str(arguments.observation.parent / "data/azookey-tree")})
    from azookey.bridge import Bridge
    from azookey.settings import SettingsWindow
    from azookey.settings_store import SettingsStore

    bridge = Bridge()
    store = SettingsStore()
    try:
        values = bridge.request("settings")["settings"]
        values.update({"live": False, "tree": False, "learning": "nothing", "includeContext": False})
        values["userDictionary"] = {"items": [{
            "id": "d1300001-0000-4000-8000-000000000001",
            "reading": "ふくきゅう", "word": "UXRecovery", "hint": "synthetic recovery fixture",
        }]}
        store.save(values)
        assert not bridge.request("configure", settings=values).get("error")
        values = bridge.request("settings")["settings"]
        store.save(values)
    finally:
        bridge.close()
    store.path.write_bytes(INVALID_DOCUMENT)
    window = SettingsWindow()
    window.show_all()
    window.present()
    sequence = 0
    key_events = []
    observed_windows = set()

    def observe_keys(widget):
        native = widget.get_window()
        if native is None or native.get_xid() in observed_windows:
            return
        window_id = native.get_xid()
        observed_windows.add(window_id)

        def record_key(_widget, event):
            if event.type in (Gdk.EventType.KEY_PRESS, Gdk.EventType.KEY_RELEASE):
                key_events.append({"window": window_id, "type": int(event.type), "keyval": event.keyval})

        widget.connect("event-after", record_key)

    def observe():
        nonlocal sequence
        sequence += 1
        dialogs = [dialog for dialog in Gtk.Window.list_toplevels()
                   if isinstance(dialog, Gtk.MessageDialog) and dialog.get_visible()]
        for widget in (window, *dialogs):
            observe_keys(widget)
        document = store.path.read_bytes()
        try:
            settings = json.loads(document)
        except ValueError:
            settings = None
        observation = {
            "sequence": sequence, "editorWindow": window.get_window().get_xid(), "keyEvents": key_events,
            "dialogs": [{"window": dialog.get_window().get_xid(), "mapped": dialog.get_mapped()}
                        for dialog in dialogs],
            "settingsSHA256": hashlib.sha256(document).hexdigest(),
            "invalidSHA256": hashlib.sha256(INVALID_DOCUMENT).hexdigest(),
            "settings": settings, "originalDictionary": values["userDictionary"],
            "archives": [hashlib.sha256(path.read_bytes()).hexdigest()
                         for path in sorted(store.path.parent.glob("settings.recovered-*"))],
            "recoveryVisible": window.recovery_bar.get_visible(), "message": window.message.get_text(),
        }
        temporary = arguments.observation.with_suffix(".tmp")
        temporary.write_text(json.dumps(observation, ensure_ascii=False))
        temporary.replace(arguments.observation)
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(OBSERVATION_INTERVAL_MILLISECONDS, observe)
    try:
        Gtk.main()
    finally:
        window.destroy()


if __name__ == "__main__":
    main()
