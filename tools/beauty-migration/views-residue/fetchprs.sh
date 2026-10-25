#!/bin/sh
# usage: fetchprs.sh PR...: fetch each PR head into refs/remotes/pr/<n> and list its files.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
for p in "$@"; do
  git fetch -q origin "pull/$p/head:refs/remotes/pr/$p"
done
sh target/exp/borrows/prfiles2.sh "$@"
