"""Capture a stopped XCTest process without evaluating expressions after exit."""
import json
import os
from pathlib import Path

import lldb


CAPTURED_PROCESSES = set()
# Stack output remains complete; this bounds each thread's one-line reason only.
STOP_DESCRIPTION_LIMIT = 1024


def capture(debugger, case_name):
    target = debugger.GetSelectedTarget()
    process = target.GetProcess()
    identity = (case_name, process.GetProcessID())
    if identity in CAPTURED_PROCESSES:
        return
    CAPTURED_PROCESSES.add(identity)
    state = process.GetState()
    observation = {
        "case": case_name,
        "processId": process.GetProcessID(),
        "state": lldb.SBDebugger.StateAsCString(state),
        "triple": target.GetTriple(),
    }
    if state == lldb.eStateExited:
        observation["exitStatus"] = process.GetExitStatus()
        observation["exitDescription"] = process.GetExitDescription()
    elif state in (lldb.eStateStopped, lldb.eStateCrashed, lldb.eStateSuspended):
        observation["threads"] = [
            {
                "id": thread.GetThreadID(),
                "stopReason": thread.GetStopReason(),
                "stopDescription": thread.GetStopDescription(STOP_DESCRIPTION_LIMIT),
                "topFunction": thread.GetFrameAtIndex(0).GetFunctionName(),
            }
            for thread in process
        ]
    destination = Path(os.environ["AZOOKEY_RECONVERSION_DIAGNOSTIC"])
    with (destination / f"{case_name}-process.json").open("x") as stream:
        json.dump(observation, stream, indent=2)
        stream.write("\n")
    print("reconversion-process: " + json.dumps(observation), flush=True)
    if "threads" not in observation:
        return
    debugger.HandleCommand("thread backtrace all")
    # x0 is an exception object only at this known arm64 Objective-C entry point.
    frame = process.GetSelectedThread().GetFrameAtIndex(0)
    if target.GetTriple().startswith("arm64") and frame.GetFunctionName() == "objc_exception_throw":
        debugger.HandleCommand("expression --language objc --object-description -- (NSException *)$x0")
