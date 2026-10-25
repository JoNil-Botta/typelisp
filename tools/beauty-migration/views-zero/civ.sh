#!/bin/sh
# usage: civ.sh LABEL: ci-verify of the worktree checkout on the selected Linux gates
# (target/exp/zero/gates-sel-w.txt), jobs 2 within 16 GiB, TMPDIR outside the checkout.
cd /home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3 || exit 1
export TMPDIR=/var/tmp/jn-borrows-tmp
export TYPELISP_BIN=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/stage0/typelisp
free -g | sed -n 2p
start=$(date +%s)
sh scripts/ci-verify.sh --jobs 2 --memory-mib 16384 --gates "$(cat target/exp/zero/gates-sel-w.txt)" > "target/exp/zero/civ-$1.log" 2>&1
rc=$?
echo "[ci-verify] rc=$rc in $(( $(date +%s) - start ))s"
grep -E "^\[ci-verify\] (FAIL|PASS)" "target/exp/zero/civ-$1.log" | grep -c PASS
grep -E "^\[ci-verify\] FAIL" "target/exp/zero/civ-$1.log"
tail -2 "target/exp/zero/civ-$1.log"
