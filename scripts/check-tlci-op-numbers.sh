#!/usr/bin/env sh
set -eu

# check-tlci-op-numbers.sh - fail closed on duplicate tlci host callback op
# numbers and drift between the implementation and SPEC catalog.
#
# The host callback ops are additive ABI constants in a single source-bound
# binary: the producer emits an op number and `compiler-comptime-host-invoke-step`
# dispatches on it through a `cond`. Nothing in the type system or the existing
# manually maintained `tlci-test-host-callback-op-layout-ok?` rejects two
# constants sharing a number. Two branches adding ops in different regions of
# the file therefore merge without a textual conflict and produce duplicate
# `cond` arms, where the first wins and the second is silently dead.
#
# This gate reads declarations directly from the source, then requires section
# 5.17.1's append-only operation table to contain exactly the same numeric IDs.
# In pull-request CI, --open-prs additionally compares the current PR's changed
# claims with current main and the changed claims on every other open PR head.
# That mode is deliberately opt-in so normal local verification stays
# deterministic and network-free.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SOURCE=src/tlci_core.tl
SPEC=SPEC.md
SELF_TEST=0
OPEN_PRS=0
if [ "${1:-}" = "--self-test" ]; then
    SELF_TEST=1
elif [ "${1:-}" = "--open-prs" ]; then
    OPEN_PRS=1
elif [ "$#" -ne 0 ]; then
    echo "usage: scripts/check-tlci-op-numbers.sh [--self-test | --open-prs]" >&2
    exit 2
fi

