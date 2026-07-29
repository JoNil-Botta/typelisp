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
SURFACE_HYDRATED_ASM="$WORKDIR/surface-hydrated.s"
SURFACE_HYDRATED_STDOUT="$WORKDIR/surface-hydrated.stdout"
SURFACE_HYDRATED_STDERR="$WORKDIR/surface-hydrated.stderr"
SURFACE_SOURCE_ASM="$WORKDIR/surface-source.s"
SURFACE_SOURCE_STDOUT="$WORKDIR/surface-source.stdout"
SURFACE_SOURCE_STDERR="$WORKDIR/surface-source.stderr"
SURFACE_MISMATCH_PROFILE_ASM="$WORKDIR/surface-mismatch-profile.s"
SURFACE_MISMATCH_PROFILE_OBJ="$WORKDIR/surface-mismatch-profile.$NL_OBJ_EXT"
SURFACE_MISMATCH_PROFILE_BIN="$WORKDIR/surface-mismatch-profile$NL_BIN_EXT"
SURFACE_MISMATCH_ASM="$WORKDIR/surface-mismatch.s"
SURFACE_MISMATCH_STDOUT="$WORKDIR/surface-mismatch.stdout"
SURFACE_MISMATCH_STDERR="$WORKDIR/surface-mismatch.stderr"
SURFACE_COMPILER_MISMATCH_PROFILE_ASM="$WORKDIR/surface-compiler-mismatch-profile.s"
SURFACE_COMPILER_MISMATCH_PROFILE_OBJ="$WORKDIR/surface-compiler-mismatch-profile.$NL_OBJ_EXT"
SURFACE_COMPILER_MISMATCH_PROFILE_BIN="$WORKDIR/surface-compiler-mismatch-profile$NL_BIN_EXT"
SURFACE_COMPILER_MISMATCH_ASM="$WORKDIR/surface-compiler-mismatch.s"
SURFACE_COMPILER_MISMATCH_STDOUT="$WORKDIR/surface-compiler-mismatch.stdout"
SURFACE_COMPILER_MISMATCH_STDERR="$WORKDIR/surface-compiler-mismatch.stderr"
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
DETACH_NOCHANGE_ASM="$WORKDIR/macro-detach-nochange.s"
DETACH_NOCHANGE_STDOUT="$WORKDIR/macro-detach-nochange.stdout"
DETACH_NOCHANGE_STDERR="$WORKDIR/macro-detach-nochange.stderr"
DETACH_CHANGED_ASM="$WORKDIR/macro-detach-changed.s"
DETACH_CHANGED_STDOUT="$WORKDIR/macro-detach-changed.stdout"
DETACH_CHANGED_STDERR="$WORKDIR/macro-detach-changed.stderr"
PEAK_RESET_STDOUT="$WORKDIR/profile-peak-reset.stdout"
PEAK_RESET_STDERR="$WORKDIR/profile-peak-reset.stderr"
BUILD_STDOUT="$WORKDIR/profile-build.stdout"
BUILD_STDERR="$WORKDIR/profile-build.stderr"
CHECK_STDOUT="$WORKDIR/profile-check.stdout"
CHECK_STDERR="$WORKDIR/profile-check.stderr"
COMPTIME_HOST_SMOKE_STDOUT="$WORKDIR/comptime-host-smoke.stdout"
COMPTIME_HOST_SMOKE_STDERR="$WORKDIR/comptime-host-smoke.stderr"
COMPTIME_HOST_SMOKE_ASM="$WORKDIR/comptime-host-smoke.s"
COMPTIME_HOST_SMOKE_OBJ="$WORKDIR/comptime-host-smoke.$NL_OBJ_EXT"
COMPTIME_HOST_SMOKE_BIN="$WORKDIR/comptime-host-smoke$NL_BIN_EXT"
BUILD_CLI_TEST_STDOUT="$WORKDIR/profile-build-cli-test.stdout"
BUILD_CLI_TEST_STDERR="$WORKDIR/profile-build-cli-test.stderr"
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
#
# Every exact pin expressed through this helper is verified twice: in PR CI and
# after merge by Bootstrap Stage0's narrow Windows main-push step. Keep new
# exact profile pins in this verifier so they inherit that attribution guarantee
# instead of first failing on an unrelated later PR (#5773).
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

# Read one live counter out of profile output, or the literal string "absent" so
# a renamed or dropped counter fails closed instead of comparing against 0.
profile_live_counter_in() {
    awk -F'|' -v phase="$2" '
        $1 == "compile-profile" && $2 == phase { value = ($5 + 0); found = 1 }
        END { if (found) print value; else print "absent" }
    ' "$1"
}

# Assert one selfhost pool boundary from its segment count alone.
#
# Since #5541 the AST pools are reclaimable segmented storage with fixed-size
# segments, so `capacity` and `segment_bytes` are exact multiples of `segments`:
# pinning the segment count pins all three, one constant moves when the
# compiler's own sources grow a step, and no mismatch can leave the three views
# inconsistent with each other.
#
# On failure report the whole family with expected against actual. All three
# move together, and a message naming only the counter that happened to be
# compared first sends the author round a discover-by-failing loop (#5764).
assert_selfhost_pool_family() {
    _spf_file=$1
    _spf_pool=$2
    _spf_point=$3
    _spf_segments=$4
    _spf_segment_nodes=$5
    _spf_node_bytes=$6
    _spf_stdout=$7
    _spf_stderr=$8

    _spf_capacity=$((_spf_segments * _spf_segment_nodes))
    _spf_segment_bytes=$((_spf_capacity * _spf_node_bytes))
    _spf_prefix="lower.$_spf_pool.$_spf_point"
    _spf_expected="segments:$_spf_segments capacity:$_spf_capacity segment_bytes:$_spf_segment_bytes"
    _spf_bad=

    for _spf_pair in $_spf_expected; do
        _spf_metric=${_spf_pair%%:*}
        _spf_want=${_spf_pair#*:}
        _spf_got=$(profile_live_counter_in "$_spf_file" "$_spf_prefix.$_spf_metric")
        if [ "$_spf_got" != "$_spf_want" ]; then
            _spf_bad="$_spf_bad $_spf_metric"
        fi
    done

    [ -n "$_spf_bad" ] || return 0

    show_failure_logs "$_spf_stdout" "$_spf_stderr"
    echo "selfhost pool boundary $_spf_prefix does not match its pin" >&2
    echo "  mismatched:$_spf_bad" >&2
    printf '  %-14s %14s %14s\n' metric expected actual >&2
    for _spf_pair in $_spf_expected; do
        _spf_metric=${_spf_pair%%:*}
        printf '  %-14s %14s %14s\n' \
            "$_spf_metric" \
            "${_spf_pair#*:}" \
            "$(profile_live_counter_in "$_spf_file" "$_spf_prefix.$_spf_metric")" >&2
    done
    _spf_len=$(profile_live_counter_in "$_spf_file" "$_spf_prefix.len")
    _spf_actual_segments=$(profile_live_counter_in "$_spf_file" "$_spf_prefix.segments")
    echo "  used nodes $_spf_len; capacity is that rounded up to whole segments of $_spf_segment_nodes" >&2
    echo "  to refresh: set this boundary's segment count to $_spf_actual_segments" >&2
    echo "  capacity = segments * $_spf_segment_nodes, segment_bytes = capacity * $_spf_node_bytes" >&2
    echo "  this probe is Windows-gated, so a Linux run cannot regenerate these values" >&2
    fail "selfhost pool boundary $_spf_prefix does not match its pin"
}

# The pool-family checker is the only thing between an allocation regression and
# a green run, and on Linux the probe it guards never executes, so exercise it
# against synthetic profile output on every host. A grep-shaped gate that
# silently matched nothing would otherwise read as "clean".
selfhost_pool_family_self_test() {
    _spst_dir="$WORKDIR/pool-family-self-test"
    rm -rf "$_spst_dir"
    mkdir -p "$_spst_dir"
    _spst_ok="$_spst_dir/consistent.txt"
    _spst_grown="$_spst_dir/one-segment-more.txt"
    _spst_empty="$_spst_dir/no-counters.txt"

    # 7 segments of 1024 nodes at 24 bytes, internally consistent.
    {
        echo "compile-profile|lower.ast_type_pool.self_test.len|0|0|6900|0"
        echo "compile-profile|lower.ast_type_pool.self_test.segments|0|0|7|0"
        echo "compile-profile|lower.ast_type_pool.self_test.capacity|0|0|7168|0"
        echo "compile-profile|lower.ast_type_pool.self_test.segment_bytes|0|0|172032|0"
    } > "$_spst_ok"
    # The same pin with one more segment actually allocated: the regression the
    # exact pins exist to catch.
    sed -e 's/|7|0$/|8|0/' -e 's/|7168|0$/|8192|0/' -e 's/|172032|0$/|196608|0/' \
        "$_spst_ok" > "$_spst_grown"
    : > "$_spst_empty"

    if ! (assert_selfhost_pool_family "$_spst_ok" ast_type_pool self_test 7 1024 24 \
        "$_spst_ok" "$_spst_ok") >/dev/null 2>&1; then
        fail "pool family self-test rejected consistent counters"
    fi
    if (assert_selfhost_pool_family "$_spst_grown" ast_type_pool self_test 7 1024 24 \
        "$_spst_grown" "$_spst_grown") >/dev/null 2>&1; then
        fail "pool family self-test accepted a pool that grew a segment"
    fi
    if (assert_selfhost_pool_family "$_spst_empty" ast_type_pool self_test 7 1024 24 \
        "$_spst_empty" "$_spst_empty") >/dev/null 2>&1; then
        fail "pool family self-test accepted missing counters"
    fi
    # The report must name every member, not only the one that mismatched.
    _spst_report=$( (assert_selfhost_pool_family "$_spst_grown" ast_type_pool self_test 7 1024 24 \
        "$_spst_empty" "$_spst_empty") 2>&1 || true)
    for _spst_metric in segments capacity segment_bytes; do
        case "$_spst_report" in
            *"$_spst_metric"*) ;;
            *) fail "pool family failure report omitted $_spst_metric" ;;
        esac
    done
    echo "[compile-profile] pool family self-tests passed"
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

