#!/usr/bin/env sh
set -eu

# Shared-view ratchet.
#
# The `*-shared-view` macros (compiler_owned_view.tl and the per-module
# wrappers built on them) read a place through an unchecked shallow alias.
# They are migration scaffolding: new code borrows with `&`/`&mut`, element
# references and patterns instead. This gate counts the call uses of every
# identifier containing `-shared-view` in src/ and stdlib/, module-qualified
# forms included and definitions excluded. It compares the working tree against
# the resolved git base commit (merge-base with the target branch, or
# HEAD/HEAD^1 when HEAD equals that base) and fails if the count increases, so
# no change can add views without maintaining a checked-in baseline file.
#
# It also reports, without gating, the views weighted by the call sites of the
# function or macro that holds them, with thin wrappers (an accessor around one
# view) transparent: a wrapper's call sites count as views at their callers.
# A copy moved from inside an accessor to its call sites then weighs the same,
# so the report compares a migration's two sides on one rule.
#
# usage: scripts/check-shared-view-count.sh [--base <rev>] [--self-test]

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-shared-view-count.sh [--base <rev>]
       scripts/check-shared-view-count.sh --self-test

Count `*-shared-view*` call uses in src/ and stdlib/ against the git base
commit (merge-base with origin/$GITHUB_BASE_REF or $GITHUB_BASE_REF when
GITHUB_BASE_REF is set, otherwise origin/main or main; or HEAD/HEAD^1 when on
the base branch). --base <rev> or SHARED_VIEW_COUNT_BASE compares directly
against <rev>; --self-test runs the counter's own tests.
EOF
}

