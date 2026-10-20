"""Launch the product development adapter in the isolated IBus test session."""
from pathlib import Path
import json
import os
import runpy
import sys


# The development entry now honours saved preferences. This fixture explicitly
# chooses supported behavior inside the test session's fresh config directory.
settings = Path(os.environ["XDG_CONFIG_HOME"]) / "azookey-tree" / "settings.json"
settings.parent.mkdir(parents=True, exist_ok=True)
with settings.open("x", encoding="utf-8") as output:
    json.dump({"live": False, "learning": "nothing"}, output)

linux = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(linux))
sys.argv = [str(linux / "ibus-azookey-tree.py"), "--reading-worker-development"]
runpy.run_path(sys.argv[0], run_name="__main__")
