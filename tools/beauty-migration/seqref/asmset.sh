#!/bin/sh
# asmset.sh: generated-code identity on the final trees. Main's source compiled
# by main's fixpoint (in fin/tm) and by A2's and batch 3's (in fin/tn, the same
# source at an equal-length path), at opt0/1/2, one compile at a time.
# Results in fin/asm/summary.txt.
set -u
X=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp
F=$X/fin
A=$X/tools/asm.sh
O=$F/asm
mkdir -p "$O"
: > "$O/summary.txt"
for lvl in 0 1 2; do
    sh "$A" "$F/tm" "$F/tm/target/bs/typelisp" "$lvl" "$O/main-o$lvl" > /dev/null
    for br in ta tb; do
        sh "$A" "$F/tn" "$F/$br/target/bs/typelisp" "$lvl" "$O/$br-o$lvl" > /dev/null
        if cmp -s "$O/main-o$lvl.s" "$O/$br-o$lvl.s"; then
            echo "$br opt$lvl: identical ($(sha256sum "$O/$br-o$lvl.s" | cut -c1-16))" >> "$O/summary.txt"
        else
            echo "$br opt$lvl: DIFFERS" >> "$O/summary.txt"
            python3 "$X/tools/fndiff.py" "$O/main-o$lvl.s" "$O/$br-o$lvl.s" 10 >> "$O/summary.txt"
        fi
    done
done
echo "asmset done" >> "$O/summary.txt"
