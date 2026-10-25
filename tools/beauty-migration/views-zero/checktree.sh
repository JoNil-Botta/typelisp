#!/bin/sh
# usage: checktree.sh TREE FILE...: typecheck each root file in TREE; print rc and the first error.
Z=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero
T=$1
shift
for f in "$@"; do
  r=$(sh "$Z/check.sh" "$T" "$Z/ct.log" "$f")
  echo "$f $r"
  grep -m1 -A3 "^error" "$Z/ct.log" | head -4
done