SELF_TEST=0
BASE_CLI=""
BASE_CLI_SET=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --self-test)
            if [ "$SELF_TEST" -eq 1 ] || [ "$BASE_CLI_SET" -eq 1 ]; then
                usage
                exit 2
            fi
            SELF_TEST=1
            shift
            ;;
        --base)
            if [ "$SELF_TEST" -eq 1 ] || [ "$BASE_CLI_SET" -eq 1 ] || [ "$#" -lt 2 ] || [ -z "$2" ]; then
                usage
                exit 2
            fi
            BASE_CLI=$2
            BASE_CLI_SET=1
            shift 2
            ;;
        --base=*)
            _val=${1#--base=}
            if [ "$SELF_TEST" -eq 1 ] || [ "$BASE_CLI_SET" -eq 1 ] || [ -z "$_val" ]; then
                usage
                exit 2
            fi
            BASE_CLI=$_val
            BASE_CLI_SET=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            usage
            exit 2
            ;;
    esac
done

SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
FIXTURE_METRICS_TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${SHARED_VIEW_COUNT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
if [ "$BASE_CLI_SET" -eq 1 ]; then
    BASE_OVERRIDE=$BASE_CLI
else
    BASE_OVERRIDE=${SHARED_VIEW_COUNT_BASE:-}
fi

# An identifier as TypeLisp spells a call head, optionally module-qualified.
NAME_RE='[A-Za-z0-9_./?!*<>=+-]*-shared-view[A-Za-z0-9_?!*<>=+-]*'

# A sorted manifest keeps paths out of argv limits, with one scanner process
# per pass. getline/close preserves individual lines even without a final LF.
source_files() {
    _sf_root=$1
    set --
    [ -d "$_sf_root/src" ] && set -- "$@" "$_sf_root/src"
    [ -d "$_sf_root/stdlib" ] && set -- "$@" "$_sf_root/stdlib"
    [ "$#" -gt 0 ] || return 0
    find "$@" -type f -name '*.tl' -print |
        LC_ALL=C sort
}

count_uses() {
    _cu_root=$1
    source_files "$_cu_root" | awk -v name="$NAME_RE" '
        BEGIN {
            heads = 0
            definitions = 0
            heads_pattern = "\\(" name
            definitions_pattern = "\\((define|defmacro) \\(" name
        }
        {
            file = $0
            while ((getline text < file) > 0) {
                # Every match contains this literal. Keep the two stable
                # patterns at separate match sites rather than alternating
                # them through a per-line regex helper.
                if (index(text, "-shared-view") == 0) continue
                rest = text
                while (match(rest, heads_pattern)) {
                    heads++
                    rest = substr(rest, RSTART + RLENGTH)
                }
                while (match(text, definitions_pattern)) {
                    definitions++
                    text = substr(text, RSTART + RLENGTH)
                }
            }
            close(file)
        }
        END { print heads - definitions }'
}

# Report only: the views weighted by how often the code holding them runs a
# call site. A view counts once per call site of the function or macro that
# holds it (at least once; call sites of a name that several modules define
# are shared among them), so a view hidden inside a widely called function is
# not counted as one.
#
# A thin wrapper is transparent: a function or macro whose body is one view
# and at most two other calls (an accessor such as `(define (x-ref [s : (& S)]
# [i : i64]) : T (x-array-shared-view s.slots i))`), or any `*-shared-view`
# definition. Its call sites count as views, each weighted by the call sites
# of the function that holds it, exactly as the view would if it were written
# there; the view inside the wrapper is not weighted again (a wrapper nothing
# calls still counts its view once). So moving a copy out of an accessor to
# its call sites leaves the number unchanged, and turning those call sites
# into borrows lowers it. Comments and string literals are skipped.
# The awk prelude both passes share: strip strings and comments, and track the
# definition a line belongs to.
WEIGHTED_SCAN='
    function scan_line() {
        line = text
        gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
        sub(/;.*/, "", line)
        definition = 0
        if (line ~ /^\(/) {
            current = ""
            if (match(line, /^\((define|defmacro) \([^ ()]+/)) {
                current = substr(line, RSTART, RLENGTH)
                sub(/^\((define|defmacro) \(/, "", current)
                defs[current]++
                definition = 1
            }
        }
    }
'

count_weighted() {
    _cw_root=$1
    _wrappers=$METRICS_WORK/wrappers
    # Pass 1: the transparent wrappers.
    source_files "$_cw_root" |
        LC_ALL=C awk "$WEIGHTED_SCAN"'
            function scan_text() {
                scan_line()
                rest = line
                first = definition
                while (match(rest, /\([A-Za-z0-9_.\/?!*<>=+-]+/)) {
                    head = substr(rest, RSTART + 1, RLENGTH - 1)
                    rest = substr(rest, RSTART + RLENGTH)
                    if (first) {
                        first = 0
                        continue
                    }
                    if (current == "" || head == "&" || head == "&mut" || head ~ /^[A-Z]/) {
                        continue
                    }
                    if (head ~ /-shared-view/) {
                        views[current]++
                    }
                    inner[current]++
                }
            }
            {
                file = $0
                while ((getline text < file) > 0) scan_text()
                close(file)
            }
            END {
                for (name in views) {
                    if (name !~ /-shared-view/ && views[name] == 1 && inner[name] <= 3) {
                        print name
                    }
                }
            }' > "$_wrappers"
    # Pass 2: views and wrapper call sites, by the call sites of their holder.
    source_files "$_cw_root" |
        LC_ALL=C awk -v wrappers="$_wrappers" "$WEIGHTED_SCAN"'
            BEGIN {
                while ((getline name < wrappers) > 0) {
                    transparent[name] = 1
                }
            }
            function scan_text() {
                scan_line()
                rest = line
                while (match(rest, /\([A-Za-z0-9_.\/?!*<>=+-]+/)) {
                    head = substr(rest, RSTART + 1, RLENGTH - 1)
                    rest = substr(rest, RSTART + RLENGTH)
                    base = head
                    sub(/^.*\./, "", base)
                    heads[base]++
                    if (current ~ /-shared-view/ || (current in transparent)) {
                        if (head ~ /-shared-view/) {
                            hidden[current]++
                        }
                        continue
                    }
                    if (definition && head == current) {
                        continue
                    }
                    if (head ~ /-shared-view/ || (base in transparent)) {
                        sites[current]++
                    }
                }
            }
            {
                file = $0
                while ((getline text < file) > 0) scan_text()
                close(file)
            }
            END {
                total = 0
                for (name in sites) {
                    if (name == "") {
                        total += sites[name]
                        continue
                    }
                    # Several modules may define the same name (`main`):
                    # share the call sites among the definitions.
                    calls = (heads[name] - defs[name]) / defs[name]
                    if (calls < 1) {
                        calls = 1
                    }
                    total += sites[name] * calls
                }
                for (name in hidden) {
                    if ((name in transparent) && heads[name] - defs[name] <= 0) {
                        total += hidden[name]
                    }
                }
                printf "%d\n", total + 0.5
            }'
}

# True when the working tree differs from HEAD in any tracked or untracked
# `.tl` file under src/ or stdlib/.
has_dirty_tl_sources() {
    _dirty=$(
        {
            git -C "$ROOT" -c core.quotePath=false diff --name-only HEAD -- src stdlib 2>/dev/null || true
            git -C "$ROOT" -c core.quotePath=false ls-files --others --exclude-standard -- src stdlib 2>/dev/null || true
        } | tr -d '\r' | grep -E '\.tl$' || true
    )
    [ -n "$_dirty" ]
}

# Resolve the git base commit into RESOLVED_BASE_COMMIT and RESOLVED_BASE_LABEL.
# Fails closed if the checkout is not a git repository or the base cannot be
# determined.
resolve_base_commit() {
    if [ ! -e "$ROOT/.git" ]; then
        echo "check-shared-view-count: $ROOT is not a git repository root (cannot resolve base commit)" >&2
        exit 1
    fi
    _rb_head=$(git -C "$ROOT" rev-parse --verify HEAD 2>/dev/null) || {
        echo "check-shared-view-count: cannot resolve git HEAD in $ROOT" >&2
        exit 1
    }

    if [ -n "$BASE_OVERRIDE" ]; then
        _rb_target=$(git -C "$ROOT" rev-parse --verify --end-of-options "$BASE_OVERRIDE^{commit}" 2>/dev/null) || {
            echo "check-shared-view-count: invalid base revision: $BASE_OVERRIDE" >&2
            exit 1
        }
        RESOLVED_BASE_COMMIT=$_rb_target
        RESOLVED_BASE_LABEL="$BASE_OVERRIDE ($_rb_target)"
        return 0
    fi

    _rb_base_ref=""
    _rb_merge_base=""

    # GitHub Actions pull_request workflows (such as .github/workflows/ci.yml)
    # check out the synthetic two-parent merge commit (github.sha) at
    # fetch-depth: 2, where HEAD^1 is the exact base commit on the target
    # branch and HEAD^2 is the PR head commit (without fetching origin/main).
    if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] &&
       [ -n "${GITHUB_SHA:-}" ] && [ "$_rb_head" = "$GITHUB_SHA" ]; then
        _rb_p1=$(git -C "$ROOT" rev-parse --verify HEAD^1 2>/dev/null || true)
        _rb_p2=$(git -C "$ROOT" rev-parse --verify HEAD^2 2>/dev/null || true)
        if [ -n "$_rb_p1" ] && [ -n "$_rb_p2" ]; then
            _rb_base_ref="HEAD^1"
            _rb_merge_base=$_rb_p1
        fi
    fi

    if [ -z "$_rb_merge_base" ]; then
        if [ -n "${GITHUB_BASE_REF:-}" ]; then
            for _rb_cand in "origin/$GITHUB_BASE_REF" "$GITHUB_BASE_REF"; do
                if _rb_target=$(git -C "$ROOT" rev-parse --verify --end-of-options "$_rb_cand^{commit}" 2>/dev/null); then
                    _rb_base_ref=$_rb_cand
                    _rb_merge_base=$(git -C "$ROOT" merge-base "$_rb_target" "$_rb_head" 2>/dev/null) || {
                        echo "check-shared-view-count: cannot compute merge-base between $_rb_cand and HEAD (is the checkout too shallow?)" >&2
                        exit 1
                    }
                    break
                fi
            done
            if [ -z "$_rb_merge_base" ]; then
                echo "check-shared-view-count: cannot resolve git base ref for GITHUB_BASE_REF=$GITHUB_BASE_REF (checked origin/$GITHUB_BASE_REF, $GITHUB_BASE_REF)" >&2
                exit 1
            fi
        else
            for _rb_cand in origin/main main; do
                if _rb_target=$(git -C "$ROOT" rev-parse --verify --end-of-options "$_rb_cand^{commit}" 2>/dev/null); then
                    _rb_base_ref=$_rb_cand
                    _rb_merge_base=$(git -C "$ROOT" merge-base "$_rb_target" "$_rb_head" 2>/dev/null) || {
                        echo "check-shared-view-count: cannot compute merge-base between $_rb_cand and HEAD (is the checkout too shallow?)" >&2
                        exit 1
                    }
                    break
                fi
            done
            if [ -z "$_rb_merge_base" ]; then
                echo "check-shared-view-count: cannot resolve git base ref (checked origin/main, main)" >&2
                exit 1
            fi
        fi
    fi

    if [ "$_rb_merge_base" = "$_rb_head" ]; then
        if has_dirty_tl_sources; then
            RESOLVED_BASE_COMMIT=$_rb_head
            RESOLVED_BASE_LABEL="HEAD ($_rb_head)"
            return 0
        fi
        _rb_parent=$(git -C "$ROOT" rev-parse --verify HEAD^1 2>/dev/null) || {
            echo "check-shared-view-count: HEAD equals base $_rb_base_ref and has no first parent HEAD^1 (is the checkout too shallow?)" >&2
            exit 1
        }
        RESOLVED_BASE_COMMIT=$_rb_parent
        RESOLVED_BASE_LABEL="HEAD^1 ($_rb_parent)"
        return 0
    fi

    RESOLVED_BASE_COMMIT=$_rb_merge_base
    RESOLVED_BASE_LABEL="$_rb_base_ref ($_rb_merge_base)"
}

# Extract src/ and stdlib/ from a git commit into an isolated temp directory
# without touching the working tree, then count with the exact same counter.
count_uses_at_commit() {
    _cuc_rev=$1
    _cuc_tree=$METRICS_WORK/base-tree
    _cuc_tar=$METRICS_WORK/base.tar
    rm -rf -- "$_cuc_tree" "$_cuc_tar"
    mkdir -p "$_cuc_tree"
    _cuc_paths=""
    for _cuc_dir in src stdlib; do
        if git -C "$ROOT" cat-file -e "$_cuc_rev:$_cuc_dir" 2>/dev/null; then
            _cuc_paths="$_cuc_paths $_cuc_dir"
        fi
    done
    if [ -n "$_cuc_paths" ]; then
        # shellcheck disable=SC2086
        git -C "$ROOT" archive --format=tar "$_cuc_rev" -- $_cuc_paths > "$_cuc_tar" || {
            echo "check-shared-view-count: failed to archive base commit $_cuc_rev" >&2
            exit 1
        }
        ( cd "$_cuc_tree" && tar -xf - ) < "$_cuc_tar" || {
            echo "check-shared-view-count: failed to extract base commit $_cuc_rev" >&2
            exit 1
        }
    fi
    _cuc_count=$(count_uses "$_cuc_tree")
    rm -rf -- "$_cuc_tree" "$_cuc_tar"
    printf '%s\n' "$_cuc_count"
}

run_check() {
    resolve_base_commit
    _rc_base_uses=$(count_uses_at_commit "$RESOLVED_BASE_COMMIT")
    _rc_uses=$(count_uses "$ROOT")
    echo "check-shared-view-count: weighted by call sites of the enclosing function or macro, thin wrappers transparent: $(count_weighted "$ROOT") (report only)"
    if [ "$_rc_uses" -gt "$_rc_base_uses" ]; then
        echo "check-shared-view-count: $_rc_uses shared-view uses exceed base $_rc_base_uses ($RESOLVED_BASE_LABEL)." >&2
        echo "check-shared-view-count: borrow with (& x), (&mut x), (& (array-ref items i)) or a pattern instead of adding a *-shared-view call." >&2
        exit 1
    fi
    if [ "$_rc_uses" -lt "$_rc_base_uses" ]; then
        echo "check-shared-view-count: $_rc_uses shared-view uses, below base $_rc_base_uses ($RESOLVED_BASE_LABEL)"
        return 0
    fi
    echo "check-shared-view-count: $_rc_uses shared-view uses (base $_rc_base_uses at $RESOLVED_BASE_LABEL)"
}

st_git() {
    _stg_repo=$1
    shift
    git -C "$_stg_repo" \
        -c user.name=self-test \
        -c user.email=self-test@example.invalid \
        -c commit.gpgsign=false \
        -c core.autocrlf=false \
        "$@"
}

st_init_repo() {
    _sti_repo=$1
    _sti_branch=${2:-main}
    mkdir -p "$_sti_repo"
    st_git "$_sti_repo" init -q
    st_git "$_sti_repo" symbolic-ref HEAD "refs/heads/$_sti_branch"
}

st_run() {
    _str_repo=$1
    shift
    env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u GITHUB_SHA -u SHARED_VIEW_COUNT_BASE \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_str_repo" \
        sh "$SCRIPT" "$@"
}

run_self_test() {
    _st_work=$METRICS_WORK/tree
    mkdir -p "$_st_work"

    # 1. Core branch ratchet (6 uses, weighted 9): same, lower, higher, overrides, merge-base drift.
    _st_repo=$_st_work/main-repo
    st_init_repo "$_st_repo" main
    mkdir -p "$_st_repo/src/sub" "$_st_repo/stdlib"
    cat > "$_st_repo/src/a.tl" <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define (thing-box-shared-view [b : (Box i64)]) : i64 (deref b))
(define (f [x : i64]) : i64
  (+ (local-shared-view x) (owned_view.compiler-owned-shared-view x)))
EOF
    cat > "$_st_repo/src/sub/b.tl" <<'EOF'
(define (g [b : (Box i64)]) : i64
  (thing-box-shared-view b))
(define (h) : i64 (ast.ast-expr-list-box-shared-view? 1))
(define (m) : i64 (+ (f 1) (f 2)))
(define (acc [x : i64]) : i64 (owned_view.compiler-owned-shared-view x))
(define (user) : i64 (acc 1))
(define (top) : i64 (+ (user) (user)))
EOF
    cat > "$_st_repo/stdlib/c.tl" <<'EOF'
;; mentions compiler-owned-shared-view without calling it
(define (k [x : i64]) : i64 (compiler-owned-place-shared-view x))
EOF
    st_git "$_st_repo" add src stdlib
    st_git "$_st_repo" commit -qm "base: 6 shared-view uses"
    _st_c1=$(st_git "$_st_repo" rev-parse HEAD)

    # Single-commit main (no HEAD^1, clean tree) must fail closed.
    if st_run "$_st_repo" > "$_st_work/no-parent.out" 2>&1; then
        echo "self-test: single-commit main without HEAD^1 was not rejected" >&2
        exit 1
    fi

    # Explicit --base HEAD / SHARED_VIEW_COUNT_BASE=HEAD compares directly against HEAD
    # without rewriting to HEAD^1 (works even on a single-commit repo).
    _st_direct_cli=$(st_run "$_st_repo" --base HEAD 2>&1) || {
        echo "self-test: explicit --base HEAD on single-commit repo failed: $_st_direct_cli" >&2
        exit 1
    }
    case "$_st_direct_cli" in
        *"6 shared-view uses (base 6 at HEAD ($_st_c1))"*) ;;
        *)
            echo "self-test: --base HEAD did not compare directly against HEAD: $_st_direct_cli" >&2
            exit 1
            ;;
    esac
    _st_direct_env=$(env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u GITHUB_SHA \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" SHARED_VIEW_COUNT_BASE=HEAD \
        sh "$SCRIPT" 2>&1) || {
        echo "self-test: explicit SHARED_VIEW_COUNT_BASE=HEAD failed: $_st_direct_env" >&2
        exit 1
    }
    case "$_st_direct_env" in
        *"6 shared-view uses (base 6 at HEAD ($_st_c1))"*) ;;
        *)
            echo "self-test: SHARED_VIEW_COUNT_BASE=HEAD did not compare directly against HEAD: $_st_direct_env" >&2
            exit 1
            ;;
    esac

    # Branch at same count (6 vs 6) passes and reports weighted count 9.
    st_git "$_st_repo" checkout -qb feature
    printf 'note\n' > "$_st_repo/README.md"
    st_git "$_st_repo" add README.md
    st_git "$_st_repo" commit -qm "feature: unchanged count"
    _st_same=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: same-count branch failed: $_st_same" >&2
        exit 1
    }
    case "$_st_same" in
        *"6 shared-view uses (base 6 at main ($_st_c1))"*) ;;
        *)
            echo "self-test: expected 6 uses at base 6, got: $_st_same" >&2
            exit 1
            ;;
    esac
    # f holds 2 views and has 2 callers; g, h and k hold 1 each and have none.
    # acc is a thin wrapper, so its call site in user counts as a view there,
    # and user has 2 callers: 4 + 1 + 1 + 1 + 2.
    case "$_st_same" in
        *"thin wrappers transparent: 9 (report only)"*) ;;
        *)
            echo "self-test: expected a weighted count of 9, got: $_st_same" >&2
            exit 1
            ;;
    esac
    # Working tree must remain untouched after base archive/count.
    if [ -n "$(st_git "$_st_repo" status --porcelain -- src stdlib)" ]; then
        echo "self-test: check mutated working tree" >&2
        exit 1
    fi

    # Lower count (5 vs 6) passes without a shared-view-baseline.tsv reminder.
    cat > "$_st_repo/stdlib/c.tl" <<'EOF'
