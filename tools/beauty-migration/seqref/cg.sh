#!/bin/sh
# cg.sh TREE COMPILER OUT: callgrind COMPILER (use an unstripped stage3)
# compiling TREE's src/main.tl at opt1, the self_compile command line, 8 GiB cap.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
C=$2
OUT=$3
cd "$T" || exit 1
"$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 7200 \
    --report "$OUT.mem" -- valgrind --tool=callgrind --callgrind-out-file="$OUT" \
    "$C" compile src/main.tl -o "$OUT.s" \
    --target linux-x86_64 --cfg linux --cfg unix --cfg target-linux --cfg os-linux \
    --stdlib-root stdlib --stdlib-root src --opt-level 1 > "$OUT.log" 2>&1
echo "$OUT cg rc=$?" >> "$W/target/exp/tools/done.txt"
