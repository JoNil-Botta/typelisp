#!/bin/sh
# usage: testpick.sh TREE REL BACKUP: typecheck TREE/REL; while the first error sits on a line where
# BACKUP differs from TREE's copy, take BACKUP's line and retry. Stops when clean or the error line
# has no backup change.
Z=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero
T=$1; F=$2; B=$3
n=0
while [ $n -lt 40 ]; do
  n=$((n + 1))
  r=$(sh "$Z/check.sh" "$T" "$Z/tp.log" "$F")
  if [ "$r" = "check rc=0" ]; then echo "$F clean after $n checks"; exit 0; fi
  loc=$(grep -m1 -A1 "^error" "$Z/tp.log" | sed -n 's/^ *--> \([^:]*\):\([0-9]*\):.*/\1 \2/p' | head -1)
  set -- $loc
  if [ "$1" != "$F" ]; then echo "error outside $F: $loc"; grep -m1 "^error" "$Z/tp.log"; exit 1; fi
  python3 "$Z/takeline.py" "$T/$F" "$B" "$2" || { grep -m1 "^error" "$Z/tp.log"; exit 1; }
  set -- "$T" "$F" "$B"
done
