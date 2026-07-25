#!/usr/bin/env sh
set -eu

# check-instruction-counts.sh - Linux cachegrind instruction-count baseline gate.
#
# Benchmark metrics are exact. Each scalar TypeLisp benchmark is paired with
# both auto-vectorized clang -O2 and scalar-fair clang -O2
# -fno-vectorize/-fno-slp-vectorize rows. The self-compile metric carries a small
# cross-runner tolerance because cachegrind counts differ between WSL and GitHub
# hosted Linux runners even with fixed paths and a clean measured environment.
#
# That tolerance absorbs real drift as well as noise, and a tolerated result
# never refreshes the baseline. Drift is therefore cumulative against a fixed
# baseline: once it approaches the tolerance, the next change to cross the line
# reports the accumulated total rather than its own cost, and gets blamed for it.
# Rows using a large share of their budget are flagged so that is visible before
# it happens rather than after. Refs #5641.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEFAULT_BENCHMARKS="arith_loop,array_sum,borrowed_disjoint_store,hashmap_churn,hashmap_grow,hashmap_insert,hashmap_get,spmd_reduce,opt_quicksort,opt_crc32,opt_bytecode_vm"
DEFAULT_BASELINE="$ROOT/perf/insn-exec-baseline.tsv"
DEFAULT_WORKDIR="target/instruction-count-check"
BASELINE=${TYPELISP_IR_CHECK_BASELINE:-$DEFAULT_BASELINE}
RUNS=${TYPELISP_IR_CHECK_RUNS:-1}
BENCHMARKS=${TYPELISP_IR_CHECK_BENCHMARKS:-$DEFAULT_BENCHMARKS}
SELF_COMPILE_TOLERANCE_PPM=${TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM:-5000}
STALE_BUDGET_PCT=${TYPELISP_IR_STALE_BUDGET_PCT:-60}
WORKDIR=${TYPELISP_IR_CHECK_OUT:-$DEFAULT_WORKDIR}
UPDATE_BASELINE=0
BENCHMARKS_ONLY=0
SELF_COMPILE_ONLY=0
SELF_TEST=0
SEED_ARG=

usage() {
    cat <<'EOF'
usage: scripts/check-instruction-counts.sh [options] [typelisp-seed]

Options:
  --update-baseline    Regenerate the selected baseline TSV
  --baseline FILE      Baseline TSV path (default: perf/insn-exec-baseline.tsv)
  --runs N             Cachegrind runs per metric (default: 1)
  --benchmarks LIST    Comma-separated benchmark names for the per-PR gate
  --benchmarks-only    Measure benchmark cases only, not self_compile
  --self-test          Check the comparison logic against fixtures and exit;
                       needs no compiler, valgrind, or Linux host
  --self-compile-only  Measure and compare self_compile/compile_cli_opt1 only;
                       with --update-baseline, rewrites only that row and
                       preserves every benchmark row (benchmark/c and
                       benchmark/c-scalar rows depend on the local clang;
                       benchmark/typelisp rows are deterministic and unaffected
                       by a self-compile ratchet)
  --output DIR         Work directory (default: target/instruction-count-check)
  -h, --help           Show this help

Environment:
  TYPELISP_BIN                  Seed compiler when no argument is given
  TYPELISP_IR_CHECK_COMPILER    Prebuilt compiler to measure with; skips the
                                internal seed->stage1->stage2 builds (CI passes
                                the bootstrap fixpoint stage2 here)
  TYPELISP_IR_CHECK_RUNS        Default --runs
  TYPELISP_IR_CHECK_BENCHMARKS  Default --benchmarks
  TYPELISP_IR_CHECK_BASELINE    Default --baseline
  TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM
                                Default self_compile tolerance in ppm (5000 = 0.5%)
  TYPELISP_IR_STALE_BUDGET_PCT  Warn when a tolerated row uses this share of its
                                tolerance (default 60), so accumulated drift is
                                visible before it lands on an unrelated change
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
            BENCHMARKS_ONLY=1
            shift
            ;;
        --self-compile-only)
            SELF_COMPILE_ONLY=1
            shift
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

