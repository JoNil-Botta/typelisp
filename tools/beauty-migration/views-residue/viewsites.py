#!/usr/bin/env python3
"""viewsites.py PREFIX FILE...: textual *-shared-view call uses per top-level form in FILEs, split
into free forms and forms held by open PRs (target/exp/residue/PREFIX-<n>.txt from prfuncs2.py).
Writes target/exp/residue/viewsites.tsv: file, line, form, held-by."""
import glob
import os
import re
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
prefix = sys.argv[1]
FORM = re.compile(r"^\((\S+)\s+\(?([^\s()\[\]]+)")
VIEW = re.compile(r"\((?:[A-Za-z0-9_]+\.)?[A-Za-z0-9-]*-shared-view[\s)]")
held = {}
for p in glob.glob(f"{ROOT}/target/exp/residue/{prefix}-*.txt"):
    pr = os.path.basename(p)[len(prefix) + 1:-4]
    for line in open(p):
        f, n = line.rstrip("\n").split("\t")
        held.setdefault((f, n.split(" ", 1)[-1]), set()).add(pr)
out = open(f"{ROOT}/target/exp/residue/viewsites.tsv", "w")
for f in sys.argv[2:]:
    cur = None
    free = tot = 0
    forms_free = set()
    for i, line in enumerate(open(f"{ROOT}/{f}"), 1):
        if line.startswith("("):
            m = FORM.match(line)
            cur = m.group(2) if m else None
            if m and m.group(1) in ("define", "defmacro") and cur and cur.endswith("-shared-view"):
                cur = "@def"
        code = line.split(";", 1)[0]
        code = re.sub(r'"(?:[^"\\]|\\.)*"', '""', code)
        n = len(VIEW.findall(code))
        if not n or cur == "@def":
            continue
        prs = held.get((f, cur), set())
        tot += n
        if not prs:
            free += n
            forms_free.add(cur)
        for _ in range(n):
            out.write(f"{f}\t{i}\t{cur}\t{','.join(sorted(prs)) or '-'}\n")
    print(f"{f}: views={tot} free={free} free-forms={len(forms_free)}")
