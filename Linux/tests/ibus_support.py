"""Helpers restricted to the engine owned by the private integration-test bus."""
import os
import pathlib
import signal
import time

from gi.repository import Gio, GLib


# Only fixture process exit is polled; conversion timing is not inferred.
PROCESS_EXIT_WAIT_SECONDS = 3
PROCESS_EXIT_POLL_SECONDS = 0.005


def crash_converter(connection, executable_name):
    process_id = connection.call_sync(
        "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus",
        "GetConnectionUnixProcessID", GLib.Variant("(s)", ("org.azookey.Tree",)),
        GLib.VariantType.new("(u)"), Gio.DBusCallFlags.NONE, 3000, None,
    ).unpack()[0]
    # Popen runs in a worker thread. Linux lists that child under the creating
    # task, not necessarily under the process's main thread.
    children = {
        child
        for task in pathlib.Path(f"/proc/{process_id}/task").iterdir()
        for child in (task / "children").read_text().split()
    }
    targets = [
        int(child) for child in children
        if executable_name.encode() in pathlib.Path(f"/proc/{child}/cmdline").read_bytes()
    ]
    assert len(targets) == 1, "test must identify exactly one converter belonging to its own service"
    os.kill(targets[0], signal.SIGKILL)
    # A sent SIGKILL is not yet an observed exit. The next key should exercise
    # process restart, rather than race a write into a still-closing pipe.
    status_path = pathlib.Path(f"/proc/{targets[0]}/stat")
    exit_deadline = time.monotonic() + PROCESS_EXIT_WAIT_SECONDS
    while True:
        try:
            state = status_path.read_text().rpartition(")")[2].split()[0]
        except FileNotFoundError:
            return
        if state == "Z":
            return
        assert time.monotonic() < exit_deadline, "the fixture converter did not exit after SIGKILL"
        time.sleep(PROCESS_EXIT_POLL_SECONDS)
