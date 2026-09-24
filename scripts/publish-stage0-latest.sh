#!/usr/bin/env sh
set -eu

# publish-stage0-latest.sh - stage and promote the mutable stage0 release.
#
# GitHub's high-level release creation uploads through a draft and then
# publishes it. Recreating stage0-latest through that composite command left a
# successfully verified release draft again after the command returned (#6367).
# Build the complete candidate under a private temporary tag instead. Only
# after every asset is uploaded and the candidate is rechecked do we remove the
# old alias and publish the prepared release with one explicit REST PATCH.
#
# The alias only moves forward along main (#8055). A candidate is promoted
# while its commit is still on main and strictly newer than the commit the
# alias currently targets; main advancing past it is normal and not a reason
# to skip, or the alias starves whenever merges outpace a publish run. An older
# or equal candidate, or one no longer on main, leaves the alias untouched.

usage() {
    cat <<'EOF'
usage:
  scripts/publish-stage0-latest.sh --self-test
  scripts/publish-stage0-latest.sh REPO EXPECTED_SHA CANDIDATE_TAG NOTES_FILE ASSET...

The live mode requires authenticated `gh`, `curl`, and `jq`. CANDIDATE_TAG must
be unique to the workflow run/attempt. ASSET paths must have distinct portable
base names. The final public tag is always stage0-latest. Exit 3 means the
candidate was not promoted (it is no longer on main, or stage0-latest already
targets it or a newer commit) and the caller should skip final-SHA
verification.
EOF
}

fail() {
    echo "[stage0-publish] $*" >&2
    return 1
}

RELEASE_RECORD_JQ='[ (.id | tostring), (.draft | tostring), .tag_name, .target_commitish, (.published_at // ""), .upload_url ] | join("|")'
FINAL_TAG=stage0-latest
CANDIDATE_ID=
CUTOVER_STARTED=0

validate_release_record() {
    record=$1
    expected_id=$2
    expected_draft=$3
    expected_tag=$4
    expected_sha=$5
    require_published=$6

    IFS='|' read -r record_id draft tag target published_at upload_url <<EOF
$record
EOF
    case "$record_id" in
        "" | *[!0-9]*)
            fail "release record has invalid id: $record_id"
            return 1
            ;;
    esac
    if [ -n "$expected_id" ] && [ "$record_id" != "$expected_id" ]; then
        fail "release record id $record_id, expected $expected_id"
        return 1
    fi
    if [ "$draft" != "$expected_draft" ]; then
        fail "release $record_id has draft=$draft, expected $expected_draft"
        return 1
    fi
    if [ "$tag" != "$expected_tag" ]; then
        fail "release $record_id has tag $tag, expected $expected_tag"
        return 1
    fi
    if [ "$target" != "$expected_sha" ]; then
        fail "release $record_id targets $target, expected $expected_sha"
        return 1
    fi
    if [ "$require_published" = 1 ] && [ -z "$published_at" ]; then
        fail "release $record_id is public but has no published_at timestamp"
        return 1
    fi
    if [ "$require_published" = 0 ] && [ -z "$upload_url" ]; then
        fail "draft release $record_id has no upload URL"
        return 1
    fi
}

validate_candidate_assets() {
    records=$1
    expected_names=$2
    actual_names=

    while IFS='|' read -r asset_name asset_state asset_size; do
        [ -n "$asset_name" ] || continue
        if [ "$asset_state" != uploaded ]; then
            fail "candidate asset $asset_name has state=$asset_state"
            return 1
        fi
        case "$asset_size" in
            "" | *[!0-9]* | 0)
                fail "candidate asset $asset_name has invalid size=$asset_size"
                return 1
                ;;
        esac
        if [ -z "$actual_names" ]; then
            actual_names=$asset_name
        else
            actual_names="$actual_names
$asset_name"
        fi
    done <<EOF
$records
EOF

    actual_names=$(printf '%s\n' "$actual_names" | LC_ALL=C sort)
    if [ "$actual_names" != "$expected_names" ]; then
        echo "[stage0-publish] candidate asset set mismatch" >&2
        echo "[stage0-publish] expected:" >&2
        printf '%s\n' "$expected_names" | sed 's/^/  /' >&2
        echo "[stage0-publish] actual:" >&2
        printf '%s\n' "$actual_names" | sed 's/^/  /' >&2
        return 1
    fi
}

