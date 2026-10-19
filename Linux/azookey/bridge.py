import json
import os
import pathlib
import subprocess


class Bridge:
    """Private stdio connection; never sends typed text to a log or a socket."""

    def __init__(self, executable=None):
        executable = executable or os.environ.get("AZOOKEY_BRIDGE")
        if not executable:
            executable = str(pathlib.Path(__file__).resolve().parents[1] / "libexec/azookey-desktop-bridge")
        self.process = subprocess.Popen([executable], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.DEVNULL, text=True, bufsize=1)

    def request(self, operation, **payload):
        if self.process.poll() is not None:
            raise RuntimeError("azooKey conversion process stopped")
        self.process.stdin.write(json.dumps({"operation": operation, **payload}, ensure_ascii=False) + "\n")
        self.process.stdin.flush()
        response = self.process.stdout.readline()
        if not response:
            raise RuntimeError("azooKey conversion process closed its output")
        return json.loads(response)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                self.process.wait(timeout=5)
