#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_BUNDLE="$ROOT/build/macos-app/.build/arm64-apple-macosx/debug/azooKeyMacStandalonePackageTests.xctest"
export AZOOKEY_RECONVERSION_DIAGNOSTIC="$ROOT/build/reconversion-diagnostic"
mkdir -p "$AZOOKEY_RECONVERSION_DIAGNOSTIC"
[[ -d "$TEST_BUNDLE" ]] || { echo "The original test bundle is missing." >&2; exit 2; }

run_case() {
    local case_name="$1"
    shift
    local capture="script reconversion_lldb.capture(lldb.debugger, '$case_name')"
    # Keep the second process even when the first stops or exits with failures.
    set +e
    xcrun lldb --batch --no-lldbinit \
        -o "command script import \"$ROOT/Tools/diagnostics/reconversion_lldb.py\"" \
        -o 'settings set target.disable-aslr false' \
        -o 'breakpoint set --name objc_exception_throw' \
        -o run -o "$capture" -k "$capture" \
        -- "$(xcrun -f xctest)" "$@" "$TEST_BUNDLE" \
        2>&1 | tee "$AZOOKEY_RECONVERSION_DIAGNOSTIC/$case_name.log"
    local pipeline_status=("${PIPESTATUS[@]}")
    set -e
    printf '{"lldbExit":%s,"teeExit":%s}\n' "${pipeline_status[0]}" "${pipeline_status[1]}" \
        > "$AZOOKEY_RECONVERSION_DIAGNOSTIC/$case_name-driver.json"
}

run_case isolated \
    -XCTest azooKeyMacTests.ReconversionCommitLifetimeTests/testCancelingBeforeCommitStillRestoresTheOriginalSelection
# With no filter, XCTest retains the original AI/UI/shared-fixture/reconversion order.
run_case full-suite

python3 - <<'PY'
import json
import os
from pathlib import Path

directory = Path(os.environ["AZOOKEY_RECONVERSION_DIAGNOSTIC"])
observations = {}
for name in ("isolated", "full-suite"):
    process_path = directory / f"{name}-process.json"
    observations[name] = {
        "driver": json.loads((directory / f"{name}-driver.json").read_text()),
        "process": json.loads(process_path.read_text()) if process_path.exists() else None,
    }
(directory / "summary.json").write_text(json.dumps(observations, indent=2) + "\n")
print(json.dumps(observations, indent=2))
# A diagnostic capture is not a successful test execution.
raise SystemExit(0 if all(
    observation["process"] is not None
    and observation["process"].get("exitStatus") == 0
    and observation["driver"] == {"lldbExit": 0, "teeExit": 0}
    for observation in observations.values()
) else 1)
PY
