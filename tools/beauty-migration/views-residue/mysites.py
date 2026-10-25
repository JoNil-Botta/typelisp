#!/usr/bin/env python3
"""usage: mysites.py: list -seq-ref call sites in my residue files on the working tree, with the
enclosing top-level form and whether that form is touched by open PRs (funcs-<n>.txt)."""
import glob
import os
import re

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
FILES = ["src/compiler_backend.tl", "src/compiler_regalloc.tl", "src/compiler_ir_types.tl",
         "src/compiler_lower.tl", "src/compiler_liveness.tl"]
FORM = re.compile(r"^\((\S+)\s+\(?([^\s()\[\]]+)")
SITE = re.compile(r"compiler-ir-[a-z0-9-]+-seq-ref\b")

held = {}
for path in glob.glob(f"{ROOT}/target/exp/residue/funcs-*.txt"):
    pr = os.path.basename(path)[6:-4]
    for line in open(path):
        f, n = line.rstrip("\n").split("\t")
        held.setdefault((f, n), []).append(pr)

total = 0
free = 0
for f in FILES:
    cur = None
    for i, line in enumerate(open(f"{ROOT}/{f}"), 1):
        if line.startswith("("):
            m = FORM.match(line)
            cur = (m.group(1) + " " + m.group(2)) if m else line[:40]
        code = line.split(";", 1)[0]
        for m in SITE.finditer(code):
            if cur and cur.endswith("-seq-ref"):
                continue
            prs = held.get((f, cur), [])
            total += 1
            if not prs:
                free += 1
            print(f"{f}:{i}\t{m.group(0)}\t{cur}\t{','.join(sorted(prs)) or '-'}\t{line.strip()[:120]}")
print(f"# total={total} free={free}")
