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

select_single_release_id() {
    release_ids=$1
    tag=$2

    if [ -z "$release_ids" ]; then
        fail "no release (published or draft) found for tag $tag"
        return 1
    fi
    if [ "$(printf '%s\n' "$release_ids" | wc -l | tr -d ' ')" -ne 1 ]; then
        fail "multiple releases found for tag $tag: $release_ids"
        return 1
    fi
    printf '%s\n' "$release_ids"
}

# Retry a release-discovery command inside the propagation budget and print the
# ids it found. Only a command that both succeeds and prints something is
# promoted: a command that fails never leaves its output behind as a release id
# (an API error body would otherwise satisfy the single-id check and be spliced
# into the next request path), and its own diagnostic is surfaced instead of
# being reported as an absent release. A clean empty result is the real "not
# visible yet" case and prints nothing, so the caller reports it as absent.
retry_release_discovery() {
    discovery_tag=$1
    shift

    discovery_err=${TMPDIR:-/tmp}/stage0-release-discovery.$$
    discovery_found=
    discovery_failed=0
    discovery_attempt=1
    while [ "$discovery_attempt" -le "$ATTEMPTS" ]; do
        discovery_failed=0
        if discovery_candidate=$("$@" 2>"$discovery_err"); then
            if [ -n "$discovery_candidate" ]; then
                discovery_found=$discovery_candidate
                break
            fi
        else
            discovery_failed=1
        fi
        if [ "$discovery_attempt" -lt "$ATTEMPTS" ]; then
            echo "[stage0-release] authenticated release list not ready for tag $discovery_tag (attempt $discovery_attempt/$ATTEMPTS); retrying in ${DELAY}s" >&2
            sleep "$DELAY"
        fi
        discovery_attempt=$((discovery_attempt + 1))
    done

    if [ -z "$discovery_found" ] && [ "$discovery_failed" -eq 1 ]; then
        if [ -s "$discovery_err" ]; then
            cat "$discovery_err" >&2
        fi
        rm -f "$discovery_err"
        fail "release discovery command failed for tag $discovery_tag"
        return 1
    fi
    rm -f "$discovery_err"
    printf '%s\n' "$discovery_found"
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

# Self-test discovery stubs. Each runs in the command substitution inside
# retry_release_discovery, so the attempt counter lives in a file rather than a
# variable.
self_test_lagging_discovery() {
    count=$(cat "$SELF_TEST_DISCOVERY_COUNTER")
    count=$((count + 1))
    printf '%s\n' "$count" > "$SELF_TEST_DISCOVERY_COUNTER"
    # Succeeds with no match until the release becomes visible on attempt 3.
    if [ "$count" -ge 3 ]; then
        echo 100
    fi
}

self_test_absent_discovery() {
    count=$(cat "$SELF_TEST_DISCOVERY_COUNTER")
    printf '%s\n' "$((count + 1))" > "$SELF_TEST_DISCOVERY_COUNTER"
}

self_test_failing_discovery() {
    # Mirrors `gh api` on an auth failure: an error body on stdout, the
    # actionable message on stderr, and a non-zero status.
    echo '{"message":"Bad credentials","status":"401"}'
    echo "gh: Bad credentials (HTTP 401)" >&2
    return 1
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
    release_id=$(select_single_release_id 100 stage0-latest)
    [ "$release_id" = 100 ] || {
        echo "self-test release id selection mismatch: $release_id" >&2
        return 1
    }
    expect_failure "no release (published or draft) found" \
        select_single_release_id "" stage0-latest
    expect_failure "multiple releases found" \
        select_single_release_id "100
101" stage0-latest

    ATTEMPTS=4
    DELAY=0
    SELF_TEST_DISCOVERY_COUNTER=${TMPDIR:-/tmp}/stage0-self-test-discovery.$$
    printf '0\n' > "$SELF_TEST_DISCOVERY_COUNTER"
    discovered=$(retry_release_discovery stage0-latest \
        self_test_lagging_discovery 2>/dev/null)
    [ "$discovered" = 100 ] || {
        echo "self-test lagging discovery mismatch: $discovered" >&2
        rm -f "$SELF_TEST_DISCOVERY_COUNTER"
        return 1
    }
    [ "$(cat "$SELF_TEST_DISCOVERY_COUNTER")" = 3 ] || {
        echo "self-test lagging discovery attempt count mismatch:" \
            "$(cat "$SELF_TEST_DISCOVERY_COUNTER")" >&2
        rm -f "$SELF_TEST_DISCOVERY_COUNTER"
        return 1
    }
    printf '0\n' > "$SELF_TEST_DISCOVERY_COUNTER"
    discovered=$(retry_release_discovery stage0-latest \
        self_test_absent_discovery 2>/dev/null)
    [ -z "$discovered" ] || {
        echo "self-test absent discovery should print nothing: $discovered" >&2
        rm -f "$SELF_TEST_DISCOVERY_COUNTER"
        return 1
    }
    rm -f "$SELF_TEST_DISCOVERY_COUNTER"

    # A failing discovery command must not have its output adopted as a release
    # id: an API error body is a single line and would otherwise pass
    # select_single_release_id and be spliced into the next request path.
    expect_failure "release discovery command failed" \
        retry_release_discovery stage0-latest self_test_failing_discovery
    expect_failure "Bad credentials" \
        retry_release_discovery stage0-latest self_test_failing_discovery
    set +e
    leaked=$(retry_release_discovery stage0-latest \
        self_test_failing_discovery 2>/dev/null)
    set -e
    [ -z "$leaked" ] || {
        echo "self-test failing discovery leaked output as a release id:" \
            "$leaked" >&2
        return 1
    }

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
# complete draft can be recovered and its id can be reported actionably. A
# newly created release can take a few seconds to appear in this list, so bound
# the discovery race with the same propagation retry budget used below.
list_release_ids() {
    gh api "repos/$REPO/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$TAG\") | .id"
}

release_ids=$(retry_release_discovery "$TAG" list_release_ids) || exit 1
release_id=$(select_single_release_id "$release_ids" "$TAG") || exit 1

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