# Runs on every host, ahead of the expensive builds: the selfhost pool probe it
# guards is Windows-gated, so this is the only coverage the checker gets on
# Linux, and a broken checker there would land silently.
selfhost_pool_family_self_test

echo "[compile-profile] build embedded stdlib tlci input"
scripts/build-embedded-stdlib-tlci.sh \
    "$COMPILER" target/embedded-stdlib-tlci/stdlib.tlci "$NL_HOST_OS"
if PRODUCER_IDENTITY=$($COMPILER --producer-identity 2>/dev/null); then
    :
else
    # The published transition seed predates the dedicated command but reports
    # the same exact revision as the second field of its version line.
    PRODUCER_IDENTITY=$($COMPILER --version 2>/dev/null |
        awk 'NR == 1 && $1 == "typelisp" { print $2 }')
fi
if ! printf '%s\n' "$PRODUCER_IDENTITY" | grep -Eq '^[0-9a-f]{40}$'; then
    fail "compiler reported malformed producer identity: $PRODUCER_IDENTITY"
fi
mkdir -p target/build-stage0
printf '%s' "$PRODUCER_IDENTITY" > target/build-stage0/git-hash.txt

echo "[compile-profile] compile profile-enabled CLI"
if ! "$COMPILER" compile src/main.tl \
    -o "$PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compiler-build-identity \
    --cfg compile-profile \
    --cfg embedded-stdlib-tlci \
    --cfg tlci-native-route \
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

echo "[compile-profile] verify native comptime host metadata parity"
if ! "$PROFILE_BIN" compile src/tests/comptime_host_smoke.tl \
    -o "$COMPTIME_HOST_SMOKE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    > "$COMPTIME_HOST_SMOKE_STDOUT" 2> "$COMPTIME_HOST_SMOKE_STDERR"; then
    show_failure_logs "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR"
    fail "native comptime host metadata smoke compile failed"
fi
if ! assemble_and_link \
    comptime-host-smoke \
    "$COMPTIME_HOST_SMOKE_ASM" \
    "$COMPTIME_HOST_SMOKE_OBJ" \
    "$COMPTIME_HOST_SMOKE_BIN" \
    >> "$COMPTIME_HOST_SMOKE_STDOUT" 2>> "$COMPTIME_HOST_SMOKE_STDERR"; then
    show_failure_logs "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR"
    fail "native comptime host metadata smoke link failed"
fi
set +e
"$COMPTIME_HOST_SMOKE_BIN" \
    >> "$COMPTIME_HOST_SMOKE_STDOUT" 2>> "$COMPTIME_HOST_SMOKE_STDERR"
COMPTIME_HOST_SMOKE_STATUS=$?
set -e
if [ "$COMPTIME_HOST_SMOKE_STATUS" -ne 42 ]; then
    show_failure_logs "$COMPTIME_HOST_SMOKE_STDOUT" "$COMPTIME_HOST_SMOKE_STDERR"
    fail "native comptime host metadata smoke expected exit 42, got $COMPTIME_HOST_SMOKE_STATUS"
fi

echo "[compile-profile] verify package-test native structural equality"
if ! "$PROFILE_BIN" test --check src/build_cli_core.tl \
    --target "$NL_BOOTSTRAP_TARGET" \
    --stdlib-root stdlib \
    > "$BUILD_CLI_TEST_STDOUT" 2> "$BUILD_CLI_TEST_STDERR"; then
    show_failure_logs "$BUILD_CLI_TEST_STDOUT" "$BUILD_CLI_TEST_STDERR"
    fail "profile package-test native structural equality failed"
fi

echo "[compile-profile] verify hydrated prelude bypass and source parity"
if ! "$PROFILE_BIN" compile tests/integration/arithmetic.tl \
    -o "$SURFACE_HYDRATED_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    > "$SURFACE_HYDRATED_STDOUT" 2> "$SURFACE_HYDRATED_STDERR"; then
    show_failure_logs "$SURFACE_HYDRATED_STDOUT" "$SURFACE_HYDRATED_STDERR"
    fail "hydrated prelude profile fixture failed"
fi
for row in \
    'prelude.source_pipeline_entries|0' \
    'prelude.hydrations|1' \
    'prelude.macro_walk_decl_visits|0' \
    'prelude.typecheck_decl_checks|0'; do
    assert_contains_in "$SURFACE_HYDRATED_STDERR" \
        "compile-profile-detail|$row" \
        "$SURFACE_HYDRATED_STDOUT" "$SURFACE_HYDRATED_STDERR"
done
if ! "$PROFILE_BIN" compile tests/integration/arithmetic.tl \
    -o "$SURFACE_SOURCE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$SURFACE_SOURCE_STDOUT" 2> "$SURFACE_SOURCE_STDERR"; then
    show_failure_logs "$SURFACE_SOURCE_STDOUT" "$SURFACE_SOURCE_STDERR"
    fail "source prelude parity fixture failed"
fi
assert_contains_in "$SURFACE_SOURCE_STDERR" \
    "compile-profile-detail|prelude.source_pipeline_entries|1" \
    "$SURFACE_SOURCE_STDOUT" "$SURFACE_SOURCE_STDERR"
assert_contains_in "$SURFACE_SOURCE_STDERR" \
    "compile-profile-detail|prelude.hydrations|0" \
    "$SURFACE_SOURCE_STDOUT" "$SURFACE_SOURCE_STDERR"
cmp "$SURFACE_HYDRATED_ASM" "$SURFACE_SOURCE_ASM" >/dev/null ||
    fail "hydrated prelude assembly differs from source prelude output"

echo "[compile-profile] verify source-mismatched surface fallback"
SOURCE_HASH_FILE=target/embedded-stdlib-tlci/source-hash.txt
EXPECTED_SOURCE_HASH=$(cat "$SOURCE_HASH_FILE")
printf '%s-mismatch' "$EXPECTED_SOURCE_HASH" > "$SOURCE_HASH_FILE"
set +e
"$COMPILER" compile src/main.tl \
    -o "$SURFACE_MISMATCH_PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compiler-build-identity \
    --cfg compile-profile \
    --cfg embedded-stdlib-tlci \
    --cfg tlci-native-route \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"
status=$?
set -e
printf '%s' "$EXPECTED_SOURCE_HASH" > "$SOURCE_HASH_FILE"
if [ "$status" -ne 0 ]; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "source-mismatch profile CLI compile failed"
fi
if ! assemble_and_link surface-mismatch-profile-cli \
    "$SURFACE_MISMATCH_PROFILE_ASM" \
    "$SURFACE_MISMATCH_PROFILE_OBJ" \
    "$SURFACE_MISMATCH_PROFILE_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "source-mismatch profile CLI link failed"
fi
if ! "$SURFACE_MISMATCH_PROFILE_BIN" compile \
    tests/integration/arithmetic.tl \
    -o "$SURFACE_MISMATCH_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    > "$SURFACE_MISMATCH_STDOUT" 2> "$SURFACE_MISMATCH_STDERR"; then
    show_failure_logs "$SURFACE_MISMATCH_STDOUT" "$SURFACE_MISMATCH_STDERR"
    fail "source-mismatched surface fallback fixture failed"
