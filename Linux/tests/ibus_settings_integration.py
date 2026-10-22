"""Keep a real IBus context converting while its settings document is damaged."""
import json
import os
import pathlib
import sys

import gi
gi.require_version("IBus", "1.0")
from gi.repository import IBus

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))
from azookey.settings_store import SettingsStore
from ibus_async_integration import Field, wait_until


def main():
    IBus.init()
    bus = IBus.Bus()
    assert bus.is_connected()
    store = SettingsStore()
    path = store.path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({"live": False, "tree": False, "halfSpace": True, "learning": "nothing"}))
    field = Field(bus, "azookey-settings-recovery")
    field.context.set_capabilities(IBus.Capabilite.PREEDIT_TEXT | IBus.Capabilite.FOCUS | IBus.Capabilite.AUXILIARY_TEXT)
    notices = []
    field.context.connect("update-auxiliary-text", lambda _context, text, visible: notices.append(text.get_text()) if visible else None)
    field.focus()
    field.type("a")
    wait_until(lambda: field.preedit == "あ")
    field.key(IBus.KEY_Return)
    wait_until(lambda: field.commits == ["あ"])
    field.key(IBus.KEY_space)
    wait_until(lambda: field.commits == ["あ", " "])

    documents = [
        ("invalid-json", "{", False),
        ("wrong-type", '{"live":"yes"}', False),
        ("unknown-value", '{"learning":"unknown"}', False),
        ("unknown-key", '{"unrecognized":true}', False),
    ]
    if os.geteuid() != 0:
        documents.append(("unreadable-file", "{}", True))
    for name, document, unreadable in documents:
        path.write_text(document)
        if unreadable:
            path.chmod(0)
        previous_commits = list(field.commits)
        previous_notices = len(notices)
        try:
            field.type("ai")
            wait_until(lambda: field.preedit == "あい")
            field.key(IBus.KEY_Return)
            wait_until(lambda: field.commits == previous_commits + ["あい"])
            assert field.forwarded == [], (name, field.forwarded)
            assert len(notices) == previous_notices + 1, (name, notices)
        finally:
            path.chmod(0o600)
        assert path.read_text() == document

    original = path.read_bytes()
    # Repair the shared file while the same engine/context stays alive.
    # The next key must observe halfSpace=False without a process restart.
    restored = store.save({"live": False, "tree": False, "halfSpace": False, "learning": "nothing"}, recover=True)
    assert restored.backup_path.read_bytes() == original
    previous_commits = list(field.commits)
    field.key(IBus.KEY_space)
    wait_until(lambda: field.commits == previous_commits + ["　"])
    field.type("nihongo")
    field.key(IBus.KEY_space)
    field.key(IBus.KEY_Return)
    wait_until(lambda: field.commits == previous_commits + ["　", "日本語"])
    assert field.forwarded == []
    field.context.focus_out()
    print(json.dumps({"status": "PASS", "settings_cases": [name for name, _, _ in documents],
                      "notices": len(notices), "restart_required": False}))


if __name__ == "__main__":
    main()
