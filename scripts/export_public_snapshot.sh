#!/bin/zsh
# Materialize a reviewed public tree without changing the repository's real index.
#
# Usage:
#   scripts/export_public_snapshot.sh --ref <commit-ish> <target-directory>
#   scripts/export_public_snapshot.sh --working-tree <target-directory>
#
# --ref archives exactly one resolved commit. --working-tree builds a temporary
# index from HEAD, then stages tracked changes and non-ignored untracked files in
# that temporary index. Neither mode includes ignored files.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MODE=""
SOURCE_REF=""
TARGET_INPUT=""
TEMP_INDEX=""

usage() {
    print -u2 -- "Usage: $0 (--ref <commit-ish> | --working-tree) <target-directory>"
}

fail() {
    print -u2 -- "Error: $*"
    exit 1
}

cleanup() {
    if [[ -n "$TEMP_INDEX" ]]; then
        /bin/rm -f -- "$TEMP_INDEX" "${TEMP_INDEX}.lock"
    fi
}
trap cleanup EXIT INT TERM

while (( $# > 0 )); do
    case "$1" in
        --ref)
            [[ -z "$MODE" ]] || fail "choose exactly one source mode"
            (( $# >= 2 )) || { usage; exit 2; }
            MODE="ref"
            SOURCE_REF="$2"
            shift 2
            ;;
        --working-tree)
            [[ -z "$MODE" ]] || fail "choose exactly one source mode"
            MODE="working-tree"
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        --*)
            fail "unknown option '$1'"
            ;;
        *)
            [[ -z "$TARGET_INPUT" ]] || fail "only one target directory is allowed"
            TARGET_INPUT="$1"
            shift
            ;;
    esac
done

[[ -n "$MODE" && -n "$TARGET_INPUT" ]] || { usage; exit 2; }

# Resolve without requiring the target itself to exist.
TARGET_PARENT="$(cd "$(dirname "$TARGET_INPUT")" && pwd)"
TARGET="$TARGET_PARENT/$(basename "$TARGET_INPUT")"

case "$TARGET/" in
    "$ROOT_DIR/"*) fail "target must be outside the source worktree" ;;
esac

mkdir -p -- "$TARGET"
if [[ -n "$(find "$TARGET" -mindepth 1 -maxdepth 1 ! -name .git -print -quit)" ]]; then
    fail "target is not empty (only an existing .git directory is allowed)"
fi

EXCLUDES=(
    ".mcp.json"
    "CLAUDE.md"
    "DEV_LOG.md"
    "docs/cloud-processing-implementation-checklist.md"
    "docs/cloud-processing-improvement-spec.md"
    "docs/environment-staging.md"
    "docs/founder-growth-operating-system.md"
    "docs/meeting-recap-sharing-rollout.md"
    "docs/release-distribution-checklist.md"
    "docs/swift-product-data-operating-plan.md"
    "docs/unified-analytics-dashboard.md"
    "scripts/check_live_sparkle_update.sh"
    "scripts/release.sh"
    "scripts/release_continue.sh"
    "scripts/release_sparkle_only.sh"
    "scripts/setup_posthog_paste_experiment.py"
    "scripts/update_homebrew.sh"
    "scripts/verify_release_artifacts.sh"
    "scripts/verify_sparkle_ed_signature.swift"
)

if [[ "$MODE" == "ref" ]]; then
    ARCHIVE_OBJECT="$(git -C "$ROOT_DIR" rev-parse --verify "${SOURCE_REF}^{commit}")" \
        || fail "'$SOURCE_REF' does not resolve to a commit"
    SOURCE_DESCRIPTION="commit $ARCHIVE_OBJECT"
else
    TEMP_INDEX="$(mktemp "${TMPDIR:-/tmp}/resonant-public-index.XXXXXX")"
    /bin/rm -f -- "$TEMP_INDEX"
    GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT_DIR" read-tree HEAD
    GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT_DIR" add -A -- .
    ARCHIVE_OBJECT="$(GIT_INDEX_FILE="$TEMP_INDEX" git -C "$ROOT_DIR" write-tree)"
    SOURCE_DESCRIPTION="working tree $ARCHIVE_OBJECT"
fi

git -C "$ROOT_DIR" archive "$ARCHIVE_OBJECT" | tar -x -C "$TARGET"

# Every path is relative to the newly materialized target. The target was
# required to be empty, so recursive removal cannot touch pre-existing content.
for exclude_file in "${EXCLUDES[@]}"; do
    /bin/rm -rf -- "$TARGET/$exclude_file"
