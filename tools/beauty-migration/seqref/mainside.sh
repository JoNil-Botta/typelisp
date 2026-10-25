#!/bin/sh
# mainside.sh DIR REV TAG: main's side of the gates in DIR: trees tm and tn at
# REV, tm's fixpoint, same-input Ir (opt1 self_compile row), and the official
# benchmark of tm.
set -u
X=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp
T=$X/tools
D=$1
REV=$2
TAG=$3
S=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/stage0/typelisp
mkdir -p "$D"
rm -rf "$D/tm" "$D/tn"
sh "$T/mktree.sh" "$REV" "$D/tm"
sh "$T/mktree.sh" "$REV" "$D/tn"
sh "$T/bs.sh" "$D/tm" "$S"
sh "$T/ir.sh" "$D/tm" "$D/tm/target/bs/typelisp" "$TAG-main"
sh "$T/cbench.sh" "$D/tm" "$S"
echo "mainside $TAG done" >> "$T/done.txt"
