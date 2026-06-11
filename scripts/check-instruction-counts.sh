#!/usr/bin/env sh
set -eu

# check-instruction-counts.sh - Linux cachegrind instruction-count baseline gate.
#
# Benchmark metrics are exact. The self-compile metric carries a small
# cross-runner tolerance because cachegrind counts differ between WSL and GitHub
# hosted Linux runners even with fixed paths and a clean measured environment.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

DEFAULT_BENCHMARKS="arith_loop,array_sum,hashmap_churn,hashmap_grow,hashmap_insert,hashmap_get,spmd_reduce"
DEFAULT_BASELINE="$ROOT/perf/insn-exec-baseline.tsv"
DEFAULT_WORKDIR="target/instruction-count-check"
BASELINE=${TYPELISP_IR_CHECK_BASELINE:-$DEFAULT_BASELINE}
RUNS=${TYPELISP_IR_CHECK_RUNS:-1}
BENCHMARKS=${TYPELISP_IR_CHECK_BENCHMARKS:-$DEFAULT_BENCHMARKS}
SELF_COMPILE_TOLERANCE_PPM=${TYPELISP_IR_SELF_COMPILE_TOLERANCE_PPM:-5000}
WORKDIR=${TYPELISP_IR_CHECK_OUT:-$DEFAULT_WORKDIR}
UPDATE_BASELINE=0
BENCHMARKS_ONLY=0
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
    {
        printf 'name\tir_count\n'
        cat "$CURRENT"
    } > "$BASELINE"
    echo "[ir-check] baseline updated: $BASELINE"
    cat "$BASELINE"
    exit 0
fi

if [ ! -f "$BASELINE" ]; then
    echo "[ir-check] missing baseline: $BASELINE" >&2
    echo "[ir-check] create it with: $update_command" >&2
    exit 1
fi

if awk -F '\t' -v self_compile_tolerance_ppm="$SELF_COMPILE_TOLERANCE_PPM" '
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
BEGIN {
    print "metric | baseline | current | delta | pct | tolerance | status"
}
NR == FNR {
    if (FNR == 1 && $1 == "name") {
        next
    }
    if (NF < 2) {
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
        print name " | " base " | " now " | " signed(delta) " | " pct(delta, base + 0) " | " tolerance " | " status
    }
    for (i = 1; i <= current_count; i++) {
        name = current_order[i]
        if (!(name in baseline)) {
            print name " | <missing> | " current[name] " | n/a | n/a | n/a | extra-current"
            failed = 1
        }
    }
    exit failed ? 1 : 0
}
' "$BASELINE" "$CURRENT" > "$DIFF_OUT"; then
    cat "$DIFF_OUT"
    echo "[ir-check] instruction-count baseline matches $BASELINE"
else
    cat "$DIFF_OUT" >&2
    echo "[ir-check] instruction counts differ from $BASELINE" >&2
    echo "[ir-check] update intentional changes with: $update_command" >&2
    exit 1
fi
