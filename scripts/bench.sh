#!/usr/bin/env sh
set -eu

# scripts/bench.sh - TypeLisp vs clang C micro-benchmark harness. refs #1097
#
# For each benchmarks/<name>/ that contains bench.tl + baseline.c, this compiles
# both to native code, checks they agree on observable output, runs each a few
# times, and prints a TypeLisp-vs-C comparison: wall-clock runtime (min/median),
# executable size, emitted assembly size, and TypeLisp compile time.
#
# Benchmarks are intentionally kept OUT of normal correctness CI; run manually.
#
# Linux builds the native ELF through `typelisp build` (GNU as/ld); Windows
# (Git Bash / MSYS / Cygwin) builds a native windows-x86_64 exe through
# `typelisp build --target windows-x86_64` (clang/lld-link). clang -O2 builds the
# C baseline on both. The TypeLisp-vs-C ratio is only comparable within one host.
#
# Env:
#   TYPELISP_BIN     compiler path (else the published stage0 is fetched)
#   BENCH_RUNS       timed runs per program (default 5)
#   BENCH_CLANG_OPT  clang optimization level (default -O2)
#   BENCH_FILTER     only run benchmarks whose name contains this substring

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

RUNS=${BENCH_RUNS:-5}
CLANG_OPT=${BENCH_CLANG_OPT:--O2}
FILTER=${BENCH_FILTER:-}

# `--smoke` (#1099): build + run ONE benchmark and assert TypeLisp and C agree
# on observable output, then stop — no timing runs. This is a fast correctness
# smoke for CI (a few seconds), NOT a performance gate. Defaults to the small
# `arith_loop` benchmark when no BENCH_FILTER is set.
SMOKE=0
for _arg in "$@"; do
    [ "$_arg" = "--smoke" ] && SMOKE=1
done
if [ "$SMOKE" = 1 ] && [ -z "$FILTER" ]; then
    FILTER=arith_loop
fi

HOST_OS=linux
EXE=
TARGET_ARGS=
case "$(uname -s)" in
    Linux*) HOST_OS=linux ;;
    MINGW* | MSYS* | CYGWIN*)
        HOST_OS=windows
        EXE=.exe
        TARGET_ARGS="--target windows-x86_64"
        ;;
    *)
        echo "benchmark harness is unsupported on this host" >&2
        exit 1
        ;;
esac

if [ -n "${TYPELISP_BIN:-}" ]; then
    COMPILER=$TYPELISP_BIN
else
    # No-Rust fallback for local development: fetch the published
    # self-hosted stage0 (CI always passes a compiler via TYPELISP_BIN).
    . "$ROOT/scripts/lib-stage0.sh"
    COMPILER=$(resolve_stage0_compiler "$ROOT") || exit 1
fi
[ -x "$COMPILER" ] || {
    echo "typelisp compiler is not executable: $COMPILER" >&2
    exit 1
}

command -v clang >/dev/null 2>&1 || {
    echo "missing clang (C baseline compiler)" >&2
    exit 1
}
if [ "$HOST_OS" = linux ]; then
    command -v as >/dev/null 2>&1 || { echo "missing assembler: as" >&2; exit 1; }
    command -v ld >/dev/null 2>&1 || { echo "missing linker: ld" >&2; exit 1; }
fi

WORKDIR="$ROOT/target/bench"
rm -rf "$WORKDIR"
mkdir -p "$WORKDIR"

now() { date +%s.%N; }

# elapsed SECONDS_START SECONDS_END -> "%.3f" seconds
elapsed() { awk "BEGIN { printf \"%.3f\", $2 - $1 }"; }

# read newline-separated numbers on stdin; print the minimum
minimum() { sort -n | head -n 1; }

# read newline-separated numbers on stdin; print the median
median() {
    sort -n | awk '
        { a[NR] = $1 }
        END {
            if (NR == 0) { print "0"; }
            else if (NR % 2) { print a[(NR + 1) / 2]; }
            else { printf "%.3f\n", (a[NR / 2] + a[NR / 2 + 1]) / 2; }
        }'
}

# time_build OUT_FILE -- COMMAND...  : run COMMAND, echo elapsed seconds
time_build() {
    _out=$1
    shift
    _s=$(now)
    "$@" >"$_out.build.stdout" 2>"$_out.build.stderr" || {
        echo "FAIL: build command failed: $*" >&2
        sed 's/^/  /' "$_out.build.stderr" >&2 || true
        exit 1
    }
    _e=$(now)
    elapsed "$_s" "$_e"
}

# run BIN once; echo its exit code
run_exit() {
    set +e
    "$1" >/dev/null 2>&1
    _code=$?
    set -e
    echo "$_code"
}

