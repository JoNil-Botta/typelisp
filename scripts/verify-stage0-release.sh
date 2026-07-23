#!/usr/bin/env sh
set -eu

# verify-stage0-release.sh - Publish and verify the mutable stage0 release.
#
# `gh release create` creates a draft, uploads assets, and then publishes it.
# A failed or skipped final publish has previously left a complete draft while
# still allowing the bootstrap workflow to report success. Find the release in
# the authenticated release list (which includes drafts), validate its payload,
# explicitly publish a complete draft, and then prove both the public tag API
# and stable compiler asset URLs resolve.

usage() {
    cat <<'EOF'
usage:
  scripts/verify-stage0-release.sh --self-test
  scripts/verify-stage0-release.sh REPO TAG EXPECTED_SHA ASSET...

Live verification requires authenticated `gh` and `curl`. The caller must list
the complete expected asset set. Publication/URL propagation retries default to
12 attempts with a 5-second delay; override them with
TYPELISP_STAGE0_VERIFY_ATTEMPTS and TYPELISP_STAGE0_VERIFY_DELAY.
EOF
}

fail() {
    echo "[stage0-release] $*" >&2
    return 1
}

# Keep the multi-field API projection in one tested filter. Parenthesize the
# piped fields: without the first pair, jq evaluates the later object lookups
# against `.id` and fails with "expected an object but got: number".
RELEASE_RECORD_JQ='[ (.id | tostring), (.draft | tostring), .target_commitish, (.published_at // "") ] | join("|")'

# Validate state already returned by the GitHub releases API. Assets are a
# sorted, newline-separated list so duplicates and unexpected names fail too.
validate_release_payload() {
    release_id=$1
    target=$2
    actual_assets=$3
    expected_sha=$4
    expected_assets=$5

    if [ "$target" != "$expected_sha" ]; then
        fail "release $release_id targets $target, expected $expected_sha"
        return 1
    fi
    if [ "$actual_assets" != "$expected_assets" ]; then
        echo "[stage0-release] release $release_id asset set mismatch" >&2
        echo "[stage0-release] expected:" >&2
        printf '%s\n' "$expected_assets" | sed 's/^/  /' >&2
        echo "[stage0-release] actual:" >&2
        printf '%s\n' "$actual_assets" | sed 's/^/  /' >&2
        return 1
    fi
}

validate_published_release() {
    release_id=$1
    draft=$2
    target=$3
    published_at=$4
    actual_assets=$5
    expected_sha=$6
    expected_assets=$7

    validate_release_payload \
        "$release_id" "$target" "$actual_assets" \
        "$expected_sha" "$expected_assets" || return 1
    if [ "$draft" != false ]; then
        fail "release $release_id is still draft=$draft"
        return 1
    fi
    if [ -z "$published_at" ]; then
        fail "release $release_id is public but has no published_at timestamp"
        return 1
    fi
}

expect_failure() {
    expected=$1
    shift
    set +e
    output=$("$@" 2>&1)
    status=$?
    set -e
    if [ "$status" -eq 0 ]; then
        echo "self-test expected failure containing: $expected" >&2
        return 1
    fi
    case "$output" in
        *"$expected"*) ;;
        *)
            echo "self-test failure did not contain '$expected':" >&2
            echo "$output" >&2
            return 1
            ;;
    esac
}

self_test() {
    expected_sha=0123456789abcdef0123456789abcdef01234567
    expected_assets=$(printf '%s\n' \
        SHA256SUMS \
        typelisp-stage0-linux \
        typelisp-stage0-windows.exe \
        typelisp.vsix | LC_ALL=C sort)
    missing_assets=$(printf '%s\n' \
        SHA256SUMS \
        typelisp-stage0-linux \
        typelisp.vsix | LC_ALL=C sort)
    command -v jq >/dev/null 2>&1 || {
        echo "self-test requires jq" >&2
        return 1
    }
    release_record=$(printf '%s\n' \
        '{"id":100,"draft":false,"target_commitish":"0123456789abcdef0123456789abcdef01234567","published_at":"2026-07-23T00:00:00Z"}' |
        jq -r "$RELEASE_RECORD_JQ")
    if [ "$release_record" != "100|false|$expected_sha|2026-07-23T00:00:00Z" ]; then
        echo "self-test release record projection mismatch: $release_record" >&2
        return 1
    fi

    validate_published_release \
        100 false "$expected_sha" 2026-07-23T00:00:00Z \
        "$expected_assets" "$expected_sha" "$expected_assets"
    expect_failure "still draft=true" \
        validate_published_release \
        101 true "$expected_sha" "" \
        "$expected_assets" "$expected_sha" "$expected_assets"
    expect_failure "asset set mismatch" \
        validate_published_release \
        102 false "$expected_sha" 2026-07-23T00:00:00Z \
        "$missing_assets" "$expected_sha" "$expected_assets"
    expect_failure "targets deadbeef" \
        validate_published_release \
        103 false deadbeef 2026-07-23T00:00:00Z \
        "$expected_assets" "$expected_sha" "$expected_assets"
    echo "stage0 release verification self-test passed"
}

if [ "${1:-}" = --self-test ]; then
    [ "$#" -eq 1 ] || {
        usage >&2
        exit 2
    }
    self_test
    exit 0
