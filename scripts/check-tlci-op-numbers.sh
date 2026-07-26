#!/usr/bin/env sh
set -eu

# check-tlci-op-numbers.sh - fail closed on duplicate tlci host callback op
# numbers, producer-side raw ids, and drift between the implementation and
# SPEC catalog.
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

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

SOURCE=src/tlci_core.tl
SPEC=SPEC.md
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

# Producer entries are generated source, so a stale numeric id still compiles
# and is only discovered when the entry executes against a newer host catalog.
# Replacing every legacy id with its long catalog name regressed the Linux
# self-compile instruction count by 0.588%, so the existing append-only ABI
# literals remain frozen instead. New or changed raw ids alter this source-order
# signature and must either become named constants or receive explicit review.
producer_raw_ops() {
    awk -v max_op="$2" '
        {
            rest = $0
            while (match(rest, /[0-9][0-9]*/)) {
                value = substr(rest, RSTART, RLENGTH)
                if ((value + 0) >= 100 && (value + 0) <= max_op) {
                    print value
                }
                rest = substr(rest, RSTART + RLENGTH)
            }
        }
    ' "$1"
}

check_producer_raw_ops() {
    observed=$(producer_raw_ops "$1" "$2" | cksum)
    if [ "$observed" != "$3" ]; then
        count=$(producer_raw_ops "$1" "$2" | wc -l | tr -d ' ')
        echo "tlci producer raw callback signature changed in $1:" >&2
        echo "  expected: $3" >&2
        echo "  observed: $observed ($count callback-range integers)" >&2
        echo "use tlci-host-callback-op-* constants for new sites; update the signature only after explicit ABI review" >&2
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
    RAW_PRODUCER="$WORKDIR/producer-raw-op.tl"
    cat > "$RAW_PRODUCER" <<'FIXTURE'
(comptime-host-invoke host session 252 0 0 0)
FIXTURE
    RAW_SIGNATURE=$(producer_raw_ops "$RAW_PRODUCER" 261 | cksum)
    if ! check_producer_raw_ops "$RAW_PRODUCER" 261 "$RAW_SIGNATURE"; then
        echo "self-test: unchanged producer raw-op signature was rejected" >&2
        exit 1
    fi
    MUTATED_PRODUCER="$WORKDIR/producer-mutated-op.tl"
    cat > "$MUTATED_PRODUCER" <<'FIXTURE'
(comptime-host-invoke host session 253 0 0 0)
FIXTURE
    if check_producer_raw_ops "$MUTATED_PRODUCER" 261 "$RAW_SIGNATURE" 2>/dev/null; then
        echo "self-test: changed producer raw-op signature was not rejected" >&2
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
check_spec_catalog "$SOURCE" "$SPEC"
MAX_OP=$(extract_ops "$SOURCE" | sort -n | tail -n 1 | cut -f1)
EXPECTED_PRODUCER_RAW_OP_SIGNATURE="936215337 608"
check_producer_raw_ops \
    src/compiler_tlci_native_producer.tl \
    "$MAX_OP" \
    "$EXPECTED_PRODUCER_RAW_OP_SIGNATURE"
echo "tlci host callback catalog matches SPEC ($(extract_ops "$SOURCE" | wc -l | tr -d ' ') unique declarations)"
