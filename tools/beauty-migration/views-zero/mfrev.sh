#!/bin/sh
# usage: mfrev.sh TREE REV FILE...: three-way merge of TREE's copy with REV's (base origin/main);
# prints conflict-block counts.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
T=$1; V=$2
shift 2
O=target/exp/zero/mf
mkdir -p "$O"
for f in "$@"; do
  b=$(basename "$f")
  git show "origin/main:$f" > "$O/$b.rbase"
  git show "$V:$f" > "$O/$b.rtheirs"
  cp "$T/$f" "$O/$b.rours"
  git merge-file -p "$O/$b.rours" "$O/$b.rbase" "$O/$b.rtheirs" > "$O/$b.rmerged"
  echo "$V $f: $(grep -c '^<<<<<<<' "$O/$b.rmerged") conflict blocks"
done
