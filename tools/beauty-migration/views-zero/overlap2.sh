#!/bin/sh
# usage: overlap2.sh FILELIST PR...: for each PR, trial-merge it with HEAD and with origin/main and
# count conflict blocks per listed file; a file whose count rises with HEAD has a new conflict.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
L=$1
shift
for p in "$@"; do
  th=$(git merge-tree --write-tree HEAD "refs/pr/$p" 2>/dev/null | head -1)
  tm=$(git merge-tree --write-tree origin/main "refs/pr/$p" 2>/dev/null | head -1)
  added=0
  for f in $(cat "$L"); do
    a=$(git show "$th:$f" 2>/dev/null | grep -c '^<<<<<<<')
    b=$(git show "$tm:$f" 2>/dev/null | grep -c '^<<<<<<<')
    if [ "$a" != "$b" ]; then echo "  #$p $f: $b -> $a conflict blocks"; added=1; fi
  done
  echo "#$p new conflicts: $added"
done
