#!/usr/bin/env sh
set -eu

# check-instruction-counts.sh - Linux cachegrind instruction-count baseline gate.
#
# Benchmark metrics are exact. Each scalar TypeLisp benchmark is paired with a
# scalar-fair clang -O2 -fno-vectorize/-fno-slp-vectorize row. Measurement may
# also report auto-vectorized clang -O2, but a baseline chooses whether that row
# is gated by including benchmark/c/<name>.
#
# self_compile is not a row of any baseline. Its absolute count is
# environment-specific, so scripts/self-compile.sh measures it in the
# `linux-self-compile-measurement` gate and gates each PR's own cost against
# main's CI-owned reference for the tested base (perf/README.md, #9307). A
# self_compile row in a baseline file is a stale pin and fails here.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"
. "$ROOT/scripts/lib-gate.sh"
. "$ROOT/scripts/lib-benchmark.sh"

DEFAULT_BENCHMARKS=$(benchmark_ci_case_csv "$ROOT" instruction-main)
DEFAULT_BASELINE="$ROOT/perf/insn-exec-baseline.tsv"
DEFAULT_WORKDIR="target/instruction-count-check"
BASELINE=${TYPELISP_IR_CHECK_BASELINE:-$DEFAULT_BASELINE}
RUNS=${TYPELISP_IR_CHECK_RUNS:-1}
BENCHMARKS=${TYPELISP_IR_CHECK_BENCHMARKS:-$DEFAULT_BENCHMARKS}
WORKDIR=${TYPELISP_IR_CHECK_OUT:-$DEFAULT_WORKDIR}
UPDATE_BASELINE=0
SELF_TEST=0
SEED_ARG=

usage() {
    cat <<'EOF'
usage: scripts/check-instruction-counts.sh [options] [typelisp-seed]

Options:
  --update-baseline    Rewrite the selected benchmark rows of the baseline TSV,
                       preserving every other row
  --baseline FILE      Baseline TSV path (default: perf/insn-exec-baseline.tsv)
  --runs N             Cachegrind runs per metric (default: 1)
  --benchmarks LIST    Comma-separated benchmark names for the per-PR gate
  --benchmarks-only    Accepted for compatibility: benchmark rows are all this
                       checker measures
  --self-test          Check the comparison logic against fixtures and exit;
                       needs no compiler, valgrind, or Linux host
  --output DIR         Work directory (default: target/instruction-count-check)
  -h, --help           Show this help

self_compile is measured by `scripts/self-compile.sh measure` and gated
main-relative in CI; see perf/README.md.

Environment:
  TYPELISP_BIN                  Seed compiler when no argument is given
  TYPELISP_IR_CHECK_COMPILER    Prebuilt compiler to measure with; skips the
                                internal seed->stage1->stage2 builds (CI passes
                                the bootstrap fixpoint stage2 here)
  TYPELISP_IR_CHECK_RUNS        Default --runs
  TYPELISP_IR_CHECK_BENCHMARKS  Default --benchmarks
  TYPELISP_IR_CHECK_BASELINE    Default --baseline
  TYPELISP_IR_CHECK_OUT         Default --output
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --update-baseline)
            UPDATE_BASELINE=1
            shift
            ;;
        --baseline)
            [ "$#" -ge 2 ] || {
                echo "missing value for --baseline" >&2
                exit 2
            }
            BASELINE=$2
            shift 2
            ;;
        --runs)
            [ "$#" -ge 2 ] || {
                echo "missing value for --runs" >&2
                exit 2
            }
            RUNS=$2
            shift 2
            ;;
        --benchmarks)
            [ "$#" -ge 2 ] || {
                echo "missing value for --benchmarks" >&2
                exit 2
            }
            BENCHMARKS=$2
            shift 2
            ;;
        --benchmarks-only)
            shift
            ;;
        --self-compile-only)
            echo "self_compile is no longer a checked baseline row (#9307):" >&2
            echo "measure it with scripts/self-compile.sh measure; CI gates each" >&2
            echo "PR's own cost against main (perf/README.md)" >&2
            exit 2
            ;;
        --self-test)
            SELF_TEST=1
            shift
            ;;
        --output)
            [ "$#" -ge 2 ] || {
                echo "missing value for --output" >&2
                exit 2
            }
            WORKDIR=$2
            shift 2
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        -*)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            if [ -n "$SEED_ARG" ]; then
                echo "only one typelisp seed may be provided" >&2
                exit 2
            fi
            SEED_ARG=$1
            shift
            ;;
    esac
