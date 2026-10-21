#!/usr/bin/env sh
set -eu

# publish-stage0-latest.sh - stage and promote the mutable stage0 release.
#
# GitHub's high-level release creation uploads through a draft and then
# publishes it. Recreating stage0-latest through that composite command can
# leave a successfully verified release draft again after the command returns.
# Build the complete candidate under a private temporary tag instead. Only
# after every asset is uploaded and the candidate is rechecked do we remove the
# old release and publish the prepared release with one explicit REST PATCH.
# Publishers must be serialized (the workflow uses stage0-bootstrap concurrency).
#
# The alias only moves forward along main. A candidate is promoted
# while its commit is still on main and newer than the stable tag, or resumes
# a same-commit cutover before a matching release exists. Main may advance
# during preparation; requiring exact equality would starve publication.
# Matching release targets, older candidates, and candidates no longer on main
# leave the alias untouched.

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

validate_alias_sha() {
    case "$1" in
        "" | *[!0-9a-f]*)
            fail "invalid $FINAL_TAG object SHA: $1"
            return 1
            ;;
    esac
    [ "${#1}" -eq 40 ] || fail "invalid $FINAL_TAG object SHA length: $1"
}

# The Git tag remains authoritative when its release is draft or missing.
# The public releases/tags endpoint hides drafts and cannot prove absence.
current_latest_target_sha() {
    latest_error=${TMPDIR:-/tmp}/stage0-latest-target.$$
    if latest_ref=$(gh api "repos/$REPO/git/ref/tags/$FINAL_TAG" \
        --jq '[.object.type, .object.sha] | join("|")' 2>"$latest_error"); then
        rm -f "$latest_error"
        IFS='|' read -r latest_kind latest_sha <<EOF
$latest_ref
EOF
        validate_alias_sha "$latest_sha" || return 1
        case "$latest_kind" in
            commit) ;;
            tag)
                # Resolve the explicit tag, including nested annotated tags;
                # a same-named branch must not become the comparison base.
                latest_sha=$(gh api "repos/$REPO/commits/refs%2Ftags%2F$FINAL_TAG" \
                    --jq '.sha') || return 1
                validate_alias_sha "$latest_sha" || return 1
                ;;
            *) fail "unexpected $FINAL_TAG ref object type: $latest_kind"; return 1 ;;
        esac
        printf '%s\n' "$latest_sha"
        return 0
    fi
    if grep -F "HTTP 404" "$latest_error" >/dev/null 2>&1; then
        rm -f "$latest_error"
        return 0
    fi
    cat "$latest_error" >&2 || true
    rm -f "$latest_error"
    fail "cannot inspect the current $FINAL_TAG Git ref"
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

move_final_tag() {
    # Never delete the stable tag: GitHub can process its deletion after the
    # replacement is public and draft whichever release now holds that tag.
    tag_error=${TMPDIR:-/tmp}/stage0-tag-move.$$
    if gh api "repos/$REPO/git/ref/tags/$FINAL_TAG" --silent \
        2>"$tag_error"; then
        rm -f "$tag_error"
        gh api --method PATCH "repos/$REPO/git/refs/tags/$FINAL_TAG" \
            -f sha="$EXPECTED_SHA" -F force=true --silent || return $?
        echo "[stage0-publish] moved tag $FINAL_TAG to $EXPECTED_SHA"
        return 0
    fi
    if grep -F "HTTP 404" "$tag_error" >/dev/null 2>&1; then
        rm -f "$tag_error"
        gh api --method POST "repos/$REPO/git/refs" \
            -f ref="refs/tags/$FINAL_TAG" -f sha="$EXPECTED_SHA" --silent || return $?
        echo "[stage0-publish] created tag $FINAL_TAG at $EXPECTED_SHA"
        return 0
    fi
    cat "$tag_error" >&2 || true
    rm -f "$tag_error"
    fail "cannot move $FINAL_TAG to $EXPECTED_SHA; previous release retained"
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

# Whether the candidate advances publication: there is no alias, it is off
# main, the candidate is newer, or its earlier tag move needs a release.
# The final checkpoint supplies its already-discovered predecessor ID so no
# paginated release discovery widens the final guarded mutation window.
candidate_newer_than_latest() {
    latest_target=$(current_latest_target_sha) || return 2
    [ -n "$latest_target" ] || return 0
    if [ "$latest_target" = "$EXPECTED_SHA" ]; then
        # Moving the ref precedes release replacement. A failed cutover can
        # therefore leave this ref ahead of the release, or without a release.
        # Finish that publication without replacing a matching/newer release.
        if [ "$#" -eq 0 ]; then
            recovery_ids=$(release_ids_for_tag) || return 2
            recovery_id=$(select_single_optional_release_id "$recovery_ids" "$FINAL_TAG") || return 2
        else
            recovery_id=$1
        fi
        [ -n "$recovery_id" ] || return 0
        latest_target=$(gh api "repos/$REPO/releases/$recovery_id" \
            --jq '.target_commitish') || return 2
        validate_alias_sha "$latest_target" || return 2
        [ "$latest_target" != "$EXPECTED_SHA" ] || return 1
    fi
    relation=$(commit_relation "$REPO" "$latest_target" "$EXPECTED_SHA") || return 2
    known_relation "$relation" || return 2
    case "$relation" in
        ahead | diverged) return 0 ;;
    esac
    return 1
}

