#!/usr/bin/env sh
set -eu

# benchmark-compile-vs-clang.sh - the compile lane's reference instrument.
#
# For every benchmarks/<name>/ pair holding bench.tl and baseline.c, build both
# sides to an executable the way the benchmark harnesses do: TypeLisp `build`
# at --opt-level 1 and 2, clang with -std=c11 -DNDEBUG at -O0 and -O2. Each leg
# runs --runs times; its cell is the fastest build and the smallest peak RSS
# observed through GNU time -f '%M'. Writes
# target/compile-vs-clang/results.tsv, then prints the geomean TypeLisp/clang
# wall-time and peak-memory ratios for opt1:-O0 and opt2:-O2. A pair whose build
# fails is skipped with a note on stderr; the script is a local measurement, not
# a CI gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
usage: scripts/benchmark-compile-vs-clang.sh [options] [typelisp-compiler]

Options:
  --runs N        Build repetitions per leg; each cell is the fastest (default: 3)
  --only NAME     Measure only benchmarks/NAME
  -h, --help      Show this help

Environment:
  TYPELISP_COMPILE_VS_CLANG_OUT       Output root (default target/compile-vs-clang)
  TYPELISP_COMPILE_VS_CLANG_RUNS      Default for --runs
  TYPELISP_COMPILE_VS_CLANG_TIME_BIN  GNU time binary for peak RSS (default /usr/bin/time)
EOF
}

COMPILER=
RUNS=${TYPELISP_COMPILE_VS_CLANG_RUNS:-3}
ONLY=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --runs)
            [ "$#" -ge 2 ] || {
                echo "missing value for --runs" >&2
                exit 2
            }
            RUNS=$2
            shift 2
            ;;
        --only)
            [ "$#" -ge 2 ] || {
                echo "missing value for --only" >&2
                exit 2
            }
            ONLY=$2
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
            [ -z "$COMPILER" ] || {
                echo "unexpected argument: $1" >&2
                usage >&2
                exit 2
            }
            COMPILER=$1
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

if [ -z "$COMPILER" ]; then
    COMPILER=target/stage0/typelisp