;; mentions compiler-owned-shared-view without calling it
(define (k [x : i64]) : i64 x)
EOF
    st_git "$_st_repo" add stdlib/c.tl
    st_git "$_st_repo" commit -qm "feature: remove 1 shared-view"
    _st_lower=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: lower-count branch failed: $_st_lower" >&2
        exit 1
    }
    case "$_st_lower" in
        *"5 shared-view uses, below base 6"*) ;;
        *)
            echo "self-test: unexpected lower-count message: $_st_lower" >&2
            exit 1
            ;;
    esac
    case "$_st_lower" in
        *"shared-view-baseline.tsv"* | *"lower max_uses"*)
            echo "self-test: obsolete baseline reminder printed: $_st_lower" >&2
            exit 1
            ;;
    esac

    # Higher count (7 vs 6) fails closed with diagnostic.
    cat > "$_st_repo/stdlib/c.tl" <<'EOF'
(define (k [x : i64]) : i64
  (+ (compiler-owned-place-shared-view x) (compiler-owned-place-shared-view x)))
EOF
    st_git "$_st_repo" add stdlib/c.tl
    st_git "$_st_repo" commit -qm "feature: add 1 net shared-view (7 total)"
    if st_run "$_st_repo" > "$_st_work/over.out" 2>&1; then
        echo "self-test: higher-count branch was not rejected" >&2
        exit 1
    fi
    grep -q '7 shared-view uses exceed base 6' "$_st_work/over.out" || {
        echo "self-test: higher-count failure lacks diagnostic:" >&2
        cat "$_st_work/over.out" >&2
        exit 1
    }

    # Explicit --base and SHARED_VIEW_COUNT_BASE overrides (valid and invalid).
    _st_c7=$(st_git "$_st_repo" rev-parse HEAD)
    printf 'note2\n' >> "$_st_repo/README.md"
    st_git "$_st_repo" add README.md
    st_git "$_st_repo" commit -qm "feature: second 7-use commit"
    _st_override_cli=$(st_run "$_st_repo" --base "$_st_c7" 2>&1) || {
        echo "self-test: --base override failed: $_st_override_cli" >&2
        exit 1
    }
    case "$_st_override_cli" in
        *"7 shared-view uses (base 7 at $_st_c7 ($_st_c7))"*) ;;
        *)
            echo "self-test: unexpected --base output: $_st_override_cli" >&2
            exit 1
            ;;
    esac
    _st_override_env=$(env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u GITHUB_SHA \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" SHARED_VIEW_COUNT_BASE="$_st_c7" \
        sh "$SCRIPT" 2>&1) || {
        echo "self-test: SHARED_VIEW_COUNT_BASE override failed: $_st_override_env" >&2
        exit 1
    }
    case "$_st_override_env" in
        *"7 shared-view uses (base 7 at $_st_c7 ($_st_c7))"*) ;;
        *)
            echo "self-test: unexpected SHARED_VIEW_COUNT_BASE output: $_st_override_env" >&2
            exit 1
            ;;
    esac
    if st_run "$_st_repo" --base nonexistent-ref > "$_st_work/bad-cli.out" 2>&1; then
        echo "self-test: invalid --base was not rejected" >&2
        exit 1
    fi
    if env -u GITHUB_EVENT_NAME -u GITHUB_BASE_REF -u GITHUB_SHA \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" SHARED_VIEW_COUNT_BASE=nonexistent-ref \
        sh "$SCRIPT" > "$_st_work/bad-env.out" 2>&1; then
        echo "self-test: invalid SHARED_VIEW_COUNT_BASE was not rejected" >&2
        exit 1
    fi

    # 2. On-main HEAD vs HEAD^1, merge-base drift isolation, and dirty working tree.
    st_git "$_st_repo" checkout -q main
    cat > "$_st_repo/src/a.tl" <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define (thing-box-shared-view [b : (Box i64)]) : i64 (deref b))
