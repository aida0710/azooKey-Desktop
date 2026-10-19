#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/azookey-docker-preflight.XXXXXX")"
trap 'rm -rf "$FIXTURE"' EXIT
mkdir -p "$FIXTURE/Tools"
cp "$ROOT/Tools/test-docker.sh" "$FIXTURE/Tools/"
cat > "$FIXTURE/Tools/fetch-models.py" <<'PY'
import sys
assert sys.argv[1:] == ['--verify-only']
raise SystemExit(19)  # Missing/invalid pinned models.
PY
cat > "$FIXTURE/docker" <<'SH'
#!/bin/bash
exit 0
SH
chmod +x "$FIXTURE/docker"
set +e
DOCKER_BIN="$FIXTURE/docker" bash "$FIXTURE/Tools/test-docker.sh" --zenzai > "$FIXTURE/output" 2>&1
RESULT=$?
set -e
if [[ "$RESULT" != 19 ]]; then
    cat "$FIXTURE/output" >&2
    echo 'FAIL: --zenzai must stop when pinned models are unavailable' >&2
    exit 1
fi
echo 'PASS: --zenzai rejects unavailable pinned models'
