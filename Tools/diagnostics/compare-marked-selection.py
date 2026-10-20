"""Compare the same input regressions before and after the Mac adapter fix."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


BEFORE_OUTCOMES = {
    "testAnEmptyRefreshAfterCommitKeepsTheNextInputBeforeTheSuffix": "failed",
    "testPreviewUsesTheUTF16EndOfMarkedTextBeforeTheSuffix": "failed",
    "testAnExplicitCompositionCaretRemainsInsideMarkedText": "passed",
    "testClearingAPreviewKeepsTheNextInputBeforeTheSuffix": "failed",
}
AFTER_COUNTS = {
    "MarkedTextSelectionTests": 4,
    "DocumentTextInputTests": 7,
    "ReconversionCommitLifetimeTests": 9,
}
SOURCE_PATHS = (
    "azooKeyMac/InputController/azooKeyMacInputController.swift",
    "azooKeyMacTests/DocumentTextInput.swift",
    "azooKeyMacTests/DocumentTextInputTests.swift",
    "azooKeyMacTests/MarkedTextSelectionTests.swift",
    "azooKeyMacTests/ReconversionCommitLifetimeTests.swift",
    "azooKeyMacTests/AISuggestionInputTests.swift",
)
CASE_PATTERN = re.compile(r"Test Case '-\[\S+\.(\w+) (\w+)\]' (passed|failed)")


def observe_revision(revision, *, label, test_filter, directory):
    subprocess.run(["git", "checkout", "--detach", revision], check=True)
    actual_revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True
    ).strip()
    if actual_revision != revision:
        raise RuntimeError(f"Unexpected revision: {actual_revision}")
    subprocess.run(["git", "diff", "--exit-code"], check=True)
    source_hashes = {
        name: hashlib.sha256(Path(name).read_bytes()).hexdigest()
        for name in SOURCE_PATHS
    }
    log_path = directory / f"{label}.log"
    with log_path.open("w") as output:
        completed = subprocess.run(
            ["bash", "Tools/test-macos-app.sh", "test", "--jobs", "4",
             "--filter", test_filter],
            stdout=output, stderr=subprocess.STDOUT,
        )
    outcomes = [
        {"suite": suite, "test": test, "outcome": outcome}
        for suite, test, outcome in CASE_PATTERN.findall(log_path.read_text())
    ]
    observation = {
        "source": actual_revision,
        "sourceSHA256": source_hashes,
        "exitCode": completed.returncode,
        "testFilter": test_filter,
        "completedCases": outcomes,
        "logSHA256": hashlib.sha256(log_path.read_bytes()).hexdigest(),
    }
    (directory / f"{label}.json").write_text(
        json.dumps(observation, ensure_ascii=False, indent=2) + "\n"
    )
    print(json.dumps({"stage": label, **observation}), flush=True)
    return observation


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--before", required=True)
    parser.add_argument("--after", required=True)
    arguments = parser.parse_args()
    for revision in (arguments.before, arguments.after):
        if not re.fullmatch(r"[0-9a-f]{40}", revision):
            parser.error("Revisions must be full commit IDs")
    directory = Path("build/marked-selection-comparison").resolve()
    directory.mkdir(parents=True, exist_ok=True)
    before = observe_revision(
        arguments.before, label="before",
        test_filter="MarkedTextSelectionTests", directory=directory,
    )
    # Complete the positive observation even if the negative control is unexpected.
    after = observe_revision(
        arguments.after, label="after",
        test_filter="|".join(AFTER_COUNTS), directory=directory,
    )
    before_cases = before["completedCases"]
    negative_control = (
        before["exitCode"] != 0
        and len(before_cases) == len(BEFORE_OUTCOMES)
        and {case["test"]: case["outcome"] for case in before_cases}
        == BEFORE_OUTCOMES
    )
    after_cases = after["completedCases"]
    counts = {
        suite: sum(case["suite"] == suite for case in after_cases)
        for suite in AFTER_COUNTS
    }
    positive_control = (
        after["exitCode"] == 0
        and counts == AFTER_COUNTS
        and len(after_cases) == sum(AFTER_COUNTS.values())
        and all(case["outcome"] == "passed" for case in after_cases)
    )
    unchanged_tests = all(
        before["sourceSHA256"][name] == after["sourceSHA256"][name]
        for name in SOURCE_PATHS if name.startswith("azooKeyMacTests/")
    )
    summary = {
        "negativeControlMatched": negative_control,
        "positiveControlPassed": positive_control,
        "sameTestSources": unchanged_tests,
        "before": before, "after": after,
        "scope": "AppKit input-controller and native NSTextView tests; not real-application IME acceptance.",
    }
    (directory / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n"
    )
    raise SystemExit(0 if negative_control and positive_control and unchanged_tests else 1)


if __name__ == "__main__":
    main()
