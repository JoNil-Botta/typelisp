#!/usr/bin/env sh
set -eu

# check-tlci-op-numbers.sh - fail closed on duplicate tlci host callback op
# numbers.
#
# The host callback ops are additive ABI constants in a single source-bound
# binary: the producer emits an op number and `compiler-comptime-host-invoke-step`
# dispatches on it through a `cond`. Nothing in the type system or the existing
# `tlci-test-host-callback-op-layout-ok?` (which pins values only through 198)
# rejects two constants sharing a number. Two branches adding ops in different
# regions of the file therefore merge without a textual conflict and produce
# duplicate `cond` arms, where the first wins and the second is silently dead.
#
# This gate reads the declarations out of the source, so it cannot drift from
# the constants it checks.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SOURCE=src/tlci_core.tl
SELF_TEST=0
if [ "${1:-}" = "--self-test" ]; then
    SELF_TEST=1
elif [ "$#" -ne 0 ]; then
    echo "usage: scripts/check-tlci-op-numbers.sh [--self-test]" >&2
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
    COUNT=$(extract_ops "$SOURCE" | wc -l | tr -d ' ')
    if [ "$COUNT" -lt 100 ]; then
        echo "self-test: only $COUNT op declarations found in $SOURCE" >&2
        echo "self-test: the extractor stopped matching the source shape" >&2
        exit 1
    fi
    echo "tlci op number gate self-tests passed ($COUNT declarations parsed)"
fi

check_source "$SOURCE"
echo "tlci host callback op numbers are unique ($(extract_ops "$SOURCE" | wc -l | tr -d ' ') declarations)"
