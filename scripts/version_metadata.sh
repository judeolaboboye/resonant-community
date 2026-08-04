#!/bin/zsh

resonant_read_plist_value() {
    local plist_path="$1"
    local key="$2"
    /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path"
}

resonant_upsert_plist_value() {
    local plist_path="$1"
    local key="$2"
    local type="$3"
    local value="$4"

    /usr/libexec/PlistBuddy -c "Set :$key $value" "$plist_path" >/dev/null 2>&1 || \
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$plist_path" >/dev/null
}

resonant_effective_app_version() {
    local info_plist_path="$1"
    local version="${RESONANT_APP_VERSION:-}"

    if [[ -z "$version" ]]; then
        version="$(resonant_read_plist_value "$info_plist_path" CFBundleShortVersionString)"
    fi

    if [[ -z "$version" ]]; then
        echo "Error: CFBundleShortVersionString is empty" >&2
        return 1
    fi

    print -r -- "$version"
}

resonant_generated_release_build_number() {
    date -u +"%Y%m%d%H%M%S"
}

resonant_effective_build_number() {
    local info_plist_path="$1"
    local release_build="${2:-${RESONANT_RELEASE_BUILD:-0}}"
    local build_number="${RESONANT_BUILD_NUMBER:-}"

    if [[ -z "$build_number" ]]; then
        build_number="$(resonant_read_plist_value "$info_plist_path" CFBundleVersion)"
    fi

    if [[ "$release_build" == "1" && ( -z "$build_number" || "$build_number" == "1" ) ]]; then
        build_number="$(resonant_generated_release_build_number)"
    fi

    if [[ -z "$build_number" ]]; then
        echo "Error: CFBundleVersion is empty" >&2
        return 1
    fi

    if [[ ! "$build_number" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
        echo "Error: CFBundleVersion must be numeric (received '$build_number')" >&2
        return 1
    fi

    print -r -- "$build_number"
}

resonant_effective_update_check_interval() {
    local interval="${RESONANT_UPDATE_CHECK_INTERVAL:-14400}"

    if [[ ! "$interval" =~ ^[0-9]+$ || "$interval" -le 0 ]]; then
        echo "Error: RESONANT_UPDATE_CHECK_INTERVAL must be a positive integer in seconds" >&2
        return 1
    fi

    print -r -- "$interval"
}

resonant_effective_automatic_downloads() {
    local distribution="${1:-$(resonant_effective_distribution)}"
    local default_value="false"
    if [[ "$distribution" == "official" ]]; then
        default_value="true"
    fi
    local raw_value="${RESONANT_AUTOMATICALLY_DOWNLOAD_UPDATES:-$default_value}"
    local normalized="${(L)raw_value}"

    case "$normalized" in
        1|true|yes)
            print -r -- "true"
            ;;
        0|false|no|"")
            print -r -- "false"
            ;;
        *)
            echo "Error: RESONANT_AUTOMATICALLY_DOWNLOAD_UPDATES must be true/false" >&2
            return 1
            ;;
    esac
}

resonant_effective_distribution() {
    local info_plist_path="${1:-}"
    local raw_value="${RESONANT_DISTRIBUTION:-}"
    local normalized

    if [[ -z "$raw_value" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        raw_value="$(resonant_read_plist_value "$info_plist_path" ResonantDistribution 2>/dev/null || true)"
    fi

    if [[ -z "$raw_value" ]]; then
        print -r -- "community"
        return 0
    fi

    normalized="${(L)raw_value}"
    case "$normalized" in
        community|official)
            print -r -- "$normalized"
            ;;
        *)
            echo "Error: RESONANT_DISTRIBUTION must be community or official" >&2
            return 1
            ;;
    esac
}

resonant_effective_bundle_identifier() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local bundle_identifier="${RESONANT_BUNDLE_IDENTIFIER:-}"
    local distribution="${2:-$(resonant_effective_distribution)}"

    if [[ -z "$bundle_identifier" ]]; then
        case "$distribution:$release_build" in
            community:1) bundle_identifier="org.resonant.community" ;;
            community:*) bundle_identifier="org.resonant.community.dev" ;;
            official:1) bundle_identifier="com.resonance.resonant" ;;
            official:*) bundle_identifier="com.resonance.resonant.dev" ;;
        esac
    fi

    if [[ ! "$bundle_identifier" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$ ]]; then
        echo "Error: RESONANT_BUNDLE_IDENTIFIER is not a valid bundle identifier ('$bundle_identifier')" >&2
        return 1
    fi

    print -r -- "$bundle_identifier"
}