fi
assert_contains_in "$SURFACE_MISMATCH_STDERR" \
    "compile-profile-detail|prelude.source_pipeline_entries|1" \
    "$SURFACE_MISMATCH_STDOUT" "$SURFACE_MISMATCH_STDERR"
assert_contains_in "$SURFACE_MISMATCH_STDERR" \
    "compile-profile-detail|prelude.hydrations|0" \
    "$SURFACE_MISMATCH_STDOUT" "$SURFACE_MISMATCH_STDERR"
cmp "$SURFACE_SOURCE_ASM" "$SURFACE_MISMATCH_ASM" >/dev/null ||
    fail "source-mismatched fallback differs from explicit source output"

echo "[compile-profile] verify producer-compiler-mismatched surface fallback"
MISMATCH_PRODUCER_IDENTITY=0000000000000000000000000000000000000000
if [ "$MISMATCH_PRODUCER_IDENTITY" = "$PRODUCER_IDENTITY" ]; then
    MISMATCH_PRODUCER_IDENTITY=1111111111111111111111111111111111111111
fi
printf '%s' "$MISMATCH_PRODUCER_IDENTITY" > target/build-stage0/git-hash.txt
set +e
"$COMPILER" compile src/main.tl \
    -o "$SURFACE_COMPILER_MISMATCH_PROFILE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    --stdlib-root src \
    --cfg compiler-build-identity \
    --cfg compile-profile \
    --cfg embedded-stdlib-tlci \
    --cfg tlci-native-route \
    > "$BUILD_STDOUT" 2> "$BUILD_STDERR"
status=$?
set -e
printf '%s' "$PRODUCER_IDENTITY" > target/build-stage0/git-hash.txt
if [ "$status" -ne 0 ]; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "producer-mismatch profile CLI compile failed"
fi
if ! assemble_and_link surface-compiler-mismatch-profile-cli \
    "$SURFACE_COMPILER_MISMATCH_PROFILE_ASM" \
    "$SURFACE_COMPILER_MISMATCH_PROFILE_OBJ" \
    "$SURFACE_COMPILER_MISMATCH_PROFILE_BIN" \
    >> "$BUILD_STDOUT" 2>> "$BUILD_STDERR"; then
    show_failure_logs "$BUILD_STDOUT" "$BUILD_STDERR"
    fail "producer-mismatch profile CLI link failed"
fi
if ! "$SURFACE_COMPILER_MISMATCH_PROFILE_BIN" compile \
    tests/integration/arithmetic.tl \
    -o "$SURFACE_COMPILER_MISMATCH_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    > "$SURFACE_COMPILER_MISMATCH_STDOUT" \
    2> "$SURFACE_COMPILER_MISMATCH_STDERR"; then
    show_failure_logs \
        "$SURFACE_COMPILER_MISMATCH_STDOUT" \
        "$SURFACE_COMPILER_MISMATCH_STDERR"
    fail "producer-compiler-mismatched surface fallback fixture failed"
fi
assert_contains_in "$SURFACE_COMPILER_MISMATCH_STDERR" \
    "compile-profile-detail|prelude.source_pipeline_entries|1" \
    "$SURFACE_COMPILER_MISMATCH_STDOUT" \
    "$SURFACE_COMPILER_MISMATCH_STDERR"
assert_contains_in "$SURFACE_COMPILER_MISMATCH_STDERR" \
    "compile-profile-detail|prelude.hydrations|0" \
    "$SURFACE_COMPILER_MISMATCH_STDOUT" \
    "$SURFACE_COMPILER_MISMATCH_STDERR"
cmp "$SURFACE_SOURCE_ASM" "$SURFACE_COMPILER_MISMATCH_ASM" >/dev/null ||
    fail "producer-compiler-mismatched fallback differs from explicit source output"

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

echo "[compile-profile] verify macro detach structural-change decision"
if ! "$PROFILE_BIN" compile tests/integration/compile_profile_macro_detach_unchanged.tl \
    -o "$DETACH_NOCHANGE_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$DETACH_NOCHANGE_STDOUT" 2> "$DETACH_NOCHANGE_STDERR"; then
    show_failure_logs "$DETACH_NOCHANGE_STDOUT" "$DETACH_NOCHANGE_STDERR"
    fail "macro detach no-change fixture compile failed"
fi
assert_profile_live_counter_eq_in \
    "$DETACH_NOCHANGE_STDERR" \
    "lower.macro_detach.fast_path_hits" \
    1 \
    "$DETACH_NOCHANGE_STDOUT" \
    "$DETACH_NOCHANGE_STDERR"
assert_profile_live_counter_eq_in \
    "$DETACH_NOCHANGE_STDERR" \
    "lower.macro_detach.fast_path_misses" \
    0 \
    "$DETACH_NOCHANGE_STDOUT" \
    "$DETACH_NOCHANGE_STDERR"
assert_profile_live_counter_eq_in \
    "$DETACH_NOCHANGE_STDERR" \
    "lower.macro_detach.change_reasons" \
    0 \
    "$DETACH_NOCHANGE_STDOUT" \
    "$DETACH_NOCHANGE_STDERR"

if ! "$PROFILE_BIN" compile tests/integration/compile_profile_macro_detail.tl \
    -o "$DETACH_CHANGED_ASM" \
    --target "$NL_BOOTSTRAP_TARGET" \
    $(native_target_cfg_args) \
    --stdlib-root stdlib \
    > "$DETACH_CHANGED_STDOUT" 2> "$DETACH_CHANGED_STDERR"; then
    show_failure_logs "$DETACH_CHANGED_STDOUT" "$DETACH_CHANGED_STDERR"
    fail "macro detach changed fixture compile failed"
fi
assert_profile_live_counter_eq_in \
    "$DETACH_CHANGED_STDERR" \
    "lower.macro_detach.fast_path_hits" \
    0 \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"
assert_profile_live_counter_eq_in \
    "$DETACH_CHANGED_STDERR" \
    "lower.macro_detach.fast_path_misses" \
    1 \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"
assert_contains_in \
    "$DETACH_CHANGED_STDERR" \
    "compile-profile|lower.macro_handoff|" \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"
assert_contains_in \
    "$DETACH_CHANGED_STDERR" \
    "compile-profile|lower.macro_expand|" \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"
assert_contains_in \
    "$DETACH_CHANGED_STDERR" \
    "compile-profile|lower.macro_finalize|" \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"