select_single_optional_release_id() {
    release_ids=$1
    tag=$2
    count=0
    if [ -n "$release_ids" ]; then
        count=$(printf '%s\n' "$release_ids" | wc -l | tr -d ' ')
    fi
    if [ "$count" -gt 1 ]; then
        fail "multiple releases found for tag $tag: $release_ids"
        return 1
    fi
    printf '%s\n' "$release_ids"
}

# Live API adapters. The self-test replaces these functions with a deterministic
# in-memory fixture and exercises the same orchestration below.
current_main_sha() {
    gh api "repos/$REPO/git/ref/heads/main" --jq '.object.sha'
}

# GitHub's compare status of HEAD relative to BASE: ahead (BASE is an ancestor
# of HEAD), identical, behind, or diverged.
commit_relation() {
    gh api "repos/$1/compare/$2...$3" --jq '.status'
}

# The commit the current stable alias targets, or nothing when it is absent.
current_latest_target_sha() {
    latest_error=${TMPDIR:-/tmp}/stage0-latest-target.$$
    if gh api "repos/$REPO/releases/tags/$FINAL_TAG" --jq '.target_commitish' \
        2>"$latest_error"; then
        rm -f "$latest_error"
        return 0
    fi
    if grep -F "HTTP 404" "$latest_error" >/dev/null 2>&1; then
        rm -f "$latest_error"
        return 0
    fi
    cat "$latest_error" >&2 || true
    rm -f "$latest_error"
    fail "cannot inspect the current $FINAL_TAG release"
}

create_candidate_release() {
    notes=$(cat "$NOTES_FILE")
    gh api --method POST "repos/$REPO/releases" \
        -f tag_name="$CANDIDATE_TAG" \
        -f target_commitish="$EXPECTED_SHA" \
        -f name="Stage0 latest candidate" \
        -f body="$notes" \
        -F draft=true \
        -F prerelease=false \
        --jq "$RELEASE_RECORD_JQ"
}

upload_candidate_asset() {
    upload_base=$1
    asset_path=$2
    asset_name=$3
    api_token=${GH_TOKEN:-${GITHUB_TOKEN:-}}
    [ -n "$api_token" ] || {
        fail "GH_TOKEN or GITHUB_TOKEN is required for asset upload"
        return 1
    }
    curl --fail --show-error --silent \
        -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $api_token" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "Content-Type: application/octet-stream" \
        --data-binary "@$asset_path" \
        "$upload_base?name=$asset_name" >/dev/null
}

candidate_asset_records() {
    gh api "repos/$REPO/releases/$CANDIDATE_ID" \
        --jq '.assets[] | [ .name, .state, (.size | tostring) ] | join("|")' |
        LC_ALL=C sort
}

release_ids_for_tag() {
    gh api --paginate "repos/$REPO/releases?per_page=100" \
        --jq ".[] | select(.tag_name == \"$FINAL_TAG\") | .id"
}

delete_release() {
    release_id=$1
    case "$release_id" in
        "" | *[!0-9]*)
            fail "refusing to delete invalid release id: $release_id"
            return 1
            ;;
    esac
    gh api --method DELETE "repos/$REPO/releases/$release_id" --silent
}

delete_tag_if_exists() {
    tag_name=$1
    case "$tag_name" in
        "" | *[!A-Za-z0-9._-]*)
            fail "refusing to delete invalid tag: $tag_name"
            return 1
            ;;
    esac
    tag_error=${TMPDIR:-/tmp}/stage0-tag-delete.$$
    if gh api "repos/$REPO/git/ref/tags/$tag_name" --silent \
        2>"$tag_error"; then
        gh api --method DELETE "repos/$REPO/git/refs/tags/$tag_name" --silent
        rm -f "$tag_error"
        return 0
    fi
    if grep -F "HTTP 404" "$tag_error" >/dev/null 2>&1; then
        rm -f "$tag_error"
        return 0
    fi
    cat "$tag_error" >&2 || true
    rm -f "$tag_error"
    fail "cannot inspect existing tag $tag_name"
}

delete_final_tag() {
    delete_tag_if_exists "$FINAL_TAG"
}

delete_candidate_tag() {
    delete_tag_if_exists "$CANDIDATE_TAG"
}

