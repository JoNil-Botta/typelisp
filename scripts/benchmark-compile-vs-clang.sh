#!/usr/bin/env sh
set -eu

# benchmark-compile-vs-clang.sh - the compile lane's reference instrument.
#
# For every benchmarks/<name>/ pair holding bench.tl and baseline.c, build both
# sides to an executable the way the benchmark harnesses do: TypeLisp `build`
# at --opt-level 1 and 2, clang with -std=c11 -DNDEBUG at -O0 and -O2. Each leg
# runs --runs times; its cell is the fastest build and the smallest peak RSS
# observed through GNU time -f '%M'. On Linux with a usable perf it also counts
# exact user-space instructions (instructions:u) for one extra build per leg.
# Writes target/compile-vs-clang/results.tsv, then prints the geomean
# TypeLisp/clang wall-time, peak-memory and, when counted, instruction ratios for
# opt1:-O0 and opt2:-O2. A pair whose build fails is skipped with a note on
# stderr; the script is a local measurement, not a CI gate.

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

usage() {
    cat <<'EOF'
usage: scripts/benchmark-compile-vs-clang.sh [options] [typelisp-compiler]

Options:
  --runs N        Build repetitions per leg; each cell is the fastest (default: 3)
  --only NAME     Measure only benchmarks/NAME
  --no-perf       Skip the exact instructions:u counts (they are n/a)
  -h, --help      Show this help

Environment:
  TYPELISP_COMPILE_VS_CLANG_OUT       Output root (default target/compile-vs-clang)
  TYPELISP_COMPILE_VS_CLANG_RUNS      Default for --runs
  TYPELISP_COMPILE_VS_CLANG_TIME_BIN  GNU time binary for peak RSS
                                      (default /usr/bin/time, then ~/.local/bin/time)
EOF
}

COMPILER=
RUNS=${TYPELISP_COMPILE_VS_CLANG_RUNS:-3}
ONLY=
PERF_WANTED=1
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
        --no-perf)
            PERF_WANTED=0
            shift
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

TIME_BIN=${TYPELISP_COMPILE_VS_CLANG_TIME_BIN:-}
if [ -z "$TIME_BIN" ]; then
    for _tb_candidate in /usr/bin/time "$HOME/.local/bin/time"; do
        if [ -x "$_tb_candidate" ]; then
            TIME_BIN=$_tb_candidate
            break
        fi
    done
fi
if [ -z "$TIME_BIN" ] || [ ! -x "$TIME_BIN" ]; then
    echo "GNU time is required for peak RSS: ${TIME_BIN:-/usr/bin/time}" >&2
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
printf 'name\ttl_opt1_ms\ttl_opt1_kib\tclang_O0_ms\tclang_O0_kib\ttl_opt2_ms\ttl_opt2_kib\tclang_O2_ms\tclang_O2_kib\ttl_opt1_insns\tclang_O0_insns\ttl_opt2_insns\tclang_O2_insns\n' > "$RESULTS"

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

# perf_insns STAT_FILE COMMAND...
#   Run COMMAND once under perf's instructions:u counter, writing the -x, report
#   to STAT_FILE. Print the exact user-space instruction count, or fail when
#   perf reports no single positive, fully scheduled instructions:u event.
perf_insns() {
    _pi_stat=$1
    shift
    rm -f "$_pi_stat"
    set +e
    "$PERF_BIN" stat --no-big-num -x ',' -e instructions:u -o "$_pi_stat" -- "$@" \
        >"$_pi_stat.stdout" 2>"$_pi_stat.stderr"
    _pi_status=$?
    set -e
    [ "$_pi_status" -eq 0 ] || return 1
    LC_ALL=C awk -F ',' '
        $3 == "instructions:u" {
            if (++events != 1 || $1 !~ /^[0-9]+$/ || $1 + 0 <= 0 ||
                $5 !~ /^[0-9]+([.][0-9]+)?$/ || $5 + 0 != 100) {
                invalid = 1
            }
            count = $1
        }
        END {
            if (events != 1 || invalid) exit 1
            print count
        }
    ' "$_pi_stat"
}

