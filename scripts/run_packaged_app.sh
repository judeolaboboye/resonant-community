#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/scripts/version_metadata.sh"
CONFIGURATION_INPUT="${1:-${CONFIGURATION:-Debug}}"
CONFIGURATION_LOWER="${(L)CONFIGURATION_INPUT}"

case "$CONFIGURATION_LOWER" in
    debug)
        CONFIGURATION_DIR="Debug"
        PACKAGE_RELEASE_BUILD=0
        ;;
    release)
        CONFIGURATION_DIR="Release"
        PACKAGE_RELEASE_BUILD="${RESONANT_RELEASE_BUILD:-1}"
        ;;
    *)
        echo "Usage: $0 [Debug|Release|debug|release]" >&2
        exit 1
        ;;
esac
EXPECTED_BUNDLE_ID="$(RESONANT_RELEASE_BUILD="$PACKAGE_RELEASE_BUILD" resonant_effective_bundle_identifier "$PACKAGE_RELEASE_BUILD")"
EXPECTED_APP_ENV="$(RESONANT_RELEASE_BUILD="$PACKAGE_RELEASE_BUILD" resonant_effective_app_environment "$PACKAGE_RELEASE_BUILD")"
EXPECTED_CALLBACK_SCHEME="$(RESONANT_RELEASE_BUILD="$PACKAGE_RELEASE_BUILD" resonant_effective_callback_scheme "$PACKAGE_RELEASE_BUILD")"
EXPECTED_DISTRIBUTION="$(resonant_effective_distribution "$ROOT_DIR/Sources/Resonant/Info.plist")"
if [[ "$EXPECTED_DISTRIBUTION" == "community" ]]; then
    EXPECTED_APP_BUNDLE_NAME="Resonant Community.app"
else
    EXPECTED_APP_BUNDLE_NAME="Resonant.app"
fi

if [[ "${RESONANT_CLEAN_BUILD:-0}" == "1" ]]; then
    swift package clean
fi

resolve_source_products_dir() {
    if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -e "${BUILT_PRODUCTS_DIR}/Resonant" ]]; then
        print -r -- "$BUILT_PRODUCTS_DIR"
        return
    fi

    swift build --configuration "$CONFIGURATION_LOWER" --show-bin-path
}

resolve_existing_app_dir() {
    local source_products_dir="$1"
    local -a candidates=()

    if [[ -n "${RESONANT_APP_OUTPUT_DIR:-}" ]]; then
        candidates+=("${RESONANT_APP_OUTPUT_DIR}/$EXPECTED_APP_BUNDLE_NAME")
    fi

    candidates+=(
        "$ROOT_DIR/.build/xcode/$CONFIGURATION_DIR/$EXPECTED_APP_BUNDLE_NAME"
        "$source_products_dir/$EXPECTED_APP_BUNDLE_NAME"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -d "$candidate" ]]; then
            print -r -- "$candidate"
            return
        fi
    done
}

needs_repackage() {
    local app_dir="$1"
    local source_executable="$2"
    local packaged_executable="$app_dir/Contents/MacOS/Resonant"
    local packaged_info_plist="$app_dir/Contents/Info.plist"
    local source_info_plist="$ROOT_DIR/Sources/Resonant/Info.plist"
    local packaged_bundle_id=""

    [[ "${RESONANT_FORCE_REPACKAGE:-0}" == "1" ]] && return 0
    [[ -z "$app_dir" || ! -d "$app_dir" ]] && return 0
    [[ ! -x "$packaged_executable" ]] && return 0
    packaged_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$packaged_info_plist" 2>/dev/null || true)"
    [[ "$packaged_bundle_id" != "$EXPECTED_BUNDLE_ID" ]] && return 0
    [[ -e "$source_executable" && "$source_executable" -nt "$packaged_executable" ]] && return 0
    [[ -f "$source_info_plist" && ( ! -f "$packaged_info_plist" || "$source_info_plist" -nt "$packaged_info_plist" ) ]] && return 0

    return 1
}

SOURCE_PRODUCTS_DIR="$(resolve_source_products_dir)"
SOURCE_EXECUTABLE="$SOURCE_PRODUCTS_DIR/Resonant"
APP_DIR="$(resolve_existing_app_dir "$SOURCE_PRODUCTS_DIR")"

