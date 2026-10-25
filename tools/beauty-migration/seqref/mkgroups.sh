#!/bin/sh
# mkgroups.sh: recompute the index lookup sites, their blocks-parameter closure,
# and the function list target/exp/c1/all-fns.txt.
W=/home/jonathan/dev/typelisp/.claude/worktrees/agent-ad50a44d11c1e499f
C=$W/target/exp/c1
T=$W/target/exp/tools
python3 -I "$T/sites.py" "$W/src/compiler_optimize.tl" 'opt-cfg-index-block ' 'opt-cfg-index-find-block ' \
    'opt-cfg-index-refresh-blocks! ' 'index\.blocks' > "$C/sites.tsv"
python3 -I "$T/closure.py" "$W/src/compiler_optimize.tl" "$C/sites.tsv" > "$C/closure.txt"
{
    cut -f2 "$C/sites.tsv" | sort -u
    grep -o "opt-[a-z0-9?!-]*" "$C/closure.txt"
} | sort -u > "$C/all-fns.txt"
wc -l < "$C/all-fns.txt"
