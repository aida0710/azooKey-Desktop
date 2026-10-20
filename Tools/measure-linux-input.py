#!/usr/bin/env python3
"""Measure synthetic input latency without retaining input or candidate text."""
import argparse
import json
import math
import os
import pathlib
import statistics
import sys
import tempfile
import time

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "Linux"))
from azookey.bridge import Bridge
from azookey.keymap import translate


FIXTURES = {
    "short": "nihongo",
    "long": "watashihanihongowobenkyoushiteimasu.ashitahatokyounotomodachitoaitaimasuga,tenkihadoudeshouka.",
}


def summarize(seconds):
    ordered = sorted(value * 1000 for value in seconds)
    return {
        "samples": len(ordered),
        "p50_ms": round(statistics.median(ordered), 3),
        "p95_ms": round(ordered[math.ceil(len(ordered) * 0.95) - 1], 3),
        "max_ms": round(ordered[-1], 3),
    }


def measure_phrase(bridge, phrase, *, require_zenzai):
    latencies = []
    for keyval in [*map(ord, phrase), 32, 0xFF0D]:
        start = time.monotonic()
        snapshot = bridge.request("key", event=translate(keyval, 0))
        latencies.append(time.monotonic() - start)
        if snapshot.get("error"):
            raise RuntimeError("benchmark request failed")
        if require_zenzai and not snapshot.get("zenzaiLoaded"):
            raise RuntimeError("Zenzai benchmark cannot silently fall back to dictionary conversion")
    return latencies


def measure_fixture(phrase, *, samples, require_zenzai):
    initialization = []
    first_keys = []
    cold = []
    warm = []
    for _ in range(samples):
        with tempfile.TemporaryDirectory(prefix="azookey-latency-") as directory:
            environment = {**os.environ, "AZOOKEY_DATA_DIR": directory, "XDG_CONFIG_HOME": directory}
            start = time.monotonic()
            bridge = Bridge(environment=environment)
            try:
                settings = bridge.request("settings")["settings"]
                bridge.request("configure", settings={**settings, "live": True, "learning": "nothing"})
                initialization.append(time.monotonic() - start)
                latencies = measure_phrase(bridge, phrase, require_zenzai=require_zenzai)
                first_keys.append(latencies[0])
                cold.extend(latencies)
                bridge.request("reset", submit=False)
                warm.extend(measure_phrase(bridge, phrase, require_zenzai=require_zenzai))
            finally:
                bridge.close()
    return {
        "input_characters": len(phrase), "fresh_processes": samples,
        "initialization": summarize(initialization), "first_key": summarize(first_keys),
        "first_phrase": summarize(cold), "warm_phrase": summarize(warm),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--samples", type=int, default=10)
    parser.add_argument("--zenzai", action="store_true")
    arguments = parser.parse_args()
    if arguments.samples < 1:
        parser.error("--samples must be positive")
    if arguments.zenzai and not os.environ.get("AZOOKEY_RESOURCES"):
        parser.error("--zenzai requires a verified AZOOKEY_RESOURCES directory")
    measurements = {
        "mode": "zenzai" if arguments.zenzai else "dictionary",
        "clock": "monotonic", "unit": "milliseconds",
        "fixtures": {
            name: measure_fixture(phrase, samples=arguments.samples, require_zenzai=arguments.zenzai)
            for name, phrase in FIXTURES.items()
        },
    }
    print(json.dumps(measurements, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