if needs_repackage "$APP_DIR" "$SOURCE_EXECUTABLE"; then
    APP_DIR="$(RESONANT_DISTRIBUTION="$EXPECTED_DISTRIBUTION" RESONANT_RELEASE_BUILD="$PACKAGE_RELEASE_BUILD" RESONANT_BUNDLE_IDENTIFIER="$EXPECTED_BUNDLE_ID" RESONANT_APP_ENV="$EXPECTED_APP_ENV" RESONANT_CALLBACK_SCHEME="$EXPECTED_CALLBACK_SCHEME" "$ROOT_DIR/scripts/package_app.sh" "$CONFIGURATION_INPUT" | tail -n 1)"
fi

if [[ -z "$APP_DIR" || ! -d "$APP_DIR" ]]; then
    echo "Error: could not resolve a packaged $EXPECTED_APP_BUNDLE_NAME to launch." >&2
    exit 1
fi

if [[ "${RESONANT_SKIP_OPEN:-0}" == "1" ]]; then
    echo "$APP_DIR"
    exit 0
fi

# Reset accessibility permission only when explicitly requested.
# Use `RESONANT_RESET_ACCESSIBILITY=1` for a forced re-prompt when debugging TCC.
if [[ "${RESONANT_RESET_ACCESSIBILITY:-0}" == "1" ]]; then
    BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "com.resonance.resonant")
    tccutil reset Accessibility "$BUNDLE_ID" 2>/dev/null || true
fi

# Force-register this build as the handler for resonantmac:// URL scheme
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true

BUNDLE_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP_DIR/Contents/Info.plist" 2>/dev/null || echo "com.resonance.resonant")
if [[ "$BUNDLE_ID" != "$EXPECTED_BUNDLE_ID" ]]; then
    echo "Error: packaged bundle id '$BUNDLE_ID' does not match expected '$EXPECTED_BUNDLE_ID' for $CONFIGURATION_DIR." >&2
    echo "Try clearing RESONANT_BUNDLE_IDENTIFIER or RESONANT_RELEASE_BUILD overrides in .env.local." >&2
    exit 1
fi
APP_EXECUTABLE="$APP_DIR/Contents/MacOS/Resonant"

running_app_pids() {
    local executable="$1"
    ps -axo pid=,command= | awk -v executable="$executable" '
        {
            pid = $1
            sub(/^[[:space:]]*[0-9]+[[:space:]]+/, "", $0)
            if ($0 == executable || index($0, executable " ") == 1) {
                print pid
            }
        }
    '
}

wait_for_app_exit() {
    local executable="$1"
    local attempts="${2:-20}"
    local delay="${3:-0.25}"

    local attempt=1
    while [[ "$attempt" -le "$attempts" ]]; do
        if [[ -z "$(running_app_pids "$executable")" ]]; then
            return 0
        fi
        sleep "$delay"
        attempt=$((attempt + 1))
    done
    return 1
}

# Quit any running instance of this packaged bundle ID.
osascript <<APPLESCRIPT >/dev/null 2>&1 || true
tell application id "$BUNDLE_ID"
    if it is running then quit
end tell
APPLESCRIPT

wait_for_app_exit "$APP_EXECUTABLE" 20 0.25 || true

remaining_pids=("${(@f)$(running_app_pids "$APP_EXECUTABLE")}")
if [[ ${#remaining_pids[@]} -gt 0 && -n "${remaining_pids[1]}" ]]; then
    kill "${remaining_pids[@]}" 2>/dev/null || true
    wait_for_app_exit "$APP_EXECUTABLE" 20 0.25 || true
fi

remaining_pids=("${(@f)$(running_app_pids "$APP_EXECUTABLE")}")
if [[ ${#remaining_pids[@]} -gt 0 && -n "${remaining_pids[1]}" ]]; then
    kill -9 "${remaining_pids[@]}" 2>/dev/null || true
    if ! wait_for_app_exit "$APP_EXECUTABLE" 8 0.25; then
        echo "Error: could not terminate stale Resonant process for $APP_EXECUTABLE: ${remaining_pids[*]}" >&2
        exit 1
    fi
fi

if ! open -n "$APP_DIR"; then
    sleep 1
    open -n "$APP_DIR"
fi
