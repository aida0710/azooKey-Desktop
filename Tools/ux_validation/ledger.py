"""Persist release evidence and verify that recorded observations still apply."""

from collections import Counter
from contextlib import contextmanager
from datetime import datetime
import fcntl
import hashlib
from itertools import combinations
import json
import math
import os
from pathlib import Path
import tempfile
from zoneinfo import ZoneInfo

from .requirements import (
    FORMAT, LATENCY_ENDPOINTS, PERCENTILES, STATUSES, ValidationError,
    case_specs, environment_errors, environment_template, is_observed_text, metrics_errors,
    validate_target,
)


# Stream large package and video files without loading them into memory.
HASH_CHUNK_BYTES = 1024 * 1024


def timestamp():
    return datetime.now(ZoneInfo("Asia/Tokyo")).isoformat(timespec="seconds")


def read_json(path):
    try:
        return json.loads(
            Path(path).read_text(encoding="utf-8"),
            parse_constant=reject_nonfinite_constant,
            parse_float=finite_json_float,
        )
    except (OSError, UnicodeError, ValueError) as error:
        raise ValidationError(f"JSONを読めません: {path}: {error}") from error


def reject_nonfinite_constant(_value):
    raise ValidationError("JSONにNaNやInfinityは使えません")


def finite_json_float(value):
    number = float(value)
    if not math.isfinite(number):
        raise ValidationError("JSONの数値は有限値で指定してください")
    return number


def write_json(path, content):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=path.parent, delete=False
        ) as temporary:
            temporary_path = Path(temporary.name)
            json.dump(content, temporary, ensure_ascii=False, indent=2, allow_nan=False)
            temporary.write("\n")
        temporary_path.replace(path)
    finally:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)


def lock_path(ledger_path):
    path = Path(ledger_path).resolve()
    return path.with_name(path.name + ".lock")


@contextmanager
def ledger_lock(ledger_path):
    path = lock_path(ledger_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Keep this inode after unlocking; deleting it would allow two independent locks.
    with path.open("a") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)


def paths_alias(first, second):
    first, second = Path(first), Path(second)
    return first.resolve() == second.resolve() or (
        first.exists() and second.exists() and first.samefile(second)
    )


def reject_record_aliases(ledger_path, *, environment, evidence, metrics):
    reserved = [Path(ledger_path), lock_path(ledger_path)]
    reserved.extend(Path(path) for path in (environment, metrics) if path is not None)
    for first, second in combinations(reserved, 2):
        if paths_alias(first, second):
            raise ValidationError(f"台帳・ロック・環境・性能値は別のファイルにしてください: {first}, {second}")
    for path in evidence:
        for reserved_path in reserved:
            if paths_alias(path, reserved_path):
                raise ValidationError(f"証跡には台帳・ロック・環境・性能値自身を指定できません: {path}")


def file_reference(path, ledger_path, *, fingerprints=None):
    try:
        path = Path(path).resolve()
        file_stat = path.stat()
        if not path.is_file() or file_stat.st_size == 0:
            raise ValidationError(f"ファイルが存在しないか空です: {path}")
        signature = file_signature(file_stat)
        cached = fingerprints.get(path) if fingerprints is not None else None
        if cached is not None and cached["signature"] == signature:
            digest = cached["sha256"]
        else:
            hasher = hashlib.sha256()
            with path.open("rb") as stream:
                for chunk in iter(lambda: stream.read(HASH_CHUNK_BYTES), b""):
                    hasher.update(chunk)
            if file_signature(path.stat()) != signature:
                raise ValidationError(f"検証中にファイルが変更されました: {path}")
            digest = hasher.hexdigest()
            if fingerprints is not None:
                fingerprints[path] = {"signature": signature, "sha256": digest}
        return {
            "path": os.path.relpath(path, Path(ledger_path).resolve().parent),
            "sha256": digest,
            "size": file_stat.st_size,
        }
    except (OSError, ValueError) as error:
        raise ValidationError(f"ファイルを確認できません: {path}: {error}") from error


def file_signature(file_stat):
    # One video may cover many cases; cache only within a check and invalidate on change.
    return (
        file_stat.st_dev, file_stat.st_ino, file_stat.st_size,
        file_stat.st_mtime_ns, file_stat.st_ctime_ns,
    )


def reference_path(reference, ledger_path):
    if not isinstance(reference, dict) or not isinstance(reference.get("path"), str):
        raise ValidationError("ファイルの記録が不正です")
    return Path(ledger_path).resolve().parent / reference["path"]


def verify_reference(reference, ledger_path, *, fingerprints=None):
    path = reference_path(reference, ledger_path)
    observed = file_reference(path, ledger_path, fingerprints=fingerprints)
    if observed["sha256"] != reference.get("sha256") or observed["size"] != reference.get("size"):
        raise ValidationError(f"記録後にファイルが変更されています: {path}")
    return path


def new_ledger(target):
    validate_target(target)
    return {
        "format": FORMAT,
        "created_at": timestamp(),
        "target": target,
        "cases": {case_id: {"status": "untested"} for case_id in case_specs(target)},
    }


