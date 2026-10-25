#!/usr/bin/env python3
"""selftail.py TREE STATE [--revert]: of the match-borrow sites in STATE (siteLoop json; lines are valid
in TREE), those inside a function that calls itself in tail position (#9044: a tail match on a
borrowed scrutinee falls back to a value match, so self tail calls in its arms stop being tail
calls). Tail positions: the body's last form, through if/when/unless/cond/begin/let/match/unsafe.
With --revert, the view goes back at those sites (in TREE) and they move to STATE's reverted list."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sx  # noqa: E402

tree, state_path = sys.argv[1], sys.argv[2]
revert = "--revert" in sys.argv
state = json.load(open(state_path))


def head(n):
    if n[0] == 'L' and n[3] and n[3][0][0] == 'A':
        return n[3][0][3]
    return None


def base(name):
    return name.rsplit(".", 1)[-1] if name and "." in name else name


def tails(n, out):
    """Collect the call nodes in tail position of expression n."""
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
    elif h in ("when", "unless"):
        if len(k) > 2:
            tails(k[-1], out)
    elif h in ("begin", "let", "unsafe", "with", "in-arena"):
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


by_rel = {}
for s in state["sites"]:
    by_rel.setdefault(s["rel"], []).append(s)
hits = []
for rel, sites in by_rel.items():
    text = open(f"{tree}/{rel}").read()
    lines = text.split("\n")
    starts = [0]
    for ln in lines:
        starts.append(starts[-1] + len(ln) + 1)
    selftail = {}
    spans = []
    for f in sx.parse(text):
        if head(f) != "define" or len(f[3]) < 3 or f[3][1][0] != 'L' or not f[3][1][3]:
            continue
        name = f[3][1][3][0][3]
        body = f[3][-1]
        out = []
        tails(body, out)
        # also `(return (f ...))` anywhere in the body
        stack = [body]
        while stack:
            n = stack.pop()
            if n[0] == 'P' and n[4] is not None:
                stack.append(n[4])
            elif n[0] in ('L', 'V'):
                if head(n) == "return" and len(n[3]) > 1:
                    tails(n[3][1], out)
                stack.extend(n[3])
        selftail[name] = any(base(head(c)) == name for c in out)
        spans.append((f[1], f[2], name))
    for s in sites:
        off = starts[s["line"] - 1] + s["col"]
        fn = next((nm for a, b, nm in spans if a <= off < b), None)
        if fn and selftail.get(fn):
            hits.append((s, fn))
print("match-borrow sites:", len(state["sites"]), "in self-tail-call functions:", len(hits))
for s, fn in hits:
    print("  ", s["rel"], s["line"], fn, s["arg"])
if revert and hits:
    for rel in by_rel:
        lines = open(f"{tree}/{rel}").read().split("\n")
        for s, fn in sorted([h for h in hits if h[0]["rel"] == rel], key=lambda h: (h[0]["line"], h[0]["col"]), reverse=True):
            ln = lines[s["line"] - 1]
            c = s["col"]
            rep = s["rep"]
            if ln[c:c + len(rep)] != rep:
                alt = rep[3:-1] if rep.startswith("(& ") else None
                if alt and ln[c:c + len(alt)] == alt:
                    rep = alt
                else:
                    print("WARN not found", s)
                    continue
            lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(rep):]
            state["sites"].remove(s)
            state["reverted"].append(s)
        open(f"{tree}/{rel}", "w").write("\n".join(lines))
    json.dump(state, open(state_path, "w"))
