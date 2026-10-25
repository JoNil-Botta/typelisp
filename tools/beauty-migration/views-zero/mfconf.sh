#!/bin/sh
# usage: mfconf.sh TREE PR FILE...: three-way merge (git merge-file) of each FILE: ours = TREE's copy,
# base = merge-base(origin/main, refs/pr/PR), theirs = the PR head. Prints the conflict-block count
# with TREE's copy and with origin/main's copy; the merged text with TREE's copy lands in
# target/exp/zero/mf/<basename>.merged.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
T=$1; P=$2
shift 2
O=target/exp/zero/mf
mkdir -p "$O"
mb=$(git merge-base origin/main "refs/pr/$P")
for f in "$@"; do
  b=$(basename "$f")
  git show "$mb:$f" > "$O/$b.base"
  git show "refs/pr/$P:$f" > "$O/$b.theirs"
  git show "origin/main:$f" > "$O/$b.main"
  cp "$T/$f" "$O/$b.ours"
  git merge-file -p "$O/$b.ours" "$O/$b.base" "$O/$b.theirs" > "$O/$b.merged"
  git merge-file -p "$O/$b.main" "$O/$b.base" "$O/$b.theirs" > "$O/$b.mmerged"
  a=$(grep -c '^<<<<<<<' "$O/$b.merged")
  m=$(grep -c '^<<<<<<<' "$O/$b.mmerged")
  echo "#$P $f: main $m, tree $a"
done
