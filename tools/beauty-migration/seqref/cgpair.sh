#!/bin/sh
# cgpair.sh DIR: once DIR/tm and DIR/tb have their fixpoints, callgrind both
# stage3 compilers compiling DIR/tn at opt2 (in parallel), then write the
# program totals and whether the outputs match to DIR/cg-summary.txt.
X=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f/target/exp
T=$X/tools
D=$1
until grep -q "$D/tm bs rc=" "$T/done.txt" && grep -q "$D/tb bs rc=" "$T/done.txt"; do sleep 30; done
sh "$T/cg2.sh" "$D/tn" "$D/tm/target/build-stage0/stage3" "$D/cg-main-o2" 2 &
sh "$T/cg2.sh" "$D/tn" "$D/tb/target/build-stage0/stage3" "$D/cg-br-o2" 2 &
wait
{
    for f in cg-main-o2 cg-br-o2; do
        echo "$f $(callgrind_annotate "$D/$f" 2>/dev/null | grep -m1 'PROGRAM TOTALS')"
    done
    if cmp -s "$D/cg-main-o2.s" "$D/cg-br-o2.s"; then echo "outputs identical"; else echo "outputs DIFFER"; fi
} > "$D/cg-summary.txt"
echo "cgpair $D done" >> "$T/done.txt"
