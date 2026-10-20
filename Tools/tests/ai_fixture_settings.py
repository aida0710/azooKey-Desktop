#!/usr/bin/env python3
"""Apply/restore local mock preferences through the installed package's APIs."""
import argparse
import hashlib
import json
import os
import pathlib
import sys

from ai_fixture_preferences import verify
from ai_fixture_restore import original_settings, restore_settings
from ai_mock_server import MODEL, control_address


INSTALLED_ROOT = pathlib.Path("/opt/azookey-tree")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("apply", "restore"))
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    parser.add_argument("--server-state", type=pathlib.Path)
    arguments = parser.parse_args()
    if not (INSTALLED_ROOT / "libexec/azookey-desktop-bridge").is_file():
        raise SystemExit("Run only in the dedicated VM with the installed package")
    sys.path.insert(0, str(INSTALLED_ROOT))
    from azookey.bridge import Bridge
    from azookey.settings_store import SettingsStore
    original_path = arguments.directory / "original-effective-settings.json"
    environment = os.environ.copy()
    for key in ("AZOOKEY_BRIDGE", "AZOOKEY_DATA_DIR", "AZOOKEY_RESOURCES"):
        environment.pop(key, None)
    environment["LD_LIBRARY_PATH"] = str(INSTALLED_ROOT / "libexec")
    def bridge_factory():
        return Bridge(str(INSTALLED_ROOT / "libexec/azookey-desktop-bridge"), environment=environment)

    if arguments.action == "restore":
        settings_path = SettingsStore().path
        original_settings(arguments.directory, settings_path=settings_path)
        from ai_fixture_runtime import InstalledRuntime
        runtime = InstalledRuntime(INSTALLED_ROOT)
        outcome = restore_settings(
            arguments.directory, settings_path=settings_path, bridge_factory=bridge_factory, runtime=runtime,
        )
        print(json.dumps(outcome))
        return
    bridge = bridge_factory()
    try:
        if arguments.action == "apply":
            if arguments.server_state is None:
                parser.error("--server-state is required for apply")
            if not verify(arguments.directory)["matches"]:
                raise SystemExit("Preferences changed after backup; start a new trial")
            address = control_address(arguments.server_state)
            server = json.loads(arguments.server_state.read_text(encoding="utf-8"))
            if server["model"] != MODEL or server["endpoint"] != address + "/v1/chat/completions":
                raise SystemExit("The local fixture model does not match")
            store = SettingsStore()
            manifest = json.loads((arguments.directory / "manifest.json").read_text(encoding="utf-8"))
            if store.path.parent.resolve() != pathlib.Path(manifest["sourceDirectory"]):
                raise SystemExit("The backup belongs to a different preferences directory")
            loaded = store.load(bridge.request("settings")["settings"])
            if loaded.problem:
                raise SystemExit("Resolve the existing settings problem before starting an AI trial")
            with original_path.open("x", encoding="utf-8") as stream:
                original_path.chmod(0o600)
                json.dump(loaded.values, stream, ensure_ascii=False)
                stream.flush()
                os.fsync(stream.fileno())
            checksum = hashlib.sha256(original_path.read_bytes()).hexdigest()
            checksum_path = arguments.directory / "original-effective-settings.sha256"
            checksum_path.write_text(checksum + "\n", encoding="ascii")
            checksum_path.chmod(0o600)
            changes = {
                "aiEnabled": True, "aiModel": MODEL, "aiEndpoint": server["endpoint"],
                "includeContext": False, "transformShortcut": {"key": "s", "modifiers": 2},
            }
            store.update(changes, defaults=loaded.values)
            print(json.dumps({"applied": changes, "originalSHA256": checksum}))
    finally:
        bridge.close()


if __name__ == "__main__":
    main()
