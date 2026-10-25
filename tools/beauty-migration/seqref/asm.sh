#!/bin/sh
# asm.sh TREE COMPILER LEVEL OUT [EXTRA...]: compile TREE's src/main.tl to OUT.s
# with COMPILER at LEVEL, 8 GiB cap. EXTRA goes to the compiler.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
C=$2
L=$3
O=$4
shift 4
cd "$T" || exit 1
"$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 1800 \
    --report "$O.mem" -- "$C" compile src/main.tl -o "$O.s" --target linux-x86_64 \
    --stdlib-root stdlib --stdlib-root src --opt-level "$L" "$@" > "$O.log" 2>&1
echo "asm $L rc=$? $O"
