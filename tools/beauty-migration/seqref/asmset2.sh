#!/bin/sh
# asmset2.sh DIR BR: generated-code identity. Main's source compiled by main's
# fixpoint (DIR/tm) and by DIR/BR's fixpoint (in DIR/tn, the same source at an
# equal-length path), at opt0/1/2, one compile at a time. DIR/asm/summary.txt.
set -u
X=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp
F=$1
BR=$2
A=$X/tools/asm.sh
O=$F/asm
mkdir -p "$O"
: > "$O/summary.txt"
for lvl in 0 1 2; do
    sh "$A" "$F/tm" "$F/tm/target/bs/typelisp" "$lvl" "$O/main-o$lvl" > /dev/null
    sh "$A" "$F/tn" "$F/$BR/target/bs/typelisp" "$lvl" "$O/$BR-o$lvl" > /dev/null
    if cmp -s "$O/main-o$lvl.s" "$O/$BR-o$lvl.s"; then
        echo "$BR opt$lvl: identical ($(sha256sum "$O/$BR-o$lvl.s" | cut -c1-16))" >> "$O/summary.txt"
    else
        echo "$BR opt$lvl: DIFFERS" >> "$O/summary.txt"
        python3 "$X/tools/fndiff.py" "$O/main-o$lvl.s" "$O/$BR-o$lvl.s" 10 >> "$O/summary.txt"
    fi
done
echo "asmset done" >> "$O/summary.txt"