fi
case "$COMPILER" in
    /* | [A-Za-z]:[/\\]*) ;;
    *) COMPILER="$ROOT/$COMPILER" ;;
esac
if [ ! -x "$COMPILER" ]; then
    echo "typelisp compiler is not executable: $COMPILER" >&2
    echo "fetch the published seed with scripts/fetch-stage0.sh" >&2
    exit 1
fi

case "$ONLY" in
    "") ;;
    *[!A-Za-z0-9_.-]*)
        echo "invalid --only name: $ONLY" >&2
        exit 2
        ;;
esac

EXE=
TL_TARGET_ARGS=
case "$(uname -s)" in
    Linux*) ;;
    MINGW* | MSYS* | CYGWIN*)
        EXE=.exe
        TL_TARGET_ARGS="--target windows-x86_64"
        ;;
    *)
        echo "compile-vs-clang benchmarks are unsupported on this host: $(uname -s)" >&2
        exit 1
        ;;
esac

TIME_BIN=${TYPELISP_COMPILE_VS_CLANG_TIME_BIN:-/usr/bin/time}
if [ ! -x "$TIME_BIN" ]; then
    echo "GNU time is required for peak RSS: $TIME_BIN" >&2
    echo "install it (pacman -S time, apt install time) or set TYPELISP_COMPILE_VS_CLANG_TIME_BIN" >&2
    exit 1
fi
command -v clang >/dev/null 2>&1 || {
    echo "missing tool: clang" >&2
    exit 1
}

if [ -n "$ONLY" ]; then
    if [ ! -f "$ROOT/benchmarks/$ONLY/bench.tl" ] || [ ! -f "$ROOT/benchmarks/$ONLY/baseline.c" ]; then
        echo "no benchmark pair for --only $ONLY" >&2
        echo "need benchmarks/$ONLY/bench.tl and benchmarks/$ONLY/baseline.c" >&2
        exit 2
    fi
fi

WORKDIR=${TYPELISP_COMPILE_VS_CLANG_OUT:-"$ROOT/target/compile-vs-clang"}
RESULTS="$WORKDIR/results.tsv"
BUILDDIR="$WORKDIR/build"
LOGDIR="$WORKDIR/log"
rm -rf "$WORKDIR"
mkdir -p "$BUILDDIR" "$LOGDIR"
printf 'name\ttl_opt1_ms\ttl_opt1_kib\tclang_O0_ms\tclang_O0_kib\ttl_opt2_ms\ttl_opt2_kib\tclang_O2_ms\tclang_O2_kib\n' > "$RESULTS"

now_ms() {
    value=$(date +%s%3N 2>/dev/null || true)
    case "$value" in
        *[!0-9]* | "") ;;
        *)
            printf '%s\n' "$value"
            return 0
            ;;
    esac
    perl -MTime::HiRes=time -e 'printf "%d\n", time() * 1000'
}

first_log_line() {
    awk 'NF { print substr($0, 1, 300); exit }' "$1" 2>/dev/null || true
}

# measure_build BIN STEM COMMAND...
#   Build COMMAND $RUNS times with its logs on STEM, each under GNU time's
#   peak-RSS report. Sets BEST_MS and BEST_KIB to the smallest observed wall
#   time and peak RSS, or LAST_ERROR and a non-zero status on a failure.
measure_build() {
    _mbb_bin=$1
    _mbb_stem=$2
    shift 2
    BEST_MS=
    BEST_KIB=
    _mbb_run=1
    while [ "$_mbb_run" -le "$RUNS" ]; do
        rm -f "$_mbb_bin" "$_mbb_stem.rss"
        _mbb_out="$_mbb_stem.run.$_mbb_run.stdout"
        _mbb_err="$_mbb_stem.run.$_mbb_run.stderr"
        _mbb_start=$(now_ms)
        set +e
        "$TIME_BIN" -f '%M' -o "$_mbb_stem.rss" "$@" >"$_mbb_out" 2>"$_mbb_err"
        _mbb_status=$?
        set -e
        _mbb_end=$(now_ms)
        if [ "$_mbb_status" -ne 0 ]; then
            _mbb_reason=$(first_log_line "$_mbb_err")
            [ -n "$_mbb_reason" ] || _mbb_reason=$(first_log_line "$_mbb_out")
            if [ -n "$_mbb_reason" ]; then
                LAST_ERROR="build exited $_mbb_status: $_mbb_reason"
            else
                LAST_ERROR="build exited $_mbb_status"
            fi
            return 1
        fi
        if [ ! -x "$_mbb_bin" ]; then
            LAST_ERROR="build wrote no executable at $_mbb_bin"
            return 1
        fi
        _mbb_kib=$(cat "$_mbb_stem.rss" 2>/dev/null || true)
        case "$_mbb_kib" in
            "" | *[!0-9]*)
                LAST_ERROR="no peak RSS from $TIME_BIN: $_mbb_stem.rss"
                return 1
                ;;
        esac
        _mbb_ms=$((_mbb_end - _mbb_start))
        if [ -z "$BEST_MS" ] || [ "$_mbb_ms" -lt "$BEST_MS" ]; then
            BEST_MS=$_mbb_ms
        fi
        if [ -z "$BEST_KIB" ] || [ "$_mbb_kib" -lt "$BEST_KIB" ]; then
            BEST_KIB=$_mbb_kib
        fi
        _mbb_run=$((_mbb_run + 1))
    done
}

# record_leg LABEL BIN STEM COMMAND...
#   Measure one build leg of the current pair into TL1_*/CLANG_O0_*/TL2_*/
#   CLANG_O2_*, or set SKIP_REASON and fail.
record_leg() {
    _rl_label=$1
    _rl_bin=$2
    _rl_stem=$3
    shift 3
    if ! measure_build "$_rl_bin" "$_rl_stem" "$@"; then
        SKIP_REASON="$_rl_label: $LAST_ERROR"
        return 1
    fi
    case "$_rl_label" in
        tl-opt1)
            TL1_MS=$BEST_MS
            TL1_KIB=$BEST_KIB
            ;;
        clang-O0)
            CLANG_O0_MS=$BEST_MS
            CLANG_O0_KIB=$BEST_KIB
            ;;
        tl-opt2)
            TL2_MS=$BEST_MS
            TL2_KIB=$BEST_KIB
            ;;
        clang-O2)
            CLANG_O2_MS=$BEST_MS
            CLANG_O2_KIB=$BEST_KIB
            ;;
    esac
}

