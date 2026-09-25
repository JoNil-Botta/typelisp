#!/usr/bin/env sh
# refactor-oracle.sh - prove a refactor leaves generated code byte-identical.
#
# usage: scripts/refactor-oracle.sh <base-compiler> <head-compiler> <base-tree>
#            [--full] [--jobs N] [--out DIR] [--no-self]
#
# Both compilers compile the same fixed inputs, taken from <base-tree>:
#   - benchmarks/*/bench.tl, examples/*.tl, tests/integration/*.tl,
#     tests/inline/*.tl and tests/spmd/*.tl (`compile`, assembly compared);
#   - tests/safety/*.tl and tests/diagnostics/**/*.tl (`check`, exit code and
#     output compared);
#   - the compiler itself: <base-tree>/src/main.tl (unless --no-self).
# Each compiler resolves the stdlib from its own tree: the base compiler runs in
# <base-tree> with its stdlib, and the head compiler runs in a copy of the same
# corpus paired with this checkout's stdlib (a compiler prefers the stdlib of the
# tree it runs in, so both sides need their own tree). Exit code, stdout, stderr
# and emitted assembly must match byte for byte after the tree prefix is
# normalized.
#
# Default mode is linux-x86_64 --opt-level 2, plus avx2/avx512 for tests/spmd.
# --full adds opt levels 0 and 1, the windows-x86_64 target, and the scalar
# SPMD mode. Output lands in target/exp/refactor-oracle unless --out is given.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

if [ "${1:-}" = "--job" ]; then
    # --job <compiler> <stdlib> <tree> <outdir> <verb> <target> <opt> <mode> <file>
    compiler=$2 stdlib=$3 tree=$4 outdir=$5 verb=$6 target=$7 opt=$8 mode=$9
    shift 9
    file=$1
    key=$(printf '%s' "$file" | tr '/' '_')
    dest="$outdir/$verb-$target-O$opt-$mode"
    mkdir -p "$dest"
    rc=0
    if [ "$verb" = compile ]; then
        set -- --target "$target" --opt-level "$opt" --stdlib-root "$stdlib"
        if [ "$mode" != default ]; then
            set -- "$@" --backend-mode "$mode"
        fi
        (cd "$tree" && "$compiler" compile "$file" -o "$dest/$key.s" "$@") \
            > "$dest/$key.out" 2> "$dest/$key.err" || rc=$?
    else
        (cd "$tree" && "$compiler" check "$file" --target "$target" --stdlib-root "$stdlib") \
            > "$dest/$key.out" 2> "$dest/$key.err" || rc=$?
    fi
    echo "$rc" > "$dest/$key.rc"
    # Normalize the per-side output directory and source tree the compiler echoes back.
    for stream in out err s; do
        [ -e "$dest/$key.$stream" ] || continue
        sed -e "s|$outdir/|<OUT>/|g" -e "s|$tree/|<TREE>/|g" "$dest/$key.$stream" > "$dest/$key.$stream.n"
        mv "$dest/$key.$stream.n" "$dest/$key.$stream"
    done
    exit 0
fi

if [ "$#" -lt 3 ]; then
    sed -n '4,20p' "$0" >&2
    exit 2
fi
BASE=$1 HEAD=$2 BASE_TREE=$3
shift 3
FULL=0 JOBS=$(nproc 2>/dev/null || echo 8) OUT="$ROOT/target/exp/refactor-oracle" SELF=1
while [ "$#" -gt 0 ]; do
    case "$1" in
        --full) FULL=1 ;;
        --jobs) JOBS=$2; shift ;;
        --out) OUT=$2; shift ;;
        --no-self) SELF=0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
    shift
