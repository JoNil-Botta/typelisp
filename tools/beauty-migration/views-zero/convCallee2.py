#!/usr/bin/env python3
"""convCallee2.py FILE NAME PARAM NEWTYPE: in FILE, set the declared type of parameter PARAM of the
(unique) definition of NAME to NEWTYPE. Prints `OLD<TAB>file:line`, or `ERR ...`."""
import re
import sys

ROOT = __import__("os").environ.get("ZROOT", "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3")
rel, name, param, newty = sys.argv[1:5]
path = f"{ROOT}/{rel}"
text = open(path).read()
hits = [m.start() for m in re.finditer(r"^\(define \(" + re.escape(name) + r"(?=[\s)])", text, re.M)]
if len(hits) != 1:
    print("ERR definitions:", len(hits))
    sys.exit(1)
start = hits[0]
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
    print("ERR param not found")
    sys.exit(1)
ts = i + pm.end()
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
old = text[ts:k]
if old == newty:
    print("ERR unchanged", old)
    sys.exit(1)
text = text[:ts] + newty + text[k:]
open(path, "w").write(text)
print(f"{old}\t{rel}:{text.count(chr(10), 0, start) + 1}")