(define (f [x : i64]) : i64 x)
EOF
    st_git "$_st_repo" add src/a.tl
    st_git "$_st_repo" commit -qm "main: lower to 4 uses"
    _st_c2=$(st_git "$_st_repo" rev-parse HEAD)

    # Feature forked from _st_c1 (6 uses); advance feature back to 6 uses and verify
    # merge-base uses _st_c1 (6), not main's newer tip _st_c2 (4).
    st_git "$_st_repo" checkout -q feature
    cat > "$_st_repo/stdlib/c.tl" <<'EOF'
(define (k [x : i64]) : i64 (compiler-owned-place-shared-view x))
EOF
    st_git "$_st_repo" add stdlib/c.tl
    st_git "$_st_repo" commit -qm "feature: back to 6 uses"
    _st_drift=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: diverged branch failed despite matching merge-base: $_st_drift" >&2
        exit 1
    }
    case "$_st_drift" in
        *"6 shared-view uses (base 6 at main ($_st_c1))"*) ;;
        *)
            echo "self-test: merge-base did not ignore main drift: $_st_drift" >&2
            exit 1
            ;;
    esac

    # On main (clean): HEAD (4) vs HEAD^1 (6) passes.
    st_git "$_st_repo" checkout -q main
    _st_on_main=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: on-main HEAD vs HEAD^1 failed: $_st_on_main" >&2
        exit 1
    }
    case "$_st_on_main" in
        *"4 shared-view uses, below base 6 (HEAD^1 ($_st_c1))"*) ;;
        *)
            echo "self-test: expected HEAD^1 comparison on main, got: $_st_on_main" >&2
            exit 1
            ;;
    esac

    # On main with dirty non-.tl file: still compares HEAD (4) vs HEAD^1 (6).
    printf 'unrelated\n' > "$_st_repo/NOTES.txt"
    _st_non_tl=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: on-main with dirty non-.tl file failed: $_st_non_tl" >&2
        exit 1
    }
    case "$_st_non_tl" in
        *"4 shared-view uses, below base 6 (HEAD^1 ($_st_c1))"*) ;;
        *)
            echo "self-test: dirty non-.tl file altered base resolution: $_st_non_tl" >&2
            exit 1
            ;;
    esac
    rm -f "$_st_repo/NOTES.txt"

    # On main with uncommitted tracked .tl increase (5 vs HEAD's 4): must compare vs HEAD and fail.
    cat > "$_st_repo/src/a.tl" <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define (thing-box-shared-view [b : (Box i64)]) : i64 (deref b))
