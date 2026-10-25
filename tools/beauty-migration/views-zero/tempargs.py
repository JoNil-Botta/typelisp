#!/usr/bin/env python3
"""tempargs.py: for every read-only by-value parameter (readonly.json) the flip would turn into
(& T), classify the argument at each of its call sites: an identity view (the view goes), a place
(auto-borrows, unchanged text), a temporary (needs an explicit `(& (expr))`, unless the language
auto-borrowed temporaries), or a literal/constructor. Also counts the flip set restricted to
parameters that have at least one view site."""
import collections
import json
import re
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero")
import census_lib as C  # noqa: E402

R = C.ROOT + "/target/exp/zero/"
texts, parsed, defs = C.load()
ro = json.load(open(R + "readonly.json"))
flip = collections.defaultdict(dict)  # callee -> {idx: rel}
for k, v in ro.items():
    if v["ro"]:
        name, idx = k.rsplit("#", 1)
        flip[name][int(idx)] = v["rel"]
VIEW = re.compile(r"\((?:[a-z_]+\.)?[a-z_-]*(?:global|owned|place)-shared-view\s+[^\s()]+\)$")
PLACE = re.compile(r"[A-Za-z_*?!-][A-Za-z0-9_*?!.-]*$")
kinds = collections.Counter()
per_param = collections.defaultdict(collections.Counter)


def walk(n, t):
    if n[0] == 'P':
        if n[4] is not None:
            walk(n[4], t)
        return
    if n[0] not in ('L', 'V'):
        return
    k = n[3]
    if n[0] == 'L' and k and k[0][0] == 'A':
        g = C.base(k[0][3])
        if g in flip:
            for idx in flip[g]:
                if idx + 1 < len(k):
                    a = k[idx + 1]
                    s = re.sub(r"\s+", " ", t[a[1]:a[2]])
                    if a[0] == 'V':
                        continue
                    if a[0] == 'A' and PLACE.match(s) and not s[:1].isdigit() and s not in ("true", "false"):
                        kind = "place"
                    elif a[0] == 'P' or (a[0] == 'A' and "." in s):
                        kind = "place"
                    elif VIEW.match(s):
                        kind = "view"
                    elif a[0] == 'A' or s.startswith('"'):
                        kind = "literal"
                    elif a[0] == 'L' and a[3] and a[3][0][0] == 'A' and C.is_ctor(a[3][0][3]):
                        kind = "ctor"
                    elif s.startswith("(&"):
                        kind = "already-borrowed"
                    else:
                        kind = "temporary"
                    kinds[kind] += 1
                    per_param[f"{g}#{idx}"][kind] += 1
    for c in k:
        walk(c, t)


for rel, forms in parsed.items():
    t = texts[rel]
    for f in forms:
        walk(f, t)
print("all read-only params:", sum(len(v) for v in flip.values()), "call-site args:", dict(kinds))
with_views = {p: c for p, c in per_param.items() if c["view"] > 0}
agg = collections.Counter()
for c in with_views.values():
    agg.update(c)
print("params with >=1 view site:", len(with_views), "their call-site args:", dict(agg))
nt = sum(1 for c in with_views.values() if c["temporary"] == 0 and c["ctor"] == 0)
print("of those, params with no temporary argument (flip is a pure signature + view edit):", nt)
tmp_heads = collections.Counter()
