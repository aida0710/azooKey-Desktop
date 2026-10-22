"""Fixed desktop acceptance cases and their required observation fields."""

import math
import re
from itertools import product


FORMAT = "azookey-ux-validation-1"
STATUSES = ("pass", "fail", "untested", "unsupported")
STATUS_LABELS = dict(zip(STATUSES, ("合格", "不合格", "未検証", "非対応")))
# Issue #27 requires the supported desktop applications at these display scales.
SCALES = (100, 150, 200)
TREE_MODES = {"tree-on": True, "tree-off": False}
CANDIDATE_SIZES = ("standard", "large")
SCENARIOS = (
    "composition", "pointer", "cancel", "focus", "reconversion", "dictionary",
    "recovery", "privacy", "accessibility", "appearance", "latency",
)
BUILD_FIELDS = ("artifact_sha256", "commit", "version", "platform", "architecture", "backend")
ENVIRONMENT_TEXT_FIELDS = (
    "os_version", "session", "session_version", "execution", "hardware",
    "hardware_vendor", "app", "app_name", "app_version",
)
ENVIRONMENT_FIELDS = (
    *BUILD_FIELDS, *ENVIRONMENT_TEXT_FIELDS, "scale", "tree_candidates", "candidate_size",
)
UNOBSERVED_VALUES = {"", "unknown", "unverified", "untested", "tbd", "n/a", "未確認", "未検証", "不明"}
PERCENTILES = ("p50", "p95", "p99")
LATENCY_ENDPOINTS = ("preedit_ms", "candidate_ms", "commit_ms")
# Each endpoint needs independent measurements for all eight workload conditions.
LATENCY_CONDITIONS = {
    (length, startup, live)
    for length in ("short", "long")
    for startup in ("cold", "warm")
    for live in (False, True)
}


class ValidationError(ValueError):
    """The requested result cannot be supported by the supplied evidence."""


def is_observed_text(value):
    return isinstance(value, str) and value.strip().casefold() not in UNOBSERVED_VALUES


def validate_target(target):
    if not isinstance(target, dict):
        raise ValidationError("target はオブジェクトで指定してください")
    if not re.fullmatch(r"[0-9a-f]{40}", str(target.get("commit", ""))):
        raise ValidationError("commit は省略しない40桁の小文字Git SHAで指定してください")
    if not is_observed_text(target.get("version")):
        raise ValidationError("配布物の version が未記入です")
    if target.get("platform") not in ("ubuntu", "macos"):
        raise ValidationError("platform は ubuntu または macos です")
    if target.get("architecture") not in ("amd64", "arm64"):
        raise ValidationError("architecture は amd64 または arm64 です")
    if target.get("backend") not in ("dictionary", "cpu", "metal"):
        raise ValidationError("backend は dictionary、cpu、metal のいずれかです")
    if target["platform"] == "macos" and target["architecture"] != "arm64":
        raise ValidationError("このmacOS検証計画の対象は arm64 です")
    if target["platform"] == "ubuntu" and target["backend"] == "metal":
        raise ValidationError("UbuntuでMetalを検証済みとして記録することはできません")


def build_identity(target):
    return {
        "artifact_sha256": target["artifact"]["sha256"],
        **{field: target[field] for field in BUILD_FIELDS if field != "artifact_sha256"},
    }


def case_specs(target):
    if target["platform"] == "ubuntu":
        slots = ("x11", "gnome-wayland")
        apps = ("gtk", "qt", "chromium")
    else:
        slots = ("physical",) if target["backend"] == "metal" else ("physical", "apple-vm")
        apps = ("textedit", "safari", "chromium")
    return {
        f"{slot}/{app}/{scale}/{tree_mode}/{candidate_size}/{scenario}": {
            "slot": slot, "app": app, "scale": scale, "scenario": scenario,
            "tree_candidates": TREE_MODES[tree_mode], "candidate_size": candidate_size,
        }
        for slot, app, scale, tree_mode, candidate_size, scenario in product(
            slots, apps, SCALES, TREE_MODES, CANDIDATE_SIZES, SCENARIOS
        )
    }


def environment_template(target):
    return {
        **build_identity(target),
        **{field: "" for field in ENVIRONMENT_TEXT_FIELDS},
        "scale": None,
        "tree_candidates": None,
        "candidate_size": "",
    }


