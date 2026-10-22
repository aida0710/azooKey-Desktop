"""Ask Core to read, save and recover the settings file.

Core validates, stages and replaces the file and keeps its last good copy.
These helpers only send the requests and turn the replies into Python values.
"""
from dataclasses import dataclass

from .i18n import text


@dataclass(frozen=True)
class SettingsFile:
    values: dict
    path: str
    stamp: str
    exists: bool
    problem: dict | None


@dataclass(frozen=True)
class SavedSettings:
    values: dict
    stamp: str
    recovered_path: str | None
    backup_warning: bool


def problem_text(problem):
    return text(problem["message"], **problem.get("arguments", {}))


def schema(bridge):
    return _result(bridge.request("settings-schema"))["schema"]


def load(bridge):
    return file_state(bridge.request("settings-load"))


def save(bridge, values, *, expected_stamp):
    return saved_settings(bridge.request("settings-save", settings=values, settingsFile={"expectedStamp": expected_stamp}))


def recover(bridge, *, expected_stamp, use_defaults):
    return saved_settings(bridge.request(
        "settings-recover", settingsFile={"expectedStamp": expected_stamp, "useDefaults": use_defaults},
    ))


def update(bridge, changes):
    """Change some settings in the file; the engines apply it on their next reload."""
    return saved_settings(bridge.request("settings-update", settings=changes))


def file_state(reply):
    state = _result(reply)["file"]
    return SettingsFile(reply["settings"], state["path"], state["stamp"], state["exists"], state.get("problem"))


def saved_settings(reply):
    result = _result(reply)
    return SavedSettings(
        reply["settings"], result["file"]["stamp"], result["saved"].get("recoveredPath"),
        not result["saved"]["lastGoodSaved"],
    )


def _result(reply):
    if type(reply) is not dict or reply.get("error") is not None or type(reply.get("settingsResult")) is not dict:
        raise RuntimeError("azooKey settings request failed")
    result = reply["settingsResult"]
    if result.get("error"):
        raise ValueError(problem_text(result["error"]))
    return result
