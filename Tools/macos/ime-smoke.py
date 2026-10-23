#!/usr/bin/env python3
"""Install a released IME, type physical keys in TextEdit and retain failure evidence.

Example on a disposable Apple Silicon Mac:
  python3 Tools/macos/ime-smoke.py --tag tree-v0.2.0 --backend cpu --output build/ime-smoke

Exit 0 means the ASCII control and Japanese conversion both worked with no crash.
A blocked permission, registration failure or missing text is a failed test, with
its narrower diagnosis in result.json. Never run against an existing installation.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import re
import sys
import time

from smoke_evidence import Evidence

REPOSITORY = "aida0710/azooKey-Desktop"
JAPANESE_SOURCE = "dev.ensan.inputmethod.azooKeyMac.Japanese"
# Registration and app startup are asynchronous; poll their state up to a deadline.
STATE_WAIT_SECONDS = 20
POLL_INTERVAL_SECONDS = 0.5
# Network transfer and first Swift compilation can be slow on a fresh runner.
RELEASE_DOWNLOAD_TIMEOUT_SECONDS = 120
HELPER_BUILD_TIMEOUT_SECONDS = 120
# Direct launch is diagnostic only; a healthy IME normally stays in its main loop.
DIRECT_LAUNCH_OBSERVATION_SECONDS = 10
DEBUGGER_TIMEOUT_SECONDS = 30


def require_success(completed, description):
    if completed.returncode:
        raise RuntimeError(f"{description}: exit {completed.returncode}; see command stdout/stderr")
    return completed


def read_document(evidence, name):
    completed = evidence.run(name, [evidence.directory / "helpers/TextEditDocument", "read"])
    return json.loads(completed.stdout)["text"] if completed.returncode == 0 else None


def wait_for_text(evidence, name, predicate):
    deadline = time.monotonic() + STATE_WAIT_SECONDS
    attempt = 0
    while True:
        text = read_document(evidence, f"{name}-{attempt}")
        if (text is not None and predicate(text)) or time.monotonic() >= deadline:
            return text
        time.sleep(POLL_INTERVAL_SECONDS)
        attempt += 1


def install_release(evidence, arguments):
    version = arguments.tag.removeprefix("tree-v")
    suffix = "-cpu" if arguments.backend == "cpu" else ""
    asset = f"azookey-tree-{version}-arm64{suffix}.zip"
    downloads = evidence.directory / "downloads"
    downloads.mkdir()
    require_success(evidence.run("release-download", ["gh", "release", "download", arguments.tag,
                    "--repo", REPOSITORY, "--pattern", asset, "--pattern", asset + ".sha256",
                    "--dir", str(downloads)], timeout=RELEASE_DOWNLOAD_TIMEOUT_SECONDS), "Release download")
    # Validate against the published checksum without depending on its relative path.
    expected = (downloads / (asset + ".sha256")).read_text().split()[0]
    actual = hashlib.sha256((downloads / asset).read_bytes()).hexdigest()
    evidence.write_json("release.json", {"tag": arguments.tag, "backend": arguments.backend,
                                        "asset": asset, "expectedSHA256": expected, "actualSHA256": actual})
    if expected != actual:
        raise RuntimeError("Release checksum mismatch")
    input_methods = Path.home() / "Library/Input Methods"
    app = input_methods / "azooKeyMac.app"
    if app.exists():
        raise RuntimeError(f"Refusing to overwrite an existing installation: {app}")
    input_methods.mkdir(parents=True, exist_ok=True)
    require_success(evidence.run("install", ["ditto", "-x", "-k", str(downloads / asset), str(input_methods)]),
                    "Release extraction")
    # Do not upload another copy of a public 120 MB release with every test.
    for path in downloads.iterdir():
        path.unlink()
    downloads.rmdir()
    evidence.run("codesign-verify", ["codesign", "--verify", "--deep", "--strict", str(app)])
    evidence.run("codesign-details", ["codesign", "-d", "--entitlements", ":-", str(app)])
    evidence.run("bundle-files", ["find", str(app), "-type", "f"])
    evidence.run("linked-libraries", ["otool", "-L", str(app / "Contents/MacOS/azooKeyMac")])
    with (app / "Contents/Info.plist").open("rb") as source:
        evidence.write_json("Info.plist.json", plistlib.load(source))
    return app


def compile_helpers(evidence):
    executables = evidence.directory / "helpers"
    executables.mkdir()
    for name in ["InputSource", "SendKeys", "TextEditDocument", "InputSourcePermission"]:
        require_success(evidence.run("compile-" + name, ["xcrun", "swiftc", "-swift-version", "5",
                        str(Path(__file__).parent / (name + ".swift")),
                        str(Path(__file__).parent / "SmokeOutput.swift"), "-o", str(executables / name)],
                        timeout=HELPER_BUILD_TIMEOUT_SECONDS), "Compile " + name)
    return executables / "InputSource", executables / "SendKeys"


def register_source(evidence, input_source, app):
    require_success(evidence.run("register", [input_source, "register", app]), "TISRegisterInputSource")
    evidence.run("input-source-permission", [evidence.directory / "helpers/InputSourcePermission"])
    evidence.screenshot("screen-registration")
    deadline = time.monotonic() + STATE_WAIT_SECONDS
    attempt = 0
    while True:
        listing = evidence.run(f"sources-{attempt}", [input_source, "list"])
        if listing.returncode == 0 and any(source["id"] == JAPANESE_SOURCE for source in json.loads(listing.stdout)):
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("TIS registration succeeded but the Japanese input source did not appear")
        time.sleep(POLL_INTERVAL_SECONDS)
        attempt += 1


def exercise_input(evidence, input_source, send_keys, outcome):
    permissions = evidence.run("permissions", [send_keys, "permissions"])
    outcome["permissions"] = json.loads(require_success(permissions, "Read permissions").stdout)
    document_path = evidence.directory / "TextEdit-document.txt"
    document_path.write_text("")
    require_success(evidence.run("textedit-open", ["open", "-a", "TextEdit", str(document_path)]), "Open TextEdit")
    ready_text = wait_for_text(evidence, "textedit-ready", lambda text: text == "")
    if ready_text != "":
        raise RuntimeError("TextEdit's focused text area is unavailable; see Accessibility diagnostics")
    require_success(evidence.run("select-ascii", [input_source, "ascii"]), "Select ASCII control")
    posted = evidence.run("type-ascii", [send_keys, "nihongo"])
    outcome["asciiText"] = wait_for_text(evidence, "ascii-text", lambda text: text == "nihongo")
    outcome["asciiControlPassed"] = posted.returncode == 0 and outcome["asciiText"] == "nihongo"
    evidence.screenshot("screen-ascii")
    require_success(evidence.run("textedit-clear", [evidence.directory / "helpers/TextEditDocument", "clear"]),
                    "Clear control text")
    if wait_for_text(evidence, "empty-test-document", lambda text: text == "") != "":
        raise RuntimeError("The test document is not empty")
    selected = evidence.run("select-japanese", [input_source, "select", JAPANESE_SOURCE])
    outcome["japaneseSourceSelected"] = selected.returncode == 0
    # Even with denied event permissions, selecting an IME can launch it and crash.
    evidence.run("process-after-select", ["pgrep", "-lx", "azooKeyMac"])
    typed = evidence.run("type-japanese", [send_keys, "nihongo"])
    outcome["keyPostingSucceeded"] = typed.returncode == 0
    outcome["preeditText"] = wait_for_text(evidence, "preedit-text", bool)
    evidence.screenshot("screen-preedit")
    converted = evidence.run("convert", [send_keys, "space"])
    outcome["convertedText"] = wait_for_text(evidence, "converted-text", lambda text: "日本語" in text)
    evidence.screenshot("screen-candidates")
    confirmed = evidence.run("confirm", [send_keys, "return"])
    outcome["conversionKeysPosted"] = converted.returncode == 0 and confirmed.returncode == 0
    outcome["documentText"] = wait_for_text(evidence, "confirmed-text", lambda text: "日本語" in text)
    (evidence.directory / "TextEdit.txt").write_text(outcome["documentText"] or "")
    current = evidence.run("source-after-typing", [input_source, "current"])
    outcome["japaneseSourceRetained"] = current.returncode == 0 and json.loads(current.stdout)["id"] == JAPANESE_SOURCE
    saved = evidence.run("save-document", [send_keys, "save"])
    deadline = time.monotonic() + STATE_WAIT_SECONDS
    while time.monotonic() < deadline and document_path.read_text() != outcome["documentText"]:
        time.sleep(POLL_INTERVAL_SECONDS)
    outcome["savedDocumentText"] = document_path.read_text()
    outcome["documentSaved"] = saved.returncode == 0 and outcome["savedDocumentText"] == outcome["documentText"]
    running = evidence.run("process-after-input", ["pgrep", "-x", "azooKeyMac"])
    outcome["processAliveAfterInput"] = running.returncode == 0
    outcome["japaneseConversionPassed"] = (outcome["documentText"] is not None and outcome["documentText"].strip() == "日本語"
        and outcome["conversionKeysPosted"] and outcome["japaneseSourceRetained"] and outcome["documentSaved"])


def launch_fallback(evidence, app, outcome):
    # This is separate from the natural TIS launch so it cannot turn a failed
    # registration/input test into a pass. Preserve direct-launch stderr as well.
    outcome["directLaunchAttempted"] = True
    evidence.run("fallback-open", ["open", "-a", str(app)])
    evidence.run("fallback-executable", [str(app / "Contents/MacOS/azooKeyMac")], timeout=DIRECT_LAUNCH_OBSERVATION_SECONDS)
    # A crash stops LLDB and prints a symbolized stack; a healthy main loop times out.
    evidence.run("fallback-lldb", ["xcrun", "lldb", "--batch",
                 "-o", "settings set target.disable-aslr false", "-o", "run",
                 "-k", "thread backtrace all", "--", str(app / "Contents/MacOS/azooKeyMac")], timeout=DEBUGGER_TIMEOUT_SECONDS)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--backend", choices=["cpu", "metal"], default="cpu")
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    if not re.fullmatch(r"tree-v\d+\.\d+\.\d+", arguments.tag):
        parser.error("tag must be tree-vMAJOR.MINOR.PATCH")
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        parser.error("this test requires a disposable Apple Silicon Mac")
    evidence = Evidence(arguments.output)
    outcome = {"tag": arguments.tag, "backend": arguments.backend, "status": "incomplete"}
    app = None
    input_source = None
    original_source = None
    try:
        evidence.start_observation()
        evidence.run("macos-version", ["sw_vers"])
        evidence.run("console-user", ["stat", "-f", "%Su", "/dev/console"])
        evidence.run("hardware", ["system_profiler", "SPHardwareDataType", "SPDisplaysDataType"])
        input_source, send_keys = compile_helpers(evidence)
        original = evidence.run("source-original", [input_source, "current"])
        if original.returncode == 0:
            original_source = json.loads(original.stdout)["id"]
        app = install_release(evidence, arguments)
        register_source(evidence, input_source, app)
        exercise_input(evidence, input_source, send_keys, outcome)
    except Exception as error:
        outcome["error"] = str(error)
        print(f"Smoke test error: {error}", flush=True)
    finally:
        # Save natural activation evidence before any explicit launch/debugger.
        if (evidence.directory / "helpers/InputSourcePermission").exists():
            evidence.run("input-source-permission-final", [evidence.directory / "helpers/InputSourcePermission"])
        outcome["processObservedDuringInput"] = evidence.observed_processes
        outcome["crashesBeforeFallback"] = [str(path) for path in evidence.crash_reports()]
        try:
            running = evidence.run("process-before-fallback", ["pgrep", "-x", "azooKeyMac"])
            if app and running.returncode != 0 and not outcome.get("japaneseConversionPassed"):
                launch_fallback(evidence, app, outcome)
            reports = evidence.collect()
            outcome["crashReports"] = [str(path) for path in reports]
            outcome["processObserved"] = evidence.observed_processes
            if outcome.get("error"):
                outcome["status"] = "setup-failed"
            elif reports:
                outcome["status"] = "crashed"
            elif not outcome.get("asciiControlPassed"):
                outcome["status"] = "input-unverified"
            elif not outcome.get("japaneseSourceSelected"):
                outcome["status"] = "selection-failed"
            elif not outcome.get("processAliveAfterInput"):
                outcome["status"] = "process-exited"
            elif not outcome.get("japaneseConversionPassed"):
                outcome["status"] = "conversion-failed"
            else:
                outcome["status"] = "passed"
        except Exception as error:
            outcome["collectionError"] = str(error)
        if input_source and original_source:
            evidence.run("restore-source", [input_source, "select", original_source])
        evidence.write_json("result.json", outcome)
        summary = json.dumps(outcome, ensure_ascii=False, indent=2)
        print(summary)
        if os.environ.get("GITHUB_STEP_SUMMARY"):
            with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as destination:
                destination.write(f"### {arguments.tag} / {arguments.backend}\n\n```json\n{summary}\n```\n")
    return 0 if outcome["status"] == "passed" else 1


if __name__ == "__main__":
    sys.exit(main())
