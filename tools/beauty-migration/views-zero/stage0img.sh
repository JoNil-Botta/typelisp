#!/bin/sh
# usage: stage0img.sh <name>: build the converged, embedded-stdlib-TLCI stage0 of the exported tree
# <name>-src with scripts/build-stage0.sh (seed: this worktree's stage0-latest), under an 8 GiB cap.
# The binary lands at target/exp/borrows/<name>-stage0img.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
D=$W/target/exp/borrows
N=$1
cd "$D/$N-src" || exit 1
echo "[stage0img $N] start $(date +%T)"
sh "$D/bounded.sh" "stage0img-$N" 8192 5400 -- sh scripts/build-stage0.sh "$W/target/stage0/typelisp" "$D/$N-stage0img" \
  > "$D/$N-stage0img.log" 2>&1
rc=$?
echo "[stage0img $N] rc=$rc $(date +%T)"
tail -3 "$D/$N-stage0img.log"
