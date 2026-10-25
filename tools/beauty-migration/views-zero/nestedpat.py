#!/usr/bin/env python3
"""nestedpat.py STATE [--revert]: of the match-borrow sites in STATE (siteLoop json), those whose
match has an arm with a nested enum-variant pattern (a variant pattern inside a variant pattern, or
an or-pattern of them), which #8905 miscompiles for a match on a reference. With --revert, put
the original view back at those sites."""
import json
import sys

sys.path.insert(0, "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3/target/exp/zero")
import sx  # noqa: E402

ROOT = __import__("os").environ.get("TREE", "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3")
state_path = sys.argv[1]
revert = "--revert" in sys.argv
state = json.load(open(state_path))


def is_variant_pat(n):
    return n[0] == 'L' and n[3] and n[3][0][0] == 'A' and n[3][0][3][:1].isupper() or \
        (n[0] == 'L' and n[3] and n[3][0][0] == 'A' and "." in n[3][0][3]
         and n[3][0][3].rsplit(".", 1)[-1][:1].isupper())


def nested(p):
    if p[0] != 'L' or not p[3] or p[3][0][0] != 'A':
        return False
    h = p[3][0][3]
    if h == "or":
        return any(nested(c) for c in p[3][1:])
    if not is_variant_pat(p):
        return False
    return any(is_variant_pat(c) or (c[0] == 'L' and c[3] and c[3][0][0] == 'A' and c[3][0][3] in ("or",)
                                     and any(is_variant_pat(cc) for cc in c[3][1:]))
               for c in p[3][1:])


by_rel = {}
for s in state["sites"]:
    by_rel.setdefault(s["rel"], []).append(s)
hits = []
for rel, sites in by_rel.items():
    text = open(f"{ROOT}/{rel}").read()
    lines = text.split("\n")
    starts = [0]
    for ln in lines:
        starts.append(starts[-1] + len(ln) + 1)
    forms = sx.parse(text)
    matches = []

    def walk(n):
        if n[0] == 'P':
            if n[4] is not None:
                walk(n[4])
            return
        if n[0] not in ('L', 'V'):
            return
        if n[0] == 'L' and n[3] and n[3][0][0] == 'A' and n[3][0][3] == "match" and len(n[3]) > 1:
            matches.append(n)
        for c in n[3]:
            walk(c)

    for f in forms:
        walk(f)
    by_start = {m[3][1][1]: m for m in matches}
    for s in sites:
        off = starts[s["line"] - 1] + s["col"]
        m = by_start.get(off)
        if m is None:
            continue
        arms = [a for a in m[3][2:] if a[0] == 'V' and a[3]]
        if any(nested(a[3][0]) for a in arms):
            hits.append(s)
print("match-borrow sites:", len(state["sites"]), "with a nested variant pattern:", len(hits))
if revert and hits:
    for rel in by_rel:
        lines = open(f"{ROOT}/{rel}").read().split("\n")
        for s in sorted([h for h in hits if h["rel"] == rel], key=lambda s: (s["line"], s["col"]), reverse=True):
            ln = lines[s["line"] - 1]
            c = s["col"]
            assert ln[c:c + len(s["rep"])] == s["rep"], (s, ln[c:c + 40])
            lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(s["rep"]):]
            state["sites"].remove(s)
            state["reverted"].append(s)
        open(f"{ROOT}/{rel}", "w").write("\n".join(lines))
    json.dump(state, open(state_path, "w"))
