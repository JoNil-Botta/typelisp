#!/bin/sh
# usage: w1loop.sh ROOT.tl...: typecheck each root; on an error at a W1-rewritten line, revert that
# line (w1revert.py) and retry; stop at the first error that is not on a W1 line.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
Z=$W/target/exp/zero
for root in "$@"; do
  n=0
  while [ $n -lt 40 ]; do
    n=$((n + 1))
    r=$(sh "$Z/check.sh" "$W" "$Z/w1loop.log" "$root")
    if [ "$r" = "check rc=0" ]; then echo "$root clean"; break; fi
    loc=$(grep -m1 -A1 "^error" "$Z/w1loop.log" | sed -n 's/^ *--> \([^:]*\):\([0-9]*\):.*/\1 \2/p' | head -1)
    msg=$(grep -m1 "^error" "$Z/w1loop.log")
    echo "$root: $msg at $loc"
    out=$(python3 "$Z/w1revert.py" $loc)
    echo "$out"
    case "$out" in
      revert*) ;;
      *) echo "$root: stop"; break ;;
    esac
  done
done