promote_candidate_release() {
    notes=$(cat "$NOTES_FILE")
    gh api --method PATCH "repos/$REPO/releases/$CANDIDATE_ID" \
        -f tag_name="$FINAL_TAG" \
        -f target_commitish="$EXPECTED_SHA" \
        -f name="Stage0 latest" \
        -f body="$notes" \
        -F draft=false \
        -F prerelease=false \
        --jq "$RELEASE_RECORD_JQ"
}

cleanup_candidate() {
    if [ -n "$CANDIDATE_ID" ] && [ "$CUTOVER_STARTED" -eq 0 ]; then
        echo "[stage0-publish] removing unpromoted candidate release $CANDIDATE_ID" >&2
        delete_release "$CANDIDATE_ID" || true
        delete_candidate_tag || true
        CANDIDATE_ID=
    fi
}

# Both checks return 0 (yes), 1 (no) or 2 (the API could not answer). An
# unanswerable check fails the run rather than silently skipping promotion.
known_relation() {
    case "$1" in
        ahead | identical | behind | diverged) return 0 ;;
    esac
    fail "unexpected compare status: ${1:-<empty>}"
}

# Whether main still contains the candidate commit (main may be ahead).
candidate_on_main() {
    main_sha=$1
    [ -n "$main_sha" ] || {
        fail "cannot resolve main"
        return 2
    }
    [ "$main_sha" != "$EXPECTED_SHA" ] || return 0
    relation=$(commit_relation "$REPO" "$EXPECTED_SHA" "$main_sha") || return 2
    known_relation "$relation" || return 2
    case "$relation" in
        ahead | identical) return 0 ;;
    esac
    return 1
}

# Whether the candidate moves the alias forward: there is no alias yet, the
# alias is off main's history, or the candidate is strictly newer than it.
candidate_newer_than_latest() {
    latest_target=$(current_latest_target_sha) || return 2
    [ -n "$latest_target" ] || return 0
    [ "$latest_target" != "$EXPECTED_SHA" ] || return 1
    relation=$(commit_relation "$REPO" "$latest_target" "$EXPECTED_SHA") || return 2
    known_relation "$relation" || return 2
    case "$relation" in
        ahead | diverged) return 0 ;;
    esac
    return 1
}

publish_latest() {
    # Validate every operator-controlled setting before creating a candidate,
    # and especially before deleting the stable release/tag. A configuration
    # error must be a no-mutation failure rather than opening a cutover gap.
    attempts=${TYPELISP_STAGE0_PROMOTE_ATTEMPTS:-4}
    delay=${TYPELISP_STAGE0_PROMOTE_DELAY:-2}
    case "$attempts" in
        "" | *[!0-9]* | 0)
            fail "TYPELISP_STAGE0_PROMOTE_ATTEMPTS must be a positive integer"
            return 1
            ;;
    esac
    case "$delay" in
        "" | *[!0-9]*)
            fail "TYPELISP_STAGE0_PROMOTE_DELAY must be a non-negative integer"
            return 1
            ;;
    esac

    expected_names=
    for asset_path do
        [ -s "$asset_path" ] || {
            fail "candidate asset is missing or empty: $asset_path"
            return 1
        }
        asset_name=$(basename "$asset_path")
        case "$asset_name" in
            "" | *[!A-Za-z0-9._-]*)
                fail "candidate asset has non-portable name: $asset_name"
                return 1
                ;;
        esac
        if [ -z "$expected_names" ]; then
            expected_names=$asset_name
        else
            expected_names="$expected_names
$asset_name"
        fi
    done
    expected_names=$(printf '%s\n' "$expected_names" | LC_ALL=C sort)
    unique_count=$(printf '%s\n' "$expected_names" | LC_ALL=C uniq | wc -l | tr -d ' ')
    total_count=$(printf '%s\n' "$expected_names" | wc -l | tr -d ' ')
    if [ "$unique_count" -ne "$total_count" ]; then
        fail "candidate asset base names must be unique"
        return 1
    fi

    latest_main=$(current_main_sha)
    candidate_on_main "$latest_main" && on_main_status=0 || on_main_status=$?
    if [ "$on_main_status" -eq 2 ]; then
        return 1
    fi
    if [ "$on_main_status" -ne 0 ]; then
        echo "[stage0-publish] skipping $EXPECTED_SHA because it is not on main ($latest_main)"
        return 3
    fi
    candidate_newer_than_latest && newer_status=0 || newer_status=$?
    if [ "$newer_status" -eq 2 ]; then
        return 1
    fi
    if [ "$newer_status" -ne 0 ]; then
        echo "[stage0-publish] skipping $EXPECTED_SHA because $FINAL_TAG already targets it or a newer commit"
        return 3
    fi

    candidate_record=$(create_candidate_release)
    validate_release_record \
        "$candidate_record" "" true "$CANDIDATE_TAG" "$EXPECTED_SHA" 0 || return 1
    IFS='|' read -r CANDIDATE_ID _draft _tag _target _published upload_url <<EOF