fi

[ "$#" -ge 5 ] || {
    usage >&2
    exit 2
}

REPO=$1
TAG=$2
EXPECTED_SHA=$3
shift 3
EXPECTED_ASSETS=$(printf '%s\n' "$@" | LC_ALL=C sort)
ATTEMPTS=${TYPELISP_STAGE0_VERIFY_ATTEMPTS:-12}
DELAY=${TYPELISP_STAGE0_VERIFY_DELAY:-5}

case "$ATTEMPTS" in
    "" | *[!0-9]* | 0)
        echo "TYPELISP_STAGE0_VERIFY_ATTEMPTS must be a positive integer" >&2
        exit 2
        ;;
esac
case "$DELAY" in
    "" | *[!0-9]*)
        echo "TYPELISP_STAGE0_VERIFY_DELAY must be a non-negative integer" >&2
        exit 2
        ;;
esac

for command in gh curl; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "missing required command: $command" >&2
        exit 2
    }
done

# The tag endpoint hides drafts. Search the authenticated list first so a
# complete draft can be recovered and its id can be reported actionably.
release_ids=$(gh api "repos/$REPO/releases?per_page=100" \
    --jq ".[] | select(.tag_name == \"$TAG\") | .id")
if [ -z "$release_ids" ]; then
    echo "[stage0-release] no release (published or draft) found for tag $TAG" >&2
    exit 1
fi
if [ "$(printf '%s\n' "$release_ids" | wc -l | tr -d ' ')" -ne 1 ]; then
    echo "[stage0-release] multiple releases found for tag $TAG: $release_ids" >&2
    exit 1
fi
release_id=$release_ids

release_record=$(gh api "repos/$REPO/releases/$release_id" \
    --jq "$RELEASE_RECORD_JQ")
IFS='|' read -r record_id draft target published_at <<EOF
$release_record
EOF
actual_assets=$(gh api "repos/$REPO/releases/$release_id" \
    --jq '.assets[].name' | LC_ALL=C sort)
validate_release_payload \
    "$record_id" "$target" "$actual_assets" \
    "$EXPECTED_SHA" "$EXPECTED_ASSETS"

if [ "$draft" = true ]; then
    echo "[stage0-release] publishing complete draft release $record_id for $TAG"
    gh api --method PATCH "repos/$REPO/releases/$record_id" \
        -F draft=false >/dev/null
elif [ "$draft" != false ]; then
    echo "[stage0-release] release $record_id has invalid draft state: $draft" >&2
    exit 1
fi

# Prove the public tag endpoint exposes the exact release. It can lag the PATCH
# briefly, so retry only this external propagation boundary.
published=false
attempt=1
while [ "$attempt" -le "$ATTEMPTS" ]; do
    if tag_record=$(gh api "repos/$REPO/releases/tags/$TAG" \
        --jq "$RELEASE_RECORD_JQ" \
        2>/dev/null); then
        IFS='|' read -r tag_id tag_draft tag_target tag_published_at <<EOF
$tag_record
EOF
        tag_assets=$(gh api "repos/$REPO/releases/$tag_id" \
            --jq '.assets[].name' | LC_ALL=C sort)
        # A visible wrong target or asset set is not propagation and cannot
        # heal; fail immediately rather than retrying the wrong release.
        validate_release_payload \
            "$tag_id" "$tag_target" "$tag_assets" \
            "$EXPECTED_SHA" "$EXPECTED_ASSETS" || exit 1
        if [ "$tag_draft" = false ] && [ -n "$tag_published_at" ]; then
            published=true
            release_id=$tag_id
            break
        fi
        if [ "$tag_draft" != true ] && [ "$tag_draft" != false ]; then
            echo "[stage0-release] release $tag_id has invalid draft state: $tag_draft" >&2
            exit 1
        fi
    fi
    if [ "$attempt" -lt "$ATTEMPTS" ]; then
        echo "[stage0-release] public tag API not ready (attempt $attempt/$ATTEMPTS); retrying in ${DELAY}s" >&2
        sleep "$DELAY"
    fi
    attempt=$((attempt + 1))
done
if [ "$published" != true ]; then
    echo "[stage0-release] release $release_id did not become publicly available for tag $TAG" >&2
    exit 1
fi

for asset in typelisp-stage0-linux typelisp-stage0-windows.exe; do
    url="https://github.com/$REPO/releases/download/$TAG/$asset"
    resolved=false
    attempt=1
    while [ "$attempt" -le "$ATTEMPTS" ]; do
        if curl --fail --silent --show-error --location --head \
            --output /dev/null "$url"; then
            resolved=true
            break
        fi
        if [ "$attempt" -lt "$ATTEMPTS" ]; then
            echo "[stage0-release] $asset URL not ready (attempt $attempt/$ATTEMPTS); retrying in ${DELAY}s" >&2
            sleep "$DELAY"
        fi
        attempt=$((attempt + 1))
    done
    if [ "$resolved" != true ]; then
        echo "[stage0-release] stable asset URL did not resolve: $url" >&2
        exit 1
    fi
done

echo "[stage0-release] verified published release $release_id for $TAG at $EXPECTED_SHA"
