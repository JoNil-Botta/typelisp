#!/bin/sh
# usage: counts2.sh TREE: seq-ref figures and the shared-view gate output for an exported tree.
cd "$1" || exit 1
raw=$(cat src/*.tl src/*/*.tl stdlib/*.tl stdlib/*/*.tl 2>/dev/null | grep -oE -- '-seq-ref\b' | wc -l)
all=$(cat src/*.tl src/*/*.tl stdlib/*.tl stdlib/*/*.tl 2>/dev/null | sed 's/;.*//' | grep -oE '\((compiler_ir_types\.|ir\.)?compiler-ir-[a-z0-9-]+-seq-ref[ )]' | wc -l)
defs=$(cat src/*.tl src/*/*.tl stdlib/*.tl stdlib/*/*.tl 2>/dev/null | grep -cE '^\((define|defmacro) \(compiler-ir-[a-z0-9-]+-seq-ref ')
echo "raw -seq-ref tokens: $raw; compiler-ir-*-seq-ref calls: $((all - defs))"
for f in src/compiler_backend.tl src/compiler_regalloc.tl src/compiler_ir_types.tl src/compiler_lower.tl src/compiler_liveness.tl; do
  n=$(sed 's/;.*//' "$f" | grep -oE '\((compiler_ir_types\.|ir\.)?compiler-ir-[a-z0-9-]+-seq-ref[ )]' | wc -l)
  d=$(grep -cE '^\((define|defmacro) \(compiler-ir-[a-z0-9-]+-seq-ref ' "$f")
  echo "  $f $((n - d))"
done
sh scripts/check-shared-view-count.sh 2>&1 | tail -3
