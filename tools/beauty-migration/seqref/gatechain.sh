#!/bin/sh
# gatechain.sh DIR REV TAG: the branch side of the gates on DIR (which holds
# main's tm/tn trees with their fixpoint and official benchmark): rebuild
# DIR/tb at REV, fixpoint, same-input Ir, asm identity, an opt2 trace compile,
# the official benchmark, fixed-input peaks against main's driver, and rows.
set -u
X=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp
T=$X/tools
D=$1
REV=$2
TAG=$3
S=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/stage0/typelisp
rm -rf "$D/tb" "$D/asm" "$D/fixed"
sh "$T/mktree.sh" "$REV" "$D/tb"
sh "$T/bs.sh" "$D/tb" "$S"
sh "$T/ir.sh" "$D/tn" "$D/tb/target/bs/typelisp" "$TAG-br"
sh "$T/asmset2.sh" "$D" tb
sh "$T/asm.sh" "$D/tn" "$D/tb/target/bs/typelisp" 2 "$D/trace-o2" --trace-passes
sh "$T/cbench.sh" "$D/tb" "$S"
sh "$T/fixedpeak.sh" "$D/tm/target/cbench/profile/compile_profile" "$D/tb/target/cbench/profile/compile_profile" \
    "$D/tn" "$D/fixed" > "$D/fixed-peaks.txt" 2>&1
sh "$T/rows.sh" "$D/tb" "$D/tb/target/bs/typelisp" "$TAG"
echo "gatechain $TAG done" >> "$T/done.txt"
