#!/usr/bin/env sh
set -eu

# check-compiler-state-schema.sh - packed compiler state stays behind its
# schema (#7021).
#
# The lowerer's state cells are declared once by
# `compiler-state-directory-schema` (src/compiler_state_schema.tl), whose
# generated typed accessors are the only code that addresses them. The generic
# macros they replaced took a slot and a pointee type as independent caller
# arguments, so any call could read a cell through the wrong pointer type.
# This check fails if one of those retired spellings appears again in a
# TypeLisp source.
#
# Usage: scripts/check-compiler-state-schema.sh [--self-test]

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# The retired generic lower-state accessors, as whole symbols: a generated
# accessor such as `compiler-lower-state-cell-count` would not match.
RETIRED='(^|[^a-z0-9?!*_-])compiler-lower-state-(read|write!|cell)([^a-z0-9?!*_-]|$)'

# Print "file:line:text" for every retired spelling under the given roots.
find_retired() {
    find "$@" -name '*.tl' -type f -print | LC_ALL=C sort | awk -v retired="$RETIRED" '
        {
            file = $0
            line = 0
            while ((getline text < file) > 0) {
                line++
                if (text ~ retired) print file ":" line ":" text
            }
            close(file)
        }'
}

check_roots() {
    found=$(find_retired "$@")
    if [ -n "$found" ]; then
        echo "compiler-state-schema: retired generic state accessors found; use the schema's typed accessors (src/compiler_state_schema.tl):" >&2
        printf '%s\n' "$found" >&2
        return 1
    fi
    return 0
}

mkdir -p "$ROOT/target/exp"
WORKDIR=$(mktemp -d "$ROOT/target/exp/compiler-state-schema.XXXXXX")
case "$WORKDIR" in "$ROOT/target/exp/compiler-state-schema."??????) ;; *) exit 1 ;; esac
trap 'if [ "$?" -eq 0 ]; then rm -rf -- "${WORKDIR:?}"; fi' EXIT
FIXTURE_METRICS_TOOLS=$ROOT/scripts
. "$ROOT/scripts/lib-fixture-metrics.sh"
fixture_metrics_init "$WORKDIR"

case "${1:-}" in
    "")
        fixture_metrics_run scan check_roots src stdlib tests
        echo "[compiler-state-schema] no retired state accessor spellings"
        ;;
    --self-test)
        clean="$WORKDIR/clean"
        dirty="$WORKDIR/dirty"
        mkdir -p "$clean" "$dirty"
        printf '%s\n' '(compiler-lower-state-active-symbols-ready state)' \
            '(compiler-lower-state-cell-count state)' > "$clean/ok.tl"
        printf '%s\n' '(compiler-lower-state-read state bool active-symbols-ready)' > "$dirty/bad.tl"
        check_roots "$clean" 2> "$WORKDIR/clean.err" || {
            echo "compiler-state-schema self-test: a typed accessor was flagged" >&2
            exit 1
        }
        if check_roots "$dirty" 2> "$WORKDIR/dirty.err"; then
            echo "compiler-state-schema self-test: a retired spelling was not flagged" >&2
            exit 1
        fi
        grep -q 'bad.tl:1:' "$WORKDIR/dirty.err" || {
            echo "compiler-state-schema self-test: the report does not name the file and line" >&2
            exit 1
        }
        # Multiple files, roots and lines retain sorted diagnostics. Exercise
        # every retired head, token boundaries, and a file without final LF.
        mkdir -p "$clean/nested" "$dirty/nested"
        printf '%s\n' '(xcompiler-lower-state-read state)' \
            '(compiler-lower-state-write!x state)' '(compiler-lower-state-cell-count state)' > "$clean/nested/boundaries.tl"
        check_roots "$clean" || exit 1
        printf '%s\n' '(compiler-lower-state-write! state value)' > "$dirty/nested/a file.tl"
        printf '\n%s' '(compiler-lower-state-cell state)' > "$dirty/z.tl"
        printf '%s\n' "$dirty/bad.tl:1:(compiler-lower-state-read state bool active-symbols-ready)" \
            "$dirty/nested/a file.tl:1:(compiler-lower-state-write! state value)" \
            "$dirty/z.tl:2:(compiler-lower-state-cell state)" > "$WORKDIR/expected"
        find_retired "$dirty" "$clean" > "$WORKDIR/actual"
        if [ "$(cat "$WORKDIR/expected")" != "$(cat "$WORKDIR/actual")" ]; then
            echo "compiler-state-schema self-test: sorted file/line report differs; evidence in $WORKDIR" >&2
            echo "expected:" >&2
            cat "$WORKDIR/expected" >&2
            echo "actual:" >&2
            cat "$WORKDIR/actual" >&2
            exit 1
        fi
        for spelling in read 'write!' cell; do
            printf '(compiler-lower-state-%s state)\n' "$spelling" > "$WORKDIR/planted.tl"
            if check_roots "$WORKDIR/planted.tl" 2> "$WORKDIR/planted.err"; then
                echo "compiler-state-schema self-test: $spelling was not rejected" >&2
                exit 1
            fi
        done
        echo "[compiler-state-schema] self-test passed"
        ;;
    *)
        echo "usage: scripts/check-compiler-state-schema.sh [--self-test]" >&2
        exit 2
        ;;
esac
