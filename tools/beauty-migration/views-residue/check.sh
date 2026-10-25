#!/bin/sh
# check.sh TREE LOG [ROOT.tl] [CFG]: typecheck ROOT (default src/main.tl) in TREE with this
# worktree's stage0, under an 8 GiB cap (waits for 16 GB available first).
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
T=$1
LOG=$2
R=${3:-src/main.tl}
CFG=${4:-}
cd "$T" || exit 1
while [ "$(free -g | awk '/^Mem:/{print $7}')" -lt 16 ]; do sleep 30; done
sh "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 1800 \
    --report "$LOG.mem" -- "${CHECK_COMPILER:-$W/target/stage0/typelisp}" check "$R" \
    --stdlib-root stdlib --stdlib-root src ${CFG:+--cfg "$CFG"} > "$LOG" 2>&1
echo "check rc=$?"
