#!/bin/sh
# usage: meas2.sh <base> <cand> [skip-base]: same-input self_compile Ir: base's compiler and cand's compiler
# both compiling base's source, in parallel (base run skipped when a third argument is given).
D=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/borrows
B=$1; C=$2
if [ -z "$3" ]; then
  sh "$D/measure.sh" "m-$B" "$D/$B-src" "$D/$B-stage2" &
fi
sh "$D/measure.sh" "x-$C-on-$B" "$D/$B-src" "$D/$C-stage2" &
wait
grep -h "" /dev/null
for f in "m-$B" "x-$C-on-$B"; do
  printf "%s Ir=%s\n" "$f" "$(grep '^summary:' "$D/measure/$f.cg" | awk '{print $2}')"
done
