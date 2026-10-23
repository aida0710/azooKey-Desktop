"""Bounded command execution and macOS evidence collection for the IME smoke test."""

import datetime
import json
from pathlib import Path
import shutil
import subprocess
import threading
import time

# Diagnostic commands must not consume the entire workflow timeout when an IME hangs.
COMMAND_TIMEOUT_SECONDS = 45
# Sample frequently enough to see restarts; crash reports cover shorter lifetimes.
PROCESS_SAMPLE_INTERVAL_SECONDS = 0.5
# ReportCrash writes asynchronously after the process exits.
CRASH_REPORT_WAIT_SECONDS = 15


class Evidence:
    def __init__(self, directory):
        self.directory = Path(directory).resolve()
        self.directory.mkdir(parents=True, exist_ok=True)
        self.started_at = datetime.datetime.now().astimezone()
        self.commands = []
        self.observed_processes = False
        self.stop_sampling = threading.Event()
        self.sampling_thread = None
        self.log_process = None
        self.log_file = None

    def write_json(self, name, value):
        (self.directory / name).write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")

    def run(self, name, arguments, *, timeout=COMMAND_TIMEOUT_SECONDS):
        started = time.monotonic()
        with (self.directory / f"{name}.stdout.txt").open("w") as stdout, \
                (self.directory / f"{name}.stderr.txt").open("w") as stderr:
            process = subprocess.Popen(arguments, stdout=stdout, stderr=stderr, start_new_session=True)
            timed_out = False
            try:
                process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                # macOS can deny killpg for an AppleEvent process group. Kill
                # only the command we created and preserve the timeout evidence.
                process.kill()
                process.wait()
        record = {
            "name": name, "arguments": [str(argument) for argument in arguments],
            "returncode": process.returncode, "timedOut": timed_out,
            "elapsedSeconds": round(time.monotonic() - started, 3),
        }
        self.commands.append(record)
        self.write_json("commands.json", self.commands)
        print(f"{name}: exit={process.returncode}, timeout={timed_out}", flush=True)
        return subprocess.CompletedProcess(arguments, process.returncode,
                                           (self.directory / f"{name}.stdout.txt").read_text(),
                                           (self.directory / f"{name}.stderr.txt").read_text())

    def start_observation(self):
        self.log_file = (self.directory / "azooKeyMac-live.log").open("w")
        self.log_process = subprocess.Popen(
            ["/usr/bin/log", "stream", "--style", "compact", "--level", "debug",
             "--predicate", 'process == "azooKeyMac"'],
            stdout=self.log_file, stderr=subprocess.STDOUT,
        )
        self.sampling_thread = threading.Thread(target=self.sample_processes, daemon=True)
        self.sampling_thread.start()

    def sample_processes(self):
        with (self.directory / "process-timeline.jsonl").open("w") as timeline:
            while not self.stop_sampling.is_set():
                try:
                    processes = subprocess.run(["pgrep", "-fl", "azooKeyMac.app/Contents/MacOS/azooKeyMac"],
                                               capture_output=True, text=True, timeout=5)
                    snapshot = {"time": datetime.datetime.now().astimezone().isoformat(),
                                "returncode": processes.returncode, "processes": processes.stdout.strip()}
                    self.observed_processes |= processes.returncode == 0
                except subprocess.TimeoutExpired:
                    snapshot = {"error": "pgrep timed out"}
                timeline.write(json.dumps(snapshot) + "\n")
                timeline.flush()
                self.stop_sampling.wait(PROCESS_SAMPLE_INTERVAL_SECONDS)

    def screenshot(self, name):
        return self.run(name, ["screencapture", "-x", str(self.directory / f"{name}.png")])

    def crash_reports(self):
        reports = []
        for directory in [Path.home() / "Library/Logs/DiagnosticReports", Path("/Library/Logs/DiagnosticReports")]:
            if not directory.exists():
                continue
            for path in directory.rglob("*"):
                if (path.is_file() and "azookey" in path.name.lower()
                        and path.stat().st_mtime >= self.started_at.timestamp()):
                    reports.append(path)
        return reports

    def collect(self):
        deadline = time.monotonic() + CRASH_REPORT_WAIT_SECONDS
        while time.monotonic() < deadline and not self.crash_reports():
            time.sleep(PROCESS_SAMPLE_INTERVAL_SECONDS)
        self.stop_sampling.set()
        if self.sampling_thread:
            self.sampling_thread.join(timeout=COMMAND_TIMEOUT_SECONDS)
        if self.log_process:
            self.log_process.terminate()
            try:
                self.log_process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.log_process.kill()
                self.log_process.wait()
            self.log_file.close()
        self.run("process-final", ["pgrep", "-fl", "azooKeyMac"])
        self.run("process-table", ["ps", "-axo", "pid,ppid,stat,lstart,command"])
        start = self.started_at.strftime("%Y-%m-%d %H:%M:%S")
        self.run("azooKeyMac-log-show", ["/usr/bin/log", "show", "--start", start,
                                       "--style", "compact", "--info", "--debug",
                                       "--predicate", 'process == "azooKeyMac"'])
        self.run("inputmethod-system-log", ["/usr/bin/log", "show", "--start", start,
                 "--style", "compact", "--info", "--debug", "--predicate",
                 'process == "tccd" OR process == "TextEdit" OR '
                 '(eventMessage CONTAINS[c] "azooKey") OR subsystem CONTAINS[c] "InputMethod"'])
        self.run("input-source-preferences", ["defaults", "read", "com.apple.HIToolbox"])
        self.screenshot("screen-final")
        crash_directory = self.directory / "DiagnosticReports"
        crash_directory.mkdir(exist_ok=True)
        reports = self.crash_reports()
        for index, path in enumerate(reports):
            shutil.copy2(path, crash_directory / f"{index}-{path.name}")
        self.write_json("crash-reports.json", [str(path) for path in reports])
        return reports