done

case "$RUNS" in
    "" | *[!0-9]* | 0)
        echo "--runs must be a positive integer: $RUNS" >&2
        exit 2
        ;;
esac

case "$BENCHMARKS" in
    "" | *[!A-Za-z0-9_.,-]*)
        echo "--benchmarks must be comma-separated benchmark names: $BENCHMARKS" >&2
        exit 2
        ;;
esac

# The comparison program, held in a variable so --self-test can exercise the
# exact logic CI runs rather than a copy of it. Contains no single quotes.
IR_COMPARE_AWK='
function benchmark_case(name,    part, count) {
    count = split(name, part, "/")
    if (count == 3 && part[1] == "benchmark") {
        return part[3]
    }
    return ""
}
function selected_metric(name,    case_name) {
    case_name = benchmark_case(name)
    return case_name == "" || benchmarks == "" ||
        (case_name in selected_benchmark)
}
function signed(n,    s) {
    s = sprintf("%.0f", n)
    if (n > 0) {
        return "+" s
    }
    return s
}
function pct(delta, base) {
    if (base == 0) {
        return "n/a"
    }
    return sprintf("%+.6f%%", (delta * 100.0) / base)
}
BEGIN {
    selected_count = split(benchmarks, selected_name, ",")
    for (selected_i = 1; selected_i <= selected_count; selected_i++) {
        selected_benchmark[selected_name[selected_i]] = 1
    }
    print "metric | baseline | current | delta | pct | status"
}
NR == FNR {
    if (FNR == 1 && $1 == "name") {
        next
    }
    if (NF < 2) {
        next
    }
    if (!selected_metric($1)) {
        next
    }
    baseline[$1] = $2
    baseline_order[++baseline_count] = $1
    next
}
FNR == 1 && $1 == "name" {
    next
}
{
    if (NF < 2) {
        next
    }
    if (!selected_metric($1)) {
        next
    }
    current[$1] = $2
    current_order[++current_count] = $1
}
END {
    failed = 0
    for (i = 1; i <= baseline_count; i++) {
        name = baseline_order[i]
        base = baseline[name]
        if (!(name in current)) {
            print name " | " base " | <missing> | n/a | n/a | missing-current"
            failed = 1
            continue
        }
        now = current[name]
        delta = (now + 0) - (base + 0)
        status = "ok"
        if (delta > 0) {
            status = "REGRESSION"
            failed = 1
        } else if (delta < 0) {
            status = "IMPROVEMENT"
            failed = 1
        }
        print name " | " base " | " now " | " signed(delta) " | " pct(delta, base + 0) " | " status
    }
    for (i = 1; i <= current_count; i++) {
        name = current_order[i]
        if (!(name in baseline)) {
            print name " | <missing> | " current[name] " | n/a | n/a | extra-current"
            failed = 1
        }
    }
    exit failed ? 1 : 0
}
'

# Compare a baseline TSV against a current TSV and render the report on stdout.
# Exits non-zero when any row regresses, improves, or is missing or extra.
compare_counts() {
    awk -F '	' \
        -v benchmarks="$BENCHMARKS" \
        "$IR_COMPARE_AWK" "$1" "$2"
}