case "$SELF_COMPILE_TOLERANCE_PPM" in
    "" | *[!0-9]*)
        echo "TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM must be a non-negative integer: $SELF_COMPILE_TOLERANCE_PPM" >&2
        exit 2
        ;;
esac

case "$STALE_BUDGET_PCT" in
    "" | *[!0-9]* | 0)
        echo "TYPELISP_IR_STALE_BUDGET_PCT must be a positive integer: $STALE_BUDGET_PCT" >&2
        exit 2
        ;;
esac

# The comparison program, held in a variable so --self-test can exercise the
# exact logic CI runs rather than a copy of it. Contains no single quotes.
IR_COMPARE_AWK='
function signed(n,    s) {
    s = sprintf("%.0f", n)
    if (n > 0) {
        return "+" s
    }
    return s
}
function tolerance_for(name, base) {
    if (name == "self_compile/compile_cli_opt1") {
        return int(((base + 0) * self_compile_tolerance_ppm) / 1000000)
    }
    return 0
}
function pct(delta, base) {
    if (base == 0) {
        return "n/a"
    }
    return sprintf("%+.6f%%", (delta * 100.0) / base)
}
# Share of the tolerance for a row consumed by `delta`, as a percentage. Rows
# with a zero tolerance are exact and can never be partially consumed.
function budget_used(delta, tolerance,    d) {
    if (tolerance <= 0) {
        return 0
    }
    d = delta < 0 ? -delta : delta
    return (d * 100.0) / tolerance
}
BEGIN {
    print "metric | baseline | current | delta | pct | tolerance | status"
    stale = 0
}
NR == FNR {
    if (FNR == 1 && $1 == "name") {
        next
    }
    if (NF < 2) {
        next
    }
    if (self_compile_only == 1 && $1 != "self_compile/compile_cli_opt1") {
        next
    }
    if (benchmarks_only == 1 && $1 == "self_compile/compile_cli_opt1") {
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
    current[$1] = $2
    current_order[++current_count] = $1
}
END {
    failed = 0
    for (i = 1; i <= baseline_count; i++) {
        name = baseline_order[i]
        base = baseline[name]
        if (!(name in current)) {
            print name " | " base " | <missing> | n/a | n/a | n/a | missing-current"
            failed = 1
            continue
        }
        now = current[name]
        delta = (now + 0) - (base + 0)
        tolerance = tolerance_for(name, base)
        status = "ok"
        if (delta > tolerance) {
            status = "REGRESSION"
            failed = 1
        } else if (delta < -tolerance) {
            status = "IMPROVEMENT"
            failed = 1
        } else if (delta != 0) {
            status = "within-tolerance"
        }
        used = budget_used(delta, tolerance)
        if (used >= stale_budget_pct) {
            status = status " (" sprintf("%d", used) "% of tolerance)"
            stale = 1
        }
        print name " | " base " | " now " | " signed(delta) " | " pct(delta, base + 0) " | " tolerance " | " status
    }
    for (i = 1; i <= current_count; i++) {
        name = current_order[i]
        if (!(name in baseline)) {
            print name " | <missing> | " current[name] " | n/a | n/a | n/a | extra-current"
            failed = 1
        }
    }
    if (stale) {
        print ""
        print "[ir-check] a tolerance-carrying row is at " stale_budget_pct "%+ of its budget."
        print "[ir-check] the tolerance absorbs cross-runner noise, but it also absorbs real"
        print "[ir-check] drift, and a tolerated result never refreshes the baseline. Once"
        print "[ir-check] the baseline lags main, the next change to cross the line reports"
        print "[ir-check] the accumulated total rather than its own cost. Refresh the row"
        print "[ir-check] against main before attributing a regression to a change. Refs #5641."
    }
    exit failed ? 1 : 0
}
'

# Compare a baseline TSV against a current TSV and render the report on stdout.
# Exits non-zero when any row regresses, improves, or is missing or extra.
compare_counts() {
    awk -F '	' \
        -v self_compile_tolerance_ppm="$SELF_COMPILE_TOLERANCE_PPM" \
        -v benchmarks_only="$BENCHMARKS_ONLY" \
        -v self_compile_only="$SELF_COMPILE_ONLY" \
        -v stale_budget_pct="$STALE_BUDGET_PCT" \
        "$IR_COMPARE_AWK" "$1" "$2"
}

# Host-independent coverage for the comparison itself: no compiler, no
# valgrind, no measurement. Fixtures use the real numbers from the runs that
# motivated the budget annotation so the cases stay recognizable.
self_test_row() {
    printf 'name\tir_count\nbenchmark/typelisp/arith_loop\t%s\nself_compile/compile_cli_opt1\t%s\n' \
        "$1" "$2"
}

self_test_case() {
    _stc_name=$1
    _stc_current=$2
    _stc_want_status=$3
    _stc_want_exit=$4
    _stc_want_note=$5

    set +e
    _stc_out=$(compare_counts "$SELF_TEST_DIR/base.tsv" "$_stc_current" 2>&1)
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
    case "$_stc_out" in
        *"of its budget."*) _stc_saw_note=yes ;;
        *) _stc_saw_note=no ;;
    esac
    if [ "$_stc_saw_note" != "$_stc_want_note" ]; then
        echo "self-test $_stc_name: drift note $_stc_saw_note, want $_stc_want_note" >&2
        echo "$_stc_out" >&2
        return 1
    fi
}

