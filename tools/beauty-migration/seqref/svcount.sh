#!/bin/sh
# svcount.sh TREE: the shared-view gate and weighted report in TREE, plus the
# -seq-ref / -seq-borrow name counts (definitions included).
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
cd "$T" || exit 1
mkdir -p "$W/target/exp/tmp"
"$W/scripts/run-memory-bounded.sh" --limit-mib 2048 --timeout-seconds 300 \
    --report "$W/target/exp/tmp/sv.mem" -- sh scripts/check-shared-view-count.sh 2>&1 \
    | grep "check-shared-view-count"
r_src=$(grep -rhoE -- '-seq-ref\b' src | wc -l)
r_opt=$(grep -oE -- '-seq-ref\b' src/compiler_optimize.tl | wc -l)
b_src=$(grep -rhoE -- '-seq-borrow\b' src | wc -l)
echo "seq-ref src=$r_src optimize=$r_opt; seq-borrow src=$b_src"
