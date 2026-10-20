"""Check delayed real-Core reconversion against GTK4 or Qt document edits."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import time

from azookey.reconversion_strings import message
from native_ibus_observer import assert_reply_between_delete_and_ack, observe_ibus
from native_ibus_property import activate_focused_property
from native_toolkit_support import (
    BACKSPACE, CONTROL, ESCAPE, F10, HENKAN, HOME, RETURN, RIGHT, SHIFT,
    NativeKeyboard, heartbeat_summary, loaded_input_modules, wait_for,
)


ORIGINAL_SELECTION = "前ニホンゴ後"
ORIGINAL_READING_SELECTION = "前日本語後"
ROMAN_INPUT = "hashi"
READING_INPUT = "nihongo"
SUBMITTED_READING = "にほんご"
QT_HOME_KEY = 0x01000010
ACTIVATIONS = ("key", "property-enter", "property-edit", "property-escape")
RECONVERSION_OPERATIONS = ("reconvert", "undo-commit", "confirm-reconversion")


def trace_events():
    path = Path(os.environ["AZOOKEY_TEST_RECONVERSION_TRACE"])
    return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []


def inserted_text(events, toolkit):
    if toolkit == "gtk4":
        return [event["text"] for event in events if event["event"] == "insert"]
    return [event["commit"] for event in events
            if event["event"] == "input-method" and event["commit"]]


def assert_delayed_operations(events, operation):
    relevant = [event for event in events if event["operation"] in (operation, "confirm-reconversion")]
    assert [(event["operation"], event["phase"]) for event in relevant] == [
        (operation, "started"), (operation, "replied"),
        ("confirm-reconversion", "started"), ("confirm-reconversion", "replied"),
    ], relevant
    delay = float(os.environ["AZOOKEY_TEST_DELAY"])
    durations = [relevant[index + 1]["monotonic"] - relevant[index]["monotonic"]
                 for index in (0, 2)]
    assert all(duration >= delay for duration in durations), durations
    return durations


def prepare_selection(keyboard, state, process, *, length):
    keyboard.key(HOME, modifiers=(CONTROL,))
    keyboard.key(RIGHT)
    for _ in range(length):
        keyboard.key(RIGHT, modifiers=(SHIFT,))
    return wait_for(state, process, lambda value: value["cursor"] == length + 1 and value["anchor"] == 1)


def prepare_undo(keyboard, state, process):
    keyboard.key(HOME, modifiers=(CONTROL,))
    keyboard.key(RIGHT)
    wait_for(state, process, lambda value: value["cursor"] == value["anchor"] == 1)
    for character in ROMAN_INPUT:
        keyboard.key(ord(character))
    keyboard.key(F10)
    return wait_for(state, process, lambda value: value["text"] == "phashiq"
                    and value["cursor"] == 6 and not value["preedit"])


def assert_completed(observation, toolkit, *, scenario, event_start, trace_start):
    events = observation["events"][event_start:]
    expected_commit = {"selection": "日本語", "undo": ROMAN_INPUT, "reading": SUBMITTED_READING}[scenario]
    assert inserted_text(events, toolkit) == [expected_commit], events
    preedits = [event.get("preedit", event.get("text", "")) for event in events
                if event["event"] in ("preedit", "input-method")]
    assert any(preedits), events
    if scenario == "selection":
        assert expected_commit in preedits, preedits
    operation = "undo-commit" if scenario == "undo" else "reconvert"
    operation_events = trace_events()[trace_start:]
    durations = assert_delayed_operations(operation_events, operation)
    if scenario == "reading":
        reading_events = [event for event in operation_events if event["operation"] == "reconversion-reading"]
        assert [event["phase"] for event in reading_events] == ["started", "replied"] * (len(READING_INPUT) + 1)
        submit_duration = reading_events[-1]["monotonic"] - reading_events[-2]["monotonic"]
        assert submit_duration >= float(os.environ["AZOOKEY_TEST_DELAY"]), reading_events[-2:]
        durations.append(submit_duration)
    if toolkit == "gtk4":
        assert [(event["position"], event["count"]) for event in events if event["event"] == "delete"] == [
            (1, 4 if scenario == "selection" else len(ROMAN_INPUT)),
        ], events
    else:
        # Qt receives native Home through its key handler, after the IME commit.
        homes = [event for event in events
                 if event["event"] == "key-press" and event["key"] == QT_HOME_KEY]
        commits = [event for event in events if event["event"] == "input-method" and event["commit"]]
        assert len(homes) == 1, homes
        assert commits[0]["monotonic"] < homes[0]["monotonic"], events
    return {"operations": operation_events, "operationSeconds": durations, "commits": [expected_commit]}


def type_reading(keyboard, state, process, *, directory):
    bus_log = directory / "ibus-events.log"

    def reading_visible(value, reading):
        return value["text"] == ORIGINAL_READING_SELECTION and not value["preedit"] \
            and value["cursor"] == 4 and value["anchor"] == 1 \
            and message("reading_input", reading=reading) in bus_log.read_text()

    keyboard.key(ord("r"), modifiers=(CONTROL, SHIFT))
    wait_for(state, process, lambda value: reading_visible(value, ""))
    for character in READING_INPUT:
        keyboard.key(ord(character))
    observation = wait_for(state, process, lambda value: reading_visible(value, SUBMITTED_READING))
    assert inserted_text(observation["events"], "qt") == [], observation["events"]
    (directory / "reading.json").write_text(json.dumps(observation, ensure_ascii=False))
    (directory / "reading-submit.json").write_text(json.dumps({"enterSentMonotonic": time.monotonic()}) + "\n")
    keyboard.key(RETURN)
    keyboard.key(F10)
    keyboard.key(HOME, modifiers=(CONTROL,))


def start_burst(keyboard, directory, *, scenario, activation):
    # No observation wait between native chords: later keys must remain ordered
    # while Core plans and confirms the replacement.
    if activation == "key":
        keyboard.key(ord("r") if scenario == "selection" else BACKSPACE, modifiers=(CONTROL, SHIFT))
    else:
        activate_focused_property(directory, "reconvert" if scenario == "selection" else "undo-commit")
        if activation == "property-enter":
            confirmed_at = time.monotonic()
            keyboard.key(RETURN)
            (directory / "menu-confirmation.json").write_text(json.dumps({
                "enterSentMonotonic": confirmed_at,
            }) + "\n")
    if activation == "property-escape":
        keyboard.key(ESCAPE)
    else:
        keyboard.key(RETURN if scenario == "selection" and activation != "property-edit" else F10)
    keyboard.key(HOME, modifiers=(CONTROL,))


def assert_cancelled(observation, toolkit, *, event_start, trace_start):
    events = observation["events"][event_start:]
    assert inserted_text(events, toolkit) == [], events
    assert not any(event["event"] == "delete" for event in events), events
    operations = trace_events()[trace_start:]
    assert not any(event["operation"] in RECONVERSION_OPERATIONS for event in operations), operations
    return {"operations": operations, "operationSeconds": [], "commits": []}


def run(toolkit, scenario, directory, *, activation):
    state = directory / "editor.json"
    environment = {**os.environ, "GTK_IM_MODULE": "ibus", "QT_IM_MODULE": "ibus", "QT_QPA_PLATFORM": "xcb"}
    assert "IBUS_ENABLE_SYNC_MODE" not in environment
    original = {"selection": ORIGINAL_SELECTION, "undo": "pq", "reading": ORIGINAL_READING_SELECTION}[scenario]
    with (directory / "editor.log").open("w") as log:
        process = subprocess.Popen([
            "python3", "Linux/tests/fixtures/native_key_editor.py", toolkit, str(state), "--text", original,
        ], env=environment, stdout=log, stderr=log)
        keyboard = None
        try:
            keyboard = NativeKeyboard()
            ready = wait_for(state, process, lambda value: len(value["heartbeats"]) >= 2)
            keyboard.focus(ready["window"])
            wait_for(state, process, lambda value: value["active"] and value["focused"])
            # GTK Entry can select all initial text when it first gains focus.
            # Collapse that real selection before testing IME preedit.
            keyboard.key(RIGHT)
            wait_for(state, process, lambda value: value["cursor"] == value["anchor"] == len(original))
            keyboard.key(HENKAN)
            keyboard.key(ord("a"))
            positive = wait_for(state, process, lambda value: bool(value["preedit"]) and value["text"] == original)
            modules = loaded_input_modules(process, toolkit)
            for _ in range(3):
                keyboard.key(ESCAPE)
            wait_for(state, process, lambda value: not value["preedit"] and value["text"] == original)
            prepared = prepare_undo(keyboard, state, process) if scenario == "undo" else prepare_selection(
                keyboard, state, process, length=3 if scenario == "reading" else 4,
            )
            assert inserted_text(prepared["events"], toolkit) == ([ROMAN_INPUT] if scenario == "undo" else [])
            (directory / "positive.json").write_text(json.dumps(positive, ensure_ascii=False))
            (directory / "prepared.json").write_text(json.dumps(prepared, ensure_ascii=False))
            event_start, trace_start = len(prepared["events"]), len(trace_events())
            started = time.monotonic()
            if scenario == "reading":
                assert toolkit == "qt" and activation == "key", "reading requires a selection-aware Qt client"
                type_reading(keyboard, state, process, directory=directory)
            else:
                start_burst(keyboard, directory, scenario=scenario, activation=activation)
            cancelled = activation in ("property-edit", "property-escape")
            expected = prepared["text"] if cancelled else {
                "selection": "前日本語後", "undo": "phashiq", "reading": "前にほんご後",
            }[scenario]
            final = wait_for(state, process, lambda value: value["text"] == expected
                             and value["cursor"] == value["anchor"] == 0 and not value["preedit"]
                             and len(inserted_text(value["events"][event_start:], toolkit)) == int(not cancelled))
            if cancelled:
                confirmed = assert_cancelled(final, toolkit, event_start=event_start, trace_start=trace_start)
            else:
                confirmed = assert_completed(final, toolkit, scenario=scenario,
                                             event_start=event_start, trace_start=trace_start)
            (directory / "final.json").write_text(json.dumps(final, ensure_ascii=False))
            return {
                "status": "PASS", "toolkit": toolkit, "scenario": scenario, "activation": activation,
                "document": final["text"], "cursor": final["cursor"], "anchor": final["anchor"],
                "positionUnit": final["positionUnit"], "elapsedSeconds": time.monotonic() - started,
                "processId": process.pid, "inputModules": modules, "syncModeOverride": False,
                **heartbeat_summary(prepared, final), **confirmed,
            }
        finally:
            if keyboard is not None:
                keyboard.close()
            process.terminate()
            process.wait(timeout=5)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--toolkit", choices=("gtk4", "qt"), default=os.environ.get("AZOOKEY_TEST_TOOLKIT"),
                        required="AZOOKEY_TEST_TOOLKIT" not in os.environ)
    parser.add_argument("--scenario", choices=("selection", "undo", "reading"), default=os.environ.get("AZOOKEY_TEST_SCENARIO"),
                        required="AZOOKEY_TEST_SCENARIO" not in os.environ)
    parser.add_argument("--activation", choices=ACTIVATIONS,
                        default=os.environ.get("AZOOKEY_TEST_ACTIVATION", "key"))
    arguments = parser.parse_args()
    destination = Path(os.environ["AZOOKEY_NATIVE_ARTIFACTS"])
    destination.mkdir(parents=True, exist_ok=True)
    with observe_ibus(destination):
        summary = run(arguments.toolkit, arguments.scenario, destination, activation=arguments.activation)
    bus_events = (destination / "ibus-events.log").read_text()
    assert "member=ForwardKeyEvent" not in bus_events
    if arguments.activation != "key":
        assert message("confirm_selection" if arguments.scenario == "selection" else "confirm_undo") in bus_events
    if arguments.activation == "property-enter":
        confirmation = json.loads((destination / "menu-confirmation.json").read_text())
        operation = "reconvert" if arguments.scenario == "selection" else "undo-commit"
        request = next(event for event in summary["operations"]
                       if event["operation"] == operation and event["phase"] == "started")
        assert request["monotonic"] >= confirmation["enterSentMonotonic"], summary
    if arguments.scenario == "reading":
        submitted = json.loads((destination / "reading-submit.json").read_text())
        handshake = assert_reply_between_delete_and_ack(
            destination, keyval=RETURN, removed_text="前後", sent_after=submitted["enterSentMonotonic"],
        )
        (destination / "reading-handshake.json").write_text(json.dumps(handshake, ensure_ascii=False, indent=2) + "\n")
    summary["forwardedEvents"] = 0
    (destination / "summary.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(summary, ensure_ascii=False))
