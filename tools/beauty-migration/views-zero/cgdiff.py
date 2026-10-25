#!/usr/bin/env python3
"""cgdiff.py BASE.cg CAND.cg STATE.json [MATCH.json]: per-function self Ir from two cachegrind
outputs of the same input; reports the hottest functions whose parameters the flip prototype
converted (STATE converted entries) or whose match scrutinee it borrowed (MATCH sites), with
their Ir deltas, plus the module totals."""
import collections
import json
import re
import sys


def load(path):
    ir = collections.Counter()
    fn = None
    for line in open(path, errors="replace"):
        if line.startswith("fn="):
            fn = line[3:].strip()
        elif line[:1].isdigit() and fn is not None:
            parts = line.split()
            if len(parts) >= 2:
                ir[fn] += int(parts[1])
    return ir


def sym(name):
    s = name.replace("?", "_question").replace("!", "_bang").replace("-", "_").replace("*", "_star")
    return s


base, cand = load(sys.argv[1]), load(sys.argv[2])
state = json.load(open(sys.argv[3]))
flipped = {}
for v in state["converted"].values():
    flipped.setdefault(v["base"], []).append(v["param"])
matched = set()
if len(sys.argv) > 4:
    ms = json.load(open(sys.argv[4]))
    root = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/"
    for s in ms["sites"]:
        lines = open(root + s["rel"]).read().split("\n")
        i = s["line"]
        while i > 1 and not lines[i - 1].startswith("("):
            i -= 1
        m = re.match(r"\(define \(([^\s)]+)", lines[i - 1])
        if m:
            matched.add(m.group(1))
total_b, total_c = sum(base.values()), sum(cand.values())
print(f"total Ir {total_b} -> {total_c} ({total_c - total_b:+d}, {(total_c - total_b) / total_b * 100:+.4f}%)")
by_sym = {}
for f in set(base) | set(cand):
    m = re.match(r"_tl_(?:typelisp_src_)?(.+?)_\1_(.+)$", f)
    if m:
        by_sym.setdefault(m.group(2), []).append(f)
rows = []
for name in set(flipped) | matched:
    for f in by_sym.get(sym(name), []):
        rows.append((base[f], cand[f], name, f))
rows.sort(reverse=True)
print("hottest touched functions (base Ir, cand Ir, delta, flipped params / match-borrow):")
for b, c, name, f in rows[:15]:
    tag = ",".join(flipped.get(name, [])) + (" [match]" if name in matched else "")
    print(f"{b:>12} {c:>12} {c - b:+10d} {b / total_b * 100:6.3f}%  {name}  ({tag})")
tb = sum(r[0] for r in rows)
tc = sum(r[1] for r in rows)
print(f"all {len(rows)} touched functions: {tb} -> {tc} ({tc - tb:+d})")
mods = collections.Counter()
modc = collections.Counter()
for f in set(base) | set(cand):
    m = re.match(r"_tl_(?:typelisp_src_)?(compiler_[a-z_]+?)_\1_", f)
    k = m.group(1) if m else "other"
    mods[k] += base[f]
    modc[k] += cand[f]
print("module totals with the largest deltas:")
for k in sorted(mods, key=lambda k: -abs(modc[k] - mods[k]))[:6]:
    print(f"  {k}: {mods[k]} -> {modc[k]} ({modc[k] - mods[k]:+d})")
