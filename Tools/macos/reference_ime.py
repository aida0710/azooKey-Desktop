"""Capture Apple's Japanese input method in the same TextEdit window.

The screenshots are a size reference for azooKey Tree's candidate window; they
do not test Apple's input method.
"""

import json
import re
import time

from smoke_evidence import require_success

APPLE_JAPANESE_PARENT = "com.apple.inputmethod.Kotoeri.RomajiTyping"
APPLE_JAPANESE_MODE = re.compile(r"com\.apple\.inputmethod\.Kotoeri\.(RomajiTyping\.)?Japanese")
# Apple's candidate window is drawn by another process; leave it time to appear.
CANDIDATE_SETTLE_SECONDS = 1.5


def capture_reference_ime(evidence, input_source, send_keys, *, outcome):
    text_edit = evidence.directory / "helpers/TextEditDocument"

    def keys(name, value):
        require_success(evidence.run(name, [send_keys, value]), "Post " + value)
        time.sleep(CANDIDATE_SETTLE_SECONDS)

    def clear(name):
        for attempt in range(3):
            keys(f"{name}-escape-{attempt}", "escape")
        require_success(evidence.run(name + "-clear", [text_edit, "clear"]), "Clear TextEdit")

    listed = require_success(evidence.run("reference-sources", [input_source, "list"]), "List input sources")
    identifiers = [source["id"] for source in json.loads(listed.stdout)]
    mode = next((identifier for identifier in identifiers if APPLE_JAPANESE_MODE.fullmatch(identifier)), None)
    if mode is None:
        raise RuntimeError("Apple's Japanese input method is not installed on this runner")
    if APPLE_JAPANESE_PARENT in identifiers:
        evidence.run("reference-enable-parent", [input_source, "enable", APPLE_JAPANESE_PARENT])
    require_success(evidence.run("reference-select", [input_source, "select", mode]), "Select Apple's Japanese input method")
    require_success(evidence.run("reference-reactivate", [text_edit, "reactivate"]), "Reactivate TextEdit")
    clear("reference-start")
    keys("reference-type-sentence", "kyouhagakkainiikoutoomotteimasu")
    evidence.screenshot("reference-typing")
    keys("reference-space-1", "space")
    evidence.screenshot("reference-space1")
    keys("reference-space-2", "space")
    evidence.screenshot("reference-space2")
    clear("reference-sentence")
    keys("reference-type-word", "tesuto")
    keys("reference-word-space-1", "space")
    keys("reference-word-space-2", "space")
    evidence.screenshot("reference-short-list")
    clear("reference-word")
    outcome["referenceInputSource"] = mode
