#!/usr/bin/env python3
"""Capture a test field's IBus context, then explicitly reset that same context."""
import argparse
import json
import pathlib
import time


# A missing reply is a failed fault-injection attempt, not an observed Reset.
CALL_TIMEOUT_MS = 3000


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("capture", "reset"))
    parser.add_argument("--context-file", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    import gi
    gi.require_version("IBus", "1.0")
    from gi.repository import Gio, IBus
    IBus.init()
    bus = IBus.Bus()
    connection = bus.get_connection()
    if connection is None or not connection.get_guid():
        raise SystemExit("The test session has no IBus connection")
    current = bus.current_input_context()
    if arguments.action == "capture":
        engine = bus.get_global_engine()
        if not current or engine is None or engine.get_name() != "azookey-tree":
            raise SystemExit("Focus the synthetic test field with azooKey Tree first")
        observed = {
            "busGUID": connection.get_guid(), "contextPath": current,
            "engineName": engine.get_name(), "capturedAt": time.time(),
        }
        with arguments.context_file.open("x", encoding="utf-8") as stream:
            json.dump(observed, stream)
    else:
        observed = json.loads(arguments.context_file.read_text(encoding="utf-8"))
        if observed.get("engineName") != "azookey-tree" or observed["busGUID"] != connection.get_guid():
            raise SystemExit("IBus restarted; capture the original field again")
        path = observed["contextPath"]
        if not path.startswith("/org/freedesktop/IBus/InputContext_"):
            raise SystemExit("The saved object is not an IBus input context")
        connection.call_sync(
            "org.freedesktop.IBus", path, "org.freedesktop.IBus.InputContext", "Reset",
            None, None, Gio.DBusCallFlags.NONE, CALL_TIMEOUT_MS, None,
        )
        observed = {**observed, "resetAcknowledgedAt": time.time(), "currentContextPath": current}
    print(json.dumps(observed))


if __name__ == "__main__":
    main()