$candidate_record
EOF
    upload_base=${upload_url%%\{*}

    for asset_path do
        asset_name=$(basename "$asset_path")
        echo "[stage0-publish] uploading $asset_name to draft release $CANDIDATE_ID"
        upload_candidate_asset "$upload_base" "$asset_path" "$asset_name"
    done
    asset_records=$(candidate_asset_records)
    validate_candidate_assets "$asset_records" "$expected_names" || return 1

    # Resolve the predecessor before the final main guard. Pagination can take
    # long enough for main to advance; this lookup is read-only and must not
    # widen the guarded mutation window below.
    existing_ids=$(release_ids_for_tag)
    existing_id=$(select_single_optional_release_id "$existing_ids" "$FINAL_TAG") || return 1

    # Main or the alias can move during asset upload or release discovery.
    # This second guard is immediately before the short destructive cutover; a
    # superseded publisher only deletes its private draft and leaves the stable
    # release untouched.
    latest_main=$(current_main_sha)
    candidate_on_main "$latest_main" && on_main_status=0 || on_main_status=$?
    if [ "$on_main_status" -eq 2 ]; then
        cleanup_candidate
        return 1
    fi
    if [ "$on_main_status" -ne 0 ]; then
        echo "[stage0-publish] discarding candidate $CANDIDATE_ID; $EXPECTED_SHA is no longer on main ($latest_main)"
        cleanup_candidate
        return 3
    fi
    candidate_newer_than_latest && newer_status=0 || newer_status=$?
    if [ "$newer_status" -eq 2 ]; then
        cleanup_candidate
        return 1
    fi
    if [ "$newer_status" -ne 0 ]; then
        echo "[stage0-publish] discarding candidate $CANDIDATE_ID; $FINAL_TAG already targets $EXPECTED_SHA or a newer commit"
        cleanup_candidate
        return 3
    fi

    CUTOVER_STARTED=1
    if [ -n "$existing_id" ]; then
        echo "[stage0-publish] removing previous $FINAL_TAG release $existing_id"
        delete_release "$existing_id"
    fi
    delete_final_tag

    promote_error=${TMPDIR:-/tmp}/stage0-promote.$$
    promoted=false
    attempt=1
    while [ "$attempt" -le "$attempts" ]; do
        if promoted_record=$(promote_candidate_release 2>"$promote_error") &&
            validate_release_record \
                "$promoted_record" "$CANDIDATE_ID" false "$FINAL_TAG" \
                "$EXPECTED_SHA" 1; then
            promoted=true
            break
        fi
        if [ "$attempt" -lt "$attempts" ]; then
            echo "[stage0-publish] promotion not authoritative yet (attempt $attempt/$attempts); retrying in ${delay}s" >&2
            sleep "$delay"
        fi
        attempt=$((attempt + 1))
    done
    if [ "$promoted" != true ]; then
        [ ! -s "$promote_error" ] || cat "$promote_error" >&2
        rm -f "$promote_error"
        fail "candidate release $CANDIDATE_ID could not be promoted to $FINAL_TAG"
        return 1
    fi
    rm -f "$promote_error"
    echo "[stage0-publish] promoted release $CANDIDATE_ID to $FINAL_TAG"
    CANDIDATE_ID=

    # Main advancing past the promoted commit is expected; main no longer
    # containing it (a rewrite during cutover) is not, and must stay red.
    latest_main=$(current_main_sha)
    candidate_on_main "$latest_main" && on_main_status=0 || on_main_status=$?
    if [ "$on_main_status" -ne 0 ]; then
        fail "main ${latest_main:-<unresolved>} no longer contains $EXPECTED_SHA after $FINAL_TAG cutover"
        return 1
    fi
}