# A refresh that writes nothing must not report success. `--update-baseline` is
# a required pre-PR step whose whole job is to rewrite rows, and a tolerated
# row never refreshes on its own, so a no-op refresh that still prints
# "baseline updated" is how baseline drift accumulates against an author who
# ran the step and saw it pass. Every measured row must reach the file.
# Refs #5697, #5641.
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

# Every TypeLisp benchmark row in a baseline must have both clang rows beside
# it. Checking the *baseline* rather than the measurement is what keeps the hole
# from reopening: a leg that stopped measuring scalar-fair rows, or a refresh
# taken without them, would otherwise compare cleanly against a baseline that
# had quietly lost the comparison (#5678).
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
        $1 ~ /^benchmark\/c\// {
            auto[substr($1, length("benchmark/c/") + 1)] = 1
        }
        END {
            for (i = 1; i <= count; i++) {
                name = order[i]
                if (!(name in auto)) {
                    print "[ir-check] " file ": benchmark/c/" name \
                        " is missing" > "/dev/stderr"
                    missing += 1
                }
                if (!(name in scalar)) {
                    print "[ir-check] " file ": benchmark/c-scalar/" name \
                        " is missing" > "/dev/stderr"
                    missing += 1
                }
            }
            if (missing > 0) {
                print "[ir-check] every benchmark case needs both a" \
                    " scalar-fair and an auto-vectorized clang row" \
                    > "/dev/stderr"
                print "[ir-check] see perf/README.md; refresh with" \
                    " --update-baseline on Linux" > "/dev/stderr"
                exit 1
            }
        }
    ' "$_asfb_baseline"
}

