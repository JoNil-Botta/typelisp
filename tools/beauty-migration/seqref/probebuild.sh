#!/bin/sh
# probebuild.sh TREE OUT: build a probe compiler from TREE's src/main.tl with
# the worktree's stage0 at opt2 (one stage, no fixpoint), 8 GiB cap; link it to
# OUT. Then run it on main's source (fin5/tn) at opt1 and opt2, stderr kept in
# OUT.o1.err / OUT.o2.err.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
T=$1
O=$2
cd "$T" || exit 1
ROOT=$T
. "$T/scripts/lib-native-link.sh"
native_link_detect_host
"$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 3600 \
    --report "$O.mem" -- "$W/target/stage0/typelisp" compile src/main.tl -o "$O.s" \
    --target "$NL_BOOTSTRAP_TARGET" $(native_target_cfg_args) \
    --stdlib-root stdlib --stdlib-root src --opt-level 2 > "$O.log" 2>&1 || { echo "probe build failed"; exit 1; }
assemble_and_link x "$O.s" "$O.o" "$O" || { echo "probe link failed"; exit 1; }
I=$W/target/exp/fin5/tn
cd "$I" || exit 1
for lvl in 1 2; do
    "$W/scripts/run-memory-bounded.sh" --limit-mib 8192 --timeout-seconds 3600 \
        --report "$O.o$lvl.mem" -- "$O" compile src/main.tl -o "$O.o$lvl.s" --target linux-x86_64 \
        --stdlib-root stdlib --stdlib-root src --opt-level "$lvl" > /dev/null 2> "$O.o$lvl.err"
    echo "probe run opt$lvl rc=$?"
done
