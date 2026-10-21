#!/usr/bin/python3
"""Record synthetic fixture IPC while forwarding every request to real Core."""
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time


# Keep teardown bounded if a deliberately stopped child does not exit.
CHILD_EXIT_SECONDS = 5


def main():
    directory = Path(os.environ["AZOOKEY_NATIVE_ARTIFACTS"]) / "workers"
    directory.mkdir(parents=True, exist_ok=True)
    role = os.environ["AZOOKEY_BRIDGE_ROLE"]
    assert role in ("reading", "candidate")
    executable = Path(os.environ["AZOOKEY_REAL_BRIDGE"])
    with (directory / f"{role}-{os.getpid()}.stderr.log").open("w") as error_stream:
        child = subprocess.Popen([str(executable)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=error_stream, text=True)
        metadata = {
            "role": role, "wrapperPID": os.getpid(), "pid": child.pid,
            "parentPID": os.getppid(), "executable": str(executable),
            "binarySha256": hashlib.sha256(executable.read_bytes()).hexdigest(),
            "startedMonotonic": time.monotonic(),
        }
        (directory / f"{role}-{os.getpid()}.json").write_text(json.dumps(metadata) + "\n")

        def stop(_signum, _frame):
            raise SystemExit(0)

        signal.signal(signal.SIGTERM, stop)
        signal.signal(signal.SIGINT, stop)
        try:
            with (directory / f"{role}-{os.getpid()}.jsonl").open("w", buffering=1) as trace:
                for sequence, line in enumerate(sys.stdin, start=1):
                    request = json.loads(line)
                    record = {"role": role, "wrapperPID": os.getpid(), "pid": child.pid,
                              "sequence": sequence, "operation": request["operation"], "request": request}
                    trace.write(json.dumps({**record, "phase": "request", "monotonic": time.monotonic()},
                                           ensure_ascii=False) + "\n")
                    child.stdin.write(line)
                    child.stdin.flush()
                    response = child.stdout.readline()
                    if not response:
                        trace.write(json.dumps({**record, "phase": "closed", "monotonic": time.monotonic()}) + "\n")
                        return
                    trace.write(json.dumps({**record, "phase": "response", "monotonic": time.monotonic(),
                                            "response": json.loads(response)}, ensure_ascii=False) + "\n")
                    print(response, end="", flush=True)
        finally:
            child.stdin.close()
            if child.poll() is None:
                child.send_signal(signal.SIGCONT)
                child.terminate()
            try:
                child.wait(timeout=CHILD_EXIT_SECONDS)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
            child.stdout.close()


if __name__ == "__main__":
    main()
