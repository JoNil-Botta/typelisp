#!/bin/sh
# Full ci-verify of the worktree (all host gates), jobs 2 within 16 GiB.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
export TMPDIR=/var/tmp/jn-borrows-tmp
export TYPELISP_BIN=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/stage0/typelisp
start=$(date +%s)
sh scripts/ci-verify.sh --jobs 2 --memory-mib 16384 > target/exp/zero/civ-w1.log 2>&1
rc=$?
echo "[ci-verify] rc=$rc in $(( $(date +%s) - start ))s"
grep -E "^\[ci-verify\]" target/exp/zero/civ-w1.log | tail -15