def initialize_ledger(ledger_path, *, target, environment_path=None):
    ledger_path = Path(ledger_path)
    outputs = [ledger_path]
    if environment_path is not None:
        outputs.append(Path(environment_path))
    if len(outputs) == 2 and paths_alias(*outputs):
        raise ValidationError("台帳と環境ひな形は別のファイルへ保存してください")
    if any(paths_alias(path, lock_path(ledger_path)) for path in outputs):
        raise ValidationError("台帳・環境ひな形をロックファイルと同じ場所に保存できません")
    ledger = new_ledger(target)
    with ledger_lock(ledger_path):
        for path in outputs:
            if path.exists():
                raise ValidationError(f"既存の記録を上書きしません: {path}")
        write_json(ledger_path, ledger)
        if environment_path is not None:
            write_json(environment_path, environment_template(target))
    return ledger


def load_ledger(path):
    ledger = read_json(path)
    if not isinstance(ledger, dict) or ledger.get("format") != FORMAT:
        raise ValidationError(f"検証台帳のformatが不正です: {path}")
    validate_target(ledger.get("target"))
    target = ledger["target"]
    if not isinstance(target.get("artifact"), dict):
        raise ValidationError("対象配布物の記録がありません")
    if not isinstance(target["artifact"].get("sha256"), str):
        raise ValidationError("対象配布物のSHA256がありません")
    expected_cases = set(case_specs(target))
    cases = ledger.get("cases")
    if not isinstance(cases, dict) or set(cases) != expected_cases:
        missing = sorted(expected_cases - set(cases or {})) if isinstance(cases, dict) else []
        raise ValidationError(f"受入マトリクスの行が追加・削除されています。欠落: {missing}")
    return ledger


def entry_errors(entry, *, case, target, ledger_path, fingerprints=None):
    if not isinstance(entry, dict) or entry.get("status") not in STATUSES:
        return ["合格/不合格/未検証/非対応の状態が明示されていません"]
    if entry["status"] == "untested":
        return []
    errors = []
    if not is_observed_text(entry.get("note")):
        errors.append("結果または非対応理由が未記入です")
    try:
        if datetime.fromisoformat(entry.get("recorded_at", "")).tzinfo is None:
            errors.append("記録日時にタイムゾーンがありません")
    except (TypeError, ValueError):
        errors.append("記録日時がありません")
    if entry["status"] in ("pass", "fail") or entry.get("environment") is not None:
        errors.extend(environment_errors(entry.get("environment"), target, case))
    evidence = entry.get("evidence")
    if not isinstance(evidence, list) or not evidence:
        errors.append("証跡がありません")
    else:
        for reference in evidence:
            try:
                verify_reference(reference, ledger_path, fingerprints=fingerprints)
            except ValidationError as error:
                errors.append(str(error))
    requires_metrics = case["scenario"] == "latency" and entry["status"] == "pass"
    if requires_metrics or "metrics" in entry:
        try:
            metrics_path = verify_reference(entry.get("metrics"), ledger_path, fingerprints=fingerprints)
            if requires_metrics:
                metrics = read_json(metrics_path)
                errors.extend(metrics_errors(metrics))
                fixture_hash = metrics.get("fixture_sha256") if isinstance(metrics, dict) else None
                if not fixture_hash or not isinstance(evidence, list) or not any(
                    isinstance(reference, dict) and reference.get("sha256") == fixture_hash
                    for reference in evidence
                ):
                    errors.append("性能測定の固定入力ファイルを --evidence に含めてください")
        except ValidationError as error:
            errors.append(f"性能は未検証です: {error}")
    return errors


def record_case(ledger_path, *, case_id, status, note, environment=None, evidence=(), metrics=None):
    ledger_path = Path(ledger_path).resolve()
    reject_record_aliases(
        ledger_path, environment=environment, evidence=evidence, metrics=metrics,
    )
    with ledger_lock(ledger_path):
        ledger = load_ledger(ledger_path)
        fingerprints = {}
        verify_reference(ledger["target"]["artifact"], ledger_path, fingerprints=fingerprints)
        if case_id not in ledger["cases"]:
            raise ValidationError(f"受入マトリクスにないcase IDです: {case_id}")
        case = case_specs(ledger["target"])[case_id]
        entry = observation_entry(
            ledger_path, status=status, note=note, environment=environment,
            evidence=evidence, metrics=metrics, fingerprints=fingerprints,
        )
        if metrics is not None and case["scenario"] != "latency":
            raise ValidationError("--metrics は latency ケースだけに使えます")
        errors = entry_errors(
            entry, case=case, target=ledger["target"], ledger_path=ledger_path,
            fingerprints=fingerprints,
        )
        if errors:
            raise ValidationError("\n".join(errors))
        ledger["cases"][case_id] = entry
        write_json(ledger_path, ledger)


