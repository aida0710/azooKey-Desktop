#!/usr/bin/env python3
"""Measure bridge round trips with fixed text; this does not measure UI latency."""
import argparse
import hashlib
import json
import math
import os
import pathlib
import re
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Linux"))
from azookey.bridge import Bridge
from azookey.keymap import translate


FIXTURES = {
    "short": ("nihongo", "toukyou"),
    "long": (
        "watashihanihongowobenkyoushiteimasu.ashitahatokyounotomodachitoaitaimasuga,tenkihadoudeshouka.",
        "kyouhatoshokandehonwoyondekarakouenwosanposhimashita.raishuuhaosakanoatarashiibijutsukanniikimasu.",
    ),
}
PHASES = ("cold", "warm_same_text", "warm_different_text")
# Keep optional conversion features fixed so only the live preference varies.
FIXED_SETTINGS = {
    "tree": True, "showRelativeScores": True, "learning": "nothing",
    "predictiveTyping": False, "typoCorrection": False, "aiEnabled": False,
}
CONVERT_KEY = 0x20
COMMIT_KEY = 0xFF0D
# Stream model hashes without holding the model in the measurement process.
HASH_CHUNK_BYTES = 1024 * 1024
RECORDED_SETTINGS = ("inferenceLimit", "personalization", "inputStyle", *FIXED_SETTINGS, "live")


def summarize(milliseconds):
    ordered = sorted(milliseconds)
    if not ordered:
        raise ValueError("cannot summarize an empty sample")
    return {
        "samples": len(ordered),
        "p50_ms": round(statistics.median(ordered), 3),
        "p95_ms": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 3),
        "p99_ms": round(ordered[math.ceil(len(ordered) * 0.99) - 1], 3),
        "max_ms": round(ordered[-1], 3),
    }


def sha256_file(path):
    digest = hashlib.sha256()
    with pathlib.Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(HASH_CHUNK_BYTES), b""):
            digest.update(chunk)
    return digest.hexdigest()


def check_response(snapshot):
    if snapshot.get("error"):
        raise RuntimeError("benchmark request failed")
    return snapshot


def measure_key(bridge, keyval, *, require_zenzai):
    event = translate(keyval, 0)
    start = time.monotonic_ns()
    snapshot = bridge.request("key", event=event)
    elapsed_ms = (time.monotonic_ns() - start) / 1_000_000
    check_response(snapshot)
    if snapshot.get("zenzaiLoaded") is not require_zenzai:
        raise RuntimeError("benchmark backend differs from the requested backend")
    if not snapshot.get("consumed"):
        raise RuntimeError("benchmark key was not consumed")
    if bridge.restarts:
        raise RuntimeError("benchmark converter restarted")
    return snapshot, elapsed_ms


def measure_phrase(bridge, phrase, *, require_zenzai):
    requests = []
    keys = [("typing", ord(character)) for character in phrase]
    keys.append(("convert", CONVERT_KEY))
    for operation, keyval in keys:
        snapshot, elapsed_ms = measure_key(bridge, keyval, require_zenzai=require_zenzai)
        requests.append({"operation": operation, "elapsed_ms": elapsed_ms})
    # With live conversion off, the first Space previews the sentence and keeps
    # the candidate window hidden. That response is still a completed conversion.
    previewing = snapshot.get("inputState") == "previewing" and bool(snapshot.get("preedit"))
    if not snapshot.get("candidates") and not previewing:
        raise RuntimeError("benchmark conversion returned neither preview nor candidates")
    # A selected candidate can consume a prefix. Finish the remaining preedit
    # instead of discarding it at reset and calling that a full-sentence commit.
    while True:
        previous_reading_length = len(snapshot["reading"])
        snapshot, elapsed_ms = measure_key(bridge, COMMIT_KEY, require_zenzai=require_zenzai)
        requests.append({"operation": "commit", "elapsed_ms": elapsed_ms})
        if not snapshot.get("commits"):
            raise RuntimeError("benchmark commit returned no text")
        if not snapshot.get("preedit"):
            break
        if len(snapshot["reading"]) >= previous_reading_length:
            raise RuntimeError("benchmark commit did not consume the composition")
    return requests


