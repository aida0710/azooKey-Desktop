#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/azookey-sync-test.XXXXXX")"
trap 'rm -rf "$SANDBOX"' EXIT
export GIT_AUTHOR_NAME='Sync Test' GIT_COMMITTER_NAME='Sync Test'
export GIT_AUTHOR_EMAIL='test@example.invalid' GIT_COMMITTER_EMAIL='test@example.invalid'
git init -q -b main "$SANDBOX/upstream"
git -C "$SANDBOX/upstream" config commit.gpgsign false
printf 'base\n' > "$SANDBOX/upstream/shared.txt"
git -C "$SANDBOX/upstream" add .
git -C "$SANDBOX/upstream" commit -qm base
git clone -q --bare "$SANDBOX/upstream" "$SANDBOX/origin.git"
git clone -q "$SANDBOX/origin.git" "$SANDBOX/work"
git -C "$SANDBOX/work" remote add upstream "$SANDBOX/upstream"
git -C "$SANDBOX/work" config commit.gpgsign false
run_sync() { bash "$ROOT/Tools/sync-upstream.sh" --repo "$SANDBOX/work" "$@"; }
run_sync > "$SANDBOX/noop.log"
grep -q 'Already contains upstream' "$SANDBOX/noop.log"
printf 'new\n' > "$SANDBOX/upstream/new.txt"
git -C "$SANDBOX/upstream" add .
git -C "$SANDBOX/upstream" commit -qm update
printf 'uncommitted user work\n' > "$SANDBOX/work/shared.txt"
BEFORE="$(git -C "$SANDBOX/work" rev-parse HEAD)"
run_sync > "$SANDBOX/merge.log"
grep -q 'Prepared merge' "$SANDBOX/merge.log"
[[ "$(git -C "$SANDBOX/work" rev-parse HEAD)" == "$BEFORE" ]]
[[ "$(cat "$SANDBOX/work/shared.txt")" == 'uncommitted user work' ]]
[[ "$(git -C "$SANDBOX/origin.git" for-each-ref --format='%(refname)' refs/heads | wc -l | tr -d ' ')" == 1 ]]
run_sync > "$SANDBOX/repeat.log"
grep -q 'Prepared merge' "$SANDBOX/repeat.log"
# A fork-only commit survives; a conflicting upstream change is rejected.
git -C "$SANDBOX/work" add shared.txt
git -C "$SANDBOX/work" commit -qm 'fork work'
git -C "$SANDBOX/work" push -q origin main
printf 'upstream conflict\n' > "$SANDBOX/upstream/shared.txt"
git -C "$SANDBOX/upstream" commit -qam conflict
set +e
run_sync > "$SANDBOX/conflict.log" 2>&1
RESULT=$?
set -e
[[ "$RESULT" == 3 ]]
grep -q 'Merge conflict' "$SANDBOX/conflict.log"
[[ "$(cat "$SANDBOX/work/shared.txt")" == 'uncommitted user work' ]]
echo 'PASS: no-op, merge, repeated run, dirty checkout preserved, no unintended push, conflict rejected'