publish_latest() {
    # Validate every operator-controlled setting before creating a candidate,
    # and especially before replacing the stable release. A configuration
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
    candidate_newer_than_latest "$existing_id" && newer_status=0 || newer_status=$?
    if [ "$newer_status" -eq 2 ]; then
        cleanup_candidate
        return 1
    fi
    if [ "$newer_status" -ne 0 ]; then
        echo "[stage0-publish] discarding candidate $CANDIDATE_ID; $FINAL_TAG already targets $EXPECTED_SHA or a newer commit"
        cleanup_candidate
        return 3
    fi

    # Move the existing ref before removing the old release; release deletion
    # leaves its tag intact. A failed move must retain the public predecessor.
    move_final_tag || return 1
    CUTOVER_STARTED=1
    if [ -n "$existing_id" ]; then
        echo "[stage0-publish] removing previous $FINAL_TAG release $existing_id"
        delete_release "$existing_id" || return 1
    fi
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
    mock_release_visibility=public
    mock_annotated_sha=$older_sha
    mock_tag_state=present
    mock_release_target=from-ref
    mock_delete_failure=false
    mock_catalog_failure=false

    # Exercise alias lookup and tag mutation at the real API adapter boundary.
    gh() {
        case "$*" in
            "api repos/$REPO/git/ref/tags/$FINAL_TAG --jq [.object.type, .object.sha] | join(\"|\")")
                latest_value=$(next_latest_value)
                case "$latest_value" in
                    none) echo 'gh: Not Found (HTTP 404)' >&2; return 1 ;;
                    denied) echo 'gh: Forbidden (HTTP 403)' >&2; return 1 ;;
                    tag) echo 'tag|aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' ;;
                    bad-type) printf 'blob|%s\n' "$older_sha" ;;
                    empty-sha) echo 'commit|' ;;
                    short-sha) echo 'commit|abcd' ;;
                    bad-sha) echo 'commit|0123456789abcdef0123456789abcdef0123456g' ;;
                    *) printf 'commit|%s\n' "$latest_value" ;;
                esac
                ;;
            "api repos/$REPO/commits/refs%2Ftags%2F$FINAL_TAG --jq .sha")
                echo resolve-annotated >> "$action_log"
                [ "$mock_annotated_sha" != denied ] || return 1
                printf '%s\n' "$mock_annotated_sha"
                ;;
            "api repos/$REPO/releases/tags/$FINAL_TAG --jq .target_commitish")
                # Main-red control: the old adapter hides this newer draft.
                latest_value=$(next_latest_value)
                if [ "$mock_release_visibility" = draft ] || [ "$latest_value" = none ]; then
                    echo 'gh: Not Found (HTTP 404)' >&2
                    return 1
                fi
                printf '%s\n' "$latest_value"
                ;;
            "api repos/$REPO/releases/90 --jq .target_commitish")
                echo release-target >> "$action_log"
                [ "$mock_release_target" != denied ] || return 1
                if [ "$mock_release_target" = from-ref ]; then
                    latest_count=$(cat "$latest_counter")
                    latest_value=$(printf '%s\n' "$mock_latest_values" | sed -n "${latest_count}p")
                    if [ "$latest_value" = tag ]; then
                        printf '%s\n' "$mock_annotated_sha"
                    else
                        printf '%s\n' "$latest_value"
                    fi
                else
                    printf '%s\n' "$mock_release_target"
                fi
                ;;
            "api repos/$REPO/git/ref/tags/$FINAL_TAG --silent")
                printf 'inspect-tag:%s\n' "$FINAL_TAG" >> "$action_log"
                case "$mock_tag_state" in
                    absent | create-denied)
                        echo 'gh: Not Found (HTTP 404)' >&2
                        return 1
                        ;;
                esac
                if [ "$mock_tag_state" = inspect-denied ]; then
                    echo 'gh: Forbidden (HTTP 403)' >&2
                    return 1
                fi
                ;;
            "api --method PATCH repos/$REPO/git/refs/tags/$FINAL_TAG -f sha=$EXPECTED_SHA -F force=true --silent")
                if [ "$mock_tag_state" = denied ]; then
                    echo 'gh: Forbidden (HTTP 403)' >&2
                    return 1
                fi
                printf 'move-tag:%s:%s\n' "$FINAL_TAG" "$EXPECTED_SHA" >> "$action_log"
                ;;
            "api --method POST repos/$REPO/git/refs -f ref=refs/tags/$FINAL_TAG -f sha=$EXPECTED_SHA --silent")
                if [ "$mock_tag_state" = create-denied ]; then
                    echo 'gh: Forbidden (HTTP 403)' >&2
                    return 1
                fi
                printf 'create-tag:%s:%s\n' "$FINAL_TAG" "$EXPECTED_SHA" >> "$action_log"
                ;;
            *) self_test_fail "unexpected GitHub request: $*" ;;
        esac
    }

    current_main_sha() {
        count=$(cat "$main_counter")
        count=$((count + 1))
        printf '%s\n' "$count" > "$main_counter"
        printf 'main\n' >> "$action_log"
        printf '%s\n' "$mock_main_values" | sed -n "${count}p"
    }
    # One line per call; a line `none` models an absent alias.
    next_latest_value() {
        latest_count=$(cat "$latest_counter")
        latest_count=$((latest_count + 1))
        printf '%s\n' "$latest_count" > "$latest_counter"
        printf 'latest-target\n' >> "$action_log"
        latest_value=$(printf '%s\n' "$mock_latest_values" | sed -n "${latest_count}p")
        printf '%s\n' "$latest_value"
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
        [ "$mock_catalog_failure" = false ] || return 1
        printf '%s\n' "$mock_existing_ids"
    }
    delete_release() {
        printf 'delete-release:%s\n' "$1" >> "$action_log"
        if [ "$1" = 90 ] && [ "$mock_delete_failure" = true ]; then
            echo 'injected predecessor deletion failure' >&2
            return 1
        fi
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
        case_output=$test_dir/case-output
        set +e
        publish_latest "$asset_a" "$asset_b" > "$case_output" 2>&1
        case_status=$?
        set -e
        cat "$case_output"
        [ "$case_status" -eq "$expected_status" ] ||
            self_test_fail "$case_name exited $case_status, expected $expected_status" || return 1
        if [ "$expected_status" -ne 0 ] &&
            grep -E 'delete-release:90|delete-tag|move-tag:|create-tag:|promote:' "$action_log" >/dev/null 2>&1; then
            self_test_fail "$case_name reached the stable cutover" || return 1
        fi
        if [ "$expected_status" -eq 0 ]; then
            grep -E "\[stage0-publish\] (moved tag $FINAL_TAG to|created tag $FINAL_TAG at) $EXPECTED_SHA" \
                "$case_output" >/dev/null 2>&1 ||
                self_test_fail "$case_name did not report the successful tag mutation" || return 1
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
inspect-tag:stage0-latest
move-tag:stage0-latest:$expected_sha
delete-release:90
promote:100
main"
    [ "$(cat "$action_log")" = "$expected_actions" ] ||
        self_test_fail "happy-path action mismatch" || return 1

    # Main advancing past the candidate at every checkpoint is normal: the
    # candidate is still on main and newer than the alias, so it is promoted.
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
    mock_tag_state=absent
    mock_existing_ids=
    reset_case "$expected_sha
$expected_sha
$expected_sha" "none
none" ""
    run_case missing-tag 0 || return 1
    grep -F "create-tag:$FINAL_TAG:$expected_sha" "$action_log" >/dev/null 2>&1 ||
        self_test_fail "missing tag was not created" || return 1
    if grep -F 'delete-release:' "$action_log" >/dev/null 2>&1; then
        self_test_fail "first publication deleted an existing release" || return 1
    fi
    mock_existing_ids=90
    mock_tag_state=denied
    reset_case "$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    run_case tag-update-denied 1 || return 1
    mock_tag_state=inspect-denied
    reset_case "$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    run_case tag-inspection-denied 1 || return 1
    mock_tag_state=create-denied
    reset_case "$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    run_case tag-create-denied 1 || return 1
    mock_tag_state=present
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

    # Release visibility must not turn an existing newer/equal Git tag into
    # absence. Exercise the real target adapter at the mocked API boundary.
    mock_release_visibility=draft
    reset_case "$newer_sha
$newer_sha
$newer_sha" "$newer_sha
$newer_sha" "$expected_sha $newer_sha ahead
$newer_sha $expected_sha behind"
    run_case newer-draft-alias 3 || return 1
    expect_no_candidate newer-draft-alias || return 1
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$expected_sha
$expected_sha" ""
    run_case equal-draft-alias 3 || return 1
    expect_no_candidate equal-draft-alias || return 1
    reset_case "$expected_sha
$expected_sha" "$older_sha
$newer_sha" "$advance
$newer_sha $expected_sha behind"
    run_case draft-alias-advanced-during-upload 3 || return 1
    grep -F 'delete-release:100' "$action_log" >/dev/null 2>&1 ||
        self_test_fail "did not discard candidate superseded by a draft" || return 1
    mock_release_visibility=public

    reset_case "$expected_sha
$expected_sha
$expected_sha" "tag
tag" "$advance"
    run_case annotated-alias 0 || return 1
    [ "$(grep -c '^resolve-annotated$' "$action_log")" -eq 2 ] ||
        self_test_fail "annotated tag was not resolved at both checkpoints" || return 1
    for invalid_ref in denied bad-type empty-sha short-sha bad-sha; do
        reset_case "$expected_sha" "$invalid_ref" ""
        run_case "invalid-ref-$invalid_ref" 1 || return 1
        expect_no_candidate "invalid-ref-$invalid_ref" || return 1
    done
    for invalid_target in denied '' abcd 0123456789abcdef0123456789abcdef0123456g; do
        mock_annotated_sha=$invalid_target
        reset_case "$expected_sha" tag ""
        run_case invalid-annotated-target 1 || return 1
        expect_no_candidate invalid-annotated-target || return 1
    done
    mock_annotated_sha=$older_sha

    mock_annotated_sha=$expected_sha
    reset_case "$expected_sha" tag ""
    run_case annotated-alias-already-current 3 || return 1
    expect_no_candidate annotated-alias-already-current || return 1
    mock_annotated_sha=$older_sha

    # An interrupted cutover has moved the ref but retained the old release.
    # A fresh same-commit attempt must finish replacing that older payload.
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$older_sha
$older_sha" "$advance"
    mock_delete_failure=true
    set +e
    publish_latest "$asset_a" "$asset_b" > "$test_dir/interrupted-output" 2>&1
    interrupted_status=$?
    set -e
    [ "$interrupted_status" -eq 1 ] ||
        self_test_fail "predecessor deletion failure was ignored" || return 1
    if grep -F 'promote:' "$action_log" >/dev/null 2>&1; then
        self_test_fail "promotion continued after failed predecessor deletion" || return 1
    fi
    grep -F "move-tag:$FINAL_TAG:$expected_sha" "$action_log" >/dev/null 2>&1 ||
        self_test_fail "interrupted fixture did not move the tag" || return 1
    mock_delete_failure=false
    mock_release_target=$older_sha
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$expected_sha
$expected_sha" "$advance"
    run_case interrupted-tag-cutover-resume 0 || return 1
    [ "$(grep -c '^list-existing$' "$action_log")" -eq 2 ] ||
        self_test_fail "recovery repeated release discovery inside the final guard" || return 1

    # Deletion can also finish before promotion fails: the tag then exists
    # without a release. A retry restores it without deleting another release.
    mock_existing_ids=
    reset_case "$expected_sha
$expected_sha
$expected_sha" "$expected_sha
$expected_sha" ""
    run_case interrupted-release-cutover-resume 0 || return 1
    if grep -F 'delete-release:' "$action_log" >/dev/null 2>&1; then
        self_test_fail "release recovery deleted a nonexistent predecessor" || return 1
    fi
    mock_existing_ids=90

    # Inconsistent/newer metadata or an unanswerable recovery lookup cannot
    # justify replacing the current release, even when the ref equals us.
    mock_release_target=$newer_sha
    reset_case "$newer_sha
$newer_sha
$newer_sha" "$expected_sha
$expected_sha" "$expected_sha $newer_sha ahead
$newer_sha $expected_sha behind"
    run_case newer-release-after-tag-read 3 || return 1
    expect_no_candidate newer-release-after-tag-read || return 1
    for invalid_release_target in '' abcd denied; do
        mock_release_target=$invalid_release_target
        reset_case "$expected_sha" "$expected_sha" ""
        run_case invalid-recovery-target 1 || return 1
        expect_no_candidate invalid-recovery-target || return 1
    done
    mock_existing_ids='90
91'
    reset_case "$expected_sha" "$expected_sha" ""
    run_case duplicate-recovery-releases 1 || return 1
    expect_no_candidate duplicate-recovery-releases || return 1
    mock_existing_ids=90
    mock_release_target=from-ref
    mock_catalog_failure=true
    reset_case "$expected_sha" "$expected_sha" ""
    run_case recovery-catalog-unavailable 1 || return 1
    expect_no_candidate recovery-catalog-unavailable || return 1
    mock_catalog_failure=false

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
