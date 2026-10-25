#!/usr/bin/env python3
"""reborrow.py [--fix] FILE...: find `(& p)` / `(&mut p)` where p is a parameter of the enclosing
function that is already declared `(& ...)`/`(&mut ...)`. With --fix, rewrite `(& p)` to `p`
(only the shared form; `(&mut p)` is reported, not changed)."""
import re
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue/mainsrc"
fix = "--fix" in sys.argv
files = [a for a in sys.argv[1:] if a != "--fix"]
total = 0
for rel in files:
    text = open(f"{ROOT}/{rel}").read()
    starts = [m.start() for m in re.finditer(r"^\(", text, re.M)] + [len(text)]
    edits = []
    for a, b in zip(starts, starts[1:]):
        m = re.match(r"\(define \(([^\s)]+)", text[a:])
        if not m:
            continue
        i = text.index("(", a + 1)
        d = 0
        j = i
        while True:
            c = text[j]
            if c in "([":
                d += 1
            elif c in ")]":
                d -= 1
                if d == 0:
                    break
            j += 1
        refs = [p for p, ty in re.findall(r"\[([^\s\[\]]+) : (\((?:[^()]|\([^()]*\))*\)|[^\s\]]+)\]", text[i:j + 1])
                if ty.startswith("(&")]
        if not refs:
            continue
        body = text[j + 1:b]
        for p in refs:
            for mm in re.finditer(r"\((&|&mut) " + re.escape(p) + r"\)", body):
                off = j + 1 + mm.start()
                line = text.count("\n", 0, off) + 1
                print(f"{rel}:{line}\t{m.group(1)}\t{mm.group(0)}")
                total += 1
                if fix and mm.group(1) == "&":
                    edits.append((off, off + len(mm.group(0)), p))
    if fix and edits:
        for s, e, p in sorted(edits, reverse=True):
            text = text[:s] + p + text[e:]
        open(f"{ROOT}/{rel}", "w").write(text)
print("total", total, file=sys.stderr)
