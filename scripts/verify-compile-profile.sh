#!/usr/bin/env sh
set -eu

# verify-compile-profile.sh - smoke compile-profile detail output.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

. "$ROOT/scripts/lib-native-link.sh"
native_link_detect_host
configure_toolchain

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac

if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
fi

WORKDIR="$ROOT/target/compile-profile-verify/$NL_HOST_OS"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

PROFILE_ASM="$WORKDIR/typelisp-profile.s"
PROFILE_OBJ="$WORKDIR/typelisp-profile.$NL_OBJ_EXT"
PROFILE_BIN="$WORKDIR/typelisp-profile$NL_BIN_EXT"
SUMMARY_ASM="$WORKDIR/typelisp-summary.s"
SUMMARY_OBJ="$WORKDIR/typelisp-summary.$NL_OBJ_EXT"
SUMMARY_BIN="$WORKDIR/typelisp-summary$NL_BIN_EXT"
SUMMARY_BUILD_STDOUT="$WORKDIR/summary-build.stdout"
SUMMARY_BUILD_STDERR="$WORKDIR/summary-build.stderr"
SUMMARY_CHECK_STDOUT="$WORKDIR/summary-check.stdout"
SUMMARY_CHECK_STDERR="$WORKDIR/summary-check.stderr"
SUMMARY_OUTPUT_ASM="$WORKDIR/summary-output.s"
NORMAL_CHECK_STDOUT="$WORKDIR/normal-check.stdout"
NORMAL_CHECK_STDERR="$WORKDIR/normal-check.stderr"
NORMAL_OUTPUT_ASM="$WORKDIR/normal-output.s"
PEAK_RESET_STDOUT="$WORKDIR/profile-peak-reset.stdout"
PEAK_RESET_STDERR="$WORKDIR/profile-peak-reset.stderr"
BUILD_STDOUT="$WORKDIR/profile-build.stdout"
BUILD_STDERR="$WORKDIR/profile-build.stderr"
CHECK_STDOUT="$WORKDIR/profile-check.stdout"
CHECK_STDERR="$WORKDIR/profile-check.stderr"
STDLIB_TLCI_DIR="$WORKDIR/stdlib-tlci-dispatch"
STDLIB_TLCI_EMBEDDED_ASM="$STDLIB_TLCI_DIR/embedded.s"
STDLIB_TLCI_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/embedded.stdout"
STDLIB_TLCI_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/embedded.stderr"
STDLIB_TLCI_SOURCE_ASM="$STDLIB_TLCI_DIR/source.s"
STDLIB_TLCI_SOURCE_STDOUT="$STDLIB_TLCI_DIR/source.stdout"
STDLIB_TLCI_SOURCE_STDERR="$STDLIB_TLCI_DIR/source.stderr"
VECTOR_CORE_STDOUT="$WORKDIR/profile-vector-core.stdout"
VECTOR_CORE_STDERR="$WORKDIR/profile-vector-core.stderr"
VECTOR_FULL_STDOUT="$WORKDIR/profile-vector-full.stdout"
VECTOR_FULL_STDERR="$WORKDIR/profile-vector-full.stderr"
VECTOR_ONE_ASM="$WORKDIR/profile-vector-one.s"
VECTOR_ONE_STDOUT="$WORKDIR/profile-vector-one.stdout"
VECTOR_ONE_STDERR="$WORKDIR/profile-vector-one.stderr"
VECTOR_FIVE_ASM="$WORKDIR/profile-vector-five.s"
VECTOR_FIVE_STDOUT="$WORKDIR/profile-vector-five.stdout"
VECTOR_FIVE_STDERR="$WORKDIR/profile-vector-five.stderr"
GEN_IMPORT_STDOUT="$WORKDIR/profile-generated-import.stdout"
GEN_IMPORT_STDERR="$WORKDIR/profile-generated-import.stderr"
RESULT_IMPORT_STDOUT="$WORKDIR/profile-result-import.stdout"
RESULT_IMPORT_STDERR="$WORKDIR/profile-result-import.stderr"
CROSS_SINGLE_STDOUT="$WORKDIR/profile-cross-single.stdout"
CROSS_SINGLE_STDERR="$WORKDIR/profile-cross-single.stderr"
GEN_IMPORT_INERT_STDOUT="$WORKDIR/profile-generated-import-inert.stdout"
GEN_IMPORT_INERT_STDERR="$WORKDIR/profile-generated-import-inert.stderr"
REPLAY_STDOUT="$WORKDIR/profile-generated-replay.stdout"
REPLAY_STDERR="$WORKDIR/profile-generated-replay.stderr"
LAYOUT_STDOUT="$WORKDIR/profile-layout.stdout"
LAYOUT_STDERR="$WORKDIR/profile-layout.stderr"
CONCAT_ASM="$WORKDIR/profile-string-concat.s"
CONCAT_STDOUT="$WORKDIR/profile-string-concat.stdout"
CONCAT_STDERR="$WORKDIR/profile-string-concat.stderr"
OPT_ASM="$WORKDIR/profile-opt.s"
OPT_STDOUT="$WORKDIR/profile-opt.stdout"
OPT_STDERR="$WORKDIR/profile-opt.stderr"
SELFHOST_ASM="$WORKDIR/profile-selfhost.s"
SELFHOST_STDOUT="$WORKDIR/profile-selfhost.stdout"
SELFHOST_STDERR="$WORKDIR/profile-selfhost.stderr"
BATCH_LIST="$WORKDIR/profile-batch.txt"
BATCH_STDOUT="$WORKDIR/profile-batch.stdout"
BATCH_STDERR="$WORKDIR/profile-batch.stderr"
BATCH_ARITH="$WORKDIR/profile-batch-arithmetic.s"
BATCH_FUNCTIONS="$WORKDIR/profile-batch-functions.s"
BATCH_SINGLE_ARITH="$WORKDIR/profile-single-arithmetic.s"
BATCH_SINGLE_FUNCTIONS="$WORKDIR/profile-single-functions.s"
BATCH_SINGLE_STDOUT="$WORKDIR/profile-single.stdout"
BATCH_SINGLE_STDERR="$WORKDIR/profile-single.stderr"
NORMAL_BATCH_LIST="$WORKDIR/normal-batch.txt"
NORMAL_BATCH_STDOUT="$WORKDIR/normal-batch.stdout"
NORMAL_BATCH_STDERR="$WORKDIR/normal-batch.stderr"
NORMAL_BATCH_ARITH="$WORKDIR/normal-batch-arithmetic.s"
NORMAL_BATCH_FUNCTIONS="$WORKDIR/normal-batch-functions.s"
WINDOWS_MEMORY_DIR="$WORKDIR/windows-memory"
FAILED_BATCH_LIST="$WORKDIR/failed-batch.txt"
FAILED_BATCH_STDOUT="$WORKDIR/failed-batch.stdout"
FAILED_BATCH_STDERR="$WORKDIR/failed-batch.stderr"
FAILED_BATCH_FIRST="$WORKDIR/failed-batch-first.s"
FAILED_BATCH_SECOND="$WORKDIR/missing/failed-batch-second.s"

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

