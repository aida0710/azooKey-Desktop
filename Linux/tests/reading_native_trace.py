"""Inspect and suspend only real Core children belonging to the native fixture."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import time

from ibus_native_field import wait_for


# /proc/PID/stat field 22 is offset 19 after the parenthesized command name.
START_TICKS_OFFSET = 19


class CoreTrace:
    def __init__(self, directory):
        self.directory = directory

    def records(self, *, role=None, operation=None, phase=None, since=0):
        records = []
        for path in (self.directory / "workers").glob("*.jsonl"):
            # A wrapper may currently be writing the final line.
            for line in path.read_text().splitlines(keepends=True):
                if not line.endswith("\n"):
                    continue
                value = json.loads(line)
                if (value["monotonic"] >= since and (role is None or value["role"] == role)
                        and (operation is None or value["operation"] == operation)
                        and (phase is None or value["phase"] == phase)):
                    records.append(value)
        return sorted(records, key=lambda value: value["monotonic"])

    def worker(self, role, context):
        matches = []
        for record in self.records(role=role, phase="response"):
            request = record["request"]
            authority = (request.get("reference") if role == "reading"
                         else request.get("request", {}).get("authority"))
            if authority and authority.get("context") == context:
                matches.append(record)
        assert matches, (role, context)
        selected = matches[-1]
        metadata = json.loads((self.directory / "workers" / f"{role}-{selected['wrapperPID']}.json").read_text())
        process = Path("/proc") / str(metadata["pid"])
        assert process.joinpath("exe").resolve() == Path(metadata["executable"]).resolve(), metadata
        return metadata

    @contextmanager
    def stopped(self, role, context):
        worker = self.worker(role, context)
        pid = worker["pid"]
        process = Path("/proc") / str(pid)
        start_ticks = process.joinpath("stat").read_text().rpartition(")")[2].split()[START_TICKS_OFFSET]
        worker["processStartTicks"] = start_ticks
        os.kill(pid, signal.SIGSTOP)
        try:
            def stopped():
                state = (Path("/proc") / str(pid) / "status").read_text()
                return any(line.startswith("State:\tT") for line in state.splitlines())
            wait_for(stopped, "the owned Core child did not stop")
            worker["stoppedMonotonic"] = time.monotonic()
            yield worker
        finally:
            try:
                current_ticks = process.joinpath("stat").read_text().rpartition(")")[2].split()[START_TICKS_OFFSET]
                assert current_ticks == start_ticks, "the owned process identity changed"
                os.kill(pid, signal.SIGCONT)
                worker["resumedMonotonic"] = time.monotonic()
                worker["resumeDisposition"] = "resumed-same-process"
            except (FileNotFoundError, ProcessLookupError):
                # Destroying the old IBus Engine legitimately closes its worker.
                # Preserve the trial's result instead of masking it at cleanup.
                worker["exitObservedMonotonic"] = time.monotonic()
                worker["resumeDisposition"] = "process-retired-before-resume"
            (self.directory / f"{role}-stop-{worker['wrapperPID']}.json").write_text(
                json.dumps(worker, indent=2) + "\n")
