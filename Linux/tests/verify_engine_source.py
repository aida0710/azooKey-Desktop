"""Confirm the tested service belongs to the source process we started."""
import hashlib
import json
import pathlib
import sys

from gi.repository import Gio, GLib


def verify_source(expected_pid, source):
    connection = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    process_id = connection.call_sync(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.azookey.Tree",)),
        GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None,
    ).unpack()[0]
    assert process_id == expected_pid, f"test used engine PID {process_id}, expected source PID {expected_pid}"
    arguments = pathlib.Path(f"/proc/{process_id}/cmdline").read_bytes().split(b"\0")
    arguments = [argument.decode() for argument in arguments if argument]
    source = source.resolve()
    assert source in [pathlib.Path(argument).resolve() for argument in arguments], arguments
    engine = source.parent / "azookey/engine.py"
    print(json.dumps({
        "source_engine_pid": process_id,
        "source_entrypoint": str(source),
        "entrypoint_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "engine_sha256": hashlib.sha256(engine.read_bytes()).hexdigest(),
    }))


if __name__ == "__main__":
    verify_source(int(sys.argv[1]), pathlib.Path(sys.argv[2]))
