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
abi-call.tl|abi-call.obj|abi-call.s
abi-entry.tl|abi-entry.obj|abi-entry.s
abi-return.tl|abi-return.obj|abi-return.s
forced.tl|forced.obj|forced.s|force-assembly
EOF
cat > "$PLAN" <<'EOF'
object.tl|coff-object|object.obj|none|stdlib-archive
fallback.tl|assembly|fallback.s|unsupported-coff-image|none
abi-call.tl|assembly|abi-call.s|unsupported-object-abi:windows-x86_64:call|none
abi-entry.tl|assembly|abi-entry.s|unsupported-object-abi:windows-x86_64:function-entry|none
abi-return.tl|assembly|abi-return.s|unsupported-object-abi:windows-x86_64:function-return|none
forced.tl|assembly|forced.s|forced-assembly|stdlib-archive
EOF
awk -f "$VALIDATOR" "$BATCH" "$PLAN" > "$NORMALIZED"
cat > "$WORKDIR/expected.plan" <<'EOF'
object.tl|coff-object|object.obj|none|object.obj|object.s|0|stdlib-archive
fallback.tl|assembly|fallback.s|unsupported-coff-image|fallback.obj|fallback.s|0|none
abi-call.tl|assembly|abi-call.s|unsupported-object-abi:windows-x86_64:call|abi-call.obj|abi-call.s|0|none
abi-entry.tl|assembly|abi-entry.s|unsupported-object-abi:windows-x86_64:function-entry|abi-entry.obj|abi-entry.s|0|none
abi-return.tl|assembly|abi-return.s|unsupported-object-abi:windows-x86_64:function-return|abi-return.obj|abi-return.s|0|none
forced.tl|assembly|forced.s|forced-assembly|forced.obj|forced.s|1|stdlib-archive
EOF
cmp "$WORKDIR/expected.plan" "$NORMALIZED"

expect_failure missing-row \
    'Windows COFF plan row count mismatch: expected 2, got 1' \
    'one.tl|one.obj|one.s
two.tl|two.obj|two.s' \
    'one.tl|coff-object|one.obj|none|none'
expect_failure reordered-source \
    'Windows COFF plan line 1 source mismatch' \
    'one.tl|one.obj|one.s
two.tl|two.obj|two.s' \
    'two.tl|coff-object|two.obj|none|none
one.tl|coff-object|one.obj|none|none'
expect_failure wrong-selected-path \
    'Windows COFF plan line 1 selected the wrong object path' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|other.obj|none|none'
expect_failure implicit-forced-row \
    'Windows COFF plan line 1 lost its forced-assembly reason' \
    'one.tl|one.obj|one.s|force-assembly' \
    'one.tl|assembly|one.s|unsupported-coff-image|none'
expect_failure forged-forced-reason \
    'Windows COFF plan line 1 reported forced-assembly for an automatic row' \
    'one.tl|one.obj|one.s' \
    'one.tl|assembly|one.s|forced-assembly|none'
expect_failure object-reason \
    'Windows COFF plan line 1 object reason must be none' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|one.obj|unsupported-coff-image|none'
expect_failure missing-archive-requirement \
    'Windows COFF plan line 1 must have 5 fields' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|one.obj|none'
expect_failure invalid-archive-requirement \
    'Windows COFF plan line 1 has an invalid archive requirement: maybe' \
    'one.tl|one.obj|one.s' \
    'one.tl|coff-object|one.obj|none|maybe'

# Multi-plan mode validates multiple (batch, plan, label) pairs in one awk run.
BATCH_A="$WORKDIR/multi-a.list"
PLAN_A="$WORKDIR/multi-a.plan"
BATCH_B="$WORKDIR/multi-b.list"
PLAN_B="$WORKDIR/multi-b.plan"
PLAN_LIST="$WORKDIR/multi.plans"