self_test() {
    SELF_TEST_DIR=${TMPDIR:-/tmp}/ir-check-self-test.$$
    mkdir -p "$SELF_TEST_DIR"
    # 55356290376 is the committed self_compile baseline these cases were taken
    # against; 276781451 is its 0.5% tolerance.
    self_test_row 437500077 55356290376 > "$SELF_TEST_DIR/base.tsv"
    self_test_row 437500077 55608478646 > "$SELF_TEST_DIR/drifted.tsv"
    self_test_row 437500077 55667745289 > "$SELF_TEST_DIR/regressed.tsv"
    self_test_row 437500077 55366290376 > "$SELF_TEST_DIR/small.tsv"
    self_test_row 437500077 55356290376 > "$SELF_TEST_DIR/exact.tsv"
    self_test_row 437000000 55356290376 > "$SELF_TEST_DIR/improved.tsv"
    printf 'name\tir_count\nself_compile/compile_cli_opt1\t55356290376\n' \
        > "$SELF_TEST_DIR/missing-row.tsv"

    _st_status=0
    # A tolerated row at 91% of budget still passes, and says so. This is the
    # case that silently consumed the budget before the annotation existed.
    self_test_case drifted "$SELF_TEST_DIR/drifted.tsv" \
        "within-tolerance (91% of tolerance)" 0 yes || _st_status=1
    # A regression still fails, now with the share of budget it used.
    self_test_case regressed "$SELF_TEST_DIR/regressed.tsv" \
        "REGRESSION (112% of tolerance)" 1 yes || _st_status=1
    # Ordinary small drift stays quiet so the note keeps its meaning.
    self_test_case small "$SELF_TEST_DIR/small.tsv" \
        "| within-tolerance" 0 no || _st_status=1
    self_test_case exact "$SELF_TEST_DIR/exact.tsv" "| ok" 0 no || _st_status=1
    # Exact-tolerance rows cannot be partially consumed, so they never annotate.
    self_test_case improved "$SELF_TEST_DIR/improved.tsv" \
        "| IMPROVEMENT" 1 no || _st_status=1
    # Fail-closed shapes are unchanged.
    self_test_case missing-row "$SELF_TEST_DIR/missing-row.tsv" \
        "missing-current" 1 no || _st_status=1

    # The refresh guard: a baseline that was not actually rewritten must not
    # report success, which is the failure shape #5697 is about.
    printf 'self_compile/compile_cli_opt1\t1\n' \
        > "$SELF_TEST_DIR/refresh-current.tsv"
    printf 'name\tir_count\nself_compile/compile_cli_opt1\t1\n' \
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

    # The scalar-fair row contract (#5678). The committed baselines are checked
    # too, not just fixtures: the hole this closes was a real baseline missing
    # real rows, so a fixture-only test would have passed throughout it.
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\nbenchmark/c/a\t2\nbenchmark/c-scalar/a\t3\n' \
        > "$SELF_TEST_DIR/scalar-complete.tsv"
    if ! (assert_scalar_fair_baseline "$SELF_TEST_DIR/scalar-complete.tsv") \
        >/dev/null 2>&1; then
        echo "self-test scalar-complete: a complete baseline was rejected" >&2
        _st_status=1
    fi
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\nbenchmark/c/a\t2\n' \
        > "$SELF_TEST_DIR/scalar-missing.tsv"
    if (assert_scalar_fair_baseline "$SELF_TEST_DIR/scalar-missing.tsv") \
        >/dev/null 2>&1; then
        echo "self-test scalar-missing: a baseline with no c-scalar row passed" >&2
        _st_status=1
    fi
    printf 'name\tir_count\nbenchmark/typelisp/a\t1\nbenchmark/c-scalar/a\t3\n' \
        > "$SELF_TEST_DIR/auto-missing.tsv"
    if (assert_scalar_fair_baseline "$SELF_TEST_DIR/auto-missing.tsv") \
        >/dev/null 2>&1; then
        echo "self-test auto-missing: a baseline with no benchmark/c row passed" >&2
        _st_status=1
    fi
    for _st_baseline in perf/insn-exec-baseline.tsv \
        perf/insn-exec-heavy-baseline.tsv; do
        if [ -f "$ROOT/$_st_baseline" ] &&
            ! (assert_scalar_fair_baseline "$ROOT/$_st_baseline") \
            >/dev/null 2>&1; then
            echo "self-test committed-baseline: $_st_baseline lacks a" \
                "scalar-fair row" >&2
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

if [ "$BENCHMARKS_ONLY" -eq 1 ] && [ "$SELF_COMPILE_ONLY" -eq 1 ]; then
    echo "--benchmarks-only and --self-compile-only are mutually exclusive" >&2
    exit 2
fi

# Scalar-fair C rows are required of every benchmark leg, not of one baseline
# file. This used to key off the baseline's *name*, which made the rows
# structurally unreachable for the heavy leg and left 5 of 16 cases with no
# scalar-fair comparison at all (#5678) -- an ordering artifact of #5176 writing
# the policy and #5184 promoting the heavy corpus into the gate afterwards.
# `string_scan` was the worst of it: its C baseline is a serial
# `acc = acc*131 + byte` recurrence clang cannot vectorize, so its ratio was
# measured only against auto-vectorized clang, which is exactly the conflation
# between "our scalar codegen is behind" and "their auto-vectorizer won" that
# #5176 existed to remove.
SCALAR_FAIR=1
if [ "$SELF_COMPILE_ONLY" -eq 1 ]; then
    SCALAR_FAIR=0
fi

case "$(uname -s)" in
    Linux*) ;;
    *)
        echo "[ir-check] instruction-count baseline is Linux-only; skipping on $(uname -s)"
        exit 0
        ;;