# time_runs BIN -> "min median" wall-clock seconds over RUNS runs
time_runs() {
    _bin=$1
    _times="$WORKDIR/times.txt"
    : >"$_times"
    _r=0
    while [ "$_r" -lt "$RUNS" ]; do
        _s=$(now)
        "$_bin" >/dev/null 2>&1 || true
        _e=$(now)
        elapsed "$_s" "$_e" >>"$_times"
        printf '\n' >>"$_times"
        _r=$((_r + 1))
    done
    _min=$(minimum <"$_times")
    _med=$(median <"$_times")
    echo "$_min $_med"
}

ratio() { awk "BEGIN { if ($2 == 0) { print \"n/a\" } else { printf \"%.2fx\", $1 / $2 } }"; }

found=0
printf '%s\n' "TypeLisp benchmark harness (host=$HOST_OS, runs=$RUNS, clang $CLANG_OPT)"
printf '%s\n' "compiler: $COMPILER"
printf '\n'

for bench_tl in benchmarks/*/bench.tl; do
    [ -e "$bench_tl" ] || continue
    dir=$(dirname "$bench_tl")
    name=$(basename "$dir")
    baseline_c="$dir/baseline.c"
    [ -f "$baseline_c" ] || continue
    case "$name" in
        *"$FILTER"*) ;;
        *) continue ;;
    esac
    found=$((found + 1))

    tl_bin="$WORKDIR/$name.tl$EXE"
    tl_asm="$WORKDIR/$name.tl.s"
    c_bin="$WORKDIR/$name.c$EXE"

    # TypeLisp: measure compile-to-asm time + asm size, then build a runnable exe.
    tl_compile=$(time_build "$WORKDIR/$name.asm" "$COMPILER" compile "$bench_tl" -o "$tl_asm" $TARGET_ARGS)
    time_build "$WORKDIR/$name.tlbuild" "$COMPILER" build "$bench_tl" -o "$tl_bin" $TARGET_ARGS >/dev/null

    # C baseline.
    c_compile=$(time_build "$WORKDIR/$name.cbuild" clang $CLANG_OPT "$baseline_c" -o "$c_bin")

    # Correctness gate: both must agree on the exit code.
    tl_code=$(run_exit "$tl_bin")
    c_code=$(run_exit "$c_bin")
    if [ "$tl_code" != "$c_code" ]; then
        echo "FAIL: $name observable output differs (typelisp exit $tl_code, C exit $c_code)" >&2
        exit 1
    fi

    # Smoke mode: the build + correctness gate above is the whole check. Report
    # and stop before any timing so CI stays fast and timing-noise-free.
    if [ "$SMOKE" = 1 ]; then
        printf 'smoke OK: %s — typelisp and C agree on exit %s (build+run only, no timing)\n' "$name" "$tl_code"
        break
    fi

    set -- $(time_runs "$tl_bin")
    tl_min=$1
    tl_med=$2
    set -- $(time_runs "$c_bin")
    c_min=$1
    c_med=$2

    tl_exe_size=$(wc -c <"$tl_bin")
    c_exe_size=$(wc -c <"$c_bin")
    tl_asm_size=$(wc -c <"$tl_asm")
    tl_asm_lines=$(wc -l <"$tl_asm")

    printf '== %s (exit %s) ==\n' "$name" "$tl_code"
    printf '%-22s %14s %14s %10s\n' "metric" "typelisp" "clang $CLANG_OPT" "tl / c"
    printf '%-22s %14s %14s %10s\n' "runtime min (s)" "$tl_min" "$c_min" "$(ratio "$tl_min" "$c_min")"
    printf '%-22s %14s %14s %10s\n' "runtime median (s)" "$tl_med" "$c_med" "$(ratio "$tl_med" "$c_med")"
    printf '%-22s %14s %14s %10s\n' "exe size (bytes)" "$tl_exe_size" "$c_exe_size" "$(ratio "$tl_exe_size" "$c_exe_size")"
    printf '%-22s %14s %14s %10s\n' "compile time (s)" "$tl_compile" "$c_compile" "$(ratio "$tl_compile" "$c_compile")"
    printf '%-22s %14s %14s\n' "typelisp asm bytes" "$tl_asm_size" "-"
    printf '%-22s %14s %14s\n' "typelisp asm lines" "$tl_asm_lines" "-"
    printf '\n'
done

if [ "$found" -eq 0 ]; then
    echo "no benchmarks matched (filter='$FILTER')" >&2
    exit 1
fi

echo "benchmark harness completed: $found benchmark(s)"
