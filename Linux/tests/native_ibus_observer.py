"""Record the local test IBus traffic without changing engine or widget state."""
from contextlib import contextmanager
import json
import re
import subprocess
import time


MONITOR_START_SECONDS = 5
MONITOR_POLL_SECONDS = .01


def assert_reply_between_delete_and_ack(directory, *, keyval, removed_text, sent_after):
    """Check the original Engine reply, not an eventual synthesized key."""
    observed = (directory / "ibus-events.log").read_text()
    clock = json.loads((directory / "observation-clock.json").read_text())
    sent_wall = sent_after + clock["wallSeconds"] - clock["monotonicSeconds"]
    blocks = re.split(r"(?=^(?:signal|method call|method return|error) time=)", observed, flags=re.M)
    calls = [(index, block) for index, block in enumerate(blocks)
             if "interface=org.freedesktop.IBus.Engine; member=ProcessKeyEvent" in block
             and re.findall(r"uint32 (\d+)", block)[::2] == [str(keyval), "0"]
             and float(re.search(r"time=([0-9.]+)", block)[1]) >= sent_wall]
    assert len(calls) == 1, calls
    call_index, call = calls[0]
    serial = re.search(r" serial=(\d+)", call)[1]
    deletions = [(index, block) for index, block in enumerate(blocks)
                 if index > call_index
                 and "interface=org.freedesktop.IBus.Engine; member=DeleteSurroundingText" in block]
    assert len(deletions) == 1, deletions
    delete_index, deletion = deletions[0]
    engine_sender = re.search(r"sender=(\S+)", deletion)[1]
    replies = [(index, block) for index, block in enumerate(blocks)
               if block.startswith("method return ")
               and f"sender={engine_sender} " in block and f"reply_serial={serial}\n" in block]
    assert len(replies) == 1, replies
    reply_index, reply = replies[0]
    acknowledgements = [(index, block) for index, block in enumerate(blocks)
                        if index > delete_index
                        and "interface=org.freedesktop.IBus.Engine; member=SetSurroundingText" in block
                        and f'string "{removed_text}"' in block
                        and re.findall(r"uint32 (\d+)", block)[-2:] == ["1", "1"]]
    assert acknowledgements, "the real client must acknowledge the one deletion"
    ack_index, acknowledgement = acknowledgements[0]
    assert call_index < delete_index < reply_index < ack_index, (
        call, deletion, reply, acknowledgement,
    )
    assert "boolean true" in reply, reply
    return {"request": call, "deletion": deletion, "reply": reply, "acknowledgement": acknowledgement}


@contextmanager
def observe_ibus(directory):
    address = subprocess.check_output(["ibus", "address"], text=True).strip()
    assert address.startswith("unix:"), "the isolated IBus daemon must be ready"
    path = directory / "ibus-events.log"
    clock = {"wallSeconds": time.time(), "monotonicSeconds": time.monotonic()}
    (directory / "observation-clock.json").write_text(json.dumps(clock) + "\n")
    with path.open("w") as stream:
        monitor = subprocess.Popen([
            "stdbuf", "-oL", "dbus-monitor", "--address", address,
            "interface='org.freedesktop.IBus.Engine'",
            "interface='org.freedesktop.IBus.InputContext'",
            "interface='org.freedesktop.DBus.Properties'",
            "type='method_return'", "type='error'",
        ], stdout=stream, stderr=stream)
        try:
            deadline = time.monotonic() + MONITOR_START_SECONDS
            while not path.stat().st_size:
                assert monitor.poll() is None, "IBus observation process exited before recording"
                assert time.monotonic() < deadline, "IBus observer did not start"
                time.sleep(MONITOR_POLL_SECONDS)
            yield
        finally:
            monitor.terminate()
            monitor.wait(timeout=5)