esac

if ! command -v valgrind >/dev/null 2>&1; then
    echo "[ir-check] valgrind not found; skipping instruction-count baseline"
    exit 0
fi

if [ -n "$SEED_ARG" ]; then
    SEED=$SEED_ARG
elif [ -n "${TYPELISP_BIN:-}" ]; then
    SEED=$TYPELISP_BIN
else
    . "$ROOT/scripts/lib-stage0.sh"
    SEED=$(resolve_stage0_compiler "$ROOT") || exit 1
fi

case "$SEED" in
    /*) ;;
    *) SEED="$ROOT/$SEED" ;;
esac

[ -x "$SEED" ] || {
    echo "typelisp seed is not executable: $SEED" >&2
    exit 1
}

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
if [ "$BENCHMARKS_ONLY" -eq 1 ]; then
    update_command="$update_command --benchmarks-only"
fi
if [ "$SELF_COMPILE_ONLY" -eq 1 ]; then
    update_command="$update_command --self-compile-only"
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
    mkdir -p "$WORKDIR/compiler/stage1" "$WORKDIR/compiler/stage2"
    STAGE1_COMPILER="$WORKDIR/compiler/stage1/typelisp"
    CHECK_COMPILER="$WORKDIR/compiler/stage2/typelisp"
    echo "[ir-check] build current stage1 compiler for measurement: $STAGE1_COMPILER"
    scripts/build-stage0.sh "$SEED" "$STAGE1_COMPILER"
    echo "[ir-check] build current stage2 compiler for measurement: $CHECK_COMPILER"
    scripts/build-stage0.sh "$STAGE1_COMPILER" "$CHECK_COMPILER"
fi

echo "[ir-check] measure instruction-count subset"
measure_args=
if [ "$BENCHMARKS_ONLY" -eq 1 ]; then
    measure_args="--benchmarks-only"
elif [ "$SELF_COMPILE_ONLY" -eq 1 ]; then
    measure_args="--self-compile-only"
fi
if [ "$SELF_COMPILE_ONLY" -eq 0 ] && [ "$SCALAR_FAIR" -eq 1 ]; then
    measure_args="$measure_args --c-scalar"
fi
env -i PATH="$PATH" HOME="${HOME:-}" LC_ALL=C \
    scripts/measure-instruction-counts.sh \
    --runs "$RUNS" \
    --cases "$BENCHMARKS" \
    --output "$MEASURE_OUT" \
    $measure_args \
    "$CHECK_COMPILER"

awk -F '\t' '
BEGIN { OFS = "\t" }
NR == 1 { next }
{ print $1 "/" $2, $3 }
' "$MEASURE_OUT/summary.tsv" > "$CURRENT"

if [ "$UPDATE_BASELINE" -eq 1 ]; then
    mkdir -p "$(dirname -- "$BASELINE")"
    if [ "$SELF_COMPILE_ONLY" -eq 1 ] && [ -f "$BASELINE" ]; then
        # Rewrite only the self_compile row. benchmark/typelisp rows are
        # deterministic and out of scope for a self-compile ratchet;
        # benchmark/c and benchmark/c-scalar rows depend on the local clang
        # version and must not absorb its noise.
        awk -F '\t' '
        BEGIN { OFS = "\t" }
        NR == FNR {
            if (NF >= 2 && $1 != "name") {
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
            for (name in current) {
                if (!(name in seen)) {
                    print name, current[name]
                }
            }
        }
        ' "$CURRENT" "$BASELINE" > "$BASELINE.tmp"
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

if [ "$SELF_COMPILE_ONLY" -eq 0 ]; then
    assert_scalar_fair_baseline "$BASELINE" || exit 1
fi

if compare_counts "$BASELINE" "$CURRENT" > "$DIFF_OUT"; then
    cat "$DIFF_OUT"
    echo "[ir-check] instruction-count baseline matches $BASELINE"
else
    cat "$DIFF_OUT" >&2
    echo "[ir-check] instruction counts differ from $BASELINE" >&2
    echo "[ir-check] update intentional changes with: $update_command" >&2
    exit 1
fi
