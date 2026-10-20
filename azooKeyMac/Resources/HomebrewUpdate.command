#!/bin/sh
set -u
umask 077

CASK=aida0710/tap/azookey-tree
BUNDLE_ID=dev.ensan.inputmethod.azooKeyMac
ARTIFACT=azooKeyMac.app
# A normal app termination should finish promptly; never force an input method out.
PARENT_EXIT_TIMEOUT_SECONDS=120
PARENT_EXIT_POLL_SECONDS=1
# Bounds apply only to the fixed cask metadata and the operating system PID type.
MAXIMUM_ARTIFACTS=128
MAXIMUM_PARENT_PID=2147483647

terminal_brew=$(command -v brew 2>/dev/null || :)
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH
# Metadata reads must not perform an implicit update or unrelated cleanup.
HOMEBREW_NO_AUTO_UPDATE=1
HOMEBREW_NO_INSTALL_CLEANUP=1
HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_AUTO_UPDATE HOMEBREW_NO_INSTALL_CLEANUP HOMEBREW_NO_ENV_HINTS

extract_value() {
    # A sentinel preserves raw trailing newlines that command substitution removes.
    extracted_value=$(/usr/bin/plutil -extract "$2" raw -expect "$3" -n -o - "$1" 2>/dev/null && printf '.') || return 1
    extracted_value=${extracted_value%.}
    case "$extracted_value" in *'
'*) return 1 ;; esac
    printf '%s' "$extracted_value"
}

valid_uuid() {
    [ "${#1}" -eq 36 ] || return 1
    case "$1" in ''|*[!0-9a-fA-F-]*) return 1 ;; esac
    previous_ifs=$IFS
    IFS=-
    set -- $1
    IFS=$previous_ifs
    [ "$#" -eq 5 ] && [ "${#1}" -eq 8 ] && [ "${#2}" -eq 4 ] &&
        [ "${#3}" -eq 4 ] && [ "${#4}" -eq 4 ] && [ "${#5}" -eq 12 ]
}

valid_version() {
    case "$1" in ''|*[!0-9.]*|.*|*..*|*.) return 1 ;; esac
    previous_ifs=$IFS
    IFS=.
    set -- $1
    IFS=$previous_ifs
    [ "$#" -eq 3 ] || return 1
    for component in "$@"; do
        case "$component" in 0|[1-9]|[1-9][0-9]*) ;; *) return 1 ;; esac
    done
}

version_is_newer() {
    # Decimal strings avoid both lexicographic 1.10 < 1.9 and integer overflow.
    /usr/bin/awk 'BEGIN {
        split(ARGV[1], candidate, /[.]/); split(ARGV[2], installed, /[.]/)
        for (part = 1; part <= 3; part++) {
            if (length(candidate[part]) != length(installed[part]))
                exit !(length(candidate[part]) > length(installed[part]))
            if ("x" candidate[part] != "x" installed[part])
                exit !("x" candidate[part] > "x" installed[part])
        }
        exit 1
    }' "$1" "$2"
}

