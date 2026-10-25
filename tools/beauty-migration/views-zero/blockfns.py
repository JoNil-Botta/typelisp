#!/usr/bin/env python3
"""blockfns.py TREE REL FLIPSTATE MATCHSTATE: for each conflict block that the tree's copy of REL adds
in a merge with the PR (newblocks.py's inputs in target/exp/zero/mf/), locate the block's tree-side
text in TREE/REL and name the enclosing top-level form. Then list what to undo there: flipped
parameters of that function, match-borrow sites inside it, and callees whose flip edited a call site
inside it. Prints REVERT_NAMES and the match-borrow sites (rel:line)."""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import newblocks_lib as nb  # noqa: E402

tree, rel, flip_path, match_path = sys.argv[1:5]
b = os.path.basename(rel)
text = open(f"{tree}/{rel}").read()
lines = text.split("\n")
main_lines = set(open(nb.O + b + ".main").read().split("\n"))
tb = nb.blocks(nb.O + b + ".merged")
mb = nb.blocks(nb.O + b + ".mmerged")
main_ours = {x[1] for x in mb}
new = [x for x in tb if x[1] not in main_ours]


def enclosing(ln):
    i = ln
    while i > 1 and not lines[i - 1].startswith("("):
        i -= 1
    hi = ln + 1
    while hi <= len(lines) and not lines[hi - 1].startswith("("):
        hi += 1
    m = re.match(r"\((?:define|defmacro) \(?([^\s()]+)", lines[i - 1])
    return (m.group(1) if m else None), i, hi - 1


fns = {}
for at, ours, whole in new:
    probe = ours if ours.strip() else None
    if probe is None:
        continue
    k = text.find(probe)
    if k < 0:
        # fall back to the first tree-only line
        cand = [l for l in ours.split("\n") if l not in main_lines and l.strip()]
        k = text.find(cand[0]) if cand else -1
    if k < 0:
        print("unlocated block at merged line", at + 1)
        continue
    ln = text.count("\n", 0, k) + 1
    end_ln = ln + ours.count("\n")
    name, lo, hi = enclosing(ln)
    fns.setdefault(name, (lo, hi))
flip = json.load(open(flip_path))
match = json.load(open(match_path))
revert_names = set()
match_sites = []
for name, (lo, hi) in fns.items():
    for v in flip["converted"].values():
        if v["base"] == name and v["def"].startswith(rel):
            revert_names.add(name)
    for ed in flip.get("edits", []):
        if ed["rel"] == rel and lo <= ed["line"] <= hi:
            revert_names.add(ed["g"])
    for s in match["sites"]:
        if s["rel"] == rel and lo <= s["line"] <= hi:
            match_sites.append(f"{s['rel']}:{s['line']}")
print("functions with new conflict blocks:", sorted(n for n in fns if n))
print("REVERT_NAMES=" + ",".join(sorted(n for n in revert_names if n)))
print("MATCH_SITES=" + ",".join(match_sites))
