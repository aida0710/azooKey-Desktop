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

# macOS ships Bash 3.2, where nounset rejects an empty "${EXTRA[@]}".
# Dictionary-only runs must still reach Docker with no model arguments.
git -C "$FIXTURE" init -q
git -C "$FIXTURE" -c user.name=Test -c user.email=test@example.invalid -c commit.gpgsign=false \
    commit -q --allow-empty -m fixture
cat > "$FIXTURE/docker" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "${0%/*}/docker-arguments"
SH
DOCKER_BIN="$FIXTURE/docker" bash "$FIXTURE/Tools/test-docker.sh" > "$FIXTURE/output" 2>&1 || {
    cat "$FIXTURE/output" >&2
    exit 1
}
[[ "$(head -n 1 "$FIXTURE/docker-arguments")" == run ]]
if grep -q AZOOKEY_RESOURCES "$FIXTURE/docker-arguments"; then
    echo 'FAIL: dictionary-only run must not require model resources' >&2
    exit 1
fi
echo 'PASS: dictionary-only run accepts an empty model argument list'