resonant_effective_callback_scheme() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local callback_scheme="${RESONANT_CALLBACK_SCHEME:-}"
    local distribution="${2:-$(resonant_effective_distribution)}"

    if [[ -z "$callback_scheme" ]]; then
        case "$distribution:$release_build" in
            community:1) callback_scheme="resonant-community" ;;
            community:*) callback_scheme="resonant-community-dev" ;;
            official:1) callback_scheme="resonantmac" ;;
            official:*) callback_scheme="resonantmac-dev" ;;
        esac
    fi

    if [[ ! "$callback_scheme" =~ ^[A-Za-z][A-Za-z0-9+.-]*$ ]]; then
        echo "Error: RESONANT_CALLBACK_SCHEME is not a valid URL scheme ('$callback_scheme')" >&2
        return 1
    fi

    print -r -- "$callback_scheme"
}

resonant_effective_legacy_callback_scheme() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${2:-$(resonant_effective_distribution)}"

    if [[ "$distribution" == "community" ]]; then
        print -r -- ""
    elif [[ "$release_build" == "1" ]]; then
        print -r -- "resonant"
    else
        print -r -- "resonant-dev"
    fi
}

resonant_set_url_schemes() {
    local plist_path="$1"
    local bundle_identifier="$2"
    local primary_scheme="$3"
    local secondary_scheme="$4"

    /usr/libexec/PlistBuddy -c "Delete :CFBundleURLTypes" "$plist_path" >/dev/null 2>&1 || true
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes array" "$plist_path" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0 dict" "$plist_path" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLName string $bundle_identifier" "$plist_path" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$plist_path" >/dev/null
    /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string $primary_scheme" "$plist_path" >/dev/null
    if [[ -n "$secondary_scheme" ]]; then
        /usr/libexec/PlistBuddy -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:1 string $secondary_scheme" "$plist_path" >/dev/null
    fi
}

resonant_effective_app_environment() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local raw_value="${RESONANT_APP_ENV:-}"
    local normalized

    if [[ -z "$raw_value" ]]; then
        if [[ "$release_build" == "1" ]]; then
            print -r -- "production"
        else
            print -r -- "development"
        fi
        return 0
    fi

    normalized="${(L)raw_value}"
    case "$normalized" in
        dev|development)
            print -r -- "development"
            ;;
        prod|production)
            print -r -- "production"
            ;;
        *)
            echo "Error: RESONANT_APP_ENV must be development or production" >&2
            return 1
            ;;
    esac
}

resonant_default_convex_cloud_url() {
    local environment="$1"

    case "$environment" in
        development|production)
            print -r -- ""
            ;;
        *)
            echo "Error: unknown app environment '$environment'" >&2
            return 1
            ;;
    esac
}

resonant_default_auth_base_url() {
    local environment="$1"

    case "$environment" in
        development|production)
            print -r -- ""
            ;;
        *)
            echo "Error: unknown app environment '$environment'" >&2
            return 1
            ;;
    esac
}