cat > "$BATCH_A" <<'EOF'
alpha.tl|alpha.obj|alpha.s
beta.tl|beta.obj|beta.s
EOF
cat > "$PLAN_A" <<'EOF'
alpha.tl|coff-object|alpha.obj|none|stdlib-archive
beta.tl|assembly|beta.s|unsupported-coff-image|none
EOF
cat > "$BATCH_B" <<'EOF'
gamma.tl|gamma.obj|gamma.s|force-assembly
delta.tl|delta.obj|delta.s
EOF
cat > "$PLAN_B" <<'EOF'
gamma.tl|assembly|gamma.s|forced-assembly|stdlib-archive
delta.tl|coff-object|delta.obj|none|none
EOF
printf '%s|%s|first\n%s|%s|second\n' "$BATCH_A" "$PLAN_A" "$BATCH_B" "$PLAN_B" > "$PLAN_LIST"
awk -f "$VALIDATOR" -v multi=1 "$PLAN_LIST" > "$NORMALIZED"
cat > "$WORKDIR/expected-multi.plan" <<'EOF'
alpha.tl|coff-object|alpha.obj|none|alpha.obj|alpha.s|0|stdlib-archive
beta.tl|assembly|beta.s|unsupported-coff-image|beta.obj|beta.s|0|none
gamma.tl|assembly|gamma.s|forced-assembly|gamma.obj|gamma.s|1|stdlib-archive
delta.tl|coff-object|delta.obj|none|delta.obj|delta.s|0|none
EOF
cmp "$WORKDIR/expected-multi.plan" "$NORMALIZED"

expect_multi_failure() {
    _label=$1
    _expected=$2
    _list_file=$3
    if awk -f "$VALIDATOR" -v multi=1 "$_list_file" > "$NORMALIZED" 2> "$STDERR"; then
        echo "Windows COFF plan validator multi-plan self-test unexpectedly passed: $_label" >&2
        exit 1
    fi
    if ! grep -F "$_expected" "$STDERR" >/dev/null; then
        echo "Windows COFF plan validator multi-plan self-test produced the wrong diagnostic: $_label" >&2
        cat "$STDERR" >&2
        exit 1
    fi
}

printf '%s\n' 'bad.tl|bad.obj|bad.s' > "$BATCH_B"
printf '%s\n' 'bad.tl|coff-object|wrong.obj|none|none' > "$PLAN_B"
printf '%s|%s|first\n%s|%s|second\n' "$BATCH_A" "$PLAN_A" "$BATCH_B" "$PLAN_B" > "$PLAN_LIST"
expect_multi_failure multi-second-batch-wrong-path \
    'FAIL: invalid Windows COFF result plan for batch second: Windows COFF plan line 1 selected the wrong object path' \
    "$PLAN_LIST"

printf '%s\n%s\n' 'one.tl|one.obj|one.s' 'two.tl|two.obj|two.s' > "$BATCH_B"
printf '%s\n' 'one.tl|coff-object|one.obj|none|none' > "$PLAN_B"
expect_multi_failure multi-second-batch-row-count \
    'FAIL: invalid Windows COFF result plan for batch second: Windows COFF plan row count mismatch: expected 2, got 1' \
    "$PLAN_LIST"

: > "$WORKDIR/empty.plans"
expect_multi_failure multi-empty-list \
    'Windows COFF plan list is empty' \
    "$WORKDIR/empty.plans"

# Exercise the multi-plan registration mode used by verify-integration.sh.
REG_ROOT="$WORKDIR/reg-root"
REG_PREFIX="target/integration-verify/windows/"
mkdir -p \
    "$REG_ROOT/${REG_PREFIX}ok_obj" \
    "$REG_ROOT/${REG_PREFIX}ok_asm" \
    "$REG_ROOT/${REG_PREFIX}ok_forced" \
    "$REG_ROOT/${REG_PREFIX}both_case"
printf 'obj\n' > "$REG_ROOT/${REG_PREFIX}ok_obj/ok_obj.obj"
printf 'asm\n' > "$REG_ROOT/${REG_PREFIX}ok_asm/ok_asm.s"
printf 'asm\n' > "$REG_ROOT/${REG_PREFIX}ok_forced/ok_forced.s"
printf 'obj\n' > "$REG_ROOT/${REG_PREFIX}both_case/both_case.obj"
printf 'asm\n' > "$REG_ROOT/${REG_PREFIX}both_case/both_case.s"