# A self_compile row is a pin of the retired checked-row contract. Refuse it
# in any baseline, so an old ratchet commit cannot quietly re-enter and so no
# refresh carries it forward.
assert_no_self_compile_row() {
    if awk -F '\t' '$1 ~ /^self_compile\// { found = 1 } END { exit found ? 0 : 1 }' "$1"; then
        echo "[ir-check] $1 carries a self_compile row" >&2
        echo "[ir-check] self_compile is gated main-relative by scripts/self-compile.sh;" >&2
        echo "[ir-check] remove the row (perf/README.md, #9307)" >&2
        return 1
    fi
}

# A refresh that writes nothing must not report success. `--update-baseline` is
# a required pre-PR step whose whole job is to rewrite rows, so a no-op refresh
# that still prints "baseline updated" would leave a stale row against an
# author who ran the step and saw it pass. Every measured row must reach the
# file.
count_baseline_rows() {
    if [ ! -f "$1" ]; then
        printf '0\n'
        return 0
    fi
    awk -F '\t' 'NF >= 2 && $1 != "name" { count++ } END { print count + 0 }' "$1"
}

assert_baseline_refreshed() {
    _abr_baseline=$1
    _abr_current=$2
    _abr_want=$(count_baseline_rows "$_abr_current")
    _abr_got=$(count_baseline_rows "$_abr_baseline")
    if [ "$_abr_want" -eq 0 ]; then
        echo "[ir-check] measured no rows; nothing was refreshed into $_abr_baseline" >&2
        exit 1
    fi
    if [ "$_abr_got" -lt "$_abr_want" ]; then
        echo "[ir-check] baseline refresh wrote $_abr_got rows, measured $_abr_want" >&2
        echo "[ir-check] refusing to report success for an unwritten baseline" >&2
        exit 1
    fi
}

# Merge only the measured rows into the baseline, preserving every other row,
# so a benchmark subset refresh leaves the remaining rows untouched.
merge_baseline_rows() {
    _mbr_current=$1
    _mbr_baseline=$2
    _mbr_output=$3
    awk -F '\t' '
    BEGIN { OFS = "\t" }
    NR == FNR {
        if (NF >= 2 && $1 != "name") {
            if (!($1 in current)) {
                current_order[++current_count] = $1
            }
            current[$1] = $2
        }
        next
    }
    $1 in current {
        print $1, current[$1]
        seen[$1] = 1
        next
    }
    { print }
    END {
        for (i = 1; i <= current_count; i++) {
            name = current_order[i]
            if (!(name in seen)) {
                print name, current[name]
            }
        }
    }
    ' "$_mbr_current" "$_mbr_baseline" > "$_mbr_output"
}

# Every TypeLisp benchmark row in a baseline must have a scalar-fair clang row
# beside it. Checking the *baseline* rather than the measurement keeps the hole
# from reopening: a leg that stopped measuring scalar-fair rows, or a refresh
# taken without them, would otherwise compare cleanly against a baseline that
# had quietly lost the comparison.
assert_scalar_fair_baseline() {
    _asfb_baseline=$1
    awk -F '\t' -v file="$_asfb_baseline" '
        NR == 1 && $1 == "name" { next }
        $1 ~ /^benchmark\/typelisp\// {
            name = substr($1, length("benchmark/typelisp/") + 1)
            if (!(name in seen)) { order[++count] = name; seen[name] = 1 }
            next
        }
        $1 ~ /^benchmark\/c-scalar\// {
            scalar[substr($1, length("benchmark/c-scalar/") + 1)] = 1
            next
        }
        END {
            for (i = 1; i <= count; i++) {
                name = order[i]
                if (!(name in scalar)) {
                    print "[ir-check] " file ": benchmark/c-scalar/" name \
                        " is missing" > "/dev/stderr"
                    missing += 1
                }
            }
            if (missing > 0) {
                print "[ir-check] every benchmark case needs a" \
                    " scalar-fair clang row" \
                    > "/dev/stderr"
                print "[ir-check] see perf/README.md; refresh with" \
                    " --update-baseline on Linux" > "/dev/stderr"
                exit 1
            }
        }
    ' "$_asfb_baseline"
}