canonical_directory() {
    case "$1" in /*) ;; *) return 1 ;; esac
    case "$1" in *'
'*) return 1 ;; esac
    (CDPATH= cd -P "$1" && pwd -P) 2>/dev/null
}

# Capture the app identity and external job before Homebrew can replace Resources.
helper_bundle=$(canonical_directory "$(/usr/bin/dirname "$0")/../..") || exit 1
case "$HOME" in /*) ;; *) exit 1 ;; esac
job_directory=
request=
job_id=
for update_root in \
    "$HOME/Library/Containers/dev.ensan.inputmethod.azooKeyMac/Data/Library/Application Support/azooKey Tree/HomebrewUpdates" \
    "$HOME/Library/Application Support/azooKey Tree/HomebrewUpdates"; do
    candidate_id=$(extract_value "$update_root/latest.plist" jobID string) || continue
    valid_uuid "$candidate_id" || continue
    candidate_directory="$update_root/$candidate_id"
    candidate_request="$candidate_directory/request.plist"
    [ "$(extract_value "$candidate_request" jobID string)" = "$candidate_id" ] || continue
    candidate_bundle=$(extract_value "$candidate_request" bundlePath string) || continue
    [ "$(canonical_directory "$candidate_bundle")" = "$helper_bundle" ] || continue
    # Choosing between two different matching jobs would update an unknown caller.
    [ -z "$job_directory" ] || exit 1
    job_directory=$candidate_directory
    request=$candidate_request
    job_id=$candidate_id
done
[ -n "$job_directory" ] || exit 1
# A second Terminal launch must not overwrite the original helper's result.
/bin/mkdir "$job_directory/.started" 2>/dev/null || exit 0
installed_version=
target_version=
finished=false

write_status() {
    status_temporary="$job_directory/.status-$$.tmp"
    printf '{"jobID":"%s","phase":"%s","code":"%s","installedVersion":"%s","targetVersion":"%s","helperPID":%s}\n' \
        "$job_id" "$1" "$2" "$installed_version" "$target_version" "$$" > "$status_temporary" &&
        /bin/mv -f "$status_temporary" "$job_directory/status.json"
}

fail() {
    write_status failed "$1"
    finished=true
    exit 1
}

trap 'if [ "$finished" != true ]; then write_status failed interrupted; fi' 0
trap 'fail interrupted' HUP INT TERM
write_status checking '' || exit 1
[ "$(/usr/bin/uname -s)" = Darwin ] || fail unsupported

bundle_path=$(extract_value "$request" bundlePath string) || fail unsupported
running_version=$(extract_value "$request" bundleVersion string) || fail unsupported
parent_pid=$(extract_value "$request" parentPID integer) || fail unsupported
language=$(extract_value "$request" language string) || fail unsupported
case "$language" in ja|en) ;; *) fail unsupported ;; esac
case "$parent_pid" in ''|*[!0-9]*) fail unsupported ;; esac
/usr/bin/awk 'BEGIN { exit !(ARGV[1] > 1 && ARGV[1] <= ARGV[2]) }' "$parent_pid" "$MAXIMUM_PARENT_PID" || fail unsupported
[ "$parent_pid" != "$$" ] || fail unsupported
valid_version "$running_version" || fail unsupported
case "$bundle_path" in /*) ;; *) fail unsupported ;; esac
case "$bundle_path" in *'
'*) fail unsupported ;; esac
bundle_path=$(CDPATH= cd -P "$bundle_path" && pwd -P) || fail unmanaged
installed_version=$running_version

read_metadata() {
    "$1" info --json=v2 --cask "$CASK" > "$job_directory/cask.json" 2>/dev/null || return 1
    metadata_file="$job_directory/cask.json"
    [ "$(extract_value "$metadata_file" casks array)" = 1 ] || return 1
    [ "$(extract_value "$metadata_file" casks.0.tap string)" = aida0710/tap ] || return 2
    [ "$(extract_value "$metadata_file" casks.0.token string)" = azookey-tree ] || return 2
    [ "$(extract_value "$metadata_file" casks.0.full_token string)" = "$CASK" ] || return 2
    metadata_installed=$(extract_value "$metadata_file" casks.0.installed string) || return 2
    metadata_version=$(extract_value "$metadata_file" casks.0.version string) || return 1
    valid_version "$metadata_installed" && valid_version "$metadata_version" || return 1
    artifact_count=$(extract_value "$metadata_file" casks.0.artifacts array) || return 1
    [ "$artifact_count" -le "$MAXIMUM_ARTIFACTS" ] || return 1
    artifact_index=0
    input_method_count=0
    while [ "$artifact_index" -lt "$artifact_count" ]; do
        artifact_key="casks.0.artifacts.$artifact_index.input_method"
        if input_method_size=$(extract_value "$metadata_file" "$artifact_key" array); then
            [ "$input_method_size" = 1 ] || return 2
            [ "$(extract_value "$metadata_file" "$artifact_key.0" string)" = "$ARTIFACT" ] || return 2
            input_method_count=$((input_method_count + 1))
        fi
        artifact_index=$((artifact_index + 1))
    done
    [ "$input_method_count" -eq 1 ] || return 2
}

verify_installation() {
    [ "$metadata_installed" = "$2" ] || return 1
    caskroom_path=$("$1" --caskroom "$CASK" 2>/dev/null) || return 1
    canonical_caskroom=$(canonical_directory "$caskroom_path") || return 1
    staged_artifact="$canonical_caskroom/$metadata_installed/$ARTIFACT"
    [ -L "$staged_artifact" ] || return 1
    [ "$(canonical_directory "$staged_artifact")" = "$bundle_path" ] || return 1
    bundle_info="$bundle_path/Contents/Info.plist"
    [ "$(extract_value "$bundle_info" CFBundleIdentifier string)" = "$BUNDLE_ID" ] || return 1
    [ "$(extract_value "$bundle_info" CFBundleShortVersionString string)" = "$2" ] || return 1
}

selected_brew=
found_brew=false
metadata_failed=false
for candidate_brew in /opt/homebrew/bin/brew /usr/local/bin/brew "$terminal_brew"; do
    case "$candidate_brew" in /*) ;; *) continue ;; esac
    case "$candidate_brew" in *'
'*) continue ;; esac
    [ -x "$candidate_brew" ] || continue
    found_brew=true
    if read_metadata "$candidate_brew"; then
        if verify_installation "$candidate_brew" "$running_version"; then
            selected_brew=$candidate_brew
            original_caskroom=$canonical_caskroom
            break
        fi
    else
        [ "$?" -ne 1 ] || metadata_failed=true
    fi
done
if [ -z "$selected_brew" ]; then
    [ "$found_brew" = true ] || fail noHomebrew
    [ "$metadata_failed" = false ] || fail checkFailed
    fail unmanaged
fi

recheck_original() {
    read_metadata "$selected_brew" && verify_installation "$selected_brew" "$running_version" &&
        [ "$canonical_caskroom" = "$original_caskroom" ]
}

# Recheck immediately before and after updating tap metadata, before any upgrade.
recheck_original || fail changedInstallation
target_version=$metadata_version
write_status updating '' || exit 1
"$selected_brew" update || fail updateFailed
recheck_original || fail changedInstallation
if ! version_is_newer "$metadata_version" "$running_version"; then
    target_version=$running_version
    write_status upToDate '' || exit 1
    finished=true
    exit 0
fi

target_version=$metadata_version
write_status updating '' || exit 1
"$selected_brew" upgrade --cask --no-ask --require-sha "$CASK" || fail updateFailed
read_metadata "$selected_brew" || fail verificationFailed
verify_installation "$selected_brew" "$target_version" || fail verificationFailed
[ "$canonical_caskroom" = "$original_caskroom" ] || fail verificationFailed
installed_version=$target_version
write_status updated '' || exit 1

elapsed_seconds=0
while kill -0 "$parent_pid" 2>/dev/null; do
    [ "$elapsed_seconds" -lt "$PARENT_EXIT_TIMEOUT_SECONDS" ] || fail restartFailed
    /bin/sleep "$PARENT_EXIT_POLL_SECONDS" || fail interrupted
    elapsed_seconds=$((elapsed_seconds + PARENT_EXIT_POLL_SECONDS))
done
write_status restarting '' || exit 1
/usr/bin/open "$bundle_path" || fail restartFailed
write_status restarted '' || exit 1
finished=true
