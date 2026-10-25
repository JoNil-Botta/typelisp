#!/bin/sh
# usage: build1.sh <tree-dir> <name> <compiler>: one `typelisp build` (opt2) of an exported tree with
# the given compiler; the binary lands in target/exp/borrows/<name>-stage2. Use a compiler whose
# codegen equals the tree's (the base stage2 when the change does not touch codegen).
D=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/borrows
cd "$D/$1" || exit 1
echo "[$2] build $(date +%T)"
sh "$D/bounded.sh" "$2-build1" 8192 1800 -- "$3" build > "$D/$2-build1.log" 2>&1 || { tail -20 "$D/$2-build1.log"; exit 1; }
cp target/release/typelisp "$D/$2-stage2"
echo "[$2] done $(date +%T)"
