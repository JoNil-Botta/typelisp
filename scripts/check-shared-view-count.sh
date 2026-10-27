#!/usr/bin/env sh
set -eu

# Shared-view ratchet.
#
# The `*-shared-view` macros (compiler_owned_view.tl and the per-module
# wrappers built on them) read a place through an unchecked shallow alias.
# They are migration scaffolding: new code borrows with `&`/`&mut`, element
# references and patterns instead. This gate counts the call uses of every
# identifier containing `-shared-view` in src/ and stdlib/, module-qualified
# forms included and definitions excluded. It fails when the count exceeds the
# checked-in baseline, so no change can add views. When the count drops, the
# change that removed them lowers the baseline to the new count.
#
# It also reports, without gating, the views weighted by the call sites of the
# function or macro that holds them, with thin wrappers (an accessor around one
# view) transparent: a wrapper's call sites count as views at their callers.
# A copy moved from inside an accessor to its call sites then weighs the same,
# so the report compares a migration's two sides on one rule.
#
# usage: scripts/check-shared-view-count.sh [--self-test]

usage() {
    cat >&2 <<'EOF'
usage: scripts/check-shared-view-count.sh [--self-test]

Count `*-shared-view*` call uses in src/ and stdlib/ against
scripts/shared-view-baseline.tsv; --self-test runs the counter's own tests.
EOF
}

SELF_TEST=0
case "${1:-}" in
    "") ;;
    --self-test) SELF_TEST=1 ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        usage
        exit 2
        ;;
esac
if [ "$#" -gt 1 ]; then
    usage
    exit 2
fi

SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)/$(basename -- "$0")
FIXTURE_METRICS_TOOLS=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ROOT=${SHARED_VIEW_COUNT_ROOT:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}
BASELINE=${SHARED_VIEW_COUNT_BASELINE:-$ROOT/scripts/shared-view-baseline.tsv}

# An identifier as TypeLisp spells a call head, optionally module-qualified.
NAME_RE='[A-Za-z0-9_./?!*<>=+-]*-shared-view[A-Za-z0-9_?!*<>=+-]*'

# A sorted manifest keeps paths out of argv limits, with one scanner process
# per pass. getline/close preserves individual lines even without a final LF.
source_files() {
    find "$ROOT/src" "$ROOT/stdlib" -type f -name '*.tl' -print |
        LC_ALL=C sort
}

