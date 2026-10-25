#!/usr/bin/env python3
"""newblocks.py BASENAME: compare target/exp/zero/mf/<b>.merged (tree merged with the PR) and
<b>.mmerged (main merged with the PR); print each conflict block of the tree merge whose text does not
occur among main's blocks, with the tree-side ("ours") lines that differ from main's file."""
import sys

O = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero/mf/"
b = sys.argv[1]


def blocks(path):
    out = []
    lines = open(path).read().split("\n")
    i = 0
    while i < len(lines):
        if lines[i].startswith("<<<<<<<"):
            j = i + 1
            ours = []
            while not lines[j].startswith("=======") and not lines[j].startswith("|||||||"):
                ours.append(lines[j])
                j += 1
            while not lines[j].startswith(">>>>>>>"):
                j += 1
            theirs_end = j
            out.append((i, "\n".join(ours), "\n".join(lines[i:theirs_end + 1])))
            i = j + 1
        else:
            i += 1
    return out


tb = blocks(O + b + ".merged")
mb = blocks(O + b + ".mmerged")
main_ours = {x[1] for x in mb}
main_lines = set(open(O + b + ".main").read().split("\n"))
new = [x for x in tb if x[1] not in main_ours]
print(b, "tree blocks", len(tb), "main blocks", len(mb), "tree blocks with ours-text not in main's:", len(new))
for at, ours, whole in new:
    diff = [l for l in ours.split("\n") if l not in main_lines]
    print(f"--- merged line {at + 1}: {len(diff)} tree-only lines")
    for l in diff[:6]:
        print("   ", l.strip()[:120])
