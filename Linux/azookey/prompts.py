"""Prompt history stores instructions only, never the selected document text."""
import json
import os
import pathlib
import tempfile
import time


def parse_shortcut(value):
    if not value.strip():
        return None
    parts = value.lower().split("+")
    modifiers = {"shift": 1, "ctrl": 2, "alt": 4, "super": 8}
    if len(parts[-1]) != 1 or any(part not in modifiers for part in parts[:-1]):
        raise ValueError("ショートカットは Ctrl+Alt+e の形式で入力してください。")
    flags = 0
    for part in parts[:-1]:
        flags |= modifiers[part]
    if not flags:
        raise ValueError("Ctrl・Alt・Shift・Superのいずれかを指定してください。")
    return {"key": parts[-1], "modifiers": flags}


def shortcut_text(value):
    if not value:
        return ""
    return "+".join([name for name, bit in [("Ctrl", 2), ("Alt", 4), ("Shift", 1), ("Super", 8)] if value["modifiers"] & bit] + [value["key"]])


def matches(value, event):
    return bool(value and value["key"].lower() == event.get("charactersIgnoringModifiers")
                and value["modifiers"] == event["modifierFlags"])


class PromptHistory:
    def __init__(self, directory=None):
        base = pathlib.Path(directory or os.environ.get("XDG_CONFIG_HOME", pathlib.Path.home() / ".config"))
        self.path = base / "azookey-tree/prompts.json"

    def load(self):
        if not self.path.is_file():
            return [{"prompt": prompt, "pinned": True, "lastUsed": 0, "shortcut": None}
                    for prompt in ["elaborate", "rewrite", "formal", "english"]]
        try:
            items = json.loads(self.path.read_text())
            return sorted(items, key=lambda item: (not item["pinned"], -item["lastUsed"]))
        except (ValueError, KeyError, TypeError):
            return []

    def save(self, prompt, pinned=False, shortcut=None):
        items = [item for item in self.load() if item["prompt"] != prompt]
        if shortcut and any(item.get("shortcut") == shortcut for item in items):
            raise ValueError("このショートカットは別のプロンプトに割り当てられています。")
        items.insert(0, {"prompt": prompt, "pinned": pinned, "shortcut": shortcut if pinned else None, "lastUsed": time.time()})
        items = [item for item in items if item["pinned"]] + [item for item in items if not item["pinned"]][:10]
        self.path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        fd, temporary = tempfile.mkstemp(dir=self.path.parent)
        try:
            with os.fdopen(fd, "w") as stream:
                json.dump(items, stream, ensure_ascii=False)
            os.replace(temporary, self.path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