def environment_errors(environment, target, case):
    if not isinstance(environment, dict):
        return ["environment が未記入です"]
    errors = []
    allowed_fields = set(ENVIRONMENT_FIELDS) | {"screen_reader", "screen_reader_version"}
    if unexpected := set(environment) - allowed_fields:
        errors.append(f"未定義の環境項目: {', '.join(sorted(unexpected))}")
    for field, expected in build_identity(target).items():
        if environment.get(field) != expected:
            errors.append(f"検証した配布物の {field} が台帳の対象と一致しません")
    for field in ENVIRONMENT_TEXT_FIELDS:
        if not is_observed_text(environment.get(field)):
            errors.append(f"環境の {field} が未確認です")
    if environment.get("app") != case["app"]:
        errors.append("検証したアプリがcase IDと一致しません")
    if type(environment.get("scale")) is not int or environment["scale"] != case["scale"]:
        errors.append("表示倍率がcase IDと一致しません")
    if (
        type(environment.get("tree_candidates")) is not bool
        or environment["tree_candidates"] != case["tree_candidates"]
    ):
        errors.append("tree_candidates はcase IDと一致する true/false を記録してください")
    if environment.get("candidate_size") != case["candidate_size"]:
        errors.append("candidate_size がcase IDと一致しません")
    if target["platform"] == "ubuntu":
        if environment.get("execution") not in ("physical", "vm"):
            errors.append("Docker/Xvfbの結果をデスクトップVM・実機の結果に代用できません")
        if environment.get("session") != case["slot"]:
            errors.append("デスクトップセッションがcase IDと一致しません")
        if not re.fullmatch(r"24\.04(?:\.\d+)?(?: LTS)?", str(environment.get("os_version", ""))):
            errors.append("Ubuntuの対象環境は24.04です")
        session_version = str(environment.get("session_version", ""))
        if case["slot"] == "x11" and (
            not re.fullmatch(r"Xorg \d+(?:\.\d+)+(?: \([^()]+\))?", session_version)
            or any(marker in session_version.casefold() for marker in ("xvfb", "headless"))
        ):
            errors.append("X11は実デスクトップのXorg版を記録してください。Xvfbは代用できません")
        if case["slot"] == "gnome-wayland" and not re.match(
            r"^GNOME 46(?:[.\s]|$)", session_version
        ):
            errors.append("GNOME WaylandはGNOME 46の実セッションを記録してください")
    else:
        if environment.get("session") != "aqua":
            errors.append("macOS実入力の検証にはAquaセッションが必要です")
        if environment.get("execution") != case["slot"]:
            errors.append("macOSの実機とAppleハードウェア上のVMを区別してください")
        if environment.get("hardware_vendor") != "Apple":
            errors.append("macOSの検証先はAppleハードウェアです")
    if case["scenario"] == "accessibility":
        reader = "Orca" if target["platform"] == "ubuntu" else "VoiceOver"
        if environment.get("screen_reader") != reader:
            errors.append(f"{reader}の実際の読み上げ・確定結果が必要です")
        if not is_observed_text(environment.get("screen_reader_version")):
            errors.append("screen_reader_version が未確認です")
    return errors


def metrics_errors(metrics):
    if not isinstance(metrics, dict) or metrics.get("measurement_scope") != "input-to-ui":
        return ["性能値は input-to-ui の実測が必要です。bridge往復時間で代用できません"]
    errors = []
    if not re.fullmatch(r"[0-9a-f]{64}", str(metrics.get("fixture_sha256", ""))):
        errors.append("性能測定に使った固定入力ファイルの fixture_sha256 がありません")
    if not is_observed_text(metrics.get("measurement_method")):
        errors.append("計測方法・ツール版の measurement_method が未確認です")
    samples = metrics.get("samples")
    if not isinstance(samples, list):
        return errors + ["性能値の samples が未記入です"]
    conditions = set()
    for index, sample in enumerate(samples):
        if not isinstance(sample, dict):
            errors.append(f"性能条件 {index} がオブジェクトではありません")
            continue
        condition = (sample.get("text_length"), sample.get("startup"), sample.get("live"))
        if (
            not isinstance(condition[0], str)
            or not isinstance(condition[1], str)
            or type(condition[2]) is not bool
            or condition not in LATENCY_CONDITIONS
        ):
            errors.append(f"性能条件 {index} の長さ・起動状態・liveが不正です")
            continue
        if condition in conditions:
            errors.append(f"性能条件 {condition} が重複しています")
        conditions.add(condition)
        if type(sample.get("count")) is not int or sample["count"] < 1:
            errors.append(f"性能条件 {condition} の実測件数が未記入です")
        for endpoint in LATENCY_ENDPOINTS:
            values = sample.get(endpoint)
            if not isinstance(values, dict):
                errors.append(f"性能条件 {condition} の {endpoint} が未測定です")
                continue
            percentiles = [values.get(percentile) for percentile in PERCENTILES]
            if not all(is_finite_nonnegative_number(value) for value in percentiles):
                errors.append(f"性能条件 {condition} の {endpoint} はp50/p95/p99の有限な実測値が必要です")
            elif percentiles != sorted(percentiles):
                errors.append(f"性能条件 {condition} の {endpoint} のpercentile順序が不正です")
    if missing := LATENCY_CONDITIONS - conditions:
        errors.append(f"性能条件が未検証です: {sorted(missing)}")
    return errors


def is_finite_nonnegative_number(value):
    if type(value) not in (int, float):
        return False
    try:
        return math.isfinite(value) and value >= 0
    except OverflowError:
        return False
