import json
import os
import pathlib
import subprocess
import select
import time


class Bridge:
    """Private stdio connection; never sends typed text to a log or a socket."""
    _shared = None
    _owners = 0

    @classmethod
    def acquire(cls):
        # IBus callbacks run on the same main loop. One converter owns learning
        # and model state while Core keeps compositions separate by context ID.
        if cls._shared is None:
            cls._shared = cls()
        cls._owners += 1
        return cls._shared

    @classmethod
    def release(cls):
        cls._owners -= 1
        if cls._owners == 0 and cls._shared is not None:
            cls._shared.close()
            cls._shared = None

    @classmethod
    def reset_shared_learning(cls):
        if cls._shared is None:
            return False
        return not cls._shared.request("reset-learning").get("error")

    def __init__(self, executable=None, timeout=30, environment=None):
        self.timeout = timeout
        self.buffer = b""
        executable = executable or os.environ.get("AZOOKEY_BRIDGE")
        if not executable:
            executable = str(pathlib.Path(__file__).resolve().parents[1] / "libexec/azookey-desktop-bridge")
        self.executable = executable
        self.environment = environment
        self.restarts = 0
        self._start()

    def _start(self):
        self.buffer = b""
        self.process = subprocess.Popen([self.executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, bufsize=0, env=self.environment)

    def ensure_running(self):
        if self.process.poll() is not None:
            self.close()
            self._start()
            self.restarts += 1

    def invalidate(self):
        if self.process.poll() is None:
            self.process.kill()
            self.process.wait(timeout=5)

    def request(self, operation, **payload):
        self.ensure_running()
        self.process.stdin.write((json.dumps({"operation": operation, **payload}, ensure_ascii=False) + "\n").encode())
        self.process.stdin.flush()
        deadline = time.monotonic() + self.timeout
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
        return json.loads(response)

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
