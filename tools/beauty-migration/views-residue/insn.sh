#!/bin/sh
# usage: insn.sh LABEL: benchmark instruction-count rows (scripts/check-instruction-counts.sh
# --benchmarks-only, seeded from this worktree's stage0) under an 8 GiB cap; summary of the rows.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
cd "$W" || exit 1
L=$1
free -g | sed -n 2p
sh scripts/run-memory-bounded.sh --limit-mib 8192 --timeout-seconds 7200 --report "$W/target/exp/residue/insn-$L.mem" \
  -- sh scripts/check-instruction-counts.sh --benchmarks-only "$W/target/stage0/typelisp" > "$W/target/exp/residue/insn-$L.log" 2>&1
echo "rc=$?"
grep "^benchmark/" "$W/target/exp/residue/insn-$L.log" | awk -F' [|] ' '{split($1,a,"/"); print a[2], $7}' | sort | uniq -c
