#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOCKER="${DOCKER_BIN:-docker}"
CPU=false
if [[ "${1:-}" == --zenzai ]]; then CPU=true; shift; fi
if $CPU; then
    # CPU inference tests must never silently fall back to dictionary-only mode.
    python3 "$ROOT/Tools/fetch-models.py" --verify-only
fi
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
    EXTRA+=(--mount "type=bind,source=$ROOT/build/models,target=/opt/azookey/models,readonly" --env AZOOKEY_RESOURCES=/opt/azookey/models)
fi
# Keep each run's fixed-fixture evidence after the disposable container exits.
mkdir -p "$ROOT/build/test-artifacts"
ARTIFACT_DIRECTORY="$(mktemp -d "$ROOT/build/test-artifacts/linux.XXXXXX")"
echo "Native toolkit evidence: $ARTIFACT_DIRECTORY"
# Source is copied into the image; only the evidence directory is writable.
"$DOCKER" run --rm --init --cpus=4 --memory=8g \
    --mount type=volume,source=azookey-tree-core-build,target=/workspace/Core/.build \
    --mount type=volume,source=azookey-tree-spm-cache,target=/root/.cache/org.swift.swiftpm \
    --mount "type=bind,source=$ARTIFACT_DIRECTORY,target=/test-artifacts" \
    --env AZOOKEY_TOOLKIT_ARTIFACTS=/test-artifacts \
    ${EXTRA[@]+"${EXTRA[@]}"} "$IMAGE" "$@"
