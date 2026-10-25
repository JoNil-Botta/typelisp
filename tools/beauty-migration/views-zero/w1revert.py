#!/usr/bin/env python3
"""w1revert.py REL LINE: put the original view back. The W1 rewrites are same-line edits, so HEAD's
line numbers still hold: when LINE carries W1 rows, restore that line from HEAD; otherwise restore
every W1 line of the top-level form that contains LINE. Removes the reverted rows from
w1-sites.tsv."""
import subprocess
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
R = ROOT + "/target/exp/zero/"
rel, ln = sys.argv[1], int(sys.argv[2])
rows = [l.split("\t") for l in open(R + "w1-sites.tsv").read().split("\n") if l]
lines = open(f"{ROOT}/{rel}").read().split("\n")
head = subprocess.run(["git", "-C", ROOT, "show", f"HEAD:{rel}"], capture_output=True, text=True).stdout.split("\n")
assert len(head) == len(lines), "line counts differ from HEAD"
mine = [r for r in rows if r[0] == rel and int(r[1]) == ln]
if not mine:
    lo = ln
    while lo > 1 and not lines[lo - 1].startswith("("):
        lo -= 1
    hi = ln + 1
    while hi <= len(lines) and not lines[hi - 1].startswith("("):
        hi += 1
    mine = [r for r in rows if r[0] == rel and lo <= int(r[1]) < hi]
if not mine:
    print("NOT FOUND", rel, ln)
    sys.exit(0)
for r in mine:
    lines[int(r[1]) - 1] = head[int(r[1]) - 1]
    rows.remove(r)
    print("revert", rel, r[1], r[2], r[3], r[4])
open(f"{ROOT}/{rel}", "w").write("\n".join(lines))
with open(R + "w1-sites.tsv", "w") as fh:
    for r in rows:
        fh.write("\t".join(r) + "\n")
