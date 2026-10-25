#!/bin/sh
# usage: oracle2.sh BASE HEAD: scripts/refactor-oracle.sh, main's compilers against this head's, on both
# routes: the interpreter route (the stage1 compilers that `build` produced from stage0-latest) and the
# embedded-image route (the converged stage0 binaries from scripts/build-stage0.sh). Fixed inputs come
# from the BASE tree; outputs land under target/exp/zero/oracle-<route>.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3
D=$W/target/exp/borrows
B=$1; H=$2
cd "$W" || exit 1
for route in stage1 stage0img; do
  free -g | sed -n 2p
  start=$(date +%s)
  sh scripts/refactor-oracle.sh "$D/$B-$route" "$D/$H-$route" "$D/$B-src" --jobs 4 \
    --out "$W/target/exp/zero/oracle-$route" > "$W/target/exp/zero/oracle-$route.log" 2>&1
  echo "[oracle $route] rc=$? in $(( $(date +%s) - start ))s"
  tail -4 "$W/target/exp/zero/oracle-$route.log"
done
