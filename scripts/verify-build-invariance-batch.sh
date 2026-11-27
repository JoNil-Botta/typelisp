#!/usr/bin/env sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$ROOT/scripts/lib-build-invariance-batch.sh"
BOUNDED_POOL_LABEL=build-invariance
. "$ROOT/scripts/lib-bounded-pool.sh"
mkdir -p "$ROOT/target/exp"
WORKDIR=$(mktemp -d "$ROOT/target/exp/build-invariance-batch.XXXXXX")
case "$WORKDIR" in
    "$ROOT/target/exp/build-invariance-batch."??????) ;;
    *) echo "unexpected fixture scratch directory: $WORKDIR" >&2; exit 1 ;;
esac
trap 'rm -rf -- "${WORKDIR:?}"' EXIT HUP INT TERM
mkdir -p "$WORKDIR/left" "$WORKDIR/right"
CASES="$WORKDIR/cases"
ENTRIES="$WORKDIR/entries"
ALIASES="$WORKDIR/aliases"

record() {
    printf '%s|%s|%s|%s/%s.s|%s\n' "$1" "$2" "$2" "$3" "$1" "$4"
}

# Both producers' opt1/opt2 selfhost jobs retain their full cap and get a
# separate timeout. Ordinary and complete codegen chunks keep the old timeout.
for timeout_producer in left right; do
    for timeout_opt in 1 2; do
        record "selfhost_main_opt$timeout_opt" src/main.tl \
            "$WORKDIR/$timeout_producer" "$timeout_opt" > "$WORKDIR/timeout-cases"
        build_invariance_chunk_is_selfhost "$WORKDIR/timeout-cases"
        test "$(build_invariance_chunk_timeout_seconds "$WORKDIR/timeout-cases")" -eq 1200
    done
done
record ordinary input.tl "$WORKDIR/left" 2 > "$WORKDIR/timeout-cases"
test "$(build_invariance_chunk_timeout_seconds "$WORKDIR/timeout-cases")" -eq 600
record smoke src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2 > "$WORKDIR/timeout-cases"
test "$(build_invariance_chunk_timeout_seconds "$WORKDIR/timeout-cases")" -eq 600
record selfhost_main_opt2 src/main.tl "$WORKDIR/left" 2 >> "$WORKDIR/timeout-cases"
if build_invariance_chunk_is_selfhost "$WORKDIR/timeout-cases"; then
    echo 'mixed chunk acquired selfhost timeout' >&2
    exit 1
fi
test "$(build_invariance_chunk_timeout_seconds "$WORKDIR/timeout-cases")" -eq 600
record selfhost_main_opt2_alias src/main.tl "$WORKDIR/left" 2 > "$WORKDIR/timeout-cases"
test "$(build_invariance_chunk_timeout_seconds "$WORKDIR/timeout-cases")" -eq 600

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
rm -- "${ALIASES:?}"
reject build_invariance_require_plan "$CASES" "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
cp "$WORKDIR/saved-aliases" "$ALIASES"
reject build_invariance_copy_aliases "$ALIASES"
: > "$WORKDIR/left/first.s"
reject build_invariance_copy_aliases "$ALIASES"
printf 'assembly\n' > "$WORKDIR/left/first.s"
build_invariance_copy_aliases "$ALIASES"
cmp "$WORKDIR/left/first.s" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm -- "${WORKDIR:?}/left/alias.s"
ln -s "$WORKDIR/nonexistent" "$WORKDIR/left/alias.s"
reject build_invariance_copy_aliases "$ALIASES"
rm -- "${WORKDIR:?}/left/alias.s" "${WORKDIR:?}/left/first.s"
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
rm -- "${BATCHES:?}/opt2/chunks/cases.0000.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0000.txt"
cp "$WORKDIR/saved-chunk" "$BATCHES/opt2/chunks/cases.0001.txt"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
rm -- "${BATCHES:?}/opt2/chunks/cases.0001.txt"
printf 'other|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"
printf 'first|input.tl|1\nfirst|other.tl|2\n' > "$CORPUS"
reject build_invariance_require_coverage "$CORPUS" "$BATCHES"

# Large inputs stay isolated from different inputs, while all their adjacent
# logical aliases remain in the authoritative inventory and output comparisons.
CHUNK_ROOT="$WORKDIR/chunk-tests"
mkdir -p "$CHUNK_ROOT/opt2"
{
    record before ordinary.tl "$WORKDIR/left" 2
    record smoke-a src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2
    record smoke-b src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2
    record other src/tests/compiler_other_smoke.tl "$WORKDIR/left" 2
    record after ordinary.tl "$WORKDIR/left" 2
    record after-alias ordinary.tl "$WORKDIR/left" 2
} > "$CHUNK_ROOT/cases.txt"
build_invariance_write_chunks "$CHUNK_ROOT/cases.txt" "$CHUNK_ROOT/opt2/chunks" 64
test "$(find "$CHUNK_ROOT/opt2/chunks" -name 'cases.*.txt' | wc -l)" -eq 4
awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$CHUNK_ROOT/cases.txt" > "$CORPUS"
build_invariance_require_coverage "$CORPUS" "$CHUNK_ROOT"
test "$(wc -l < "$CHUNK_ROOT/opt2/chunks/cases.0001.txt")" -eq 2
build_invariance_chunk_is_codegen_smoke "$CHUNK_ROOT/opt2/chunks/cases.0001.txt"
if build_invariance_chunk_is_codegen_smoke "$CHUNK_ROOT/opt2/chunks/cases.0002.txt"; then
    echo "unrelated smoke acquired codegen memory class" >&2
    exit 1
