#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-}"
ACTION="${2:-status}"
[[ "$PLATFORM" == macos || "$PLATFORM" == ubuntu ]] || {
    echo 'Usage: vm-test.sh macos|ubuntu create|start|status|shell|stop|copy [args...]' >&2
    exit 2
}
shift "$(( $# >= 2 ? 2 : $# ))"
export LIMA_HOME="${AZOOKEY_VM_HOME:-$(dirname "$ROOT")/azookey-vm}"
NAME="azookey-$PLATFORM"
command -v limactl >/dev/null || { echo 'Lima is required. No tools were installed.' >&2; exit 2; }
case "$ACTION" in
    create)
        mkdir -p "$LIMA_HOME"
        if [[ -f "$LIMA_HOME/$NAME/lima.yaml" ]]; then
            echo "Instance already exists: $NAME (use start)"
            exit 0
        fi
        if [[ "$PLATFORM" == macos ]]; then
            [[ "$(uname -s)" == Darwin && "$(uname -m)" == arm64 ]] || {
                echo 'macOS guests require an Apple Silicon Mac.' >&2; exit 2;
            }
            limactl create --name="$NAME" --cpus=4 --memory=8 --disk=64 \
                --mount-none --containerd=none --tty=false template:macos-26
        else
            limactl create --name="$NAME" --tty=false "$ROOT/packaging/vm/ubuntu-desktop.yaml"
        fi
        ;;
    start) limactl start --tty=false "$NAME" ;;
    status) limactl list "$NAME" ;;
    shell) limactl shell --workdir=/ "$NAME" "$@" ;;
    stop) limactl stop "$NAME" ;;
    copy)
        [[ $# == 2 && -e "$1" ]] || { echo 'copy requires a local source and guest destination' >&2; exit 2; }
        limactl copy -r "$1" "$NAME:$2"
        ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