# Probe once: the four *_insns columns stay n/a when perf cannot count a
# user-space-only instruction event on this host.
PERF_BIN=
PERF_ENABLED=0
if [ "$PERF_WANTED" -eq 1 ]; then
    PERF_BIN=$(command -v perf 2>/dev/null || true)
    if [ -n "$PERF_BIN" ] && _probe_insns=$(perf_insns "$WORKDIR/perf-probe.stat" true 2>/dev/null); then
        PERF_ENABLED=1
    else
        PERF_BIN=
    fi
fi
if [ "$PERF_ENABLED" -eq 0 ]; then
    if [ "$PERF_WANTED" -eq 1 ]; then
        echo "[compile-vs-clang] perf instructions:u unavailable; instruction columns will be n/a" >&2
    else
        echo "[compile-vs-clang] perf instructions:u disabled; instruction columns will be n/a" >&2
    fi
fi

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
    BEST_INSNS=n/a
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
    # One extra build under perf, separate from GNU time so neither measures the
    # other. Instruction counts are exact and do not need a best-of.
    if [ "$PERF_ENABLED" -eq 1 ]; then
        if _mbb_insns=$(perf_insns "$_mbb_stem.insns.stat" "$@"); then
            BEST_INSNS=$_mbb_insns
        else
            echo "[compile-vs-clang] no instructions:u for $_mbb_stem; column is n/a" >&2
        fi
    fi
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
            TL1_INSNS=$BEST_INSNS
            ;;
        clang-O0)
            CLANG_O0_MS=$BEST_MS
            CLANG_O0_KIB=$BEST_KIB
            CLANG_O0_INSNS=$BEST_INSNS
            ;;
        tl-opt2)
            TL2_MS=$BEST_MS
            TL2_KIB=$BEST_KIB
            TL2_INSNS=$BEST_INSNS
            ;;
        clang-O2)
            CLANG_O2_MS=$BEST_MS
            CLANG_O2_KIB=$BEST_KIB
            CLANG_O2_INSNS=$BEST_INSNS
            ;;
    esac
}

# geomean_ratio COLUMN_A COLUMN_B
#   Print the geometric mean of A/B over the measured rows of results.tsv.
geomean_ratio() {
    awk -F '\t' -v a="$1" -v b="$2" '
        NR > 1 && $a ~ /^[0-9]+$/ && $b ~ /^[0-9]+$/ && $a + 0 > 0 && $b + 0 > 0 {
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
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" \
            "$TL1_MS" "$TL1_KIB" \
            "$CLANG_O0_MS" "$CLANG_O0_KIB" \
            "$TL2_MS" "$TL2_KIB" \
            "$CLANG_O2_MS" "$CLANG_O2_KIB" \
            "$TL1_INSNS" "$CLANG_O0_INSNS" \
            "$TL2_INSNS" "$CLANG_O2_INSNS" >> "$RESULTS"
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
INSNS_OPT1=$(geomean_ratio 10 11)
INSNS_OPT2=$(geomean_ratio 12 13)
INSNS_PARTS=
[ "$INSNS_OPT1" = n/a ] || INSNS_PARTS="opt1:-O0 ${INSNS_OPT1}x"
[ "$INSNS_OPT2" = n/a ] || INSNS_PARTS="${INSNS_PARTS:+$INSNS_PARTS, }opt2:-O2 ${INSNS_OPT2}x"
INSNS_SUMMARY=
[ -z "$INSNS_PARTS" ] || INSNS_SUMMARY="; insns TL/clang $INSNS_PARTS"
printf '[compile-vs-clang] headline: time TL/clang opt1:-O0 %sx, opt2:-O2 %sx; peak RSS TL/clang opt1:-O0 %sx, opt2:-O2 %sx%s\n' \
    "$(geomean_ratio 2 4)" \
    "$(geomean_ratio 6 8)" \
    "$(geomean_ratio 3 5)" \
    "$(geomean_ratio 7 9)" \
    "$INSNS_SUMMARY"
echo "[compile-vs-clang] results: $RESULTS"