fi
build_invariance_plan_chunk "$CHUNK_ROOT/opt2/chunks/cases.0001.txt" \
    "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
test "$(wc -l < "$ENTRIES")" -eq 1
test "$(wc -l < "$ALIASES")" -eq 1
printf 'fresh complete smoke assembly\n' > "$WORKDIR/left/smoke-a.s"
build_invariance_copy_aliases "$ALIASES"
cmp "$WORKDIR/left/smoke-a.s" "$WORKDIR/left/smoke-b.s"
cat "$CHUNK_ROOT/opt2/chunks/cases.0002.txt" >> "$CHUNK_ROOT/opt2/chunks/cases.0001.txt"
if build_invariance_chunk_is_codegen_smoke "$CHUNK_ROOT/opt2/chunks/cases.0001.txt"; then
    echo "mixed inputs acquired codegen memory class" >&2
    exit 1
fi
: > "$CHUNK_ROOT/empty"
if build_invariance_chunk_is_codegen_smoke "$CHUNK_ROOT/empty"; then
    echo "empty chunk acquired codegen memory class" >&2
    exit 1
fi

# The ceiling counts logical aliases; crossing it starts a new fresh compile.
: > "$CASES"
i=0
while [ "$i" -lt 65 ]; do
    record "large-$i" src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2 >> "$CASES"
    i=$((i + 1))
done
build_invariance_write_chunks "$CASES" "$CHUNK_ROOT/boundary" 64
test "$(find "$CHUNK_ROOT/boundary" -name 'cases.*.txt' | wc -l)" -eq 2
test "$(wc -l < "$CHUNK_ROOT/boundary/cases.0000.txt")" -eq 64
test "$(wc -l < "$CHUNK_ROOT/boundary/cases.0001.txt")" -eq 1
build_invariance_plan_chunk "$CHUNK_ROOT/boundary/cases.0000.txt" \
    "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"
test "$(wc -l < "$ENTRIES")" -eq 1
test "$(wc -l < "$ALIASES")" -eq 63

# Staged input paths and requested optimization are part of the invocation
# identity even when logical source names match.
record original src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2 > "$CASES"
sed 's/|src\/tests\/compiler_codegen_smoke_suite.tl|\([^|]*\)|2$/|staged.tl|\1|2/' \
    "$CASES" >> "$CHUNK_ROOT/staged"
cat "$CHUNK_ROOT/staged" >> "$CASES"
build_invariance_write_chunks "$CASES" "$CHUNK_ROOT/identity" 64
test "$(find "$CHUNK_ROOT/identity" -name 'cases.*.txt' | wc -l)" -eq 2
record same src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 1 >> "$CASES"
reject build_invariance_write_chunks "$CASES" "$CHUNK_ROOT/identity" 64
build_invariance_write_chunks "$CASES" "$CHUNK_ROOT/identity-opt" 64
test "$(find "$CHUNK_ROOT/identity-opt" -name 'cases.*.txt' | wc -l)" -eq 3
build_invariance_write_chunks "$CHUNK_ROOT/empty" "$CHUNK_ROOT/identity-empty" 64
test "$(find "$CHUNK_ROOT/identity-empty" -type f | wc -l)" -eq 0

# Equal actual inputs with only requested optimization changed must also split.
record opt-first src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 1 > "$CHUNK_ROOT/opt-cases"
record opt-second src/tests/compiler_codegen_smoke_suite.tl "$WORKDIR/left" 2 >> "$CHUNK_ROOT/opt-cases"
build_invariance_write_chunks "$CHUNK_ROOT/opt-cases" "$CHUNK_ROOT/opt-identity" 64
test "$(find "$CHUNK_ROOT/opt-identity" -name 'cases.*.txt' | wc -l)" -eq 2
build_invariance_plan_chunk "$CHUNK_ROOT/opt-identity/cases.0000.txt" \
    "$ENTRIES" "$ALIASES" 1 "$WORKDIR/left"
build_invariance_plan_chunk "$CHUNK_ROOT/opt-identity/cases.0001.txt" \
    "$ENTRIES" "$ALIASES" 2 "$WORKDIR/left"

# Compiler sources and test programs never share a chunk, while each side
# still batches up to the ceiling and keeps every logical row.
{
    record program-a tests/integration/a.tl "$WORKDIR/left" 2
    record program-b examples/b.tl "$WORKDIR/left" 2
    record source-a src/tests/sample_smoke.tl "$WORKDIR/left" 2
    record source-b src/sample_module.tl "$WORKDIR/left" 2
    record program-c tests/integration/c.tl "$WORKDIR/left" 2
} > "$CHUNK_ROOT/class-cases.txt"
mkdir -p "$CHUNK_ROOT/class/opt2"
build_invariance_write_chunks "$CHUNK_ROOT/class-cases.txt" "$CHUNK_ROOT/class/opt2/chunks" 64
test "$(find "$CHUNK_ROOT/class/opt2/chunks" -name 'cases.*.txt' | wc -l)" -eq 3
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/class/opt2/chunks/cases.0000.txt" | paste -sd, -)" = program-a,program-b
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/class/opt2/chunks/cases.0001.txt" | paste -sd, -)" = source-a,source-b
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/class/opt2/chunks/cases.0002.txt" | paste -sd, -)" = program-c
cp "$CHUNK_ROOT/class-cases.txt" "$CHUNK_ROOT/class/cases.txt"
awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$CHUNK_ROOT/class-cases.txt" > "$CORPUS"
build_invariance_require_coverage "$CORPUS" "$CHUNK_ROOT/class"

