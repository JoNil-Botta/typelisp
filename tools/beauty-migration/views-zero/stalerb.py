#!/usr/bin/env python3
"""stalerb.py MAIN TREE [--fix]: lines where MAIN has `(& x)` and TREE has `x` (a re-borrow fix), but x is
not a reference parameter of TREE's enclosing function any more (its flip was reverted). With --fix,
put MAIN's line back."""
import re
import sys

main_path, tree_path = sys.argv[1], sys.argv[2]
fix = "--fix" in sys.argv
a = open(main_path).read().split("\n")
b = open(tree_path).read().split("\n")
assert len(a) == len(b)


def params_of(lines, ln):
    i = ln
    while i > 1 and not lines[i - 1].startswith("("):
        i -= 1
    out = {}
    j = i
    while j <= len(lines) and j < i + 80:
        for m in re.finditer(r"\[([A-Za-z0-9_?!*-]+) : (\([^\]]*\)|[^\]\s]+)\]", lines[j - 1]):
            out[m.group(1)] = m.group(2)
        if re.search(r"\) : ", lines[j - 1]) or "]) :" in lines[j - 1]:
            break
        j += 1
    return out


stale = []
for i, (x, y) in enumerate(zip(a, b)):
    if x == y:
        continue
    for m in re.finditer(r"\(& ([A-Za-z0-9_?!*-]+)\)", x):
        name = m.group(1)
        if x.replace(m.group(0), name, 1) == y:
            ps = params_of(b, i + 1)
            ty = ps.get(name)
            if ty is None or not ty.startswith("(&"):
                stale.append(i + 1)
                print(i + 1, name, ty, y.strip()[:80])
if fix:
    for ln in stale:
        b[ln - 1] = a[ln - 1]
    open(tree_path, "w").write("\n".join(b))
print("stale re-borrow fixes:", len(stale))
