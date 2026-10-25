#!/usr/bin/env python3
"""conflictlines.py TREE FILE: for a merge-tree result TREE (HEAD merged with a PR), print the HEAD line
ranges that each conflict block's "ours" side covers, and the lines HEAD changed against origin/main
that fall within one of them (or touch one)."""
import re
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
tree, rel = sys.argv[1], sys.argv[2]


def git(*a):
    return subprocess.run(["git", "-C", ROOT, *a], capture_output=True, text=True).stdout


merged = git("show", f"{tree}:{rel}").split("\n")
head = git("show", f"HEAD:{rel}").split("\n")
diff = git("diff", "-U0", "origin/main", "HEAD", "--", rel)
changed = set()
for m in re.finditer(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,(\d+))? @@", diff, re.M):
    s = int(m.group(1))
    n = int(m.group(2)) if m.group(2) is not None else 1
    changed.update(range(s, s + n))
# Walk the merged file, tracking the HEAD line number: lines outside conflict blocks and the
# "ours" side are HEAD lines, in order.
hl = 0
i = 0
blocks = []
while i < len(merged):
    ln = merged[i]
    if ln.startswith("<<<<<<<"):
        start = hl + 1
        i += 1
        while not merged[i].startswith("|||||||") and not merged[i].startswith("======="):
            hl += 1
            i += 1
        end = hl
        while not merged[i].startswith(">>>>>>>"):
            i += 1
        blocks.append((start, end))
        i += 1
        continue
    hl += 1
    i += 1
# The walk only stays aligned if non-conflict lines equal HEAD's; check a sample.
hits = []
for s, e in blocks:
    for c in changed:
        if s - 1 <= c <= e + 1:
            hits.append((c, s, e))
for c, s, e in sorted(set(hits)):
    print(f"{rel}:{c} in conflict block HEAD {s}-{e}: {head[c - 1].strip()[:90]}")
print(f"{rel}: {len(blocks)} blocks, {len(changed)} changed lines, {len(set(h[0] for h in hits))} in blocks")