def measure_trial(phrases, *, live, require_zenzai):
    with tempfile.TemporaryDirectory(prefix="azookey-latency-") as directory:
        environment = {**os.environ, "AZOOKEY_DATA_DIR": directory, "XDG_CONFIG_HOME": directory}
        if not require_zenzai:
            environment.pop("AZOOKEY_RESOURCES", None)
        start = time.monotonic_ns()
        bridge = Bridge(environment=environment)
        try:
            settings = check_response(bridge.request("settings"))["settings"]
            expected = {**FIXED_SETTINGS, "live": live}
            check_response(bridge.request("configure", settings={**settings, **expected}))
            initialization_ms = (time.monotonic_ns() - start) / 1_000_000
            applied = check_response(bridge.request("settings"))["settings"]
            if any(applied[key] != value for key, value in expected.items()):
                raise RuntimeError("benchmark preferences were not applied")
            phases = {}
            for phase, phrase in zip(PHASES, (phrases[0], phrases[0], phrases[1])):
                phases[phase] = measure_phrase(bridge, phrase, require_zenzai=require_zenzai)
                check_response(bridge.request("reset", submit=False))
            return {
                "initialization_ms": initialization_ms,
                "settings": {key: applied.get(key) for key in RECORDED_SETTINGS},
                "phases": phases,
            }
        finally:
            bridge.close()


def summarize_trials(trials):
    phases = {}
    for phase in PHASES:
        requests = [request for trial in trials for request in trial["phases"][phase]]
        phases[phase] = {
            "all_keys": summarize([request["elapsed_ms"] for request in requests]),
            "first_key": summarize([trial["phases"][phase][0]["elapsed_ms"] for trial in trials]),
            **{
                operation: summarize([
                    request["elapsed_ms"] for request in requests if request["operation"] == operation
                ])
                for operation in ("typing", "convert", "commit")
            },
        }
    return {
        "initialization": summarize([trial["initialization_ms"] for trial in trials]),
        "phases": phases,
    }


def measure_condition(name, *, samples, live, require_zenzai):
    phrases = FIXTURES[name]
    trials = []
    for iteration in range(samples):
        trials.append(measure_trial(phrases, live=live, require_zenzai=require_zenzai))
        print(f"{name} live={live}: {iteration + 1}/{samples}", file=sys.stderr, flush=True)
    return {
        "text_length": name, "live": live, "fresh_processes": samples,
        "fixtures": [
            {"input_characters": len(phrase), "sha256": hashlib.sha256(phrase.encode()).hexdigest()}
            for phrase in phrases
        ],
        **summarize_trials(trials),
        # Preserve request durations for later percentiles; never retain response text.
        "raw_trials": trials,
    }


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--zenzai", action="store_true")
    parser.add_argument("--live", choices=("on", "off", "both"), default="both")
    parser.add_argument("--source-commit", required=True, help="full commit recorded by the tested build")
    arguments = parser.parse_args()
    if arguments.samples < 1:
        parser.error("--samples must be positive")
    if not re.fullmatch(r"[0-9a-f]{40}", arguments.source_commit):
        parser.error("--source-commit must be a full lowercase Git commit")
    if not os.environ.get("AZOOKEY_BRIDGE"):
        parser.error("AZOOKEY_BRIDGE must identify the tested executable")
    if arguments.zenzai and not os.environ.get("AZOOKEY_RESOURCES"):
        parser.error("--zenzai requires a verified AZOOKEY_RESOURCES directory")
    return arguments


def main():
    arguments = parse_arguments()
    model_directory = pathlib.Path(os.environ["AZOOKEY_RESOURCES"]) if arguments.zenzai else None
    measurements = {
        "measurement_scope": "bridge-roundtrip",
        "mode": "zenzai" if arguments.zenzai else "dictionary",
        "bridge_source_commit": arguments.source_commit,
        "bridge_sha256": sha256_file(os.environ["AZOOKEY_BRIDGE"]),
        "script_sha256": sha256_file(__file__),
        "model_sha256": {
            path.name: sha256_file(path) for path in sorted(model_directory.iterdir()) if path.is_file()
        } if model_directory else {},
        "backend_validation": {"every_key_response_zenzaiLoaded": arguments.zenzai},
        "clock": "monotonic_ns", "unit": "milliseconds",
        "percentile_method": "median p50; nearest-rank p95/p99",
        "cold_definition": "fresh converter and isolated settings; OS page cache is retained",
        "warm_definition": "same process, reset after commit; same text then different fixed text",
        "fixed_settings": FIXED_SETTINGS,
        "conditions": [],
    }
    live_modes = (True, False) if arguments.live == "both" else (arguments.live == "on",)
    for live in live_modes:
        for name in FIXTURES:
            measurements["conditions"].append(
                measure_condition(name, samples=arguments.samples, live=live, require_zenzai=arguments.zenzai)
            )
    print(json.dumps(measurements, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
