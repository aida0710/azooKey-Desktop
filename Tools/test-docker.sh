#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER_BIN:-docker}"
CPU=false
if [[ "${1:-}" == --zenzai ]]; then CPU=true; shift; fi
if ! command -v "$DOCKER" >/dev/null && [[ -x /Applications/Docker.app/Contents/Resources/bin/docker ]]; then
    DOCKER=/Applications/Docker.app/Contents/Resources/bin/docker
fi
"$DOCKER" info >/dev/null
"$DOCKER" build --file "$ROOT/packaging/docker/Dockerfile" --tag azookey-tree-tests:local \
    --build-arg "AZOOKEY_BUILD_COMMIT=$(git -C "$ROOT" rev-parse HEAD)" "$ROOT"
IMAGE=azookey-tree-tests:local
EXTRA=()
if $CPU; then
    "$DOCKER" build --file "$ROOT/packaging/docker/Dockerfile.zenzai" --tag azookey-tree-zenzai-tests:local "$ROOT"
    IMAGE=azookey-tree-zenzai-tests:local
    if [[ -f "$ROOT/build/models/ggml-model-Q5_K_M.gguf" ]]; then
        python3 "$ROOT/Tools/fetch-models.py" --verify-only
        EXTRA+=(--mount "type=bind,source=$ROOT/build/models,target=/opt/azookey/models,readonly" --env AZOOKEY_RESOURCES=/opt/azookey/models)
    fi
fi
# Source is copied into the image: tests cannot modify files on the host.
"$DOCKER" run --rm --init --cpus=4 --memory=8g \
    --mount type=volume,source=azookey-tree-core-build,target=/workspace/Core/.build \
    --mount type=volume,source=azookey-tree-spm-cache,target=/root/.cache/org.swift.swiftpm \
    "${EXTRA[@]}" "$IMAGE" "$@"