# Pool classes: hard cap and queue rank of one producer's chunk.
chunk_class() {
    : > "$WORKDIR/class-chunk"
    while [ "$#" -gt 1 ]; do
        record "$1" "$2" "$WORKDIR/left" 2 >> "$WORKDIR/class-chunk"
        shift 2
    done
    build_invariance_chunk_class "$WORKDIR/class-chunk" "$1"
}
test "$(chunk_class smoke src/tests/compiler_codegen_smoke_suite.tl opt1-built)" = '8192 2'
test "$(chunk_class smoke src/tests/compiler_codegen_smoke_suite.tl opt2-built)" = '4096 2'
test "$(chunk_class selfhost_main_opt2 src/main.tl opt1-built)" = '6144 1'
test "$(chunk_class selfhost_main_opt2 src/main.tl opt2-built)" = '6144 1'
test "$(chunk_class selfhost_main_opt1 src/main.tl opt2-built)" = '4096 4'
test "$(chunk_class other src/tests/compiler_other_smoke.tl opt1-built)" = '4096 3'
test "$(chunk_class program tests/integration/a.tl source src/tests/sample_smoke.tl opt2-built)" = '4096 3'
test "$(chunk_class program tests/integration/a.tl example examples/b.tl opt1-built)" = '2048 6'
# A mixed or aliased chunk never borrows a whole-compiler class.
test "$(chunk_class smoke src/tests/compiler_codegen_smoke_suite.tl program tests/integration/a.tl opt1-built)" = '4096 3'
test "$(chunk_class selfhost_main_opt2 src/main.tl selfhost_main_opt2_alias src/main.tl opt1-built)" = '4096 3'

# Transitive-LOC singleton splitting, 3-tier src/ memory caps, and LPT weights.
WEIGHTS="$WORKDIR/synthetic-weights.txt"
cat > "$WEIGHTS" <<'EOF'
src/tests/small_a.tl|12000
src/tests/small_b.tl|99999
src/tests/medium_a.tl|100001
src/tests/medium_b.tl|350000
src/tests/giant_a.tl|400001
src/tests/giant_b.tl|721000
src/tests/missing_src.tl|-1
EOF
{
    record small-a src/tests/small_a.tl "$WORKDIR/left" 2
    record small-b src/tests/small_b.tl "$WORKDIR/left" 2
    record giant-a src/tests/giant_a.tl "$WORKDIR/left" 2
    record giant-a-alias src/tests/giant_a.tl "$WORKDIR/left" 2
    record medium-a src/tests/medium_a.tl "$WORKDIR/left" 2
    record giant-b src/tests/giant_b.tl "$WORKDIR/left" 2
    record small-c src/tests/small_a.tl "$WORKDIR/left" 2
} > "$CHUNK_ROOT/loc-cases.txt"
mkdir -p "$CHUNK_ROOT/loc/opt2"
build_invariance_write_chunks "$CHUNK_ROOT/loc-cases.txt" "$CHUNK_ROOT/loc/opt2/chunks" 64 "$WEIGHTS" "$ROOT"
# small-a + small-b batch together; giant-a (+ alias), medium-a, giant-b stay singletons; small-c gets its own chunk.
test "$(find "$CHUNK_ROOT/loc/opt2/chunks" -name 'cases.*.txt' | wc -l)" -eq 5
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/loc/opt2/chunks/cases.0000.txt" | paste -sd, -)" = small-a,small-b
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/loc/opt2/chunks/cases.0001.txt" | paste -sd, -)" = giant-a,giant-a-alias
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/loc/opt2/chunks/cases.0002.txt" | paste -sd, -)" = medium-a
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/loc/opt2/chunks/cases.0003.txt" | paste -sd, -)" = giant-b
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/loc/opt2/chunks/cases.0004.txt" | paste -sd, -)" = small-c
cp "$CHUNK_ROOT/loc-cases.txt" "$CHUNK_ROOT/loc/cases.txt"
awk -F '|' '{ print $1 "|" $2 "|" $5 }' "$CHUNK_ROOT/loc-cases.txt" > "$CORPUS"
build_invariance_require_coverage "$CORPUS" "$CHUNK_ROOT/loc"

# 3-tier src/ caps and fail-closed fallback for unmeasured src/ entries.
test "$(build_invariance_chunk_class "$CHUNK_ROOT/loc/opt2/chunks/cases.0000.txt" opt1-built "$WEIGHTS" "$ROOT")" = '2048 5'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/loc/opt2/chunks/cases.0001.txt" opt1-built "$WEIGHTS" "$ROOT")" = '4096 3'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/loc/opt2/chunks/cases.0002.txt" opt1-built "$WEIGHTS" "$ROOT")" = '3072 4'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/loc/opt2/chunks/cases.0003.txt" opt2-built "$WEIGHTS" "$ROOT")" = '4096 3'
record missing-case src/tests/missing_src.tl "$WORKDIR/left" 2 > "$WORKDIR/missing-chunk"
test "$(build_invariance_chunk_class "$WORKDIR/missing-chunk" opt1-built "$WEIGHTS" "$ROOT")" = '4096 3'

# LPT weights sum unique inputs only (aliases do not double-count).
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/loc/opt2/chunks/cases.0000.txt" "$WEIGHTS" "$ROOT")" -eq 111999
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/loc/opt2/chunks/cases.0001.txt" "$WEIGHTS" "$ROOT")" -eq 400001
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/loc/opt2/chunks/cases.0003.txt" "$WEIGHTS" "$ROOT")" -eq 721000

