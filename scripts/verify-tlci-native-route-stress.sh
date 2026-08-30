#!/usr/bin/env sh
set -eu

# Production macro-walk sustained stress for the embedded stdlib TLCI route
# (#5926). The compiler supplied here is the profile CLI built by
# verify-compile-profile.sh with compile-profile, embedded-stdlib-tlci, and
# tlci-native-route-stress. Production routing follows normal trusted-source
# policy on both hosts; the runtime workload variable enables only the durable
# fixed-width stress telemetry used by this gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
. "$ROOT/scripts/lib-ci-timing.sh"

COMPILER=${1:-${TYPELISP_BIN:-}}
if [ -z "$COMPILER" ]; then
    echo "usage: $0 <stress-enabled-profile-compiler>" >&2
    exit 2
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
if [ ! -x "$COMPILER" ]; then
    echo "tlci native route stress compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/tlci-native-route-stress/$NL_HOST_OS"
NATIVE_CWD="$WORKDIR/native-cwd"
SOURCE_ROOT="$WORKDIR/source-root"
NATIVE_DIR="$WORKDIR/native"
SOURCE_DIR="$WORKDIR/source"
WINDOWS_MEMORY_DIR="$WORKDIR/windows-memory"
NATIVE_BATCH="$WORKDIR/native.batch"
SOURCE_BATCH="$WORKDIR/source.batch"
NATIVE_STDOUT="$WORKDIR/native.stdout"
NATIVE_STDERR="$WORKDIR/native.stderr"
SOURCE_STDOUT="$WORKDIR/source.stdout"
SOURCE_STDERR="$WORKDIR/source.stderr"
EVIDENCE="$WORKDIR/evidence.tsv"
RAW_IMAGE="$ROOT/target/embedded-stdlib-tlci/stdlib.tlci"
HEAVY_DISPATCHES=16000
LIGHT_DISPATCHES=2501
ROW_COUNT=5
TLCI_NATIVE_ROUTE_TIME_BIN=${TLCI_NATIVE_ROUTE_TIME_BIN:-/usr/bin/time}

TYPELISP_TLCI_NATIVE_ROUTE_STRESS=1
export TYPELISP_TLCI_NATIVE_ROUTE_STRESS

rm -rf "$WORKDIR"
mkdir -p "$NATIVE_CWD" "$SOURCE_ROOT/stdlib" "$NATIVE_DIR" "$SOURCE_DIR"

finalize_record() {
    record_source=$NATIVE_STDERR
    if [ "$NL_HOST_OS" = windows ]; then
        record_source="$WINDOWS_MEMORY_DIR/stderr.log"
    fi
    if [ -f "$record_source" ]; then
        grep '^tlci-native-stress|' "$record_source" |
            tail -n 1 > "$WORKDIR/final-record.txt" || true
    fi
}
trap finalize_record EXIT

fail() {
    echo "[tlci-native-route-stress] $*" >&2
    exit 1
}