resonant_effective_convex_cloud_url() {
    local environment="$1"
    local info_plist_path="${2:-}"
    local override="${RESONANT_CONVEX_CLOUD_URL:-}"

    if [[ -n "$override" ]]; then
        print -r -- "$override"
        return 0
    fi

    if [[ "$environment" == "development" && -n "${RESONANT_DEV_CONVEX_CLOUD_URL:-}" ]]; then
        print -r -- "$RESONANT_DEV_CONVEX_CLOUD_URL"
        return 0
    fi

    if [[ -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        override="$(resonant_read_plist_value "$info_plist_path" ResonantConvexCloudURL 2>/dev/null || true)"
        if [[ -n "$override" ]]; then
            print -r -- "$override"
            return 0
        fi
    fi

    resonant_default_convex_cloud_url "$environment"
}

resonant_effective_auth_base_url() {
    local environment="$1"
    local info_plist_path="${2:-}"
    local override="${RESONANT_AUTH_BASE_URL:-}"

    if [[ -n "$override" ]]; then
        print -r -- "$override"
        return 0
    fi

    if [[ -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        override="$(resonant_read_plist_value "$info_plist_path" ResonantAuthBaseURL 2>/dev/null || true)"
        if [[ -n "$override" ]]; then
            print -r -- "$override"
            return 0
        fi
    fi

    resonant_default_auth_base_url "$environment"
}

resonant_is_http_url() {
    local url="$1"
    local remainder authority

    case "$url" in
        http://*|https://*) ;;
        *) return 1 ;;
    esac

    remainder="${url#*://}"
    authority="${remainder%%/*}"
    [[ -n "$authority" && "$authority" != *[[:space:]]* ]]
}

resonant_is_loopback_http_url() {
    local url="$1"
    case "$url" in
        http://localhost|http://localhost/*|http://localhost:*|\
        http://127.0.0.1|http://127.0.0.1/*|http://127.0.0.1:*|\
        'http://[::1]'|'http://[::1]/'*|'http://[::1]:'*) return 0 ;;
        *) return 1 ;;
    esac
}

resonant_validate_hosted_services_config() {
    local convex_cloud_url="$1"
    local auth_base_url="$2"
    local release_build="${3:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${4:-$(resonant_effective_distribution)}"

    if [[ -n "$convex_cloud_url" && -z "$auth_base_url" ]] || \
       [[ -z "$convex_cloud_url" && -n "$auth_base_url" ]]; then
        echo "Error: hosted services are an all-or-none configuration. Set both RESONANT_CONVEX_CLOUD_URL and RESONANT_AUTH_BASE_URL (or both matching Info.plist values), or leave both empty." >&2
        return 1
    fi

    if [[ -n "$convex_cloud_url" ]] && ! resonant_is_http_url "$convex_cloud_url"; then
        echo "Error: RESONANT_CONVEX_CLOUD_URL must be an http(s) URL" >&2
        return 1
    fi
    if [[ -n "$auth_base_url" ]] && ! resonant_is_http_url "$auth_base_url"; then
        echo "Error: RESONANT_AUTH_BASE_URL must be an http(s) URL" >&2
        return 1
    fi

    if [[ -n "$convex_cloud_url" && "$convex_cloud_url" != https://* ]]; then
        if [[ "$release_build" == "1" ]] || ! resonant_is_loopback_http_url "$convex_cloud_url"; then
            echo "Error: hosted service URLs require HTTPS; plain HTTP is allowed only for loopback development." >&2
            return 1
        fi
    fi
    if [[ -n "$auth_base_url" && "$auth_base_url" != https://* ]]; then
        if [[ "$release_build" == "1" ]] || ! resonant_is_loopback_http_url "$auth_base_url"; then
            echo "Error: hosted service URLs require HTTPS; plain HTTP is allowed only for loopback development." >&2
            return 1
        fi
    fi

    if [[ "$distribution" == "official" && "$release_build" == "1" && -z "$convex_cloud_url" ]]; then
        echo "Error: official release builds require explicit hosted services. Set RESONANT_CONVEX_CLOUD_URL and RESONANT_AUTH_BASE_URL; production endpoints are intentionally not stored in source." >&2
        return 1
    fi
}

resonant_effective_sentry_dsn() {
    local info_plist_path="${1:-}"
    local dsn="${RESONANT_SENTRY_DSN:-${SENTRY_DSN:-}}"
    if [[ -z "$dsn" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        dsn="$(resonant_read_plist_value "$info_plist_path" ResonantSentryDSN 2>/dev/null || true)"
    fi
    print -r -- "$dsn"
}

resonant_effective_posthog_api_key() {
    local info_plist_path="${1:-}"
    local api_key="${RESONANT_POSTHOG_API_KEY:-${POSTHOG_API_KEY:-}}"
    if [[ -z "$api_key" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        api_key="$(resonant_read_plist_value "$info_plist_path" ResonantPostHogAPIKey 2>/dev/null || true)"
    fi
    print -r -- "$api_key"
}

resonant_effective_sparkle_feed_url() {
    local info_plist_path="${1:-}"
    local feed_url="${RESONANT_SPARKLE_FEED_URL:-}"
    if [[ -z "$feed_url" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        feed_url="$(resonant_read_plist_value "$info_plist_path" SUFeedURL 2>/dev/null || true)"
    fi
    print -r -- "$feed_url"
}

resonant_effective_sparkle_public_ed_key() {
    local info_plist_path="${1:-}"
    local public_key="${RESONANT_SPARKLE_PUBLIC_ED_KEY:-}"
    if [[ -z "$public_key" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        public_key="$(resonant_read_plist_value "$info_plist_path" SUPublicEDKey 2>/dev/null || true)"
    fi
    print -r -- "$public_key"
}

resonant_validate_sparkle_runtime_config() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${2:-$(resonant_effective_distribution)}"
    local info_plist_path="${3:-}"
    local feed_url public_key
    feed_url="$(resonant_effective_sparkle_feed_url "$info_plist_path")"
    public_key="$(resonant_effective_sparkle_public_ed_key "$info_plist_path")"

    if [[ -n "$feed_url" && -z "$public_key" ]] || [[ -z "$feed_url" && -n "$public_key" ]]; then
        echo "Error: Sparkle configuration is incomplete. Set both RESONANT_SPARKLE_FEED_URL and RESONANT_SPARKLE_PUBLIC_ED_KEY, or leave both empty." >&2
        return 1
    fi

    if [[ "$distribution" == "official" && "$release_build" == "1" && -z "$feed_url" ]]; then
        echo "Error: official release builds need RESONANT_SPARKLE_FEED_URL and RESONANT_SPARKLE_PUBLIC_ED_KEY so shipped apps can receive updates. Community builds leave these empty by default." >&2
        return 1
    fi
}

resonant_validate_posthog_runtime_config() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${2:-$(resonant_effective_distribution)}"
    local info_plist_path="${3:-}"
    local require_api_key="${RESONANT_REQUIRE_POSTHOG_API_KEY:-}"

    if [[ -z "$require_api_key" ]]; then
        if [[ "$distribution" == "official" && "$release_build" == "1" ]]; then
            require_api_key="true"
        else
            require_api_key="false"
        fi
    fi

    if [[ "$require_api_key" == "true" && -z "$(resonant_effective_posthog_api_key "$info_plist_path")" ]]; then
        echo "Error: set RESONANT_POSTHOG_API_KEY or POSTHOG_API_KEY so the packaged app reports analytics to the intended PostHog project (or export RESONANT_REQUIRE_POSTHOG_API_KEY=false to ship without analytics)." >&2
        return 1
    fi
}

resonant_effective_sentry_project() {
    local info_plist_path="${1:-}"
    local project="${RESONANT_SENTRY_PROJECT:-${SENTRY_PROJECT:-}}"
    if [[ -z "$project" && -n "$info_plist_path" && -f "$info_plist_path" ]]; then
        project="$(resonant_read_plist_value "$info_plist_path" ResonantSentryProject 2>/dev/null || true)"
    fi
    print -r -- "$project"
}

resonant_should_require_sentry_dsn() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${2:-$(resonant_effective_distribution)}"
    local raw_value="${RESONANT_REQUIRE_SENTRY_DSN:-}"
    local normalized

    if [[ -z "$raw_value" ]]; then
        if [[ "$distribution" == "official" && "$release_build" == "1" ]]; then
            print -r -- "true"
        else
            print -r -- "false"
        fi
        return 0
    fi

    normalized="${(L)raw_value}"
    case "$normalized" in
        1|true|yes)
            print -r -- "true"
            ;;
        0|false|no)
            print -r -- "false"
            ;;
        *)
            echo "Error: RESONANT_REQUIRE_SENTRY_DSN must be true/false" >&2
            return 1
            ;;
    esac
}

resonant_validate_sentry_runtime_config() {
    local release_build="${1:-${RESONANT_RELEASE_BUILD:-0}}"
    local distribution="${2:-$(resonant_effective_distribution)}"
    local info_plist_path="${3:-}"
    local require_sentry_dsn sentry_dsn

    require_sentry_dsn="$(resonant_should_require_sentry_dsn "$release_build" "$distribution")"
    sentry_dsn="$(resonant_effective_sentry_dsn "$info_plist_path")"

    if [[ "$require_sentry_dsn" == "true" && -z "$sentry_dsn" ]]; then
        echo "Error: set RESONANT_SENTRY_DSN or SENTRY_DSN so the packaged app sends runtime events to the intended Sentry project." >&2
        return 1
    fi
}

resonant_materialize_info_plist() {
    local source_plist_path="$1"
    local destination_plist_path="$2"
    local release_build="${3:-${RESONANT_RELEASE_BUILD:-0}}"
    local version build_number update_check_interval automatically_downloads sentry_dsn sentry_project posthog_api_key sparkle_feed_url sparkle_public_ed_key app_environment distribution convex_cloud_url auth_base_url bundle_identifier callback_scheme legacy_callback_scheme updates_enabled

    distribution="$(resonant_effective_distribution "$source_plist_path")"
    version="$(resonant_effective_app_version "$source_plist_path")"
    build_number="$(resonant_effective_build_number "$source_plist_path" "$release_build")"
    update_check_interval="$(resonant_effective_update_check_interval)"
    automatically_downloads="$(resonant_effective_automatic_downloads "$distribution")"
    bundle_identifier="$(resonant_effective_bundle_identifier "$release_build" "$distribution")"
    callback_scheme="$(resonant_effective_callback_scheme "$release_build" "$distribution")"
    legacy_callback_scheme="$(resonant_effective_legacy_callback_scheme "$release_build" "$distribution")"
    app_environment="$(resonant_effective_app_environment "$release_build")"
    convex_cloud_url="$(resonant_effective_convex_cloud_url "$app_environment" "$source_plist_path")"
    auth_base_url="$(resonant_effective_auth_base_url "$app_environment" "$source_plist_path")"
    resonant_validate_hosted_services_config "$convex_cloud_url" "$auth_base_url" "$release_build" "$distribution" || return 1
    resonant_validate_sentry_runtime_config "$release_build" "$distribution" "$source_plist_path" || return 1
    sentry_dsn="$(resonant_effective_sentry_dsn "$source_plist_path")"
    sentry_project="$(resonant_effective_sentry_project "$source_plist_path")"
    resonant_validate_posthog_runtime_config "$release_build" "$distribution" "$source_plist_path" || return 1
    posthog_api_key="$(resonant_effective_posthog_api_key "$source_plist_path")"
    resonant_validate_sparkle_runtime_config "$release_build" "$distribution" "$source_plist_path" || return 1
    sparkle_feed_url="$(resonant_effective_sparkle_feed_url "$source_plist_path")"
    sparkle_public_ed_key="$(resonant_effective_sparkle_public_ed_key "$source_plist_path")"
    if [[ -n "$sparkle_feed_url" && -n "$sparkle_public_ed_key" ]]; then
        updates_enabled="true"
    else
        updates_enabled="false"
        automatically_downloads="false"
    fi

    cp "$source_plist_path" "$destination_plist_path"
    resonant_upsert_plist_value "$destination_plist_path" CFBundleIdentifier string "$bundle_identifier"
    resonant_upsert_plist_value "$destination_plist_path" CFBundleShortVersionString string "$version"
    resonant_upsert_plist_value "$destination_plist_path" CFBundleVersion string "$build_number"
    if [[ "$distribution" == "official" && "$release_build" == "1" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" CFBundleName string "Resonant"
        resonant_upsert_plist_value "$destination_plist_path" CFBundleDisplayName string "Resonant"
    elif [[ "$distribution" == "official" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" CFBundleName string "Resonant Dev"
        resonant_upsert_plist_value "$destination_plist_path" CFBundleDisplayName string "Resonant Dev"
    elif [[ "$release_build" == "1" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" CFBundleName string "Resonant Community"
        resonant_upsert_plist_value "$destination_plist_path" CFBundleDisplayName string "Resonant Community"
    else
        resonant_upsert_plist_value "$destination_plist_path" CFBundleName string "Resonant Community Dev"
        resonant_upsert_plist_value "$destination_plist_path" CFBundleDisplayName string "Resonant Community Dev"
    fi
    resonant_set_url_schemes "$destination_plist_path" "$bundle_identifier" "$callback_scheme" "$legacy_callback_scheme"
    resonant_upsert_plist_value "$destination_plist_path" SUEnableAutomaticChecks bool "$updates_enabled"
    resonant_upsert_plist_value "$destination_plist_path" SUScheduledCheckInterval integer "$update_check_interval"
    resonant_upsert_plist_value "$destination_plist_path" SUAutomaticallyUpdate bool "$automatically_downloads"
    resonant_upsert_plist_value "$destination_plist_path" ResonantDistribution string "$distribution"
    resonant_upsert_plist_value "$destination_plist_path" ResonantAppEnvironment string "$app_environment"
    resonant_upsert_plist_value "$destination_plist_path" ResonantConvexCloudURL string "$convex_cloud_url"
    resonant_upsert_plist_value "$destination_plist_path" ResonantAuthBaseURL string "$auth_base_url"
    if [[ -n "$sentry_dsn" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" ResonantSentryDSN string "$sentry_dsn"
    fi
    if [[ -n "$sentry_project" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" ResonantSentryProject string "$sentry_project"
    fi
    if [[ -n "$posthog_api_key" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" ResonantPostHogAPIKey string "$posthog_api_key"
    fi
    if [[ -n "$sparkle_feed_url" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" SUFeedURL string "$sparkle_feed_url"
    fi
    if [[ -n "$sparkle_public_ed_key" ]]; then
        resonant_upsert_plist_value "$destination_plist_path" SUPublicEDKey string "$sparkle_public_ed_key"
    fi
}

# ─── Code-signing health checks ────────────────────────────────────────────────
# A Developer ID signature must carry TeamIdentifier and an Apple-anchored
# designated requirement. Without them, macOS App Management cannot apply the
# same-team exemption and Sparkle updates prompt users to approve the updater
# on every release (see release 0.1.82).

resonant_expected_team_id() {
    if [[ -z "${RESONANT_EXPECTED_TEAM_ID:-}" ]]; then
        echo "Error: set RESONANT_EXPECTED_TEAM_ID for an official signed release." >&2
        return 1
    fi
    print -r -- "$RESONANT_EXPECTED_TEAM_ID"
}

# Custom keychain trust overrides on Apple CA certificates break codesign's
# Apple-anchored chain evaluation: it silently emits TeamIdentifier=not set
# and a weak "certificate leaf = H..." designated requirement.
resonant_assert_clean_apple_trust_settings() {
    local overrides
    overrides="$(security dump-trust-settings 2>/dev/null \
        | grep -E 'Developer ID Certification Authority|Apple Root CA|Apple Worldwide Developer Relations' || true)"
    if [[ -n "$overrides" ]]; then
        echo "Error: custom keychain trust settings exist on Apple CA certificates:" >&2
        print -r -- "$overrides" >&2
        echo "These make codesign emit signatures with TeamIdentifier=not set, which breaks" >&2
        echo "silent Sparkle self-updates (users get App Management prompts every release)." >&2
        echo "Fix: Keychain Access -> select the certificate -> Trust -> 'Use System Defaults'," >&2
        echo "or export the cert and run: security remove-trusted-cert <cert.pem>" >&2
        return 1
    fi
}

resonant_assert_team_signature() {
    local target_path="$1"
    local label="${2:-$target_path}"
    local expected_team team_line requirement
    expected_team="$(resonant_expected_team_id)"

    team_line="$(codesign -dv "$target_path" 2>&1 | grep '^TeamIdentifier=' || true)"
    if [[ "$team_line" != "TeamIdentifier=$expected_team" ]]; then
        echo "Error: $label has '${team_line:-no TeamIdentifier}', expected TeamIdentifier=$expected_team." >&2
        echo "Run 'security dump-trust-settings' — Apple CA trust overrides are the usual cause." >&2
        return 1
    fi

    requirement="$(codesign -d -r- "$target_path" 2>&1 | sed -n 's/^designated => //p')"
    if [[ "$requirement" != *"anchor apple generic"* ]] || {
        [[ "$requirement" != *"subject.OU] = $expected_team"* ]] &&
        [[ "$requirement" != *"subject.OU] = \"$expected_team\""* ]]
    }; then
        echo "Error: $label designated requirement is not Apple-anchored to team $expected_team:" >&2
        echo "    ${requirement:-<none>}" >&2
        return 1
    fi
}

# Catches broken signing in seconds, before a multi-minute build + notarize:
# sign a scratch binary with the release identity and validate the result.
resonant_assert_signing_identity_healthy() {
    local identity="$1"
    local scratch
    scratch="$(mktemp "${TMPDIR:-/tmp}/resonant-sign-probe.XXXXXX")"
    {
        cp /bin/ls "$scratch"
        codesign --force --sign "$identity" --timestamp=none "$scratch" >/dev/null 2>&1 || {
            echo "Error: test codesign with identity '$identity' failed" >&2
            return 1
        }
        resonant_assert_team_signature "$scratch" "signing probe for '$identity'"
    } always {
        rm -f "$scratch"
    }
}
