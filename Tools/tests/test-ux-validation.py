#!/usr/bin/env python3
"""Exercise the release ledger through its public command-line interface."""

import copy
from contextlib import redirect_stderr, redirect_stdout
import hashlib
import importlib.util
import io
import itertools
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


CLI = Path(__file__).resolve().parents[1] / "ux-validation.py"
sys.path.insert(0, str(CLI.parent))
from ux_validation.ledger import inspect_ledger, load_ledger

# Synthetic identities and data are only written into TemporaryDirectory fixtures.
CURRENT_COMMIT = "a" * 40
PREVIOUS_COMMIT = "b" * 40
VERSION = "test-release"
# Bound hangs without using timing to determine the order of concurrent writers.
PROCESS_TIMEOUT_SECONDS = 15


def record_with_process_gates(ledger_path, observation, gates):
    from ux_validation import ledger as ledger_module

    original_load = ledger_module.load_ledger
    original_lock = ledger_module.fcntl.flock

    def load_with_gate(path):
        ledger = original_load(path)
        if "loaded" in gates:
            gates["loaded"].set()
            if not gates["continue"].wait(PROCESS_TIMEOUT_SECONDS):
                raise RuntimeError("Concurrent writer test did not release the first read")
        return ledger

    def lock_with_gate(descriptor, operation):
        if operation == ledger_module.fcntl.LOCK_EX and "attempted_lock" in gates:
            gates["attempted_lock"].set()
        return original_lock(descriptor, operation)

    with patch.object(ledger_module, "load_ledger", load_with_gate):
        with patch.object(ledger_module.fcntl, "flock", lock_with_gate):
            ledger_module.record_case(ledger_path, **observation)


def stop_process(process):
    if process.is_alive():
        process.terminate()
    process.join(PROCESS_TIMEOUT_SECONDS)


def initialize_with_process_gate(arguments, constructed):
    from ux_validation import ledger as ledger_module

    specification = importlib.util.spec_from_file_location("ux_validation_cli", CLI)
    command = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(command)
    original_new_ledger = ledger_module.new_ledger

    def construct_with_gate(target):
        ledger = original_new_ledger(target)
        constructed.wait(PROCESS_TIMEOUT_SECONDS)
        return ledger

    with patch.object(ledger_module, "new_ledger", construct_with_gate):
        with patch.object(sys, "argv", [str(CLI), *arguments]):
            with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                raise SystemExit(command.main())


class ValidationLedgerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.artifact = self.directory / "fixture.deb"
        self.artifact.write_bytes(b"synthetic distribution fixture\n")
        self.ledger = self.directory / "validation.json"
        self.environment_file = self.directory / "environment.json"
        self.evidence = self.directory / "evidence.log"
        self.evidence.write_text("synthetic acceptance evidence\n", encoding="utf-8")
        self.metrics_file = self.directory / "metrics.json"
        self.write_json(self.metrics_file, self.complete_metrics())
        self.initialize()
        self.environment = {
            **self.read_json(self.environment_file),
            "os_version": "24.04.3",
            "session": "x11",
            "session_version": "Xorg 21.1.11",
            "execution": "vm",
            "hardware": "Synthetic KVM fixture; 2 vCPU; 6 GiB",
            "hardware_vendor": "generic",
            "app": "gtk",
            "app_name": "Synthetic GTK editor",
            "app_version": "4.14.5",
            "scale": 100,
            "tree_candidates": True,
            "candidate_size": "standard",
        }
        self.write_json(self.environment_file, self.environment)

    def run_cli(self, *arguments, expected_code=0):
        completed = subprocess.run(
            [sys.executable, str(CLI), *(str(argument) for argument in arguments)],
            capture_output=True, text=True, timeout=PROCESS_TIMEOUT_SECONDS,
        )
        self.assertEqual(
            completed.returncode, expected_code,
            f"arguments={arguments}\nstdout={completed.stdout}\nstderr={completed.stderr}",
        )
        return completed

    def initialize(self, *, ledger=None, commit=CURRENT_COMMIT, **overrides):
        options = {
            "artifact": self.artifact, "commit": commit, "version": VERSION,
            "platform": "ubuntu", "architecture": "amd64", "backend": "cpu",
            **overrides,
        }
        arguments = ["init", ledger or self.ledger]
        for option, value in options.items():
            arguments.extend([f"--{option.replace('_', '-')}", value])
        if ledger is None:
            arguments.extend(["--environment-template", self.environment_file])
        return self.run_cli(*arguments)

    def write_json(self, path, content):
        Path(path).write_text(json.dumps(content, ensure_ascii=False), encoding="utf-8")

    def read_json(self, path):
        return json.loads(Path(path).read_text(encoding="utf-8"))

    def record(self, *, case="x11/gtk/100/tree-on/standard/composition", status="pass", expected_code=0, metrics=False):
        arguments = [
            "record", self.ledger, "--case", case, "--status", status,
            "--note", "Synthetic test observation", "--environment", self.environment_file,
            "--evidence", self.evidence,
        ]
        if metrics:
            arguments.extend(["--metrics", self.metrics_file])
        return self.run_cli(*arguments, expected_code=expected_code)

    def check(self, *, ledger=None, expected_code=1, commit=CURRENT_COMMIT, baseline=None):
        arguments = [
            "check", ledger or self.ledger, "--artifact", self.artifact,
            "--commit", commit, "--version", VERSION, "--json",
        ]
        if baseline:
            arguments.extend(["--baseline", baseline])
        return self.read_output(self.run_cli(*arguments, expected_code=expected_code))

    def read_output(self, completed):
        return json.loads(completed.stdout)

    def complete_metrics(self):
        return {
            "measurement_scope": "input-to-ui",
            "fixture_sha256": hashlib.sha256(self.evidence.read_bytes()).hexdigest(),
            "measurement_method": "Synthetic display measurement v1",
            "samples": [
                {
                    "text_length": length, "startup": startup, "live": live, "count": 100,
                    "preedit_ms": {"p50": 1, "p95": 2, "p99": 3},
                    "candidate_ms": {"p50": 4, "p95": 5, "p99": 6},
                    "commit_ms": {"p50": 7, "p95": 8, "p99": 9},
                }
                for length, startup, live in itertools.product(
                    ("short", "long"), ("cold", "warm"), (False, True)
                )
            ],
        }

    def test_new_ledger_keeps_every_required_combination_unverified(self):
        inspection = self.check()
        self.assertEqual(inspection["counts"], {"pass": 0, "fail": 0, "untested": 792, "unsupported": 0})
        self.assertEqual(len(inspection["groups"]), 72)
        self.assertIn("gnome-wayland/qt/200/tree-on/standard/accessibility", inspection["cases"])
        self.assertIn("gnome-wayland/qt/200/tree-off/large/accessibility", inspection["cases"])
        self.assertFalse(inspection["complete"])
        self.assertEqual(
            self.read_json(self.ledger)["target"]["artifact"]["sha256"],
            hashlib.sha256(self.artifact.read_bytes()).hexdigest(),
        )

    def test_verified_observation_is_preserved_but_remaining_cases_block_completion(self):
        self.record()
        inspection = self.check()
        self.assertEqual(inspection["counts"]["pass"], 1)
        self.assertEqual(inspection["counts"]["untested"], 791)
        self.assertFalse(inspection["complete"])
        entry = self.read_json(self.ledger)["cases"]["x11/gtk/100/tree-on/standard/composition"]
        self.assertEqual(entry["environment"]["app_version"], "4.14.5")
        self.assertTrue(entry["recorded_at"].endswith("+09:00"))

    def test_pass_without_evidence_is_rejected_without_changing_the_ledger(self):
        before = self.ledger.read_bytes()
        completed = self.run_cli(
            "record", self.ledger, "--case", "x11/gtk/100/tree-on/standard/composition", "--status", "pass",
            "--note", "No evidence", "--environment", self.environment_file, expected_code=2,
        )
        self.assertIn("証跡がありません", completed.stderr)
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_empty_or_wrong_environment_is_not_accepted_as_a_pass(self):
        changes = (
            {"os_version": ""},
            {"os_version": "26.04"},
            {"app_version": "未確認"},
            {"commit": PREVIOUS_COMMIT},
            {"artifact_sha256": "0" * 64},
            {"backend": "dictionary"},
            {"architecture": "arm64"},
            {"execution": "container", "session_version": "Xvfb"},
            {"execution": "vm", "session_version": "Xvfb 21.1.11"},
            {"session_version": "Xorg 21.1.11 (headless)"},
            {"app": "qt"},
            {"scale": 150},
            {"tree_candidates": ""},
            {"tree_candidates": False},
            {"candidate_size": "large"},
        )
        for change in changes:
            with self.subTest(change=change):
                self.write_json(self.environment_file, {**self.environment, **change})
                self.record(expected_code=2)
        self.assertEqual(self.check()["counts"]["pass"], 0)

    def test_all_tree_and_size_settings_need_separate_observations(self):
        for tree_mode, candidate_size in itertools.product(
            ("tree-on", "tree-off"), ("standard", "large")
        ):
            self.write_json(self.environment_file, {
                **self.environment,
                "tree_candidates": tree_mode == "tree-on",
                "candidate_size": candidate_size,
            })
            self.record(case=f"x11/gtk/100/{tree_mode}/{candidate_size}/composition")
        inspection = self.check()
        self.assertEqual(inspection["counts"]["pass"], 4)
        self.assertFalse(inspection["complete"])

    def test_screen_reader_and_wayland_session_must_be_observed(self):
        wayland_environment = {
            **self.environment, "session": "gnome-wayland",
            "session_version": "GNOME 46.0",
        }
        self.write_json(self.environment_file, wayland_environment)
        self.record(case="gnome-wayland/gtk/100/tree-on/standard/accessibility", expected_code=2)
        wayland_environment.update(screen_reader="Orca", screen_reader_version="46.0")
        self.write_json(self.environment_file, wayland_environment)
        self.record(case="gnome-wayland/gtk/100/tree-on/standard/accessibility")
        wayland_environment["session_version"] = "GNOME 48.0"
        self.write_json(self.environment_file, wayland_environment)
        self.record(case="gnome-wayland/gtk/100/tree-on/standard/accessibility", expected_code=2)

    def test_modified_or_missing_evidence_invalidates_an_earlier_pass(self):
        self.record()
        self.evidence.write_text("changed evidence\n", encoding="utf-8")
        inspection = self.check(expected_code=2)
        self.assertEqual(inspection["counts"]["pass"], 0)
        self.assertIn("変更されています", str(inspection["cases"]))
        self.evidence.unlink()
        inspection = self.check(expected_code=2)
        self.assertEqual(inspection["counts"]["untested"], 792)

    def test_distribution_changes_and_other_release_identity_cannot_reuse_a_pass(self):
        self.record()
        inspection = self.check(expected_code=2, commit=PREVIOUS_COMMIT)
        self.assertIn("commit", " ".join(inspection["target_errors"]))
        self.artifact.write_bytes(b"new distribution\n")
        inspection = self.check(expected_code=2)
        self.assertEqual(inspection["counts"]["pass"], 0)
        self.assertFalse(inspection["complete"])

    def test_deleted_matrix_rows_and_blank_results_are_not_success(self):
        ledger = self.read_json(self.ledger)
        ledger["cases"].pop("gnome-wayland/qt/200/tree-on/standard/composition")
        self.write_json(self.ledger, ledger)
        self.run_cli("summary", self.ledger, expected_code=2)
        ledger["cases"]["gnome-wayland/qt/200/tree-on/standard/composition"] = {"status": ""}
        self.write_json(self.ledger, ledger)
        self.assertEqual(self.check(expected_code=2)["counts"]["pass"], 0)

    def test_failures_and_unsupported_cases_remain_distinct_and_block_completion(self):
        self.record(status="fail")
        self.record(case="x11/gtk/100/tree-on/standard/reconversion", status="unsupported")
        counts = self.check()["counts"]
        self.assertEqual(counts["fail"], 1)
        self.assertEqual(counts["unsupported"], 1)
        self.assertEqual(counts["pass"], 0)

    def test_initialization_never_overwrites_existing_evidence(self):
        before = self.ledger.read_bytes()
        self.run_cli(
            "init", self.ledger, "--artifact", self.artifact, "--commit", CURRENT_COMMIT,
            "--version", VERSION, "--platform", "ubuntu", "--architecture", "amd64",
            "--backend", "cpu", expected_code=2,
        )
        self.assertEqual(self.ledger.read_bytes(), before)

    def test_concurrent_initializations_create_only_one_ledger(self):
        context = multiprocessing.get_context("spawn")
        constructed = context.Barrier(2)
        new_ledger_path = self.directory / "concurrent-init.json"
        arguments = [
            "init", str(new_ledger_path), "--artifact", str(self.artifact),
            "--commit", CURRENT_COMMIT, "--platform", "ubuntu",
            "--architecture", "amd64", "--backend", "cpu",
        ]
        processes = [
            context.Process(
                target=initialize_with_process_gate,
                args=([*arguments, "--version", version], constructed),
            )
            for version in ("first-initialization", "second-initialization")
        ]
        for process in processes:
            process.start()
            self.addCleanup(stop_process, process)
        for process in processes:
            process.join(PROCESS_TIMEOUT_SECONDS)
            self.assertIsNotNone(process.exitcode, "Concurrent initialization did not finish")
        self.assertEqual(sorted(process.exitcode for process in processes), [0, 2])
        self.assertEqual(len(self.read_json(new_ledger_path)["cases"]), 792)

    def test_self_references_are_rejected_before_the_ledger_changes(self):
        before = self.ledger.read_bytes()
        aliases = [self.ledger, self.environment_file, self.metrics_file]
        symbolic_alias = self.directory / "ledger-symlink.json"
        symbolic_alias.symlink_to(self.ledger)
        aliases.append(symbolic_alias)
        hard_alias = self.directory / "ledger-hardlink.json"
        os.link(self.ledger, hard_alias)
        aliases.append(hard_alias)
        aliases.append(self.ledger.with_name(self.ledger.name + ".lock"))
        for path in aliases:
            with self.subTest(evidence=path):
                completed = self.run_cli(
                    "record", self.ledger, "--case", "x11/gtk/100/tree-on/standard/latency",
                    "--status", "pass", "--note", "Self reference",
                    "--environment", self.environment_file, "--evidence", path,
                    "--metrics", self.metrics_file, expected_code=2,
                )
                self.assertIn("自身を指定できません", completed.stderr)
                self.assertEqual(self.ledger.read_bytes(), before)
        for option in ("--environment", "--metrics"):
            with self.subTest(option=option):
                self.run_cli(
                    "record", self.ledger, "--case", "x11/gtk/100/tree-on/standard/latency",
                    "--status", "pass", "--note", "Self reference",
                    "--evidence", self.evidence, option, symbolic_alias, expected_code=2,
                )
                self.assertEqual(self.ledger.read_bytes(), before)

    def test_concurrent_writers_preserve_both_the_failure_and_the_other_result(self):
        context = multiprocessing.get_context("spawn")
        loaded = context.Event()
        continue_writing = context.Event()
        attempted_lock = context.Event()
        common = {
            "note": "Concurrent synthetic observation",
            "environment": self.environment_file, "evidence": [self.evidence],
        }
        first = context.Process(target=record_with_process_gates, args=(
            self.ledger,
            {**common, "case_id": "x11/gtk/100/tree-on/standard/composition", "status": "fail"},
            {"loaded": loaded, "continue": continue_writing},
        ))
        second = context.Process(target=record_with_process_gates, args=(
            self.ledger,
            {**common, "case_id": "x11/gtk/100/tree-on/standard/cancel", "status": "pass"},
            {"attempted_lock": attempted_lock},
        ))
        first.start()
        self.addCleanup(stop_process, first)
        try:
            self.assertTrue(loaded.wait(PROCESS_TIMEOUT_SECONDS), "First writer did not read the ledger")
            second.start()
            self.addCleanup(stop_process, second)
            self.assertTrue(
                attempted_lock.wait(PROCESS_TIMEOUT_SECONDS), "Second writer did not request the lock"
            )
        finally:
            continue_writing.set()
        for process in (first, second):
            process.join(PROCESS_TIMEOUT_SECONDS)
            self.assertEqual(process.exitcode, 0)
        inspection = self.check()
        self.assertEqual(inspection["counts"]["fail"], 1)
        self.assertEqual(inspection["counts"]["pass"], 1)
        self.assertFalse(inspection["complete"])

    def test_macos_cpu_and_metal_separate_apple_vm_and_physical_results(self):
        cpu_ledger = self.directory / "mac-cpu.json"
        self.initialize(ledger=cpu_ledger, platform="macos", architecture="arm64")
        self.assertIn("apple-vm/safari/200/tree-on/standard/composition", self.read_json(cpu_ledger)["cases"])
        metal_ledger = self.directory / "mac-metal.json"
        self.initialize(
            ledger=metal_ledger, platform="macos", architecture="arm64", backend="metal"
        )
        self.assertEqual(len(self.read_json(metal_ledger)["cases"]), 396)
        self.assertFalse(any(case.startswith("apple-vm/") for case in self.read_json(metal_ledger)["cases"]))
        self.ledger = cpu_ledger
        self.environment.update(
            platform="macos", architecture="arm64", os_version="26.0", session="aqua",
            session_version="26.0", execution="apple-vm", app="textedit",
            app_name="TextEdit", app_version="1.20",
        )
        self.write_json(self.environment_file, self.environment)
        self.record(case="apple-vm/textedit/100/tree-on/standard/composition", expected_code=2)
        self.environment["hardware_vendor"] = "Apple"
        self.write_json(self.environment_file, self.environment)
        self.record(case="apple-vm/textedit/100/tree-on/standard/composition")
        self.record(case="physical/textedit/100/tree-on/standard/composition", expected_code=2)

    def test_incomplete_or_bridge_only_latency_is_not_a_ui_measurement(self):
        metrics = self.complete_metrics()
        variants = []
        bridge_only = copy.deepcopy(metrics)
        bridge_only["measurement_scope"] = "bridge-roundtrip"
        variants.append(bridge_only)
        missing_percentile = copy.deepcopy(metrics)
        del missing_percentile["samples"][0]["preedit_ms"]["p99"]
        variants.append(missing_percentile)
        missing_condition = copy.deepcopy(metrics)
        missing_condition["samples"].pop()
        variants.append(missing_condition)
        missing_endpoint = copy.deepcopy(metrics)
        del missing_endpoint["samples"][0]["commit_ms"]
        variants.append(missing_endpoint)
        for variant in variants:
            with self.subTest(variant=variant):
                self.write_json(self.metrics_file, variant)
                self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True, expected_code=2)
        self.write_json(self.metrics_file, metrics)
        self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True)
        self.assertEqual(self.check()["counts"]["pass"], 1)
        self.write_json(self.metrics_file, missing_percentile)
        self.assertEqual(self.check(expected_code=2)["counts"]["pass"], 0)

    def test_performance_can_compare_another_commit_only_in_the_same_environment(self):
        self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True)
        baseline = self.directory / "baseline.json"
        previous_ledger = self.read_json(self.ledger)
        previous_ledger["target"]["commit"] = PREVIOUS_COMMIT
        previous_ledger["target"]["version"] = "previous-test-release"
        previous_entry = previous_ledger["cases"]["x11/gtk/100/tree-on/standard/latency"]
        previous_entry["environment"]["commit"] = PREVIOUS_COMMIT
        previous_entry["environment"]["version"] = "previous-test-release"
        self.write_json(baseline, previous_ledger)
        inspection = self.check(baseline=baseline)
        self.assertEqual(len(inspection["comparisons"]), 8)
        self.assertEqual(inspection["comparisons"][0]["delta_ms"]["preedit_ms"]["p99"], 0)
        previous_entry["environment"]["hardware"] = "A different physical machine"
        self.write_json(baseline, previous_ledger)
        inspection = self.check(baseline=baseline, expected_code=2)
        self.assertIn("hardware", " ".join(inspection["target_errors"]))
        self.assertFalse(inspection["complete"])

    def complete_matrix_fixture(self):
        self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True)
        ledger = self.read_json(self.ledger)
        observed = ledger["cases"]["x11/gtk/100/tree-on/standard/latency"]
        for case_id in ledger["cases"]:
            session, app, scale, tree_mode, candidate_size, scenario = case_id.split("/")
            entry = copy.deepcopy(observed)
            entry["environment"].update(
                session=session, app=app, app_name=f"Synthetic {app} editor", scale=int(scale),
                tree_candidates=tree_mode == "tree-on", candidate_size=candidate_size,
                session_version="GNOME 46.0" if session == "gnome-wayland" else "Xorg 21.1.11",
            )
            if scenario == "accessibility":
                entry["environment"].update(screen_reader="Orca", screen_reader_version="46.0")
            if scenario != "latency":
                del entry["metrics"]
            ledger["cases"][case_id] = entry
        self.write_json(self.ledger, ledger)

    def test_only_a_complete_valid_matrix_passes_the_release_check(self):
        self.complete_matrix_fixture()
        inspection = self.check(expected_code=0)
        self.assertTrue(inspection["complete"])
        self.assertEqual(inspection["counts"]["pass"], 792)

    def test_shared_video_evidence_is_read_once_per_check_and_changes_are_rechecked(self):
        self.complete_matrix_fixture()
        original_open = Path.open
        evidence_reads = []

        def track_evidence_reads(path, *arguments, **keywords):
            if path.resolve() == self.evidence and arguments and arguments[0] == "rb":
                evidence_reads.append(path)
            return original_open(path, *arguments, **keywords)

        with patch.object(Path, "open", track_evidence_reads):
            self.assertTrue(inspect_ledger(load_ledger(self.ledger), self.ledger)["complete"])
        self.assertEqual(len(evidence_reads), 1)
        self.evidence.write_text("changed after the earlier check\n", encoding="utf-8")
        self.assertFalse(inspect_ledger(load_ledger(self.ledger), self.ledger)["complete"])

    def test_nonfinite_numbers_and_malformed_types_return_clean_errors(self):
        original_ledger = self.ledger.read_text(encoding="utf-8")
        malformed_documents = (
            original_ledger.replace('"format":', '"nonfinite": NaN, "format":', 1),
            original_ledger.replace('"format":', '"nonfinite": Infinity, "format":', 1),
            original_ledger.replace('"format":', '"nonfinite": 1e999, "format":', 1),
            json.dumps({"format": "azookey-ux-validation-1", "target": []}),
        )
        for document in malformed_documents:
            with self.subTest(document=document[:80]):
                self.ledger.write_text(document, encoding="utf-8")
                completed = self.run_cli("summary", self.ledger, expected_code=2)
                self.assertNotIn("Traceback", completed.stderr)
        self.ledger.write_text(original_ledger, encoding="utf-8")
        self.write_json(self.environment_file, [])
        completed = self.record(expected_code=2)
        self.assertNotIn("Traceback", completed.stderr)
        self.write_json(self.environment_file, self.environment)
        metrics = self.complete_metrics()
        metrics["samples"][0]["preedit_ms"]["p50"] = 10 ** 1000
        self.write_json(self.metrics_file, metrics)
        self.assertNotIn(
            "Traceback", self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True, expected_code=2).stderr
        )

    def test_different_fixed_inputs_and_measurement_methods_are_not_compared(self):
        self.record(case="x11/gtk/100/tree-on/standard/latency", metrics=True)
        baseline_path = self.directory / "baseline-method.json"
        baseline = self.read_json(self.ledger)
        previous_entry = baseline["cases"]["x11/gtk/100/tree-on/standard/latency"]
        previous_metrics = self.complete_metrics()
        previous_metrics_path = self.directory / "previous-metrics.json"

        def reference(path):
            return {
                "path": path.name,
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "size": path.stat().st_size,
            }

        previous_metrics["measurement_method"] = "Another measurement method"
        self.write_json(previous_metrics_path, previous_metrics)
        previous_entry["metrics"] = reference(previous_metrics_path)
        self.write_json(baseline_path, baseline)
        inspection = self.check(baseline=baseline_path, expected_code=2)
        self.assertIn("measurement_method", " ".join(inspection["target_errors"]))

        previous_metrics["measurement_method"] = "Synthetic display measurement v1"
        other_fixture = self.directory / "other-inputs.txt"
        other_fixture.write_text("different synthetic fixed inputs\n", encoding="utf-8")
        previous_metrics["fixture_sha256"] = reference(other_fixture)["sha256"]
        self.write_json(previous_metrics_path, previous_metrics)
        previous_entry["metrics"] = reference(previous_metrics_path)
        previous_entry["evidence"].append(reference(other_fixture))
        self.write_json(baseline_path, baseline)
        inspection = self.check(baseline=baseline_path, expected_code=2)
        self.assertIn("fixture_sha256", " ".join(inspection["target_errors"]))


if __name__ == "__main__":
    unittest.main()