batch_path() {
    if [ "$NL_HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

read_u64_le() {
    od -An -tu8 -j "$2" -N 8 "$1" | tr -d ' \r\n'
}

capture_now_ms() {
    ci_timing_set_now_ms
    CAPTURED_NOW_MS=$CI_TIMING_NOW_MS
}

[ -s "$RAW_IMAGE" ] ||
    fail "raw embedded image is missing; run verify-compile-profile.sh first"
REPOSITORY_IDENTITY=$(git rev-parse --verify HEAD 2>/dev/null || true)
COMPILER_IDENTITY=$($COMPILER --producer-identity 2>/dev/null | tr -d '\r\n')
IDENTITY_OFFSET=$(read_u64_le "$RAW_IMAGE" 32)
IDENTITY_LENGTH=$(read_u64_le "$RAW_IMAGE" 40)
case "$IDENTITY_OFFSET:$IDENTITY_LENGTH" in
    *[!0-9:]* | :* | *:) fail "embedded image has malformed producer identity range" ;;
esac
[ "$IDENTITY_LENGTH" -eq 40 ] ||
    fail "embedded image producer identity length is $IDENTITY_LENGTH, expected 40"
IMAGE_IDENTITY=$(dd if="$RAW_IMAGE" bs=1 skip="$IDENTITY_OFFSET" \
    count="$IDENTITY_LENGTH" 2>/dev/null)
for identity in "$REPOSITORY_IDENTITY" "$COMPILER_IDENTITY" "$IMAGE_IDENTITY"; do
    printf '%s\n' "$identity" | grep -Eq '^[0-9a-f]{40}$' ||
        fail "malformed or unknown producer identity: $identity"
done
[ "$COMPILER_IDENTITY" = "$REPOSITORY_IDENTITY" ] ||
    fail "running compiler identity $COMPILER_IDENTITY does not equal repository $REPOSITORY_IDENTITY"
[ "$IMAGE_IDENTITY" = "$COMPILER_IDENTITY" ] ||
    fail "embedded image identity $IMAGE_IDENTITY does not equal running compiler $COMPILER_IDENTITY"
printf 'repository=%s\ncompiler=%s\nimage=%s\n' \
    "$REPOSITORY_IDENTITY" "$COMPILER_IDENTITY" "$IMAGE_IDENTITY" \
    > "$WORKDIR/producer-identities.txt"

# A comment-only stdlib copy is semantically identical but provenance-distinct,
# forcing the source interpreter without changing expected assembly or
# diagnostics. This is the same fail-closed differential used by the bounded
# route fixtures in verify-compile-profile.sh.
for source_file in "$ROOT"/stdlib/*.tl; do
    {
        sed -n '1,$p' "$source_file"
        echo ";; tlci-native-route-stress-source-control"
    } > "$SOURCE_ROOT/stdlib/$(basename "$source_file")"
done

generate_success_source() {
    output=$1
    dispatches=$2
    cat > "$output" <<'FIXTURE'
(import stdlib.hash)
(import stdlib.text_buf)
(import (hash.hash i64) as stress_hash_i64)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (__tl_make-array i64 1)]
    [buf : text_buf.TextBuf (text_buf.empty)]
    (begin
      (set! (array-ref items 0) 7)
      (text_buf.append! buf "x")
      (__tl-box-place (box 7))
      (and true true)
      (or false true)
      (unless false unit)
FIXTURE
    index=0
    while [ "$index" -lt "$dispatches" ]; do
        # This private projection bridge is the cheapest stable native Expr
        # identity in the measured fixture set. The result is pure and unused,
        # so ordinary optimization removes the expanded field reads while the
        # production macro walk still performs every native dispatch. Keep the
        # formerly sustained identities as explicit probes above.
        printf '%s\n' '      (__tl-project-field buf len)' >> "$output"
        index=$((index + 1))
    done
    cat >> "$output" <<'FIXTURE'
      (if (and
        (= (__tl_array-length items) 1)
        (= (stress_hash_i64.hash (array-ref items 0))
          (stress_hash_i64.hash 7)))
        42
        1))))
FIXTURE
}

: > "$NATIVE_BATCH"
: > "$SOURCE_BATCH"
row=0
while [ "$row" -lt "$ROW_COUNT" ]; do
    source_file="$WORKDIR/row-$row.tl"
    if [ "$row" -eq 0 ]; then
        generate_success_source "$source_file" "$HEAVY_DISPATCHES"
    else
        generate_success_source "$source_file" "$LIGHT_DISPATCHES"
    fi
    printf '%s|%s\n' \
        "$(batch_path "$source_file")" \
        "$(batch_path "$NATIVE_DIR/row-$row.s")" >> "$NATIVE_BATCH"
    printf '%s|%s\n' \
        "$(batch_path "$source_file")" \
        "$(batch_path "$SOURCE_DIR/row-$row.s")" >> "$SOURCE_BATCH"
    row=$((row + 1))
done

TARGET_CFG_ARGS=$(native_target_cfg_args | tr '\n' ' ')
cat > "$WORKDIR/reproduce.txt" <<EOF
native: cd $NATIVE_CWD && TYPELISP_TLCI_NATIVE_ROUTE_STRESS=1 $COMPILER compile --batch $NATIVE_BATCH --target $NL_BOOTSTRAP_TARGET $TARGET_CFG_ARGS--opt-level 2
source: cd $SOURCE_ROOT && TYPELISP_TLCI_NATIVE_ROUTE_STRESS=1 $COMPILER compile --batch $SOURCE_BATCH --target $NL_BOOTSTRAP_TARGET $TARGET_CFG_ARGS--opt-level 2 --stdlib-root stdlib
EOF

echo "[tlci-native-route-stress] native production-route batch"
capture_now_ms
NATIVE_STARTED_MS=$CAPTURED_NOW_MS
NATIVE_STATUS=0
if [ "$NL_HOST_OS" = windows ]; then
    set +e
    (
        cd "$NATIVE_CWD"
        pwsh -NoProfile -File "$ROOT/scripts/measure-compile-batch-memory.ps1" \
            -Compiler "$COMPILER" \
            -Batch "$NATIVE_BATCH" \
            -OutputDir "$WINDOWS_MEMORY_DIR" \
            -Target "$NL_BOOTSTRAP_TARGET" \
            -NoStdlibRoot \
            -OptLevel 2
    ) > "$WORKDIR/native-launch.stdout" 2> "$WORKDIR/native-launch.stderr"
    NATIVE_STATUS=$?
    set -e
    NATIVE_STDOUT="$WINDOWS_MEMORY_DIR/stdout.log"
    NATIVE_STDERR="$WINDOWS_MEMORY_DIR/stderr.log"
else
    [ -x "$TLCI_NATIVE_ROUTE_TIME_BIN" ] ||
        fail "GNU time is required for the native-route RSS report: $TLCI_NATIVE_ROUTE_TIME_BIN"
    if ! "$TLCI_NATIVE_ROUTE_TIME_BIN" -v -o /dev/null true >/dev/null 2>&1; then
        fail "GNU time with -v support is required for the native-route RSS report: $TLCI_NATIVE_ROUTE_TIME_BIN"
    fi
    set +e
    (
        cd "$NATIVE_CWD"
        "$TLCI_NATIVE_ROUTE_TIME_BIN" \
            -f 'wall_seconds=%e\npeak_rss_kb=%M' \
            -o "$WORKDIR/native.time" \
            "$COMPILER" compile --batch "$NATIVE_BATCH" \
                --target "$NL_BOOTSTRAP_TARGET" \
                $(native_target_cfg_args) \
                --opt-level 2
    ) > "$NATIVE_STDOUT" 2> "$NATIVE_STDERR"
    NATIVE_STATUS=$?
    set -e
fi
capture_now_ms
NATIVE_COMPILE_MS=$((CAPTURED_NOW_MS - NATIVE_STARTED_MS))
ci_timing_record_elapsed all native-compile \
    "$NATIVE_COMPILE_MS" "$NATIVE_STATUS"
if [ "$NATIVE_STATUS" -ne 0 ]; then
    finalize_record
    fail "native $NL_HOST_OS batch failed; see $NATIVE_STDERR"
fi
if [ "$NL_HOST_OS" = windows ]; then
    cp "$WINDOWS_MEMORY_DIR/summary.tsv" "$WORKDIR/metrics.tsv"
else
    {
        printf 'host\tmetric\tvalue\n'
        sed -n 's/^\([^=]*\)=\(.*\)$/linux\t\1\t\2/p' "$WORKDIR/native.time"
    } > "$WORKDIR/metrics.tsv"
fi
finalize_record

echo "[tlci-native-route-stress] source-route differential batch"
capture_now_ms
SOURCE_STARTED_MS=$CAPTURED_NOW_MS
set +e
(
    cd "$SOURCE_ROOT"
    "$COMPILER" compile --batch "$SOURCE_BATCH" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --opt-level 2 \
        --stdlib-root stdlib
) > "$SOURCE_STDOUT" 2> "$SOURCE_STDERR"
SOURCE_STATUS=$?
set -e
capture_now_ms
SOURCE_COMPILE_MS=$((CAPTURED_NOW_MS - SOURCE_STARTED_MS))
ci_timing_record_elapsed all source-compile \
    "$SOURCE_COMPILE_MS" "$SOURCE_STATUS"
if [ "$SOURCE_STATUS" -ne 0 ]; then
    fail "source differential batch failed; see $SOURCE_STDERR"
fi

capture_now_ms
COMPARE_STARTED_MS=$CAPTURED_NOW_MS
row=0
while [ "$row" -lt "$ROW_COUNT" ]; do
    cmp "$NATIVE_DIR/row-$row.s" "$SOURCE_DIR/row-$row.s" >/dev/null ||
        fail "native/source assembly differs for successful batch row $row"
    row=$((row + 1))
done
capture_now_ms
ASSEMBLY_COMPARE_MS=$((CAPTURED_NOW_MS - COMPARE_STARTED_MS))

profile_values() {
    awk -F '|' -v phase="typecheck.macro.$1" \
        '$1 == "compile-profile" && $2 == phase { print $3 }' "$2"
}

profile_phase_values() {
    awk -F '|' -v phase="$1" \
        '$1 == "compile-profile" && $2 == phase { print $3 }' "$2"
}

DISPATCH_VALUES=$(profile_values stdlib_tlci_native_dispatches "$NATIVE_STDERR")
DISPATCH_ROWS=$(printf '%s\n' "$DISPATCH_VALUES" | awk 'NF { rows++ } END { print rows + 0 }')
[ "$DISPATCH_ROWS" -eq "$ROW_COUNT" ] ||
    fail "native batch emitted $DISPATCH_ROWS dispatch counter rows, expected $ROW_COUNT"
HEAVY_ACTUAL=$(printf '%s\n' "$DISPATCH_VALUES" | sed -n '1p')
TOTAL_ACTUAL=$(printf '%s\n' "$DISPATCH_VALUES" | awk '{ total += $1 } END { print total + 0 }')
[ "$HEAVY_ACTUAL" -ge 16000 ] ||
    fail "one-pass routed dispatch count is $HEAVY_ACTUAL, expected at least 16000"
[ "$TOTAL_ACTUAL" -gt 25000 ] ||
    fail "aggregate routed dispatch count is $TOTAL_ACTUAL, expected above 25000"

assert_profile_sum_at_least() {
    phase=$1
    minimum=$2
    value=$(profile_values "$phase" "$NATIVE_STDERR" |
        awk '{ total += $1 } END { print total + 0 }')
    [ "$value" -ge "$minimum" ] ||
        fail "profile counter $phase is $value, expected at least $minimum"
}

assert_profile_sum_eq() {
    phase=$1
    wanted=$2
    value=$(profile_values "$phase" "$NATIVE_STDERR" |
        awk '{ total += $1 } END { print total + 0 }')
    [ "$value" -eq "$wanted" ] ||
        fail "profile counter $phase is $value, expected $wanted"
}

assert_profile_sum_at_least stdlib_tlci_native_expr_results 25000
assert_profile_sum_at_least stdlib_tlci_native_module_results "$ROW_COUNT"
assert_profile_sum_at_least stdlib_tlci_native_decls_results "$ROW_COUNT"
# #6550 moved text_buf/append! off the final shell. Sustained production
# routing must now preserve the catalog-wide zero-shell/zero-fallback state.
assert_profile_sum_eq stdlib_tlci_shell_learns 0
assert_profile_sum_eq stdlib_tlci_interpreted_fallbacks 0
assert_profile_sum_at_least stdlib_source_interpreted "$ROW_COUNT"
assert_profile_sum_eq stdlib_tlci_catalog_misses 0
assert_profile_sum_eq stdlib_tlci_load_failures 0

SOURCE_HITS=$(profile_values stdlib_tlci_catalog_hits "$SOURCE_STDERR" |
    awk '{ total += $1 } END { print total + 0 }')
[ "$SOURCE_HITS" -eq 0 ] ||
    fail "source differential unexpectedly used the native catalog $SOURCE_HITS time(s)"

# Compile-profile detail rows already carry a machine-readable identity, arity,
# and call count. Validate exactly one expected pair in every batch entry rather
# than accepting a substring from any row. The compile-profile total row is the
# per-entry boundary; this makes missing and duplicate detail rows fail closed.
macro_profile_counts_valid() {
    profile_file=$1
    macro_identity=$2
    macro_arity=$3
    heavy_calls=$4
    light_calls=$5
    expected_rows=$6
    awk -F '|' \
        -v identity="$macro_identity" \
        -v arity="$macro_arity" \
        -v heavy="$heavy_calls" \
        -v light="$light_calls" \
        -v rows="$expected_rows" '
        BEGIN { program = 0 }
        $1 == "compile-profile-detail" && $2 == "typecheck.macro_expand" {
            prefix = identity " arity=" arity " calls="
            if (index($4, prefix) == 1) {
                seen[program]++
                wanted = program == 0 ? heavy : light
                if ($4 != prefix wanted) bad = 1
            }
        }
        $1 == "compile-profile" && $2 == "total" { program++ }
        END {
            if (program != rows) bad = 1
            for (row = 0; row < rows; row++) {
                if (seen[row] != 1) bad = 1
            }
            exit bad ? 1 : 0
        }
    ' "$profile_file"
}

assert_macro_profile_counts() {
    if ! macro_profile_counts_valid "$@"; then
        fail "profile identity/arity counts changed for $2 arity=$3"
    fi
}

verify_macro_profile_counter() {
    good="$WORKDIR/profile-counter-good.txt"
    missing="$WORKDIR/profile-counter-missing.txt"
    duplicate="$WORKDIR/profile-counter-duplicate.txt"
    wrong="$WORKDIR/profile-counter-wrong.txt"
    cat > "$good" <<'EOF'
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=9
compile-profile|total|1|0|0|0
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=3
compile-profile|total|1|0|0|0
EOF
    cat > "$missing" <<'EOF'
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=9
compile-profile|total|1|0|0|0
compile-profile|total|1|0|0|0
EOF
    cat > "$duplicate" <<'EOF'
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=9
compile-profile|total|1|0|0|0
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=3
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=3
compile-profile|total|1|0|0|0
EOF
    cat > "$wrong" <<'EOF'
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=1 calls=9
compile-profile|total|1|0|0|0
compile-profile-detail|typecheck.macro_expand|0|stdlib.test/probe arity=2 calls=4
compile-profile|total|1|0|0|0
EOF
    macro_profile_counts_valid \
        "$good" stdlib.test/probe 2 9 3 2 ||
        fail "exact profile counter rejected its valid control"
    for malformed in "$missing" "$duplicate" "$wrong"; do
        if macro_profile_counts_valid \
            "$malformed" stdlib.test/probe 2 9 3 2; then
            fail "exact profile counter accepted malformed input: $malformed"
        fi
    done
}

verify_macro_profile_counter
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.core_macros/__tl-project-field 2 \
    "$HEAVY_DISPATCHES" "$LIGHT_DISPATCHES" "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.core_macros/__tl-box-place 1 1 1 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.core_macros/and 2 71 71 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.core_macros/or 2 14 14 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.core_macros/unless 2 1 1 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.hash/hash 1 1 1 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.text_buf_family/owned 0 1 1 "$ROW_COUNT"
assert_macro_profile_counts \
    "$NATIVE_STDERR" stdlib.text_buf/append! 2 1 1 "$ROW_COUNT"

RECORDS="$WORKDIR/progress-records.txt"
grep '^tlci-native-stress|' "$NATIVE_STDERR" > "$RECORDS" ||
    fail "stress-enabled compiler emitted no durable progress records"
if ! awk -F '|' '
    BEGIN {
        names[2] = "pass"; widths[2] = 6
        names[3] = "dispatch"; widths[3] = 12
        names[4] = "total"; widths[4] = 12
        names[5] = "catalog"; widths[5] = 8
        names[6] = "identity"; widths[6] = 6
        names[7] = "route"; widths[7] = 3
        names[8] = "result"; widths[8] = 3
        names[9] = "status"; widths[9] = 3
        names[10] = "expr"; widths[10] = 12
        names[11] = "type"; widths[11] = 12
        names[12] = "poolgen"; widths[12] = 12
        names[13] = "image"; widths[13] = 8
        names[14] = "release"; widths[14] = 8
        names[15] = "session"; widths[15] = 12
        names[16] = "canary"; widths[16] = 2
    }
    {
        if ($1 != "tlci-native-stress" || NF != 16) bad = 1
        if (NR == 1) record_len = length($0)
        if (length($0) != record_len) bad = 1
        for (i = 2; i <= 16; i++) {
            count = split($i, pair, "=")
            if (count != 2 || pair[1] != names[i] ||
                length(pair[2]) != widths[i] || pair[2] !~ /^[0-9]+$/) bad = 1
        }
        if ($16 != "canary=11") bad = 1
        rows++
    }
    END { exit rows > 0 && !bad ? 0 : 1 }
' "$RECORDS"; then
    fail "durable progress records violate the fixed-width schema or canaries"
fi

START_RECORDS=$(awk -F '|' '$8 == "result=000" { n++ } END { print n + 0 }' "$RECORDS")
END_RECORDS=$(awk -F '|' '$8 == "result=006" { n++ } END { print n + 0 }' "$RECORDS")
[ "$START_RECORDS" -eq "$ROW_COUNT" ] ||
    fail "expected $ROW_COUNT pass-start records, got $START_RECORDS"
[ "$END_RECORDS" -eq "$ROW_COUNT" ] ||
    fail "expected $ROW_COUNT pass-end records, got $END_RECORDS"
# Native Expr, Module, and Decls commits must all appear. Result 004 was the
# learned-shell marker; #6550's zero-shell end state makes its presence a
# regression rather than a required coverage point.
for result in 001 002 003; do
    grep -F "|result=$result|" "$RECORDS" >/dev/null ||
        fail "durable records never observed result kind $result"
done
if grep -F '|result=004|' "$RECORDS" >/dev/null; then
    fail "durable records observed a learned fallback shell"
fi
grep -F '|dispatch=000000013552|' "$RECORDS" >/dev/null ||
    fail "durable records missed the historical 13,552-dispatch boundary"
UNIQUE_IDENTITIES=$(awk -F '|' '
    $8 != "result=000" && $8 != "result=006" {
        split($6, pair, "=")
        if (pair[2] != "999999") seen[pair[2]] = 1
    }
    END { for (key in seen) count++; print count + 0 }
' "$RECORDS")
# The former append! shell forced a result-004 record for a fifth identity.
# Fully native Expr results are sampled at fixed dispatch boundaries instead;
# require the four independently sampled identities here, while the explicit
# profile row below proves append!'s own native identity/arity.
[ "$UNIQUE_IDENTITIES" -ge 4 ] ||
    fail "stress observed only $UNIQUE_IDENTITIES stable identity indexes, expected at least 4"

if ! awk -F '|' -v rows="$ROW_COUNT" '
    $8 == "result=006" {
        split($2, pass, "=")
        split($3, dispatch, "=")
        split($4, total, "=")
        split($13, image, "=")
        split($14, release, "=")
        split($15, session, "=")
        ends++
        if ((pass[2] + 0) == 1 && (dispatch[2] + 0) < 16000) bad = 1
        final_pass = pass[2] + 0
        final_total = total[2] + 0
        final_image = image[2] + 0
        final_release = release[2] + 0
        final_session = session[2] + 0
    }
    END {
        exit ends == rows && final_pass == rows && final_total > 25000 &&
            final_image >= rows && final_release >= rows &&
            final_session > 25000 && !bad ? 0 : 1
    }
' "$RECORDS"; then
    fail "pass/reset/map/session lifecycle totals did not cross required bounds"
fi

generate_failure_source() {
    case_name=$1
    output=$2
    case "$case_name" in
        unmatched-open)
            template='"a{"'
            arguments=
            ;;
        too-many-arguments)
            template='"{}"'
            arguments=' one two'
            ;;
        *) fail "unknown failure fixture: $case_name" ;;
    esac
    cat > "$output" <<EOF
(import stdlib.format)
(import stdlib.io)
(define one : i64 1)
(define two : i64 2)
(define (main) : i64
  (begin
    (io.print-format "{}" (format.format $template$arguments))
    0))
EOF
}

filter_diagnostic() {
    grep -v -E '^(compile-profile|compile-batch-profile|tlci-native-stress)' "$1" |
        sed '/^[[:space:]]*$/d' > "$2"
}

capture_now_ms
DIAGNOSTIC_STARTED_MS=$CAPTURED_NOW_MS
for case_name in unmatched-open too-many-arguments; do
    failure_source="$WORKDIR/failure-$case_name.tl"
    generate_failure_source "$case_name" "$failure_source"
    native_failure_batch="$WORKDIR/failure-$case_name-native.batch"
    source_failure_batch="$WORKDIR/failure-$case_name-source.batch"
    printf '%s|%s\n' "$(batch_path "$failure_source")" \
        "$(batch_path "$WORKDIR/failure-$case_name-native.s")" > "$native_failure_batch"
    printf '%s|%s\n' "$(batch_path "$failure_source")" \
        "$(batch_path "$WORKDIR/failure-$case_name-source.s")" > "$source_failure_batch"
    set +e
    (
        cd "$NATIVE_CWD"
        "$COMPILER" compile --batch "$native_failure_batch" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --opt-level 2
    ) > "$WORKDIR/failure-$case_name-native.stdout" \
        2> "$WORKDIR/failure-$case_name-native.stderr"
    native_status=$?
    (
        cd "$SOURCE_ROOT"
        "$COMPILER" compile --batch "$source_failure_batch" \
            --target "$NL_BOOTSTRAP_TARGET" \
            $(native_target_cfg_args) \
            --opt-level 2 --stdlib-root stdlib
    ) > "$WORKDIR/failure-$case_name-source.stdout" \
        2> "$WORKDIR/failure-$case_name-source.stderr"
    source_status=$?
    set -e
    [ "$native_status" -ne 0 ] && [ "$source_status" -ne 0 ] ||
        fail "$case_name did not fail on both routes: native=$native_status source=$source_status"
    grep -F '|result=005|' "$WORKDIR/failure-$case_name-native.stderr" >/dev/null ||
        fail "$case_name did not reach a native error result"
    filter_diagnostic "$WORKDIR/failure-$case_name-native.stderr" \
        "$WORKDIR/failure-$case_name-native.diag"
    filter_diagnostic "$WORKDIR/failure-$case_name-source.stderr" \
        "$WORKDIR/failure-$case_name-source.diag"
    cmp "$WORKDIR/failure-$case_name-native.diag" \
        "$WORKDIR/failure-$case_name-source.diag" >/dev/null ||
        fail "$case_name native/source diagnostics differ"
done
capture_now_ms
DIAGNOSTIC_MS=$((CAPTURED_NOW_MS - DIAGNOSTIC_STARTED_MS))

NATIVE_BACKEND_VALUES=$(profile_phase_values backend "$NATIVE_STDERR")
SOURCE_BACKEND_VALUES=$(profile_phase_values backend "$SOURCE_STDERR")
NATIVE_BACKEND_ROWS=$(printf '%s\n' "$NATIVE_BACKEND_VALUES" |
    awk 'NF { rows++ } END { print rows + 0 }')
SOURCE_BACKEND_ROWS=$(printf '%s\n' "$SOURCE_BACKEND_VALUES" |
    awk 'NF { rows++ } END { print rows + 0 }')
[ "$NATIVE_BACKEND_ROWS" -eq "$ROW_COUNT" ] ||
    fail "native batch emitted $NATIVE_BACKEND_ROWS backend rows, expected $ROW_COUNT"
[ "$SOURCE_BACKEND_ROWS" -eq "$ROW_COUNT" ] ||
    fail "source batch emitted $SOURCE_BACKEND_ROWS backend rows, expected $ROW_COUNT"

TOTAL_SOURCE_BYTES=0
TOTAL_NATIVE_ASSEMBLY_BYTES=0
TOTAL_SOURCE_ASSEMBLY_BYTES=0
TOTAL_NATIVE_BACKEND_MS=0
TOTAL_SOURCE_BACKEND_MS=0
{
    printf 'scope\trow\tmetric\tvalue\tunit\thost\n'
    printf 'phase\tall\tnative_compile_elapsed\t%s\tms\t%s\n' \
        "$NATIVE_COMPILE_MS" "$NL_HOST_OS"
    printf 'phase\tall\tsource_compile_elapsed\t%s\tms\t%s\n' \
        "$SOURCE_COMPILE_MS" "$NL_HOST_OS"
    printf 'phase\tall\tassembly_compare_elapsed\t%s\tms\t%s\n' \
        "$ASSEMBLY_COMPARE_MS" "$NL_HOST_OS"
    printf 'phase\tall\tdiagnostic_controls_elapsed\t%s\tms\t%s\n' \
        "$DIAGNOSTIC_MS" "$NL_HOST_OS"
    row=0
    while [ "$row" -lt "$ROW_COUNT" ]; do
        source_bytes=$(wc -c < "$WORKDIR/row-$row.tl" | tr -d ' ')
        native_assembly_bytes=$(wc -c < "$NATIVE_DIR/row-$row.s" | tr -d ' ')
        source_assembly_bytes=$(wc -c < "$SOURCE_DIR/row-$row.s" | tr -d ' ')
        profile_row=$((row + 1))
        native_backend_ms=$(printf '%s\n' "$NATIVE_BACKEND_VALUES" |
            sed -n "${profile_row}p")
        source_backend_ms=$(printf '%s\n' "$SOURCE_BACKEND_VALUES" |
            sed -n "${profile_row}p")
        printf 'row\t%s\tgenerated_source_bytes\t%s\tbytes\t%s\n' \
            "$row" "$source_bytes" "$NL_HOST_OS"
        printf 'row\t%s\tnative_assembly_bytes\t%s\tbytes\t%s\n' \
            "$row" "$native_assembly_bytes" "$NL_HOST_OS"
        printf 'row\t%s\tsource_assembly_bytes\t%s\tbytes\t%s\n' \
            "$row" "$source_assembly_bytes" "$NL_HOST_OS"
        printf 'row\t%s\tnative_main_backend_elapsed\t%s\tms\t%s\n' \
            "$row" "$native_backend_ms" "$NL_HOST_OS"
        printf 'row\t%s\tsource_main_backend_elapsed\t%s\tms\t%s\n' \
            "$row" "$source_backend_ms" "$NL_HOST_OS"
        TOTAL_SOURCE_BYTES=$((TOTAL_SOURCE_BYTES + source_bytes))
        TOTAL_NATIVE_ASSEMBLY_BYTES=$((
            TOTAL_NATIVE_ASSEMBLY_BYTES + native_assembly_bytes))
        TOTAL_SOURCE_ASSEMBLY_BYTES=$((
            TOTAL_SOURCE_ASSEMBLY_BYTES + source_assembly_bytes))
        TOTAL_NATIVE_BACKEND_MS=$((TOTAL_NATIVE_BACKEND_MS + native_backend_ms))
        TOTAL_SOURCE_BACKEND_MS=$((TOTAL_SOURCE_BACKEND_MS + source_backend_ms))
        row=$((row + 1))
    done
    printf 'aggregate\tall\tgenerated_source_bytes\t%s\tbytes\t%s\n' \
        "$TOTAL_SOURCE_BYTES" "$NL_HOST_OS"
    printf 'aggregate\tall\tnative_assembly_bytes\t%s\tbytes\t%s\n' \
        "$TOTAL_NATIVE_ASSEMBLY_BYTES" "$NL_HOST_OS"
    printf 'aggregate\tall\tsource_assembly_bytes\t%s\tbytes\t%s\n' \
        "$TOTAL_SOURCE_ASSEMBLY_BYTES" "$NL_HOST_OS"
    printf 'aggregate\tall\tnative_main_backend_elapsed\t%s\tms\t%s\n' \
        "$TOTAL_NATIVE_BACKEND_MS" "$NL_HOST_OS"
    printf 'aggregate\tall\tsource_main_backend_elapsed\t%s\tms\t%s\n' \
        "$TOTAL_SOURCE_BACKEND_MS" "$NL_HOST_OS"
} > "$EVIDENCE"

evidence_valid() {
    evidence_file=$1
    awk -F '\t' -v rows="$ROW_COUNT" -v host="$NL_HOST_OS" '
    BEGIN {
        phase["native_compile_elapsed"] = "ms"
        phase["source_compile_elapsed"] = "ms"
        phase["assembly_compare_elapsed"] = "ms"
        phase["diagnostic_controls_elapsed"] = "ms"
        metric["generated_source_bytes"] = "bytes"
        metric["native_assembly_bytes"] = "bytes"
        metric["source_assembly_bytes"] = "bytes"
        metric["native_main_backend_elapsed"] = "ms"
        metric["source_main_backend_elapsed"] = "ms"
    }
    NR == 1 {
        if ($0 != "scope\trow\tmetric\tvalue\tunit\thost") bad = 1
        next
    }
    {
        if (NF != 6 || $4 !~ /^[0-9]+$/ || $6 != host) bad = 1
        if ($1 == "phase") {
            if ($2 != "all" || !($3 in phase) || $5 != phase[$3]) bad = 1
            phase_seen[$3]++
        } else if ($1 == "row") {
            if ($2 !~ /^[0-9]+$/ || ($2 + 0) >= rows ||
                !($3 in metric) || $5 != metric[$3]) bad = 1
            row_seen[$2, $3]++
        } else if ($1 == "aggregate") {
            if ($2 != "all" || !($3 in metric) || $5 != metric[$3]) bad = 1
            aggregate_seen[$3]++
        } else {
            bad = 1
        }
    }
    END {
        for (name in phase) if (phase_seen[name] != 1) bad = 1
        for (name in metric) {
            if (aggregate_seen[name] != 1) bad = 1
            for (row = 0; row < rows; row++) {
                if (row_seen[row, name] != 1) bad = 1
            }
        }
        exit bad ? 1 : 0
    }
' "$evidence_file"
}

if ! evidence_valid "$EVIDENCE"; then
    fail "evidence artifact violates its required phase/row schema"
fi

verify_evidence_schema() {
    duplicate="$WORKDIR/evidence-duplicate.tsv"
    missing="$WORKDIR/evidence-missing.tsv"
    malformed="$WORKDIR/evidence-malformed.tsv"
    awk 'NR == 2 { print } { print }' "$EVIDENCE" > "$duplicate"
    awk -F '\t' \
        '$1 != "aggregate" || $3 != "native_assembly_bytes"' \
        "$EVIDENCE" > "$missing"
    awk -F '\t' 'BEGIN { OFS = "\t" } NR == 2 { $4 = "bad" } { print }' \
        "$EVIDENCE" > "$malformed"
    for invalid_evidence in "$duplicate" "$missing" "$malformed"; do
        if evidence_valid "$invalid_evidence"; then
            fail "evidence checker accepted malformed input: $invalid_evidence"
        fi
    done
}

verify_evidence_schema
scripts/check-tlci-native-route-size.sh "$EVIDENCE"
ci_timing_record_elapsed all native-main-backend \
    "$TOTAL_NATIVE_BACKEND_MS" 0
ci_timing_record_elapsed all source-main-backend \
    "$TOTAL_SOURCE_BACKEND_MS" 0

echo "[tlci-native-route-stress] producer identity exact: $COMPILER_IDENTITY"
echo "[tlci-native-route-stress] dispatches one-pass=$HEAVY_ACTUAL total=$TOTAL_ACTUAL rows=$ROW_COUNT identities=$UNIQUE_IDENTITIES"
echo "[tlci-native-route-stress] native assembly bytes=$TOTAL_NATIVE_ASSEMBLY_BYTES backend-ms=$TOTAL_NATIVE_BACKEND_MS"
echo "[tlci-native-route-stress] assembly and failure-diagnostic parity passed"
echo "[tlci-native-route-stress] metrics: $WORKDIR/metrics.tsv"
echo "[tlci-native-route-stress] evidence: $EVIDENCE"
echo "[tlci-native-route-stress] final record: $WORKDIR/final-record.txt"