# geomean_ratio COLUMN_A COLUMN_B
#   Print the geometric mean of A/B over the measured rows of results.tsv.
geomean_ratio() {
    awk -F '\t' -v a="$1" -v b="$2" '
        NR > 1 {
            total += log($a / $b)
            rows++
        }
        END {
            if (rows == 0) {
                printf "n/a"
                exit
            }
            printf "%.2f", exp(total / rows)
        }' "$RESULTS"
}

measured=0
skipped=0
for case_dir in "$ROOT"/benchmarks/*/; do
    [ -f "$case_dir/bench.tl" ] || continue
    [ -f "$case_dir/baseline.c" ] || continue
    name=$(basename -- "$case_dir")
    if [ -n "$ONLY" ] && [ "$name" != "$ONLY" ]; then
        continue
    fi
    echo "[compile-vs-clang] $name"
    TL1_BIN="$BUILDDIR/$name.tl-opt1$EXE"
    CLANG_O0_BIN="$BUILDDIR/$name.clang-O0$EXE"
    TL2_BIN="$BUILDDIR/$name.tl-opt2$EXE"
    CLANG_O2_BIN="$BUILDDIR/$name.clang-O2$EXE"
    # Host target knobs are intentionally simple space-separated flags.
    # shellcheck disable=SC2086
    if record_leg tl-opt1 "$TL1_BIN" "$LOGDIR/$name.tl-opt1" \
        "$COMPILER" build "$case_dir/bench.tl" --opt-level 1 -o "$TL1_BIN" $TL_TARGET_ARGS &&
        record_leg clang-O0 "$CLANG_O0_BIN" "$LOGDIR/$name.clang-O0" \
            clang -O0 -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_O0_BIN" &&
        record_leg tl-opt2 "$TL2_BIN" "$LOGDIR/$name.tl-opt2" \
            "$COMPILER" build "$case_dir/bench.tl" --opt-level 2 -o "$TL2_BIN" $TL_TARGET_ARGS &&
        record_leg clang-O2 "$CLANG_O2_BIN" "$LOGDIR/$name.clang-O2" \
            clang -O2 -std=c11 -DNDEBUG "$case_dir/baseline.c" -o "$CLANG_O2_BIN"
    then
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" \
            "$TL1_MS" "$TL1_KIB" \
            "$CLANG_O0_MS" "$CLANG_O0_KIB" \
            "$TL2_MS" "$TL2_KIB" \
            "$CLANG_O2_MS" "$CLANG_O2_KIB" >> "$RESULTS"
        measured=$((measured + 1))
    else
        echo "[compile-vs-clang] skip $name: $SKIP_REASON" >&2
        skipped=$((skipped + 1))
    fi
done

if [ "$measured" -eq 0 ]; then
    echo "no benchmark pair could be built (skipped $skipped); see the notes above" >&2
    exit 1
fi

printf '[compile-vs-clang] %s pairs measured, %s skipped, best of %s builds\n' \
    "$measured" "$skipped" "$RUNS"
printf '[compile-vs-clang] headline: time TL/clang opt1:-O0 %sx, opt2:-O2 %sx; peak RSS TL/clang opt1:-O0 %sx, opt2:-O2 %sx\n' \
    "$(geomean_ratio 2 4)" \
    "$(geomean_ratio 6 8)" \
    "$(geomean_ratio 3 5)" \
    "$(geomean_ratio 7 9)"
echo "[compile-vs-clang] results: $RESULTS"
