#!/usr/bin/env python3
"""flipmatch.py TREE FLIPSTATE: a flipped parameter is a reference, so `(match param ...)` in its
function is a match on a borrowed scrutinee. Report those matches that have a nested variant pattern
(#8905) or sit in a function that calls itself in tail position (#9044)."""
import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import sx  # noqa: E402

spec = importlib.util.spec_from_file_location("st", HERE + "/selftail.py")
tree, state_path = sys.argv[1], sys.argv[2]
st = json.load(open(state_path))
flipped = {}
for v in st["converted"].values():
    flipped.setdefault((v["def"].split(":")[0], v["base"]), set()).add(v["param"])


def head(n):
    if n[0] == 'L' and n[3] and n[3][0][0] == 'A':
        return n[3][0][3]
    return None


def is_variant_pat(n):
    h = head(n)
    return h is not None and h.rsplit(".", 1)[-1][:1].isupper()


def nested(p):
    h = head(p)
    if h is None:
        return False
    if h == "or":
        return any(nested(c) for c in p[3][1:])
    if not is_variant_pat(p):
        return False
    return any(is_variant_pat(c) or (head(c) == "or" and any(is_variant_pat(cc) for cc in c[3][1:]))
               for c in p[3][1:])


def tails(n, out):
    if n[0] == 'P':
        if n[4] is not None:
            tails(n[4], out)
        return
    if n[0] != 'L' or not n[3]:
        return
    h = head(n)
    k = n[3]
    if h == "if":
        for c in k[2:4]:
            tails(c, out)
    elif h in ("when", "unless", "begin", "let", "unsafe", "with", "in-arena"):
        if len(k) > 1:
            tails(k[-1], out)
    elif h == "cond":
        for clause in k[1:]:
            if clause[0] in ('V', 'L') and clause[3]:
                tails(clause[3][-1], out)
    elif h == "match":
        for arm in k[2:]:
            if arm[0] == 'V' and len(arm[3]) > 1:
                tails(arm[3][-1], out)
    elif h == "return":
        if len(k) > 1:
            tails(k[1], out)
    elif h is not None:
        out.append(n)


rels = sorted({r for r, _ in flipped})
found = []
for rel in rels:
    text = open(f"{tree}/{rel}").read()
    for f in sx.parse(text):
        if head(f) != "define" or len(f[3]) < 3 or f[3][1][0] != 'L' or not f[3][1][3]:
            continue
        name = f[3][1][3][0][3]
        params = flipped.get((rel, name))
        if not params:
            continue
        out = []
        tails(f[3][-1], out)
        selft = any((head(c) or "").rsplit(".", 1)[-1] == name for c in out)
        stack = [f[3][-1]]
        while stack:
            n = stack.pop()
            if n[0] == 'P':
                if n[4] is not None:
                    stack.append(n[4])
                continue
            if n[0] not in ('L', 'V'):
                continue
            if head(n) == "match" and len(n[3]) > 1:
                sc = n[3][1]
                if sc[0] == 'A' and sc[3] in params:
                    arms = [a for a in n[3][2:] if a[0] == 'V' and a[3]]
                    nest = any(nested(a[3][0]) for a in arms)
                    if nest or selft:
                        line = text.count("\n", 0, n[1]) + 1
                        found.append((rel, line, name, sc[3], "nested" if nest else "", "selftail" if selft else ""))
            stack.extend(n[3])
print("flipped-parameter matches with a nested pattern or in a self-tail-call function:", len(found))
for r in found:
    print("  ", *r)