assert_profile_live_counter_at_least_in \
    "$DETACH_CHANGED_STDERR" \
    "lower.macro_detach.change_reasons" \
    1 \
    "$DETACH_CHANGED_STDOUT" \
    "$DETACH_CHANGED_STDERR"

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
# walk now starts in the compact destination and grows fixed-size node segments;
# typecheck starts in a fresh segmented destination.
#
# The macro-expand expr boundary crossed the 41 -> 42 segment step and had been
# failing on main since #5712, which is what #5766 tracked. Attribution, holding
# the profile binary fixed and varying only the compiled tree: 1e7ef1d90 used
# 2679678 nodes (41 segments), #5712 used 2689228 (42 segments, 2252 over the
# old pin), and #5717 added 4093 more. Nothing regressed -- both grew the
# compiler's own source graph, and a segmented pool sized from that graph is
# expected to step.
#
# PR CI verifies a head merged into the base as of that event, not the eventual
# merge result. Bootstrap Stage0 therefore runs this complete verifier on its
# converged Windows compiler after every push to main. A boundary crossed by a
# merge now fails on that merge's own workflow instead of whichever unrelated
# PR opens next (#5773). Keep that post-merge step paired with these Windows
# selfhost pins. Each boundary moves as one constant with a report that names
# the whole family, so the next step costs a one-number edit instead of the
# archaeology that took (#5764).
#
# Current headroom, used against capacity, measured directly on Windows after
# the AstExpr row narrowing landed:
# expr macro_expand 2859302/2883584, expr typecheck 1704980/1769472,
# type macro_expand 20702/21504, and type typecheck 6180/7168. #5980 added the
# LSP code-action source and transcript coverage. Transformer-owned hygiene
# nodes still reuse their CTFE slots instead of retaining a second complete
# expression tree. The combined #6012/#6035 main tree crossed the expr
# typecheck boundary from 26 to 27 segments after #6012's last PR run; the
# other three values are retained from their latest direct measurements.
# All four sit within a few percent of their next step, so expect these to move.
# #5701 landed while
# this was in review and consumed 4177 of the expr macro_expand headroom without
# crossing, which is the normal case this shape is meant to make cheap. #6069's
# load-CSE source crossed the expr typecheck boundary from 26 to 27 segments.
#
# type typecheck DID cross on the AstExpr row narrowing, 6 -> 7 segments. That
# commit moves nine variants' inline AstType payloads into the type pool, so the
# types those rows used to carry inline are now interned nodes: measured
# directly on this host, the same selfhost probe reports 6040 type nodes at the
# typecheck boundary before the change and 6180 after (+140), and 6144 was the
# 6-segment capacity. The expr pools grew too (+1838..+2254 nodes) but held
# their segment counts, which is the sizing this trade was designed to buy.
#
# Keep both the logical
# capacity and physical payload bytes exact so an accidental return to eager or
# copy-on-grow storage is visible.
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
    # One constant per boundary: the segment count. capacity and segment_bytes
    # are derived, so a source-size step is a one-number edit and the three
    # views cannot drift apart. Expr nodes are 32 bytes in segments of 65536
    # (they were 40 until the AstExpr row moved its inline AstType payloads
    # behind AstTypeIds); type nodes are 24 bytes in segments of 1024.
    #
    # The type-pool macro_expand boundary is load-bearing beyond sizing: the
    # ordinary scalar `for` macro retains each source binding's produced type
    # for expr-type inspection, so its macro-walk type footprint is part of the
    # intentional exact selfhost allocation boundary.
    assert_selfhost_pool_family \
        "$SELFHOST_STDERR" ast_expr_pool macro_expand 44 65536 32 \
        "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
    assert_selfhost_pool_family \
        "$SELFHOST_STDERR" ast_expr_pool typecheck 27 65536 32 \
        "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
    assert_selfhost_pool_family \
        "$SELFHOST_STDERR" ast_type_pool macro_expand 21 1024 24 \
        "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
    assert_selfhost_pool_family \
        "$SELFHOST_STDERR" ast_type_pool typecheck 7 1024 24 \
        "$SELFHOST_STDOUT" "$SELFHOST_STDERR"
    # Each ownership boundary must expose used nodes, logical capacity, and
    # physical segmentation for both pools. Values vary with the source graph;
    # the exact selfhost segment invariants above catch sizing regressions.
    for pool_point in source_load checked_pool macro_detach retained_reader; do
        for pool_kind in ast_expr_pool ast_type_pool; do
            for pool_metric in len capacity segments segment_bytes; do
                assert_contains_in \
                    "$SELFHOST_STDERR" \
                    "compile-profile|lower.$pool_kind.$pool_point.$pool_metric|" \
                    "$SELFHOST_STDOUT" \
                    "$SELFHOST_STDERR"
            done
        done
    done
    # The phase reports arena destruction as a negative live delta. Exact-size
    # declaration/path reversals keep accumulated macro scratch below 500 MB;
    # the former grow-and-copy reversals retained roughly 600 MB here.
    assert_profile_live_counter_at_least_in \
        "$SELFHOST_STDERR" \
        "typecheck.macro_scratch_release" \
        -500000000 \
        "$SELFHOST_STDOUT" \
        "$SELFHOST_STDERR"
    # Last-use pruning only needs lexical bindings. The compiler's combined
    # GOT lookup/insert body borrows a String in a loop and consumes it after;
    # crossing the authoritative global cache here once made that one body
    # take about five seconds while resolving the whole compiler environment.
    BORROW_LIFETIME_SCAN_MAX=$(profile_counter_value_in \
        "$SELFHOST_STDERR" \
        "typecheck.env.borrow_lifetime_scan_max")
    [ "$BORROW_LIFETIME_SCAN_MAX" -le 256 ] ||
        fail "borrow lifetime scan crossed lexical boundary: $BORROW_LIFETIME_SCAN_MAX bindings"
else
    echo "[compile-profile] selfhost allocation probe and pool pins SKIPPED (windows-gated)"
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
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro_materialize|"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=2 calls=1"
assert_contains "$CHECK_STDERR" "stdlib.str_cat/str-cat arity=6 calls=1"
# str-cat's six-plus-operand path now delegates packing to the bootstrap-safe
# runtime implementation, so that module's str-cat-pack step appears in the
# macro-expansion profile.
assert_contains "$CHECK_STDERR" "stdlib.str_cat_runtime/str-cat-pack arity=3"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/and arity=3"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/or arity=2"
assert_contains "$CHECK_STDERR" "stdlib.core_macros/cond arity=4"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.walk_rewalk_zero_fire_calls|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.walk_rewalk_provenance_skips|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.walk_hygiene_nodes_reused|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.walk_hygiene_nodes_copied|"
assert_profile_counter_at_least_in \
    "$CHECK_STDERR" \
    "typecheck.macro.walk_hygiene_nodes_reused" \
    1 \
    "$CHECK_STDOUT" \
    "$CHECK_STDERR"
assert_profile_counter_at_least_in \
    "$CHECK_STDERR" \
    "typecheck.macro.walk_rewalk_provenance_skips" \
    1 \
    "$CHECK_STDOUT" \
    "$CHECK_STDERR"
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
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.borrow_lifetime_scans|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.borrow_lifetime_scan_bindings|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.env.borrow_lifetime_scan_max|"
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
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_native_expr_results|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_native_module_results|"
assert_contains "$CHECK_STDERR" "compile-profile|typecheck.macro.stdlib_tlci_native_decls_results|"
# The repo's own stdlib is content-identical to the embedded payload, so
# the catalog dispatches here too; shell entries keep the counted
# interpreted fallback (and their per-identity profile rows above). On
# Windows the route is gated off until #5460 closes, so the stand-down
# shape is asserted instead.
if [ "$NL_HOST_OS" = windows ]; then
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
else
    # #5634: the macro-detail fixture's last interpreted shells are going
    # native (#5596's zero-shell end state), so a non-zero fallback count can
    # no longer be required here. Assert the catalog route is live and exact
    # instead (same shape as the routing fixture below); the row-exists
    # assertion above keeps the fallback counter's plumbing covered.
    assert_profile_counter_at_least_in \
        "$CHECK_STDERR" \
        "typecheck.macro.stdlib_tlci_catalog_hits" \
        1 \
        "$CHECK_STDOUT" \
        "$CHECK_STDERR"
    assert_profile_counter_at_least_in \
        "$CHECK_STDERR" \
        "typecheck.macro.stdlib_tlci_native_dispatches" \
        1 \
        "$CHECK_STDOUT" \
        "$CHECK_STDERR"
    assert_profile_counter_eq_in \
        "$CHECK_STDERR" \
        "typecheck.macro.stdlib_tlci_catalog_misses" \
        0 \
        "$CHECK_STDOUT" \
        "$CHECK_STDERR"
fi
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

if [ "$NL_HOST_OS" = windows ]; then
    echo "[compile-profile] skip routing differential on windows (route gated, #5460)"
else
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
# With the fold bodies native, every cataloged macro in this fixture now
# commits natively; assert the dispatches instead of a fallback count.
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$STDLIB_TLCI_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_EMBEDDED_STDERR"
# A pristine stdlib root is content-identical to the embedded payload, so
# the catalog dispatches for it too; the byte-parity requirement below is
# the contract that matters.
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_SOURCE_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    1 \
    "$STDLIB_TLCI_SOURCE_STDOUT" \
    "$STDLIB_TLCI_SOURCE_STDERR"
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_SOURCE_ASM"; then
    diff -u "$STDLIB_TLCI_SOURCE_ASM" "$STDLIB_TLCI_EMBEDDED_ASM" >&2 || true
    fail "embedded and source stdlib routing changed generated assembly"
fi

