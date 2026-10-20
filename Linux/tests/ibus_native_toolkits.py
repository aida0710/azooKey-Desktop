"""Drive real X11 widget key events; record sync-client waiting separately."""
import json
import os
from pathlib import Path
import subprocess
import tempfile


from native_toolkit_support import (
    BACKSPACE, CONTROL, ESCAPE, HENKAN, HOME, LEFT, MUHENKAN, RETURN, SHIFT,
    NativeKeyboard, heartbeat_summary, loaded_input_modules, wait_for,
)


def run_toolkit(toolkit, directory):
    state = directory / f"{toolkit}.json"
    environment = {**os.environ, "GTK_IM_MODULE": "ibus", "QT_IM_MODULE": "ibus",
                   "QT_QPA_PLATFORM": "xcb"}
    # Preserve the toolkit's default IBus synchronous/asynchronous behavior.
    assert "IBUS_ENABLE_SYNC_MODE" not in environment
    with (directory / f"{toolkit}.log").open("w") as log:
        process = subprocess.Popen(
            ["python3", "Linux/tests/fixtures/native_key_editor.py", toolkit, str(state)],
            env=environment, stdout=log, stderr=log,
        )
        keyboard = None
        try:
            keyboard = NativeKeyboard()
            ready = wait_for(state, process, lambda value: len(value["heartbeats"]) >= 2)
            keyboard.focus(ready["window"])
            wait_for(state, process, lambda value: value["active"])
            keyboard.key(HENKAN)
            keyboard.key(ord("a"))
            positive = wait_for(state, process, lambda value: value["preedit"] == "a" and value["text"] == "")
            modules = loaded_input_modules(process, toolkit)
            keyboard.key(ESCAPE)
            wait_for(state, process, lambda value: value["preedit"] == "" and value["text"] == "")
            keyboard.key(MUHENKAN)
            keyboard.key(ord("a"), modifiers=(SHIFT,))
            keyboard.key(LEFT)
            keyboard.key(ord("b"), modifiers=(SHIFT,))
            english = wait_for(state, process, lambda value: value["text"] == "BA" and value["cursor"] == 1)
            keyboard.key(HOME, modifiers=(CONTROL,))
            idle = wait_for(state, process, lambda value: value["cursor"] == 0)
            assert idle["text"] == "BA"
            keyboard.key(ord("a"), modifiers=(CONTROL,))
            keyboard.key(BACKSPACE)
            wait_for(state, process, lambda value: value["text"] == "")
            keyboard.key(ord("p"))
            keyboard.key(ord("q"))
            keyboard.key(LEFT)
            wait_for(state, process, lambda value: value["text"] == "pq" and value["cursor"] == 1)
            keyboard.key(HENKAN)
            keyboard.key(ord("a"))
            keyboard.key(RETURN)
            keyboard.key(HOME, modifiers=(CONTROL,))
            pending = wait_for(state, process, lambda value: value["text"] == "paq"
                               and value["cursor"] == 0 and value["preedit"] == "")
            if toolkit == "gtk4":
                inserted = [event["text"] for event in pending["events"] if event["event"] == "insert"]
            else:
                inserted = [
                    event.get("commit", event.get("text", ""))
                    for event in pending["events"]
                    if event["event"] in ("input-method", "key-press")
                ]
            for text in ("A", "B", "p", "q", "a"):
                assert inserted.count(text) == 1, (text, inserted)
            for stage, observation in (("positive", positive), ("english", english),
                                       ("idleHome", idle), ("pendingHome", pending)):
                (directory / f"{toolkit}-{stage}.json").write_text(json.dumps(observation, ensure_ascii=False))
            return {
                "toolkit": toolkit, "inputDelivery": "PASS", "text": pending["text"], "cursor": pending["cursor"],
                "englishText": english["text"], "englishCursor": english["cursor"],
                **heartbeat_summary(ready, pending), "syncModeOverride": False,
                "processId": process.pid, "inputModules": modules,
            }
        finally:
            if keyboard is not None:
                keyboard.close()
            process.terminate()
            process.wait(timeout=5)
            if process.returncode not in (0, -15):
                print(log.name + ":\n" + Path(log.name).read_text())


artifact_path = os.environ.get("AZOOKEY_NATIVE_ARTIFACTS")
destination = Path(artifact_path or tempfile.mkdtemp(prefix="azookey-native-toolkit-"))
destination.mkdir(parents=True, exist_ok=True)
observations = [run_toolkit(name, destination) for name in ("gtk4", "qt")]
print(json.dumps({"delaySeconds": float(os.environ["AZOOKEY_TEST_DELAY"]), "observations": observations}))