# End-to-end transitive import-closure measurement against a synthetic source tree
# (keeps this self-test self-contained with zero dependency on repo source files).
FAKE_ROOT="$WORKDIR/fake-repo"
FAKE_SRC="src"
FAKE_TESTS="$FAKE_SRC/tests"
mkdir -p "$FAKE_ROOT/$FAKE_TESTS"
awk 'BEGIN { for (i = 0; i < 410000; i++) print ";" }' > "$FAKE_ROOT/$FAKE_SRC/dep_huge.tl"
awk 'BEGIN { for (i = 0; i < 150000; i++) print ";" }' > "$FAKE_ROOT/$FAKE_SRC/dep_med.tl"
awk 'BEGIN { for (i = 0; i < 500; i++) print ";" }' > "$FAKE_ROOT/$FAKE_SRC/dep_small.tl"
printf '(import dep_huge)\n(define (main) : i64 0)\n' > "$FAKE_ROOT/$FAKE_TESTS/non_compiler_giant.tl"
printf '(import dep_med)\n(define (main) : i64 0)\n' > "$FAKE_ROOT/$FAKE_TESTS/non_compiler_med.tl"
printf '(import dep_small)\n(define (main) : i64 0)\n' > "$FAKE_ROOT/$FAKE_TESTS/compiler_small_smoke.tl"
printf '(import dep_small)\n(define (main) : i64 0)\n' > "$FAKE_ROOT/$FAKE_TESTS/non_compiler_small.tl"
FAKE_WEIGHTS="$WORKDIR/fake-weights.txt"
{
    record giant "$FAKE_TESTS/non_compiler_giant.tl" "$WORKDIR/left" 2
    record med "$FAKE_TESTS/non_compiler_med.tl" "$WORKDIR/left" 2
    record comp-small "$FAKE_TESTS/compiler_small_smoke.tl" "$WORKDIR/left" 2
    record plain-small "$FAKE_TESTS/non_compiler_small.tl" "$WORKDIR/left" 2
} > "$WORKDIR/fake-cases.txt"
build_invariance_write_src_weights "$WORKDIR/fake-cases.txt" "$FAKE_WEIGHTS" "$FAKE_ROOT"
build_invariance_write_chunks "$WORKDIR/fake-cases.txt" "$CHUNK_ROOT/fake-chunks" 64 "$FAKE_WEIGHTS" "$FAKE_ROOT"
test "$(find "$CHUNK_ROOT/fake-chunks" -name 'cases.*.txt' | wc -l)" -eq 4
test "$(build_invariance_chunk_class "$CHUNK_ROOT/fake-chunks/cases.0000.txt" opt1-built "$FAKE_WEIGHTS" "$FAKE_ROOT")" = '4096 3'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/fake-chunks/cases.0001.txt" opt1-built "$FAKE_WEIGHTS" "$FAKE_ROOT")" = '3072 4'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/fake-chunks/cases.0002.txt" opt1-built "$FAKE_WEIGHTS" "$FAKE_ROOT")" = '2048 5'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/fake-chunks/cases.0003.txt" opt1-built "$FAKE_WEIGHTS" "$FAKE_ROOT")" = '2048 5'
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/fake-chunks/cases.0000.txt" "$FAKE_WEIGHTS" "$FAKE_ROOT")" -eq 410002
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/fake-chunks/cases.0001.txt" "$FAKE_WEIGHTS" "$FAKE_ROOT")" -eq 150002
test "$(build_invariance_chunk_weight "$CHUNK_ROOT/fake-chunks/cases.0002.txt" "$FAKE_WEIGHTS" "$FAKE_ROOT")" -eq 502

# Hydrated src_core.tli mode: eligible src/ tests batch separately from
# full-source src/ entries and ordinary test programs (capped at 10 per chunk,
# 2048 MiB rank 5), while selfhost main, the 8 GiB codegen/backend gates, and
# the generated-macro tests stay on full source with their original caps.
# Build path strings via $FAKE_SRC/$FAKE_TESTS so ci-affected does not treat
# these pure string-classification probes as file-content dependencies.
for full_case in \
    "selfhost_main_opt1|$FAKE_SRC/main.tl" \
    "selfhost_main_opt2|$FAKE_SRC/main.tl" \
    "integration_codegen|$FAKE_TESTS/compiler_codegen_smoke_suite.tl" \
    "integration_backend|$FAKE_TESTS/compiler_backend_smoke.tl" \
    "integration_frontend|$FAKE_TESTS/compiler_frontend_smoke_suite.tl" \
    "integration_parse|$FAKE_TESTS/compiler_parse_smoke.tl" \
    "integration_tlci|$FAKE_TESTS/tlci_loader_smoke.tl" \
    'integration_ordinary|tests/integration/a.tl'; do
    if build_invariance_source_uses_src_core_tli "${full_case%%|*}" "${full_case#*|}"; then
        echo "unexpected src_core.tli eligibility for $full_case" >&2
        exit 1
    fi
done
build_invariance_source_uses_src_core_tli integration_doc "$FAKE_TESTS/doc_html_smoke.tl"
build_invariance_source_uses_src_core_tli integration_tc "$FAKE_TESTS/compiler_typecheck_smoke.tl"

