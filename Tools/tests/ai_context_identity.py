#!/usr/bin/env python3
"""Record the active synthetic field's IBus identity without sending input."""
import argparse
import json
import pathlib
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--context-file", required=True, type=pathlib.Path)
    arguments = parser.parse_args()
    import gi
    gi.require_version("IBus", "1.0")
    from gi.repository import IBus
    IBus.init()
    bus = IBus.Bus()
    connection = bus.get_connection()
    if connection is None or not connection.get_guid():
        raise SystemExit("The test session has no IBus connection")
    current = bus.current_input_context()
    engine = bus.get_global_engine()
    if not current or engine is None or engine.get_name() != "azookey-tree":
        raise SystemExit("Focus the synthetic test field with azooKey Tree first")
    observed = {
        "busGUID": connection.get_guid(), "contextPath": current,
        "engineName": engine.get_name(), "capturedAt": time.time(),
    }
    with arguments.context_file.open("x", encoding="utf-8") as stream:
        json.dump(observed, stream)
    print(json.dumps(observed))


if __name__ == "__main__":
    main()
