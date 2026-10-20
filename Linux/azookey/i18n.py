"""The desktop UI's Japanese message catalog."""

import json
from pathlib import Path


_MESSAGES = json.loads((Path(__file__).parent / "locales" / "ja.json").read_text(encoding="utf-8"))


def text(key, **values):
    return _MESSAGES[key].format(**values)
