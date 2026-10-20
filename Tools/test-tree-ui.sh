#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Candidate settings, details and geometry share the application's real Core.
exec bash "$ROOT/Tools/test-macos-app.sh" test --filter CandidateTreeViewTests "$@"