# Emit "<value> <name>" for every `(define tlci-host-callback-op-<name> : i64`
# whose next non-blank line is an integer literal.
extract_ops() {
    awk '
        /^\(define tlci-host-callback-op-[^ ]+ : i64$/ {
            name = $2
            pending = 1
            next
        }
        pending {
            value = $0
            gsub(/[^0-9-]/, "", value)
            if (value != "") print value "\t" name
            pending = 0
        }
    ' "$1"
}

check_spec_catalog() {
    awk '
        FNR == NR {
            if ($0 ~ /^\(define tlci-host-callback-op-[^ ]+ : i64$/) {
                source_name = $2
                sub(/^tlci-host-callback-op-/, "", source_name)
                pending_source_value = 1
                next
            }
            if (pending_source_value) {
                value = $0
                gsub(/[^0-9-]/, "", value)
                if (value != "") {
                    if ((value + 0) < 1) {
                        print "tlci callback op ids must be positive in " FILENAME > "/dev/stderr"
                        bad = 1
                    }
                    source[value] = source_name
                    if ((value + 0) > max_value) max_value = value + 0
                }
                pending_source_value = 0
            }
            next
        }
        /^\| ID \| Operation \|$/ {
            in_catalog = 1
            next
        }
        in_catalog && /^\| ---:/ {
            next
        }
        in_catalog && /^\|/ {
            split($0, fields, "|")
            value = fields[2]
            gsub(/[[:space:]]/, "", value)
            if (value !~ /^[0-9]+$/) {
                print "malformed tlci callback op id `" value "` in " FILENAME > "/dev/stderr"
                bad = 1
                next
            }
            if ((value + 0) < 1) {
                print "tlci callback op ids must be positive in " FILENAME > "/dev/stderr"
                bad = 1
            }
            if (spec_count > 0 && (value + 0) <= last_spec_value) {
                print "tlci callback ops are not strictly increasing at " value " in " FILENAME > "/dev/stderr"
                bad = 1
            }
            if (value in spec) {
                print "duplicate tlci callback op " value " in " FILENAME > "/dev/stderr"
                bad = 1
            }
            spec[value] = 1
            operation = fields[3]
            sub(/^[^`]*`/, "", operation)
            sub(/`.*/, "", operation)
            spec_name[value] = operation
            last_spec_value = value + 0
            spec_count++
            if ((value + 0) > max_value) max_value = value + 0
            next
        }
        in_catalog && $0 !~ /^\|/ {
            in_catalog = 0
        }
        END {
            for (value = 1; value <= max_value; value++) {
                key = value ""
                if ((key in source) && !(key in spec)) {
                    print "tlci callback op " value " (" source[key] ") is missing from " FILENAME > "/dev/stderr"
                    bad = 1
                }
                if ((key in spec) && !(key in source)) {
                    print "tlci callback op " value " is documented in " FILENAME " but absent from the implementation" > "/dev/stderr"
                    bad = 1
                }
                if ((key in source) && (key in spec) && source[key] != spec_name[key]) {
                    print "tlci callback op " value " is " source[key] " in the implementation but " spec_name[key] " in " FILENAME > "/dev/stderr"
                    bad = 1
                }
            }
            exit bad
        }
    ' "$1" "$2"
}

check_source() {
    duplicates=$(extract_ops "$1" | sort -n | awk -F'\t' '
        {
            if ($1 == last_value) {
                print $1 "\t" last_name "\t" $2
            }
            last_value = $1
            last_name = $2
        }
    ')
    if [ -n "$duplicates" ]; then
        echo "duplicate tlci host callback op numbers in $1:" >&2
        printf '%s\n' "$duplicates" | while IFS="$(printf '\t')" read -r value a b; do
            echo "  op $value declared by both $a and $b" >&2
        done
        return 1
    fi
    return 0
}

# Emit the op map stored at REVISION into DESTINATION without checking out the
# revision. Keeping every PR head out of the worktree lets the networked gate
# compare an arbitrary number of branches in one small job.
extract_revision_ops() {
    revision=$1
    destination=$2
    source_snapshot="${destination}.source"
    if ! git show "$revision:$SOURCE" > "$source_snapshot"; then
        echo "failed to read $SOURCE from revision $revision" >&2
        rm -f "$source_snapshot"
        return 1
    fi
    extract_ops "$source_snapshot" > "$destination"
    rm -f "$source_snapshot"
}

# Emit every ID/name pair in HEAD_OPS that is new or changed relative to
# BASE_OPS. Unchanged catalog entries on a stale branch are not claims by that
# PR and therefore cannot create false cross-PR collisions.
extract_changed_claims() {
    base_ops=$1
    head_ops=$2
    destination=$3
    awk -F "$(printf '\t')" '
        NR == FNR {
            base[$1] = $2
            next
        }
        !($1 in base) || base[$1] != $2 {
            print $1 "\t" $2
        }
    ' "$base_ops" "$head_ops" |
        LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 > "$destination"
}

# Emit "<id> <left-name> <right-name>" for IDs claimed under different names.
# Claiming the same ID/name pair is not an ABI collision.
find_claim_collisions() {
    left_claims=$1
    right_claims=$2
    destination=$3
    awk -F "$(printf '\t')" '
        NR == FNR {
            left[$1] = $2
            next
        }
        ($1 in left) && left[$1] != $2 {
            print $1 "\t" left[$1] "\t" $2
        }
    ' "$left_claims" "$right_claims" |
        LC_ALL=C sort -t "$(printf '\t')" -k1,1n -k2,2 -k3,3 > "$destination"
}

check_open_pr_claims() {
    repository=${TLCI_GITHUB_REPOSITORY:-${GITHUB_REPOSITORY:-}}
    current_pr=${TLCI_CURRENT_PR:-}
    current_head=${TLCI_CURRENT_HEAD:-}
    base_branch=${TLCI_BASE_BRANCH:-main}
    remote=${TLCI_GIT_REMOTE:-origin}

    if [ -z "$repository" ] || [ -z "$current_pr" ] || [ -z "$current_head" ]; then
        echo "--open-prs requires TLCI_GITHUB_REPOSITORY, TLCI_CURRENT_PR, and TLCI_CURRENT_HEAD" >&2
        return 2
    fi
    case "$current_pr" in
        *[!0-9]* | "")
            echo "invalid TLCI_CURRENT_PR: $current_pr" >&2
            return 2
            ;;
    esac
    if ! command -v gh >/dev/null 2>&1; then
        echo "--open-prs requires the GitHub CLI (gh)" >&2
        return 2
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo "--open-prs requires git" >&2
        return 2
    fi

    workdir=target/tlci-open-pr-op-numbers
    rm -rf "$workdir"
    mkdir -p "$workdir"
    base_ref="refs/remotes/$remote/$base_branch"
    if ! git fetch --quiet --no-tags "$remote" \
        "+refs/heads/$base_branch:$base_ref"; then
        echo "failed to fetch $remote/$base_branch for the tlci op claim gate" >&2
        return 1
    fi

    if ! git cat-file -e "$current_head^{commit}" 2>/dev/null; then
        current_ref="refs/tlci-open-prs/$current_pr"
        if ! git fetch --quiet --no-tags "$remote" \
            "+refs/pull/$current_pr/head:$current_ref"; then
            echo "failed to fetch current PR #$current_pr head" >&2
            return 1
        fi
        fetched_current_head=$(git rev-parse "$current_ref")
        if [ "$fetched_current_head" != "$current_head" ]; then
            echo "PR #$current_pr head moved during the tlci op claim check:" >&2
            echo "  workflow head: $current_head" >&2
            echo "  current head:  $fetched_current_head" >&2
            echo "rerun the check on the current head" >&2
            return 1
        fi
    fi

    if ! current_base=$(git merge-base "$base_ref" "$current_head"); then
        echo "failed to find the merge base for PR #$current_pr" >&2
        return 1
    fi
    current_base_ops="$workdir/current-base.tsv"
    current_head_ops="$workdir/current-head.tsv"
    current_claims="$workdir/current-claims.tsv"
    main_ops="$workdir/main.tsv"
    extract_revision_ops "$current_base" "$current_base_ops"
    extract_revision_ops "$current_head" "$current_head_ops"
    extract_changed_claims "$current_base_ops" "$current_head_ops" "$current_claims"
    extract_revision_ops "$base_ref" "$main_ops"

    claim_count=$(wc -l < "$current_claims" | tr -d ' ')
    if [ "$claim_count" -eq 0 ]; then
        echo "tlci open-PR op claim check: PR #$current_pr changes no callback op claims"
        return 0
    fi

    bad=0
    main_collisions="$workdir/main-collisions.tsv"
    find_claim_collisions "$current_claims" "$main_ops" "$main_collisions"
    if [ -s "$main_collisions" ]; then
        echo "tlci host callback op claims in PR #$current_pr collide with $remote/$base_branch:" >&2
        awk -F "$(printf '\t')" \
            -v current="PR #$current_pr" \
            -v other="$remote/$base_branch" '
                {
                    print "  op " $1 ": " current " claims " $2 "; " other " claims " $3
                }
            ' "$main_collisions" >&2
        bad=1
    fi

    pr_list="$workdir/open-prs.tsv"
    if ! gh api --paginate \
        "repos/$repository/pulls?state=open&base=$base_branch&per_page=100" \
        --jq '.[].number' > "$pr_list"; then
        echo "failed to list open PR heads for $repository" >&2
        return 1
    fi

    checked_prs=0
    while IFS= read -r other_pr; do
        [ -n "$other_pr" ] || continue
        [ "$other_pr" = "$current_pr" ] && continue
        case "$other_pr" in
            *[!0-9]*)
                echo "invalid open PR number from GitHub: $other_pr" >&2
                bad=1
                continue
                ;;
        esac

        other_ref="refs/tlci-open-prs/$other_pr"
        if ! git fetch --quiet --no-tags "$remote" \
            "+refs/pull/$other_pr/head:$other_ref"; then
            echo "failed to fetch open PR #$other_pr head" >&2
            bad=1
            continue
        fi
        if ! other_base=$(git merge-base "$base_ref" "$other_ref"); then
            echo "failed to find the merge base for open PR #$other_pr" >&2
            bad=1
            continue
        fi

        other_base_ops="$workdir/pr-$other_pr-base.tsv"
        other_head_ops="$workdir/pr-$other_pr-head.tsv"
        other_claims="$workdir/pr-$other_pr-claims.tsv"
        collisions="$workdir/pr-$other_pr-collisions.tsv"
        if ! extract_revision_ops "$other_base" "$other_base_ops" ||
            ! extract_revision_ops "$other_ref" "$other_head_ops"; then
            bad=1
            continue
        fi
        extract_changed_claims "$other_base_ops" "$other_head_ops" "$other_claims"
        find_claim_collisions "$current_claims" "$other_claims" "$collisions"
        if [ -s "$collisions" ]; then
            echo "tlci host callback op claims collide between PR #$current_pr and PR #$other_pr:" >&2
            awk -F "$(printf '\t')" \
                -v current="PR #$current_pr" \
                -v other="PR #$other_pr" '
                    {
                        print "  op " $1 ": " current " claims " $2 "; " other " claims " $3
                    }
                ' "$collisions" >&2
            bad=1
        fi
        checked_prs=$((checked_prs + 1))
    done < "$pr_list"

    if [ "$bad" -ne 0 ]; then
        return 1
    fi
    echo "tlci open-PR op claim check passed ($claim_count changed claim(s), $checked_prs other open PR(s))"
}

if [ "$SELF_TEST" -eq 1 ]; then
    WORKDIR=target/tlci-op-numbers-selftest
    rm -rf "$WORKDIR"
    mkdir -p "$WORKDIR"
    BAD="$WORKDIR/duplicate.tl"
    cat > "$BAD" <<'FIXTURE'
(define tlci-host-callback-op-alpha : i64
  222)
(define tlci-host-callback-op-beta : i64
  223)
(define tlci-host-callback-op-gamma : i64
  222)
FIXTURE
    if check_source "$BAD" 2>/dev/null; then
        echo "self-test: duplicate op numbers were not rejected" >&2
        exit 1
    fi
    GOOD="$WORKDIR/unique.tl"
    cat > "$GOOD" <<'FIXTURE'
(define tlci-host-callback-op-alpha : i64
  222)
(define tlci-host-callback-op-beta : i64
  223)
FIXTURE
    if ! check_source "$GOOD"; then
        echo "self-test: unique op numbers were rejected" >&2
        exit 1
    fi
    GOOD_SPEC="$WORKDIR/catalog-good.md"
    cat > "$GOOD_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| 222 | `alpha` |
| 223 | `beta` |
FIXTURE
    if ! check_spec_catalog "$GOOD" "$GOOD_SPEC"; then
        echo "self-test: matching SPEC catalog was rejected" >&2
        exit 1
    fi
    BAD_SPEC="$WORKDIR/catalog-missing.md"
    cat > "$BAD_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| 222 | `alpha` |
FIXTURE
    if check_spec_catalog "$GOOD" "$BAD_SPEC" 2>/dev/null; then
        echo "self-test: missing SPEC catalog op was not rejected" >&2
        exit 1
    fi
    EXTRA_SPEC="$WORKDIR/catalog-extra.md"
    cat > "$EXTRA_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| 222 | `alpha` |
| 223 | `beta` |
| 224 | `gamma` |
FIXTURE
    if check_spec_catalog "$GOOD" "$EXTRA_SPEC" 2>/dev/null; then
        echo "self-test: extra SPEC catalog op was not rejected" >&2
        exit 1
    fi
    ZERO_SPEC="$WORKDIR/catalog-zero.md"
    cat > "$ZERO_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| 0 | `zero` |
| 222 | `alpha` |
| 223 | `beta` |
FIXTURE
    if check_spec_catalog "$GOOD" "$ZERO_SPEC" 2>/dev/null; then
        echo "self-test: non-positive SPEC catalog op was not rejected" >&2
        exit 1
    fi
    NEGATIVE_SPEC="$WORKDIR/catalog-negative.md"
    cat > "$NEGATIVE_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| -1 | `negative` |
| 222 | `alpha` |
| 223 | `beta` |
FIXTURE
    if check_spec_catalog "$GOOD" "$NEGATIVE_SPEC" 2>/dev/null; then
        echo "self-test: malformed SPEC catalog op was not rejected" >&2
        exit 1
    fi
    BAD_NAME_SPEC="$WORKDIR/catalog-wrong-name.md"
    cat > "$BAD_NAME_SPEC" <<'FIXTURE'
| ID | Operation |
| ---: | --- |
| 222 | `alpha` |
| 223 | `gamma` |
FIXTURE
    if check_spec_catalog "$GOOD" "$BAD_NAME_SPEC" 2>/dev/null; then
        echo "self-test: mismatched SPEC catalog name was not rejected" >&2
        exit 1
    fi
    CLAIM_BASE="$WORKDIR/claim-base.tsv"
    CLAIM_HEAD="$WORKDIR/claim-head.tsv"
    CLAIMS="$WORKDIR/claims.tsv"
    cat > "$CLAIM_BASE" <<'FIXTURE'
222	tlci-host-callback-op-alpha
223	tlci-host-callback-op-beta
FIXTURE
    cat > "$CLAIM_HEAD" <<'FIXTURE'
222	tlci-host-callback-op-alpha
223	tlci-host-callback-op-beta-renamed
224	tlci-host-callback-op-delta
FIXTURE
    extract_changed_claims "$CLAIM_BASE" "$CLAIM_HEAD" "$CLAIMS"
    EXPECTED_CLAIMS="$WORKDIR/claims-expected.tsv"
    cat > "$EXPECTED_CLAIMS" <<'FIXTURE'
223	tlci-host-callback-op-beta-renamed
224	tlci-host-callback-op-delta
FIXTURE
    if ! cmp "$EXPECTED_CLAIMS" "$CLAIMS"; then
        echo "self-test: changed op claims were not isolated from the base map" >&2
        exit 1
    fi
    OTHER_CLAIMS="$WORKDIR/other-claims.tsv"
    cat > "$OTHER_CLAIMS" <<'FIXTURE'
224	tlci-host-callback-op-epsilon
225	tlci-host-callback-op-zeta
FIXTURE
    COLLISIONS="$WORKDIR/collisions.tsv"
    find_claim_collisions "$CLAIMS" "$OTHER_CLAIMS" "$COLLISIONS"
    EXPECTED_COLLISIONS="$WORKDIR/collisions-expected.tsv"
    cat > "$EXPECTED_COLLISIONS" <<'FIXTURE'
224	tlci-host-callback-op-delta	tlci-host-callback-op-epsilon
FIXTURE
    if ! cmp "$EXPECTED_COLLISIONS" "$COLLISIONS"; then
        echo "self-test: different op names on one ID were not reported" >&2
        exit 1
    fi
    SAME_CLAIMS="$WORKDIR/same-claims.tsv"
    cat > "$SAME_CLAIMS" <<'FIXTURE'
224	tlci-host-callback-op-delta
FIXTURE
    find_claim_collisions "$CLAIMS" "$SAME_CLAIMS" "$COLLISIONS"
    if [ -s "$COLLISIONS" ]; then
        echo "self-test: the same ID/name claim was reported as a collision" >&2
        exit 1
    fi
    OPEN_PR_ROOT="$WORKDIR/open-pr"
    OPEN_PR_REMOTE="$OPEN_PR_ROOT/remote.git"
    OPEN_PR_REPO="$OPEN_PR_ROOT/repo"
    OPEN_PR_FAKE_BIN="$OPEN_PR_ROOT/bin"
    mkdir -p "$OPEN_PR_FAKE_BIN"
    git init --quiet --bare "$OPEN_PR_REMOTE"
    git -c init.defaultBranch=main init --quiet "$OPEN_PR_REPO"
    (
        cd "$OPEN_PR_REPO"
        git config user.email tlci-op-gate@example.invalid
        git config user.name tlci-op-gate
        mkdir -p src
        cat > src/tlci_core.tl <<'FIXTURE'
(define tlci-host-callback-op-alpha : i64
  222)
FIXTURE
        git add src/tlci_core.tl
        git commit --quiet -m base
        git remote add origin "$ROOT/$OPEN_PR_REMOTE"
        git push --quiet origin main

        git switch --quiet -c current-pr
        cat >> src/tlci_core.tl <<'FIXTURE'
(define tlci-host-callback-op-delta : i64
  224)
FIXTURE
        git add src/tlci_core.tl
        git commit --quiet -m current
        git push --quiet origin current-pr:refs/pull/1/head
        current_head=$(git rev-parse HEAD)

        git switch --quiet -c other-pr main
        cat >> src/tlci_core.tl <<'FIXTURE'
(define tlci-host-callback-op-epsilon : i64
  224)
FIXTURE
        git add src/tlci_core.tl
        git commit --quiet -m other
        git push --quiet origin other-pr:refs/pull/2/head
        git switch --quiet current-pr

        cat > "$ROOT/$OPEN_PR_FAKE_BIN/gh" <<FIXTURE
#!/usr/bin/env sh
printf '1\\n2\\n'
FIXTURE
        chmod +x "$ROOT/$OPEN_PR_FAKE_BIN/gh"
        if PATH="$ROOT/$OPEN_PR_FAKE_BIN:$PATH" \
            TLCI_GITHUB_REPOSITORY=example/typelisp \
            TLCI_CURRENT_PR=1 \
            TLCI_CURRENT_HEAD="$current_head" \
            check_open_pr_claims \
            > "$ROOT/$OPEN_PR_ROOT/collision.stdout" \
            2> "$ROOT/$OPEN_PR_ROOT/collision.stderr"; then
            echo "self-test: cross-PR op collision was not rejected" >&2
            exit 1
        fi

        git switch --quiet -c advanced-main main
        cat >> src/tlci_core.tl <<'FIXTURE'
(define tlci-host-callback-op-main-gamma : i64
  224)
FIXTURE
        git add src/tlci_core.tl
        git commit --quiet -m advanced-main
        git push --quiet origin advanced-main:main
        cat > "$ROOT/$OPEN_PR_FAKE_BIN/gh" <<'FIXTURE'
#!/usr/bin/env sh
printf '1\n'
FIXTURE
        chmod +x "$ROOT/$OPEN_PR_FAKE_BIN/gh"
        if PATH="$ROOT/$OPEN_PR_FAKE_BIN:$PATH" \
            TLCI_GITHUB_REPOSITORY=example/typelisp \
            TLCI_CURRENT_PR=1 \
            TLCI_CURRENT_HEAD="$current_head" \
            check_open_pr_claims \
            > "$ROOT/$OPEN_PR_ROOT/main-collision.stdout" \
            2> "$ROOT/$OPEN_PR_ROOT/main-collision.stderr"; then
            echo "self-test: main-branch op collision was not rejected" >&2
            exit 1
        fi
    )
    if ! grep -qF \
        "tlci host callback op claims collide between PR #1 and PR #2:" \
        "$OPEN_PR_ROOT/collision.stderr"; then
        echo "self-test: cross-PR diagnostic did not name both PRs" >&2
        sed 's/^/  /' "$OPEN_PR_ROOT/collision.stderr" >&2 || true
        exit 1
    fi
    if ! grep -qF \
        "op 224: PR #1 claims tlci-host-callback-op-delta; PR #2 claims tlci-host-callback-op-epsilon" \
        "$OPEN_PR_ROOT/collision.stderr"; then
        echo "self-test: cross-PR diagnostic did not name both op claims" >&2
        sed 's/^/  /' "$OPEN_PR_ROOT/collision.stderr" >&2 || true
        exit 1
    fi
    if ! grep -qF \
        "tlci host callback op claims in PR #1 collide with origin/main:" \
        "$OPEN_PR_ROOT/main-collision.stderr"; then
        echo "self-test: main-collision diagnostic did not name the PR and base" >&2
        sed 's/^/  /' "$OPEN_PR_ROOT/main-collision.stderr" >&2 || true
        exit 1
    fi
    if ! grep -qF \
        "op 224: PR #1 claims tlci-host-callback-op-delta; origin/main claims tlci-host-callback-op-main-gamma" \
        "$OPEN_PR_ROOT/main-collision.stderr"; then
        echo "self-test: main-collision diagnostic did not name both op claims" >&2
        sed 's/^/  /' "$OPEN_PR_ROOT/main-collision.stderr" >&2 || true
        exit 1
    fi
    rm -rf "$OPEN_PR_ROOT"
    COUNT=$(extract_ops "$SOURCE" | wc -l | tr -d ' ')
    if [ "$COUNT" -lt 100 ]; then
        echo "self-test: only $COUNT op declarations found in $SOURCE" >&2
        echo "self-test: the extractor stopped matching the source shape" >&2
        exit 1
    fi
    echo "tlci op number gate self-tests passed ($COUNT declarations parsed)"
fi

if [ "$OPEN_PRS" -eq 1 ]; then
    check_open_pr_claims
fi
check_source "$SOURCE"
check_spec_catalog "$SOURCE" "$SPEC"
echo "tlci host callback catalog matches SPEC ($(extract_ops "$SOURCE" | wc -l | tr -d ' ') unique declarations)"