{
    record ord-a tests/integration/a.tl "$WORKDIR/left" 2
    record hyd-1 "$FAKE_TESTS/compiler_bounds_check_smoke.tl" "$WORKDIR/left" 2
    record hyd-2 "$FAKE_TESTS/doc_html_smoke.tl" "$WORKDIR/left" 2
    record full-codegen "$FAKE_TESTS/compiler_codegen_smoke_suite.tl" "$WORKDIR/left" 2
    record full-frontend "$FAKE_TESTS/compiler_frontend_smoke_suite.tl" "$WORKDIR/left" 2
    record hyd-3 "$FAKE_TESTS/compiler_typecheck_smoke.tl" "$WORKDIR/left" 2
    record ord-b tests/integration/b.tl "$WORKDIR/left" 2
} > "$CHUNK_ROOT/tli-cases.txt"
build_invariance_write_chunks "$CHUNK_ROOT/tli-cases.txt" "$CHUNK_ROOT/tli-chunks" 64 "$WEIGHTS" "$ROOT" 1
test "$(find "$CHUNK_ROOT/tli-chunks" -name 'cases.*.txt' | wc -l)" -eq 6
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0000.txt" | paste -sd, -)" = ord-a
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0001.txt" | paste -sd, -)" = hyd-1,hyd-2
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0002.txt" | paste -sd, -)" = full-codegen
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0003.txt" | paste -sd, -)" = full-frontend
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0004.txt" | paste -sd, -)" = hyd-3
test "$(cut -d '|' -f 1 "$CHUNK_ROOT/tli-chunks/cases.0005.txt" | paste -sd, -)" = ord-b
build_invariance_chunk_uses_src_core_tli "$CHUNK_ROOT/tli-chunks/cases.0001.txt"
build_invariance_chunk_uses_src_core_tli "$CHUNK_ROOT/tli-chunks/cases.0004.txt"
for non_tli_chunk in cases.0000.txt cases.0002.txt cases.0003.txt cases.0005.txt; do
    if build_invariance_chunk_uses_src_core_tli "$CHUNK_ROOT/tli-chunks/$non_tli_chunk"; then
        echo "non-eligible chunk marked for src_core.tli: $non_tli_chunk" >&2
        exit 1
    fi
done
test "$(build_invariance_chunk_class "$CHUNK_ROOT/tli-chunks/cases.0001.txt" opt1-built "$WEIGHTS" "$ROOT" 1)" = '2048 5'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/tli-chunks/cases.0002.txt" opt1-built "$WEIGHTS" "$ROOT" 1)" = '8192 2'
test "$(build_invariance_chunk_class "$CHUNK_ROOT/tli-chunks/cases.0003.txt" opt1-built "$WEIGHTS" "$ROOT" 1)" = '4096 3'
# Mixed chunk fails closed and never gets --extra-tli.
cat "$CHUNK_ROOT/tli-chunks/cases.0001.txt" "$CHUNK_ROOT/tli-chunks/cases.0002.txt" > "$CHUNK_ROOT/tli-mixed.txt"
if build_invariance_chunk_uses_src_core_tli "$CHUNK_ROOT/tli-mixed.txt"; then
    echo "mixed chunk acquired src_core.tli flag" >&2
    exit 1
fi
# Hydrated src/ chunks split at 10 entries to keep 4 workers parallel.
: > "$CHUNK_ROOT/tli-cap-cases.txt"
i=0
while [ "$i" -lt 12 ]; do
    record "hyd-cap-$i" "$FAKE_TESTS/small_$i.tl" "$WORKDIR/left" 2 >> "$CHUNK_ROOT/tli-cap-cases.txt"
    i=$((i + 1))
done
build_invariance_write_chunks "$CHUNK_ROOT/tli-cap-cases.txt" "$CHUNK_ROOT/tli-cap-chunks" 64 "$WEIGHTS" "$ROOT" 1
test "$(find "$CHUNK_ROOT/tli-cap-chunks" -name 'cases.*.txt' | wc -l)" -eq 2
test "$(wc -l < "$CHUNK_ROOT/tli-cap-chunks/cases.0000.txt")" -eq 10
test "$(wc -l < "$CHUNK_ROOT/tli-cap-chunks/cases.0001.txt")" -eq 2

# Worker pool: jobs start in queue order, only inside the memory budget, exactly
# once; a drained pool passes only with one successful result per queued job.
POOL="$WORKDIR/pool"
QUEUE="$WORKDIR/queue"
printf 'full-a|8192\nfull-b|8192\nsmall-a|4096\nsmall-b|4096\n' > "$QUEUE"
bounded_pool_init "$POOL" 12288 "$QUEUE"
test "$(bounded_pool_claim "$POOL")" = 'full-a|8192'
# The second 8 GiB job does not fit beside the first; the next fitting job runs.
test "$(bounded_pool_claim "$POOL")" = 'small-a|4096'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 3
test ! -s "$WORKDIR/stdout"
reject bounded_pool_require_complete "$POOL"
bounded_pool_finish "$POOL" small-a 0
test "$(bounded_pool_claim "$POOL")" = 'small-b|4096'
bounded_pool_finish "$POOL" full-a 0
test "$(bounded_pool_claim "$POOL")" = 'full-b|8192'
pool_status=0
bounded_pool_claim "$POOL" > "$WORKDIR/stdout" || pool_status=$?
test "$pool_status" -eq 1
reject bounded_pool_require_complete "$POOL"
bounded_pool_finish "$POOL" small-b 0
bounded_pool_finish "$POOL" full-b 0
bounded_pool_require_complete "$POOL"
# A job reports once, and only after it was started.
reject bounded_pool_finish "$POOL" full-b 0
reject bounded_pool_finish "$POOL" never-started 0
bounded_pool_require_complete "$POOL"

