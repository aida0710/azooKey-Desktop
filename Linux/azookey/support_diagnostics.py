"""Read only the build/environment fields suitable for a public issue."""
import os
import platform
import re
from pathlib import Path

from .i18n import text as message

GUIDE_URL = "https://github.com/aida0710/azooKey-Desktop/blob/main/docs/setup-and-recovery.md"
RELEASES_URL = "https://github.com/aida0710/azooKey-Desktop/releases"
ISSUES_URL = "https://github.com/aida0710/azooKey-Desktop/issues/new"
UPSTREAM_URL = "https://github.com/azooKey/azooKey-Desktop"
BUILD_INFO_PATH = Path(__file__).resolve().parents[1] / "build-info.txt"
BUILD_PATTERNS = {
    "version": r"\d+\.\d+\.\d+",
    "architecture": r"(?:amd64|arm64)",
    "source": r"[0-9a-f]{7,40}",
}


def read_build_info(path=BUILD_INFO_PATH):
    try:
        lines = Path(path).read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError):
        return {}
    values = {}
    for line in lines:
        key, separator, value = line.partition("=")
        if separator and key in BUILD_PATTERNS and re.fullmatch(BUILD_PATTERNS[key], value):
            values[key] = value
    return values


def component_version():
    return read_build_info().get("version", "development")


def renderer_status(*, tree_enabled, session, engine_status):
    if not tree_enabled:
        return message("support.renderer.ibus-list"), message("support.fallback.setting")
    if engine_status is None:
        return message("support.unknown"), message("support.fallback.unavailable")
    if session == "x11":
        return message("support.renderer.gtk-tree"), message("support.none")
    if session == "wayland" and engine_status is not None:
        if engine_status.get("rendererRegistered") is True:
            return message("support.renderer.shell-tree"), message("support.none")
        return message("support.renderer.ibus-list"), message("support.fallback.extension")
    return message("support.unknown"), message("support.fallback.unavailable")


def diagnostics(*, tree_enabled, engine_status, build_info=None, environment=None, os_release=None, architecture=None):
    build_info = read_build_info() if build_info is None else build_info
    environment = os.environ if environment is None else environment
    if os_release is None:
        try:
            os_release = platform.freedesktop_os_release()
        except OSError:
            os_release = {}
    unknown = message("support.unknown")
    # Session and build fields use recognized values, not arbitrary environment text.
    session = environment.get("XDG_SESSION_TYPE", "").lower()
    if session not in ("x11", "wayland"):
        session = unknown
    build = {key: value for key, value in build_info.items()
             if key in BUILD_PATTERNS and isinstance(value, str) and re.fullmatch(BUILD_PATTERNS[key], value)}
    os_parts = [os_release.get("ID", ""), os_release.get("VERSION_ID", "")]
    operating_system = " ".join(part for part in os_parts if re.fullmatch(r"[a-zA-Z0-9_.-]+", part)) or unknown
    renderer, fallback = renderer_status(tree_enabled=tree_enabled, session=session, engine_status=engine_status)
    fields = [
        ("support.version", build.get("version", unknown)),
        ("support.source", build.get("source", unknown)),
        ("support.os", operating_system),
        ("support.cpu", architecture or platform.machine()),
        ("support.package-cpu", build.get("architecture", unknown)),
        ("support.backend", "CPU" if "version" in build else unknown),
        ("support.session", session),
        ("support.renderer", renderer),
        ("support.fallback", fallback),
    ]
    return "\n".join(["azooKey Tree"] + [f"{message(key)}: {value}" for key, value in fields])
