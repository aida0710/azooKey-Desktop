"""Protect bridge measurements against wrong settings, backends and mixed timings."""
import importlib.util
import pathlib
import unittest
from unittest.mock import patch


SCRIPT = pathlib.Path(__file__).resolve().parents[2] / "Tools" / "measure-linux-input.py"
SPEC = importlib.util.spec_from_file_location("input_measurement", SCRIPT)
measurement = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(measurement)


class FakeBridge:
    def __init__(self, *, environment, ignore_live=False, zenzai=False, error=False):
        self.environment = environment
        self.ignore_live = ignore_live
        self.zenzai = zenzai
        self.error = error
        self.restarts = 0
        self.closed = False
        self.settings = {"live": True, **measurement.FIXED_SETTINGS}
        self.operations = []

    def request(self, operation, **payload):
        self.operations.append((operation, payload))
        if operation == "settings":
            return {"settings": dict(self.settings)}
        if operation == "configure":
            self.settings.update(payload["settings"])
            if self.ignore_live:
                self.settings["live"] = True
        if self.error:
            return {"error": "synthetic_error"}
        return {
            "consumed": True, "zenzaiLoaded": self.zenzai,
            "candidates": [{"text": "SYNTHETIC"}], "commits": ["SYNTHETIC"], "preedit": "", "reading": "あいう",
        }

    def close(self):
        self.closed = True


class InputMeasurementTests(unittest.TestCase):
    def test_percentiles_preserve_outliers_and_small_sample_limits(self):
        summary = measurement.summarize(range(1, 101))
        self.assertEqual(summary, {"samples": 100, "p50_ms": 50.5, "p95_ms": 95, "p99_ms": 99, "max_ms": 100})
        self.assertEqual(measurement.summarize([1, 2, 3])["p99_ms"], 3)
        with self.assertRaises(ValueError):
            measurement.summarize([])

    def test_slow_conversion_and_commit_are_not_reported_as_typing(self):
        requests = [
            {"operation": "typing", "elapsed_ms": 1},
            {"operation": "typing", "elapsed_ms": 3},
            {"operation": "convert", "elapsed_ms": 200},
            {"operation": "commit", "elapsed_ms": 50},
        ]
        trial = {"initialization_ms": 400, "phases": {phase: requests for phase in measurement.PHASES}}
        summary = measurement.summarize_trials([trial])
        for phase in summary["phases"].values():
            self.assertEqual(phase["typing"]["p50_ms"], 2)
            self.assertEqual(phase["convert"]["p50_ms"], 200)
            self.assertEqual(phase["commit"]["p50_ms"], 50)
            self.assertEqual(phase["first_key"]["p50_ms"], 1)

    def test_live_off_is_applied_and_dictionary_ignores_inherited_models(self):
        bridges = []

        def create_bridge(**options):
            bridge = FakeBridge(**options)
            bridges.append(bridge)
            return bridge

        with patch.object(measurement, "Bridge", side_effect=create_bridge), \
                patch.dict(measurement.os.environ, {"AZOOKEY_RESOURCES": "/synthetic-model"}):
            trial = measurement.measure_trial(("a", "b"), live=False, require_zenzai=False)
        bridge = bridges[0]
        self.assertTrue(bridge.closed)
        self.assertNotIn("AZOOKEY_RESOURCES", bridge.environment)
        self.assertFalse(bridge.settings["live"])
        self.assertEqual(bridge.settings["learning"], "nothing")
        self.assertEqual(len(trial["phases"]), 3)
        typed = [payload["event"]["characters"] for operation, payload in bridge.operations
                 if operation == "key" and payload["event"]["keyCode"] == 0xFFFF]
        self.assertEqual(typed, ["a", "a", "b"])
        self.assertEqual([operation for operation, _ in bridge.operations].count("reset"), 3)
        self.assertNotIn("SYNTHETIC", str(trial))

    def test_ignored_settings_fail_before_measurement_and_close_the_process(self):
        bridge = FakeBridge(environment={}, ignore_live=True)
        with patch.object(measurement, "Bridge", return_value=bridge):
            with self.assertRaisesRegex(RuntimeError, "preferences"):
                measurement.measure_trial(("a", "b"), live=False, require_zenzai=False)
        self.assertTrue(bridge.closed)
        self.assertFalse(any(operation == "key" for operation, _ in bridge.operations))

    def test_backend_fallback_failed_request_and_restarts_are_rejected(self):
        for options, expected_zenzai, message in (
            ({}, True, "backend"), ({"zenzai": True}, False, "backend"), ({"error": True}, False, "request"),
        ):
            with self.subTest(options=options):
                with self.assertRaisesRegex(RuntimeError, message):
                    measurement.measure_phrase(FakeBridge(environment={}, **options), "a",
                                               require_zenzai=expected_zenzai)
        restarted = FakeBridge(environment={})
        restarted.restarts = 1
        with self.assertRaisesRegex(RuntimeError, "restarted"):
            measurement.measure_phrase(restarted, "a", require_zenzai=False)

    def test_partial_commit_is_finished_before_the_next_phrase(self):
        class PartialBridge(FakeBridge):
            commit_count = 0

            def request(self, operation, **payload):
                snapshot = super().request(operation, **payload)
                if operation == "key" and payload["event"]["keyCode"] == 36:
                    self.commit_count += 1
                    if self.commit_count == 1:
                        snapshot.update(preedit="残り", reading="のこ")
                return snapshot

        bridge = PartialBridge(environment={})
        timings = measurement.measure_phrase(bridge, "a", require_zenzai=False)
        self.assertEqual(bridge.commit_count, 2)
        self.assertEqual([request["operation"] for request in timings], ["typing", "convert", "commit", "commit"])

    def test_nonprogressing_commit_fails_instead_of_looping(self):
        class StalledBridge(FakeBridge):
            def request(self, operation, **payload):
                snapshot = super().request(operation, **payload)
                snapshot["preedit"] = "SYNTHETIC"
                return snapshot

        with self.assertRaisesRegex(RuntimeError, "consume the composition"):
            measurement.measure_phrase(StalledBridge(environment={}), "a", require_zenzai=False)

    def test_live_off_preview_does_not_require_a_visible_candidate_window(self):
        class PreviewBridge(FakeBridge):
            def request(self, operation, **payload):
                snapshot = super().request(operation, **payload)
                if operation == "key" and payload["event"]["keyCode"] == 49:
                    snapshot.update(candidates=[], inputState="previewing", preedit="SYNTHETIC")
                return snapshot

        requests = measurement.measure_phrase(PreviewBridge(environment={}), "a", require_zenzai=False)
        self.assertEqual([request["operation"] for request in requests], ["typing", "convert", "commit"])


if __name__ == "__main__":
    unittest.main()
