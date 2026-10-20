"""User-facing Linux messages, kept outside state and storage code."""
from functools import cache
import json
import pathlib


@cache
def _catalog():
    # Linux currently ships Japanese UI. Keep the catalog separate so other
    # languages can be added without changing recovery or input behavior.
    path = pathlib.Path(__file__).with_name("locales") / "ja.json"
    return json.loads(path.read_text(encoding="utf-8"))


def message(key, **values):
    return _catalog()[key].format(**values)
