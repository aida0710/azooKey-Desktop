#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER_BIN:-docker}"
if ! command -v "$DOCKER" >/dev/null && [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    DOCKER=/Applications/Docker.app/Contents/Resources/bin/docker
fi
"$DOCKER" info >/dev/null
"$DOCKER" build --file "$ROOT/packaging/docker/Dockerfile" --tag azookey-tree-tests:local \
    --build-arg "AZOOKEY_BUILD_COMMIT=$(git -C "$ROOT" rev-parse HEAD)" "$ROOT"
# Source is copied into the image: tests cannot modify files on the host.
"$DOCKER" run --rm --init --cpus=4 --memory=8g azookey-tree-tests:local "$@"
