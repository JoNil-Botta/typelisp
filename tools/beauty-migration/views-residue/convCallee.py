#!/usr/bin/env python3
"""convCallee.py NAME PARAM [--revert]: in src/, change the definition of NAME so that parameter
PARAM (by name) has type (& T) instead of T (or back with --revert). Prints file:line of the
definition, or an error."""
import glob
import re
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
name, param = sys.argv[1], sys.argv[2]
revert = "--revert" in sys.argv
base = name.rsplit(".", 1)[-1]
hits = []
for path in sorted(glob.glob(ROOT + "/src/*.tl")):
    text = open(path).read()
    for m in re.finditer(r"^\(define \(" + re.escape(base) + r"(?=[\s)])", text, re.M):
        hits.append((path, m.start(), text))
if len(hits) != 1:
    print("ERR definitions:", len(hits), [h[0] for h in hits])
    sys.exit(1)
path, start, text = hits[0]
# header: from start to the closing paren of the (NAME params...) list
i = text.index("(", start + 1)
depth = 0
j = i
while True:
    ch = text[j]
    if ch in "([":
        depth += 1
    elif ch in ")]":
        depth -= 1
        if depth == 0:
            break
    j += 1
header = text[i:j + 1]
pm = re.search(r"\[" + re.escape(param) + r" : ", header)
if not pm:
    print("ERR param not found in", header[:200])
    sys.exit(1)
ts = i + pm.end()
# type extent
k = ts
if text[k] == "(":
    d = 0
    while True:
        if text[k] == "(":
            d += 1
        elif text[k] == ")":
            d -= 1
            if d == 0:
                k += 1
                break
        k += 1
else:
    while text[k] not in " ]":
        k += 1
ty = text[ts:k]
if revert:
    m2 = re.fullmatch(r"\(& (.*)\)", ty, re.S)
    if not m2:
        print("ERR not a reference:", ty)
        sys.exit(1)
    new = m2.group(1)
else:
    if ty.startswith("(&"):
        print("ERR already a reference:", ty)
        sys.exit(1)
    new = "(& " + ty + ")"
text = text[:ts] + new + text[k:]
open(path, "w").write(text)
line = text.count("\n", 0, start) + 1
print(f"{path[len(ROOT) + 1:]}:{line}\t{base}\t{param}\t{ty} -> {new}")