# A modified stdlib root must keep every one of its modules on source
# interpretation (the catalog may never shadow user stdlib), and a
# comment-only modification must still produce byte-identical output.
echo "[compile-profile] verify modified stdlib root stands the catalog down"
STDLIB_TLCI_MODIFIED_DIR="$STDLIB_TLCI_DIR/modified-root"
STDLIB_TLCI_MODIFIED_ASM="$STDLIB_TLCI_DIR/modified.s"
STDLIB_TLCI_MODIFIED_STDOUT="$STDLIB_TLCI_DIR/modified.stdout"
STDLIB_TLCI_MODIFIED_STDERR="$STDLIB_TLCI_DIR/modified.stderr"
rm -rf "$STDLIB_TLCI_MODIFIED_DIR"
mkdir -p "$STDLIB_TLCI_MODIFIED_DIR/stdlib"
for f in "$ROOT"/stdlib/*.tl; do
    { cat "$f"; echo ";; provenance-control-comment"; } \
        > "$STDLIB_TLCI_MODIFIED_DIR/stdlib/$(basename "$f")"
done
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_MODIFIED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$STDLIB_TLCI_MODIFIED_STDOUT" 2> "$STDLIB_TLCI_MODIFIED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_MODIFIED_STDOUT" "$STDLIB_TLCI_MODIFIED_STDERR"
    fail "modified stdlib routing fixture compile failed"
fi
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_MODIFIED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STDLIB_TLCI_MODIFIED_STDOUT" \
    "$STDLIB_TLCI_MODIFIED_STDERR"
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_MODIFIED_STDERR" \
    "typecheck.macro.stdlib_source_interpreted" \
    1 \
    "$STDLIB_TLCI_MODIFIED_STDOUT" \
    "$STDLIB_TLCI_MODIFIED_STDERR"
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_MODIFIED_ASM"; then
    diff -u "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_MODIFIED_ASM" >&2 || true
    fail "comment-modified stdlib root changed generated assembly"
fi

# The public concatenator must preserve every operand-count arm across the
# embedded native route and forced source interpretation. Besides assembly
# parity, assert the public and runtime profile rows plus zero native-route
# fallbacks so silently dropping the native entry cannot pass this gate.
echo "[compile-profile] verify public str-cat arity routing differential (#5628)"
STR_CAT_ARITIES_SOURCE="$ROOT/tests/integration/str_cat_native_arities.tl"
STR_CAT_ARITIES_EMBEDDED_ASM="$STDLIB_TLCI_DIR/str-cat-arities-embedded.s"
STR_CAT_ARITIES_EMBEDDED_OBJ="$STDLIB_TLCI_DIR/str-cat-arities-embedded.$NL_OBJ_EXT"
STR_CAT_ARITIES_EMBEDDED_BIN="$STDLIB_TLCI_DIR/str-cat-arities-embedded$NL_BIN_EXT"
STR_CAT_ARITIES_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/str-cat-arities-embedded.stdout"
STR_CAT_ARITIES_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/str-cat-arities-embedded.stderr"
STR_CAT_ARITIES_INTERPRETED_ASM="$STDLIB_TLCI_DIR/str-cat-arities-interpreted.s"
STR_CAT_ARITIES_INTERPRETED_STDOUT="$STDLIB_TLCI_DIR/str-cat-arities-interpreted.stdout"
STR_CAT_ARITIES_INTERPRETED_STDERR="$STDLIB_TLCI_DIR/str-cat-arities-interpreted.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$STR_CAT_ARITIES_SOURCE" \
        -o "$STR_CAT_ARITIES_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$STR_CAT_ARITIES_EMBEDDED_STDOUT" 2> "$STR_CAT_ARITIES_EMBEDDED_STDERR"; then
    show_failure_logs \
        "$STR_CAT_ARITIES_EMBEDDED_STDOUT" "$STR_CAT_ARITIES_EMBEDDED_STDERR"
    fail "embedded public str-cat arity fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$STR_CAT_ARITIES_SOURCE" \
        -o "$STR_CAT_ARITIES_INTERPRETED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$STR_CAT_ARITIES_INTERPRETED_STDOUT" 2> "$STR_CAT_ARITIES_INTERPRETED_STDERR"; then
    show_failure_logs \
        "$STR_CAT_ARITIES_INTERPRETED_STDOUT" "$STR_CAT_ARITIES_INTERPRETED_STDERR"
    fail "interpreted public str-cat arity fixture compile failed"
fi
for arity in 0 1 2 5 6 8; do
    assert_contains \
        "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
        "stdlib.str_cat/str-cat arity=$arity"
    assert_contains \
        "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
        "stdlib.str_cat_runtime/str-cat-scoped arity=$arity"
done
assert_contains \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
    "stdlib.str_cat_runtime/str-cat-pack arity=3"
assert_profile_counter_at_least_in \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    6 \
    "$STR_CAT_ARITIES_EMBEDDED_STDOUT" \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_misses" \
    0 \
    "$STR_CAT_ARITIES_EMBEDDED_STDOUT" \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_load_failures" \
    0 \
    "$STR_CAT_ARITIES_EMBEDDED_STDOUT" \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_interpreted_fallbacks" \
    0 \
    "$STR_CAT_ARITIES_EMBEDDED_STDOUT" \
    "$STR_CAT_ARITIES_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STR_CAT_ARITIES_INTERPRETED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STR_CAT_ARITIES_INTERPRETED_STDOUT" \
    "$STR_CAT_ARITIES_INTERPRETED_STDERR"
if ! cmp -s "$STR_CAT_ARITIES_EMBEDDED_ASM" "$STR_CAT_ARITIES_INTERPRETED_ASM"; then
    diff -u \
        "$STR_CAT_ARITIES_INTERPRETED_ASM" "$STR_CAT_ARITIES_EMBEDDED_ASM" \
        >&2 || true
    fail "native and interpreted public str-cat arities changed generated assembly"
fi
if ! assemble_and_link \
    str-cat-arities-native \
    "$STR_CAT_ARITIES_EMBEDDED_ASM" \
    "$STR_CAT_ARITIES_EMBEDDED_OBJ" \
    "$STR_CAT_ARITIES_EMBEDDED_BIN" \
    >> "$STR_CAT_ARITIES_EMBEDDED_STDOUT" 2>> "$STR_CAT_ARITIES_EMBEDDED_STDERR"; then
    show_failure_logs \
        "$STR_CAT_ARITIES_EMBEDDED_STDOUT" "$STR_CAT_ARITIES_EMBEDDED_STDERR"
    fail "native public str-cat arity fixture link failed"
fi
set +e
"$STR_CAT_ARITIES_EMBEDDED_BIN" \
    >> "$STR_CAT_ARITIES_EMBEDDED_STDOUT" 2>> "$STR_CAT_ARITIES_EMBEDDED_STDERR"
STR_CAT_ARITIES_STATUS=$?
set -e
if [ "$STR_CAT_ARITIES_STATUS" -ne 42 ]; then
    show_failure_logs \
        "$STR_CAT_ARITIES_EMBEDDED_STDOUT" "$STR_CAT_ARITIES_EMBEDDED_STDERR"
    fail \
        "native public str-cat arity fixture expected exit 42, got $STR_CAT_ARITIES_STATUS"
fi

# The scoped concatenator's fixed arities now execute through the native
# catalog. Compare that route with forced source interpretation, then run the
# native result so parity covers both generated bytes and behavior. Refs #5656.
echo "[compile-profile] verify scoped str-cat routing differential (#5656)"
SCOPED_CAT_SOURCE="$ROOT/tests/integration/str_cat_scoped_region.tl"
SCOPED_CAT_EMBEDDED_ASM="$STDLIB_TLCI_DIR/scoped-cat-embedded.s"
SCOPED_CAT_EMBEDDED_OBJ="$STDLIB_TLCI_DIR/scoped-cat-embedded.$NL_OBJ_EXT"
SCOPED_CAT_EMBEDDED_BIN="$STDLIB_TLCI_DIR/scoped-cat-embedded$NL_BIN_EXT"
SCOPED_CAT_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/scoped-cat-embedded.stdout"
SCOPED_CAT_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/scoped-cat-embedded.stderr"
SCOPED_CAT_INTERPRETED_ASM="$STDLIB_TLCI_DIR/scoped-cat-interpreted.s"
SCOPED_CAT_INTERPRETED_STDOUT="$STDLIB_TLCI_DIR/scoped-cat-interpreted.stdout"
SCOPED_CAT_INTERPRETED_STDERR="$STDLIB_TLCI_DIR/scoped-cat-interpreted.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$SCOPED_CAT_SOURCE" \
        -o "$SCOPED_CAT_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$SCOPED_CAT_EMBEDDED_STDOUT" 2> "$SCOPED_CAT_EMBEDDED_STDERR"; then
    show_failure_logs "$SCOPED_CAT_EMBEDDED_STDOUT" "$SCOPED_CAT_EMBEDDED_STDERR"
    fail "embedded scoped str-cat routing fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$SCOPED_CAT_SOURCE" \
        -o "$SCOPED_CAT_INTERPRETED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$SCOPED_CAT_INTERPRETED_STDOUT" 2> "$SCOPED_CAT_INTERPRETED_STDERR"; then
    show_failure_logs "$SCOPED_CAT_INTERPRETED_STDOUT" "$SCOPED_CAT_INTERPRETED_STDERR"
    fail "interpreted scoped str-cat routing fixture compile failed"
fi
for arity in 2 3 4 5; do
    assert_contains \
        "$SCOPED_CAT_EMBEDDED_STDERR" \
        "stdlib.str_cat_runtime/str-cat-scoped arity=$arity"
done
assert_profile_counter_at_least_in \
    "$SCOPED_CAT_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$SCOPED_CAT_EMBEDDED_STDOUT" \
    "$SCOPED_CAT_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$SCOPED_CAT_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_interpreted_fallbacks" \
    0 \
    "$SCOPED_CAT_EMBEDDED_STDOUT" \
    "$SCOPED_CAT_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$SCOPED_CAT_INTERPRETED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$SCOPED_CAT_INTERPRETED_STDOUT" \
    "$SCOPED_CAT_INTERPRETED_STDERR"
if ! cmp -s "$SCOPED_CAT_EMBEDDED_ASM" "$SCOPED_CAT_INTERPRETED_ASM"; then
    diff -u "$SCOPED_CAT_INTERPRETED_ASM" "$SCOPED_CAT_EMBEDDED_ASM" >&2 || true
    fail "native and interpreted scoped str-cat changed generated assembly"
fi
if ! assemble_and_link \
    scoped-cat-native \
    "$SCOPED_CAT_EMBEDDED_ASM" \
    "$SCOPED_CAT_EMBEDDED_OBJ" \
    "$SCOPED_CAT_EMBEDDED_BIN" \
    >> "$SCOPED_CAT_EMBEDDED_STDOUT" 2>> "$SCOPED_CAT_EMBEDDED_STDERR"; then
    show_failure_logs "$SCOPED_CAT_EMBEDDED_STDOUT" "$SCOPED_CAT_EMBEDDED_STDERR"
    fail "native scoped str-cat routing fixture link failed"
fi
set +e
"$SCOPED_CAT_EMBEDDED_BIN" \
    >> "$SCOPED_CAT_EMBEDDED_STDOUT" 2>> "$SCOPED_CAT_EMBEDDED_STDERR"
SCOPED_CAT_STATUS=$?
set -e
if [ "$SCOPED_CAT_STATUS" -ne 42 ]; then
    show_failure_logs "$SCOPED_CAT_EMBEDDED_STDOUT" "$SCOPED_CAT_EMBEDDED_STDERR"
    fail "native scoped str-cat routing fixture expected exit 42, got $SCOPED_CAT_STATUS"
fi

# The same native-vs-interpreted comparison over the template node kinds the
# json/serialize/text_buf/math hooks use (#5605): `return`, `box`/`box-get`,
# `(set! (struct-get ...) ...)`, and float literals inside quasiquotes. The
# array fixture above exercises none of them, so a reconstruction divergence
# in those node kinds would otherwise reach the bootstrap unchecked.
echo "[compile-profile] verify template node kind routing differential (#5605)"
TEMPLATE_NODES_SOURCE="$ROOT/tests/integration/tlci_native_template_nodes.tl"
TEMPLATE_NODES_EMBEDDED_ASM="$STDLIB_TLCI_DIR/template-nodes-embedded.s"
TEMPLATE_NODES_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/template-nodes-embedded.stdout"
TEMPLATE_NODES_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/template-nodes-embedded.stderr"
TEMPLATE_NODES_INTERPRETED_ASM="$STDLIB_TLCI_DIR/template-nodes-interpreted.s"
TEMPLATE_NODES_INTERPRETED_STDOUT="$STDLIB_TLCI_DIR/template-nodes-interpreted.stdout"
TEMPLATE_NODES_INTERPRETED_STDERR="$STDLIB_TLCI_DIR/template-nodes-interpreted.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$TEMPLATE_NODES_SOURCE" \
        -o "$TEMPLATE_NODES_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$TEMPLATE_NODES_EMBEDDED_STDOUT" 2> "$TEMPLATE_NODES_EMBEDDED_STDERR"; then
    show_failure_logs \
        "$TEMPLATE_NODES_EMBEDDED_STDOUT" "$TEMPLATE_NODES_EMBEDDED_STDERR"
    fail "template node kind fixture failed on the embedded route"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$TEMPLATE_NODES_SOURCE" \
        -o "$TEMPLATE_NODES_INTERPRETED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$TEMPLATE_NODES_INTERPRETED_STDOUT" \
    2> "$TEMPLATE_NODES_INTERPRETED_STDERR"; then
    show_failure_logs \
        "$TEMPLATE_NODES_INTERPRETED_STDOUT" \
        "$TEMPLATE_NODES_INTERPRETED_STDERR"
    fail "template node kind fixture failed on the interpreted route"
fi
assert_profile_counter_at_least_in \
    "$TEMPLATE_NODES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$TEMPLATE_NODES_EMBEDDED_STDOUT" \
    "$TEMPLATE_NODES_EMBEDDED_STDERR"
# text_buf_family.owned commits a Decls result through the real mapped image;
# the byte comparison below proves its handle rejoins the source CTFE
# validation/splice path instead of merely returning a native value. Refs
# #4870.
assert_profile_counter_at_least_in \
    "$TEMPLATE_NODES_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_decls_results" \
    1 \
    "$TEMPLATE_NODES_EMBEDDED_STDOUT" \
    "$TEMPLATE_NODES_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$TEMPLATE_NODES_INTERPRETED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$TEMPLATE_NODES_INTERPRETED_STDOUT" \
    "$TEMPLATE_NODES_INTERPRETED_STDERR"
if ! cmp -s "$TEMPLATE_NODES_EMBEDDED_ASM" "$TEMPLATE_NODES_INTERPRETED_ASM"; then
    diff -u "$TEMPLATE_NODES_INTERPRETED_ASM" "$TEMPLATE_NODES_EMBEDDED_ASM" >&2 \
        || true
    fail "native and interpreted template node kinds changed generated assembly"
fi

# #5454 regression: the same modified root reached by a non-`stdlib` path
# spelling from a working directory without a `stdlib/` fallback must still
# typecheck the root's own modules against that root's core-macros prelude
# (previously: 'unbound name cond' unless the root was literally `stdlib`).
STDLIB_TLCI_PATHROOT_ASM="$STDLIB_TLCI_DIR/pathroot.s"
STDLIB_TLCI_PATHROOT_STDOUT="$STDLIB_TLCI_DIR/pathroot.stdout"
STDLIB_TLCI_PATHROOT_STDERR="$STDLIB_TLCI_DIR/pathroot.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$ROOT/tests/integration/array_qualified_macros.tl" \
        -o "$STDLIB_TLCI_PATHROOT_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root modified-root/stdlib
) > "$STDLIB_TLCI_PATHROOT_STDOUT" 2> "$STDLIB_TLCI_PATHROOT_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_PATHROOT_STDOUT" "$STDLIB_TLCI_PATHROOT_STDERR"
    fail "path-spelled modified stdlib root failed to typecheck (#5454)"
fi
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_PATHROOT_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STDLIB_TLCI_PATHROOT_STDOUT" \
    "$STDLIB_TLCI_PATHROOT_STDERR"
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_PATHROOT_STDERR" \
    "typecheck.macro.stdlib_source_interpreted" \
    1 \
    "$STDLIB_TLCI_PATHROOT_STDOUT" \
    "$STDLIB_TLCI_PATHROOT_STDERR"
if ! cmp -s "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_PATHROOT_ASM"; then
    diff -u "$STDLIB_TLCI_EMBEDDED_ASM" "$STDLIB_TLCI_PATHROOT_ASM" >&2 || true
    fail "path-spelled modified stdlib root changed generated assembly (#5454)"
fi

# #5647: the index-fold bodies walk an operand list by index, and a fold that
# stops one element early, repeats one, or reverses the order still compiles
# and still runs. Only a route differential catches that, and
# array_qualified_macros.tl exercises neither fold, so drive them explicitly.
echo "[compile-profile] verify tlci index-fold route differential"
STDLIB_TLCI_FOLDS_SOURCE="$ROOT/tests/integration/tlci_native_index_folds.tl"
STDLIB_TLCI_FOLDS_EMBEDDED_ASM="$STDLIB_TLCI_DIR/folds-embedded.s"
STDLIB_TLCI_FOLDS_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/folds-embedded.stdout"
STDLIB_TLCI_FOLDS_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/folds-embedded.stderr"
STDLIB_TLCI_FOLDS_MODIFIED_ASM="$STDLIB_TLCI_DIR/folds-modified.s"
STDLIB_TLCI_FOLDS_MODIFIED_STDOUT="$STDLIB_TLCI_DIR/folds-modified.stdout"
STDLIB_TLCI_FOLDS_MODIFIED_STDERR="$STDLIB_TLCI_DIR/folds-modified.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_FOLDS_SOURCE" \
        -o "$STDLIB_TLCI_FOLDS_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$STDLIB_TLCI_FOLDS_EMBEDDED_STDOUT" \
    2> "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_FOLDS_EMBEDDED_STDOUT" \
        "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR"
    fail "embedded tlci index-fold fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_FOLDS_SOURCE" \
        -o "$STDLIB_TLCI_FOLDS_MODIFIED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$STDLIB_TLCI_FOLDS_MODIFIED_STDOUT" \
    2> "$STDLIB_TLCI_FOLDS_MODIFIED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_FOLDS_MODIFIED_STDOUT" \
        "$STDLIB_TLCI_FOLDS_MODIFIED_STDERR"
    fail "comment-modified-root tlci index-fold fixture compile failed"
fi
# The embedded route must actually take the native entries, and the modified
# root must actually interpret, or the byte comparison below proves nothing.
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_misses" \
    0 \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_FOLDS_MODIFIED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STDLIB_TLCI_FOLDS_MODIFIED_STDOUT" \
    "$STDLIB_TLCI_FOLDS_MODIFIED_STDERR"
# Both folds must fire, so a fixture edit cannot silently stop covering them.
assert_contains "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR" \
    "stdlib.str_cat_runtime/str-cat-pack arity=3"
assert_contains "$STDLIB_TLCI_FOLDS_EMBEDDED_STDERR" \
    "stdlib.fs/path-join-fold arity=3"
if ! cmp -s "$STDLIB_TLCI_FOLDS_EMBEDDED_ASM" \
    "$STDLIB_TLCI_FOLDS_MODIFIED_ASM"; then
    diff -u "$STDLIB_TLCI_FOLDS_EMBEDDED_ASM" \
        "$STDLIB_TLCI_FOLDS_MODIFIED_ASM" >&2 || true
    fail "native and interpreted index folds produced different assembly"
fi

# Native-vs-interpreted parity over the computed string-dispatch scrutinees
# (#5604): `(type-kind (comptime.expr-type e))` and `(type-key T)` probes pick
# an arm inside the native entry, so a wrong probe result silently selects a
# different expansion instead of failing. The array fixture above has no such
# dispatch, and neither does the #5605 template-node fixture.
echo "[compile-profile] verify computed scrutinee routing differential (#5604)"
SCRUTINEE_SOURCE="$ROOT/tests/integration/tlci_native_computed_scrutinee.tl"
SCRUTINEE_EMBEDDED_ASM="$STDLIB_TLCI_DIR/scrutinee-embedded.s"
SCRUTINEE_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/scrutinee-embedded.stdout"
SCRUTINEE_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/scrutinee-embedded.stderr"
SCRUTINEE_INTERPRETED_ASM="$STDLIB_TLCI_DIR/scrutinee-interpreted.s"
SCRUTINEE_INTERPRETED_STDOUT="$STDLIB_TLCI_DIR/scrutinee-interpreted.stdout"
SCRUTINEE_INTERPRETED_STDERR="$STDLIB_TLCI_DIR/scrutinee-interpreted.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$SCRUTINEE_SOURCE" \
        -o "$SCRUTINEE_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$SCRUTINEE_EMBEDDED_STDOUT" 2> "$SCRUTINEE_EMBEDDED_STDERR"; then
    show_failure_logs "$SCRUTINEE_EMBEDDED_STDOUT" "$SCRUTINEE_EMBEDDED_STDERR"
    fail "computed scrutinee fixture failed on the embedded route"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$SCRUTINEE_SOURCE" \
        -o "$SCRUTINEE_INTERPRETED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$SCRUTINEE_INTERPRETED_STDOUT" 2> "$SCRUTINEE_INTERPRETED_STDERR"; then
    show_failure_logs \
        "$SCRUTINEE_INTERPRETED_STDOUT" "$SCRUTINEE_INTERPRETED_STDERR"
    fail "computed scrutinee fixture failed on the interpreted route"
fi
assert_profile_counter_at_least_in \
    "$SCRUTINEE_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$SCRUTINEE_EMBEDDED_STDOUT" \
    "$SCRUTINEE_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$SCRUTINEE_INTERPRETED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$SCRUTINEE_INTERPRETED_STDOUT" \
    "$SCRUTINEE_INTERPRETED_STDERR"
if ! cmp -s "$SCRUTINEE_EMBEDDED_ASM" "$SCRUTINEE_INTERPRETED_ASM"; then
    diff -u "$SCRUTINEE_INTERPRETED_ASM" "$SCRUTINEE_EMBEDDED_ASM" >&2 || true
    fail "native and interpreted computed scrutinees changed generated assembly"
fi
# #5658: `stdlib.hash/hash` generates its module in the wildcard arm of a
# type-kind match, so every type except `unit` goes through an arm that was
# interpreted per invocation until that arm compiled. A wrong module name or a
# dropped declaration there still compiles and still runs, so the route
# differential is the contract.
echo "[compile-profile] verify tlci wildcard-arm route differential"
STDLIB_TLCI_WILD_SOURCE="$ROOT/tests/integration/tlci_native_wildcard_arms.tl"
STDLIB_TLCI_WILD_EMBEDDED_ASM="$STDLIB_TLCI_DIR/wild-embedded.s"
STDLIB_TLCI_WILD_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/wild-embedded.stdout"
STDLIB_TLCI_WILD_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/wild-embedded.stderr"
STDLIB_TLCI_WILD_MODIFIED_ASM="$STDLIB_TLCI_DIR/wild-modified.s"
STDLIB_TLCI_WILD_MODIFIED_STDOUT="$STDLIB_TLCI_DIR/wild-modified.stdout"
STDLIB_TLCI_WILD_MODIFIED_STDERR="$STDLIB_TLCI_DIR/wild-modified.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_WILD_SOURCE"         -o "$STDLIB_TLCI_WILD_EMBEDDED_ASM"         --target "$NL_BOOTSTRAP_TARGET"         $(native_target_cfg_args)
) > "$STDLIB_TLCI_WILD_EMBEDDED_STDOUT"     2> "$STDLIB_TLCI_WILD_EMBEDDED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_WILD_EMBEDDED_STDOUT"         "$STDLIB_TLCI_WILD_EMBEDDED_STDERR"
    fail "embedded tlci wildcard-arm fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_WILD_SOURCE"         -o "$STDLIB_TLCI_WILD_MODIFIED_ASM"         --target "$NL_BOOTSTRAP_TARGET"         $(native_target_cfg_args)         --stdlib-root stdlib
) > "$STDLIB_TLCI_WILD_MODIFIED_STDOUT"     2> "$STDLIB_TLCI_WILD_MODIFIED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_WILD_MODIFIED_STDOUT"         "$STDLIB_TLCI_WILD_MODIFIED_STDERR"
    fail "comment-modified-root tlci wildcard-arm fixture compile failed"
fi
assert_profile_counter_at_least_in     "$STDLIB_TLCI_WILD_EMBEDDED_STDERR"     "typecheck.macro.stdlib_tlci_native_dispatches"     1     "$STDLIB_TLCI_WILD_EMBEDDED_STDOUT"     "$STDLIB_TLCI_WILD_EMBEDDED_STDERR"
# stdlib.hash/hash is a real source-lowered Module result. Compiling this
# fixture and matching its source-route assembly proves the committed handle
# reaches module identity, validation, and splice materialization. Refs #4870.
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_WILD_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_module_results" \
    1 \
    "$STDLIB_TLCI_WILD_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_WILD_EMBEDDED_STDERR"
assert_profile_counter_eq_in     "$STDLIB_TLCI_WILD_MODIFIED_STDERR"     "typecheck.macro.stdlib_tlci_catalog_hits"     0     "$STDLIB_TLCI_WILD_MODIFIED_STDOUT"     "$STDLIB_TLCI_WILD_MODIFIED_STDERR"
# Both wildcard-arm identities must fire, so a fixture edit cannot silently
# stop covering them.
assert_contains "$STDLIB_TLCI_WILD_EMBEDDED_STDERR" "stdlib.hash/hash arity=1"
assert_contains "$STDLIB_TLCI_WILD_EMBEDDED_STDERR" "stdlib.eq/inline-eq arity=3"
if ! cmp -s "$STDLIB_TLCI_WILD_EMBEDDED_ASM"     "$STDLIB_TLCI_WILD_MODIFIED_ASM"; then
    diff -u "$STDLIB_TLCI_WILD_EMBEDDED_ASM"         "$STDLIB_TLCI_WILD_MODIFIED_ASM" >&2 || true
    fail "native and interpreted wildcard arms produced different assembly"
fi

# #5701: `stdlib.io/format-from` is a comptime string scanner -- it walks the
# template one byte at a time and re-invokes itself at the next offset. An
# off-by-one in any index, a dropped escape byte, or a wrong positional
# argument still compiles and still runs, producing a subtly wrong string, so
# the differential is the contract. None of the fixtures above formats
# anything.
echo "[compile-profile] verify tlci format-scanner route differential"
STDLIB_TLCI_FMT_SOURCE="$ROOT/tests/integration/tlci_native_format_scanner.tl"
STDLIB_TLCI_FMT_EMBEDDED_ASM="$STDLIB_TLCI_DIR/format-embedded.s"
STDLIB_TLCI_FMT_EMBEDDED_STDOUT="$STDLIB_TLCI_DIR/format-embedded.stdout"
STDLIB_TLCI_FMT_EMBEDDED_STDERR="$STDLIB_TLCI_DIR/format-embedded.stderr"
STDLIB_TLCI_FMT_MODIFIED_ASM="$STDLIB_TLCI_DIR/format-modified.s"
STDLIB_TLCI_FMT_MODIFIED_STDOUT="$STDLIB_TLCI_DIR/format-modified.stdout"
STDLIB_TLCI_FMT_MODIFIED_STDERR="$STDLIB_TLCI_DIR/format-modified.stderr"
if ! (
    cd "$STDLIB_TLCI_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_FMT_SOURCE" \
        -o "$STDLIB_TLCI_FMT_EMBEDDED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args)
) > "$STDLIB_TLCI_FMT_EMBEDDED_STDOUT" \
    2> "$STDLIB_TLCI_FMT_EMBEDDED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_FMT_EMBEDDED_STDOUT" \
        "$STDLIB_TLCI_FMT_EMBEDDED_STDERR"
    fail "embedded tlci format-scanner fixture compile failed"
fi
if ! (
    cd "$STDLIB_TLCI_MODIFIED_DIR"
    "$PROFILE_BIN" compile "$STDLIB_TLCI_FMT_SOURCE" \
        -o "$STDLIB_TLCI_FMT_MODIFIED_ASM" \
        --target "$NL_BOOTSTRAP_TARGET" \
        $(native_target_cfg_args) \
        --stdlib-root stdlib
) > "$STDLIB_TLCI_FMT_MODIFIED_STDOUT" \
    2> "$STDLIB_TLCI_FMT_MODIFIED_STDERR"; then
    show_failure_logs "$STDLIB_TLCI_FMT_MODIFIED_STDOUT" \
        "$STDLIB_TLCI_FMT_MODIFIED_STDERR"
    fail "comment-modified-root tlci format-scanner fixture compile failed"
fi
assert_profile_counter_at_least_in \
    "$STDLIB_TLCI_FMT_EMBEDDED_STDERR" \
    "typecheck.macro.stdlib_tlci_native_dispatches" \
    1 \
    "$STDLIB_TLCI_FMT_EMBEDDED_STDOUT" \
    "$STDLIB_TLCI_FMT_EMBEDDED_STDERR"
assert_profile_counter_eq_in \
    "$STDLIB_TLCI_FMT_MODIFIED_STDERR" \
    "typecheck.macro.stdlib_tlci_catalog_hits" \
    0 \
    "$STDLIB_TLCI_FMT_MODIFIED_STDOUT" \
    "$STDLIB_TLCI_FMT_MODIFIED_STDERR"
# The scanner itself has to run, not just its wrapper, so a fixture edit
# cannot silently stop covering the recursive walk.
assert_contains "$STDLIB_TLCI_FMT_EMBEDDED_STDERR" "stdlib.io/format-with arity="
assert_contains "$STDLIB_TLCI_FMT_EMBEDDED_STDERR" "stdlib.io/format-from arity="
if ! cmp -s "$STDLIB_TLCI_FMT_EMBEDDED_ASM" \
    "$STDLIB_TLCI_FMT_MODIFIED_ASM"; then
    diff -u "$STDLIB_TLCI_FMT_EMBEDDED_ASM" \
        "$STDLIB_TLCI_FMT_MODIFIED_ASM" >&2 || true
    fail "native and interpreted format scanners produced different assembly"
fi

# The scanner's three rejection paths are reported by the macro itself, so a
# native arm that mis-detects them fails differently -- or not at all -- from
# the interpreted one. Compare the rendered diagnostics, not just the exit
# status.
echo "[compile-profile] verify tlci format-scanner diagnostic differential"
FMT_DIAG_DIR="$STDLIB_TLCI_DIR/format-diagnostics"
rm -rf "$FMT_DIAG_DIR"
mkdir -p "$FMT_DIAG_DIR"
cat > "$FMT_DIAG_DIR/unmatched-open.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define (main) : i64
  (begin (io.print-string (format.format "a{")) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/too-few-arguments.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define one : i64 1)
(define (main) : i64
  (begin (io.print-string (format.format "{} {}" one)) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/too-many-arguments.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define one : i64 1)
(define two : i64 2)
(define (main) : i64
  (begin (io.print-string (format.format "{}" one two)) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/unmatched-close.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define (main) : i64
  (begin (io.print-string (format.format "a}b")) 0))
FIXTURE
cat > "$FMT_DIAG_DIR/non-literal-template.tl" <<'FIXTURE'
(import stdlib.format)
(import stdlib.io)
(define template : String "{}")
(define (main) : i64
  (begin (io.print-string (format.format template 1)) 0))
FIXTURE
# The profiled compiler writes its counters to stderr too, and those legitimately
# differ by route (catalog hits, native dispatches). Compare only the rendered
# diagnostic.
format_diagnostic_text() {
    grep -v 'compile-profile' "$1" > "$2"
}
for FMT_DIAG_CASE in unmatched-open too-few-arguments too-many-arguments \
    unmatched-close non-literal-template; do
    FMT_DIAG_SOURCE="$FMT_DIAG_DIR/$FMT_DIAG_CASE.tl"
    FMT_DIAG_EMBEDDED="$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.stderr"
    FMT_DIAG_MODIFIED="$FMT_DIAG_DIR/$FMT_DIAG_CASE.modified.stderr"
    if (
        cd "$STDLIB_TLCI_DIR"
        "$PROFILE_BIN" check "$FMT_DIAG_SOURCE"
    ) > "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.stdout" \
        2> "$FMT_DIAG_EMBEDDED"; then
        fail "embedded route accepted rejected format case $FMT_DIAG_CASE"
    fi
    if (
        cd "$STDLIB_TLCI_MODIFIED_DIR"
        "$PROFILE_BIN" check "$FMT_DIAG_SOURCE" \
            --stdlib-root stdlib
    ) > "$FMT_DIAG_DIR/$FMT_DIAG_CASE.modified.stdout" \
        2> "$FMT_DIAG_MODIFIED"; then
        fail "interpreted route accepted rejected format case $FMT_DIAG_CASE"
    fi
    format_diagnostic_text "$FMT_DIAG_EMBEDDED" \
        "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.text"
    format_diagnostic_text "$FMT_DIAG_MODIFIED" \
        "$FMT_DIAG_DIR/$FMT_DIAG_CASE.modified.text"
    if ! grep -q 'format: ' "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.text"; then
        show_failure_logs "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.stdout" \
            "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.text"
        fail "embedded route reported no format diagnostic for $FMT_DIAG_CASE"
    fi
    if ! cmp -s "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.text" \
        "$FMT_DIAG_DIR/$FMT_DIAG_CASE.modified.text"; then
        diff -u "$FMT_DIAG_DIR/$FMT_DIAG_CASE.embedded.text" \
            "$FMT_DIAG_DIR/$FMT_DIAG_CASE.modified.text" >&2 || true
        fail "format scanner diagnostics differ by route for $FMT_DIAG_CASE"
    fi
done
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

# The constrained vector type operand is validated once at definition time.
# Three of the eleven compact declarations contain no reference, fixed-array,
# cleanup, or other substitution-dependent construct; each additional identity
# contributes the same 3/8 invariant/concrete split.
assert_profile_counter_eq_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_module_abstract_proofs" \
    1 \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_module_abstract_proofs" \
    1 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_decl_checks_invariant_eligible" \
    3 \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_decl_checks_invariant_eligible" \
    15 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_ONE_STDERR" \
    "typecheck.macro.generated_decl_checks_concrete_required" \
    8 \
    "$VECTOR_ONE_STDOUT" \
    "$VECTOR_ONE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.generated_decl_checks_concrete_required" \
    40 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"

# The initial table build is the only whole-program symbol/registry build.
# Every generated vector module extends the live tables at their logical end.
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.live_rebuilds" \
    1 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.live_reuses" \
    5 \
    "$VECTOR_FIVE_STDOUT" \
    "$VECTOR_FIVE_STDERR"
assert_profile_counter_eq_in \
    "$VECTOR_FIVE_STDERR" \
    "typecheck.macro.live_registry_reuses" \
    5 \
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
assert_lower_row "name_env.binds"
assert_lower_row "name_env.lookups"
assert_lower_row "name_env.lookup_steps"
assert_lower_row "name_env.stores"
assert_lower_row "name_env.store_grows"
assert_lower_row "name_env.materializations"
assert_lower_row "name_env.materialized_entries"
assert_lower_row "name_cache.builds"
assert_lower_row "name_cache.entries"
assert_lower_row "name_cache.lookups"
assert_lower_row "name_cache.local_hits"
assert_lower_row "name_cache.local_misses"

echo "[compile-profile] ok"
