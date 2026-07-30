#!/usr/bin/env sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WORKDIR="$ROOT/target/windows-coff-plan-validator-self-test"
BATCH="$WORKDIR/batch.list"
PLAN="$WORKDIR/result.plan"
NORMALIZED="$WORKDIR/normalized.plan"
STDERR="$WORKDIR/stderr.txt"
VALIDATOR="$ROOT/scripts/validate-windows-coff-plan.awk"

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

expect_failure() {
    _label=$1
    _expected=$2
    _batch=$3
    _plan=$4
    printf '%s\n' "$_batch" > "$BATCH"
    printf '%s\n' "$_plan" > "$PLAN"
    if awk -f "$VALIDATOR" "$BATCH" "$PLAN" > "$NORMALIZED" 2> "$STDERR"; then
        echo "Windows COFF plan validator self-test unexpectedly passed: $_label" >&2
        exit 1
    fi
    if ! grep -F "$_expected" "$STDERR" >/dev/null; then
        echo "Windows COFF plan validator self-test produced the wrong diagnostic: $_label" >&2
        cat "$STDERR" >&2
        exit 1
    fi
}

cat > "$BATCH" <<'EOF'
object.tl|object.obj|object.s
fallback.tl|fallback.obj|fallback.s
forced.tl|forced.obj|forced.s|force-assembly
EOF
cat > "$PLAN" <<'EOF'
object.tl|coff-object|object.obj|none
fallback.tl|assembly|fallback.s|unsupported-coff-image
forced.tl|assembly|forced.s|forced-assembly
EOF
awk -f "$VALIDATOR" "$BATCH" "$PLAN" > "$NORMALIZED"
cat > "$WORKDIR/expected.plan" <<'EOF'
object.tl|coff-object|object.obj|none|object.obj|object.s|0
fallback.tl|assembly|fallback.s|unsupported-coff-image|fallback.obj|fallback.s|0
forced.tl|assembly|forced.s|forced-assembly|forced.obj|forced.s|1
EOF
cmp "$WORKDIR/expected.plan" "$NORMALIZED"

expect_failure missing-row \
    'Windows COFF plan row count mismatch: expected 2, got 1' \
    'one.tl|one.obj|one.s
two.tl|two.obj|two.s' \
    'one.tl|coff-object|one.obj|none'
expect_failure reordered-source \
    'Windows COFF plan line 1 source mismatch' \
    'one.tl|one.obj|one.s
two.tl|two.obj|two.s' \
    'two.tl|coff-object|two.obj|none
one.tl|coff-object|one.obj|none'
expect_failure wrong-selected-path \
    'Windows COFF plan line 1 selected the wrong object path' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|other.obj|none'
expect_failure implicit-forced-row \
    'Windows COFF plan line 1 lost its forced-assembly reason' \
    'one.tl|one.obj|one.s|force-assembly' \
    'one.tl|assembly|one.s|unsupported-coff-image'
expect_failure forged-forced-reason \
    'Windows COFF plan line 1 reported forced-assembly for an automatic row' \
    'one.tl|one.obj|one.s' \
    'one.tl|assembly|one.s|forced-assembly'
expect_failure object-reason \
    'Windows COFF plan line 1 object reason must be none' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|one.obj|unsupported-coff-image'

echo "Windows COFF plan validator self-tests passed"