# Failed, missing, foreign and unfinished results and an abort all fail closed.
printf '1\n' > "$POOL/results/full-b"
reject bounded_pool_require_complete "$POOL"
rm -- "${POOL:?}/results/full-b"
reject bounded_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/full-b"
bounded_pool_require_complete "$POOL"
cp "$POOL/results/full-a" "$POOL/results/foreign"
reject bounded_pool_require_complete "$POOL"
rm -- "${POOL:?}/results/foreign"
mkdir "$POOL/claims/foreign"
reject bounded_pool_require_complete "$POOL"
rmdir -- "${POOL:?}/claims/foreign"
printf '4096\n' > "$POOL/running/small-a"
reject bounded_pool_require_complete "$POOL"
rm -- "${POOL:?}/running/small-a"
: > "$POOL/abort"
reject bounded_pool_require_complete "$POOL"
reject bounded_pool_claim "$POOL"
rm -- "${POOL:?}/abort"
bounded_pool_require_complete "$POOL"
# A lock that is never released is reported instead of waited on forever.
: > "$POOL/lock"
reject bounded_pool_require_complete "$POOL"
BOUNDED_POOL_LOCK_SECONDS=1
reject bounded_pool_claim "$POOL"
reject bounded_pool_finish "$POOL" full-a 0
BOUNDED_POOL_LOCK_SECONDS=60
rm -f -- "${POOL:?}/lock"

# Malformed, duplicate, empty and over-budget queues never start a pool.
for bad_queue in 'job' 'job|' 'job|0' 'job|08' 'job|4096|extra' '../job|4096' \
    'job|16384' 'job|4096
job|4096'; do
    printf '%s\n' "$bad_queue" > "$QUEUE"
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
    test ! -e "$POOL.bad"
done
: > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
# A final record without its newline would be validated but never run or counted.
printf 'first|4096\nlast|4096' > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
test ! -e "$POOL.bad"
printf 'job|4096\n' > "$QUEUE"
reject bounded_pool_init "$POOL.bad" 0 "$QUEUE"
reject bounded_pool_init "$POOL.bad" '' "$QUEUE"