count_uses() {
    source_files | awk -v name="$NAME_RE" '
        function occurrences(text, pattern,    n) {
            n = 0
            while (match(text, pattern)) {
                n++
                text = substr(text, RSTART + RLENGTH)
            }
            return n
        }
        {
            file = $0
            while ((getline text < file) > 0) {
                heads += occurrences(text, "\\(" name)
                definitions += occurrences(text, "\\((define|defmacro) \\(" name)
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
    _wrappers=$METRICS_WORK/wrappers
    # Pass 1: the transparent wrappers.
    source_files |
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
    source_files |
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

read_baseline() {
    [ -f "$BASELINE" ] || {
        echo "check-shared-view-count: missing baseline $BASELINE" >&2
        exit 1
    }
    _value=$(awk -F '\t' '$1 == "max_uses" { print $2 }' "$BASELINE")
    case "$_value" in
        "" | *[!0-9]*)
            echo "check-shared-view-count: $BASELINE has no numeric max_uses row" >&2
            exit 1
            ;;
    esac
    echo "$_value"
}

run_check() {
    _baseline=$(read_baseline)
    _uses=$(count_uses)
    echo "check-shared-view-count: weighted by call sites of the enclosing function or macro, thin wrappers transparent: $(count_weighted) (report only)"
    if [ "$_uses" -gt "$_baseline" ]; then
        echo "check-shared-view-count: $_uses shared-view uses exceed the baseline of $_baseline." >&2
        echo "check-shared-view-count: borrow with (& x), (&mut x), (& (array-ref items i)) or a pattern instead of adding a *-shared-view call." >&2
        exit 1
    fi
    if [ "$_uses" -lt "$_baseline" ]; then
        echo "check-shared-view-count: $_uses shared-view uses, below the baseline of $_baseline."
        echo "check-shared-view-count: lower max_uses in scripts/shared-view-baseline.tsv to $_uses in this change."
        return 0
    fi
    echo "check-shared-view-count: $_uses shared-view uses (baseline $_baseline)"
}

run_self_test() {
    _work=$METRICS_WORK/tree
    mkdir -p "$_work/src/sub" "$_work/stdlib" "$_work/scripts"
    cat > "$_work/src/a.tl" <<'EOF'
(defmacro (local-shared-view [x : Expr]) : Expr x)
(define (thing-box-shared-view [b : (Box i64)]) : i64 (deref b))
(define (f [x : i64]) : i64
  (+ (local-shared-view x) (owned_view.compiler-owned-shared-view x)))
EOF
    cat > "$_work/src/sub/b.tl" <<'EOF'
(define (g [b : (Box i64)]) : i64
  (thing-box-shared-view b))
(define (h) : i64 (ast.ast-expr-list-box-shared-view? 1))
(define (m) : i64 (+ (f 1) (f 2)))
(define (acc [x : i64]) : i64 (owned_view.compiler-owned-shared-view x))
(define (user) : i64 (acc 1))
(define (top) : i64 (+ (user) (user)))
EOF
    cat > "$_work/stdlib/c.tl" <<'EOF'
;; mentions compiler-owned-shared-view without calling it
(define (k [x : i64]) : i64 (compiler-owned-place-shared-view x))
EOF
    printf 'max_uses\t6\n' > "$_work/scripts/shared-view-baseline.tsv"
    _counted=$(SHARED_VIEW_COUNT_ROOT=$_work sh "$SCRIPT" 2>&1) || {
        echo "self-test: an at-baseline tree failed: $_counted" >&2
        exit 1
    }
    case "$_counted" in
        *"6 shared-view uses (baseline 6)"*) ;;
        *)
            echo "self-test: expected 6 uses, got: $_counted" >&2
            exit 1
            ;;
    esac
    # f holds 2 views and has 2 callers; g, h and k hold 1 each and have none.
    # acc is a thin wrapper, so its call site in user counts as a view there,
    # and user has 2 callers: 4 + 1 + 1 + 1 + 2.
    case "$_counted" in
        *"thin wrappers transparent: 9 (report only)"*) ;;
        *)
            echo "self-test: expected a weighted count of 9, got: $_counted" >&2
            exit 1
            ;;
    esac
    printf 'max_uses\t5\n' > "$_work/scripts/shared-view-baseline.tsv"
    if SHARED_VIEW_COUNT_ROOT=$_work sh "$SCRIPT" > "$_work/over.out" 2>&1; then
        echo "self-test: a count above the baseline was not rejected" >&2
        exit 1
    fi
    printf 'max_uses\t9\n' > "$_work/scripts/shared-view-baseline.tsv"
    _lower=$(SHARED_VIEW_COUNT_ROOT=$_work sh "$SCRIPT" 2>&1) || {
        echo "self-test: a count below the baseline failed: $_lower" >&2
        exit 1
    }
    case "$_lower" in
        *"lower max_uses"*"to 6"*) ;;
        *)
            echo "self-test: a lower count printed no reminder: $_lower" >&2
            exit 1
            ;;
    esac
    printf 'max_uses\tmany\n' > "$_work/scripts/shared-view-baseline.tsv"
    if SHARED_VIEW_COUNT_ROOT=$_work sh "$SCRIPT" > "$_work/bad.out" 2>&1; then
        echo "self-test: a malformed baseline was not rejected" >&2
        exit 1
    fi
    # Keep raw grep-compatible counting (including comments/strings) separate
    # from the weighted report, and retain boundaries and qualified wrappers.
    _edge=$_work/edges
    mkdir -p "$_edge/src" "$_edge/stdlib" "$_edge/scripts"
    printf '%s' '(define (acc [x : i64]) : i64 (x-shared-view x))' > "$_edge/src/a file.tl"
    printf '%s\n' '; (comment-shared-view 0)' \
        '(define (user) : i64 (+ (acc 0) (pkg.acc 1)))' > "$_edge/src/b.tl"
    printf '%s' '(define (strings) : String "(quoted-shared-view 0)")' > "$_edge/stdlib/c.tl"
    printf 'max_uses\t3\n' > "$_edge/scripts/shared-view-baseline.tsv"
    _edge_result=$(SHARED_VIEW_COUNT_ROOT=$_edge sh "$SCRIPT" 2>&1) || exit 1
    case "$_edge_result" in
        *"thin wrappers transparent: 2 (report only)"*"3 shared-view uses (baseline 3)"*) ;;
        *) echo "self-test: file-boundary/raw/weighted parity failed: $_edge_result" >&2; exit 1 ;;
    esac
    printf 'max_uses\t2\n' > "$_edge/scripts/shared-view-baseline.tsv"
    if SHARED_VIEW_COUNT_ROOT=$_edge sh "$SCRIPT" > "$_edge/over.out" 2>&1; then
        echo "self-test: planted edge use was not rejected" >&2
        exit 1
    fi
    grep -q '3 shared-view uses exceed the baseline of 2' "$_edge/over.out" || exit 1
    echo "check-shared-view-count: self-test passed"
}

mkdir -p "$ROOT/target/exp"
METRICS_WORK=$(mktemp -d "$ROOT/target/exp/shared-view-count.XXXXXX")
case "$METRICS_WORK" in "$ROOT/target/exp/shared-view-count."??????) ;; *) exit 1 ;; esac
trap 'rm -rf -- "${METRICS_WORK:?}"' EXIT
. "$FIXTURE_METRICS_TOOLS/lib-fixture-metrics.sh"
fixture_metrics_init "$METRICS_WORK"
if [ "$SELF_TEST" -eq 1 ]; then
    fixture_metrics_run self-test run_self_test
else
    fixture_metrics_run scan run_check
fi
