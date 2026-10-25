#!/bin/sh
# fixedpeak.sh MAIN_DRIVER BR_DRIVER INPUT_TREE OUTDIR: fixed-input allocator
# peaks. Both drivers are copied to equal-length paths (OUTDIR/dA, OUTDIR/dB)
# and run interleaved, twice each, at opt1 and opt2, on INPUT_TREE's source.
set -u
P=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp/tools/peakrun.sh
D=$4
mkdir -p "$D/dA" "$D/dB"
cp "$1" "$D/dA/driver"
cp "$2" "$D/dB/driver"
for lvl in 1 2; do
    for rep in 1 2; do
        sh "$P" "$D/dA/driver" "$3" "$lvl" "$D/fA-o$lvl-r$rep"
        sh "$P" "$D/dB/driver" "$3" "$lvl" "$D/fB-o$lvl-r$rep"
    done
done
