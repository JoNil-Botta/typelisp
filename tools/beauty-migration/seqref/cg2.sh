#!/bin/sh
# cg2.sh TREE COMPILER OUT LEVEL: callgrind COMPILER (an unstripped stage3)
# compiling TREE's src/main.tl at opt LEVEL with the self_compile command line,
# 12 GiB cap (opt2 under valgrind needs more than 8 GiB of address space).
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
C=$2
OUT=$3
L=$4
cd "$T" || exit 1
"$W/scripts/run-memory-bounded.sh" --limit-mib 12288 --timeout-seconds 14400 \
    --report "$OUT.mem" -- valgrind --tool=callgrind --callgrind-out-file="$OUT" \
    "$C" compile src/main.tl -o "$OUT.s" \
    --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux \
    --stdlib-root stdlib --stdlib-root src --opt-level "$L" > "$OUT.log" 2>&1
echo "$OUT cg rc=$?" >> "$W/target/exp/tools/done.txt"
