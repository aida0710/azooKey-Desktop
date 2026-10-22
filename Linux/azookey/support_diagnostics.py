"""Read the raw environment values Core's support report recognizes."""
import os
import platform
import re
from pathlib import Path

BUILD_INFO_PATH = Path(__file__).resolve().parents[1] / "build-info.txt"
# The IBus component XML needs the version before any bridge process starts.
VERSION_LINE = re.compile(r"version=(\d+\.\d+\.\d+)")


def read_build_info():
    try:
        return BUILD_INFO_PATH.read_text(encoding="utf-8")
    except (OSError, UnicodeError):
        return ""


def component_version():
    for line in read_build_info().splitlines():
        if match := VERSION_LINE.fullmatch(line):
            return match.group(1)
    return "development"


def support_environment(*, tree_enabled, renderer_registered, environment=None, os_release=None):
    """Raw values only; Core drops anything outside its recognized formats."""
    environment = os.environ if environment is None else environment
    if os_release is None:
        try:
            os_release = platform.freedesktop_os_release()
        except OSError:
            os_release = {}
    return {
        "treeEnabled": tree_enabled, "rendererRegistered": renderer_registered,
        "sessionType": environment.get("XDG_SESSION_TYPE"),
        "osReleaseID": os_release.get("ID"), "osReleaseVersionID": os_release.get("VERSION_ID"),
        "machine": platform.machine(), "buildInfo": read_build_info(),
    }
