#!/bin/sh
# mktree.sh REV DIR: a scratch tree holding REV of this worktree (git archive),
# with its own throwaway git repo so scripts that ask git work.
set -eu
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
rm -rf "$2"
mkdir -p "$2/target"
git -C "$W" archive "$1" | tar -x -C "$2"
git -C "$2" init -q
git -C "$2" add -A
git -C "$2" -c user.name=x -c user.email=x@x commit -q -m "$1"
echo "tree $2 = $1"
