#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
EXPLICIT_RESONANT_RELEASE_BUILD="${RESONANT_RELEASE_BUILD+x}"
EXPLICIT_RESONANT_BUNDLE_IDENTIFIER="${RESONANT_BUNDLE_IDENTIFIER+x}"
EXPLICIT_RESONANT_APP_ENV="${RESONANT_APP_ENV+x}"
EXPLICIT_RESONANT_CALLBACK_SCHEME="${RESONANT_CALLBACK_SCHEME+x}"
EXPLICIT_RESONANT_DISTRIBUTION="${RESONANT_DISTRIBUTION+x}"
PRESERVED_RESONANT_RELEASE_BUILD="${RESONANT_RELEASE_BUILD:-}"
PRESERVED_RESONANT_BUNDLE_IDENTIFIER="${RESONANT_BUNDLE_IDENTIFIER:-}"
PRESERVED_RESONANT_APP_ENV="${RESONANT_APP_ENV:-}"
PRESERVED_RESONANT_CALLBACK_SCHEME="${RESONANT_CALLBACK_SCHEME:-}"
PRESERVED_RESONANT_DISTRIBUTION="${RESONANT_DISTRIBUTION:-}"

# Source operator configuration for official builds. An explicit Community
# build is a clean-room request and must not inherit hosted endpoints or
# telemetry keys from a maintainer's ignored release environment.
SOURCE_LOCAL_ENV=1
if [[ -n "$EXPLICIT_RESONANT_DISTRIBUTION" && "${(L)PRESERVED_RESONANT_DISTRIBUTION}" == "community" ]]; then
    SOURCE_LOCAL_ENV=0
fi
if [[ "$SOURCE_LOCAL_ENV" == "1" && -f "$ROOT_DIR/.env.local" ]]; then
    set -a
    source "$ROOT_DIR/.env.local"
    set +a
fi
if [[ -n "$EXPLICIT_RESONANT_RELEASE_BUILD" ]]; then
    export RESONANT_RELEASE_BUILD="$PRESERVED_RESONANT_RELEASE_BUILD"
fi
if [[ -n "$EXPLICIT_RESONANT_BUNDLE_IDENTIFIER" ]]; then
    export RESONANT_BUNDLE_IDENTIFIER="$PRESERVED_RESONANT_BUNDLE_IDENTIFIER"
fi
if [[ -n "$EXPLICIT_RESONANT_APP_ENV" ]]; then
    export RESONANT_APP_ENV="$PRESERVED_RESONANT_APP_ENV"
fi
if [[ -n "$EXPLICIT_RESONANT_CALLBACK_SCHEME" ]]; then
    export RESONANT_CALLBACK_SCHEME="$PRESERVED_RESONANT_CALLBACK_SCHEME"
fi
if [[ -n "$EXPLICIT_RESONANT_DISTRIBUTION" ]]; then
    export RESONANT_DISTRIBUTION="$PRESERVED_RESONANT_DISTRIBUTION"
fi

source "$ROOT_DIR/scripts/version_metadata.sh"

# A clean Community build must not inherit production operator configuration
# from the calling shell. Downstream operators may opt in deliberately and
# provide their own complete configuration.
if [[ -n "$EXPLICIT_RESONANT_DISTRIBUTION" && "${(L)PRESERVED_RESONANT_DISTRIBUTION}" == "community" \
      && "${RESONANT_ALLOW_COMMUNITY_REMOTE_CONFIG:-0}" != "1" ]]; then
    unset RESONANT_CONVEX_CLOUD_URL RESONANT_DEV_CONVEX_CLOUD_URL RESONANT_AUTH_BASE_URL
    unset RESONANT_SENTRY_DSN SENTRY_DSN RESONANT_SENTRY_PROJECT SENTRY_PROJECT
    unset RESONANT_POSTHOG_API_KEY POSTHOG_API_KEY
    unset RESONANT_SPARKLE_FEED_URL RESONANT_SPARKLE_PUBLIC_ED_KEY
fi
CONFIGURATION_INPUT="${1:-${CONFIGURATION:-debug}}"
CONFIGURATION="${(L)CONFIGURATION_INPUT}"

if [[ "${CONFIGURATION_INPUT}" == "Debug" || "${CONFIGURATION_INPUT}" == "Release" ]]; then
    CONFIGURATION_DIR="$CONFIGURATION_INPUT"
else
    case "$CONFIGURATION" in
        debug) CONFIGURATION_DIR="Debug" ;;
        release) CONFIGURATION_DIR="Release" ;;
    esac
fi

