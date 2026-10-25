#!/bin/sh
# tfilter.sh OUTDIR FILTER...: run the optimizer inline tests matching each
# FILTER with the worktree's stage0 (cfg test), 8 GiB cap; one log per filter.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
OUT=$1
shift
mkdir -p "$OUT"
cd "$W" || exit 1
for f in "$@"; do
    "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 3600 \
        --report "$OUT/t-$f.mem" -- "$W/target/stage0/typelisp" test src/compiler_optimize_tests.tl \
        --filter "$f" --stdlib-root stdlib --stdlib-root src > "$OUT/t-$f.log" 2>&1
    echo "tfilter $f rc=$? $(grep 'TypeLisp tests:' "$OUT/t-$f.log")" >> "$OUT/summary.txt"
done
echo "tfilter done" >> "$OUT/summary.txt"
