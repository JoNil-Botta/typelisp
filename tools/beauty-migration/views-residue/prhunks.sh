#!/bin/sh
# usage: prhunks.sh <pr>...: for each fetched pr/<n>, print changed ranges (old side = merge-base)
# for my residue files, written to target/exp/residue/hunks-<n>.txt
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
for p in "$@"; do
  mb=$(git merge-base origin/main "pr/$p")
  out=target/exp/residue/hunks-$p.txt
  : > "$out"
  for f in src/compiler_backend.tl src/compiler_regalloc.tl src/compiler_ir_types.tl src/compiler_lower.tl src/compiler_liveness.tl; do
    git diff -U0 "$mb" "pr/$p" -- "$f" | grep '^@@' | sed "s|^@@ -\([0-9]*\),\{0,1\}\([0-9]*\) .*|$f \1 \2|" >> "$out"
  done
  echo "#$p mb=$(echo $mb | cut -c1-10) hunks=$(wc -l < "$out")"
done