def observation_entry(ledger_path, *, status, note, environment, evidence, metrics, fingerprints):
    entry = {
        "status": status,
        "recorded_at": timestamp(),
        "note": note,
        "environment": read_json(environment) if environment else None,
        "evidence": [file_reference(path, ledger_path, fingerprints=fingerprints) for path in evidence],
    }
    if metrics is not None:
        entry["metrics"] = file_reference(metrics, ledger_path, fingerprints=fingerprints)
    return entry


def inspect_ledger(ledger, ledger_path):
    target_errors = []
    fingerprints = {}
    try:
        verify_reference(ledger["target"]["artifact"], ledger_path, fingerprints=fingerprints)
    except ValidationError as error:
        target_errors.append(str(error))
    counts = Counter({status: 0 for status in STATUSES})
    groups = {}
    inspected_cases = {}
    for case_id, case in case_specs(ledger["target"]).items():
        entry = ledger["cases"][case_id]
        errors = entry_errors(
            entry, case=case, target=ledger["target"], ledger_path=ledger_path,
            fingerprints=fingerprints,
        )
        status = entry.get("status", "untested") if isinstance(entry, dict) else "untested"
        if errors or target_errors:
            status = "untested"
        counts[status] += 1
        group_id = case_id.rsplit("/", 1)[0]
        group = groups.setdefault(group_id, Counter({status: 0 for status in STATUSES}))
        group[status] += 1
        inspected_cases[case_id] = {"status": status, "errors": errors}
    return {
        "target": ledger["target"],
        "counts": dict(counts),
        "groups": {group_id: dict(counts) for group_id, counts in groups.items()},
        "cases": inspected_cases,
        "target_errors": target_errors,
        "complete": counts["pass"] == len(ledger["cases"]) and not target_errors,
    }


def expected_target_errors(ledger, *, artifact, commit, version, ledger_path):
    expected = file_reference(artifact, ledger_path)
    target = ledger["target"]
    errors = []
    if expected["sha256"] != target["artifact"]["sha256"]:
        errors.append("指定した配布物は、この台帳で検証した配布物と異なります")
    if commit != target["commit"]:
        errors.append("指定したcommitは、この台帳で検証したcommitと異なります")
    if version != target["version"]:
        errors.append("指定したversionは、この台帳で検証したversionと異なります")
    return errors


def compare_latency(ledger, *, ledger_path, baseline_path, inspection):
    baseline = load_ledger(baseline_path)
    previous_inspection = inspect_ledger(baseline, baseline_path)
    if previous_inspection["target_errors"]:
        raise ValidationError("比較元の配布物を検証できません")
    for field in ("platform", "architecture", "backend"):
        if ledger["target"][field] != baseline["target"][field]:
            raise ValidationError(f"性能を比較できません: {field} が異なります")
    comparisons = []
    for case_id, entry in ledger["cases"].items():
        if not case_id.endswith("/latency") or inspection["cases"][case_id]["status"] != "pass":
            continue
        if previous_inspection["cases"].get(case_id, {}).get("status") != "pass":
            raise ValidationError(f"性能を比較できません: 比較元の {case_id} が未検証です")
        previous = baseline["cases"][case_id]
        # Only the release identity may differ; VM and real hardware results never mix.
        ignored_fields = {"artifact_sha256", "commit", "version"}
        current_environment = {key: value for key, value in entry["environment"].items() if key not in ignored_fields}
        previous_environment = {key: value for key, value in previous["environment"].items() if key not in ignored_fields}
        if current_environment != previous_environment:
            changed = sorted(
                key for key in set(current_environment) | set(previous_environment)
                if current_environment.get(key) != previous_environment.get(key)
            )
            raise ValidationError(f"性能を比較できません: {case_id} の環境が異なります: {', '.join(changed)}")
        current_metrics = read_json(verify_reference(entry["metrics"], ledger_path))
        previous_metrics = read_json(verify_reference(previous["metrics"], baseline_path))
        for field in ("fixture_sha256", "measurement_method"):
            if current_metrics[field] != previous_metrics[field]:
                raise ValidationError(f"性能を比較できません: {case_id} の {field} が異なります")
        previous_samples = {
            (sample["text_length"], sample["startup"], sample["live"]): sample
            for sample in previous_metrics["samples"]
        }
        for sample in current_metrics["samples"]:
            condition = (sample["text_length"], sample["startup"], sample["live"])
            earlier_sample = previous_samples[condition]
            comparisons.append({
                "case": case_id,
                "text_length": sample["text_length"],
                "startup": sample["startup"],
                "live": sample["live"],
                "current_count": sample["count"],
                "baseline_count": earlier_sample["count"],
                "current": {endpoint: sample[endpoint] for endpoint in LATENCY_ENDPOINTS},
                "baseline": {endpoint: earlier_sample[endpoint] for endpoint in LATENCY_ENDPOINTS},
                "delta_ms": {
                    endpoint: {
                        percentile: sample[endpoint][percentile] - earlier_sample[endpoint][percentile]
                        for percentile in PERCENTILES
                    }
                    for endpoint in LATENCY_ENDPOINTS
                },
            })
    return comparisons
