#!/bin/sh
# usage: mfall.sh TREE FILE...: mfconf.sh for each open PR in target/exp/zero/prs.txt.
Z=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero
T=$1
shift
for p in $(cat "$Z/prs.txt"); do
  sh "$Z/mfconf.sh" "$T" "$p" "$@"
done
