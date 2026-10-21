"""Use each product adapter with explicit preferences in the isolated test home."""
import json
import os
from pathlib import Path
import runpy
import sys


adapter = os.environ["AZOOKEY_TEST_PREEDIT_ADAPTER"]
assert adapter in ("ordinary", "reading")
settings = Path(os.environ["XDG_CONFIG_HOME"]) / "azookey-tree/settings.json"
settings.parent.mkdir(parents=True, exist_ok=True)
with settings.open("x", encoding="utf-8") as output:
    json.dump({"live": False, "learning": "nothing", "predictiveTyping": False}, output)
linux = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(linux))
sys.argv = [str(linux / "ibus-azookey-tree.py")]
if adapter == "reading":
    sys.argv.append("--reading-worker-development")
runpy.run_path(sys.argv[0], run_name="__main__")
