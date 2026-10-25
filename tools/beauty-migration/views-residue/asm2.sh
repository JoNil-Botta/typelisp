#!/bin/sh
# usage: asm2.sh NAME: compile NAME-src/src/main.tl with NAME-stage2 at opt 2 into target/exp/residue/NAME-main.s
D=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/borrows
O=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero
N=$1
cd "$D/$N-src" || exit 1
sh "$D/bounded.sh" "asm2-$N" 8192 1800 -- "$D/$N-stage2" compile src/main.tl -o "$O/$N-main.s" --target linux-x86_64 \
  --cfg linux --cfg unix --cfg target-linux --cfg os-linux --stdlib-root stdlib --stdlib-root src --opt-level 2 > "$O/asm2-$N.log" 2>&1
echo "$N rc=$?"
