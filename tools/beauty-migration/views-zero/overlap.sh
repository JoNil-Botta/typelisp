#!/bin/sh
# usage: overlap.sh PR...: trial-merge HEAD, and origin/main, with each fetched refs/pr/<n> (no
# checkout change); report the conflicts HEAD adds over main's own.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
for p in "$@"; do
  git merge-tree --write-tree --name-only HEAD "refs/pr/$p" 2>&1 | grep CONFLICT | sort > "target/exp/zero/mt-$p-head.txt"
  git merge-tree --write-tree --name-only origin/main "refs/pr/$p" 2>&1 | grep CONFLICT | sort > "target/exp/zero/mt-$p-main.txt"
  echo "#$p head=$(wc -l < "target/exp/zero/mt-$p-head.txt") main=$(wc -l < "target/exp/zero/mt-$p-main.txt") added:"
  comm -23 "target/exp/zero/mt-$p-head.txt" "target/exp/zero/mt-$p-main.txt"
done