# Host-independent coverage for the comparison itself: no compiler, no
# valgrind, no measurement.
self_test_case() {
    _stc_name=$1
    _stc_baseline=$2
    _stc_current=$3
    _stc_want_status=$4
    _stc_want_exit=$5

    set +e
    _stc_out=$(compare_counts "$_stc_baseline" "$_stc_current" 2>&1)
    _stc_exit=$?
    set -e

    if [ "$_stc_exit" -ne "$_stc_want_exit" ]; then
        echo "self-test $_stc_name: exit $_stc_exit, want $_stc_want_exit" >&2
        echo "$_stc_out" >&2
        return 1
    fi
    case "$_stc_out" in
        *"$_stc_want_status"*) ;;
        *)
            echo "self-test $_stc_name: missing status '$_stc_want_status'" >&2
            echo "$_stc_out" >&2
            return 1
            ;;
    esac
}

self_test() {
    SELF_TEST_DIR=${TMPDIR:-/tmp}/ir-check-self-test.$$
    mkdir -p "$SELF_TEST_DIR"
    BENCHMARKS=arith_loop
    printf 'name\tir_count\nbenchmark/typelisp/arith_loop\t437500077\nbenchmark/c-scalar/arith_loop\t500001469\n' \
        > "$SELF_TEST_DIR/base.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500077\nbenchmark/c-scalar/arith_loop\t500001469\n' \
        > "$SELF_TEST_DIR/exact.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500078\nbenchmark/c-scalar/arith_loop\t500001469\n' \
        > "$SELF_TEST_DIR/regressed.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500076\nbenchmark/c-scalar/arith_loop\t500001469\n' \
        > "$SELF_TEST_DIR/improved.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500077\n' \
        > "$SELF_TEST_DIR/missing-row.tsv"
    printf 'benchmark/typelisp/arith_loop\t437500077\nbenchmark/c-scalar/arith_loop\t500001469\nbenchmark/c/arith_loop\t1\n' \
        > "$SELF_TEST_DIR/extra-row.tsv"

    _st_status=0
    # Every row is exact, in both directions, by one instruction.
    self_test_case exact "$SELF_TEST_DIR/base.tsv" "$SELF_TEST_DIR/exact.tsv" "| ok" 0 || _st_status=1
    self_test_case regressed "$SELF_TEST_DIR/base.tsv" "$SELF_TEST_DIR/regressed.tsv" "| REGRESSION" 1 || _st_status=1
    self_test_case improved "$SELF_TEST_DIR/base.tsv" "$SELF_TEST_DIR/improved.tsv" "| IMPROVEMENT" 1 || _st_status=1
    # Fail-closed shapes still fail.
    self_test_case missing-row "$SELF_TEST_DIR/base.tsv" "$SELF_TEST_DIR/missing-row.tsv" "missing-current" 1 || _st_status=1
    self_test_case extra-row "$SELF_TEST_DIR/base.tsv" "$SELF_TEST_DIR/extra-row.tsv" "extra-current" 1 || _st_status=1

    # Explicit benchmark subsets compare only their selected rows, even when
    # the baseline carries other cases. Selected mismatches still fail.
    printf 'name\tir_count\nbenchmark/typelisp/a\t20\nbenchmark/c-scalar/a\t10\nbenchmark/typelisp/b\t30\nbenchmark/c-scalar/b\t15\n' \
        > "$SELF_TEST_DIR/subset-base.tsv"
    printf 'benchmark/typelisp/a\t20\nbenchmark/c-scalar/a\t10\n' \
        > "$SELF_TEST_DIR/subset-current.tsv"
    printf 'benchmark/typelisp/a\t21\nbenchmark/c-scalar/a\t10\n' \
        > "$SELF_TEST_DIR/subset-regressed.tsv"
    BENCHMARKS=a
    self_test_case benchmark-subset "$SELF_TEST_DIR/subset-base.tsv" "$SELF_TEST_DIR/subset-current.tsv" "| ok" 0 ||
        _st_status=1
    self_test_case benchmark-subset-regression "$SELF_TEST_DIR/subset-base.tsv" "$SELF_TEST_DIR/subset-regressed.tsv" \
        "REGRESSION" 1 || _st_status=1
    BENCHMARKS=arith_loop

    # An old baseline-only self_compile pin edit is rejected, wherever it is.
    printf 'name\tir_count\nbenchmark/typelisp/a\t20\nself_compile/compile_cli_opt1\t116113939625\nbenchmark/c-scalar/a\t10\n' \
        > "$SELF_TEST_DIR/pinned.tsv"
    if (assert_no_self_compile_row "$SELF_TEST_DIR/pinned.tsv") >/dev/null 2>&1; then
        echo "self-test pin-row: a self_compile pin row was accepted" >&2
        _st_status=1
    fi
    if ! (assert_no_self_compile_row "$SELF_TEST_DIR/subset-base.tsv") >/dev/null 2>&1; then
        echo "self-test pin-row: a benchmark-only baseline was rejected" >&2
        _st_status=1
    fi
    if (sh "$ROOT/scripts/check-instruction-counts.sh" --self-compile-only) >/dev/null 2>&1; then
        echo "self-test self-compile-only: the retired self_compile mode still runs" >&2
        _st_status=1
    fi

    # The refresh guard: a baseline that was not actually rewritten must not
    # report success.
    printf 'benchmark/typelisp/a\t1\n' \
        > "$SELF_TEST_DIR/refresh-current.tsv"
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\n' \
        > "$SELF_TEST_DIR/refresh-written.tsv"
    : > "$SELF_TEST_DIR/refresh-empty.tsv"
    if (assert_baseline_refreshed "$SELF_TEST_DIR/refresh-empty.tsv" \
        "$SELF_TEST_DIR/refresh-current.tsv") >/dev/null 2>&1; then
        echo "self-test refresh-empty: an unwritten baseline reported success" >&2
        _st_status=1
    fi
    if (assert_baseline_refreshed "$SELF_TEST_DIR/refresh-written.tsv" \
        "$SELF_TEST_DIR/refresh-empty.tsv") >/dev/null 2>&1; then
        echo "self-test refresh-nothing: an empty measurement reported success" >&2
        _st_status=1
    fi
    if ! (assert_baseline_refreshed "$SELF_TEST_DIR/refresh-written.tsv" \
        "$SELF_TEST_DIR/refresh-current.tsv") >/dev/null 2>&1; then
        echo "self-test refresh-written: a written baseline was rejected" >&2
        _st_status=1
    fi

    printf 'name\tir_count\nbenchmark/typelisp/b\t10\nbenchmark/typelisp/a\t20\n' \
        > "$SELF_TEST_DIR/merge-base.tsv"
    printf 'benchmark/typelisp/a\t21\nbenchmark/c-scalar/a\t7\n' \
        > "$SELF_TEST_DIR/merge-current.tsv"
    merge_baseline_rows \
        "$SELF_TEST_DIR/merge-current.tsv" \
        "$SELF_TEST_DIR/merge-base.tsv" \
        "$SELF_TEST_DIR/merge-result.tsv"
    if ! awk -F '\t' '
        $1 == "benchmark/typelisp/b" && $2 == 10 { other = 1 }
        $1 == "benchmark/typelisp/a" && $2 == 21 { tl = 1 }
        $1 == "benchmark/c-scalar/a" && $2 == 7 { c = 1 }
        END { exit other && tl && c ? 0 : 1 }
    ' "$SELF_TEST_DIR/merge-result.tsv"; then
        echo "self-test partial-refresh: selected rows did not merge while preserving the others" >&2
        _st_status=1
    fi

    # The scalar-fair row contract. The committed baselines are checked too,
    # not just fixtures: a real baseline missing real rows would pass a
    # fixture-only test.
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\nbenchmark/c-scalar/a\t3\n' \
        > "$SELF_TEST_DIR/scalar-complete.tsv"
    if ! (assert_scalar_fair_baseline "$SELF_TEST_DIR/scalar-complete.tsv") \
        >/dev/null 2>&1; then
        echo "self-test scalar-complete: a complete baseline was rejected" >&2
        _st_status=1
    fi
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\n' \
        > "$SELF_TEST_DIR/scalar-missing.tsv"
    if (assert_scalar_fair_baseline "$SELF_TEST_DIR/scalar-missing.tsv") \
        >/dev/null 2>&1; then
        echo "self-test scalar-missing: a baseline with no c-scalar row passed" >&2
        _st_status=1
    fi
    for _st_baseline in perf/insn-exec-baseline.tsv \
        perf/insn-exec-heavy-baseline.tsv; do
        [ -f "$ROOT/$_st_baseline" ] || continue
        if ! (assert_scalar_fair_baseline "$ROOT/$_st_baseline") \
            >/dev/null 2>&1; then
            echo "self-test committed-baseline: $_st_baseline lacks a" \
                "scalar-fair row" >&2
            _st_status=1
        fi
        if ! (assert_no_self_compile_row "$ROOT/$_st_baseline") >/dev/null 2>&1; then
            echo "self-test committed-baseline: $_st_baseline carries a self_compile pin row" >&2
            _st_status=1
        fi
    done

    rm -rf "$SELF_TEST_DIR"
    if [ "$_st_status" -ne 0 ]; then
        return 1
    fi
    echo "instruction-count comparison self-test passed"
}

