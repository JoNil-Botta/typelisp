#!/usr/bin/env python3
"""newblocks.py BASENAME: compare target/exp/zero/mf/<b>.merged (tree merged with the PR) and
<b>.mmerged (main merged with the PR); print each conflict block of the tree merge whose text does not
occur among main's blocks, with the tree-side ("ours") lines that differ from main's file."""
import sys

O = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero/mf/"


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


