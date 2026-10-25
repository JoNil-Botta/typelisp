#!/bin/sh
# check.sh TREE LOG [ROOT.tl] [CFG]: typecheck ROOT (default src/main.tl) in
# TREE with the worktree's stage0, 8 GiB cap.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
LOG=$2
R=${3:-src/main.tl}
CFG=${4:-}
cd "$T" || exit 1
"$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 1800 \
    --report "$LOG.mem" -- "$W/target/stage0/typelisp" check "$R" \
    --stdlib-root stdlib --stdlib-root src ${CFG:+--cfg "$CFG"} > "$LOG" 2>&1
echo "check $R rc=$?"
