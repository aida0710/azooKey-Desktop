#!/usr/bin/env python3
"""Record evidence for a particular azooKey desktop distribution."""

import argparse
import json
from pathlib import Path
import sys

from ux_validation.ledger import (
    compare_latency, expected_target_errors, file_reference, inspect_ledger,
    initialize_ledger, load_ledger, record_case,
)
from ux_validation.requirements import STATUSES, STATUS_LABELS, ValidationError


def create_parser():
    command_parser = argparse.ArgumentParser(description=__doc__)
    commands = command_parser.add_subparsers(dest="command", required=True)
    initialize = commands.add_parser("init", help="未検証の受入マトリクスを作成")
    initialize.add_argument("ledger", type=Path)
    initialize.add_argument("--artifact", required=True, type=Path)
    initialize.add_argument("--commit", required=True)
    initialize.add_argument("--version", required=True)
    initialize.add_argument("--platform", required=True, choices=("ubuntu", "macos"))
    initialize.add_argument("--architecture", required=True, choices=("amd64", "arm64"))
    initialize.add_argument("--backend", required=True, choices=("dictionary", "cpu", "metal"))
    initialize.add_argument("--environment-template", type=Path)
    record = commands.add_parser("record", help="1シナリオの結果と証跡を記録")
    record.add_argument("ledger", type=Path)
    record.add_argument("--case", required=True, dest="case_id")
    record.add_argument("--status", required=True, choices=STATUSES)
    record.add_argument("--note", required=True)
    record.add_argument("--environment", type=Path)
    record.add_argument("--evidence", type=Path, action="append", default=[])
    record.add_argument("--metrics", type=Path)
    summary = commands.add_parser("summary", help="合格・不合格・未検証・非対応を集計")
    summary.add_argument("ledger", type=Path)
    summary.add_argument("--json", action="store_true")
    check = commands.add_parser("check", help="対象配布物に必要な検証が揃ったか確認")
    check.add_argument("ledger", type=Path)
    check.add_argument("--artifact", required=True, type=Path)
    check.add_argument("--commit", required=True)
    check.add_argument("--version", required=True)
    check.add_argument("--baseline", type=Path)
    check.add_argument("--json", action="store_true")
    return command_parser


def initialize_command(arguments):
    target = {
        "version": arguments.version,
        "commit": arguments.commit,
        "platform": arguments.platform,
        "architecture": arguments.architecture,
        "backend": arguments.backend,
        "artifact": file_reference(arguments.artifact, arguments.ledger),
    }
    ledger = initialize_ledger(
        arguments.ledger, target=target, environment_path=arguments.environment_template,
    )
    print(f"{len(ledger['cases'])}件を未検証で作成しました: {arguments.ledger}")


def display_summary(inspection, *, as_json):
    if as_json:
        print(json.dumps(inspection, ensure_ascii=False, indent=2, allow_nan=False))
        return
    target = inspection["target"]
    print(f"{target['version']} / {target['commit']} / {target['platform']} {target['architecture']} / {target['backend']}")
    print("環境\t" + "\t".join(STATUS_LABELS[status] for status in STATUSES))
    for group_id, counts in inspection["groups"].items():
        print(group_id + "\t" + "\t".join(str(counts[status]) for status in STATUSES))
    print("合計\t" + "\t".join(str(inspection["counts"][status]) for status in STATUSES))
    for error in inspection["target_errors"]:
        print(f"未検証: {error}")
    for case_id, entry in inspection["cases"].items():
        for error in entry["errors"]:
            print(f"未検証: {case_id}: {error}")
    if "comparisons" in inspection:
        print(f"同条件で比較できる性能測定: {len(inspection['comparisons'])}条件（数値は --json）。閾値は未設定です。")
    print("この配布物の必須検証は完了です。" if inspection["complete"] else "この配布物の必須検証は未完了です。")


def main():
    arguments = create_parser().parse_args()
    try:
        if arguments.command == "init":
            initialize_command(arguments)
            return 0
        if arguments.command == "record":
            record_case(
                arguments.ledger, case_id=arguments.case_id, status=arguments.status,
                note=arguments.note, environment=arguments.environment,
                evidence=arguments.evidence, metrics=arguments.metrics,
            )
            print(f"{arguments.case_id}: {STATUS_LABELS[arguments.status]}として記録しました")
            return 0
        ledger = load_ledger(arguments.ledger)
        inspection = inspect_ledger(ledger, arguments.ledger)
        if arguments.command == "check":
            inspection["target_errors"].extend(expected_target_errors(
                ledger, artifact=arguments.artifact, commit=arguments.commit,
                version=arguments.version, ledger_path=arguments.ledger,
            ))
            if arguments.baseline is not None:
                try:
                    inspection["comparisons"] = compare_latency(
                        ledger, ledger_path=arguments.ledger,
                        baseline_path=arguments.baseline, inspection=inspection,
                    )
                except ValidationError as error:
                    inspection["target_errors"].append(str(error))
            if inspection["target_errors"]:
                inspection["complete"] = False
        display_summary(inspection, as_json=arguments.json)
        has_errors = inspection["target_errors"] or any(
            entry["errors"] for entry in inspection["cases"].values()
        )
        if has_errors:
            return 2
        if arguments.command == "check" and not inspection["complete"]:
            return 1
        return 0
    except (ValidationError, OSError) as error:
        print(f"検証記録エラー: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