self_test() {
    expected_sha=0123456789abcdef0123456789abcdef01234567
    newer_sha=fedcba9876543210fedcba9876543210fedcba98
    older_sha=00000000000000000000000000000000000000aa
    test_dir=$(mktemp -d "${TMPDIR:-/tmp}/stage0-publish-self-test.XXXXXX")
    action_log=$test_dir/actions
    main_counter=$test_dir/main-counter
    latest_counter=$test_dir/latest-counter
    promote_counter=$test_dir/promote-counter
    asset_a=$test_dir/typelisp-stage0-linux
    asset_b=$test_dir/SHA256SUMS
    printf 'compiler\n' > "$asset_a"
    printf 'checksum\n' > "$asset_b"

    mock_main_values=
    mock_latest_values=
    mock_relations=
    mock_existing_ids=90
    mock_promote_drafts=false
    mock_promote_published=2026-08-09T00:00:00Z

    current_main_sha() {
        count=$(cat "$main_counter")
        count=$((count + 1))
        printf '%s\n' "$count" > "$main_counter"
        printf 'main\n' >> "$action_log"
        printf '%s\n' "$mock_main_values" | sed -n "${count}p"
    }
    # One line per call; a line `none` models an absent alias.
    current_latest_target_sha() {
        latest_count=$(cat "$latest_counter")
        latest_count=$((latest_count + 1))
        printf '%s\n' "$latest_count" > "$latest_counter"
        printf 'latest-target\n' >> "$action_log"
        latest_value=$(printf '%s\n' "$mock_latest_values" | sed -n "${latest_count}p")
        [ "$latest_value" = none ] || printf '%s\n' "$latest_value"
    }
    # `BASE HEAD status` rows; a missing row models an API failure.
    commit_relation() {
        printf 'compare:%s:%s\n' "$2" "$3" >> "$action_log"
        relation_row=$(printf '%s\n' "$mock_relations" | awk -v base="$2" -v head="$3" '$1 == base && $2 == head {print $3; exit}')
        [ -n "$relation_row" ] || return 1
        printf '%s\n' "$relation_row"
    }
    create_candidate_release() {
        printf 'create-candidate\n' >> "$action_log"
        printf '100|true|%s|%s||https://uploads.example/releases/100/assets{?name,label}\n' \
            "$CANDIDATE_TAG" "$EXPECTED_SHA"
    }
    upload_candidate_asset() {
        printf 'upload:%s\n' "$3" >> "$action_log"
    }
    candidate_asset_records() {
        printf 'inspect-assets\n' >> "$action_log"
        printf 'SHA256SUMS|uploaded|9\ntypelisp-stage0-linux|uploaded|9\n'
    }
    release_ids_for_tag() {
        printf 'list-existing\n' >> "$action_log"
        printf '%s\n' "$mock_existing_ids"
    }
    delete_release() {
        printf 'delete-release:%s\n' "$1" >> "$action_log"
    }
    delete_final_tag() {
        printf 'delete-tag:%s\n' "$FINAL_TAG" >> "$action_log"
    }
    delete_candidate_tag() {
        printf 'delete-candidate-tag:%s\n' "$CANDIDATE_TAG" >> "$action_log"
    }
    promote_candidate_release() {
        promote_count=$(cat "$promote_counter")
        promote_count=$((promote_count + 1))
        printf '%s\n' "$promote_count" > "$promote_counter"
        promote_draft=$(printf '%s\n' "$mock_promote_drafts" |
            sed -n "${promote_count}p")
        [ -n "$promote_draft" ] || promote_draft=false
        promote_published=$mock_promote_published
        [ "$promote_draft" != true ] || promote_published=
        printf 'promote:%s\n' "$CANDIDATE_ID" >> "$action_log"
        printf '100|%s|%s|%s|%s|https://uploads.example/releases/100/assets{?name,label}\n' \
            "$promote_draft" "$FINAL_TAG" "$EXPECTED_SHA" \
            "$promote_published"
    }
    reset_case() {
        : > "$action_log"
        printf '0\n' > "$main_counter"
        printf '0\n' > "$latest_counter"
        printf '0\n' > "$promote_counter"
        mock_main_values=$1
        mock_latest_values=$2
        mock_relations=$3
        CANDIDATE_ID=
        CUTOVER_STARTED=0
    }
    self_test_fail() {
        echo "stage0 publish self-test: $*" >&2
        cat "$action_log" >&2
        rm -rf "$test_dir"
        return 1
    }
    # Runs one case and checks its exit status; stable-release mutations are
    # forbidden unless the case expects a promotion.
    run_case() {
        case_name=$1
        expected_status=$2
        set +e
        publish_latest "$asset_a" "$asset_b"
        case_status=$?
        set -e
        [ "$case_status" -eq "$expected_status" ] ||
            self_test_fail "$case_name exited $case_status, expected $expected_status" || return 1
        if [ "$expected_status" -ne 0 ] &&
            grep -E 'delete-release:90|delete-tag|promote:' "$action_log" >/dev/null 2>&1; then
            self_test_fail "$case_name reached the stable cutover" || return 1
        fi
    }

    REPO=example/project
    EXPECTED_SHA=$expected_sha
    CANDIDATE_TAG=stage0-candidate-1-1
    NOTES_FILE=$test_dir/notes
    printf 'notes\n' > "$NOTES_FILE"
    TYPELISP_STAGE0_PROMOTE_ATTEMPTS=4
    TYPELISP_STAGE0_PROMOTE_DELAY=0
    advance="$older_sha $expected_sha ahead"

    # Happy path: the complete draft is prepared before the old alias is
    # touched, promotion is one explicit operation, and the candidate is
    # checked against main and the current alias on both sides of the cutover.
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    run_case happy-path 0 || return 1
    expected_actions="main
latest-target
compare:$older_sha:$expected_sha
create-candidate
upload:typelisp-stage0-linux
upload:SHA256SUMS
inspect-assets
list-existing
main
latest-target
compare:$older_sha:$expected_sha
delete-release:90
delete-tag:stage0-latest
promote:100
main"
    [ "$(cat "$action_log")" = "$expected_actions" ] ||
        self_test_fail "happy-path action mismatch" || return 1

    # Main advancing past the candidate at every checkpoint is normal: the
    # candidate is still on main and newer than the alias, so it is promoted.
    # This is the case that used to skip every run while merges kept landing.
    reset_case "$newer_sha
$newer_sha
$newer_sha" "$older_sha
$older_sha" "$advance
$expected_sha $newer_sha ahead"
    run_case main-advanced 0 || return 1
    grep -F 'promote:100' "$action_log" >/dev/null 2>&1 ||
        self_test_fail "main-advanced candidate was not promoted" || return 1

    # No alias yet, or an alias off main's history, is replaced.
    reset_case "$expected_sha
$expected_sha
$expected_sha" "none
none" ""
    run_case no-alias 0 || return 1
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$older_sha
$older_sha" "$older_sha $expected_sha diverged"
    run_case alias-off-main 0 || return 1

    # A PATCH response that remains draft is not authoritative. The bounded
    # promotion loop must issue another explicit PATCH and accept only the
    # public response.
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    mock_promote_drafts='true
false'
    run_case draft-retry 0 || return 1
    [ "$(cat "$promote_counter")" -eq 2 ] ||
        self_test_fail "did not retry draft promotion" || return 1
    mock_promote_drafts=false

    # Invalid retry configuration is rejected before any lookup, so it cannot
    # create a draft or enter the stable cutover.
    reset_case "$expected_sha" "$older_sha" "$advance"
    TYPELISP_STAGE0_PROMOTE_ATTEMPTS=invalid
    run_case invalid-config 1 || return 1
    TYPELISP_STAGE0_PROMOTE_ATTEMPTS=4
    [ ! -s "$action_log" ] ||
        self_test_fail "invalid configuration touched release state" || return 1

    # Skips before staging create no release at all: a candidate no longer on
    # main, one older than the alias, and one the alias already targets.
    expect_no_candidate() {
        if grep -F 'create-candidate' "$action_log" >/dev/null 2>&1; then
            self_test_fail "$1 created a candidate before skipping" || return 1
        fi
    }
    reset_case "$newer_sha" "$older_sha" "$expected_sha $newer_sha diverged"
    run_case not-on-main 3 || return 1
    expect_no_candidate not-on-main || return 1
    reset_case "$newer_sha" "$older_sha" "$expected_sha $newer_sha behind"
    run_case main-rewound 3 || return 1
    expect_no_candidate main-rewound || return 1
    reset_case "$expected_sha" "$newer_sha" "$newer_sha $expected_sha behind"
    run_case older-than-alias 3 || return 1
    expect_no_candidate older-than-alias || return 1
    reset_case "$expected_sha" "$expected_sha" ""
    run_case already-promoted 3 || return 1
    expect_no_candidate already-promoted || return 1

    # An API that cannot answer fails the run instead of skipping promotion.
    reset_case "$newer_sha" "$older_sha" ""
    run_case compare-unavailable 1 || return 1
    reset_case "$newer_sha" "$older_sha" "$expected_sha $newer_sha unknown"
    run_case compare-unknown-status 1 || return 1
    reset_case "" "$older_sha" "$advance"
    run_case main-unresolved 1 || return 1

    # If a newer run promoted the alias while this one uploaded, or main was
    # rewritten, only the private candidate is removed; the stable release/tag
    # mutation functions must not run (the read-only predecessor lookup is
    # allowed before the final guard).
    reset_case "$expected_sha
$expected_sha" "$older_sha
$newer_sha" "$advance
$newer_sha $expected_sha behind"
    run_case alias-advanced-during-upload 3 || return 1
    case "$(cat "$action_log")" in
        *"delete-release:100"*"delete-candidate-tag:$CANDIDATE_TAG"*) ;;
        *) self_test_fail "did not clean the superseded candidate" || return 1 ;;
    esac
    reset_case "$expected_sha