done

validate_internal_identifiers() {
    local secret_label_pattern service_url_pattern personal_path_pattern
    secret_label_pattern='ADMIN_SECRET'
    service_url_pattern='https?://[^/[:space:]]+\.convex\.(cloud|site)|https?://linear\.app/[^/[:space:]]+'
    personal_path_pattern='/Users/[A-Za-z0-9._-]+'

    # The exporter contains the generic denylist by design.
    if command -v rg >/dev/null 2>&1; then
        if rg -n -H -I --hidden \
            --glob '!**/scripts/export_public_snapshot.sh' \
            "$secret_label_pattern" "$TARGET"; then
            fail "internal identifier found in public snapshot"
        fi
        # Keep only explicitly synthetic hosted-service fixtures. Everything
        # else should be configured by a downstream operator, not committed.
        if rg -n -H -I --hidden \
            --glob '!**/scripts/export_public_snapshot.sh' \
            "$service_url_pattern" "$TARGET" \
            | rg -v 'https://(example|ignored)\.convex\.cloud|https://linear\.app/(example-workspace|resonant)/'; then
            fail "non-synthetic hosted-service URL found in public snapshot"
        fi
        # Synthetic paths used in docs/tests are allowed; real developer home
        # directory names are not.
        if rg -n -H -I --hidden \
            --glob '!**/scripts/export_public_snapshot.sh' \
            "$personal_path_pattern" "$TARGET" \
            | rg -v '/Users/(dev|example)/'; then
            fail "developer home path found in public snapshot"
        fi
    else
        if grep -RInE \
            --exclude=export_public_snapshot.sh \
            "$secret_label_pattern" "$TARGET"; then
            fail "internal identifier found in public snapshot"
        fi
        if grep -RInE \
            --exclude=export_public_snapshot.sh \
            "$service_url_pattern" "$TARGET" \
            | grep -Ev 'https://(example|ignored)\.convex\.cloud|https://linear\.app/(example-workspace|resonant)/'; then
            fail "non-synthetic hosted-service URL found in public snapshot"
        fi
        if grep -RInE \
            --exclude=export_public_snapshot.sh \
            "$personal_path_pattern" "$TARGET" \
            | grep -Ev '/Users/(dev|example)/'; then
            fail "developer home path found in public snapshot"
        fi
    fi

    if find "$TARGET/Vendor" -type f \
        -exec grep -aHnE "$secret_label_pattern|$service_url_pattern|$personal_path_pattern" {} + 2>/dev/null; then
        fail "internal identifier found in vendored public artifact"
    fi
}

validate_markdown_links() {
    local markdown_file markdown_dir raw_link link_path
    local found_broken=0

    while IFS= read -r -d '' markdown_file; do
        markdown_dir="$(dirname "$markdown_file")"
        while IFS= read -r raw_link; do
            # This deliberately validates ordinary inline local links. Reference
            # definitions, generated anchors, and remote URLs are outside scope.
            raw_link="${raw_link#<}"
            raw_link="${raw_link%>}"
            case "$raw_link" in
                ''|'#'*|http://*|https://*|mailto:*|app://*) continue ;;
            esac
            link_path="${raw_link%%#*}"
            link_path="${link_path%%\?*}"
            # Public docs use simple paths; URL-decode the common space escape.
            link_path="${link_path//%20/ }"
            if [[ "$link_path" == /* || ! -e "$markdown_dir/$link_path" ]]; then
                print -u2 -- "Broken local Markdown link: ${markdown_file#$TARGET/} -> $raw_link"
                found_broken=1
            fi
        done < <(perl -ne 'while (/\[[^\]]*\]\(([^)]+)\)/g) { print "$1\n" }' "$markdown_file")
    done < <(find "$TARGET" -type f -name '*.md' -print0)

    (( found_broken == 0 )) || fail "public snapshot contains broken local Markdown links"
}

validate_required_surface() {
    local required_file
    for required_file in \
        README.md LICENSE NOTICE CONTRIBUTING.md CODE_OF_CONDUCT.md SECURITY.md SUPPORT.md \
        docs/privacy-and-data.md docs/models.md; do
        [[ -f "$TARGET/$required_file" ]] || fail "required public file missing: $required_file"
    done
}

validate_required_surface
validate_internal_identifiers
validate_markdown_links

print -- "Public snapshot exported from $SOURCE_DESCRIPTION"
print -- "Target: $TARGET"
print -- "Next: run a history-aware secret scan, inspect licenses/notices, then initialize or commit the public repository."
