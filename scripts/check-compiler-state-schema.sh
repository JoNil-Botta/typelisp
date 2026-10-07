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
    find "$@" -name '*.tl' -type f -print | LC_ALL=C sort | while IFS= read -r file; do
        grep -n -E "$RETIRED" "$file" | sed "s#^#$file:#" || true
    done
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

WORKDIR="$ROOT/target/compiler-state-schema-check"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

case "${1:-}" in
    "")
        check_roots src stdlib tests
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
        echo "[compiler-state-schema] self-test passed"
        ;;
    *)
        echo "usage: scripts/check-compiler-state-schema.sh [--self-test]" >&2
        exit 2
        ;;
esac
