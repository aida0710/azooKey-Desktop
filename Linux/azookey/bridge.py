import json
import os
import pathlib
import subprocess
import select
import time


class BridgeProcessChanged(RuntimeError):
    """The original process ended before a request could be written."""


class Bridge:
    """Private stdio connection; never sends typed text to a log or a socket."""
    def __init__(self, executable=None, timeout=30, environment=None):
        self.timeout = timeout
        self.buffer = b""
        executable = executable or os.environ.get("AZOOKEY_BRIDGE")
        if not executable:
            executable = str(pathlib.Path(__file__).resolve().parents[1] / "libexec/azookey-desktop-bridge")
        self.executable = executable
        self.environment = environment
        self.restarts = 0
        self.interrupted = False
        self._start()

    def _start(self):
        if self.interrupted:
            raise RuntimeError("azooKey conversion connection is stopping")
        self.buffer = b""
        self.process = subprocess.Popen([self.executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0, env=self.environment)
        os.set_blocking(self.process.stdin.fileno(), False)
        if self.interrupted:
            self.interrupt()

    def ensure_running(self):
        if self.interrupted:
            raise RuntimeError("azooKey conversion connection is stopping")
        if self.process.poll() is not None:
            self.close()
            self._start()
            self.restarts += 1

    def interrupt(self):
        """Stop service-owned I/O without waiting on the main-loop caller."""
        self.interrupted = True
        try:
            self.process.terminate()
        except ProcessLookupError:
            pass

    def invalidate(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)

    def request(self, operation, *, expected_restarts=None, **payload):
        self.ensure_running()
        if expected_restarts is not None and self.restarts != expected_restarts:
            raise BridgeProcessChanged("azooKey conversion process changed before request")
        deadline = time.monotonic() + self.timeout
        message = memoryview((json.dumps({"operation": operation, **payload}, ensure_ascii=False) + "\n").encode())
        while message:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([], [self.process.stdin], [], remaining)[1]:
                self.invalidate()
                raise RuntimeError("azooKey conversion process timed out")
            try:
                written = os.write(self.process.stdin.fileno(), message)
            except BlockingIOError:
                continue
            message = message[written:]
        while b"\n" not in self.buffer:
            remaining = deadline - time.monotonic()
            if remaining <= 0 or not select.select([self.process.stdout], [], [], remaining)[0]:
                self.invalidate()
                raise RuntimeError("azooKey conversion process timed out")
            chunk = os.read(self.process.stdout.fileno(), 65536)
            if not chunk:
                raise RuntimeError("azooKey conversion process closed its output")
            self.buffer += chunk
        response, self.buffer = self.buffer.split(b"\n", 1)
        snapshot = json.loads(response)
        if not isinstance(snapshot, dict):
            raise ValueError("azooKey conversion process returned an invalid response")
        return snapshot

    def close(self):
        self.process.stdin.close()
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait(timeout=5)
        self.process.stdout.close()
