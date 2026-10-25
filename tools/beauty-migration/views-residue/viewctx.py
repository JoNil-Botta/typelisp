#!/usr/bin/env python3
"""viewctx.py PREFIX FILE: for each identity view `(X-shared-view place)` in free forms of FILE, the
head of the enclosing form; prints counts by head (callees grouped with their definition module)."""
import collections
import glob
import os
import sys

sys.path.insert(0, "/tmp/claude-1000/-home-jonathan--herdr-worktrees-typelisp-beauty/"
                   "13093798-d60a-4806-9509-5dce90daa97b/scratchpad/borrows")
import sx  # noqa: E402

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/residue")
import prepass  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
prefix, rel = sys.argv[1], sys.argv[2]
held = set()
for p in glob.glob(f"{ROOT}/target/exp/residue/{prefix}-*.txt"):
    for line in open(p):
        f, n = line.rstrip("\n").split("\t")
        held.add((f, n.split(" ", 1)[-1]))
t = open(f"{ROOT}/{rel}").read()
heads = collections.Counter()
kinds = collections.Counter()


def form_name(f):
    kids = f[3]
    if len(kids) > 1:
        k1 = kids[1]
        if k1[0] == 'L' and k1[3] and k1[3][0][0] == 'A':
            return k1[3][0][3]
        if k1[0] == 'A':
            return k1[3]
    return "?"


def walk(n, parent):
    if n[0] == 'P':
        if n[4] is not None:
            walk(n[4], parent)
        return
    if n[0] not in ('L', 'V'):
        return
    if n[0] == 'L' and len(n[3]) == 2 and n[3][0][0] == 'A' and n[3][1][0] == 'A' \
            and prepass.view_rep(t[n[1]:n[2]]) is not None:
        if parent is None:
            kinds["top"] += 1
        elif parent[0] == 'V':
            kinds["binding"] += 1
        elif parent[3] and parent[3][0][0] == 'A':
            h = parent[3][0][3]
            if h in ("match", "if", "let", "cond", "when", "unless", "and", "or", "begin", "set!", "&", "not"):
                kinds[h] += 1
            elif h[:1].isupper() or "." in h and h.rsplit(".", 1)[1][:1].isupper():
                kinds["constructor"] += 1
            else:
                kinds["call"] += 1
                heads[h] += 1
        else:
            kinds["other"] += 1
        return
    for c in n[3]:
        walk(c, n)


for f in sx.parse(t):
    if f[0] == 'L' and (rel, form_name(f)) not in held:
        walk(f, None)
print(kinds.most_common())
for h, c in heads.most_common(40):
    print(c, h)
