"""Launch the product development adapter in the isolated IBus test session."""
from pathlib import Path
import runpy
import sys


linux = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(linux))
sys.argv = [str(linux / "ibus-azookey-tree.py"), "--reading-worker-development"]
runpy.run_path(sys.argv[0], run_name="__main__")
