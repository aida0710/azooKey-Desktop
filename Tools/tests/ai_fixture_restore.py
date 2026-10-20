"""Restore preferences only across an observed IME stop/start boundary."""
import hashlib
import json
import pathlib
import time

from ai_fixture_preferences import read_backup, restore, verify


def original_settings(directory, *, settings_path):
    manifest, _contents = read_backup(directory)
    if settings_path.parent.resolve() != pathlib.Path(manifest["sourceDirectory"]).resolve():
        raise ValueError("The backup belongs to a different preferences directory")
    original_path = directory / "original-effective-settings.json"
    expected = (directory / "original-effective-settings.sha256").read_text().strip()
    if hashlib.sha256(original_path.read_bytes()).hexdigest() != expected:
        raise ValueError("The saved effective settings changed; no preference was restored")
    return json.loads(original_path.read_text(encoding="utf-8"))


def record_phase(directory, phase, **details):
    path = directory / "restoration.jsonl"
    with path.open("a", encoding="utf-8") as stream:
        path.chmod(0o600)
        stream.write(json.dumps({"phase": phase, "observedAt": time.time(), **details}) + "\n")


def check_core(bridge_factory, expected, *, configure=False):
    bridge = bridge_factory()
    try:
        if configure and "error" in bridge.request("configure", settings=expected):
            raise RuntimeError("Core rejected the original settings")
        if bridge.request("settings")["settings"] != expected:
            raise RuntimeError("Core does not match the original effective settings")
    finally:
        bridge.close()


def restore_settings(directory, *, settings_path, bridge_factory, runtime):
    # Validate both ownership and every saved byte before stopping anything or
    # creating a Core process in a potentially different XDG_CONFIG_HOME.
    original = original_settings(directory, settings_path=settings_path)
    stopped = runtime.stop()
    record_phase(directory, "engine-stopped", **stopped)
    runtime.require_stopped()
    check_core(bridge_factory, original, configure=True)
    runtime.require_stopped()
    restore(directory)
    record_phase(directory, "files-restored-engine-stopped")
    try:
        started = runtime.restart()
        record_phase(directory, "startup-acknowledged", **started)
        # Initial Engine.reload_settings remembers a complete last-good file.
        # Restore only that file after its acknowledgement; touching settings
        # again would create a fresh stamp and enqueue another remember.
        restore(directory, names=("settings.last-good.json",))
        runtime.barrier()
        check_core(bridge_factory, original)
        outcome = verify(directory)
        if not outcome["matches"]:
            raise RuntimeError("Preferences changed after the startup acknowledgement")
        record_phase(directory, "complete", **outcome)
        return {**outcome, "engineRestarted": True, "startupAcknowledged": True}
    finally:
        runtime.close()
