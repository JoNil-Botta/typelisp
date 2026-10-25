#!/usr/bin/env python3
"""cgtop.py BASE.cg CAND.cg [N]: the N functions with the largest self-Ir changes between two
cachegrind outputs of the same input."""
import collections
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


a, b = load(sys.argv[1]), load(sys.argv[2])
n = int(sys.argv[3]) if len(sys.argv) > 3 else 15
ta, tb = sum(a.values()), sum(b.values())
print(f"total {ta} -> {tb} ({tb - ta:+d}, {(tb - ta) / ta * 100:+.4f}%)")
rows = sorted(set(a) | set(b), key=lambda f: -abs(b[f] - a[f]))
for f in rows[:n]:
    print(f"{b[f] - a[f]:+12d} {a[f]:>12} -> {b[f]:>12}  {f}")
