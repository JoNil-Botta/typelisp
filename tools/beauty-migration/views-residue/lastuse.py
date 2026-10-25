#!/usr/bin/env python3
"""lastuse.py OLD_STATE NEW_STATE: from moveLoop's reverted sites, pick those whose place is not
named again later in its top-level form (a textual last use), switch them in the files again
and write NEW_STATE for moveLoop to verify."""
import bisect
import json
import re
import sys

ROOT = "/home/jonathan/dev/typelisp/.claude/worktrees/agent-aba4773dcedc2d8a3"
old = json.load(open(sys.argv[1]))
by_rel = {}
for s in old["reverted"]:
    by_rel.setdefault(s["rel"], []).append(s)
new_sites = []
for rel, sites in by_rel.items():
    text = open(f"{ROOT}/{rel}").read()
    lines = text.split("\n")
    starts = [0]
    for ln in lines:
        starts.append(starts[-1] + len(ln) + 1)
    form_starts = [m.start() for m in re.finditer(r"^\(", text, re.M)] + [len(text)]
    pick = []
    for s in sites:
        off = starts[s["line"] - 1] + s["col"]
        if text[off:off + len(s["arg"])] != s["arg"]:
            continue
        place = s["rep"]
        root = place.split(".")[0]
        i = bisect.bisect_right(form_starts, off)
        fend = form_starts[i] if i < len(form_starts) else len(text)
        rest = text[off + len(s["arg"]):fend]
        if re.search(r"(?<![A-Za-z0-9_?!*.-])" + re.escape(root) + r"(?![A-Za-z0-9_?!*-])", rest):
            continue
        # not inside a loop form of the function (a later iteration reads it again)
        fstart = form_starts[i - 1]
        before = text[fstart:off]
        if re.search(r"\((?:for|while|loop|foreach)\b", before):
            continue
        pick.append((off, s))
    for off, s in sorted(pick, key=lambda x: x[0], reverse=True):
        text = text[:off] + s["rep"] + text[off + len(s["arg"]):]
    open(f"{ROOT}/{rel}", "w").write(text)
    # recompute positions in the rewritten text
    shift = 0
    for off, s in sorted(pick, key=lambda x: x[0]):
        ns = off - shift
        line = text.count("\n", 0, ns) + 1
        col = ns - (text.rfind("\n", 0, ns) + 1)
        new_sites.append({"rel": rel, "line": line, "col": col, "arg": s["arg"], "rep": s["rep"]})
        shift += len(s["arg"]) - len(s["rep"])
    print(rel, "retry", len(pick))
json.dump({"sites": new_sites, "reverted": []}, open(sys.argv[2], "w"))
