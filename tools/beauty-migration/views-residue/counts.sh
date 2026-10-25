#!/bin/sh
# usage: counts.sh: seq-ref call uses (definitions excluded) in src+stdlib, per my files, plus the
# shared-view gate output (textual count and weighted report).
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
all=$(cat src/*.tl src/*/*.tl stdlib/*.tl stdlib/*/*.tl 2>/dev/null | sed 's/;.*//' | grep -oE '\((compiler_ir_types\.|ir\.)?compiler-ir-[a-z0-9-]+-seq-ref[ )]' | wc -l)
defs=$(cat src/*.tl src/*/*.tl stdlib/*.tl stdlib/*/*.tl 2>/dev/null | grep -cE '^\((define|defmacro) \(compiler-ir-[a-z0-9-]+-seq-ref ')
echo "seq-ref uses: $((all - defs)) (heads $all, defs $defs)"
for f in src/compiler_backend.tl src/compiler_regalloc.tl src/compiler_ir_types.tl src/compiler_lower.tl src/compiler_liveness.tl src/compiler_optimize.tl; do
  n=$(sed 's/;.*//' "$f" | grep -oE '\((compiler_ir_types\.|ir\.)?compiler-ir-[a-z0-9-]+-seq-ref[ )]' | wc -l)
  d=$(grep -cE '^\((define|defmacro) \(compiler-ir-[a-z0-9-]+-seq-ref ' "$f")
  echo "  $f $((n - d))"
done
sh scripts/check-shared-view-count.sh 2>&1 | tail -3