# Concurrent workers: every job runs once and the running caps never exceed the
# budget, which each job observes from inside the pool.
write_pool_queue() {
    i=0
    : > "$QUEUE"
    while [ "$i" -lt "$1" ]; do
        case $((i % 3)) in
            0) printf 'job%s|8192\n' "$i" >> "$QUEUE" ;;
            *) printf 'job%s|4096\n' "$i" >> "$QUEUE" ;;
        esac
        i=$((i + 1))
    done
}
count_entries() {
    find "$1" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' '
}
POOL_FAIL_JOB=
POOL_KILL_JOB=
bounded_pool_run_job() {
    bounded_pool_lock "$POOL"
    pool_used=0
    for pool_running in "$POOL/running"/*; do
        pool_used=$((pool_used + $(cat "$pool_running")))
    done
    bounded_pool_unlock "$POOL"
    [ "$pool_used" -ge "$2" ] && [ "$pool_used" -le 12288 ]
    mkdir "$WORKDIR/ran/$1"
    sleep 0.05
    if [ "$1" = "$POOL_FAIL_JOB" ]; then
        echo "job $1 fails" >&2
        exit 7
    fi
    if [ "$1" = "$POOL_KILL_JOB" ]; then
        # The parent publishes the only worker's process id after starting it.
        until [ -s "$WORKDIR/worker.pid" ]; do
            sleep 0.05
        done
        kill -KILL "$(cat "$WORKDIR/worker.pid")"
        sleep 5
    fi
}
write_pool_queue 24
bounded_pool_init "$POOL" 12288 "$QUEUE"
mkdir "$WORKDIR/ran"
bounded_pool_start "$POOL" 3
bounded_pool_wait_for "$POOL" job0 job23
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 24

# A failing job aborts the pool: its status is kept, waiters and the join fail,
# and the jobs queued behind it never start.
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_FAIL_JOB=job4
bounded_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
reject bounded_pool_wait_for "$POOL" job23
reject bounded_pool_join "$POOL"
POOL_FAIL_JOB=
test "$(cat "$POOL/results/job4")" -eq 7
grep -q 'job job4 fails' "$WORKDIR/workers.log"
test -e "$POOL/abort"
test ! -e "$WORKDIR/ran/job23"
test "$(count_entries "$WORKDIR/ran")" -lt 24
reject bounded_pool_require_complete "$POOL"

# A worker that dies without reporting cannot leave the gate waiting or green.
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_KILL_JOB=job2
bounded_pool_start "$POOL" 1 2>> "$WORKDIR/workers.log"
printf '%s\n' $BOUNDED_POOL_PIDS > "$WORKDIR/worker.pid.tmp"
mv "$WORKDIR/worker.pid.tmp" "$WORKDIR/worker.pid"
reject bounded_pool_wait_for "$POOL" job23
grep -q 'every pool worker exited without a result for job23' "$WORKDIR/stderr"
reject bounded_pool_join "$POOL"
POOL_KILL_JOB=
test -f "$POOL/running/job2"
test ! -e "$POOL/results/job2"
reject bounded_pool_require_complete "$POOL"

# The caller's own failure stops the pool: running jobs finish, none starts.
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 2 2>> "$WORKDIR/workers.log"
bounded_pool_stop "$POOL"
test "$(count_entries "$POOL/running")" -eq 0
pool_started_jobs=$(count_entries "$WORKDIR/ran")
test "$pool_started_jobs" -lt 24
test "$(count_entries "$POOL/results")" -eq "$pool_started_jobs"
sleep 0.2
test "$(count_entries "$WORKDIR/ran")" -eq "$pool_started_jobs"
reject bounded_pool_require_complete "$POOL"

# Needs name earlier queued jobs and locks are distinct names; a self, later,
# unknown or empty need, and an empty, duplicate or malformed lock, rejects the
# queue.
for bad_queue in 'a|4096|a' 'a|4096|b
b|4096' 'a|4096
b|4096|a,c' 'a|4096|' 'a|4096|-|' 'a|4096|-|x,x' 'a|4096|-|../x' \
    'a|4096|-|x|y'; do
    printf '%s\n' "$bad_queue" > "$QUEUE"
    reject bounded_pool_init "$POOL.bad" 12288 "$QUEUE"
    test ! -e "$POOL.bad"
done

# A job starts only after each of its needs succeeded, and a job blocked on its
# needs does not hold back independent jobs queued behind it: `slow` finishes
# only once `free` has run beside it.
POOL_NEEDS_FAIL_JOB=
bounded_pool_run_job() {
    needs_record=$(awk -F '|' -v job="$1" '$1 == job { print $3 }' "$QUEUE")
    [ -z "$needs_record" ] || bounded_pool_needs_met "$POOL" "$needs_record" || exit 9
    printf '%s\n' "$1" >> "$WORKDIR/order"
    if [ "$1" = slow ]; then
        needs_waits=0
        until [ -e "$WORKDIR/ran/free" ]; do
            needs_waits=$((needs_waits + 1))
            [ "$needs_waits" -lt 100 ] || exit 8
            sleep 0.1
        done
    fi
    [ "$1" != "$POOL_NEEDS_FAIL_JOB" ] || exit 7
    mkdir "$WORKDIR/ran/$1"
}
cat > "$QUEUE" <<'EOF'
slow|4096
after-slow|4096|slow
free|4096
join|8192|after-slow,free
tail|4096|join
EOF
rm -rf -- "${WORKDIR:?}/ran" "${WORKDIR:?}/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 5
test "$(sed -n '$p' "$WORKDIR/order")" = tail

# One worker runs a dependency-ordered queue exactly in queue order.
cat > "$QUEUE" <<'EOF'
a|4096
b|4096|a
c|4096
d|4096|b,c
EOF
rm -rf -- "${WORKDIR:?}/ran" "${WORKDIR:?}/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 1
bounded_pool_join "$POOL"
test "$(tr '\n' ' ' < "$WORKDIR/order")" = 'a b c d '

# A failed need aborts the pool; nothing that needs it starts.
rm -rf -- "${WORKDIR:?}/ran" "${WORKDIR:?}/order"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_NEEDS_FAIL_JOB=a
bounded_pool_start "$POOL" 3 2>> "$WORKDIR/workers.log"
reject bounded_pool_join "$POOL"
POOL_NEEDS_FAIL_JOB=
test "$(cat "$POOL/results/a")" -eq 7
test ! -e "$POOL/claims/b"
test ! -e "$POOL/claims/d"
reject bounded_pool_require_complete "$POOL"

# Jobs that share a lock never run at once, whatever their needs, and every
# lock is released when its job finishes or fails.
POOL_LOCK_FAIL_JOB=
bounded_pool_run_job() {
    lock_record=$(awk -F '|' -v job="$1" '$1 == job { print $4 }' "$QUEUE")
    for lock_name in $(printf '%s\n' "$lock_record" | tr ',' ' '); do
        mkdir "$WORKDIR/in-$lock_name" || exit 9
    done
    sleep 0.2
    for lock_name in $(printf '%s\n' "$lock_record" | tr ',' ' '); do
        rmdir -- "${WORKDIR:?}/in-${lock_name:?}"
    done
    [ "$1" != "$POOL_LOCK_FAIL_JOB" ] || exit 7
    mkdir "$WORKDIR/ran/$1"
}
cat > "$QUEUE" <<'EOF'
stamp-a|4096|-|stamp
both|4096|-|stamp,release
release-a|4096|-|release
free|4096
stamp-b|4096|free|stamp
release-b|4096|stamp-a|release
EOF
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
test "$(count_entries "$WORKDIR/ran")" -eq 6
test "$(count_entries "$POOL/held")" -eq 0
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
POOL_LOCK_FAIL_JOB=stamp-a
bounded_pool_start "$POOL" 3 2>> "$WORKDIR/workers.log"
reject bounded_pool_join "$POOL"
POOL_LOCK_FAIL_JOB=
test "$(cat "$POOL/results/stamp-a")" -eq 7
test "$(count_entries "$POOL/held")" -eq 0
# A lock left held is incomplete even when every job succeeded.
rm -rf -- "${WORKDIR:?}/ran"
mkdir "$WORKDIR/ran"
bounded_pool_init "$POOL" 12288 "$QUEUE"
bounded_pool_start "$POOL" 3
bounded_pool_join "$POOL"
mkdir "$POOL/held/stamp"
reject bounded_pool_require_complete "$POOL"

# bounded_pool_unlock must not re-stat the lock after rm succeeds: if a waiting
# worker immediately acquires the lock, looping would delete the new owner's lock.
REAL_RM=$(command -v rm)
UNLOCK_POOL="$WORKDIR/unlock-race-pool"
UNLOCK_SHIM="$WORKDIR/unlock-race-bin"
mkdir -p "$UNLOCK_POOL" "$UNLOCK_SHIM"
printf 'old-owner\n' > "$UNLOCK_POOL/lock"
: > "$UNLOCK_SHIM/calls"
cat > "$UNLOCK_SHIM/rm" <<EOF
#!/usr/bin/env sh
set -eu
printf 'call\n' >> "$UNLOCK_SHIM/calls"
"$REAL_RM" "\$@"
printf 'new-owner\n' > "$UNLOCK_POOL/lock"
EOF
chmod +x "$UNLOCK_SHIM/rm"
(
    set -eu
    PATH="$UNLOCK_SHIM:$PATH"
    bounded_pool_unlock "$UNLOCK_POOL"
)
test "$(wc -l < "$UNLOCK_SHIM/calls" | tr -d ' ')" -eq 1
test -f "$UNLOCK_POOL/lock"
test "$(cat "$UNLOCK_POOL/lock")" = 'new-owner'

# Transient rm failures retry under set -e and remove the lock once rm succeeds.
UNLOCK_RETRY_POOL="$WORKDIR/unlock-retry-pool"
UNLOCK_RETRY_SHIM="$WORKDIR/unlock-retry-bin"
mkdir -p "$UNLOCK_RETRY_POOL" "$UNLOCK_RETRY_SHIM"
printf 'owner\n' > "$UNLOCK_RETRY_POOL/lock"
: > "$UNLOCK_RETRY_SHIM/calls"
cat > "$UNLOCK_RETRY_SHIM/rm" <<EOF
#!/usr/bin/env sh
set -eu
printf 'call\n' >> "$UNLOCK_RETRY_SHIM/calls"
count=\$(wc -l < "$UNLOCK_RETRY_SHIM/calls" | tr -d ' ')
if [ "\$count" -le 2 ]; then
    exit 1
fi
"$REAL_RM" "\$@"
EOF
cat > "$UNLOCK_RETRY_SHIM/sleep" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$UNLOCK_RETRY_SHIM/rm" "$UNLOCK_RETRY_SHIM/sleep"
(
    set -eu
    PATH="$UNLOCK_RETRY_SHIM:$PATH"
    bounded_pool_unlock "$UNLOCK_RETRY_POOL"
)
test "$(wc -l < "$UNLOCK_RETRY_SHIM/calls" | tr -d ' ')" -eq 3
test ! -e "$UNLOCK_RETRY_POOL/lock"

# Persistent rm failures retry 50 times and fail closed with exit 2 and a diagnostic.
UNLOCK_FAIL_POOL="$WORKDIR/unlock-fail-pool"
UNLOCK_FAIL_SHIM="$WORKDIR/unlock-fail-bin"
mkdir -p "$UNLOCK_FAIL_POOL" "$UNLOCK_FAIL_SHIM"
printf 'stuck\n' > "$UNLOCK_FAIL_POOL/lock"
: > "$UNLOCK_FAIL_SHIM/calls"
cat > "$UNLOCK_FAIL_SHIM/rm" <<EOF
#!/usr/bin/env sh
set -eu
printf 'call\n' >> "$UNLOCK_FAIL_SHIM/calls"
exit 1
EOF
cat > "$UNLOCK_FAIL_SHIM/sleep" <<'EOF'
#!/usr/bin/env sh
exit 0
EOF
chmod +x "$UNLOCK_FAIL_SHIM/rm" "$UNLOCK_FAIL_SHIM/sleep"
unlock_fail_status=0
sh -eu -c '
    BOUNDED_POOL_LABEL=build-invariance
    . "$1/scripts/lib-bounded-pool.sh"
    PATH="$2:$PATH"
    bounded_pool_unlock "$3"
' _ "$ROOT" "$UNLOCK_FAIL_SHIM" "$UNLOCK_FAIL_POOL" \
    > "$WORKDIR/stdout" 2> "$WORKDIR/stderr" || unlock_fail_status=$?
test "$unlock_fail_status" -eq 2
test "$(wc -l < "$UNLOCK_FAIL_SHIM/calls" | tr -d ' ')" -eq 50
grep -q "could not release pool lock: $UNLOCK_FAIL_POOL/lock" "$WORKDIR/stderr"
test -f "$UNLOCK_FAIL_POOL/lock"

# High-contention worker pool: 8 workers racing through 40 fast jobs must claim
# and finish every job exactly once with zero lock-stealing collisions.
CONTENTION_POOL="$WORKDIR/contention-pool"
CONTENTION_QUEUE="$WORKDIR/contention-queue"
CONTENTION_RAN="$WORKDIR/contention-ran"
mkdir "$CONTENTION_RAN"
: > "$CONTENTION_QUEUE"
i=0
while [ "$i" -lt 40 ]; do
    printf 'fast-%03d|1\n' "$i" >> "$CONTENTION_QUEUE"
    i=$((i + 1))
done
bounded_pool_run_job() {
    mkdir "$CONTENTION_RAN/$1"
}
bounded_pool_init "$CONTENTION_POOL" 8 "$CONTENTION_QUEUE"
bounded_pool_start "$CONTENTION_POOL" 8 2> "$WORKDIR/contention.stderr"
bounded_pool_join "$CONTENTION_POOL"
test ! -s "$WORKDIR/contention.stderr"
test "$(count_entries "$CONTENTION_RAN")" -eq 40

echo 'build-invariance batch reuse and worker pool checks passed'
