#!/bin/sh
# usage: checkmany.sh FILE...: typecheck each root file in the worktree; print rc and first error.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
for f in "$@"; do
  r=$(sh "$W/target/exp/residue/check.sh" "$W" "$W/target/exp/residue/cm.log" "$f")
  echo "$f $r"
  grep -m1 -A3 "^error" "$W/target/exp/residue/cm.log" | head -4
done