cat > "$BATCH_A" <<EOF
${REG_PREFIX}ok_obj/ok_obj.tl|${REG_PREFIX}ok_obj/ok_obj.obj|${REG_PREFIX}ok_obj/ok_obj.s
${REG_PREFIX}ok_asm/ok_asm.tl|${REG_PREFIX}ok_asm/ok_asm.obj|${REG_PREFIX}ok_asm/ok_asm.s
EOF
cat > "$PLAN_A" <<EOF
${REG_PREFIX}ok_obj/ok_obj.tl|coff-object|${REG_PREFIX}ok_obj/ok_obj.obj|none|stdlib-archive
${REG_PREFIX}ok_asm/ok_asm.tl|assembly|${REG_PREFIX}ok_asm/ok_asm.s|unsupported-coff-image|none
EOF
cat > "$BATCH_B" <<EOF
${REG_PREFIX}ok_forced/ok_forced.tl|${REG_PREFIX}ok_forced/ok_forced.obj|${REG_PREFIX}ok_forced/ok_forced.s|force-assembly
EOF
cat > "$PLAN_B" <<EOF
${REG_PREFIX}ok_forced/ok_forced.tl|assembly|${REG_PREFIX}ok_forced/ok_forced.s|forced-assembly|stdlib-archive
EOF
printf '%s|%s|first\n%s|%s|second\n' "$BATCH_A" "$PLAN_A" "$BATCH_B" "$PLAN_B" > "$PLAN_LIST"
REG_ARTIFACTS="$WORKDIR/reg.artifacts"
REG_REASONS="$WORKDIR/reg.reasons"
REG_COUNTS="$WORKDIR/reg.counts"
: > "$REG_ARTIFACTS"
: > "$REG_REASONS"
awk -f "$VALIDATOR" \
    -v multi=1 \
    -v root="$REG_ROOT" \
    -v expected_prefix="$REG_PREFIX" \
    -v forced_list="ok_forced" \
    -v artifacts_out="$REG_ARTIFACTS" \
    -v reasons_out="$REG_REASONS" \
    -v counts_out="$REG_COUNTS" \
    "$PLAN_LIST"
[ "$(cat "$REG_COUNTS")" = '3|1|1|1' ]
[ "$(cat "$REG_REASONS")" = 'unsupported-coff-image' ]

# Duplicate case across batches must fail in registration mode.
if awk -f "$VALIDATOR" \
    -v multi=1 \
    -v root="$REG_ROOT" \
    -v expected_prefix="$REG_PREFIX" \
    -v forced_list="ok_forced" \
    -v artifacts_out="$REG_ARTIFACTS" \
    -v reasons_out="$REG_REASONS" \
    -v counts_out="$REG_COUNTS" \
    "$PLAN_LIST" 2> "$STDERR"; then
    echo "Windows COFF plan validator registration mode accepted duplicate case" >&2
    exit 1
fi
grep -F 'FAIL: Windows COFF plan selected ok_obj more than once' "$STDERR" >/dev/null

# Object row with stray assembly file on disk must fail in registration mode.
cat > "$BATCH_B" <<EOF
${REG_PREFIX}both_case/both_case.tl|${REG_PREFIX}both_case/both_case.obj|${REG_PREFIX}both_case/both_case.s
EOF
cat > "$PLAN_B" <<EOF
${REG_PREFIX}both_case/both_case.tl|coff-object|${REG_PREFIX}both_case/both_case.obj|none|none
EOF
printf '%s|%s|both\n' "$BATCH_B" "$PLAN_B" > "$PLAN_LIST"
: > "$REG_ARTIFACTS"
if awk -f "$VALIDATOR" \
    -v multi=1 \
    -v root="$REG_ROOT" \
    -v expected_prefix="$REG_PREFIX" \
    -v forced_list="" \
    -v artifacts_out="$REG_ARTIFACTS" \
    -v reasons_out="$REG_REASONS" \
    -v counts_out="$REG_COUNTS" \
    "$PLAN_LIST" 2> "$STDERR"; then
    echo "Windows COFF plan validator registration mode accepted object with stray assembly" >&2
    exit 1
fi
grep -F 'FAIL: Windows COFF object row also wrote assembly for both_case' "$STDERR" >/dev/null

echo "Windows COFF plan validator self-tests passed"
