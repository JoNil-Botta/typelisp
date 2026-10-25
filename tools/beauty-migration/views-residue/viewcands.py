#!/usr/bin/env python3
"""viewcands.py PREFIX DEF-FILE FILE...: candidate consumer parameters for (& T) conversion.
For every call `(f ... (X-shared-view place) ...)` in free top-level forms of FILEs, count the
view argument at f's parameter position. Only callees defined (once) in DEF-FILE, in a free form,
are reported: `callee<TAB>param<TAB>count<TAB>type`, most views first."""
import collections
import glob
import os
import re
import sys

sys.path.insert(0, "/tmp/claude-1000/-home-jonathan--herdr-worktrees-typelisp-beauty/"
                   "13093798-d60a-4806-9509-5dce90daa97b/scratchpad/borrows")
import sx  # noqa: E402

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
prefix, deffile, files = sys.argv[1], sys.argv[2], sys.argv[3:]
held = set()
for p in glob.glob(f"{ROOT}/target/exp/residue/{prefix}-*.txt"):
    for line in open(p):
        f, n = line.rstrip("\n").split("\t")
        held.add((f, n.split(" ", 1)[-1]))


def form_name(f):
    kids = f[3]
    if len(kids) > 1:
        k1 = kids[1]
        if k1[0] == 'L' and k1[3] and k1[3][0][0] == 'A':
            return k1[3][0][3]
        if k1[0] == 'A':
            return k1[3]
    return "?"


# definitions in DEF-FILE: name -> [(param, type)]
text = open(f"{ROOT}/{deffile}").read()
defs = {}
dupe = set()
for f in sx.parse(text):
    if f[0] == 'L' and f[3] and f[3][0][0] == 'A' and f[3][0][3] == 'define' and len(f[3]) > 1 \
            and f[3][1][0] == 'L':
        name = form_name(f)
        params = []
        for p in f[3][1][3][1:]:
            if p[0] == 'V' and len(p[3]) >= 3 and p[3][0][0] == 'A':
                params.append((p[3][0][3], text[p[3][2][1]:p[3][-1][2]]))
            else:
                params.append((None, None))
        if name in defs:
            dupe.add(name)
        defs[name] = (params, (deffile, name) not in held)

counts = collections.Counter()
for rel in files:
    t = open(f"{ROOT}/{rel}").read()

    def walk(n):
        if n[0] == 'P':
            if n[4] is not None:
                walk(n[4])
            return
        if n[0] not in ('L', 'V'):
            return
        kids = n[3]
        if n[0] == 'L' and kids and kids[0][0] == 'A':
            callee = kids[0][3].rsplit('.', 1)[-1]
            if callee in defs and callee not in dupe:
                for i, a in enumerate(kids[1:]):
                    if a[0] == 'L' and len(a[3]) == 2 and a[3][0][0] == 'A' and a[3][1][0] == 'A' \
                            and prepass.view_rep(t[a[1]:a[2]]) is not None:
                        counts[(callee, i)] += 1
        for c in kids:
            walk(c)

    for f in sx.parse(t):
        if f[0] == 'L' and (rel, form_name(f)) not in held:
            walk(f)

for (callee, i), c in counts.most_common():
    params, free = defs[callee]
    if i >= len(params) or params[i][0] is None:
        continue
    pname, ty = params[i]
    if ty.startswith('(&'):
        continue
    print(f"{callee}\t{pname}\t{c}\t{ty}")