$newer_sha" "$older_sha
$older_sha" "$advance
$expected_sha $newer_sha diverged"
    run_case main-rewritten-during-upload 3 || return 1
    case "$(cat "$action_log")" in
        *"delete-release:100"*) ;;
        *) self_test_fail "did not clean the stale candidate" || return 1 ;;
    esac

    # Main no longer containing the promoted commit after cutover stays red.
    reset_case "$expected_sha
$expected_sha
$newer_sha" "$older_sha
$older_sha" "$advance
$expected_sha $newer_sha diverged"
    set +e
    publish_latest "$asset_a" "$asset_b"
    rewritten_status=$?
    set -e
    [ "$rewritten_status" -eq 1 ] ||
        self_test_fail "post-cutover rewrite exited $rewritten_status, expected 1" || return 1

    expect_names=$(printf '%s\n' SHA256SUMS typelisp-stage0-linux | LC_ALL=C sort)
    validate_candidate_assets \
        'SHA256SUMS|uploaded|9
typelisp-stage0-linux|uploaded|9' \
        "$expect_names"
    if validate_candidate_assets \
        'SHA256SUMS|starter|0
typelisp-stage0-linux|uploaded|9' \
        "$expect_names" >/dev/null 2>&1; then
        self_test_fail "accepted incomplete candidate asset" || return 1
    fi
    if validate_release_record \
        "100|true|$FINAL_TAG|$expected_sha||upload" \
        100 false "$FINAL_TAG" "$expected_sha" 1 >/dev/null 2>&1; then
        self_test_fail "accepted draft promotion result" || return 1
    fi
    if select_single_optional_release_id '90
