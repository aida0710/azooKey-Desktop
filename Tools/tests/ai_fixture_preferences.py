#!/usr/bin/env python3
"""Preserve/restore only the three preferences files touched by an AI trial."""
import argparse
import hashlib
import json
import os
import pathlib
import stat
import tempfile


FILES = ("settings.json", "settings.last-good.json", "prompts.json")


def digest(content):
    return hashlib.sha256(content).hexdigest()


def backup(directory, *, source):
    # A fresh directory prevents a later run from overwriting the original.
    directory.mkdir(mode=0o700, parents=True, exist_ok=False)
    manifest = {"sourceDirectory": str(source.resolve()), "files": {}}
    for name in FILES:
        original = source / name
        if original.is_symlink():
            raise ValueError(f"Refusing a symlink: {name}")
        if not original.exists():
            manifest["files"][name] = {"existed": False}
            continue
        if not original.is_file():
            raise ValueError(f"Expected a regular file: {name}")
        content = original.read_bytes()
        saved = directory / name
        saved.write_bytes(content)
        saved.chmod(0o600)
        manifest["files"][name] = {
            "existed": True, "sha256": digest(content),
            "mode": stat.S_IMODE(original.stat().st_mode),
        }
    manifest_path = directory / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    manifest_path.chmod(0o600)
    return manifest


def read_backup(directory):
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    if set(manifest["files"]) != set(FILES):
        raise ValueError("The manifest does not match the three fixture preferences")
    source = pathlib.Path(manifest["sourceDirectory"])
    contents = {}
    # Validate every saved file before changing any current preference.
    for name, original in manifest["files"].items():
        destination = source / name
        if destination.is_symlink():
            raise ValueError(f"Refusing a symlink: {name}")
        if destination.exists() and not destination.is_file():
            raise ValueError(f"Expected a regular file: {name}")
        if original["existed"]:
            content = (directory / name).read_bytes()
            if digest(content) != original["sha256"]:
                raise ValueError(f"The saved bytes changed: {name}")
            contents[name] = content
    return manifest, contents


def restore(directory, *, names=FILES):
    if not set(names) <= set(FILES):
        raise ValueError("Only fixture preferences may be restored")
    manifest, contents = read_backup(directory)
    source = pathlib.Path(manifest["sourceDirectory"])
    for name, original in manifest["files"].items():
        if name not in names:
            continue
        destination = source / name
        if not original["existed"]:
            destination.unlink(missing_ok=True)
            continue
        descriptor, temporary = tempfile.mkstemp(prefix=".ai-fixture-restore-", dir=source)
        try:
            with os.fdopen(descriptor, "wb") as stream:
                os.fchmod(stream.fileno(), original["mode"])
                stream.write(contents[name])
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, destination)
        finally:
            pathlib.Path(temporary).unlink(missing_ok=True)
    return verify(directory)


def verify(directory):
    manifest = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    source = pathlib.Path(manifest["sourceDirectory"])
    checks = {}
    for name, original in manifest["files"].items():
        current = source / name
        checks[name] = (not current.exists() if not original["existed"] else
                        current.is_file() and not current.is_symlink()
                        and digest(current.read_bytes()) == original["sha256"]
                        and stat.S_IMODE(current.stat().st_mode) == original["mode"])
    return {"matches": all(checks.values()), "files": checks}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("backup", "restore", "verify"))
    parser.add_argument("--directory", required=True, type=pathlib.Path)
    parser.add_argument("--source", type=pathlib.Path)
    arguments = parser.parse_args()
    if arguments.action == "backup":
        if arguments.source is None:
            parser.error("--source is required for backup")
        recorded = backup(arguments.directory, source=arguments.source)
        # Hashes only; the saved JSON stays in the private guest directory.
        print(json.dumps(recorded))
    else:
        outcome = restore(arguments.directory) if arguments.action == "restore" else verify(arguments.directory)
        print(json.dumps(outcome))
        if not outcome["matches"]:
            raise SystemExit(1)


if __name__ == "__main__":
    main()