case "$CONFIGURATION" in
    debug|release) ;;
    *)
        echo "Usage: $0 [debug|release]" >&2
        exit 1
        ;;
esac

RELEASE_BUILD="${RESONANT_RELEASE_BUILD:-0}"
MAIN_BUNDLE_IDENTIFIER="$(resonant_effective_bundle_identifier "$RELEASE_BUILD")"

upload_sentry_dsyms() {
    [[ "$RELEASE_BUILD" == "1" ]] || return 0
    [[ "${RESONANT_SKIP_SENTRY_UPLOAD:-0}" == "1" ]] && return 0

    local require_upload="${RESONANT_REQUIRE_SENTRY_UPLOAD:-}"
    if [[ -z "$require_upload" ]]; then
        if [[ "${DISTRIBUTION:-community}" == "official" ]]; then
            require_upload=1
        else
            require_upload=0
        fi
    fi
    local sentry_cli="${SENTRY_CLI_PATH:-$(command -v sentry-cli 2>/dev/null || true)}"
    local -a required_vars=(SENTRY_AUTH_TOKEN SENTRY_ORG SENTRY_PROJECT)
    local -a missing=()

    for var_name in "${required_vars[@]}"; do
        if [[ -z "${(P)var_name:-}" ]]; then
            missing+=("$var_name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        if [[ "$require_upload" == "1" ]]; then
            echo "Error: missing Sentry upload configuration: ${missing[*]}" >&2
            echo "Set the missing variables or export RESONANT_SKIP_SENTRY_UPLOAD=1 to bypass." >&2
            return 1
        fi
        echo "Warning: skipping Sentry dSYM upload; missing ${missing[*]}." >&2
        return 0
    fi

    if [[ -z "$sentry_cli" || ! -x "$sentry_cli" ]]; then
        if [[ "$require_upload" == "1" ]]; then
            echo "Error: sentry-cli is required for release symbol upload." >&2
            echo "Install sentry-cli or set SENTRY_CLI_PATH to its absolute path." >&2
            return 1
        fi
        echo "Warning: skipping Sentry dSYM upload; sentry-cli is unavailable." >&2
        return 0
    fi

    local -a dsym_paths=()
    while IFS= read -r -d '' path; do
        dsym_paths+=("$path")
    done < <(find "$SOURCE_PRODUCTS_DIR" -maxdepth 4 -name '*.dSYM' -print0)

    if [[ ${#dsym_paths[@]} -eq 0 ]]; then
        if [[ "$require_upload" == "1" ]]; then
            echo "Error: no dSYM bundles found under $SOURCE_PRODUCTS_DIR for Sentry upload." >&2
            return 1
        fi
        echo "Warning: no dSYM bundles found for Sentry upload." >&2
        return 0
    fi

    "$sentry_cli" debug-files upload \
        --org "$SENTRY_ORG" \
        --project "$SENTRY_PROJECT" \
        --include-sources \
        "${dsym_paths[@]}"
}

resonant_executable_rpaths() {
    local executable_path="$1"

    otool -l "$executable_path" | awk '
        /cmd LC_RPATH/ { in_rpath = 1; next }
        in_rpath && /^[[:space:]]*path / {
            sub(/^[[:space:]]*path /, "")
            sub(/[[:space:]]+\(offset [0-9]+\)$/, "")
            print
            in_rpath = 0
        }
    '
}

resonant_is_non_distributable_rpath() {
    local rpath="$1"

    case "$rpath" in
        /Applications/Xcode.app/*|*/XcodeDefault.xctoolchain/*|*/Toolchains/*/usr/lib/swift-*)
            return 0
            ;;
    esac

    return 1
}

resonant_strip_non_distributable_rpaths() {
    local executable_path="$1"
    local rpath

    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if resonant_is_non_distributable_rpath "$rpath"; then
            echo "Removing non-distributable rpath from Resonant executable: $rpath" >&2
            install_name_tool -delete_rpath "$rpath" "$executable_path"
        fi
    done < <(resonant_executable_rpaths "$executable_path")
}

resonant_assert_no_non_distributable_rpaths() {
    local executable_path="$1"
    local rpath
    local -a bad_rpaths=()

    while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if resonant_is_non_distributable_rpath "$rpath"; then
            bad_rpaths+=("$rpath")
        fi
    done < <(resonant_executable_rpaths "$executable_path")

    if (( ${#bad_rpaths[@]} > 0 )); then
        echo "Error: Resonant executable still contains non-distributable rpaths:" >&2
        printf '  %s\n' "${bad_rpaths[@]}" >&2
        return 1
    fi
}

cd "$ROOT_DIR"

SOURCE_PRODUCTS_DIR=""
APP_PARENT_DIR="${RESONANT_APP_OUTPUT_DIR:-}"

if [[ -n "${BUILT_PRODUCTS_DIR:-}" && -e "${BUILT_PRODUCTS_DIR}/Resonant" ]]; then
    SOURCE_PRODUCTS_DIR="$BUILT_PRODUCTS_DIR"
else
    swift build --configuration "$CONFIGURATION"

    SOURCE_PRODUCTS_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
fi

if [[ -z "$APP_PARENT_DIR" ]]; then
    APP_PARENT_DIR="$SOURCE_PRODUCTS_DIR"
fi

INFO_PLIST_PATH="$ROOT_DIR/Sources/Resonant/Info.plist"
DISTRIBUTION="$(resonant_effective_distribution "$INFO_PLIST_PATH")"
if [[ "$DISTRIBUTION" == "community" ]]; then
    APP_BUNDLE_NAME="Resonant Community.app"
else
    APP_BUNDLE_NAME="Resonant.app"
fi
APP_DIR="$APP_PARENT_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE_PATH="$SOURCE_PRODUCTS_DIR/Resonant"
PACKAGED_INFO_PLIST="$(mktemp "${TMPDIR:-/tmp}/resonant-info.XXXXXX")"
trap '/bin/rm -f "$PACKAGED_INFO_PLIST"' EXIT

APP_VERSION="$(resonant_effective_app_version "$INFO_PLIST_PATH")"
BUILD_NUMBER="$(resonant_effective_build_number "$INFO_PLIST_PATH" "$RELEASE_BUILD")"
resonant_materialize_info_plist "$INFO_PLIST_PATH" "$PACKAGED_INFO_PLIST" "$RELEASE_BUILD"

if [[ "$RELEASE_BUILD" == "1" ]]; then
    ENTITLEMENTS_PATH="$ROOT_DIR/Sources/Resonant/Resources/Resonant.entitlements"
else
    ENTITLEMENTS_PATH="${CODE_SIGN_ENTITLEMENTS:-${SOURCE_PRODUCTS_DIR}/Resonant-entitlement.plist}"
fi

SIGNING_IDENTITY="${RESONANT_CODESIGN_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" && -n "${EXPANDED_CODE_SIGN_IDENTITY_NAME:-}" ]]; then
    SIGNING_IDENTITY="$EXPANDED_CODE_SIGN_IDENTITY_NAME"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$RELEASE_BUILD" == "1" && "$DISTRIBUTION" == "official" ]]; then
        # Release builds require Developer ID for notarization
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/{print $2; exit}')"
    else
        SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development:/{print $2; exit}')"
        if [[ -z "$SIGNING_IDENTITY" ]]; then
            SIGNING_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application:/{print $2; exit}')"
        fi
    fi
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ "$RELEASE_BUILD" == "1" && "$DISTRIBUTION" == "official" ]]; then
        echo "Error: Developer ID Application certificate not found (required for release builds)" >&2
        exit 1
    fi
    SIGNING_IDENTITY="-"
fi

if [[ "$RELEASE_BUILD" == "1" && "$DISTRIBUTION" == "official" ]]; then
    # Fail fast (seconds, not after a full build) if this machine would emit
    # signatures without a team identifier.
    resonant_assert_clean_apple_trust_settings
    resonant_assert_signing_identity_healthy "$SIGNING_IDENTITY"
fi

REAL_RELEASE_SIGNATURE=0
if [[ "$RELEASE_BUILD" == "1" && "$SIGNING_IDENTITY" != "-" ]]; then
    REAL_RELEASE_SIGNATURE=1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"

cp "$PACKAGED_INFO_PLIST" "$CONTENTS_DIR/Info.plist"
cp "$EXECUTABLE_PATH" "$MACOS_DIR/Resonant"

# SwiftPM emits an ad-hoc signature on the built executable. Remove it before
# mutating load commands so Xcode does not surface install_name_tool as an error.
codesign --remove-signature "$MACOS_DIR/Resonant" 2>/dev/null || true

resonant_strip_non_distributable_rpaths "$MACOS_DIR/Resonant"

if ! otool -l "$MACOS_DIR/Resonant" | grep -q '@executable_path/../Frameworks'; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Resonant"
fi

resonant_assert_no_non_distributable_rpaths "$MACOS_DIR/Resonant"

if [[ -d "$SOURCE_PRODUCTS_DIR/Sparkle.framework" ]]; then
    ditto "$SOURCE_PRODUCTS_DIR/Sparkle.framework" "$FRAMEWORKS_DIR/Sparkle.framework"

    SPARKLE_UPDATER_PLIST="$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app/Contents/Info.plist"
    if [[ -f "$SPARKLE_UPDATER_PLIST" ]]; then
        # Sparkle's progress helper is named "Updater" by default, which is what
        # macOS shows in App Management. Brand it as Resonant before signing.
        SPARKLE_UPDATER_RESOURCES_DIR="$(dirname "$SPARKLE_UPDATER_PLIST")/Resources"
        mkdir -p "$SPARKLE_UPDATER_RESOURCES_DIR"
        if [[ -f "$ROOT_DIR/Sources/Resonant/Resources/AppIcon.icns" ]]; then
            cp "$ROOT_DIR/Sources/Resonant/Resources/AppIcon.icns" "$SPARKLE_UPDATER_RESOURCES_DIR/AppIcon.icns"
            resonant_upsert_plist_value "$SPARKLE_UPDATER_PLIST" CFBundleIconFile string "AppIcon"
        fi
        resonant_upsert_plist_value "$SPARKLE_UPDATER_PLIST" CFBundleName string "Resonant"
        resonant_upsert_plist_value "$SPARKLE_UPDATER_PLIST" CFBundleDisplayName string "Resonant"
    fi
fi

ICON_SRC="$ROOT_DIR/Sources/Resonant/Resources/AppIcon.icns"
if [[ -f "$ICON_SRC" ]]; then
    cp "$ICON_SRC" "$RESOURCES_DIR/AppIcon.icns"
fi

for public_document in LICENSE NOTICE; do
    if [[ -f "$ROOT_DIR/$public_document" ]]; then
        cp "$ROOT_DIR/$public_document" "$RESOURCES_DIR/$public_document"
    fi
done
if [[ -f "$ROOT_DIR/docs/models.md" ]]; then
    cp "$ROOT_DIR/docs/models.md" "$RESOURCES_DIR/MODEL-LICENSES.md"
fi

THIRD_PARTY_LICENSES_DIR="$RESOURCES_DIR/ThirdPartyLicenses"
mkdir -p "$THIRD_PARTY_LICENSES_DIR"
license_specs=(
    "$ROOT_DIR/.build/checkouts/Defaults/license|Defaults-MIT.txt"
    "$ROOT_DIR/.build/checkouts/FluidAudio/LICENSE|FluidAudio-Apache-2.0.txt"
    "$ROOT_DIR/.build/checkouts/KeyboardShortcuts/license|KeyboardShortcuts-MIT.txt"
    "$ROOT_DIR/.build/checkouts/LaunchAtLogin/license|LaunchAtLogin-MIT.txt"
    "$ROOT_DIR/.build/checkouts/plcrashreporter/LICENSE|PLCrashReporter.txt"
    "$ROOT_DIR/.build/checkouts/posthog-ios/LICENSE|PostHog-MIT.txt"
    "$ROOT_DIR/.build/checkouts/sentry-cocoa/LICENSE.md|Sentry-MIT.txt"
    "$ROOT_DIR/.build/checkouts/Sparkle/LICENSE|Sparkle.txt"
    "$ROOT_DIR/Vendor/LICENSE-text-processing-rs|text-processing-rs-Apache-2.0.txt"
    "$ROOT_DIR/Vendor/LICENSE-lazy_static-MIT|lazy_static-MIT.txt"
)
for license_spec in "${license_specs[@]}"; do
    license_source="${license_spec%%|*}"
    license_name="${license_spec##*|}"
    if [[ ! -f "$license_source" ]]; then
        echo "Error: required third-party license is missing: $license_source" >&2
        exit 1
    fi
    cp "$license_source" "$THIRD_PARTY_LICENSES_DIR/$license_name"
done

for bundle_path in "$SOURCE_PRODUCTS_DIR"/*.bundle; do
    [[ -e "$bundle_path" ]] || continue
    ditto "$bundle_path" "$RESOURCES_DIR/$(basename "$bundle_path")"
done

if [[ -d "$RESOURCES_DIR/LaunchAtLogin_LaunchAtLogin.bundle" ]]; then
    LAUNCH_AT_LOGIN_BUNDLE="$RESOURCES_DIR/LaunchAtLogin_LaunchAtLogin.bundle"
    LAUNCH_AT_LOGIN_HELPER_ZIP="$LAUNCH_AT_LOGIN_BUNDLE/LaunchAtLoginHelper-with-runtime.zip"
    if [[ ! -f "$LAUNCH_AT_LOGIN_HELPER_ZIP" ]]; then
        LAUNCH_AT_LOGIN_HELPER_ZIP="$LAUNCH_AT_LOGIN_BUNDLE/LaunchAtLoginHelper.zip"
    fi

    LAUNCH_AT_LOGIN_HELPER_APP="$CONTENTS_DIR/Library/LoginItems/LaunchAtLoginHelper.app"
    /bin/rm -rf "$LAUNCH_AT_LOGIN_HELPER_APP"
    mkdir -p "$CONTENTS_DIR/Library/LoginItems"
    ditto -x -k "$LAUNCH_AT_LOGIN_HELPER_ZIP" "$CONTENTS_DIR/Library/LoginItems"

    /usr/libexec/PlistBuddy \
        -c "Set :CFBundleIdentifier ${MAIN_BUNDLE_IDENTIFIER}-LaunchAtLoginHelper" \
        "$LAUNCH_AT_LOGIN_HELPER_APP/Contents/Info.plist" >/dev/null

    LAUNCH_AT_LOGIN_ENTITLEMENTS="$LAUNCH_AT_LOGIN_BUNDLE/LaunchAtLogin.entitlements"
    if [[ "$REAL_RELEASE_SIGNATURE" == "1" ]]; then
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --deep --options runtime \
            --entitlements "$LAUNCH_AT_LOGIN_ENTITLEMENTS" \
            "$LAUNCH_AT_LOGIN_HELPER_APP"
    else
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --deep \
            --options runtime \
            --entitlements "$LAUNCH_AT_LOGIN_ENTITLEMENTS" \
            "$LAUNCH_AT_LOGIN_HELPER_APP"
    fi

    /bin/rm -rf "$LAUNCH_AT_LOGIN_BUNDLE"
fi

if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
    if [[ "$REAL_RELEASE_SIGNATURE" == "1" ]]; then
        # Sign Sparkle inside-out (required for notarization — --deep is unreliable)
        SPARKLE_FW="$FRAMEWORKS_DIR/Sparkle.framework"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
            "$SPARKLE_FW/Versions/B/XPCServices/Downloader.xpc"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
            "$SPARKLE_FW/Versions/B/XPCServices/Installer.xpc"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
            "$SPARKLE_FW/Versions/B/Updater.app"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp --options runtime \
            "$SPARKLE_FW/Versions/B/Autoupdate"
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp \
            "$SPARKLE_FW"
    else
        codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none --deep "$FRAMEWORKS_DIR/Sparkle.framework"
    fi
fi

if [[ "$REAL_RELEASE_SIGNATURE" == "1" ]]; then
    codesign_args=(
        --force
        --sign "$SIGNING_IDENTITY"
        --timestamp
        --options runtime
        --identifier "$MAIN_BUNDLE_IDENTIFIER"
        --entitlements "$ENTITLEMENTS_PATH"
    )
else
    codesign_args=(
        --force
        --sign "$SIGNING_IDENTITY"
        --timestamp=none
        --deep
        --identifier "$MAIN_BUNDLE_IDENTIFIER"
    )
    if [[ -f "$ENTITLEMENTS_PATH" ]]; then
        codesign_args+=(--entitlements "$ENTITLEMENTS_PATH")
    fi
fi

codesign "${codesign_args[@]}" "$APP_DIR"

if [[ "$RELEASE_BUILD" == "1" && "$DISTRIBUTION" == "official" ]]; then
    resonant_assert_team_signature "$APP_DIR" "packaged app"
    if [[ -d "$FRAMEWORKS_DIR/Sparkle.framework" ]]; then
        resonant_assert_team_signature \
            "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Updater.app" "Sparkle Updater.app"
        resonant_assert_team_signature \
            "$FRAMEWORKS_DIR/Sparkle.framework/Versions/B/Autoupdate" "Sparkle Autoupdate"
    fi
fi

upload_sentry_dsyms

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    echo "Packaged with ad-hoc signing; Accessibility trust may reset after rebuilds." >&2
else
    echo "Packaged with signing identity: $SIGNING_IDENTITY" >&2
fi
echo "Packaged environment: $(/usr/libexec/PlistBuddy -c 'Print :ResonantAppEnvironment' "$CONTENTS_DIR/Info.plist" 2>/dev/null || echo "unknown")" >&2
echo "Packaged bundle id: $MAIN_BUNDLE_IDENTIFIER" >&2
echo "Packaged version: $APP_VERSION (build $BUILD_NUMBER)" >&2

echo "$APP_DIR"