(define (f [x : i64]) : i64 (local-shared-view x))
EOF
    if st_run "$_st_repo" > "$_st_work/dirty-over.out" 2>&1; then
        echo "self-test: dirty working tree increase on main was not rejected" >&2
        exit 1
    fi
    grep -q "5 shared-view uses exceed base 4 (HEAD ($_st_c2))" "$_st_work/dirty-over.out" || {
        echo "self-test: dirty working tree failure lacks HEAD diagnostic:" >&2
        cat "$_st_work/dirty-over.out" >&2
        exit 1
    }

    # On main with uncommitted tracked .tl decrease (3 vs HEAD's 4): passes against HEAD.
    st_git "$_st_repo" checkout -- src/a.tl
    cat > "$_st_repo/stdlib/c.tl" <<'EOF'
(define (k [x : i64]) : i64 x)
EOF
    _st_dirty_low=$(st_run "$_st_repo" 2>&1) || {
        echo "self-test: dirty working tree decrease on main failed: $_st_dirty_low" >&2
        exit 1
    }
    case "$_st_dirty_low" in
        *"3 shared-view uses, below base 4 (HEAD ($_st_c2))"*) ;;
        *)
            echo "self-test: dirty decrease did not compare against HEAD: $_st_dirty_low" >&2
            exit 1
            ;;
    esac
    st_git "$_st_repo" checkout -- stdlib/c.tl

    # On main with untracked .tl file adding a view (5 vs HEAD's 4): fails against HEAD.
    printf '(define (u [x : i64]) : i64 (extra-shared-view x))\n' > "$_st_repo/src/untracked.tl"
    if st_run "$_st_repo" > "$_st_work/untracked-over.out" 2>&1; then
        echo "self-test: untracked .tl increase on main was not rejected" >&2
        exit 1
    fi
    grep -q "5 shared-view uses exceed base 4 (HEAD ($_st_c2))" "$_st_work/untracked-over.out" || {
        echo "self-test: untracked .tl failure lacks HEAD diagnostic:" >&2
        cat "$_st_work/untracked-over.out" >&2
        exit 1
    }
    rm -f "$_st_repo/src/untracked.tl"

    # On main (clean) after committing a regression (5 vs HEAD^1's 4): fails against HEAD^1.
    cat > "$_st_repo/src/a.tl" <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define (thing-box-shared-view [b : (Box i64)]) : i64 (deref b))
