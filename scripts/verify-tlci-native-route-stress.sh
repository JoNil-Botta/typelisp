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
RAW_IMAGE="$ROOT/target/embedded-stdlib-tlci/stdlib.tlci"
HEAVY_DISPATCHES=16000
LIGHT_DISPATCHES=2501
ROW_COUNT=5

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
(import stdlib.array)
(import stdlib.hash)
(import stdlib.text_buf)
(import (hash.hash i64) as stress_hash_i64)

(define (main) : i64
  (let
    [items : (__tl_dyn-array i64) (array.make-array i64 1)]
    [buf : text_buf.TextBuf (text_buf.empty)]
    (begin
      (set! (array-ref items 0) 7)
      (text_buf.append! buf "x")
FIXTURE
    index=0
    while [ "$index" -lt "$dispatches" ]; do
        case $((index % 4)) in
            0) printf '%s\n' '      (array.length items)' >> "$output" ;;
            1) printf '%s\n' '      (array.ref items 0)' >> "$output" ;;
            2) printf '%s\n' '      (and true true)' >> "$output" ;;
            3) printf '%s\n' '      (or false true)' >> "$output" ;;
        esac
        index=$((index + 1))
    done
    cat >> "$output" <<'FIXTURE'
      (if (and
        (= (array.length items) 1)
        (= (stress_hash_i64.hash (array.ref items 0))
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

cat > "$WORKDIR/reproduce.txt" <<EOF
native: TYPELISP_TLCI_NATIVE_ROUTE_STRESS=1 $COMPILER compile --batch $NATIVE_BATCH --target $NL_BOOTSTRAP_TARGET --opt-level 2
source: TYPELISP_TLCI_NATIVE_ROUTE_STRESS=1 $COMPILER compile --batch $SOURCE_BATCH --target $NL_BOOTSTRAP_TARGET --opt-level 2 --stdlib-root $SOURCE_ROOT/stdlib
EOF

echo "[tlci-native-route-stress] native production-route batch"
if [ "$NL_HOST_OS" = windows ]; then
    if ! (
        cd "$NATIVE_CWD"
        pwsh -NoProfile -File "$ROOT/scripts/measure-compile-batch-memory.ps1" \
            -Compiler "$COMPILER" \
            -Batch "$NATIVE_BATCH" \
            -OutputDir "$WINDOWS_MEMORY_DIR" \
            -Target "$NL_BOOTSTRAP_TARGET" \
            -NoStdlibRoot \
            -OptLevel 2
    ) > "$WORKDIR/native-launch.stdout" 2> "$WORKDIR/native-launch.stderr"; then
        finalize_record
        fail "native Windows batch failed; see $WINDOWS_MEMORY_DIR/stderr.log"
    fi
    NATIVE_STDOUT="$WINDOWS_MEMORY_DIR/stdout.log"
    NATIVE_STDERR="$WINDOWS_MEMORY_DIR/stderr.log"
    cp "$WINDOWS_MEMORY_DIR/summary.tsv" "$WORKDIR/metrics.tsv"
else
    if ! (
        cd "$NATIVE_CWD"
        /usr/bin/time \
            -f 'wall_seconds=%e\npeak_rss_kb=%M' \
            -o "$WORKDIR/native.time" \
            "$COMPILER" compile --batch "$NATIVE_BATCH" \
                --target "$NL_BOOTSTRAP_TARGET" \
                $(native_target_cfg_args) \
                --opt-level 2
    ) > "$NATIVE_STDOUT" 2> "$NATIVE_STDERR"; then
        finalize_record
        fail "native Linux batch failed; see $NATIVE_STDERR"
    fi
    {
        printf 'host\tmetric\tvalue\n'
        sed -n 's/^\([^=]*\)=\(.*\)$/linux\t\1\t\2/p' "$WORKDIR/native.time"
    } > "$WORKDIR/metrics.tsv"
fi
finalize_record

echo "[tlci-native-route-stress] source-route differential batch"
if ! (
    cd "$SOURCE_ROOT"
    "$COMPILER" compile --batch "$SOURCE_BATCH" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --opt-level 2 \
        --stdlib-root stdlib
) > "$SOURCE_STDOUT" 2> "$SOURCE_STDERR"; then
    fail "source differential batch failed; see $SOURCE_STDERR"
fi

row=0
while [ "$row" -lt "$ROW_COUNT" ]; do
    cmp "$NATIVE_DIR/row-$row.s" "$SOURCE_DIR/row-$row.s" >/dev/null ||
        fail "native/source assembly differs for successful batch row $row"
    row=$((row + 1))
done

profile_values() {
    awk -F '|' -v phase="typecheck.macro.$1" \
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
assert_profile_sum_at_least stdlib_tlci_shell_learns "$ROW_COUNT"
assert_profile_sum_at_least stdlib_tlci_interpreted_fallbacks "$ROW_COUNT"
assert_profile_sum_at_least stdlib_source_interpreted "$ROW_COUNT"
assert_profile_sum_eq stdlib_tlci_catalog_misses 0
assert_profile_sum_eq stdlib_tlci_load_failures 0

SOURCE_HITS=$(profile_values stdlib_tlci_catalog_hits "$SOURCE_STDERR" |
    awk '{ total += $1 } END { print total + 0 }')
[ "$SOURCE_HITS" -eq 0 ] ||
    fail "source differential unexpectedly used the native catalog $SOURCE_HITS time(s)"

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
for result in 002 003 004; do
    grep -F "|result=$result|" "$RECORDS" >/dev/null ||
        fail "durable records never observed result kind $result"
done
grep -F '|dispatch=000000013552|' "$RECORDS" >/dev/null ||
    fail "durable records missed the historical 13,552-dispatch boundary"
UNIQUE_IDENTITIES=$(awk -F '|' '
    $8 != "result=000" && $8 != "result=006" {
        split($6, pair, "=")
        if (pair[2] != "999999") seen[pair[2]] = 1
    }
    END { for (key in seen) count++; print count + 0 }
' "$RECORDS")
[ "$UNIQUE_IDENTITIES" -ge 5 ] ||
    fail "stress observed only $UNIQUE_IDENTITIES stable identity indexes, expected at least 5"

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

for identity in \
    'stdlib.array/length arity=1' \
    'stdlib.array/ref arity=2' \
    'stdlib.core_macros/and arity=' \
    'stdlib.core_macros/or arity=' \
    'stdlib.hash/hash arity=1' \
    'stdlib.text_buf_family/owned arity=0' \
    'stdlib.text_buf/append! arity=2'; do
    grep -F "$identity" "$NATIVE_STDERR" >/dev/null ||
        fail "profile output did not prove intended identity/arity: $identity"
done

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
    (io.print-string (format.format $template$arguments))
    0))
EOF
}

filter_diagnostic() {
    grep -v -E '^(compile-profile|compile-batch-profile|tlci-native-stress)' "$1" |
        sed '/^[[:space:]]*$/d' > "$2"
}

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

echo "[tlci-native-route-stress] producer identity exact: $COMPILER_IDENTITY"
echo "[tlci-native-route-stress] dispatches one-pass=$HEAVY_ACTUAL total=$TOTAL_ACTUAL rows=$ROW_COUNT identities=$UNIQUE_IDENTITIES"
echo "[tlci-native-route-stress] assembly and failure-diagnostic parity passed"
echo "[tlci-native-route-stress] metrics: $WORKDIR/metrics.tsv"
echo "[tlci-native-route-stress] final record: $WORKDIR/final-record.txt"
