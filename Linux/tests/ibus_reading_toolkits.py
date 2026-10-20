"""Exercise actual GTK4/Qt input while the real candidate process is stopped."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import signal
import subprocess
import time

from native_ibus_observer import current_native_focus, has_native_focus, observe_ibus
from native_toolkit_support import (
    BACKSPACE, ESCAPE, F10, HENKAN, HOME, LEFT, RETURN, SHIFT,
    NativeKeyboard, heartbeat_summary, loaded_input_modules, wait_for,
)


END = 0xFF57
PROCESS_STATE_TIMEOUT_SECONDS = 5  # Observe SIGSTOP before testing independent input.
PROCESS_STATE_POLL_SECONDS = 0.01
FORWARD_MEMBER = "interface=org.freedesktop.IBus.Engine; member=ForwardKeyEvent"


def save(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def candidate_process(directory):
    workers = []
    for path in (directory / "workers").glob("candidate-*.json"):
        worker = json.loads(path.read_text())
        process = Path("/proc") / str(worker["pid"])
        if process.exists():
            assert process.joinpath("exe").resolve() == Path(worker["executable"]).resolve()
            workers.append(worker)
    assert len(workers) == 1, workers
    return workers[0]


@contextmanager
def stopped_candidate(directory, *, observation_path):
    worker = candidate_process(directory)
    pid = worker["pid"]
    os.kill(pid, signal.SIGSTOP)
    try:
        deadline = time.monotonic() + PROCESS_STATE_TIMEOUT_SECONDS
        status = ""
        while time.monotonic() < deadline:
            status = (Path("/proc") / str(pid) / "status").read_text()
            if any(line.startswith("State:") and "\tT" in line for line in status.splitlines()):
                break
            time.sleep(PROCESS_STATE_POLL_SECONDS)
        else:
            raise AssertionError("candidate process did not acknowledge SIGSTOP")
        worker["stoppedMonotonic"] = time.monotonic()
        worker["stoppedUnixSeconds"] = time.time()
        worker["stoppedState"] = next(line for line in status.splitlines() if line.startswith("State:"))
        save(observation_path, worker)
        yield worker
    finally:
        os.kill(pid, signal.SIGCONT)
        worker["resumedMonotonic"] = time.monotonic()
        worker["resumedUnixSeconds"] = time.time()
        save(observation_path, worker)


def type_text(keyboard, value):
    for character in value:
        keyboard.key(ord(character))


@contextmanager
def editor(toolkit, directory, name):
    path = directory / f"{name}.json"
    environment = {**os.environ, "GTK_IM_MODULE": "ibus", "QT_IM_MODULE": "ibus", "QT_QPA_PLATFORM": "xcb"}
    assert "IBUS_ENABLE_SYNC_MODE" not in environment
    with (directory / f"{name}.log").open("w") as log:
        process = subprocess.Popen(
            ["python3", "Linux/tests/fixtures/native_key_editor.py", toolkit, str(path)],
            env=environment, stdout=log, stderr=log,
        )
        try:
            yield path, process
        finally:
            process.terminate()
            process.wait(timeout=5)


def run_toolkit(toolkit, directory):
    case = directory / toolkit
    case.mkdir()
    with observe_ibus(case), editor(toolkit, case, "first") as (state, process):
        keyboard = NativeKeyboard()
        try:
            ready = wait_for(state, process, lambda value: len(value["heartbeats"]) >= 2)
            keyboard.focus(ready["window"])
            wait_for(state, process, lambda value: value["active"] and has_native_focus(case, toolkit))
            modules = loaded_input_modules(process, toolkit)
            keyboard.key(HENKAN)
            type_text(keyboard, "nihongo")
            warm = wait_for(state, process, lambda value: value["preedit"] == "にほんご")
            keyboard.key(ord(" "))
            wait_for(state, process, lambda _value: "日本語" in (case / "ibus-events.log").read_text())
            keyboard.key(ESCAPE)
            wait_for(state, process, lambda value: value["preedit"] == "にほんご")
            keyboard.key(ESCAPE)
            wait_for(state, process, lambda value: value["preedit"] == "" and value["text"] == "")
            with stopped_candidate(directory, observation_path=case / "candidate-stop.json") as worker:
                type_text(keyboard, "nihongo")
                wait_for(state, process, lambda value: value["preedit"] == "にほんご")
                keyboard.key(LEFT)
                keyboard.key(BACKSPACE)
                wait_for(state, process, lambda value: value["preedit"] == "にほご")
                keyboard.key(HOME)
                keyboard.key(ord("a"))
                wait_for(state, process, lambda value: value["preedit"] == "あにほご")
                keyboard.key(END)
                keyboard.key(BACKSPACE)
                wait_for(state, process, lambda value: value["preedit"] == "あにほ")
                keyboard.key(RETURN)
                edited = wait_for(state, process, lambda value: value["text"] == "あにほ" and value["preedit"] == "")
                save(case / "edited-and-committed.json", edited)
                type_text(keyboard, "kanta")
                wait_for(state, process, lambda value: value["preedit"] == "かんた")
                keyboard.key(LEFT, modifiers=(SHIFT,))
                keyboard.key(F10)
                partial = wait_for(state, process, lambda value: value["text"] == "あにほkan" and value["preedit"] == "た")
                save(case / "partial-f10.json", partial)
                keyboard.key(RETURN)
                wait_for(state, process, lambda value: value["text"] == "あにほkanた" and value["preedit"] == "")
                type_text(keyboard, "nihongo")
                wait_for(state, process, lambda value: value["preedit"] == "にほんご")
                keyboard.key(ESCAPE)
                cancelled = wait_for(state, process, lambda value: value["text"] == "あにほkanた" and value["preedit"] == "")
                save(case / "cancelled.json", cancelled)
                type_text(keyboard, "nihongo")
                wait_for(state, process, lambda value: value["preedit"] == "にほんご")
                previous_focus = current_native_focus(case)
                with editor(toolkit, case, "second") as (other_state, other_process):
                    other_ready = wait_for(other_state, other_process, lambda value: len(value["heartbeats"]) >= 2)
                    keyboard.focus(other_ready["window"])
                    wait_for(other_state, other_process, lambda value: value["active"] and has_native_focus(case, toolkit)
                             and current_native_focus(case) != previous_focus)
                    lost_focus = wait_for(state, process, lambda value: not value["focused"] and value["preedit"] == "")
                    save(case / "old-field-focus-out.json", lost_focus)
                    expected_old_text = "あにほkanたにほんご"
                    focus_preserved_text = lost_focus["text"] == expected_old_text
                    # Keep a failed focus-out assertion in the final result,
                    # while still checking that it cannot contaminate the next field.
                    save(case / "focus-out-verdict.json", {
                        "status": "PASS" if focus_preserved_text else "FAIL",
                        "expectedText": expected_old_text, "observedText": lost_focus["text"],
                    })
                    type_text(keyboard, "ka")
                    wait_for(other_state, other_process, lambda value: value["preedit"] == "か" and value["text"] == "")
                    keyboard.key(RETURN)
                    next_field = wait_for(other_state, other_process, lambda value: value["text"] == "か" and value["preedit"] == "")
                    save(case / "new-field-committed.json", next_field)
                    assert json.loads(state.read_text())["text"] == lost_focus["text"]
                    worker["inputFinishedMonotonic"] = time.monotonic()
                final = wait_for(state, process, lambda value: len(value["heartbeats"]) > len(lost_focus["heartbeats"]))
                assert final["text"] == lost_focus["text"]
            save(case / "candidate-stop.json", worker)
            # Observe subsequent UI turns after resuming, without a timed sleep
            # or replaying any key that has already completed.
            resumed_heartbeat_count = len(final["heartbeats"]) + 2
            final = wait_for(state, process, lambda value: len(value["heartbeats"]) >= resumed_heartbeat_count)
            assert final["text"] == lost_focus["text"] and final["preedit"] == ""
            assert FORWARD_MEMBER not in (case / "ibus-events.log").read_text()
            summary = {
                "toolkit": toolkit, "status": "PASS" if focus_preserved_text else "FAIL", "inputModules": modules,
                "text": final["text"], "otherFieldText": next_field["text"],
                "focusOutPreservedText": focus_preserved_text,
                "editingPartialCommitCancellationAndNextField": "PASS",
                "candidateStoppedDuringAllInput": worker["inputFinishedMonotonic"] < worker["resumedMonotonic"],
                "forwardedKeys": 0, "syncModeOverride": False,
                **heartbeat_summary(warm, cancelled),
            }
            save(case / "summary.json", summary)
            return summary
        finally:
            keyboard.close()


destination = Path(os.environ["AZOOKEY_NATIVE_ARTIFACTS"])
destination.mkdir(parents=True, exist_ok=True)
observations = [run_toolkit(toolkit, destination) for toolkit in ("gtk4", "qt")]
save(destination / "summary.json", observations)
print(json.dumps(observations, ensure_ascii=False))
raise SystemExit(0 if all(item["status"] == "PASS" for item in observations) else 1)
