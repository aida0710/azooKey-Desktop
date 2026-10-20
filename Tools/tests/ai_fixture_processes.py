"""Stop only installed azooKey processes, and observe their actual exit."""
import os
import pathlib
import selectors
import signal
import time


# Stopping an already quiescent test IME must not wait for the AI I/O deadline.
EXIT_TIMEOUT_SECONDS = 5


def installed_processes(installed_root):
    entrypoint = os.fsencode(installed_root / "ibus-azookey-tree.py")
    bridge = os.fsencode(installed_root / "libexec/azookey-desktop-bridge")
    processes = {}
    for directory in pathlib.Path("/proc").iterdir():
        if not directory.name.isdecimal():
            continue
        try:
            if directory.stat().st_uid != os.getuid():
                continue
            command = (directory / "cmdline").read_bytes().split(b"\0")
            if command[0] == bridge:
                processes[int(directory.name)] = "bridge"
            elif len(command) > 1 and command[1] == entrypoint:
                if command[2:3] != [b"--ibus"]:
                    raise RuntimeError("Close the installed settings window before restoring")
                processes[int(directory.name)] = "engine"
        except (FileNotFoundError, ProcessLookupError):
            continue
    return processes


def require_stopped(installed_root):
    if installed_processes(installed_root):
        raise RuntimeError("An installed azooKey process is still running; no restore may begin")


def stop_installed_processes(installed_root):
    observed = installed_processes(installed_root)
    with selectors.DefaultSelector() as selector:
        descriptors = []
        try:
            for pid, role in observed.items():
                try:
                    descriptor = os.pidfd_open(pid)
                except ProcessLookupError:
                    continue
                descriptors.append(descriptor)
                # Recheck after opening a stable process reference. A recycled
                # PID must never become an unrelated process to terminate.
                if installed_processes(installed_root).get(pid) != role:
                    raise RuntimeError("The installed process identity changed before stopping")
                selector.register(descriptor, selectors.EVENT_READ)
            for descriptor in descriptors:
                try:
                    signal.pidfd_send_signal(descriptor, signal.SIGTERM)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + EXIT_TIMEOUT_SECONDS
            while selector.get_map():
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("The installed IME did not exit; preferences were not restored")
                for key, _events in selector.select(remaining):
                    selector.unregister(key.fd)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
    require_stopped(installed_root)
    return observed
