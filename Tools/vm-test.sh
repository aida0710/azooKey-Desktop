#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLATFORM="${1:-}"
ACTION="${2:-status}"
[[ "$PLATFORM" == macos || "$PLATFORM" == ubuntu ]] || {
    echo 'Usage: vm-test.sh macos|ubuntu create|start|status|shell|stop|copy|install|test [args...]' >&2
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
    start)
        if [[ -f "$LIMA_HOME/$NAME/viewer.pid" ]] && kill -0 "$(cat "$LIMA_HOME/$NAME/viewer.pid")" 2>/dev/null; then
            echo 'The GUI viewer is running this disk. Shut it down before starting Lima.' >&2
            exit 2
        fi
        limactl start --tty=false --timeout=60m "$NAME"
        ;;
    status) limactl list "$NAME" ;;
    shell) limactl shell --workdir=/ "$NAME" "$@" ;;
    stop) limactl stop "$NAME" ;;
    copy)
        [[ $# == 2 && -e "$1" ]] || { echo 'copy requires a local source and guest destination' >&2; exit 2; }
        if [[ -d "$1" ]]; then
            limactl copy -r "$1" "$NAME:$2"
        else
            limactl copy "$1" "$NAME:$2"
        fi
        ;;
    install)
        [[ $# == 1 && -f "$1" ]] || { echo 'install requires a built zip (macOS) or deb (Ubuntu)' >&2; exit 2; }
        GUEST_STAGE="$(limactl shell --workdir=/ "$NAME" mktemp -d /tmp/azookey-install.XXXXXX)"
        limactl copy --backend=scp "$1" "$NAME:$GUEST_STAGE/"
        if [[ "$PLATFORM" == ubuntu ]]; then
            limactl shell --workdir=/ "$NAME" sudo apt-get install --reinstall -y "$GUEST_STAGE/$(basename "$1")"
        else
            limactl shell --workdir=/ "$NAME" sh -c 'mkdir -p "$HOME/Library/Input Methods"; ditto -x -k "$1" "$HOME/Library/Input Methods"; codesign --verify --deep --strict "$HOME/Library/Input Methods/azooKeyMac.app"' sh "$GUEST_STAGE/$(basename "$1")"
        fi
        ;;
    test)
        if [[ "$PLATFORM" == macos ]]; then
            limactl shell --workdir=/ "$NAME" sh -c 'codesign --verify --deep --strict "$HOME/Library/Input Methods/azooKeyMac.app" && /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$HOME/Library/Input Methods/azooKeyMac.app/Contents/Info.plist"'
            echo 'PASS: macOS guest bundle verification. Interactive IME tests must still run in the GUI.'
        else
            GUEST_STAGE="$(limactl shell --workdir=/ "$NAME" mktemp -d /tmp/azookey-tests.XXXXXX)"
            for file in "$ROOT/Tools/tests/linux-installed.py" "$ROOT/Tools/tests/linux-desktop.sh" "$ROOT/Linux/tests/ibus_integration.py"; do
                limactl copy --backend=scp "$file" "$NAME:$GUEST_STAGE/"
            done
            limactl shell --workdir=/ "$NAME" env LD_LIBRARY_PATH=/opt/azookey-tree/libexec AZOOKEY_RESOURCES=/opt/azookey-tree/models python3 "$GUEST_STAGE/linux-installed.py"
            limactl shell --workdir=/ "$NAME" env LD_LIBRARY_PATH=/opt/azookey-tree/libexec AZOOKEY_RESOURCES=/opt/azookey-tree/models \
                AZOOKEY_INSTALLED_TEST=1 AZOOKEY_IBUS_TEST="$GUEST_STAGE/ibus_integration.py" \
                dbus-run-session -- xvfb-run -a bash "$GUEST_STAGE/linux-desktop.sh"
        fi
        ;;
    *) echo "Unknown action: $ACTION" >&2; exit 2 ;;
esac
