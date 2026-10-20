#!/usr/bin/env python3
"""Run public IMK initializer cases without building azooKey or changing its tests."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import uuid


ROOT = Path(__file__).resolve().parents[3]
SOURCES = Path(__file__).resolve().parent
OUTPUT = ROOT / "build/imk-client-diagnosis"
CASE_TIMEOUT_SECONDS = 20
BUILD_TIMEOUT_SECONDS = 90
SERVER_READY_TIMEOUT_SECONDS = 5
PROCESS_SHUTDOWN_TIMEOUT_SECONDS = 5


def execute(name, command, *, timeout):
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=timeout, cwd=ROOT)
        status = {"exitCode": process.returncode, "timedOut": False}
        stdout, stderr = process.stdout, process.stderr
    except subprocess.TimeoutExpired as error:
        status = {"exitCode": None, "timedOut": True}
        stdout = (error.stdout or b"").decode() if isinstance(error.stdout, bytes) else error.stdout or ""
        stderr = (error.stderr or b"").decode() if isinstance(error.stderr, bytes) else error.stderr or ""
    (OUTPUT / f"{name}.stdout").write_text(stdout)
    (OUTPUT / f"{name}.stderr").write_text(stderr)
    status["command"] = [str(argument) for argument in command]
    status["events"] = []
    for line in stdout.splitlines():
        try:
            status["events"].append(json.loads(line))
        except json.JSONDecodeError:
            pass
    print(json.dumps({"case": name, **status}), flush=True)
    return status


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    fixture_source = ROOT / "azooKeyMacTests/AISuggestionInputTests.swift"
    original = fixture_source.read_text()
    begin = original.index("private final class FakeTextInput: NSObject, IMKTextInput {")
    end = original.index("\n@MainActor\nfinal class AISuggestionInputTests:", begin)
    actual_fixture = original[begin:end]
    combined = "import Cocoa\nimport InputMethodKit\n\n" + actual_fixture + "\n" + (SOURCES / "ClientFactory.swift").read_text()
    fixture_copy = OUTPUT / "ClientFixture.swift"
    fixture_copy.write_text(combined)
    summary = {
        "sourceCommit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(),
        "fixtureSource": str(fixture_source.relative_to(ROOT)),
        "fixtureFileSHA256": hashlib.sha256(fixture_source.read_bytes()).hexdigest(),
        "extractedDeclarationSHA256": hashlib.sha256(actual_fixture.encode()).hexdigest(),
        "cases": {},
    }
    summary["environment"] = execute("environment", ["xcrun", "swiftc", "--version"], timeout=20)
    summary["os"] = execute("os", ["sw_vers"], timeout=20)
    swift = [
        "xcrun", "swiftc", "-swift-version", "5", "-emit-library", "-module-name", "IMKClientFixture",
        "-emit-objc-header", "-emit-objc-header-path", str(OUTPUT / "IMKClientFixture.h"),
        str(fixture_copy), "-o", str(OUTPUT / "libIMKClientFixture.dylib"),
    ]
    summary["swiftBuild"] = execute("swift-build", swift, timeout=BUILD_TIMEOUT_SECONDS)
    if summary["swiftBuild"]["exitCode"] != 0:
        (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        return 1
    clang = [
        "xcrun", "clang", "-fobjc-arc", "-fmodules", "-Wno-deprecated-declarations",
        "-I", str(OUTPUT), str(SOURCES / "main.m"), "-framework", "Cocoa",
        "-framework", "InputMethodKit", "-L", str(OUTPUT), "-lIMKClientFixture",
        "-Wl,-rpath,@executable_path",
    ]
    binary = OUTPUT / "imk-client"
    summary["objcBuild"] = execute("objc-build", clang + ["-o", str(binary)], timeout=BUILD_TIMEOUT_SECONDS)
    if summary["objcBuild"]["exitCode"] != 0:
        (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        return 1

    for case in ("direct-client", "nil-client", "nil-client-override"):
        summary["cases"][case] = execute(case, [str(binary), case], timeout=CASE_TIMEOUT_SECONDS)

    # A real peer process prevents same-process connection caching from returning
    # the root object directly instead of a remote NSDistantObject.
    name = "dev.azookey.diagnose.client." + str(uuid.uuid4())
    with (OUTPUT / "proxy-server.stderr").open("w") as server_errors:
        server = subprocess.Popen([str(binary), "serve-client", name], stdout=subprocess.PIPE,
                                  stderr=server_errors, bufsize=0)
        server_events = []
        try:
            selector = selectors.DefaultSelector()
            selector.register(server.stdout, selectors.EVENT_READ)
            # Wait for explicit registration, not a sleep before connecting.
            buffered = b""
            while selector.select(timeout=SERVER_READY_TIMEOUT_SECONDS):
                chunk = os.read(server.stdout.fileno(), 4096)
                if not chunk:
                    break
                buffered += chunk
                while b"\n" in buffered:
                    line, buffered = buffered.split(b"\n", 1)
                    server_events.append(json.loads(line))
                if any("registered" in event for event in server_events):
                    break
            ready = any(event.get("registered") for event in server_events)
            if ready:
                case = "connection-root-proxy"
                summary["cases"][case] = execute(case, [str(binary), case, name], timeout=CASE_TIMEOUT_SECONDS)
            else:
                summary["cases"]["connection-root-proxy"] = {"notRun": "server registration failed"}
            selector.close()
        finally:
            server.terminate()
            try:
                server.wait(timeout=PROCESS_SHUTDOWN_TIMEOUT_SECONDS)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()
            (OUTPUT / "proxy-server.json").write_text(json.dumps(server_events, indent=2) + "\n")

    default_binary = OUTPUT / "imk-default-init"
    summary["defaultBuild"] = execute(
        "default-build", clang + ["-DINCLUDE_DEFAULT_INITIALIZER=1", "-o", str(default_binary)],
        timeout=BUILD_TIMEOUT_SECONDS,
    )
    if summary["defaultBuild"]["exitCode"] == 0:
        summary["cases"]["default-init"] = execute(
            "default-init", [str(default_binary), "default-init"], timeout=CASE_TIMEOUT_SECONDS,
        )
    (OUTPUT / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
    print("Diagnostic outcomes are not production IME or behavior-test acceptance.", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