batch_path() {
    if [ "$NL_HOST_OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        printf '%s\n' "$1"
    fi
}

show_failure_logs() {
    _stdout=$1
    _stderr=$2
    echo "stdout:" >&2
    sed 's/^/  /' "$_stdout" >&2 || true
    echo "stderr:" >&2
    sed 's/^/  /' "$_stderr" >&2 || true
}

assert_contains_in() {
    _file=$1
    _text=$2
    _stdout=$3
    _stderr=$4
    if ! grep -F -- "$_text" "$_file" >/dev/null; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "missing expected profile text: $_text"
    fi
}

assert_contains() {
    assert_contains_in "$1" "$2" "$CHECK_STDOUT" "$CHECK_STDERR"
}

assert_not_contains_in() {
    _file=$1
    _text=$2
    _stdout=$3
    _stderr=$4
    if grep -F -- "$_text" "$_file" >/dev/null; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "unexpected profile text: $_text"
    fi
}

assert_not_contains() {
    assert_not_contains_in "$1" "$2" "$CHECK_STDOUT" "$CHECK_STDERR"
}

assert_line_count_in() {
    _file=$1
    _text=$2
    _want=$3
    _stdout=$4
    _stderr=$5
    _got=$(grep -F -- "$_text" "$_file" | wc -l | tr -d '[:space:]')
    if [ "$_got" != "$_want" ]; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected $_want profile rows for: $_text; got $_got"
    fi
}

assert_line_count_at_most_in() {
    _file=$1
    _text=$2
    _max=$3
    _stdout=$4
    _stderr=$5
    _got=$(grep -F -- "$_text" "$_file" | wc -l | tr -d '[:space:]')
    if [ "$_got" -gt "$_max" ]; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected at most $_max profile rows for: $_text; got $_got"
    fi
}

assert_profile_counter_at_least_in() {
    _file=$1
    _phase=$2
    _min=$3
    _stdout=$4
    _stderr=$5
    if ! awk -F'|' -v phase="$_phase" -v min="$_min" '
        $1 == "compile-profile" && $2 == phase && ($3 + 0) >= min { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected profile counter $_phase to be at least $_min"
    fi
}

assert_profile_counter_eq_in() {
    _file=$1
    _phase=$2
    _want=$3
    _stdout=$4
    _stderr=$5
    if ! awk -F'|' -v phase="$_phase" -v want="$_want" '
        $1 == "compile-profile" && $2 == phase && ($3 + 0) == want { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected profile counter $_phase to equal $_want"
    fi
}

profile_counter_value_in() {
    _file=$1
    _phase=$2
    awk -F'|' -v phase="$_phase" '
        $1 == "compile-profile" && $2 == phase {
            print $3 + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_file"
}

profile_live_counter_value_in() {
    _file=$1
    _phase=$2
    awk -F'|' -v phase="$_phase" '
        $1 == "compile-profile" && $2 == phase {
            print $5 + 0
            found = 1
            exit
        }
        END { if (!found) exit 1 }
    ' "$_file"
}

# Lowerer counters use the same six-field phase schema, with their value in
# the live-delta column. Keep this separate from the ordinary profile counters
# above, whose value lives in the elapsed-ms column.
assert_profile_live_counter_eq_in() {
    _file=$1
    _phase=$2
    _want=$3
    _stdout=$4
    _stderr=$5
    if ! awk -F'|' -v phase="$_phase" -v want="$_want" '
        $1 == "compile-profile" && $2 == phase && ($5 + 0) == want { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected profile live counter $_phase to equal $_want"
    fi
}

assert_profile_live_counter_at_least_in() {
    _file=$1
    _phase=$2
    _min=$3
    _stdout=$4
    _stderr=$5
    if ! awk -F'|' -v phase="$_phase" -v min="$_min" '
        $1 == "compile-profile" && $2 == phase && ($5 + 0) >= min { found = 1 }
        END { exit found ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "expected profile live counter $_phase to be at least $_min"
    fi
}

assert_profile_total_peak_covers_live_in() {
    _file=$1
    _stdout=$2
    _stderr=$3
    if ! awk -F'|' '
        $1 == "compile-profile" && $2 == "total" {
            found = 1
            if (($6 + 0) < ($5 + 0)) bad = 1
        }
        END { exit found && !bad ? 0 : 1 }
    ' "$_file"; then
        show_failure_logs "$_stdout" "$_stderr"
        fail "compile-wide peak must cover the final live allocation delta"
    fi
}

assert_layout_row() {
    assert_contains_in \
        "$LAYOUT_STDERR" \
        "compile-profile|typecheck.layout.$1|" \
        "$LAYOUT_STDOUT" \
        "$LAYOUT_STDERR"
}

assert_opt_escape_row() {
    assert_contains_in \
        "$OPT_STDERR" \
        "compile-profile-detail|optimize.escape.$1|" \
        "$OPT_STDOUT" \
        "$OPT_STDERR"
}

assert_lower_row() {
    assert_contains_in \
        "$OPT_STDERR" \
        "compile-profile|lower.$1|" \
        "$OPT_STDOUT" \
        "$OPT_STDERR"
}

echo "[compile-profile] build embedded stdlib tlci input"
scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" target/embedded-stdlib-tlci/stdlib.tlci "$NL_HOST_OS"

echo "[compile-profile] compile profile-enabled CLI"
if ! "$COMPILER" compile src/main.tl \
    -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compile-profile \
    --cfg embedded-stdlib-tlci \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "profile-enabled CLI compile failed"
fi

echo "[compile-profile] link profile-enabled CLI"
if ! assemble_and_link compile-profile-cli "$PROFILE_ASM" "$PROFILE_OBJ" "$PROFILE_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "profile-enabled CLI link failed"
fi

echo "[compile-profile] compile compact-summary CLI"
if ! "$COMPILER" compile src/main.tl \
    -o "$SUMMARY_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compile-profile \
    --cfg compile-profile-summary \
    > "$SUMMARY_BUILD_STDOUT" 2> "$SUMMARY_BUILD_STDERR"; then
    show_failure_logs "$SUMMARY_BUILD_STDOUT" "$SUMMARY_BUILD_STDERR"
    fail "compact-summary CLI compile failed"
fi
if ! assemble_and_link compile-profile-summary-cli \
    "$SUMMARY_ASM" "$SUMMARY_OBJ" "$SUMMARY_BIN" \
    >> "$SUMMARY_BUILD_STDOUT" 2>> "$SUMMARY_BUILD_STDERR"; then
    show_failure_logs "$SUMMARY_BUILD_STDOUT" "$SUMMARY_BUILD_STDERR"
    fail "compact-summary CLI link failed"
fi

echo "[compile-profile] verify compact summary schema and bound"
if ! "$SUMMARY_BIN" compile tests/integration/arithmetic.tl \
    -o "$SUMMARY_OUTPUT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$SUMMARY_CHECK_STDOUT" 2> "$SUMMARY_CHECK_STDERR"; then
    show_failure_logs "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
    fail "compact-summary fixture compile failed"
fi
assert_contains_in "$SUMMARY_CHECK_STDERR" \
    "compile-profile-summary|scope|kind|rank|name|elapsed_ms|calls" \
    "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
for row in \
    'optimizer|pass' 'optimizer|function' 'optimizer|module' \
    'backend|function' 'backend|module'; do
    assert_contains_in "$SUMMARY_CHECK_STDERR" \
        "compile-profile-summary|$row|" \
        "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
    assert_contains_in "$SUMMARY_CHECK_STDERR" \
        "compile-profile-summary|$row|0|<remainder>|" \
        "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
done
assert_contains_in "$SUMMARY_CHECK_STDERR" "compile-profile|total|" \
    "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
assert_not_contains_in "$SUMMARY_CHECK_STDERR" "compile-profile-detail|" \
    "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
summary_lines=$(grep -c '^compile-profile-summary|' "$SUMMARY_CHECK_STDERR")
if [ "$summary_lines" -gt 46 ]; then
    show_failure_logs "$SUMMARY_CHECK_STDOUT" "$SUMMARY_CHECK_STDERR"
    fail "compact summary exceeded 46 rows: $summary_lines"
fi
if ! awk -F'|' '
    $1 == "compile-profile-summary" && $2 != "scope" {
        key = $2 "|" $3
        if ($4 != 0 && $4 != previous[key] + 1) bad = 1
        if ($4 != 0) previous[key] = $4
    }
    END { exit bad ? 1 : 0 }
' "$SUMMARY_CHECK_STDERR"; then
    fail "compact summary ranks are not stable ascending rows"
fi

echo "[compile-profile] verify normal compiler has no profile output"
if ! "$COMPILER" compile tests/integration/arithmetic.tl \
    -o "$NORMAL_OUTPUT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$NORMAL_CHECK_STDOUT" 2> "$NORMAL_CHECK_STDERR"; then
    show_failure_logs "$NORMAL_CHECK_STDOUT" "$NORMAL_CHECK_STDERR"
    fail "normal fixture compile failed"
fi
assert_not_contains_in "$NORMAL_CHECK_STDERR" "compile-profile" \
    "$NORMAL_CHECK_STDOUT" "$NORMAL_CHECK_STDERR"

echo "[compile-profile] verify compile-wide peak survives nested reset"
if ! "$PROFILE_BIN" run tests/integration/compile_profile_nested_peak_reset.tl \
    --cfg compile-profile \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$PEAK_RESET_STDOUT" 2> "$PEAK_RESET_STDERR"; then
    show_failure_logs "$PEAK_RESET_STDOUT" "$PEAK_RESET_STDERR"
    fail "compile-wide nested peak reset fixture failed"
fi

echo "[compile-profile] verify per-entry batch memory boundaries"
printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$BATCH_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$BATCH_FUNCTIONS")" > "$BATCH_LIST"
if ! "$PROFILE_BIN" compile --batch "$BATCH_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$BATCH_STDOUT" 2> "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "profile batch fixture failed"
fi
assert_line_count_in "$BATCH_STDERR" \
    "compile-batch-profile|entry_ordinal|marker|" 1 \
    "$BATCH_STDOUT" "$BATCH_STDERR"
for ordinal in 0 1; do
    for marker in entry-start emit-complete owned-pool-release \
        intern-session-cleanup lower-cleanup scratch-destroy-steady; do
        assert_line_count_in "$BATCH_STDERR" \
            "compile-batch-profile|$ordinal|$marker|" 1 \
            "$BATCH_STDOUT" "$BATCH_STDERR"
    done
done
if ! awk -F'|' '
    $1 == "compile-batch-profile" && $2 != "entry_ordinal" {
        if (NF != 7 || $2 !~ /^[0-9]+$/ || $4 !~ /^-?[0-9]+$/ ||
            $5 !~ /^-?[0-9]+$/ || $6 !~ /^-?[0-9]+$/ ||
            $7 !~ /^-?[0-9]+$/) bad = 1
        rows++
    }
    END { exit rows == 12 && !bad ? 0 : 1 }
' "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "batch profile rows do not match the stable seven-field schema"
fi
if ! awk -F'|' '
    $1 == "compile-batch-profile" && $3 == "owned-pool-release" {
        rows++
        if (($7 + 0) > 1048576) bad = 1
    }
    END { exit rows == 2 && !bad ? 0 : 1 }
' "$BATCH_STDERR"; then
    show_failure_logs "$BATCH_STDOUT" "$BATCH_STDERR"
    fail "post-emission pool release rematerialized more than 1 MiB"
fi
if ! "$PROFILE_BIN" compile tests/integration/arithmetic.tl \
    -o "$BATCH_SINGLE_ARITH" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib \
    > "$BATCH_SINGLE_STDOUT" 2> "$BATCH_SINGLE_STDERR" ||
   ! "$PROFILE_BIN" compile tests/integration/functions.tl \
    -o "$BATCH_SINGLE_FUNCTIONS" --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) --stdlib-root stdlib \
    >> "$BATCH_SINGLE_STDOUT" 2>> "$BATCH_SINGLE_STDERR"; then
    show_failure_logs "$BATCH_SINGLE_STDOUT" "$BATCH_SINGLE_STDERR"
    fail "profile single-entry parity fixture failed"
fi
cmp "$BATCH_ARITH" "$BATCH_SINGLE_ARITH" >/dev/null ||
    fail "profile batch arithmetic assembly differs from one-entry output"
cmp "$BATCH_FUNCTIONS" "$BATCH_SINGLE_FUNCTIONS" >/dev/null ||
    fail "profile batch functions assembly differs from one-entry output"

echo "[compile-profile] verify failed-entry marker and diagnostic attribution"
printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$FAILED_BATCH_FIRST")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$FAILED_BATCH_SECOND")" > "$FAILED_BATCH_LIST"
if "$PROFILE_BIN" compile --batch "$FAILED_BATCH_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$FAILED_BATCH_STDOUT" 2> "$FAILED_BATCH_STDERR"; then
    show_failure_logs "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
    fail "profile batch with invalid second entry unexpectedly passed"
fi
assert_contains_in "$FAILED_BATCH_STDERR" "compile: batch source failed:" \
    "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
assert_contains_in "$FAILED_BATCH_STDERR" "functions.tl" \
    "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
assert_line_count_in "$FAILED_BATCH_STDERR" \
    "compile-batch-profile|1|emit-complete|" 1 \
    "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
if ! grep '^compile-batch-profile|1|emit-complete|' "$FAILED_BATCH_STDERR" >/dev/null; then
    show_failure_logs "$FAILED_BATCH_STDOUT" "$FAILED_BATCH_STDERR"
    fail "failed-entry emit marker was not independently parseable"
fi
cmp "$FAILED_BATCH_FIRST" "$BATCH_ARITH" >/dev/null ||
    fail "successful output before failed batch entry changed"

printf '%s|%s\n%s|%s\n' \
    "$(batch_path "$ROOT/tests/integration/arithmetic.tl")" "$(batch_path "$NORMAL_BATCH_ARITH")" \
    "$(batch_path "$ROOT/tests/integration/functions.tl")" "$(batch_path "$NORMAL_BATCH_FUNCTIONS")" > "$NORMAL_BATCH_LIST"
if ! "$COMPILER" compile --batch "$NORMAL_BATCH_LIST" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$NORMAL_BATCH_STDOUT" 2> "$NORMAL_BATCH_STDERR"; then
    show_failure_logs "$NORMAL_BATCH_STDOUT" "$NORMAL_BATCH_STDERR"
    fail "normal batch fixture failed"
fi
assert_not_contains_in "$NORMAL_BATCH_STDERR" "compile-batch-profile" \
    "$NORMAL_BATCH_STDOUT" "$NORMAL_BATCH_STDERR"
cmp "$BATCH_ARITH" "$NORMAL_BATCH_ARITH" >/dev/null ||
    fail "profile-enabled batch changed normal arithmetic assembly"
cmp "$BATCH_FUNCTIONS" "$NORMAL_BATCH_FUNCTIONS" >/dev/null ||
    fail "profile-enabled batch changed normal functions assembly"

if [ "$NL_HOST_OS" = windows ]; then
    command -v pwsh >/dev/null 2>&1 || fail "pwsh is required for Windows batch memory telemetry"
    if ! pwsh -NoProfile -File scripts/measure-compile-batch-memory.ps1 \
        -Compiler "$PROFILE_BIN" \
        -Batch "$BATCH_LIST" \
        -OutputDir "$WINDOWS_MEMORY_DIR" \
        -Target "$NL_BOOTSTRAP_TARGET" \
        -StdlibRoot stdlib \
        > "$WORKDIR/windows-memory.stdout" \
        2> "$WORKDIR/windows-memory.stderr"; then
        show_failure_logs "$WORKDIR/windows-memory.stdout" "$WORKDIR/windows-memory.stderr"
        fail "Windows batch memory sampler failed"
    fi
    windows_memory_rows=$(awk 'NR > 1 { rows++ } END { print rows + 0 }' \
        "$WINDOWS_MEMORY_DIR/memory.tsv")
    [ "$windows_memory_rows" -eq 12 ] ||
        fail "Windows batch memory sampler expected 12 rows, got $windows_memory_rows"
fi

expected_heavy_sources='compiler_typecheck_smoke|src/tests/compiler_typecheck_smoke.tl
compiler_lower_smoke|src/tests/compiler_lower_smoke.tl
compiler_backend_smoke|src/tests/compiler_backend_smoke.tl
doc_test_smoke|src/tests/doc_test_smoke.tl
compiler_driver_pic_smoke|src/tests/compiler_driver_pic_smoke.tl'
actual_heavy_sources=$(scripts/measure-heavy-closure-profile.sh --list)
if [ "$actual_heavy_sources" != "$expected_heavy_sources" ]; then
    fail "heavy-closure harness source list changed"
fi

# A source selfhost compile exercises the compiler's embedded canonical stdlib
# payloads. On Windows it is the allocation boundary that small new modules
# (such as the clone declaration-macro handoff) previously crossed. The macro
# walk now starts in the compact destination and grows its 25-page node pool
# once; typecheck starts in a fresh 25-page destination. Keep those phase-specific
# capacities exact so an extra grow still consumes the headroom this probe
# protects.
if [ "$NL_HOST_OS" = windows ]; then
    echo "[compile-profile] selfhost embedded-stdlib allocation probe"
    if ! "$PROFILE_BIN" compile src/main.tl \
        -o "$SELFHOST_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib \
        --stdlib-root src \
        --cfg compile-profile \
        > "$SELFHOST_STDOUT" 2> "$SELFHOST_STDERR"; then
        show_failure_logs "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
        fail "profile-enabled selfhost compile failed"
    fi
    assert_profile_total_peak_covers_live_in \
        "$SELFHOST_STDERR" \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_profile_live_counter_eq_in \
        "$SELFHOST_STDERR" \
        "lower.ast_expr_pool.macro_expand.capacity" \
        3309568 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_profile_live_counter_eq_in \
        "$SELFHOST_STDERR" \
        "lower.ast_expr_pool.typecheck.capacity" \
        1654784 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_profile_live_counter_eq_in \
        "$SELFHOST_STDERR" \
        "lower.ast_type_pool.macro_expand.capacity" \
        32768 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    assert_profile_live_counter_eq_in \
        "$SELFHOST_STDERR" \
        "lower.ast_type_pool.typecheck.capacity" \
        32768 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    # The phase reports arena destruction as a negative live delta. Exact-size
    # declaration/path reversals keep accumulated macro scratch below 500 MB;
    # the former grow-and-copy reversals retained roughly 600 MB here.
    assert_profile_live_counter_at_least_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro_scratch_release" \
        -500000000 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
fi

echo "[compile-profile] compile deep string concat fixture"
if ! "$PROFILE_BIN" compile tests/integration/string_concat_deep.tl \
    -o "$CONCAT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root . \
    --stdlib-root stdlib \
    --opt-level 0 \
    > "$CONCAT_STDOUT" 2> "$CONCAT_STDERR"; then
    show_failure_logs "$CONCAT_STDOUT" "$CONCAT_STDERR"
    fail "profiled deep string concat fixture compile failed"
fi

# Two 16-leaf trees flatten once each. The first group holds five leaves and
# each carry group adds four, yielding three concat5 calls plus one concat4
# call per tree. These counters make both the traversal and fan-in invariant
# observable without depending on assembly formatting.
assert_profile_live_counter_eq_in \
    "$CONCAT_STDERR" \
    "lower.string_concat.trees" \
    2 \
    "$CONCAT_STDOUT" \
    "$CONCAT_STDERR"
assert_profile_live_counter_eq_in \
    "$CONCAT_STDERR" \
    "lower.string_concat.leaves" \
    32 \
    "$CONCAT_STDOUT" \
    "$CONCAT_STDERR"
assert_profile_live_counter_eq_in \
    "$CONCAT_STDERR" \
    "lower.string_concat.runtime_calls" \
    8 \
    "$CONCAT_STDOUT" \
    "$CONCAT_STDERR"
assert_contains "$CONCAT_STDERR" "compile-profile|intern.render_calls|"
assert_contains "$CONCAT_STDERR" "compile-profile-detail|intern.phase.render|"
assert_contains "$CONCAT_STDERR" "compile-profile-detail|intern.lower_phase.render|"

echo "[compile-profile] check macro detail fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_macro_detail.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$CHECK_STDOUT" 2> "$CHECK_STDERR"; then
    show_failure_logs "$CHECK_STDOUT" "$CHECK_STDERR"
    fail "profiled fixture check failed"
fi

assert_contains "$CHECK_STDERR" "compile-profile-detail|typecheck.macro_expand|"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=2 calls=1"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=6 calls=1"
# str-cat's six-plus-operand path now delegates packing to the bootstrap-safe
# runtime implementation, so that module's str-cat-pack step appears in the
# macro-expansion profile.
assert_contains "$CHECK_STDERR" "stdlib.str_cat_runtime/str-cat-pack arity=3"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/and arity=3"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/or arity=2"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/cond arity=4"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.binds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.lookups|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.cache_builds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.cache_entries|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.macro_cache_entries|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.marker_scans|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.module_local_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.module_local_misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_binds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_cache_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_cache_misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_tail_fallbacks|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_materializations|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.scoped_materialized_slots|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_module_materializations|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_decl_checks|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_module_memo_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_module_catalog_builds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_module_catalog_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.generated_module_catalog_validations|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.live_rebuilds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.live_reuses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.live_registry_rebuilds|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.live_registry_reuses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_catalog_hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_catalog_misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_load_failures|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_interpreted_fallbacks|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_source_interpreted|"
assert_profile_counter_eq_in \
    "$CHECK_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$CHECK_STDOUT" \
    "$CHECK_STDERR"
assert_profile_counter_at_least_in \
    "$CHECK_STDERR" \
    "typecheck.macro.stdlib_source_interpreted" \
    1 \
    "$CHECK_STDOUT" \
    "$CHECK_STDERR"
# The multi-pass fixed-point loop and its follow-up worklist are deleted: macro
# expansion is a single demand-driven pass, so the fixed_point_* counters no
# longer exist.
assert_not_contains "$CHECK_STDERR" "typecheck.macro.fixed_point_"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.reinfer.move.call_func|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.reinfer.borrow.call_arg.calls|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.body_fact.move.call_func.hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.body_fact.move.call_func.misses|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.body_fact.borrow.call_func.hits|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.body_fact.borrow.call_func.misses|"

echo "[compile-profile] verify embedded stdlib tlci routing and differential output"
mkdir -p "$STDLIB_TLCI_DIR"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$STDLIB_TLCI_EMBEDDED_STDOUT" 2> "$STDLIB_TLCI_EMBEDDED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_EMBEDDED_STDOUT" "$STDLIB_TLCI_EMBEDDED_STDERR"
    fail "embedded stdlib tlci routing fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_SOURCE_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root "$ROOT/stdlib"
) > "$STDLIB_TLCI_SOURCE_STDOUT" 2> "$STDLIB_TLCI_SOURCE_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_SOURCE_STDOUT" "$STDLIB_TLCI_SOURCE_STDERR"
    fail "source stdlib routing fixture compile failed"
fi
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    1 \
    "$STDLIB_TLCI_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_misses" \
    0 \
    "$STDLIB_TLCI_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_load_failures" \
    0 \
    "$STDLIB_TLCI_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_EMBEDDED_STDERR"
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_interpreted_fallbacks" \
    1 \
    "$STDLIB_TLCI_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_SOURCE_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STDLIB_TLCI_SOURCE_STDOUT" \
    "$STDLIB_TLCI_SOURCE_STDERR"
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_SOURCE_STDERR" \
    "typecheck.macro.stdlib_source_interpreted" \
    1 \
    "$STDLIB_TLCI_SOURCE_STDOUT" \
    "$STDLIB_TLCI_SOURCE_STDERR"
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_SOURCE_ASM"; then
    diff -u "$STDLIB_TLCI_SOURCE_ASM" "$STDLIB_TLCI_EMBEDDED_ASM" >&2 || true
    fail "embedded and source stdlib routing changed generated assembly"
fi

echo "[compile-profile] compare compact and full canonical vector modules"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_vector_core.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$VECTOR_CORE_STDOUT" 2> "$VECTOR_CORE_STDERR"; then
    show_failure_logs "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR"
    fail "profiled compact vector fixture check failed"
fi
if ! "$PROFILE_BIN" check tests/integration/compile_profile_vector_full.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$VECTOR_FULL_STDOUT" 2> "$VECTOR_FULL_STDERR"; then
    show_failure_logs "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR"
    fail "profiled full vector fixture check failed"
fi

assert_contains_in \
    "$VECTOR_CORE_STDERR" \
    "stdlib.vector/vector arity=2 calls=1" \
    "$VECTOR_CORE_STDOUT" \
    "$VECTOR_CORE_STDERR"
assert_contains_in \
    "$VECTOR_FULL_STDERR" \
    "stdlib.vector/vector arity=1 calls=1" \
    "$VECTOR_FULL_STDOUT" \
    "$VECTOR_FULL_STDERR"

VECTOR_CORE_MACRO_ALLOC=$(awk -F'|' \
    '$1 == "compile-profile" && $2 == "typecheck.macro_walk" { print $4 }' \
    "$VECTOR_CORE_STDERR")
VECTOR_FULL_MACRO_ALLOC=$(awk -F'|' \
    '$1 == "compile-profile" && $2 == "typecheck.macro_walk" { print $4 }' \
    "$VECTOR_FULL_STDERR")
case "$VECTOR_CORE_MACRO_ALLOC:$VECTOR_FULL_MACRO_ALLOC" in
    *[!0-9:]* | :* | *:)
        show_failure_logs "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR"
        show_failure_logs "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR"
        fail "could not parse vector macro-walk allocation counters"
        ;;
esac
VECTOR_MACRO_ALLOC_SAVINGS=$((VECTOR_FULL_MACRO_ALLOC - VECTOR_CORE_MACRO_ALLOC))
if [ "$VECTOR_MACRO_ALLOC_SAVINGS" -lt 250000 ]; then
    show_failure_logs "$VECTOR_CORE_STDOUT" "$VECTOR_CORE_STDERR"
    show_failure_logs "$VECTOR_FULL_STDOUT" "$VECTOR_FULL_STDERR"
    fail "compact vector macro-walk savings regressed: core=$VECTOR_CORE_MACRO_ALLOC full=$VECTOR_FULL_MACRO_ALLOC savings=$VECTOR_MACRO_ALLOC_SAVINGS"
fi
echo "[compile-profile] vector macro-walk allocation core=$VECTOR_CORE_MACRO_ALLOC full=$VECTOR_FULL_MACRO_ALLOC savings=$VECTOR_MACRO_ALLOC_SAVINGS"

echo "[compile-profile] compare one and five compact vector identities"
if ! "$PROFILE_BIN" compile tests/integration/compile_profile_vector_one_core.tl \
    -o "$VECTOR_ONE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root . \
    --stdlib-root stdlib \
    --opt-level 1 \
    > "$VECTOR_ONE_STDOUT" 2> "$VECTOR_ONE_STDERR"; then
    show_failure_logs "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR"
    fail "profiled one-vector fixture compile failed"
fi
if ! "$PROFILE_BIN" compile tests/integration/compile_profile_vector_five_core.tl \
    -o "$VECTOR_FIVE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root . \
    --stdlib-root stdlib \
    --opt-level 1 \
    > "$VECTOR_FIVE_STDOUT" 2> "$VECTOR_FIVE_STDERR"; then
    show_failure_logs "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR"
    fail "profiled five-vector fixture compile failed"
fi

assert_profile_counter_eq_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_module_materializations" \
    1 \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_module_materializations" \
    5 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_module_memo_hits" \
    0 \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_module_memo_hits" \
    0 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"

VECTOR_ONE_DECL_CHECKS=$(profile_counter_value_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_decl_checks")
VECTOR_FIVE_DECL_CHECKS=$(profile_counter_value_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_decl_checks")
if [ "$VECTOR_ONE_DECL_CHECKS" -le 0 ] ||
    [ "$VECTOR_FIVE_DECL_CHECKS" -ne $((VECTOR_ONE_DECL_CHECKS * 5)) ]; then
    show_failure_logs "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR"
    show_failure_logs "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR"
    fail "generated declaration checks did not grow from one to five identities: one=$VECTOR_ONE_DECL_CHECKS five=$VECTOR_FIVE_DECL_CHECKS"
fi

for counter in \
    checked_program.pre_decls.functions \
    checked_program.reachable.decls \
    checked_program.reachable.functions \
    ir.after_decls.functions \
    ir.after_decls.blocks \
    ir.after_decls.instructions; do
    one_value=$(profile_live_counter_value_in \
        "$VECTOR_ONE_STDERR" \
        "lower.$counter")
    five_value=$(profile_live_counter_value_in \
        "$VECTOR_FIVE_STDERR" \
        "lower.$counter")
    if [ "$one_value" -le 0 ] || [ "$five_value" -le "$one_value" ]; then
        show_failure_logs "$VECTOR_ONE_STDOUT" "$VECTOR_ONE_STDERR"
        show_failure_logs "$VECTOR_FIVE_STDOUT" "$VECTOR_FIVE_STDERR"
        fail "profile counter lower.$counter did not grow from one to five identities: one=$one_value five=$five_value"
    fi
done

echo "[compile-profile] compact vector identity counters generated_decl_checks=$VECTOR_ONE_DECL_CHECKS/$VECTOR_FIVE_DECL_CHECKS"

echo "[compile-profile] check generated import fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_generated_import.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$GEN_IMPORT_STDOUT" 2> "$GEN_IMPORT_STDERR"; then
    show_failure_logs "$GEN_IMPORT_STDOUT" "$GEN_IMPORT_STDERR"
    fail "profiled generated import fixture check failed"
fi

# The generated module imports stdlib.string; the single demand-driven pass
# loads and forces that file import inline (there is no fixed-point loop or
# follow-up worklist to fall back to).
assert_not_contains_in \
    "$GEN_IMPORT_STDERR" \
    "typecheck.macro.fixed_point_" \
    "$GEN_IMPORT_STDOUT" \
    "$GEN_IMPORT_STDERR"
assert_contains_in \
    "$GEN_IMPORT_STDERR" \
    "compile-profile|typecheck.macro_scratch_release|" \
    "$GEN_IMPORT_STDOUT" \
    "$GEN_IMPORT_STDERR"

echo "[compile-profile] check generated result import fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_result_import.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$RESULT_IMPORT_STDOUT" 2> "$RESULT_IMPORT_STDERR"; then
    show_failure_logs "$RESULT_IMPORT_STDOUT" "$RESULT_IMPORT_STDERR"
    fail "profiled generated result import fixture check failed"
fi

assert_contains_in \
    "$RESULT_IMPORT_STDERR" \
    "stdlib.result/result arity=2 calls=1" \
    "$RESULT_IMPORT_STDOUT" \
    "$RESULT_IMPORT_STDERR"
assert_not_contains_in \
    "$RESULT_IMPORT_STDERR" \
    "typecheck.macro.fixed_point_" \
    "$RESULT_IMPORT_STDOUT" \
    "$RESULT_IMPORT_STDERR"

echo "[compile-profile] check cross-file single-compilation fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_cross_file_single_compilation.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$CROSS_SINGLE_STDOUT" 2> "$CROSS_SINGLE_STDERR"; then
    show_failure_logs "$CROSS_SINGLE_STDOUT" "$CROSS_SINGLE_STDERR"
    fail "profiled cross-file single-compilation fixture check failed"
fi

# Plan P1 single-compilation invariant: three separate modules import the same
# (vector i64) instantiation. The program-global memo materializes/typechecks
# that identity exactly once, so the two later importers are memo hits. Vector
# contains uses the shared generated equality module, so the compilation
# materializes exactly two identities: `(vector i64)` and `(eq.eq i64)`. The
# vector catalog currently exceeds the large-catalog cutoff and is materialized
# in full, so ordinary typechecking validates generated declarations while the
# separate partial-catalog shadow-validation counter remains zero.
assert_profile_counter_eq_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_module_memo_hits" \
    2 \
    "$CROSS_SINGLE_STDOUT" \
    "$CROSS_SINGLE_STDERR"
assert_profile_counter_eq_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_module_materializations" \
    2 \
    "$CROSS_SINGLE_STDOUT" \
    "$CROSS_SINGLE_STDERR"
CROSS_SINGLE_DECL_CHECKS=$(profile_counter_value_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_decl_checks")
if [ "$CROSS_SINGLE_DECL_CHECKS" -le 0 ]; then
    show_failure_logs "$CROSS_SINGLE_STDOUT" "$CROSS_SINGLE_STDERR"
    fail "repeated generated identity emitted no generated declaration checks"
fi
assert_profile_counter_eq_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_module_catalog_builds" \
    2 \
    "$CROSS_SINGLE_STDOUT" \
    "$CROSS_SINGLE_STDERR"
assert_profile_counter_eq_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_module_catalog_hits" \
    2 \
    "$CROSS_SINGLE_STDOUT" \
    "$CROSS_SINGLE_STDERR"
assert_profile_counter_eq_in \
    "$CROSS_SINGLE_STDERR" \
    "typecheck.macro.generated_module_catalog_validations" \
    0 \
    "$CROSS_SINGLE_STDOUT" \
    "$CROSS_SINGLE_STDERR"

echo "[compile-profile] check inert generated import fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_generated_import_inert.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$GEN_IMPORT_INERT_STDOUT" 2> "$GEN_IMPORT_INERT_STDERR"; then
    show_failure_logs "$GEN_IMPORT_INERT_STDOUT" "$GEN_IMPORT_INERT_STDERR"
    fail "profiled inert generated import fixture check failed"
fi

# The generated module imports a source file by path; the single
# demand-driven pass loads it inline (the multi-pass materialization
# fallback this fixture used to exercise is gone).
assert_not_contains_in \
    "$GEN_IMPORT_INERT_STDERR" \
    "typecheck.macro.fixed_point_" \
    "$GEN_IMPORT_INERT_STDOUT" \
    "$GEN_IMPORT_INERT_STDERR"

echo "[compile-profile] check generated module replay lazy fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_generated_replay_lazy.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$REPLAY_STDOUT" 2> "$REPLAY_STDERR"; then
    show_failure_logs "$REPLAY_STDOUT" "$REPLAY_STDERR"
    fail "profiled generated replay fixture check failed"
fi

assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile-detail|typecheck.macro_expand|" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
# The replay-compare + fingerprint machinery is deleted (plan P1): a memoized
# module is never re-expanded, so those counters no longer exist. The repeated
# import now resolves through the program-global module memo and is counted as a
# memo hit instead of a compare pass.
assert_contains_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro.generated_module_memo_hits|" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
# The demand-driven walk forces the generated module import inline in a single
# traversal, and the repeated structurally-identical import resolves through
# the program-global memo as a memo hit rather than a re-expand. The fixed-point
# loop and its follow-up counters are deleted.
assert_not_contains_in \
    "$REPLAY_STDERR" \
    "typecheck.macro.fixed_point_" \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_profile_counter_at_least_in \
    "$REPLAY_STDERR" \
    "typecheck.macro.generated_module_memo_hits" \
    1 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
# Local generated-import worklist processing and generated-identity shortcuts can
# reduce these detail rows; keep upper bounds to guard against re-expanding the
# repeated replay import.
assert_line_count_at_most_in \
    "$REPLAY_STDERR" \
    "profile-replay-user arity=1 calls=1" \
    2 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_line_count_at_most_in \
    "$REPLAY_STDERR" \
    "profile-replay-nested arity=2 calls=1" \
    2 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
# The repeated profile-replay-user import is structurally identical. It must not
# add another whole-program macro setup/walk pass just to discover no new work.
# Keep this as an upper bound so future local-worklist fixes can reduce it.
assert_line_count_at_most_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro_setup|" \
    7 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"
assert_line_count_at_most_in \
    "$REPLAY_STDERR" \
    "compile-profile|typecheck.macro_walk|" \
    7 \
    "$REPLAY_STDOUT" \
    "$REPLAY_STDERR"

echo "[compile-profile] check layout/spec counter fixture"
if ! "$PROFILE_BIN" check tests/integration/compile_profile_layout_spec.tl \
    --stdlib-root . \
    --stdlib-root stdlib \
    > "$LAYOUT_STDOUT" 2> "$LAYOUT_STDERR"; then
    show_failure_logs "$LAYOUT_STDOUT" "$LAYOUT_STDERR"
    fail "profiled layout/spec fixture check failed"
fi

assert_layout_row "repr_c_field_builds"
assert_layout_row "repr_c_field_visits"
assert_layout_row "inline_field_builds"
assert_layout_row "inline_field_visits"
assert_layout_row "inline_payload_builds"
assert_layout_row "inline_payload_visits"
assert_layout_row "inline_variant_builds"
assert_layout_row "inline_variant_visits"
assert_layout_row "stdlib_field_spec_builds"
assert_layout_row "stdlib_field_spec_visits"
assert_layout_row "stdlib_variant_spec_builds"
assert_layout_row "stdlib_variant_spec_visits"
assert_layout_row "cache_hits"
assert_layout_row "cache_misses"
assert_layout_row "cache_bypasses"

echo "[compile-profile] compile optimizer escape fixture"
if ! "$PROFILE_BIN" compile tests/integration/compile_profile_optimizer_escape.tl \
    -o "$OPT_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root . \
    --stdlib-root stdlib \
    --opt-level 1 \
    > "$OPT_STDOUT" 2> "$OPT_STDERR"; then
    show_failure_logs "$OPT_STDOUT" "$OPT_STDERR"
    fail "profiled optimized fixture compile failed"
fi

assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.functions|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.load_cse.max_table_size|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.load_cse.max_kinds_size|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.load_cse.table_cap_hits|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.load_cse.kinds_cap_hits|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_contains_in \
    "$OPT_STDERR" \
    "compile-profile|optimize.load_cse.field_key_drops|" \
    "$OPT_STDOUT" \
    "$OPT_STDERR"
assert_opt_escape_row "body"
assert_opt_escape_row "dce_escape"
assert_opt_escape_row "restore"
assert_contains_in "$OPT_STDERR" "|1|main" "$OPT_STDOUT" "$OPT_STDERR"
assert_lower_row "ast_expr_pool.macro_expand.len"
assert_lower_row "ast_expr_pool.macro_expand.capacity"
assert_lower_row "ast_type_pool.macro_expand.len"
assert_lower_row "ast_type_pool.macro_expand.capacity"
assert_lower_row "ast_expr_pool.typecheck.len"
assert_lower_row "ast_expr_pool.typecheck.capacity"
assert_lower_row "ast_type_pool.typecheck.len"
assert_lower_row "ast_type_pool.typecheck.capacity"
assert_lower_row "ast_expr_pool.pre_decls.len"
assert_lower_row "ast_expr_pool.pre_decls.capacity"
assert_lower_row "ast_type_pool.pre_decls.len"
assert_lower_row "ast_type_pool.pre_decls.capacity"
assert_lower_row "checked_program.pre_decls.decls"
assert_lower_row "checked_program.pre_decls.functions"
assert_lower_row "checked_program.reachable.decls"
assert_lower_row "checked_program.reachable.functions"
assert_lower_row "ir.after_decls.functions"
assert_lower_row "ir.after_decls.blocks"
assert_lower_row "ir.after_decls.instructions"
assert_lower_row "ir_arena.after_decls.active"

echo "[compile-profile] ok"