if [ "$SELF_TEST" -eq 1 ]; then
    self_test
    exit 0
fi

case "$WORKDIR" in
    "" | / | . | ..)
        echo "unsafe --output path: $WORKDIR" >&2
        exit 2
        ;;
esac

case "$BASELINE" in
    "" | / | . | ..)
        echo "unsafe --baseline path: $BASELINE" >&2
        exit 2
        ;;
esac

case "$(uname -s)" in
    Linux*) ;;
    *)
        if [ "${GITHUB_ACTIONS:-}" = true ]; then
            echo "[ir-check] instruction-count baseline is Linux-only; a GitHub Actions run on $(uname -s) cannot pass it" >&2
            exit 1
        fi
        echo "[ir-check] instruction-count baseline is Linux-only; skipping on $(uname -s)"
        exit 0
        ;;
esac

if ! command -v valgrind >/dev/null 2>&1; then
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        echo "[ir-check] valgrind not found: GitHub Actions never passes the instruction-count gate without it" >&2
        exit 1
    fi
    echo "[ir-check] valgrind not found; skipping instruction-count baseline"
    exit 0
fi

if [ -f "$BASELINE" ]; then
    assert_no_self_compile_row "$BASELINE" || exit 1
fi

bench_compiler "$SEED_ARG"

