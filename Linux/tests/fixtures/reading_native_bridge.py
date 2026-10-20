#!/usr/bin/python3
"""Identify the test's real child process, then replace this wrapper with Core."""
import json
import os
from pathlib import Path
import time


role = os.environ["AZOOKEY_BRIDGE_ROLE"]
assert role in ("reading", "candidate")
directory = Path(os.environ["AZOOKEY_NATIVE_ARTIFACTS"]) / "workers"
directory.mkdir(parents=True, exist_ok=True)
executable = os.environ["AZOOKEY_READING_TEST_BRIDGE"]
(directory / f"{role}-{os.getpid()}.json").write_text(json.dumps({
    "role": role, "pid": os.getpid(), "executable": executable,
    "startedMonotonic": time.monotonic(),
}) + "\n")
os.execv(executable, [executable])
