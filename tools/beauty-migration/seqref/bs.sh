#!/bin/sh
# bs.sh TREE SEED: TREE's scripts/build-stage0.sh from SEED under an 8 GiB cap.
# Fixpoint compiler: TREE/target/build-stage0/stage3 (unstripped), stripped copy
# TREE/target/bs/typelisp. Appends "TREE bs rc=N fixpoint?" to tools/done.txt.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
cd "$T" || exit 1
env -u TYPELISP_BIN "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 7200 \
    --report "$T/target/bs.mem" -- sh scripts/build-stage0.sh "$2" "$T/target/bs/typelisp" \
    > "$T/target/bs.log" 2>&1
rc=$?
if cmp -s "$T/target/build-stage0/stage2.s" "$T/target/build-stage0/stage3.s"; then
    fx=fixpoint
else
    fx=NO-FIXPOINT
fi
echo "$T bs rc=$rc $fx" >> "$W/target/exp/tools/done.txt"
