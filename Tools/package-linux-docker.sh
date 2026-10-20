#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:?Pass MAJOR.MINOR.PATCH}"
DOCKER="${DOCKER_BIN:-docker}"
if ! command -v "$DOCKER" >/dev/null && [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    DOCKER=/Applications/Docker.app/Contents/Resources/bin/docker
fi
python3 "$ROOT/Tools/fetch-models.py" --verify-only
python3 "$ROOT/Tools/fetch-wordnet.py" --verify-only
"$DOCKER" build -f "$ROOT/packaging/docker/Dockerfile" -t azookey-tree-tests:local \
    --build-arg "AZOOKEY_BUILD_COMMIT=$(git -C "$ROOT" rev-parse HEAD)" "$ROOT"
"$DOCKER" build -f "$ROOT/packaging/docker/Dockerfile.zenzai" -t azookey-tree-zenzai-tests:local "$ROOT"
mkdir -p "$ROOT/build/dist"
"$DOCKER" run --rm --init --cpus=4 --memory=8g \
    --mount type=volume,source=azookey-tree-core-build,target=/workspace/Core/.build \
    --mount type=volume,source=azookey-tree-spm-cache,target=/root/.cache/org.swift.swiftpm \
    --mount "type=bind,source=$ROOT/build/models,target=/opt/azookey/models,readonly" \
    --mount "type=bind,source=$ROOT/build/wordnet,target=/opt/azookey/dictionaries,readonly" \
    --mount "type=bind,source=$ROOT/build/dist,target=/dist" \
    --env AZOOKEY_RESOURCES=/opt/azookey/models --env AZOOKEY_OUTPUT_DIR=/dist \
    --env AZOOKEY_WORDNET_RESOURCES=/opt/azookey/dictionaries \
    azookey-tree-zenzai-tests:local bash Tools/build-linux.sh "$VERSION"
