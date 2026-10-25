#!/usr/bin/env python3
"""cfgsites.py STATE: revert the moveLoop sites (STATE json) that sit inside a `(cfg ...)` form:
code there is only typechecked under that cfg, so a move the default check accepted is unproven."""
import json
import sys

sys.path.insert(0, "/tmp/claude-1000/-home-jonathan--herdr-worktrees-typelisp-beauty/"
                   "13093798-d60a-4806-9509-5dce90daa97b/scratchpad/borrows")
import sx  # noqa: E402

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
state_path = sys.argv[1]
state = json.load(open(state_path))
by_rel = {}
for s in state["sites"]:
    by_rel.setdefault(s["rel"], []).append(s)
reverted = 0
for rel, sites in by_rel.items():
    text = open(f"{ROOT}/{rel}").read()
    spans = []

    def walk(n):
        if n[0] == 'P':
            if n[4] is not None:
                walk(n[4])
            return
        if n[0] not in ('L', 'V'):
            return
        if n[0] == 'L' and n[3] and n[3][0][0] == 'A' and n[3][0][3] == 'cfg':
            spans.append((n[1], n[2]))
        for c in n[3]:
            walk(c)

    for f in sx.parse(text):
        walk(f)
    lines = text.split("\n")
    offs = [0]
    for ln in lines:
        offs.append(offs[-1] + len(ln) + 1)
    hits = []
    for s in sites:
        o = offs[s["line"] - 1] + s["col"]
        if any(a <= o < b for a, b in spans):
            hits.append(s)
    # revert right to left per line
    for s in sorted(hits, key=lambda s: (s["line"], s["col"]), reverse=True):
        ln = lines[s["line"] - 1]
        c = s["col"]
        assert ln[c:c + len(s["rep"])] == s["rep"], (s, ln)
        lines[s["line"] - 1] = ln[:c] + s["arg"] + ln[c + len(s["rep"]):]
        state["sites"].remove(s)
        state["reverted"].append(s)
        reverted += 1
        print("revert cfg site", rel, s["line"], s["arg"])
    open(f"{ROOT}/{rel}", "w").write("\n".join(lines))
json.dump(state, open(state_path, "w"))
print("reverted", reverted)