91' "$FINAL_TAG" >/dev/null 2>&1; then
        self_test_fail "accepted duplicate stable releases" || return 1
    fi

    rm -rf "$test_dir"
    echo "stage0 latest publication self-test passed"
}

if [ "${1:-}" = --self-test ]; then
    [ "$#" -eq 1 ] || {
        usage >&2
        exit 2
    }
    self_test
    exit 0
fi

[ "$#" -ge 6 ] || {
    usage >&2
    exit 2
}
REPO=$1
EXPECTED_SHA=$2
CANDIDATE_TAG=$3
NOTES_FILE=$4
shift 4

case "$REPO" in
    */*) ;;
    *)
        fail "repository must be OWNER/REPO: $REPO"
        exit 2
        ;;
esac
case "$EXPECTED_SHA" in
    *[!0-9a-f]* | "")
        fail "expected SHA must be lowercase hexadecimal"
        exit 2
        ;;
esac
[ "${#EXPECTED_SHA}" -eq 40 ] || {
    fail "expected SHA must contain 40 hexadecimal characters"
    exit 2
}
case "$CANDIDATE_TAG" in
    "" | *[!A-Za-z0-9._-]*)
        fail "candidate tag has invalid characters: $CANDIDATE_TAG"
        exit 2
        ;;
esac
[ "$CANDIDATE_TAG" != "$FINAL_TAG" ] || {
    fail "candidate tag must differ from $FINAL_TAG"
    exit 2
}
[ -s "$NOTES_FILE" ] || {
    fail "notes file is missing or empty: $NOTES_FILE"
    exit 2
}
for command in gh curl jq; do
    command -v "$command" >/dev/null 2>&1 || {
        fail "missing required command: $command"
        exit 2
    }
done

trap cleanup_candidate 0 1 2 15
publish_latest "$@"
trap - 0 1 2 15
