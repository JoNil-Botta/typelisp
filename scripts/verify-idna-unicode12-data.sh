#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
[ "$#" -eq 0 ] || { echo "usage: scripts/verify-idna-unicode12-data.sh" >&2; exit 2; }
. "$ROOT/scripts/lib-gate.sh"
gate_compiler
gate_compiler_absolute
gate_require_compiler
WORKDIR="$ROOT/target/exp/verify-idna-unicode12-data"
mkdir -p "$WORKDIR/relocated/inputs"
EXE=
case "$(uname -s)" in MINGW* | MSYS* | CYGWIN*) EXE=.exe ;; esac
INPUTS="$ROOT/tools/idna-unicode12-data/inputs"
MODULE="$ROOT/stdlib/generated/idna_unicode12_data.tl"
for tool in generate verify reject; do
    "$COMPILER" build "tools/idna-unicode12-data/$tool.tl" \
        --stdlib-root stdlib -o "$WORKDIR/$tool$EXE"
done
GENERATOR="$WORKDIR/generate$EXE"
"$GENERATOR" "$INPUTS" "$WORKDIR/first.tl"
"$GENERATOR" "$INPUTS" "$WORKDIR/repeat.tl"
cmp "$WORKDIR/first.tl" "$WORKDIR/repeat.tl"
cp "$INPUTS/"* "$WORKDIR/relocated/inputs/"
(
    cd "$WORKDIR"
    LC_ALL=C "$GENERATOR" 'relocated\inputs' relocated.tl
)
cmp "$WORKDIR/first.tl" "$WORKDIR/relocated.tl"
if ! cmp -s "$MODULE" "$WORKDIR/first.tl"; then
    echo "stale IDNA Unicode 12 tables; regenerate with tools/idna-unicode12-data/generate.tl" >&2
    exit 1
fi
"$COMPILER" fmt --check stdlib/idna_unicode12.tl stdlib/generated/idna_unicode12_data.tl tools/idna-unicode12-data/*.tl
"$COMPILER" check stdlib/generated/idna_unicode12_data.tl --stdlib-root stdlib
"$WORKDIR/verify$EXE" "$INPUTS"

# Expected rejection is always nonzero with a filename/line diagnostic.
reject() {
    label=$1
    expected=$2
    shift 2
    if "$@" > "$WORKDIR/$label.stdout" 2> "$WORKDIR/$label.stderr"; then
        echo "IDNA negative fixture unexpectedly accepted: $label" >&2
        exit 1
    fi
    if ! grep -F "$expected" "$WORKDIR/$label.stderr" > /dev/null; then
        cat "$WORKDIR/$label.stderr" >&2
        echo "IDNA negative fixture has wrong diagnostic: $label" >&2
        exit 1
    fi
}
for fixture in integer overflow negative digit empty reversed delimiter fields property; do
    reject "$fixture" 'fixture:7:' "$WORKDIR/reject$EXE" "$fixture"
done
reject quoted 'fixture:8: unterminated' "$WORKDIR/reject$EXE" quoted
reject overlap 'fixture:8: duplicate or overlapping' "$WORKDIR/reject$EXE" overlap
reject empty-version 'fixture:1: expected Unicode 12.0.0' "$WORKDIR/reject$EXE" empty-version
reject paint-range 'fixture:7: property range outside' "$WORKDIR/reject$EXE" paint-range
reject version 'Scripts.txt:1: expected Unicode 12.0.0' "$WORKDIR/reject$EXE" version
for fixture in unsorted duplicate; do
    reject "$fixture" 'DerivedJoiningType.txt:3: unsorted' "$WORKDIR/reject$EXE" "$fixture"
done
reject cross-group-overlap 'DerivedJoiningType.txt:3: duplicate or overlapping' "$WORKDIR/reject$EXE" cross-group-overlap
reject context 'idna-tables-context.csv:2: unreviewed' "$WORKDIR/reject$EXE" context
reject idna-gap 'idna-tables-properties.csv:2: unsorted' "$WORKDIR/reject$EXE" idna-gap
reject idna-count 'idna-tables-properties.csv:3: audited' "$WORKDIR/reject$EXE" idna-count
reject unicode-order 'UnicodeData.txt:2: duplicate or unsorted' "$WORKDIR/reject$EXE" unicode-order
reject unicode-pair 'UnicodeData.txt:2: unclosed' "$WORKDIR/reject$EXE" unicode-pair
reject unicode-surrogate 'UnicodeData.txt:1: surrogate' "$WORKDIR/reject$EXE" unicode-surrogate
reject pool-overflow 'UnicodeData.txt:1: canonical decomposition pool overflow' "$WORKDIR/reject$EXE" pool-overflow

# Corrupt each source in isolation. A failed generator must never create output.
for source in "$INPUTS/"*; do
    name=$(basename "$source")
    copied="$WORKDIR/relocated/inputs/$name"
    mv "$copied" "$WORKDIR/relocated/$name.saved"
    reject "missing-$name" "$name:0: missing or unreadable" "$GENERATOR" "$WORKDIR/relocated/inputs" "$WORKDIR/rejected.tl"
    cp "$source" "$copied"
    printf x >> "$copied"
    reject "size-$name" "$name:0: pinned byte size mismatch" "$GENERATOR" "$WORKDIR/relocated/inputs" "$WORKDIR/rejected.tl"
    cp "$source" "$copied"
    printf X | dd of="$copied" bs=1 count=1 conv=notrunc 2> /dev/null
    reject "hash-$name" "$name:0: pinned SHA-256 mismatch" "$GENERATOR" "$WORKDIR/relocated/inputs" "$WORKDIR/rejected.tl"
    mv "$WORKDIR/relocated/$name.saved" "$copied"
done
[ ! -e "$WORKDIR/rejected.tl" ] || { echo 'failed generation wrote output' >&2; exit 1; }
echo 'IDNA Unicode 12: deterministic offline regeneration, scalar/NFC conformance and 48 rejection fixtures passed'