(define (f [x : i64]) : i64 (local-shared-view x))
EOF
    st_git "$_st_repo" add src/a.tl
    st_git "$_st_repo" commit -qm "main: regression to 5 uses"
    if st_run "$_st_repo" > "$_st_work/main-reg.out" 2>&1; then
        echo "self-test: committed regression on main was not rejected" >&2
        exit 1
    fi
    grep -q "5 shared-view uses exceed base 4 (HEAD^1 ($_st_c2))" "$_st_work/main-reg.out" || {
        echo "self-test: committed regression on main lacks HEAD^1 diagnostic:" >&2
        cat "$_st_work/main-reg.out" >&2
        exit 1
    }
    # Explicit --base HEAD on that regression commit compares directly against HEAD (5 vs 5),
    # not HEAD^1 (4); and --base <descendant> compares directly against that descendant when
    # merge-base equals HEAD.
    _st_reg_head=$(st_git "$_st_repo" rev-parse HEAD)
    _st_reg_direct=$(st_run "$_st_repo" --base HEAD 2>&1) || {
        echo "self-test: --base HEAD on regression commit failed: $_st_reg_direct" >&2
        exit 1
    }
    case "$_st_reg_direct" in
        *"5 shared-view uses (base 5 at HEAD ($_st_reg_head))"*) ;;
        *)
            echo "self-test: --base HEAD rewrote to HEAD^1: $_st_reg_direct" >&2
            exit 1
            ;;
    esac
    st_git "$_st_repo" checkout -q --detach "$_st_c1"
    if st_run "$_st_repo" --base "$_st_c2" > "$_st_work/direct-desc.out" 2>&1; then
        echo "self-test: --base <descendant> did not compare directly against descendant" >&2
        exit 1
    fi
    grep -q "6 shared-view uses exceed base 4 ($_st_c2 ($_st_c2))" "$_st_work/direct-desc.out" || {
        echo "self-test: --base <descendant> diagnostic missing:" >&2
        cat "$_st_work/direct-desc.out" >&2
        exit 1
    }
    st_git "$_st_repo" checkout -q main

    # 3. Ref precedence (origin/$GITHUB_BASE_REF, $GITHUB_BASE_REF, fail-closed missing
    # GITHUB_BASE_REF; origin/main) and GitHub PR merge checkouts.
    # History on main is now _st_c1 (6) -> _st_c2 (4) -> HEAD (5).
    st_git "$_st_repo" update-ref refs/remotes/origin/release "$_st_c1"
    st_git "$_st_repo" update-ref refs/remotes/origin/main "$_st_c2"
    st_git "$_st_repo" branch -f local-base "$_st_c1"
    _st_gh_base=$(env -u GITHUB_EVENT_NAME -u GITHUB_SHA -u SHARED_VIEW_COUNT_BASE \
        GITHUB_BASE_REF=release TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" \
        sh "$SCRIPT" 2>&1) || {
        echo "self-test: origin/\$GITHUB_BASE_REF precedence failed: $_st_gh_base" >&2
        exit 1
    }
    case "$_st_gh_base" in
        *"5 shared-view uses, below base 6 (origin/release ($_st_c1))"*) ;;
        *)
            echo "self-test: expected origin/release base, got: $_st_gh_base" >&2
            exit 1
            ;;
    esac
    # Local $GITHUB_BASE_REF resolves when origin/$GITHUB_BASE_REF does not exist.
    _st_gh_local=$(env -u GITHUB_EVENT_NAME -u GITHUB_SHA -u SHARED_VIEW_COUNT_BASE \
        GITHUB_BASE_REF=local-base TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" \
        sh "$SCRIPT" 2>&1) || {
        echo "self-test: local \$GITHUB_BASE_REF fallback failed: $_st_gh_local" >&2
        exit 1
    }
    case "$_st_gh_local" in
        *"5 shared-view uses, below base 6 (local-base ($_st_c1))"*) ;;
        *)
            echo "self-test: expected local-base ref, got: $_st_gh_local" >&2
            exit 1
            ;;
    esac
    # Missing GITHUB_BASE_REF must fail closed even when origin/main (and main) exist
    # and would otherwise pass.
    st_git "$_st_repo" update-ref refs/remotes/origin/main "$_st_c1"
    if env -u GITHUB_EVENT_NAME -u GITHUB_SHA -u SHARED_VIEW_COUNT_BASE \
        GITHUB_BASE_REF=missing-target TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_repo" \
        sh "$SCRIPT" > "$_st_work/missing-gh-base.out" 2>&1; then
        echo "self-test: missing GITHUB_BASE_REF silently fell through to origin/main" >&2
        exit 1
    fi
    grep -q 'cannot resolve git base ref for GITHUB_BASE_REF=missing-target' "$_st_work/missing-gh-base.out" || {
        echo "self-test: missing GITHUB_BASE_REF failure lacks diagnostic:" >&2
        cat "$_st_work/missing-gh-base.out" >&2
        exit 1
    }
    st_git "$_st_repo" update-ref refs/remotes/origin/main "$_st_c2"
    if st_run "$_st_repo" > "$_st_work/origin-main.out" 2>&1; then
        echo "self-test: origin/main precedence (5 > 4) was not enforced" >&2
        exit 1
    fi
    grep -q "5 shared-view uses exceed base 4 (origin/main ($_st_c2))" "$_st_work/origin-main.out" || {
        echo "self-test: origin/main diagnostic missing:" >&2
        cat "$_st_work/origin-main.out" >&2
        exit 1
    }

    # Normal 2-parent `git merge origin/main` branch with +1 view increase:
    # GITHUB_EVENT_NAME=pull_request with unset or mismatched GITHUB_SHA must NOT
    # trust HEAD^1 (the feature branch tip at 3 uses); it must compare against
    # origin/main (2 uses) and fail closed.
    _st_mbranch=$_st_work/pr-user-merge
    st_init_repo "$_st_mbranch" main
    mkdir -p "$_st_mbranch/src" "$_st_mbranch/stdlib"
    printf '(define (a [x : i64]) : i64 (v-shared-view x))\n' > "$_st_mbranch/src/a.tl"
    printf '(define (b [x : i64]) : i64 (v-shared-view x))\n' > "$_st_mbranch/stdlib/b.tl"
    st_git "$_st_mbranch" add src stdlib
    st_git "$_st_mbranch" commit -qm "main: 2 uses"
    st_git "$_st_mbranch" checkout -qb feat
    printf '(define (b [x : i64]) : i64 (+ (v-shared-view x) (v-shared-view x)))\n' > "$_st_mbranch/stdlib/b.tl"
    st_git "$_st_mbranch" add stdlib/b.tl
    st_git "$_st_mbranch" commit -qm "feat: regression to 3 uses"
    st_git "$_st_mbranch" checkout -q main
    printf 'main advance\n' > "$_st_mbranch/README.md"
    st_git "$_st_mbranch" add README.md
    st_git "$_st_mbranch" commit -qm "main: unrelated commit (still 2 uses)"
    _st_m_origin=$(st_git "$_st_mbranch" rev-parse HEAD)
    st_git "$_st_mbranch" update-ref refs/remotes/origin/main "$_st_m_origin"
    st_git "$_st_mbranch" checkout -q feat
    st_git "$_st_mbranch" merge -q --no-ff origin/main -m "Merge origin/main into feat"
    if env -u GITHUB_SHA -u SHARED_VIEW_COUNT_BASE \
        GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_mbranch" \
        sh "$SCRIPT" > "$_st_work/pr-unset-sha.out" 2>&1; then
        echo "self-test: pull_request with unset GITHUB_SHA trusted HEAD^1 and missed regression" >&2
        exit 1
    fi
    grep -q "3 shared-view uses exceed base 2 (origin/main ($_st_m_origin))" "$_st_work/pr-unset-sha.out" || {
        echo "self-test: pull_request with unset GITHUB_SHA lacks origin/main diagnostic:" >&2
        cat "$_st_work/pr-unset-sha.out" >&2
        exit 1
    }
    if env -u SHARED_VIEW_COUNT_BASE \
        GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main GITHUB_SHA="$_st_m_origin" \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_mbranch" \
        sh "$SCRIPT" > "$_st_work/pr-mismatch-sha.out" 2>&1; then
        echo "self-test: pull_request with mismatched GITHUB_SHA trusted HEAD^1 and missed regression" >&2
        exit 1
    fi
    grep -q "3 shared-view uses exceed base 2 (origin/main ($_st_m_origin))" "$_st_work/pr-mismatch-sha.out" || {
        echo "self-test: pull_request with mismatched GITHUB_SHA lacks origin/main diagnostic:" >&2
        cat "$_st_work/pr-mismatch-sha.out" >&2
        exit 1
    }

    # Simulate .github/workflows/ci.yml depth-2 checkout of GitHub's synthetic 2-parent PR merge
    # commit where neither origin/main nor main exists.
    _st_pr=$_st_work/pr-merge
    st_init_repo "$_st_pr" main
    mkdir -p "$_st_pr/src" "$_st_pr/stdlib"
    printf '(define (a [x : i64]) : i64 (v-shared-view x))\n' > "$_st_pr/src/a.tl"
    printf '(define (b [x : i64]) : i64 (v-shared-view x))\n' > "$_st_pr/stdlib/b.tl"
    st_git "$_st_pr" add src stdlib
    st_git "$_st_pr" commit -qm "base: 2 uses"
    _st_pr_base=$(st_git "$_st_pr" rev-parse HEAD)
    st_git "$_st_pr" checkout -qb pr-branch
    printf '(define (b [x : i64]) : i64 x)\n' > "$_st_pr/stdlib/b.tl"
    st_git "$_st_pr" add stdlib/b.tl
    st_git "$_st_pr" commit -qm "pr: lower to 1 use"
    st_git "$_st_pr" checkout -q main
    st_git "$_st_pr" merge -q --no-ff pr-branch -m "Merge PR"
    _st_pr_merge=$(st_git "$_st_pr" rev-parse HEAD)
    st_git "$_st_pr" checkout -q --detach "$_st_pr_merge"
    st_git "$_st_pr" branch -D -q main pr-branch

    _st_pr_ok=$(env -u SHARED_VIEW_COUNT_BASE \
        GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main GITHUB_SHA="$_st_pr_merge" \
        TYPELISP_CI_TIMING=0 SHARED_VIEW_COUNT_ROOT="$_st_pr" \
        sh "$SCRIPT" 2>&1) || {
        echo "self-test: GitHub PR synthetic merge checkout failed: $_st_pr_ok" >&2
        exit 1
    }
    case "$_st_pr_ok" in
        *"1 shared-view uses, below base 2 (HEAD^1 ($_st_pr_base))"*) ;;
        *)
            echo "self-test: unexpected GitHub PR merge output: $_st_pr_ok" >&2
            exit 1
            ;;
    esac

    # Without GITHUB_EVENT_NAME=pull_request and without origin/main or main, fail closed.
    if st_run "$_st_pr" > "$_st_work/missing-base.out" 2>&1; then
        echo "self-test: repo with no base ref was not rejected" >&2
        exit 1
    fi

    # Non-git directory nested inside the repository must fail closed.
    _st_nogit=$_st_work/no-git
    mkdir -p "$_st_nogit/src" "$_st_nogit/stdlib"
    printf '(define (a [x : i64]) : i64 x)\n' > "$_st_nogit/src/a.tl"
    if st_run "$_st_nogit" > "$_st_work/no-git.out" 2>&1; then
        echo "self-test: non-git directory was not rejected" >&2
        exit 1
    fi

    # 4. Keep raw grep-compatible counting (including comments/strings) separate
    # from the weighted report, and retain boundaries and qualified wrappers.
    _st_edge=$_st_work/edges
    st_init_repo "$_st_edge" main
    mkdir -p "$_st_edge/src" "$_st_edge/stdlib"
    printf '%s' '(define (acc [x : i64]) : i64 (x-shared-view x))' > "$_st_edge/src/a file.tl"
    printf '%s\n' '; (comment-shared-view 0)' \
        '(define (user) : i64 (+ (acc 0) (pkg.acc 1)))' > "$_st_edge/src/b.tl"
    printf '%s' '(define (strings) : String "plain")' > "$_st_edge/stdlib/c.tl"
    st_git "$_st_edge" add src stdlib
    st_git "$_st_edge" commit -qm "edge base: 2 uses"
    _st_edge_base2=$(st_git "$_st_edge" rev-parse HEAD)

    printf '%s' '(define (strings) : String "(quoted-shared-view 0)")' > "$_st_edge/stdlib/c.tl"
    st_git "$_st_edge" add stdlib/c.tl
    st_git "$_st_edge" commit -qm "edge: 3 raw uses (with quoted)"
    _st_edge_base3=$(st_git "$_st_edge" rev-parse HEAD)

    st_git "$_st_edge" checkout -qb edge-branch
    printf 'edge\n' > "$_st_edge/README.md"
    st_git "$_st_edge" add README.md
    st_git "$_st_edge" commit -qm "edge branch: still 3 uses"
    _st_edge_result=$(st_run "$_st_edge" 2>&1) || {
        echo "self-test: edge tree failed: $_st_edge_result; evidence in $_st_edge" >&2
        exit 1
    }
    case "$_st_edge_result" in
        *"thin wrappers transparent: 2 (report only)"*"3 shared-view uses (base 3 at main ($_st_edge_base3))"*) ;;
        *) echo "self-test: file-boundary/raw/weighted parity failed: $_st_edge_result" >&2; exit 1 ;;
    esac

    if st_run "$_st_edge" --base "$_st_edge_base2" > "$_st_edge/over.out" 2>&1; then
        echo "self-test: planted edge use was not rejected" >&2
        exit 1
    fi
    grep -q '3 shared-view uses exceed base 2' "$_st_edge/over.out" || {
        echo "self-test: planted edge failure lacks the count diagnostic; evidence in $_st_edge" >&2
        cat "$_st_edge/over.out" >&2
        exit 1
    }

    echo "check-shared-view-count: self-test passed"
}

mkdir -p "$ROOT/target/exp"
METRICS_WORK=$(mktemp -d "$ROOT/target/exp/shared-view-count.XXXXXX")
case "$METRICS_WORK" in "$ROOT/target/exp/shared-view-count."??????) ;; *) exit 1 ;; esac
cleanup() {
    _status=$?
    trap - EXIT
    if [ "$SELF_TEST" -eq 0 ] || [ "$_status" -eq 0 ]; then
        rm -rf -- "${METRICS_WORK:?}"
    fi
    exit "$_status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
. "$FIXTURE_METRICS_TOOLS/lib-fixture-metrics.sh"
fixture_metrics_init "$METRICS_WORK"
if [ "$SELF_TEST" -eq 1 ]; then
    fixture_metrics_run self-test run_self_test
else
    fixture_metrics_run scan run_check
fi