update_command="scripts/check-instruction-counts.sh --update-baseline"
if [ "$BASELINE" != "$DEFAULT_BASELINE" ]; then
    update_command="$update_command --baseline $BASELINE"
fi
if [ "$RUNS" != 1 ]; then
    update_command="$update_command --runs $RUNS"
fi
if [ "$BENCHMARKS" != "$DEFAULT_BENCHMARKS" ]; then
    update_command="$update_command --benchmarks $BENCHMARKS"
fi
if [ "$WORKDIR" != "$DEFAULT_WORKDIR" ]; then
    update_command="$update_command --output $WORKDIR"
fi
if [ -n "$SEED_ARG" ]; then
    update_command="$update_command $SEED_ARG"
elif [ -n "${TYPELISP_BIN:-}" ]; then
    update_command="TYPELISP_BIN=$TYPELISP_BIN $update_command"
fi

rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

MEASURE_OUT="$WORKDIR/measure"
CURRENT="$WORKDIR/current.tsv"
DIFF_OUT="$WORKDIR/diff.txt"

# A baseline opts into auto-vectorized clang gating by carrying benchmark/c
# rows. The default per-PR baseline deliberately gates only TypeLisp and the
# scalar-fair comparison; the heavy baseline retains its existing three rows.
GATE_AUTO_C=1
if [ -f "$BASELINE" ] && ! awk -F '\t' '
    $1 ~ /^benchmark\/c\// { found = 1 }
    END { exit found ? 0 : 1 }
