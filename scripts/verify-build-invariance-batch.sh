#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$ROOT/scripts/lib-build-invariance-batch.sh"
mkdir -p "$ROOT/target/exp"
WORKDIR=$(mktemp -d "$ROOT/target/exp/build-invariance-batch.XXXXXX")
trap 'rm -rf "$WORKDIR"' EXIT HUP INT TERM
mkdir -p "$WORKDIR/left" "$WORKDIR/right"
CASES="$WORKDIR/cases"
ENTRIES="$WORKDIR/entries"
ALIASES="$WORKDIR/aliases"

record() {
    printf '%s|%s|%s|%s/%s.s|%s\n' "$1" "$2" "$2" "$3" "$1" "$4"
}
plan() {
    build_invariance_plan_chunk "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
}
reject() {
    if "$@" > "$WORKDIR/stdout" 2> "$WORKDIR/stderr"; then
        echo "expected failure: $*" >&2
        exit 1
    fi
    test -s "$WORKDIR/stderr"
}

# Every logical row survives; only same-invocation equal inputs share work.
{
    record first input.tl "$WORKDIR/left" 2
    record second other.tl "$WORKDIR/left" 2
    record alias input.tl "$WORKDIR/left" 2
} > "$CASES"
plan
test "$(wc -l < "$CASES")" -eq 3
test "$(wc -l < "$ENTRIES")" -eq 2
printf '%s|%s\n' "$WORKDIR/left/first.s" "$WORKDIR/left/alias.s" > "$WORKDIR/expected"
cmp "$ALIASES" "$WORKDIR/expected"
build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$ENTRIES" "$WORKDIR/saved-entries"
: > "$ENTRIES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$WORKDIR/saved-entries" "$ENTRIES"
cp "$ALIASES" "$WORKDIR/saved-aliases"
printf 'foreign|foreign\n' > "$ALIASES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
rm "$ALIASES"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$WORKDIR/saved-aliases" "$ALIASES"
reject build_invariance_copy_aliases "$ALIASES"
: > "$WORKDIR/left/first.s"
reject build_invariance_copy_aliases "$ALIASES"
printf 'assembly\n' > "$WORKDIR/left/first.s"
build_invariance_copy_aliases "$ALIASES"
cmp "$WORKDIR/left/first.s" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm "$WORKDIR/left/alias.s"
ln -s "$WORKDIR/nonexistent" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm "$WORKDIR/left/alias.s" "$WORKDIR/left/first.s"
ln -s "$WORKDIR/expected" "$WORKDIR/left/first.s"
reject build_invariance_copy_aliases "$ALIASES"

# Empty, oversized, duplicate-name, malformed and foreign-producer plans fail.
: > "$CASES"
reject plan
i=0
while [ "$i" -lt 64 ]; do
    record "case$i" same.tl "$WORKDIR/left" 2 >> "$CASES"
    i=$((i + 1))
done
plan
test "$(wc -l < "$ENTRIES")" -eq 1
test "$(wc -l < "$ALIASES")" -eq 63
record overflow same.tl "$WORKDIR/left" 2 >> "$CASES"
reject plan
record single same.tl "$WORKDIR/left" 2 > "$CASES"
plan
test "$(wc -l < "$ENTRIES")" -eq 1
test ! -s "$ALIASES"
record single other.tl "$WORKDIR/left" 2 >> "$CASES"
reject plan
record other same.tl "$WORKDIR/right" 2 > "$CASES"
reject plan
record other same.tl "$WORKDIR/left" 1 > "$CASES"
reject plan
record other same.tl "$WORKDIR/left" 02 > "$CASES"
reject plan
printf 'malformed\n' > "$CASES"
reject plan

CORPUS="$WORKDIR/corpus"
BATCHES="$WORKDIR/batches"
mkdir -p "$BATCHES/opt1/chunks" "$BATCHES/opt2/chunks"
printf 'first|input.tl|1\nsecond|other.tl|2\n' > "$CORPUS"
record first input.tl "$WORKDIR/left" 1 > "$BATCHES/opt1/chunks/cases.0000.txt"
record second other.tl "$WORKDIR/left" 2 > "$BATCHES/opt2/chunks/cases.0000.txt"
cat "$BATCHES/opt1/chunks/cases.0000.txt" "$BATCHES/opt2/chunks/cases.0000.txt" > "$BATCHES/cases.txt"
build_invariance_require_coverage "$CORPUS" "$BATCHES"
cp "$BATCHES/opt2/chunks/cases.0000.txt" "$WORKDIR/saved-chunk"
cp "$BATCHES/opt1/chunks/cases.0000.txt" "$BATCHES/opt2/chunks/cases.0000.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
rm "$BATCHES/opt2/chunks/cases.0000.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0000.txt"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0001.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
rm "$BATCHES/opt2/chunks/cases.0001.txt"
printf 'other|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
printf 'first|input.tl|1\nfirst|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
echo 'build-invariance batch reuse checks passed'
