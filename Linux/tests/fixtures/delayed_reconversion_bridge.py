#!/usr/bin/env python3
"""Delay real Core reconversion replies without replacing its conversion logic."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


# Bound cleanup even if the real converter does not terminate normally.
CHILD_EXIT_TIMEOUT_SECONDS = 5
# Core uses macOS-style key codes for both Enter keys on every platform.
READING_ENTER_KEYS = (36, 76)


def record_operation(path, operation, phase):
    if path is None:
        return
    with path.open("a", encoding="utf-8") as trace:
        trace.write(json.dumps({
            "operation": operation, "phase": phase, "monotonic": time.monotonic(),
        }) + "\n")


def stop(_signal, _frame):
    raise SystemExit(0)


def main():
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    delay = float(os.environ["AZOOKEY_TEST_DELAY"])
    failure_file = Path(os.environ["AZOOKEY_TEST_RECONVERSION_FAILURE_FILE"])
    trace_path = os.environ.get("AZOOKEY_TEST_RECONVERSION_TRACE")
    trace_path = Path(trace_path) if trace_path else None
    bridge = subprocess.Popen(
        [os.environ["AZOOKEY_REAL_BRIDGE"]], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )
    try:
        for line in sys.stdin:
            request = json.loads(line)
            operation = request["operation"]
            record_operation(trace_path, operation, "started")
            submits_reading = (
                operation == "reconversion-reading"
                and request.get("event", {}).get("keyCode") in READING_ENTER_KEYS
            )
            if operation in ("reconvert", "undo-commit", "confirm-reconversion") or submits_reading:
                time.sleep(delay)
            if operation == "confirm-reconversion" and failure_file.exists():
                record_operation(trace_path, operation, "failed")
                return
            bridge.stdin.write(line)
            bridge.stdin.flush()
            response = bridge.stdout.readline()
            if not response:
                return
            record_operation(trace_path, operation, "replied")
            print(response, end="", flush=True)
    finally:
        bridge.stdin.close()
        bridge.terminate()
        try:
            bridge.wait(timeout=CHILD_EXIT_TIMEOUT_SECONDS)
        except subprocess.TimeoutExpired:
            bridge.kill()
            bridge.wait()
        bridge.stdout.close()


if __name__ == "__main__":
    main()