' "$BASELINE"; then
    GATE_AUTO_C=0
fi

# CI builds the compiler exactly once (the bootstrap fixpoint chain) and passes
# its stage2 in via TYPELISP_IR_CHECK_COMPILER; the seed->stage1->stage2 builds
# below are the standalone/local fallback only.
PREBUILT_COMPILER=${TYPELISP_IR_CHECK_COMPILER:-}
if [ -n "$PREBUILT_COMPILER" ]; then
    case "$PREBUILT_COMPILER" in
        /*) ;;
        *) PREBUILT_COMPILER="$ROOT/$PREBUILT_COMPILER" ;;
    esac
    [ -x "$PREBUILT_COMPILER" ] || {
        echo "TYPELISP_IR_CHECK_COMPILER is not executable: $PREBUILT_COMPILER" >&2
        exit 1
    }
    CHECK_COMPILER=$PREBUILT_COMPILER
    echo "[ir-check] measure with prebuilt stage2 compiler: $CHECK_COMPILER"
else
    . "$ROOT/scripts/lib-stage0.sh"
    build_selfhost_stage2 "$ROOT" "$COMPILER" "$WORKDIR/compiler" || exit 1
    CHECK_COMPILER=$(selfhost_stage2_path "$WORKDIR/compiler")
fi

echo "[ir-check] measure instruction-count subset"
env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
    scripts/measure-instruction-counts.sh \
    --runs "$RUNS" \
    --cases "$BENCHMARKS" \
    --output "$MEASURE_OUT" \
    --benchmarks-only \
    --c-scalar \
    "$CHECK_COMPILER"

awk -F '\t' -v gate_auto_c="$GATE_AUTO_C" '
BEGIN { OFS = "\t" }
NR == 1 { next }
$1 == "benchmark/c" && gate_auto_c != 1 { next }
{ print $1 "/" $2, $3 }
' "$MEASURE_OUT/summary.tsv" > "$CURRENT"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    mkdir -p "$(dirname -- "$BASELINE")"
    if [ -f "$BASELINE" ]; then
        merge_baseline_rows "$CURRENT" "$BASELINE" "$BASELINE.tmp"
        mv "$BASELINE.tmp" "$BASELINE"
    else
        {
            printf 'name\tir_count\n'
            cat "$CURRENT"
        } > "$BASELINE"
    fi
    assert_baseline_refreshed "$BASELINE" "$CURRENT"
    echo "[ir-check] baseline updated: $BASELINE"
    cat "$BASELINE"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "[ir-check] missing baseline: $BASELINE" >&2
    echo "[ir-check] create it with: $update_command" >&2
    exit 1
fi

assert_scalar_fair_baseline "$BASELINE" || exit 1

if compare_counts "$BASELINE" "$CURRENT" > "$DIFF_OUT"; then
    cat "$DIFF_OUT"
    echo "[ir-check] instruction-count baseline matches $BASELINE"
else
    cat "$DIFF_OUT" >&2
    echo "[ir-check] instruction counts differ from $BASELINE" >&2
    echo "[ir-check] update intentional changes with: $update_command" >&2
    exit 1
fi