done
abspath() { (cd "$(dirname -- "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename -- "$1")"); }
BASE=$(abspath "$BASE") HEAD=$(abspath "$HEAD") BASE_TREE=$(cd "$BASE_TREE" && pwd)
for c in "$BASE" "$HEAD"; do
    [ -x "$c" ] || { echo "not executable: $c" >&2; exit 2; }
done
rm -rf "$OUT"
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

corpus() { (cd "$BASE_TREE" && ls $1 2>/dev/null) || true; }
COMPILE_FILES=$(corpus "benchmarks/*/bench.tl examples/*.tl tests/integration/*.tl tests/inline/*.tl")
SPMD_FILES=$(corpus "tests/spmd/*.tl")
CHECK_FILES=$( (cd "$BASE_TREE" && ls tests/safety/*.tl; find tests/diagnostics -name '*.tl' 2>/dev/null) | sort -u)

targets=linux-x86_64 opts=2 spmd_modes="avx2 avx512"
if [ "$FULL" -eq 1 ]; then
    targets="linux-x86_64 windows-x86_64" opts="0 1 2" spmd_modes="scalar avx2 avx512"
fi

# The head side compiles the same corpus from its own tree so that it resolves
# this checkout's stdlib rather than the base tree's.
HEAD_TREE="$OUT/head-tree"
mkdir -p "$HEAD_TREE/benchmarks"
(cd "$BASE_TREE" && cp -a examples tests typelisp.pkg "$HEAD_TREE/")
for b in "$BASE_TREE"/benchmarks/*/; do
    [ -e "$b/bench.tl" ] || continue
    mkdir -p "$HEAD_TREE/benchmarks/$(basename "$b")"
    cp -a "$b"/*.tl "$HEAD_TREE/benchmarks/$(basename "$b")/"
done
cp -a "$ROOT/stdlib" "$HEAD_TREE/stdlib"

JOBLIST="$OUT/jobs.txt"
: > "$JOBLIST"
emit() { # side verb target opt mode files
    side=$1 verb=$2 target=$3 opt=$4 mode=$5
    shift 5
    if [ "$side" = base ]; then c=$BASE side_tree=$BASE_TREE; else c=$HEAD side_tree=$HEAD_TREE; fi
    for f in $*; do
        printf '%s\n' "--job $c stdlib $side_tree $OUT/$side $verb $target $opt $mode $f" >> "$JOBLIST"
    done
}
for side in base head; do
    for t in $targets; do
        for o in $opts; do
            emit "$side" compile "$t" "$o" default $COMPILE_FILES
            for m in $spmd_modes; do emit "$side" compile "$t" "$o" "$m" $SPMD_FILES; done
        done
        emit "$side" check "$t" 2 default $CHECK_FILES
    done
done

self_pids=
if [ "$SELF" -eq 1 ]; then
    for side in base head; do
        if [ "$side" = base ]; then c=$BASE; else c=$HEAD; fi
        mkdir -p "$OUT/$side/self"
        (
            cd "$BASE_TREE"
            rc=0
            "$c" compile src/main.tl -o "$OUT/$side/self/main.s" --target linux-x86_64 \
                --stdlib-root stdlib --stdlib-root src --opt-level 2 \
                > "$OUT/$side/self/main.out" 2> "$OUT/$side/self/main.err" || rc=$?
            echo "$rc" > "$OUT/$side/self/main.rc"
            sed -i "s|$OUT/$side/|<OUT>/|g" "$OUT/$side/self/main.out" "$OUT/$side/self/main.err"
        ) &
        self_pids="$self_pids $!"
    done
fi

echo "[refactor-oracle] $(wc -l < "$JOBLIST") compile/check jobs on $JOBS workers"
xargs -P "$JOBS" -L 1 "$0" < "$JOBLIST"
for p in $self_pids; do wait "$p"; done

total=0 differ=0 failed_both=0
REPORT="$OUT/differences.txt"
: > "$REPORT"
for dir in "$OUT"/base/*/; do
    cfg=$(basename "$dir")
    for rcfile in "$dir"*.rc; do
        [ -e "$rcfile" ] || continue
        stem=${rcfile%.rc}
        name=$(basename "$stem")
        other="$OUT/head/$cfg/$name"
        total=$((total + 1))
        same=1
        for ext in rc out err s; do
            if [ -e "$stem.$ext" ] || [ -e "$other.$ext" ]; then
                cmp -s "$stem.$ext" "$other.$ext" 2>/dev/null || { same=0; break; }
            fi
        done
        if [ "$same" -eq 0 ]; then
            differ=$((differ + 1))
            echo "$cfg/$name ($ext differs)" >> "$REPORT"
        elif [ "$(cat "$stem.rc")" != 0 ]; then
            failed_both=$((failed_both + 1))
        fi
    done
done

echo "[refactor-oracle] compared $total results: $differ differ, $failed_both fail identically in both"
if [ "$differ" -ne 0 ]; then
    echo "[refactor-oracle] FAIL: first differences (full list: $REPORT):" >&2
    head -20 "$REPORT" >&2
    exit 1
fi
if [ "$SELF" -eq 1 ] && [ "$(cat "$OUT/base/self/main.rc")" != 0 ]; then
    echo "[refactor-oracle] FAIL: the base compiler could not self-compile the base tree" >&2
    exit 1
fi
echo "[refactor-oracle] PASS: byte-identical"
